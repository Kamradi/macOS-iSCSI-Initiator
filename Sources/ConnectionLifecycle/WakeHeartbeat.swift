import Foundation

public enum WakeHeartbeat {
    /// Evidence must be from this helper, after this wake, and still recent.
    public static func isFresh(pid: Int32, expectedPID: Int32, lastSuccess: TimeInterval, wake: Date, now: Date) -> Bool {
        pid == expectedPID && lastSuccess.isFinite && lastSuccess >= wake.timeIntervalSince1970 &&
            lastSuccess <= now.timeIntervalSince1970 && now.timeIntervalSince1970 - lastSuccess <= 20
    }
}
