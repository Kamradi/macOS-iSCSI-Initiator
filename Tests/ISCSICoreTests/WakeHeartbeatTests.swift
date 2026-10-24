import XCTest
import ConnectionLifecycle

final class WakeHeartbeatTests: XCTestCase {
    func testRequiresFreshPostWakeSuccessFromSameHelper() {
        let wake = Date(timeIntervalSince1970: 1000), now = Date(timeIntervalSince1970: 1010)
        XCTAssertTrue(WakeHeartbeat.isFresh(pid: 42, expectedPID: 42, lastSuccess: 1005, wake: wake, now: now))
        for value in [999.0, 1011.0, Double.nan, Double.infinity] {
            XCTAssertFalse(WakeHeartbeat.isFresh(pid: 42, expectedPID: 42, lastSuccess: value, wake: wake, now: now))
        }
        XCTAssertFalse(WakeHeartbeat.isFresh(pid: 41, expectedPID: 42, lastSuccess: 1005, wake: wake, now: now))
        XCTAssertFalse(WakeHeartbeat.isFresh(pid: 42, expectedPID: 42, lastSuccess: 1005, wake: wake, now: Date(timeIntervalSince1970: 1030)))
    }
    func testHealthyRetainedSessionCancelsRecoveryWithoutNewMount() {
        var p = ReconnectPolicy(); p.enabled = true
        p.willSleep(recoverMountedDisk: true); p.unsafeDisconnect(); p.woke(now: .distantPast)
        p.retainedAfterSleep()
        XCTAssertFalse(p.needsAttention)
        XCTAssertFalse(p.shouldRecoverAfterSleep(now: Date(), mounted: true, busy: false))
        XCTAssertFalse(p.shouldConnect(now: Date(), mounted: true, busy: false))
    }
    func testCannotClearUnrelatedFaultOrSleepingSession() {
        var p = ReconnectPolicy(); p.enabled = true; p.unsafeDisconnect(); p.retainedAfterSleep()
        XCTAssertTrue(p.needsAttention)
        p = ReconnectPolicy(); p.enabled = true; p.willSleep(recoverMountedDisk: true); p.unsafeDisconnect(); p.retainedAfterSleep()
        XCTAssertTrue(p.needsAttention)
    }
}
