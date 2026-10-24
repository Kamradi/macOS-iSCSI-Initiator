import AppLocalization
import Foundation
import CryptoKit

public struct Configuration: Sendable {
    public var host: String
    public var port: UInt16
    public var initiator: String
    public var username: String
    public var password: String
    public init(host: String, port: UInt16 = 3260, initiator: String = "iqn.2026-10.local.synologyinitiator:mac", username: String = "", password: String = "") {
        self.host = host; self.port = port; self.initiator = initiator
        self.username = username; self.password = password
    }
}
public struct Target: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public var portals: [String]
}
public struct DiskInfo: Sendable {
    public let vendor: String
    public let model: String
    public let blockCount: UInt64
    public let blockSize: UInt32
    public var byteCount: UInt64 { blockCount * UInt64(blockSize) }
}

/// One synchronous session, one outstanding command. Confine to a single worker.
public final class Session {
    public static func isReachable(host: String, port: UInt16) -> Bool {
        guard let transport = try? TCPTransport(host: host, port: port, timeoutSeconds: 2) else { return false }
        transport.close(); return true
    }
    private let transport: Transport
    private let configuration: Configuration
    private let isid: [UInt8]
    private var cmdSN: UInt32 = 1
    private var expStatSN: UInt32 = 0
    private var maxCmdSN: UInt32 = 1
    private var tag: UInt32 = 1
    private var loggedIn = false
    private var targetSegmentLength = 8192
    public convenience init(configuration: Configuration) throws {
        try self.init(configuration: configuration, transport: TCPTransport(host: configuration.host, port: configuration.port))
    }
    init(configuration: Configuration, transport: Transport) throws {
        guard !configuration.initiator.isEmpty, !configuration.initiator.contains("\0"),
              !configuration.username.contains("\0"), !configuration.host.isEmpty else {
            throw ISCSIError.message("Некорректные параметры подключения")
        }
        self.configuration = configuration; self.transport = transport
        // Random-format ISID (RFC 7143, type 10), unique per session.
        isid = [0x80] + (0..<5).map { _ in UInt8.random(in: 0...255) }
    }
    deinit { transport.close() }
    public func close() { loggedIn = false; transport.close() }
    private func nextTag() -> UInt32 { defer { tag &+= 1 }; return tag }
    private func base(_ opcode: UInt8, flags: UInt8, task: UInt32, data: [UInt8] = []) -> PDU {
        var p = PDU(opcode, flags: flags, data: data)
        p.header.put(UInt64(task), at: 16)
        p.header.put(UInt64(cmdSN), at: 24)
        p.header.put(UInt64(expStatSN), at: 28)
        return p
    }
    private func loginExchange(_ entries: [(String, String)], flags: UInt8, task: UInt32) throws -> PDU {
        var p = base(0x43, flags: flags, task: task, data: PDU.text(entries))
        p.header.replaceSubrange(8..<14, with: isid)
        try transport.send(p)
        let r = try transport.receive()
        guard r.opcode == 0x23, r.header.uint(16, 4) == UInt64(task), Array(r.header[8..<14]) == isid else {
            throw ISCSIError.message("Некорректный ответ входа iSCSI")
        }
        guard r.header[36] == 0 else { throw ISCSIError.message("NAS отклонил вход iSCSI: \(r.header[36]).\(r.header[37]). Проверь CHAP, IQN и права Target.") }
        guard r.header[3] == 0, r.header[1] & 0x40 == 0 else { throw ISCSIError.message("Неподдерживаемая версия или продолжение Login") }
        expStatSN = UInt32(truncatingIfNeeded: r.header.uint(24, 4)) &+ 1
        maxCmdSN = UInt32(truncatingIfNeeded: r.header.uint(32, 4))
        return r
    }
    public func login(target: String? = nil) throws {
        guard !loggedIn else { throw ISCSIError.message("Сессия уже открыта") }
        guard target?.contains("\0") != true else { throw ISCSIError.message("Некорректный IQN") }
        let task = nextTag()
        let chap = !configuration.username.isEmpty
        var entries = [("InitiatorName", configuration.initiator), ("SessionType", target == nil ? "Discovery" : "Normal"), ("AuthMethod", chap ? "CHAP" : "None")]
        if let target { entries.append(("TargetName", target)) }
        var response = try loginExchange(entries, flags: chap ? 0 : 0x81, task: task)
        var params = Dictionary(try response.pairs(), uniquingKeysWith: { _, new in new })
        if chap {
            guard params["AuthMethod"] == "CHAP", response.header[1] & 0x80 == 0 else { throw ISCSIError.message("NAS не выбрал CHAP") }
            response = try loginExchange([("CHAP_A", "5")], flags: 0, task: task)
            params = Dictionary(try response.pairs(), uniquingKeysWith: { _, new in new })
            guard params["CHAP_A"] == "5", let identifier = params["CHAP_I"].flatMap(UInt8.init), let challenge = params["CHAP_C"] else {
                throw ISCSIError.message("Некорректный запрос CHAP")
            }
            let digest = try Self.chapResponse(identifier: identifier, secret: configuration.password, challenge: challenge)
            response = try loginExchange([("CHAP_N", configuration.username), ("CHAP_R", digest)], flags: 0x81, task: task)
        } else if params["AuthMethod"] != "None" {
            throw ISCSIError.message("NAS требует другой метод авторизации")
        }
        guard response.header[1] & 0x8f == 0x81 else { throw ISCSIError.message("NAS не завершил этап авторизации") }
        let operational = [
            ("HeaderDigest", "None"), ("DataDigest", "None"),
            ("MaxRecvDataSegmentLength", "262144"), ("ErrorRecoveryLevel", "0"),
            ("MaxConnections", "1"), ("InitialR2T", "Yes"), ("ImmediateData", "No"),
            ("MaxBurstLength", "262144"), ("FirstBurstLength", "65536"),
            ("MaxOutstandingR2T", "1"), ("DataPDUInOrder", "Yes"), ("DataSequenceInOrder", "Yes")
        ]
        // RFC 7143: operational keys irrelevant to discovery must not be sent.
        let discoveryKeys: Set<String> = ["HeaderDigest", "DataDigest", "MaxRecvDataSegmentLength"]
        response = try loginExchange(target == nil ? operational.filter { discoveryKeys.contains($0.0) } : operational, flags: 0x87, task: task)
        params = Dictionary(try response.pairs(), uniquingKeysWith: { _, new in new })
        if let value = params["MaxRecvDataSegmentLength"] {
            guard let size = Int(value), size >= 512, size <= 0xffffff else { throw ISCSIError.message("Некорректный размер сегмента Target") }
            targetSegmentLength = min(size, 262144)
        }
        for key in ["HeaderDigest", "DataDigest"] {
            if let v = params[key], v != "None" { throw ISCSIError.message("NAS требует неподдерживаемый \(key): \(v)") }
        }
        guard response.header[1] & 0x8f == 0x87 else { throw ISCSIError.message("NAS не перешёл в рабочую фазу; продолжение согласования пока не поддерживается") }
        loggedIn = true
    }
    static func chapResponse(identifier: UInt8, secret: String, challenge: String) throws -> String {
        let bytes: [UInt8]
        if challenge.lowercased().hasPrefix("0x") {
            let hex = Array(challenge.dropFirst(2))
            guard !hex.isEmpty, hex.count % 2 == 0 else { throw ISCSIError.message("Некорректный CHAP challenge") }
            bytes = try stride(from: 0, to: hex.count, by: 2).map {
                guard let v = UInt8(String(hex[$0...($0 + 1)]), radix: 16) else { throw ISCSIError.message("Некорректный CHAP challenge") }; return v
            }
        } else if challenge.lowercased().hasPrefix("0b"), let d = Data(base64Encoded: String(challenge.dropFirst(2))) {
            bytes = Array(d)
        } else { throw ISCSIError.message("Неизвестная кодировка CHAP challenge") }
        guard bytes.count >= 16, bytes.count <= 1024 else { throw ISCSIError.message("Недопустимая длина CHAP challenge") }
        let hash = Insecure.MD5.hash(data: Data([identifier] + Array(secret.utf8) + bytes))
        return "0x" + hash.map { String(format: "%02x", $0) }.joined()
    }
    private func receive(nopTask: UInt32? = nil) throws -> PDU {
        for _ in 0..<64 {
            let p = try transport.receive()
            if p.opcode == 0x20 && p.header.uint(16, 4) != nopTask.map(UInt64.init) {
                let task = p.header.uint(16, 4), transfer = p.header.uint(20, 4)
                guard task == 0xffffffff else { throw ISCSIError.message("Неожиданный ответ NOP") }
                // Unsolicited NOP-In does not advance StatSN.
                if transfer != 0xffffffff {
                    var reply = base(0x40, flags: 0x80, task: 0xffffffff, data: p.data)
                    reply.header.replaceSubrange(8..<16, with: p.header[8..<16])
                    reply.header.put(transfer, at: 20)
                    try transport.send(reply)
                }
                continue
            }
            if p.opcode != 0x31 && (p.opcode != 0x25 || p.header[1] & 1 != 0) {
                guard UInt32(truncatingIfNeeded: p.header.uint(24, 4)) == expStatSN else { throw ISCSIError.message("Нарушена последовательность StatSN") }
                expStatSN &+= 1
            }
            maxCmdSN = UInt32(truncatingIfNeeded: p.header.uint(32, 4))
            if p.opcode == 0x3f { throw ISCSIError.message("NAS отклонил пакет iSCSI, причина \(p.header[2])") }
            return p
        }
        throw ISCSIError.message("Слишком много служебных пакетов")
    }
    private func requireSession() throws {
        guard loggedIn else { throw ISCSIError.message("Нет активной сессии") }
        // Serial-number arithmetic, valid for windows smaller than 2^31.
        guard Int32(bitPattern: maxCmdSN &- cmdSN) >= 0 else { throw ISCSIError.message("NAS временно закрыл окно команд; повтори подключение") }
    }
    public func discover() throws -> [Target] {
        try requireSession()
        let task = nextTag()
        var request = base(0x04, flags: 0x80, task: task, data: PDU.text([("SendTargets", "All")]))
        request.header.put(0xffffffff, at: 20)
        try transport.send(request); cmdSN &+= 1
        var text: [UInt8] = []
        for _ in 0..<256 {
            let p = try receive()
            guard p.opcode == 0x24, p.header.uint(16, 4) == UInt64(task) else { throw ISCSIError.message("Некорректный ответ обнаружения") }
            text += p.data
            guard text.count <= 4 * 1024 * 1024 else { throw ISCSIError.message("Слишком большой список Target") }
            if p.header[1] & 0x80 != 0 {
                var combined = PDU(0, data: text)
                combined.header = p.header
                var targets: [Target] = []
                for (key, value) in try combined.pairs() {
                    if key == "TargetName" { targets.append(Target(name: value, portals: [])) }
                    else if key == "TargetAddress", !targets.isEmpty { targets[targets.count - 1].portals.append(value) }
                }
                return targets
            }
            guard p.header[1] & 0x40 == 0 else { throw ISCSIError.message("Продолжение текстового ключа пока не поддерживается") }
            request = base(0x04, flags: 0x80, task: task)
            request.header.put(p.header.uint(20, 4), at: 20)
            try transport.send(request); cmdSN &+= 1
        }
        throw ISCSIError.message("Обнаружение не завершено")
    }
    /// Deliberately restrict commands to read-only operations at the protocol boundary.
    func command(lun: UInt16, cdb: [UInt8], expected: Int) throws -> [UInt8] {
        try requireSession()
        guard let opcode = cdb.first, [UInt8(0x12), 0x25, 0x9e, 0x88, 0xa0].contains(opcode), cdb.count <= 16,
              expected > 0, expected <= 1024 * 1024, lun <= 16383 else {
            throw ISCSIError.message("Команда или размер чтения не поддерживаются")
        }
        let task = nextTag()
        var p = base(0x01, flags: 0xc1, task: task)
        p.header[8] = UInt8(lun >> 8) | (lun > 255 ? 0x40 : 0)
        p.header[9] = UInt8(truncatingIfNeeded: lun)
        p.header.put(UInt64(expected), at: 20)
        p.header.replaceSubrange(32..<(32 + cdb.count), with: cdb)
        try transport.send(p); cmdSN &+= 1
        var output: [UInt8] = [], dataSN: UInt32 = 0
        for _ in 0..<4096 {
            let r = try receive()
            guard r.header.uint(16, 4) == UInt64(task) else { throw ISCSIError.message("Ответ на неизвестную команду") }
            if r.opcode == 0x25 {
                guard r.header.uint(36, 4) == UInt64(dataSN), r.header.uint(40, 4) == UInt64(output.count), output.count + r.data.count <= expected else {
                    throw ISCSIError.message("Нарушен порядок или размер данных")
                }
                dataSN &+= 1; output += r.data
                if r.header[1] & 1 != 0 {
                    guard r.header[1] & 0x80 != 0, r.header[3] == 0, r.header[1] & 4 == 0 else { throw ISCSIError.message("Ошибка SCSI Data-In: \(r.header[3])") }
                    return output
                }
            } else if r.opcode == 0x21 {
                guard r.header[2] == 0, r.header[3] == 0, r.header[1] & 4 == 0 else {
                    let sense = r.data.map { String(format: "%02x", $0) }.joined()
                    throw ISCSIError.message("Ошибка SCSI: status=\(r.header[3]), sense=\(sense)")
                }
                return output
            } else { throw ISCSIError.message("Неожиданный пакет при чтении: \(r.opcode)") }
        }
        throw ISCSIError.message("Превышен лимит пакетов команды")
    }
    public func listLUNs() throws -> [UInt16] {
        var cdb = [UInt8](repeating: 0, count: 12)
        cdb[0] = 0xa0; cdb.put(65536, at: 6)
        let bytes = try command(lun: 0, cdb: cdb, expected: 65536)
        guard bytes.count >= 8 else { throw ISCSIError.message("Неполный ответ REPORT LUNS") }
        let length = Int(bytes.uint(0, 4))
        guard length % 8 == 0, length <= bytes.count - 8 else { throw ISCSIError.message("Некорректный список LUN") }
        return try stride(from: 8, to: 8 + length, by: 8).map { offset in
            guard bytes[offset] & 0xc0 <= 0x40, bytes[(offset + 2)..<(offset + 8)].allSatisfy({ $0 == 0 }) else {
                throw ISCSIError.message("Расширенная адресация LUN пока не поддерживается")
            }
            return UInt16(bytes[offset] & 0x3f) << 8 | UInt16(bytes[offset + 1])
        }
    }
    /// Check target mapping before trying to expose a disk to macOS.
    public func deviceIdentifier(lun: UInt16) throws -> String? {
        var cdb: [UInt8] = [0x12, 1, 0x83, 0, 252, 0]
        if let bytes = try? command(lun: lun, cdb: cdb, expected: 252),
           let identifier = Self.logicalUnitIdentifier(bytes) { return identifier }
        cdb[2] = 0x80
        let bytes = try command(lun: lun, cdb: cdb, expected: 252)
        guard bytes.count >= 4, bytes[1] == 0x80 else { return nil }
        let length = Int(bytes.uint(2, 2))
        guard length > 0, length <= bytes.count - 4 else { return nil }
        return "serial:" + bytes[4..<(4 + length)].map { String(format: "%02x", $0) }.joined()
    }
    static func logicalUnitIdentifier(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 4, bytes[1] == 0x83 else { return nil }
        let length = Int(bytes.uint(2, 2))
        guard length <= bytes.count - 4 else { return nil }
        var offset = 4, identifiers: [String] = []
        while offset < 4 + length {
            guard offset + 4 <= 4 + length else { return nil }
            let size = Int(bytes[offset + 3]), association = (bytes[offset + 1] >> 4) & 3
            let type = bytes[offset + 1] & 15, code = bytes[offset] & 15
            guard offset + 4 + size <= 4 + length else { return nil }
            if association == 0, size > 0, [UInt8(1), 2, 3, 8].contains(type), [UInt8(1), 2, 3].contains(code) {
                let value = bytes[(offset + 4)..<(offset + 4 + size)].map { String(format: "%02x", $0) }.joined()
                identifiers.append("\(code):\(type):" + value)
            }
            offset += 4 + size
        }
        return identifiers.isEmpty ? nil : identifiers.sorted().joined(separator: ";")
    }
    public func requireAvailableLUN(_ lun: UInt16) throws {
        let available = try listLUNs()
        guard available.contains(lun) else {
            let numbers = available.map(String.init).joined(separator: ", ")
            throw ISCSIError.message("LUN \(lun) отсутствует у выбранного Target. Доступные LUN: \(numbers). Проверь Target IQN и номер LUN.")
        }
    }
    public func inspect(lun: UInt16) throws -> DiskInfo {
        let inquiry = try command(lun: lun, cdb: [0x12, 0, 0, 0, 96, 0], expected: 96)
        if let type = inquiry.first, type & 0xe0 != 0 || type & 0x1f == 0x1f {
            throw ISCSIError.message("iSCSI-сервер сообщает, что устройство LUN \(lun) недоступно. Проверь в панели управления сервером создание, состояние и привязку LUN к этому Target.")
        }
        guard inquiry.count >= 36, inquiry[0] & 0x1f == 0, inquiry[0] & 0xe0 == 0 else {
            let summary = inquiry.prefix(36).map { String(format: "%02x", $0) }.joined()
            throw ISCSIError.message("LUN \(lun): неожиданный INQUIRY (\(inquiry.count) байт, \(summary)). Проверь привязку LUN к Target.")
        }
        var cdb = [UInt8](repeating: 0, count: 16)
        cdb[0] = 0x9e; cdb[1] = 0x10; cdb.put(32, at: 10)
        let capacity = try command(lun: lun, cdb: cdb, expected: 32)
        guard capacity.count >= 12 else { throw ISCSIError.message("Неполный ответ READ CAPACITY") }
        let last = capacity.uint(0, 8), block = capacity.uint(8, 4)
        guard last < UInt64.max, block > 0, (last + 1) <= UInt64.max / block else { throw ISCSIError.message("Некорректная ёмкость диска") }
        func field(_ range: Range<Int>) -> String { String(decoding: inquiry[range], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        return DiskInfo(vendor: field(8..<16), model: field(16..<32), blockCount: last + 1, blockSize: UInt32(block))
    }
    public func read(lun: UInt16, lba: UInt64, blocks: UInt32, info: DiskInfo) throws -> Data {
        guard blocks > 0, lba < info.blockCount, UInt64(blocks) <= info.blockCount - lba,
              UInt64(blocks) * UInt64(info.blockSize) <= 1024 * 1024 else { throw ISCSIError.message("Чтение за границами LUN или больше 1 МиБ") }
        var cdb = [UInt8](repeating: 0, count: 16)
        cdb[0] = 0x88; cdb.put(lba, at: 2, count: 8); cdb.put(UInt64(blocks), at: 10)
        let size = Int(blocks) * Int(info.blockSize)
        let bytes = try command(lun: lun, cdb: cdb, expected: size)
        guard bytes.count == size else { throw ISCSIError.message("NAS вернул неполные данные блока") }
        return Data(bytes)
    }

    /// WRITE(16), solicited Data-Out only; caller must own the LUN exclusively.
    public func write(lun: UInt16, lba: UInt64, data: Data, info: DiskInfo) throws {
        try requireSession()
        let size = Int(info.blockSize)
        guard !data.isEmpty, data.count <= 1024 * 1024, data.count % size == 0,
              lun <= 16383, lba < info.blockCount, UInt64(data.count / size) <= info.blockCount - lba else {
            throw ISCSIError.message("Некорректные границы записи LUN")
        }
        let task = nextTag()
        var p = base(0x01, flags: 0xa1, task: task)
        p.header[8] = UInt8(lun >> 8) | (lun > 255 ? 0x40 : 0); p.header[9] = UInt8(truncatingIfNeeded: lun)
        p.header.put(UInt64(data.count), at: 20)
        p.header[32] = 0x8a
        p.header.put(lba, at: 34, count: 8)
        p.header.put(UInt64(data.count / size), at: 42)
        try transport.send(p); cmdSN &+= 1
        let bytes = Array(data)
        var transferred = 0
        var r2tSN: UInt64 = 0
        for _ in 0..<4096 {
            let r = try receive()
            guard r.header.uint(16, 4) == UInt64(task) else { throw ISCSIError.message("Неизвестный ответ записи") }
            if r.opcode == 0x21 {
                guard r.header[2] == 0, r.header[3] == 0, r.header[1] & 6 == 0, transferred == data.count else {
                    throw ISCSIError.message("Запись SCSI не завершена: status=\(r.header[3]). Автоматический повтор отключён.")
                }
                return
            }
            guard r.opcode == 0x31, r.header.uint(36, 4) == r2tSN,
                  r.header.uint(40, 4) == UInt64(transferred) else { throw ISCSIError.message("Некорректный R2T") }
            let length = Int(r.header.uint(44, 4))
            guard length > 0, length <= 262144, length <= data.count - transferred else { throw ISCSIError.message("R2T за границами записи") }
            r2tSN += 1
            var offset = transferred, dataSN: UInt64 = 0
            while offset < transferred + length {
                let count = min(targetSegmentLength, transferred + length - offset)
                var out = PDU(0x05, flags: offset + count == transferred + length ? 0x80 : 0, data: Array(bytes[offset..<(offset + count)]))
                out.header.replaceSubrange(8..<16, with: p.header[8..<16])
                out.header.put(UInt64(task), at: 16); out.header.put(r.header.uint(20, 4), at: 20)
                out.header.put(UInt64(expStatSN), at: 28); out.header.put(dataSN, at: 36)
                out.header.put(UInt64(offset), at: 40)
                try transport.send(out)
                offset += count; dataSN += 1
            }
            transferred += length
        }
        throw ISCSIError.message("Запись не завершилась")
    }

    public func synchronize(lun: UInt16) throws {
        try requireSession()
        let task = nextTag()
        var p = base(0x01, flags: 0x81, task: task)
        p.header[8] = UInt8(lun >> 8) | (lun > 255 ? 0x40 : 0); p.header[9] = UInt8(truncatingIfNeeded: lun)
        p.header[32] = 0x91 // SYNCHRONIZE CACHE(16), IMMED=0.
        try transport.send(p); cmdSN &+= 1
        let r = try receive()
        guard r.opcode == 0x21, r.header.uint(16, 4) == UInt64(task), r.header[2] == 0, r.header[3] == 0 else {
            throw ISCSIError.message("iSCSI-сервер не подтвердил сброс кэша на диск")
        }
    }
    public func keepAlive() throws {
        guard loggedIn else { throw ISCSIError.message("Нет активной сессии") }
        let task = nextTag()
        var p = base(0x40, flags: 0x80, task: task)
        p.header.put(0xffffffff, at: 20)
        try transport.send(p)
        let response = try receive(nopTask: task)
        guard response.opcode == 0x20, response.header.uint(16, 4) == UInt64(task) else { throw ISCSIError.message("Не получен ответ iSCSI keepalive") }
    }
}
