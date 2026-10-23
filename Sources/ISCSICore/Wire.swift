import AppLocalization
import Foundation
import Darwin

public enum ISCSIError: Error, LocalizedError, LocalizableError {
    case message(LocalizedText)
    public var localizedText: LocalizedText { switch self { case .message(let text): return text } }
    public var errorDescription: String? { localizedText.render() }
}

extension Array where Element == UInt8 {
    func uint(_ offset: Int, _ count: Int) -> UInt64 {
        self[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    mutating func put(_ value: UInt64, at offset: Int, count: Int = 4) {
        for i in 0..<count { self[offset + i] = UInt8(truncatingIfNeeded: value >> ((count - 1 - i) * 8)) }
    }
}

struct PDU {
    var header = [UInt8](repeating: 0, count: 48)
    var data: [UInt8] = []
    init(_ opcode: UInt8, flags: UInt8 = 0, data: [UInt8] = []) {
        header[0] = opcode; header[1] = flags; self.data = data
    }
    var opcode: UInt8 { header[0] & 0x3f }
    func encoded() throws -> [UInt8] {
        guard data.count <= 0xffffff else { throw ISCSIError.message("Слишком большой пакет") }
        var h = header
        h.put(UInt64(data.count), at: 5, count: 3)
        return h + data + [UInt8](repeating: 0, count: (4 - data.count % 4) % 4)
    }
    static func text(_ entries: [(String, String)]) -> [UInt8] {
        entries.flatMap { Array(($0.0 + "=" + $0.1).utf8) + [0] }
    }
    func pairs() throws -> [(String, String)] {
        guard data.isEmpty || data.last == 0, let text = String(bytes: data, encoding: .utf8) else {
            throw ISCSIError.message("Повреждённый текст iSCSI")
        }
        return try text.split(separator: "\0").map {
            let p = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard p.count == 2 else { throw ISCSIError.message("Некорректный параметр iSCSI") }
            return (String(p[0]), String(p[1]))
        }
    }
}

protocol Transport: AnyObject {
    func send(_ pdu: PDU) throws
    func receive() throws -> PDU
    func close()
}

final class TCPTransport: Transport {
    private var fd: Int32 = -1
    init(host: String, port: UInt16, timeoutSeconds: Int = 10) throws {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP
        var addresses: UnsafeMutablePointer<addrinfo>?
        let result = getaddrinfo(host, String(port), &hints, &addresses)
        guard result == 0, let first = addresses else { throw ISCSIError.message("Не удалось найти адрес NAS: \(String(cString: gai_strerror(result)))") }
        defer { freeaddrinfo(first) }
        var entry: UnsafeMutablePointer<addrinfo>? = first
        while let current = entry {
            let a = current.pointee
            let candidate = socket(a.ai_family, a.ai_socktype, a.ai_protocol)
            if candidate >= 0 {
                var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
                var one: Int32 = 1
                setsockopt(candidate, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
                setsockopt(candidate, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
                setsockopt(candidate, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
                let oldFlags = fcntl(candidate, F_GETFL)
                _ = fcntl(candidate, F_SETFL, oldFlags | O_NONBLOCK)
                let connected = Darwin.connect(candidate, a.ai_addr, a.ai_addrlen)
                var ready = connected == 0
                if !ready && errno == EINPROGRESS {
                    var pollFD = pollfd(fd: candidate, events: Int16(POLLOUT), revents: 0)
                    if poll(&pollFD, 1, Int32(timeoutSeconds * 1000)) > 0 {
                        var error: Int32 = 0
                        var size = socklen_t(MemoryLayout.size(ofValue: error))
                        ready = getsockopt(candidate, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0
                    }
                }
                _ = fcntl(candidate, F_SETFL, oldFlags)
                if ready { fd = candidate; break }
                Darwin.close(candidate)
            }
            entry = a.ai_next
        }
        guard fd >= 0 else { throw ISCSIError.message("Нет подключения к \(host):\(port). Проверь адрес, сеть и службу iSCSI.") }
    }
    deinit { close() }
    func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
    func send(_ pdu: PDU) throws {
        if ProcessInfo.processInfo.environment["ISCSI_TRACE"] == "1" {
            FileHandle.standardError.write(Data(("TX " + pdu.header.map { String(format: "%02x", $0) }.joined() + " data=\(pdu.data.count)\n").utf8))
        }
        let bytes = try pdu.encoded()
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ISCSIError.message("Ошибка передачи или тайм-аут сети") }
                offset += n
            }
        }
    }
    private func read(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let n = recv(fd, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ISCSIError.message("Соединение прервано или истёк тайм-аут") }
                offset += n
            }
        }
        return bytes
    }
    func receive() throws -> PDU {
        let header = try read(48)
        guard header[4] == 0 else { throw ISCSIError.message("Дополнительные заголовки AHS пока не поддерживаются") }
        let length = Int(header.uint(5, 3))
        guard length <= 262144 else { throw ISCSIError.message("NAS превысил согласованный размер пакета") }
        var pdu = PDU(header[0]); pdu.header = header
        pdu.data = try read(length)
        if ProcessInfo.processInfo.environment["ISCSI_TRACE"] == "1" {
            FileHandle.standardError.write(Data(("RX " + header.map { String(format: "%02x", $0) }.joined() + " data=\(length)\n").utf8))
        }
        _ = try read((4 - length % 4) % 4)
        return pdu
    }
}
