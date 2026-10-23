import XCTest
import Darwin
@testable import DiskBridge

private final class MemoryDisk: BlockBackend {
    var bytes = Data(repeating: 0, count: 8192)
    var writable = true
    var flushes = 0
    var size: UInt64 { UInt64(bytes.count) }
    func read(offset: UInt64, count: Int) throws -> Data { bytes.subdata(in: Int(offset)..<(Int(offset) + count)) }
    func write(offset: UInt64, data: Data) throws { bytes.replaceSubrange(Int(offset)..<(Int(offset) + data.count), with: data) }
    func flush() throws { flushes += 1 }
    func keepAlive() throws {}
}
final class BridgeTests: XCTestCase {
    private func rpc(_ server: NFSServer, program: UInt32 = 100003, procedure: UInt32, args: XDRWriter) throws -> XDRReader {
        var w = XDRWriter()
        for value in [UInt32(42), 0, 2, program, 3, procedure] { w.word(value) }
        var auth = XDRWriter(); auth.word(0); auth.string("test"); auth.word(getuid()); auth.word(getgid()); auth.word(0)
        w.word(1); w.opaque(auth.bytes); w.word(0); w.word(0); w.bytes += args.bytes
        var reply = XDRReader(server.handle(w.bytes))
        XCTAssertEqual(try reply.word(), 42)
        XCTAssertEqual(try reply.word(), 1)
        for _ in 0..<4 { XCTAssertEqual(try reply.word(), 0) }
        return reply
    }
    private func file(_ server: NFSServer) throws -> [UInt8] {
        var args = XDRWriter(); args.string(server.exportPath)
        var mounted = try rpc(server, program: 100005, procedure: 1, args: args)
        XCTAssertEqual(try mounted.word(), 0)
        let root = try mounted.opaque()
        args = XDRWriter(); args.opaque(root); args.string("lun.raw")
        var lookup = try rpc(server, procedure: 3, args: args)
        XCTAssertEqual(try lookup.word(), 0)
        return try lookup.opaque()
    }
    func testPrivateExportRejectsWrongPath() throws {
        let server = try NFSServer(backend: MemoryDisk())
        var args = XDRWriter(); args.string("/wrong")
        var result = try rpc(server, program: 100005, procedure: 1, args: args)
        XCTAssertEqual(try result.word(), 13)
    }
    func testWriteIsDurableBeforeAcknowledgementAndReadMatches() throws {
        let disk = MemoryDisk(), server = try NFSServer(backend: disk), handle = try file(server)
        var args = XDRWriter(); args.opaque(handle); args.long(511); args.word(4); args.word(0); args.opaque([1, 2, 3, 4])
        var written = try rpc(server, procedure: 7, args: args)
        XCTAssertEqual(try written.word(), 0)
        XCTAssertEqual(disk.flushes, 1)
        _ = try written.fixed(92) // wcc: absent pre + post flag + fattr3
        XCTAssertEqual(try written.word(), 4)
        XCTAssertEqual(try written.word(), 2) // FILE_SYNC, never false durability
        args = XDRWriter(); args.opaque(handle); args.long(511); args.word(4)
        var read = try rpc(server, procedure: 6, args: args)
        XCTAssertEqual(try read.word(), 0)
        _ = try read.fixed(88)
        XCTAssertEqual(try read.word(), 4); XCTAssertEqual(try read.word(), 0)
        XCTAssertEqual(try read.opaque(), [1, 2, 3, 4])
    }
    func testReadOnlyAndOutOfBoundsWriteRejected() throws {
        let disk = MemoryDisk(), server = try NFSServer(backend: disk), handle = try file(server)
        var args = XDRWriter(); args.opaque(handle); args.long(8191); args.word(4); args.word(2); args.opaque([1, 2, 3, 4])
        var response = try rpc(server, procedure: 7, args: args)
        XCTAssertEqual(try response.word(), 22)
        disk.writable = false
        response = try rpc(server, procedure: 7, args: args)
        XCTAssertEqual(try response.word(), 30)
        XCTAssertEqual(disk.flushes, 0)
    }
    func testXDRRejectsUnboundedOrTruncatedInput() throws {
        var w = XDRWriter(); w.word(UInt32.max)
        var r = XDRReader(w.bytes)
        XCTAssertThrowsError(try r.opaque())
        r = XDRReader([0, 0, 0])
        XCTAssertThrowsError(try r.word())
    }
}
