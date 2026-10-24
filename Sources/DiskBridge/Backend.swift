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

/// Temporary failure before any uncertain write. NFS may retry the request.
public struct BackendUnavailable: Error {
    public let reason: String
    init(_ error: Error) { reason = error.localizedDescription }
}

protocol BlockConnection: AnyObject {
    func inspect(lun: UInt16) throws -> DiskInfo
    func deviceIdentifier(lun: UInt16) throws -> String?
    func read(lun: UInt16, lba: UInt64, blocks: UInt32, info: DiskInfo) throws -> Data
    func write(lun: UInt16, lba: UInt64, data: Data, info: DiskInfo) throws
    func synchronize(lun: UInt16) throws
    func keepAlive() throws
    func close()
}
extension Session: BlockConnection {}

/// Serialized by the RPC server. Only reads and idle transport loss may recover.
/// A possibly transmitted write or failed flush permanently offlines the backend.
public final class ISCSIBackend: BlockBackend {
    private var session: (any BlockConnection)?
    private let factory: () throws -> any BlockConnection
    private let lun: UInt16
    private let info: DiskInfo
    private let identity: String?
    private var failed = false
    private var pendingWrite = false
    public let writable: Bool
    public var size: UInt64 { info.byteCount }
    public var canReconnect: Bool { identity != nil }
    public convenience init(configuration: Configuration, target: String, lun: UInt16, writable: Bool) throws {
        try self.init(lun: lun, writable: writable, factory: {
            let session = try Session(configuration: configuration)
            do { try session.login(target: target); return session }
            catch { session.close(); throw error }
        })
    }
    init(lun: UInt16, writable: Bool, factory: @escaping () throws -> any BlockConnection) throws {
        let initial = try factory()
        do {
            info = try initial.inspect(lun: lun)
            identity = try? initial.deviceIdentifier(lun: lun)
            try initial.keepAlive()
        } catch { initial.close(); throw error }
        self.session = initial; self.factory = factory; self.lun = lun; self.writable = writable
    }
    private func terminal(_ error: Error) -> Error {
        failed = true; session?.close(); session = nil
        return error
    }
    private func unavailable(_ error: Error) -> Error {
        session?.close(); session = nil
        if pendingWrite || identity == nil || (error as? ISCSIError)?.isTransportFailure != true { return terminal(error) }
        return BackendUnavailable(error)
    }
    private func connected() throws -> any BlockConnection {
        guard !failed else { throw ISCSIError.message("Сессия отключена после ошибки I/O. Извлеки диск перед переподключением.") }
        if let session { return session }
        guard !pendingWrite, let identity else { throw terminal(ISCSIError.message("Не подтверждена возможность безопасного восстановления LUN.")) }
        let replacement: any BlockConnection
        do { replacement = try factory() }
        catch {
            if (error as? ISCSIError)?.isTransportFailure != true { throw terminal(error) }
            throw BackendUnavailable(error)
        }
        do {
            let nextInfo = try replacement.inspect(lun: lun)
            let nextIdentity = try replacement.deviceIdentifier(lun: lun)
            guard nextIdentity == identity, nextInfo.blockCount == info.blockCount, nextInfo.blockSize == info.blockSize,
                  nextInfo.vendor == info.vendor, nextInfo.model == info.model else {
                replacement.close()
                throw terminal(ISCSIError.message("Идентификатор или размер LUN изменился. Подключение остановлено."))
            }
            session = replacement
            return replacement
        } catch {
            replacement.close()
            if failed { throw error }
            if (error as? ISCSIError)?.isTransportFailure != true { throw terminal(error) }
            throw BackendUnavailable(error)
        }
    }
    public func read(offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else { throw ISCSIError.message("Чтение за границами диска") }
        if count == 0 { return Data() }
        let session = try connected()
        let block = UInt64(info.blockSize)
        let first = offset / block, last = (offset + UInt64(count) + block - 1) / block
        do {
            let data = try session.read(lun: lun, lba: first, blocks: UInt32(last - first), info: info)
            let start = Int(offset % block)
            return data.subdata(in: start..<(start + count))
        } catch { throw unavailable(error) }
    }
    public func write(offset: UInt64, data: Data) throws {
        guard writable, offset <= size, UInt64(data.count) <= size - offset else { throw ISCSIError.message("Запись запрещена или за границами диска") }
        if data.isEmpty { return }
        _ = try connected()
        let block = UInt64(info.blockSize), first = offset / block
        let aligned: Data
        if offset % block == 0 && UInt64(data.count) % block == 0 { aligned = data }
        else {
            let last = (offset + UInt64(data.count) + block - 1) / block
            var bytes = try read(offset: first * block, count: Int((last - first) * block))
            let start = Int(offset % block)
            bytes.replaceSubrange(start..<(start + data.count), with: data); aligned = bytes
        }
        let session = try connected()
        pendingWrite = true
        do { try session.write(lun: lun, lba: first, data: aligned, info: info) }
        catch { throw terminal(error) }
    }
    public func flush() throws {
        guard !failed else { throw ISCSIError.message("Сессия отключена после ошибки I/O. Извлеки диск перед переподключением.") }
        guard writable else { return }
        // Once a FILE_SYNC acknowledgement was sent, no dirty data remains in
        // this bridge. An offline no-op COMMIT cannot lose previously acked data.
        guard let session else {
            if pendingWrite { throw terminal(ISCSIError.message("Не подтверждена возможность безопасного восстановления LUN.")) }
            return
        }
        do { try session.synchronize(lun: lun); pendingWrite = false }
        catch { throw pendingWrite ? terminal(error) : unavailable(error) }
    }
    public func keepAlive() throws {
        let session = try connected()
        do { try session.keepAlive() }
        catch { throw unavailable(error) }
    }
}
