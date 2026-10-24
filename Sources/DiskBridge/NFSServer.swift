import Foundation
import Darwin
import ISCSICore

/// Private, loopback-only NFSv3 byte bridge. Not a general-purpose NFS server.
/// The export and file handles are random capabilities and are never advertised.
public final class NFSServer: @unchecked Sendable {
    public let port: UInt16
    public let exportPath: String
    private let listener: Int32
    private let backend: BlockBackend
    private let owner = getuid()
    private let group = getgid()
    private let rootHandle = Array(UUID().uuidString.utf8)
    private let fileHandle = Array(UUID().uuidString.utf8)
    private let verifier = (0..<8).map { _ in UInt8.random(in: 0...255) }
    private let lock = NSLock()
    private var modified = UInt32(Date().timeIntervalSince1970)
    private var errorReported = false
    public var onUnavailable: (@Sendable (String) -> Void)?
    public var onHealthy: (@Sendable () -> Void)?
    public var onError: (@Sendable (String) -> Void)?
    public init(backend: BlockBackend) throws {
        self.backend = backend; exportPath = "/" + UUID().uuidString
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        listener = fd
        guard fd >= 0 else { throw ISCSIError.message("Не удалось создать локальный мост") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0, listen(fd, 16) == 0 else { Darwin.close(fd); throw ISCSIError.message("Не удалось открыть локальный порт моста") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        port = UInt16(bigEndian: address.sin_port)
    }
    deinit { Darwin.close(listener) }
    public func run() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [self] in
            lock.withLock {
                do { try backend.keepAlive(); onHealthy?() } catch { report(error) }
            }
        }
        timer.resume()
        defer { timer.cancel() }
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
            DispatchQueue.global(qos: .userInitiated).async { [self] in serve(client) }
        }
    }
    private func report(_ error: Error) {
        if let temporary = error as? BackendUnavailable { onUnavailable?(temporary.reason); return }
        if !errorReported { errorReported = true; onError?(error.localizedDescription) }
    }
    private func read(_ fd: Int32, count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        try bytes.withUnsafeMutableBytes { buffer in
            var done = 0
            while done < count {
                let n = recv(fd, buffer.baseAddress!.advanced(by: done), count - done, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw RPCError.malformed }
                done += n
            }
        }
        return bytes
    }
    private func serve(_ fd: Int32) {
        defer { Darwin.close(fd) }
        do {
            while true {
                var record: [UInt8] = []
                for _ in 0..<64 {
                    var reader = XDRReader(try read(fd, count: 4))
                    let marker = try reader.word(), length = Int(marker & 0x7fffffff)
                    guard length > 0, record.count + length <= 2 * 1024 * 1024 else { throw RPCError.malformed }
                    record += try read(fd, count: length)
                    if marker & 0x80000000 != 0 { break }
                }
                let reply: [UInt8] = lock.withLock { handle(record) }
                var prefix = XDRWriter(); prefix.word(UInt32(reply.count) | 0x80000000)
                let bytes = prefix.bytes + reply
                try bytes.withUnsafeBytes { buffer in
                    var done = 0
                    while done < bytes.count {
                        let n = Darwin.send(fd, buffer.baseAddress!.advanced(by: done), bytes.count - done, 0)
                        if n < 0 && errno == EINTR { continue }
                        guard n > 0 else { throw RPCError.malformed }
                        done += n
                    }
                }
            }
        } catch { /* TCP EOF and malformed RPC close just this connection. */ }
    }
    private func attributes(_ file: Bool) -> [UInt8] {
        var w = XDRWriter()
        w.word(file ? 1 : 2); w.word(file ? (backend.writable ? 0o600 : 0o400) : 0o700)
        w.word(file ? 1 : 2); w.word(owner); w.word(group)
        w.long(file ? backend.size : 4096); w.long(file ? backend.size : 4096)
        w.word(0); w.word(0); w.long(0x53495343); w.long(file ? 2 : 1)
        for _ in 0..<3 { w.word(modified); w.word(0) }
        return w.bytes
    }
    private func post(_ file: Bool) -> [UInt8] { var w = XDRWriter(); w.bool(true); return w.bytes + attributes(file) }
    private func wcc(_ file: Bool) -> [UInt8] { var w = XDRWriter(); w.bool(false); return w.bytes + post(file) }
    private func isFile(_ reader: inout XDRReader) throws -> Bool {
        let h = try reader.opaque(max: 64)
        if h == rootHandle { return false }
        guard h == fileHandle else { throw RPCError.malformed }
        return true
    }
    func handle(_ message: [UInt8]) -> [UInt8] {
        var r = XDRReader(message), response = XDRWriter()
        do {
            let xid = try r.word()
            response.word(xid); response.word(1); response.word(0); response.word(0); response.word(0)
            guard try r.word() == 0, try r.word() == 2 else { response.word(4); return response.bytes }
            let program = try r.word(), version = try r.word(), procedure = try r.word()
            let flavor = try r.word(), credential = try r.opaque(max: 400)
            _ = try r.word(); _ = try r.opaque(max: 400)
            if flavor == 1 {
                var auth = XDRReader(credential)
                _ = try auth.word(); _ = try auth.string()
                let uid = try auth.word()
                guard uid == owner || uid == 0 else { response.word(0); response.word(13); return response.bytes }
            } else if flavor != 0 { response.word(0); response.word(13); return response.bytes }
            guard program == 100003 || program == 100005 else { response.word(1); return response.bytes }
            guard version == 3 else { response.word(2); response.word(3); response.word(3); return response.bytes }
            response.word(0)
            if procedure == 0 { return response.bytes }
            if program == 100005 {
                if procedure == 1 {
                    guard try r.string() == exportPath else { response.word(13); return response.bytes }
                    response.word(0); response.opaque(rootHandle); response.word(1); response.word(1)
                } else if procedure == 5 || procedure == 2 { response.bool(false) }
                return response.bytes
            }
            response.bytes += try nfs(procedure, &r)
            return response.bytes
        } catch {
            // Valid RPC header, but malformed argument: GARBAGE_ARGS.
            if response.bytes.count >= 20 { response.bytes = Array(response.bytes.prefix(20)); response.word(4) }
            return response.bytes
        }
    }
    private func nfs(_ procedure: UInt32, _ r: inout XDRReader) throws -> [UInt8] {
        let file = try isFile(&r)
        var w = XDRWriter()
        func failure(_ status: UInt32) -> [UInt8] {
            var result = XDRWriter(); result.word(status)
            switch procedure {
            case 2, 7, 21: result.bytes += wcc(file)
            case 3, 4, 5, 6, 16, 17, 18, 19, 20: result.bytes += post(file)
            default: break
            }
            return result.bytes
        }
        switch procedure {
        case 1:
            w.word(0); w.bytes += attributes(file)
        case 2:
            // Only metadata updates and a no-op size update are permitted.
            for _ in 0..<3 { if try r.word() != 0 { _ = try r.word() } }
            if try r.word() != 0, try r.long() != (file ? backend.size : 4096) { return failure(22) }
            for _ in 0..<2 { if try r.word() == 2 { _ = try r.word(); _ = try r.word() } }
            if try r.word() != 0 { _ = try r.word(); _ = try r.word() }
            w.word(0); w.bytes += wcc(file)
        case 3:
            let name = try r.string()
            guard !file else { return failure(20) }
            guard name == "lun.raw" || name == "." || name == ".." else { return failure(2) }
            let child = name == "lun.raw"
            w.word(0); w.opaque(child ? fileHandle : rootHandle); w.bytes += post(child); w.bytes += post(false)
        case 4:
            let access = try r.word()
            w.word(0); w.bytes += post(file); w.word(access & (backend.writable ? 0x3f : 0x23))
        case 6:
            let offset = try r.long(), count = Int(try r.word())
            guard file else { return failure(21) }
            guard count <= 1048576 else { return failure(22) }
            let actual = offset >= backend.size ? 0 : min(count, Int(min(backend.size - offset, UInt64(count))))
            do {
                let data = actual == 0 ? Data() : try backend.read(offset: offset, count: actual)
                guard data.count == actual else { return failure(5) }
                w.word(0); w.bytes += post(true); w.word(UInt32(data.count)); w.bool(offset + UInt64(actual) >= backend.size); w.opaque(Array(data))
            } catch { report(error); return failure(error is BackendUnavailable ? 10008 : 5) }
        case 7:
            let offset = try r.long(), count = try r.word(), stable = try r.word(), data = try r.opaque()
            guard file, backend.writable else { return failure(30) }
            guard count == data.count, stable <= 2, offset <= backend.size, UInt64(count) <= backend.size - offset else { return failure(22) }
            do {
                try backend.write(offset: offset, data: Data(data))
                // Every acknowledgement is FILE_SYNC, including UNSTABLE requests.
                try backend.flush(); modified = UInt32(Date().timeIntervalSince1970)
                w.word(0); w.bytes += wcc(true); w.word(count); w.word(2); w.bytes += verifier
            } catch { report(error); return failure(error is BackendUnavailable ? 10008 : 5) }
        case 16, 17:
            let cookie = try r.long(); _ = try r.fixed(8); _ = try r.word()
            if procedure == 17 { _ = try r.word() }
            guard !file else { return failure(20) }
            w.word(0); w.bytes += post(false); w.bytes += verifier
            if cookie == 0 {
                w.bool(true); w.long(2); w.string("lun.raw"); w.long(1)
                if procedure == 17 { w.bytes += post(true); w.bool(true); w.opaque(fileHandle) }
            }
            w.bool(false); w.bool(true)
        case 18:
            w.word(0); w.bytes += post(file)
            for value in [backend.size, UInt64(0), 0, 2, 0, 0] { w.long(value) }; w.word(0)
        case 19:
            w.word(0); w.bytes += post(file)
            for value in [UInt32(65536), 65536, 512, 65536, 65536, 512, 4096] { w.word(value) }
            w.long(backend.size); w.word(0); w.word(1); w.word(0x18)
        case 20:
            w.word(0); w.bytes += post(file)
            w.word(1); w.word(255); w.bool(true); w.bool(true); w.bool(false); w.bool(true)
        case 21:
            _ = try r.long(); _ = try r.word()
            do { try backend.flush(); w.word(0); w.bytes += wcc(file); w.bytes += verifier }
            catch { report(error); return failure(error is BackendUnavailable ? 10008 : 5) }
        default:
            return failure(10004)
        }
        return w.bytes
    }
}
