import XCTest
import ConnectionLifecycle

final class DiskImageLayoutTests: XCTestCase {
    func testPartitionMapWinsOverSliceAndSynthesizedAPFSDevice() {
        let entities: [[String: Any]] = [
            ["dev-entry": "/dev/disk8s1"],
            ["dev-entry": "/dev/disk9", "content-hint": "EF57347C-0000-11AA-AA11-00306543ECAC"],
            ["dev-entry": "/dev/disk8", "content-hint": "GUID_partition_scheme"]
        ]
        XCTAssertEqual(DiskImageLayout.wholeDevice(in: entities), "/dev/disk8")
    }
    func testUnpartitionedDeviceAndInvalidEntries() {
        XCTAssertEqual(DiskImageLayout.wholeDevice(in: [["dev-entry": "/dev/disk8"]]), "/dev/disk8")
        XCTAssertNil(DiskImageLayout.wholeDevice(in: [["dev-entry": "/dev/disk8s1"], ["dev-entry": "/Volumes/Test"]]))
    }
}
