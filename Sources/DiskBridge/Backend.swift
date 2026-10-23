import Foundation
import ISCSICore

public protocol BlockBackend: AnyObject {
    var size: UInt64 { get }
    var writable: Bool { get }
    func read(offset: UInt64, count: Int) throws -> Data
    func write(offset: UInt64, data: Data) throws
    func flush() throws
    func keepAlive() throws
}

/// Calls are serialized by the RPC server. An uncertain I/O result permanently
/// offlines this session; no automatic reconnect/replay of a write is attempted.
public final class ISCSIBackend: BlockBackend {
    private let session: Session
    private let lun: UInt16
    private let info: DiskInfo
    private var failed = false
    public let writable: Bool
    public var size: UInt64 { info.byteCount }
    public init(configuration: Configuration, target: String, lun: UInt16, writable: Bool) throws {
        session = try Session(configuration: configuration)
        try session.login(target: target)
        info = try session.inspect(lun: lun)
        self.lun = lun; self.writable = writable
    }
    private func perform<T>(_ body: () throws -> T) throws -> T {
        guard !failed else { throw ISCSIError.message("Сессия отключена после ошибки I/O. Извлеки диск перед переподключением.") }
        do { return try body() }
        catch { failed = true; session.close(); throw error }
    }
    public func read(offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else { throw ISCSIError.message("Чтение за границами диска") }
        if count == 0 { return Data() }
        return try perform {
            let block = UInt64(info.blockSize)
            let first = offset / block, last = (offset + UInt64(count) + block - 1) / block
            let data = try session.read(lun: lun, lba: first, blocks: UInt32(last - first), info: info)
            let start = Int(offset % block)
            return data.subdata(in: start..<(start + count))
        }
    }
    public func write(offset: UInt64, data: Data) throws {
        guard writable, offset <= size, UInt64(data.count) <= size - offset else { throw ISCSIError.message("Запись запрещена или за границами диска") }
        if data.isEmpty { return }
        try perform {
            let block = UInt64(info.blockSize), first = offset / UInt64(info.blockSize)
            if offset % block == 0 && UInt64(data.count) % block == 0 {
                try session.write(lun: lun, lba: first, data: data, info: info)
            } else {
                let last = (offset + UInt64(data.count) + block - 1) / block
                var aligned = try session.read(lun: lun, lba: first, blocks: UInt32(last - first), info: info)
                let start = Int(offset % block)
                aligned.replaceSubrange(start..<(start + data.count), with: data)
                try session.write(lun: lun, lba: first, data: aligned, info: info)
            }
        }
    }
    public func flush() throws { if writable { try perform { try session.synchronize(lun: lun) } } }
    public func keepAlive() throws { try perform { try session.keepAlive() } }
}
