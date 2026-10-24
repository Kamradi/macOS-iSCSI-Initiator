import Foundation
import ISCSICore
import DiskBridge

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 4 else {
    print("iscsi-bridge HOST TARGET LUN STATE.json [--read-write]")
    exit(2)
}
do {
    guard let lun = UInt16(args[2]), lun <= 16383 else { throw ISCSIError.message("Некорректный LUN") }
    let env = ProcessInfo.processInfo.environment
    let backend = try ISCSIBackend(configuration: Configuration(host: args[0], port: UInt16(env["ISCSI_PORT"] ?? "3260") ?? 3260, username: env["ISCSI_USERNAME"] ?? "", password: env["ISCSI_PASSWORD"] ?? ""), target: args[1], lun: lun, writable: args.contains("--read-write"))
    let server = try NFSServer(backend: backend)
    server.onError = { message in FileHandle.standardError.write(Data(("I/O: " + message + "\n").utf8)) }
    let state: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "port": server.port, "export": server.exportPath, "size": backend.size, "writable": backend.writable]
    let url = URL(fileURLWithPath: args[3])
    try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let healthURL = url.deletingLastPathComponent().appendingPathComponent("health.json")
    server.onHealthy = {
        let health: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "lastSuccess": Date().timeIntervalSince1970]
        do {
            try JSONSerialization.data(withJSONObject: health).write(to: healthURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: healthURL.path)
        } catch { /* Missing heartbeat must never be interpreted as success. */ }
    }
    print("Bridge ready: 127.0.0.1:\(server.port), \(backend.size) bytes, writable=\(backend.writable)")
    fflush(stdout)
    server.run()
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
}
