import XCTest
@testable import ISCSICore

final class MockTransport: Transport {
    var sent: [PDU] = []
    var responses: [PDU] = []
    var responder: ((PDU) throws -> [PDU])?
    func send(_ pdu: PDU) throws { sent.append(pdu); if let responder { responses += try responder(pdu) } }
    func receive() throws -> PDU {
        guard !responses.isEmpty else { throw ISCSIError.message("Mock: no response") }
        return responses.removeFirst()
    }
    func close() {}
}

final class ProtocolTests: XCTestCase {
    func testTargetMappingRejectsMissingLUNBeforeDiskCommands() throws {
        let wire = mock()
        let session = try Session(configuration: Configuration(host: "mock"), transport: wire)
        try session.login(target: "iqn.test")
        try session.requireAvailableLUN(3)
        XCTAssertThrowsError(try session.requireAvailableLUN(1)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("1"))
            XCTAssertTrue(message.contains("0, 3"))
        }
        XCTAssertFalse(wire.sent.contains { $0.opcode == 1 && [UInt8(0x12), 0x88, 0x8a].contains($0.header[32]) })
    }
    func testFramingAndPadding() throws {
        let bytes = try PDU(4, flags: 0x80, data: [1, 2, 3, 4, 5]).encoded()
        XCTAssertEqual(bytes.count, 56)
        XCTAssertEqual(bytes.uint(5, 3), 5)
        XCTAssertEqual(Array(bytes.suffix(3)), [0, 0, 0])
    }
    func testTextPreservesDuplicateAddresses() throws {
        let pdu = PDU(0, data: PDU.text([("TargetName", "iqn.test"), ("TargetAddress", "a"), ("TargetAddress", "b")]))
        XCTAssertEqual(try pdu.pairs().map(\.1), ["iqn.test", "a", "b"])
        XCTAssertThrowsError(try PDU(0, data: Array("invalid".utf8)).pairs())
    }
    func testCHAPVector() throws {
        // Independently generated MD5(id || secret || challenge).
        XCTAssertEqual(try Session.chapResponse(identifier: 7, secret: "secret", challenge: "0x000102030405060708090a0b0c0d0e0f"), "0x821643665b430359e52ac524d29c8f95")
        XCTAssertThrowsError(try Session.chapResponse(identifier: 7, secret: "secret", challenge: "0xzz"))
        XCTAssertEqual(try Session.chapResponse(identifier: 7, secret: "secret", challenge: "0bAAECAwQFBgcICQoLDA0ODw=="), try Session.chapResponse(identifier: 7, secret: "secret", challenge: "0x000102030405060708090a0b0c0d0e0f"))
    }
    private func mock() -> MockTransport {
        let wire = MockTransport()
        var stat: UInt64 = 0
        wire.responder = { request in
            var r: PDU
            if request.opcode == 3 {
                r = PDU(0x23, flags: request.header[1], data: request.header[1] == 0x81 ? PDU.text([("AuthMethod", "None")]) : [])
                r.header.replaceSubrange(8..<14, with: request.header[8..<14])
                r.header.put(1, at: 14, count: 2)
            } else if request.opcode == 4 {
                r = PDU(0x24, flags: 0x80, data: PDU.text([("TargetName", "iqn.test"), ("TargetAddress", "127.0.0.1:3260,1")]))
                r.header.put(0xffffffff, at: 20)
            } else {
                let opcode = request.header[32]
                var data: [UInt8]
                if opcode == 0x12 {
                    data = [UInt8](repeating: 0, count: 96)
                    data.replaceSubrange(8..<16, with: Array("SYNOLOGY".utf8))
                    data.replaceSubrange(16..<32, with: Array("TEST LUN        ".utf8))
                } else if opcode == 0xa0 {
                    data = [UInt8](repeating: 0, count: 24)
                    data.put(16, at: 0); data[17] = 3
                } else if opcode == 0x9e {
                    data = [UInt8](repeating: 0, count: 32)
                    data.put(2047, at: 0, count: 8); data.put(512, at: 8)
                } else { data = [UInt8](repeating: 0xab, count: Int(request.header.uint(20, 4))) }
                r = PDU(0x25, flags: 0x81, data: data)
            }
            r.header.put(request.header.uint(16, 4), at: 16)
            r.header.put(stat, at: 24); stat += 1
            r.header.put(1, at: 28); r.header.put(100, at: 32)
            return [r]
        }
        return wire
    }
    func testDiscoverySession() throws {
        let wire = mock(), session = try Session(configuration: Configuration(host: "mock"), transport: wire)
        try session.login()
        let targets = try session.discover()
        XCTAssertEqual(targets.first?.name, "iqn.test")
        XCTAssertEqual(targets.first?.portals, ["127.0.0.1:3260,1"])
        XCTAssertEqual(wire.sent[2].header.uint(24, 4), 1)
    }
    func testInspectionReadAndWriteRejection() throws {
        let wire = mock(), session = try Session(configuration: Configuration(host: "mock"), transport: wire)
        try session.login(target: "iqn.test")
        let info = try session.inspect(lun: 0)
        XCTAssertEqual(info.vendor, "SYNOLOGY")
        XCTAssertEqual(info.byteCount, 1_048_576)
        let data = try session.read(lun: 0, lba: 2047, blocks: 1, info: info)
        XCTAssertEqual(data.count, 512)
        XCTAssertEqual(data.first, 0xab)
        let count = wire.sent.count
        XCTAssertThrowsError(try session.read(lun: 0, lba: 2048, blocks: 1, info: info))
        XCTAssertThrowsError(try session.command(lun: 0, cdb: [0x2a], expected: 512))
        XCTAssertEqual(wire.sent.count, count)
    }
    func testReportLUNs() throws {
        let wire = mock(), session = try Session(configuration: Configuration(host: "mock"), transport: wire)
        try session.login(target: "iqn.test")
        XCTAssertEqual(try session.listLUNs(), [0, 3])
    }
    func testSegmentedDataWithSeparateResponseAndNOP() throws {
        let wire = mock(), session = try Session(configuration: Configuration(host: "mock"), transport: wire)
        try session.login(target: "iqn.test")
        wire.responder = { request in
            if request.opcode == 0 { return [] }
            var nop = PDU(0x20, flags: 0x80, data: [42])
            nop.header.put(0xffffffff, at: 16); nop.header.put(12, at: 20)
            var first = PDU(0x25, data: [1, 2]), second = PDU(0x25, flags: 0x80, data: [3, 4])
            var status = PDU(0x21, flags: 0x80)
            for index in 0..<3 {
                var p = [first, second, status][index]
                p.header.put(request.header.uint(16, 4), at: 16)
                p.header.put(100, at: 32)
                if index == 0 { first = p }
                if index == 1 { p.header.put(1, at: 36); p.header.put(2, at: 40); second = p }
                if index == 2 { p.header.put(2, at: 24); status = p }
            }
            return [nop, first, second, status]
        }
        XCTAssertEqual(try session.command(lun: 0, cdb: [0x12], expected: 4), [1, 2, 3, 4])
        XCTAssertEqual(wire.sent.last?.opcode, 0)
        XCTAssertEqual(wire.sent.last?.data, [42])
        XCTAssertEqual(wire.sent.last?.header.uint(20, 4), 12)
    }
    func testUnavailableLUNIsNotPresentedAsDisk() throws {
        let wire = mock(), normal = wire.responder!
        wire.responder = { request in
            var response = try normal(request)
            if request.opcode == 1 && request.header[32] == 0x12 { response[0].data[0] = 0x3f }
            return response
        }
        let session = try Session(configuration: Configuration(host: "mock"), transport: wire)
        try session.login(target: "iqn.test")
        XCTAssertThrowsError(try session.inspect(lun: 0))
        XCTAssertEqual(wire.sent.count, 3)
    }
    func testRejectOutOfOrderDataAndBadStatus() throws {
        let wire = mock(), session = try Session(configuration: Configuration(host: "mock"), transport: wire)
        try session.login(target: "iqn.test")
        wire.responder = { request in
            var r = PDU(0x25, flags: 0x81, data: [0])
            r.header.put(request.header.uint(16, 4), at: 16)
            r.header.put(2, at: 24); r.header.put(100, at: 32)
            r.header.put(1, at: 40)
            return [r]
        }
        XCTAssertThrowsError(try session.command(lun: 0, cdb: [0x12], expected: 96))
    }
    func testDigestNegotiationFailsClosed() throws {
        let wire = mock()
        let normal = wire.responder!
        wire.responder = { request in
            var result = try normal(request)
            if request.opcode == 3 && request.header[1] == 0x87 { result[0].data = PDU.text([("DataDigest", "CRC32C")]) }
            return result
        }
        let session = try Session(configuration: Configuration(host: "mock"), transport: wire)
        XCTAssertThrowsError(try session.login())
        XCTAssertThrowsError(try session.discover())
    }
    func testSolicitedWriteAndFlush() throws {
        let wire = mock(), normal = wire.responder!
        var written: [UInt8] = []
        var writeTag: UInt64 = 0
        wire.responder = { request in
            if request.opcode == 3 { return try normal(request) }
            if request.opcode == 1 && request.header[32] == 0x8a {
                writeTag = request.header.uint(16, 4)
                var r = PDU(0x31, flags: 0x80)
                r.header.put(writeTag, at: 16); r.header.put(77, at: 20)
                r.header.put(2, at: 24); r.header.put(100, at: 32); r.header.put(32768, at: 44)
                return [r]
            }
            if request.opcode == 5 {
                XCTAssertEqual(request.header.uint(20, 4), 77)
                XCTAssertEqual(request.header.uint(40, 4), UInt64(written.count))
                XCTAssertEqual(request.header.uint(36, 4), UInt64(written.count / 8192))
                XCTAssertEqual(request.header.uint(28, 4), 2)
                written += request.data
                if request.header[1] & 0x80 == 0 { return [] }
                var status = PDU(0x21, flags: 0x80)
                status.header.put(writeTag, at: 16); status.header.put(2, at: 24); status.header.put(100, at: 32)
                return [status]
            }
            XCTAssertEqual(request.header[32], 0x91)
            var status = PDU(0x21, flags: 0x80)
            status.header.put(request.header.uint(16, 4), at: 16); status.header.put(3, at: 24); status.header.put(100, at: 32)
            return [status]
        }
        let session = try Session(configuration: Configuration(host: "mock"), transport: wire)
        try session.login(target: "iqn.test")
        let info = DiskInfo(vendor: "", model: "", blockCount: 2048, blockSize: 512)
        let data = Data((0..<32768).map { UInt8(truncatingIfNeeded: $0) })
        try session.write(lun: 1, lba: 8, data: data, info: info)
        XCTAssertEqual(Data(written), data)
        try session.synchronize(lun: 1)
        XCTAssertThrowsError(try session.write(lun: 1, lba: 2048, data: data, info: info))
    }
}
