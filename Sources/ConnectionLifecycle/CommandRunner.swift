import AppLocalization
import Foundation
import Darwin

public enum CommandError: Error, LocalizedError, LocalizableError {
    case failed(String), timedOut(String)
    public var errorDescription: String? { localizedText.render() }
    public var localizedText: LocalizedText {
        switch self {
        case .failed(let message): return .literal(message)
        case .timedOut(let name): return "Операция \(name) не завершилась вовремя. Принудительное извлечение не выполнялось."
        }
    }
}
public enum CommandRunner {
    /// Files prevent inherited stdout/stderr handles in DiskImages daemons from
    /// holding a pipe open. Every operation has a monotonic wall-clock deadline.
    public static func run(_ executable: String, _ args: [String], timeout: TimeInterval = 90) throws -> Data {
        guard timeout > 0 else { throw CommandError.timedOut(URL(fileURLWithPath: executable).lastPathComponent) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout"), errorURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outputURL), errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close() }
        let process = Process(), finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
        process.standardOutput = output; process.standardError = errors
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw CommandError.timedOut(URL(fileURLWithPath: executable).lastPathComponent)
        }
        let data = try Data(contentsOf: outputURL), error = try Data(contentsOf: errorURL)
        guard process.terminationStatus == 0 else {
            throw CommandError.failed(String(decoding: error.isEmpty ? data : error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }
}
