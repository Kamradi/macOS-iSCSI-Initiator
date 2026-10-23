import Foundation
import ISCSICore
import Darwin
import ConnectionLifecycle

struct MountedDisk: Codable, Sendable {
    let device: String
    let volume: String?
    let mountDirectory: String
    let runtimeDirectory: String
    let helperPID: Int32
    let byteCount: UInt64
}

/// All methods run on one worker at a time, controlled by Model.busy.
actor DiskConnection {
    private var helper: Process?
    private var current: MountedDisk?
    private let root: URL
    init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SynologyInitiator", isDirectory: true)
    }
    private var record: URL { root.appendingPathComponent("active.json") }
    private func run(_ executable: String, _ args: [String], timeout: TimeInterval = 90) throws -> Data {
        try CommandRunner.run(executable, args, timeout: timeout)
    }
    private func images(timeout: TimeInterval = 10) throws -> [[String: Any]] {
        let data = try run("/usr/bin/hdiutil", ["info", "-plist"], timeout: timeout)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return plist?["images"] as? [[String: Any]] ?? []
    }
    func recover() throws -> MountedDisk? {
        guard FileManager.default.fileExists(atPath: record.path) else { return current }
        let saved = try JSONDecoder().decode(MountedDisk.self, from: Data(contentsOf: record))
        guard saved.runtimeDirectory.hasPrefix(root.path + "/"), saved.mountDirectory == saved.runtimeDirectory + "/mount" else { throw ISCSIError.message("Некорректная запись подключения") }
        if let image = try images().first(where: { $0["image-path"] as? String == saved.mountDirectory + "/lun.raw" }) {
            let entries = image["system-entities"] as? [[String: Any]] ?? []
            let device = entries.compactMap { $0["dev-entry"] as? String }.first { $0.range(of: "^/dev/disk[0-9]+$", options: .regularExpression) != nil } ?? saved.device
            let recovered = MountedDisk(device: device, volume: entries.compactMap { $0["mount-point"] as? String }.first, mountDirectory: saved.mountDirectory, runtimeDirectory: saved.runtimeDirectory, helperPID: saved.helperPID, byteCount: saved.byteCount)
            current = recovered; return recovered
        }
        // Keep even an incomplete mount recoverable; do not start a second one.
        current = saved
        return saved
    }
    func connect(configuration: Configuration, target: String, lun: UInt16) throws -> MountedDisk {
        guard current == nil, !FileManager.default.fileExists(atPath: record.path) else { throw ISCSIError.message("Предыдущее подключение ещё не извлечено") }
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("iscsi-bridge"), FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ISCSIError.message("Не найден iscsi-bridge. Запусти собранное приложение из dist.")
        }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let mount = directory.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let state = directory.appendingPathComponent("ready.json"), log = directory.appendingPathComponent("bridge.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let logHandle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = executable
        process.arguments = [configuration.host, target, String(lun), state.path, "--read-write"]
        var env = ProcessInfo.processInfo.environment
        env["ISCSI_USERNAME"] = configuration.username; env["ISCSI_PASSWORD"] = configuration.password
        env["ISCSI_PORT"] = String(configuration.port); env["ISCSI_TRACE"] = nil
        process.environment = env; process.standardOutput = logHandle; process.standardError = logHandle
        try process.run(); helper = process
        var mounted = false
        var attached = false
        do {
            for _ in 0..<400 {
                if FileManager.default.fileExists(atPath: state.path) || !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard process.isRunning, let ready = try? JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any],
                  let port = ready["port"] as? Int, let export = ready["export"] as? String, let size = ready["size"] as? UInt64 else {
                throw ISCSIError.message((try? String(contentsOf: log, encoding: .utf8)) ?? "Мост не запустился")
            }
            _ = try run("/sbin/mount_nfs", ["-o", "vers=3,tcp,port=\(port),mountport=\(port),noresvport,nolocks,soft,timeo=20,retrans=2,noac,nobrowse,rsize=65536,wsize=65536", "127.0.0.1:" + export, mount.path])
            mounted = true
            let pending = MountedDisk(device: "", volume: nil, mountDirectory: mount.path, runtimeDirectory: directory.path, helperPID: process.processIdentifier, byteCount: size)
            current = pending
            try JSONEncoder().encode(pending).write(to: record, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
            let result = try run("/usr/bin/hdiutil", ["attach", "-imagekey", "diskimage-class=CRawDiskImage", "-plist", mount.appendingPathComponent("lun.raw").path])
            attached = true
            guard let plist = try PropertyListSerialization.propertyList(from: result, format: nil) as? [String: Any],
                  let entities = plist["system-entities"] as? [[String: Any]],
                  let entry = entities.first?["dev-entry"] as? String, entry.hasPrefix("/dev/disk") else {
                throw ISCSIError.message("macOS не вернула устройство подключённого диска")
            }
            let infoData = try run("/usr/sbin/diskutil", ["info", "-plist", entry])
            let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
            guard let whole = info?["ParentWholeDisk"] as? String ?? info?["DeviceIdentifier"] as? String,
                  whole.range(of: "^disk[0-9]+$", options: .regularExpression) != nil else { throw ISCSIError.message("Не определён физический виртуальный диск") }
            let device = "/dev/" + whole
            let volume = entities.compactMap { $0["mount-point"] as? String }.first
            let disk = MountedDisk(device: device, volume: volume, mountDirectory: mount.path, runtimeDirectory: directory.path, helperPID: process.processIdentifier, byteCount: size)
            current = disk
            try JSONEncoder().encode(disk).write(to: record, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
            return disk
        } catch {
            if !mounted && !attached {
                if process.isRunning { process.terminate() }
                helper = nil
            }
            throw error
        }
    }
    func disconnect(timeout: TimeInterval = 60) throws {
        guard let disk = current else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func remaining() -> TimeInterval { max(0, deadline - ProcessInfo.processInfo.systemUptime) }
        let image = try images(timeout: min(5, remaining())).first { $0["image-path"] as? String == disk.mountDirectory + "/lun.raw" }
        if let image {
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            guard let device = entities.compactMap({ $0["dev-entry"] as? String }).first(where: { $0.range(of: "^/dev/disk[0-9]+$", options: .regularExpression) != nil }) else { throw ISCSIError.message("Не определён диск для извлечения") }
            _ = try run("/usr/bin/hdiutil", ["detach", device], timeout: remaining())
        }
        _ = try run("/sbin/umount", [disk.mountDirectory], timeout: remaining())
        if let helper, helper.isRunning { helper.terminate() }
        // A recovered helper is left alone rather than killing a potentially reused PID.
        helper = nil; current = nil
        if FileManager.default.fileExists(atPath: record.path) { try FileManager.default.removeItem(at: record) }
    }
    func saveProfile(_ profile: ConnectionProfile) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("profile.json")
        try JSONEncoder().encode(profile).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func loadProfile() throws -> ConnectionProfile? {
        let url = root.appendingPathComponent("profile.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ConnectionProfile.self, from: Data(contentsOf: url))
    }
    enum Health: Sendable { case healthy, failed, ejected }
    func health() throws -> Health {
        guard let disk = current else { return .ejected }
        let log = URL(fileURLWithPath: disk.runtimeDirectory).appendingPathComponent("bridge.log")
        if let text = try? String(contentsOf: log, encoding: .utf8), text.contains("I/O:") { return .failed }
        if let helper, !helper.isRunning { return .failed }
        return try images().contains(where: { $0["image-path"] as? String == disk.mountDirectory + "/lun.raw" }) ? .healthy : .ejected
    }
}
