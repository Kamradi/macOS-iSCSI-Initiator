import AppLocalization
import Foundation
import ISCSICore
import CryptoKit

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    print(LocalizedText("Использование: iscsi discover HOST [PORT] | iscsi luns HOST TARGET | iscsi inspect HOST TARGET [LUN] [PORT] | iscsi readcheck HOST TARGET LUN | iscsi identity HOST TARGET [LUN] [PORT]\nCHAP: ISCSI_USERNAME и ISCSI_PASSWORD в окружении. Только чтение.").render())
    exit(2)
}
do {
    let action = args[0]
    guard ["discover", "inspect", "luns", "readcheck", "writecheck", "identity"].contains(action) else { throw ISCSIError.message("Неизвестная команда") }
    if action != "discover", args.count < 3 { throw ISCSIError.message("Не указан Target IQN") }
    let portString = action == "discover" ? (args.count > 2 ? args[2] : "3260") : (args.count > 4 ? args[4] : "3260")
    guard let port = UInt16(portString), port > 0 else { throw ISCSIError.message("Некорректный порт") }
    let env = ProcessInfo.processInfo.environment
    let config = Configuration(host: args[1], port: port, username: env["ISCSI_USERNAME"] ?? "", password: env["ISCSI_PASSWORD"] ?? "")
    let session = try Session(configuration: config)
    defer { session.close() }
    if action == "discover" {
        try session.login()
        for target in try session.discover() { print("\(target.name)\n  \(target.portals.joined(separator: ", "))") }
    } else if action == "identity" {
        try session.login(target: args[2])
        print(try session.deviceIdentifier(lun: UInt16(args.count > 3 ? args[3] : "0") ?? 0) ?? "unavailable")
    } else if action == "luns" {
        try session.login(target: args[2])
        print(LocalizedText("Доступные LUN: \(try session.listLUNs().map(String.init).joined(separator: ", "))").render())
    } else {
        guard let lun = UInt16(args.count > 3 ? args[3] : "0") else { throw ISCSIError.message("Некорректный LUN") }
        try session.login(target: args[2])
        let info = try session.inspect(lun: lun)
        if action == "writecheck" {
            guard env["ISCSI_ALLOW_WRITE_TEST"] == "1" else { throw ISCSIError.message("Для проверки записи нужно ISCSI_ALLOW_WRITE_TEST=1") }
            let lba = info.blockCount - 8192
            let original = try session.read(lun: lun, lba: lba, blocks: 8, info: info)
            let pattern = Data((0..<original.count).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            try session.write(lun: lun, lba: lba, data: pattern, info: info)
            try session.synchronize(lun: lun)
            let check = try session.read(lun: lun, lba: lba, blocks: 8, info: info)
            try session.write(lun: lun, lba: lba, data: original, info: info)
            try session.synchronize(lun: lun)
            guard check == pattern else { throw ISCSIError.message("Запись не совпала при чтении") }
            print(LocalizedText("Запись, flush и чтение 4096 байт совпали. Исходные блоки восстановлены.").render())
            exit(0)
        }
        if action == "readcheck" {
            let blocks = UInt32(min(info.blockCount, UInt64(1024 * 1024) / UInt64(info.blockSize)))
            let start = try session.read(lun: lun, lba: 0, blocks: blocks, info: info)
            let end = try session.read(lun: lun, lba: info.blockCount - 1, blocks: 1, info: info)
            let repeatStart = try session.read(lun: lun, lba: 0, blocks: blocks, info: info)
            guard start == repeatStart else { throw ISCSIError.message("Данные при повторном чтении изменились") }
            let digest = SHA256.hash(data: start).map { String(format: "%02x", $0) }.joined()
            print(LocalizedText("Чтение начала LUN: \(start.count) байт; повтор совпал.\nЧтение последнего блока: \(end.count) байт.\nSHA-256 начала: \(digest)\nЗапись не выполнялась.").render())
            exit(0)
        }
        let first = try session.read(lun: lun, lba: 0, blocks: 1, info: info)
        print(LocalizedText("\(info.vendor) \(info.model)\nLUN \(lun): \(info.byteCount) байт, \(info.blockCount) блоков × \(info.blockSize)\nПервый блок прочитан: \(first.count) байт. Запись не выполнялась.").render())
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
