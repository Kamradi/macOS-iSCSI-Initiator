import XCTest
@testable import DiskBridge
@testable import ISCSICore

private final class FakeBlockConnection: BlockConnection {
    var identity: String? = "naa:test-lun"
    var info = DiskInfo(vendor: "TEST", model: "LUN", blockCount: 2048, blockSize: 512)
    var readError: Error?, writeError: Error?, flushError: Error?, heartbeatError: Error?
    var reads = 0, writes = 0, flushes = 0, closes = 0
    func inspect(lun: UInt16) throws -> DiskInfo { info }
    func deviceIdentifier(lun: UInt16) throws -> String? { identity }
    func read(lun: UInt16, lba: UInt64, blocks: UInt32, info: DiskInfo) throws -> Data {
        reads += 1; if let readError { throw readError }
        return Data(repeating: 0x5a, count: Int(blocks) * Int(info.blockSize))
    }
    func write(lun: UInt16, lba: UInt64, data: Data, info: DiskInfo) throws {
        writes += 1; if let writeError { throw writeError }
    }
    func synchronize(lun: UInt16) throws { flushes += 1; if let flushError { throw flushError } }
    func keepAlive() throws { if let heartbeatError { throw heartbeatError } }
    func close() { closes += 1 }
}
final class BackendRecoveryTests: XCTestCase {
    private var lost: Error { ISCSIError.transport("test connection lost") }
    func testIdleLossReconnectsSameBackendAndReadWithoutWriteReplay() throws {
        let old = FakeBlockConnection(), next = FakeBlockConnection()
        var calls = 0
        let backend = try ISCSIBackend(lun: 1, writable: true) { calls += 1; return calls == 1 ? old : next }
        old.heartbeatError = lost
        XCTAssertThrowsError(try backend.keepAlive()) { XCTAssertTrue($0 is BackendUnavailable) }
        XCTAssertEqual(try backend.read(offset: 0, count: 512), Data(repeating: 0x5a, count: 512))
        XCTAssertEqual(calls, 2); XCTAssertEqual(old.closes, 1); XCTAssertEqual(next.writes, 0)
    }
    func testReadLossCanRetryReadOnlyOnReplacement() throws {
        let old = FakeBlockConnection(), next = FakeBlockConnection(); var calls = 0
        let backend = try ISCSIBackend(lun: 1, writable: true) { calls += 1; return calls == 1 ? old : next }
        old.readError = lost
        XCTAssertThrowsError(try backend.read(offset: 0, count: 512)) { XCTAssertTrue($0 is BackendUnavailable) }
        _ = try backend.read(offset: 0, count: 512)
        XCTAssertEqual(old.reads, 1); XCTAssertEqual(next.reads, 1); XCTAssertEqual(next.writes, 0)
    }
    func testUncertainWriteNeverReconnectsOrReplays() throws {
        let old = FakeBlockConnection(); var calls = 0
        let backend = try ISCSIBackend(lun: 1, writable: true) { calls += 1; return old }
        old.writeError = lost
        XCTAssertThrowsError(try backend.write(offset: 0, data: Data(repeating: 1, count: 512))) { XCTAssertFalse($0 is BackendUnavailable) }
        XCTAssertThrowsError(try backend.keepAlive())
        XCTAssertThrowsError(try backend.write(offset: 0, data: Data(repeating: 1, count: 512)))
        XCTAssertEqual(calls, 1); XCTAssertEqual(old.writes, 1)
    }
    func testFailedFlushAfterWriteIsTerminal() throws {
        let old = FakeBlockConnection(); var calls = 0
        let backend = try ISCSIBackend(lun: 1, writable: true) { calls += 1; return old }
        try backend.write(offset: 0, data: Data(repeating: 1, count: 512)); old.flushError = lost
        XCTAssertThrowsError(try backend.flush()) { XCTAssertFalse($0 is BackendUnavailable) }
        XCTAssertThrowsError(try backend.keepAlive()); XCTAssertEqual(calls, 1)
    }
    func testConfirmedFlushAllowsIdleRecoveryAndOfflineCommit() throws {
        let old = FakeBlockConnection(), next = FakeBlockConnection(); var calls = 0
        let backend = try ISCSIBackend(lun: 1, writable: true) { calls += 1; return calls == 1 ? old : next }
        try backend.write(offset: 0, data: Data(repeating: 1, count: 512)); try backend.flush()
        old.heartbeatError = lost; XCTAssertThrowsError(try backend.keepAlive())
        try backend.flush() // all previous writes already confirmed durable
        try backend.keepAlive(); XCTAssertEqual(next.writes, 0); XCTAssertEqual(calls, 2)
    }
    func testWrongIdentityOrGeometryStopsBeforeDataAccess() throws {
        for changedIdentity in [true, false] {
            let old = FakeBlockConnection(), next = FakeBlockConnection(); var calls = 0
            if changedIdentity { next.identity = "another-lun" }
            else { next.info = DiskInfo(vendor: "TEST", model: "LUN", blockCount: 4096, blockSize: 512) }
            let backend = try ISCSIBackend(lun: 1, writable: true) { calls += 1; return calls == 1 ? old : next }
            old.heartbeatError = lost; XCTAssertThrowsError(try backend.keepAlive())
            XCTAssertThrowsError(try backend.read(offset: 0, count: 512)) { XCTAssertFalse($0 is BackendUnavailable) }
            XCTAssertThrowsError(try backend.keepAlive()); XCTAssertEqual(calls, 2)
            XCTAssertEqual(next.reads, 0); XCTAssertEqual(next.writes, 0)
        }
    }
    func testMissingIdentityDoesNotAllowAutomaticRecovery() throws {
        let old = FakeBlockConnection(); old.identity = nil; var calls = 0
        let backend = try ISCSIBackend(lun: 1, writable: true) { calls += 1; return old }
        old.heartbeatError = lost; XCTAssertThrowsError(try backend.keepAlive()) { XCTAssertFalse($0 is BackendUnavailable) }
        XCTAssertThrowsError(try backend.keepAlive()); XCTAssertEqual(calls, 1)
    }
    func testUnalignedReadFailureDoesNotSendWrite() throws {
        let old = FakeBlockConnection(), next = FakeBlockConnection(); var calls = 0
        let backend = try ISCSIBackend(lun: 1, writable: true) { calls += 1; return calls == 1 ? old : next }
        old.readError = lost
        XCTAssertThrowsError(try backend.write(offset: 1, data: Data([1]))) { XCTAssertTrue($0 is BackendUnavailable) }
        XCTAssertEqual(old.writes, 0)
        try backend.write(offset: 1, data: Data([1])); try backend.flush()
        XCTAssertEqual(next.writes, 1)
    }
    func testReadProtocolFaultIsNotTreatedAsTemporaryNetworkLoss() throws {
        let old = FakeBlockConnection(); var calls = 0
        let backend = try ISCSIBackend(lun: 1, writable: true) { calls += 1; return old }
        old.readError = ISCSIError.message("test SCSI error")
        XCTAssertThrowsError(try backend.read(offset: 0, count: 512)) { XCTAssertFalse($0 is BackendUnavailable) }
        XCTAssertThrowsError(try backend.keepAlive()); XCTAssertEqual(calls, 1)
    }
    func testRepeatedConnectFailuresDoNotLoseRecoverability() throws {
        let old = FakeBlockConnection(), next = FakeBlockConnection(); var calls = 0
        let backend = try ISCSIBackend(lun: 1, writable: true) {
            calls += 1
            if calls == 1 { return old }
            if calls < 4 { throw ISCSIError.transport("offline") }
            return next
        }
        old.heartbeatError = lost; XCTAssertThrowsError(try backend.keepAlive())
        XCTAssertThrowsError(try backend.keepAlive()) { XCTAssertTrue($0 is BackendUnavailable) }
        XCTAssertThrowsError(try backend.keepAlive()) { XCTAssertTrue($0 is BackendUnavailable) }
        try backend.keepAlive(); XCTAssertEqual(calls, 4)
    }
    func testVPDIdentifiersExcludePortsAndRejectTruncation() {
        let lu: [UInt8] = [1, 3, 0, 4, 0x60, 1, 2, 3]
        let port: [UInt8] = [1, 0x13, 0, 4, 0x60, 9, 9, 9]
        let page = [UInt8(0), 0x83, 0, 16] + port + lu
        XCTAssertEqual(Session.logicalUnitIdentifier(page), "1:3:60010203")
        XCTAssertNil(Session.logicalUnitIdentifier(Array(page.dropLast())))
        XCTAssertNil(Session.logicalUnitIdentifier([0, 0x83, 0, 8] + port))
    }
}
