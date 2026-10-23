import Foundation

public enum DiskImageLayout {
    /// An attach response can put slices before the backing device, and can
    /// include a separate synthesized APFS device. Prefer the partition map.
    public static func wholeDevice(in entities: [[String: Any]]) -> String? {
        let schemes = ["GUID_partition_scheme", "FDisk_partition_scheme", "Apple_partition_scheme"]
        let ordered = entities.filter { schemes.contains($0["content-hint"] as? String ?? "") } + entities
        return ordered.compactMap { $0["dev-entry"] as? String }.first {
            $0.range(of: "^/dev/disk[0-9]+$", options: .regularExpression) != nil
        }
    }
}
