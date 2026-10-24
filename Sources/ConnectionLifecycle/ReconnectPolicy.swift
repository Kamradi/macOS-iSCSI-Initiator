import AppLocalization
import Foundation

/// Reconnect only after a clean detach. A transport fault never authorizes
/// replaying I/O or mounting another session over the outstanding attachment.
public struct ReconnectPolicy: Sendable {
    public var enabled = false
    public private(set) var sleeping = false
    public private(set) var needsAttention = false
    public private(set) var recoveryAfterSleep = false
    public private(set) var failures = 0
    public private(set) var retryAt = Date.distantPast
    public init() {}
    public func shouldConnect(now: Date, mounted: Bool, busy: Bool) -> Bool {
        enabled && !sleeping && !needsAttention && !mounted && !busy && now >= retryAt
    }
    public mutating func willSleep(recoverMountedDisk: Bool = false) {
        sleeping = true
        if enabled && recoverMountedDisk { recoveryAfterSleep = true }
    }
    public func shouldRecoverAfterSleep(now: Date, mounted: Bool, busy: Bool) -> Bool {
        enabled && recoveryAfterSleep && !sleeping && (mounted || needsAttention) && !busy && now >= retryAt
    }
    public mutating func woke(now: Date) { sleeping = false; retryAt = now.addingTimeInterval(3) }
    public mutating func connected() { failures = 0; retryAt = .distantPast }
    public mutating func failed(now: Date) {
        failures = min(failures + 1, 5)
        retryAt = now.addingTimeInterval(min(120, 15 * pow(2, Double(failures - 1))))
    }
    public mutating func unsafeDisconnect() { needsAttention = true }
    public mutating func cleanDetach() { needsAttention = false; recoveryAfterSleep = false; failures = 0; retryAt = .distantPast }
    public mutating func retryNow() { retryAt = .distantPast }
    public mutating func manualStop() { enabled = false; recoveryAfterSleep = false; retryAt = .distantFuture }
}

public struct ConnectionProfile: Codable, Sendable {
    public var host: String
    public var port: UInt16
    public var target: String
    public var lun: UInt16
    public var chap: Bool
    public var username: String
    public var automatic: Bool
    public var needsAttention: Bool
    public init(host: String, port: UInt16, target: String, lun: UInt16, chap: Bool, username: String, automatic: Bool, needsAttention: Bool) {
        self.host = host; self.port = port; self.target = target; self.lun = lun
        self.chap = chap; self.username = username; self.automatic = automatic; self.needsAttention = needsAttention
    }
}
