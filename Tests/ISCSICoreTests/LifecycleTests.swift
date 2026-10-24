import XCTest
@testable import ConnectionLifecycle

final class LifecycleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10000)
    func testBusySleepAttachmentIsRetriedAfterWakeWithoutAuthorizingRemount() {
        var p = ReconnectPolicy(); p.enabled = true
        let now = Date()
        p.willSleep(recoverMountedDisk: true); p.unsafeDisconnect()
        XCTAssertFalse(p.shouldRecoverAfterSleep(now: now, mounted: true, busy: false))
        p.woke(now: now)
        XCTAssertTrue(p.shouldRecoverAfterSleep(now: now.addingTimeInterval(4), mounted: true, busy: false))
        XCTAssertFalse(p.shouldConnect(now: now.addingTimeInterval(4), mounted: false, busy: false))
        p.failed(now: now.addingTimeInterval(4))
        XCTAssertFalse(p.shouldRecoverAfterSleep(now: now.addingTimeInterval(5), mounted: true, busy: false))
        p.cleanDetach()
        XCTAssertFalse(p.recoveryAfterSleep)
        XCTAssertTrue(p.shouldConnect(now: now.addingTimeInterval(20), mounted: false, busy: false))
    }
    func testManualStopAndUnrelatedFaultDoNotTriggerSleepRecovery() {
        var p = ReconnectPolicy(); p.enabled = true
        p.unsafeDisconnect(); p.woke(now: .distantPast)
        XCTAssertFalse(p.shouldRecoverAfterSleep(now: Date(), mounted: true, busy: false))
        p.willSleep(recoverMountedDisk: true); p.woke(now: .distantPast); p.manualStop()
        XCTAssertFalse(p.shouldRecoverAfterSleep(now: Date(), mounted: true, busy: false))
    }

    func testCleanSleepWakeAwayFromHomeThenReturn() {
        var p = ReconnectPolicy(); p.enabled = true
        p.connected(); p.willSleep()
        XCTAssertFalse(p.shouldConnect(now: now, mounted: false, busy: false))
        p.cleanDetach()
        XCTAssertTrue(p.sleeping)
        p.woke(now: now)
        XCTAssertFalse(p.shouldConnect(now: now, mounted: false, busy: false))
        XCTAssertTrue(p.shouldConnect(now: now.addingTimeInterval(3), mounted: false, busy: false))
        // No NAS at work: back off, preserving the user's reconnect intent.
        p.failed(now: now.addingTimeInterval(3))
        XCTAssertTrue(p.enabled)
        XCTAssertFalse(p.shouldConnect(now: now.addingTimeInterval(10), mounted: false, busy: false))
        p.retryNow() // home/VPN path returned
        XCTAssertTrue(p.shouldConnect(now: now, mounted: false, busy: false))
        p.connected(); XCTAssertEqual(p.failures, 0)
    }
    func testUnfinishedSleepNeverAuthorizesSecondMount() {
        var p = ReconnectPolicy(); p.enabled = true
        p.willSleep(); p.unsafeDisconnect(); p.woke(now: now)
        p.retryNow()
        XCTAssertFalse(p.shouldConnect(now: now.addingTimeInterval(1000), mounted: false, busy: false))
        p.cleanDetach()
        XCTAssertTrue(p.shouldConnect(now: now, mounted: false, busy: false))
    }
    func testManualEjectStaysDisconnectedAcrossWakeAndNetworkChange() {
        var p = ReconnectPolicy(); p.enabled = true; p.manualStop()
        p.cleanDetach(); p.woke(now: now); p.retryNow()
        XCTAssertFalse(p.shouldConnect(now: now.addingTimeInterval(1000), mounted: false, busy: false))
    }
    func testNoDuplicateMountWhileMountedOrBusy() {
        var p = ReconnectPolicy(); p.enabled = true
        XCTAssertFalse(p.shouldConnect(now: now, mounted: true, busy: false))
        XCTAssertFalse(p.shouldConnect(now: now, mounted: false, busy: true))
    }
    func testBackoffCapsAtTwoMinutes() {
        var p = ReconnectPolicy(); p.enabled = true
        for delay in [15.0, 30, 60, 120, 120, 120] {
            p.failed(now: now)
            XCTAssertEqual(p.retryAt.timeIntervalSince(now), delay)
        }
    }
    func testProfilePersistsAttentionButHasNoPassword() throws {
        let profile = ConnectionProfile(host: "nas", port: 3260, target: "iqn.test", lun: 1, chap: true, username: "user", automatic: true, needsAttention: true)
        let data = try JSONEncoder().encode(profile)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("password"))
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: data)
        XCTAssertTrue(decoded.needsAttention); XCTAssertTrue(decoded.automatic)
    }
    func testCommandDeadlineDoesNotBlockSleepIndefinitely() {
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try CommandRunner.run("/bin/sleep", ["10"], timeout: 0.1))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }
    func testCommandOutputAndFailureArePreserved() throws {
        let result = try CommandRunner.run("/usr/bin/printf", ["hello"], timeout: 2)
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "hello")
        XCTAssertThrowsError(try CommandRunner.run("/usr/bin/false", [], timeout: 2))
    }
}
