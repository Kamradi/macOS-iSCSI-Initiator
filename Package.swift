// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SynologyInitiator", platforms: [.macOS(.v14)], products: [
    .executable(name: "SynologyInitiator", targets: ["ISCSIApp"]),
    .executable(name: "iscsi", targets: ["ISCSICLI"]),
    .executable(name: "iscsi-bridge", targets: ["ISCSIBridge"])
], targets: [
    .target(name: "AppLocalization"),
    .target(name: "ISCSICore", dependencies: ["AppLocalization"]),
    .target(name: "ConnectionLifecycle", dependencies: ["AppLocalization"]),
    .executableTarget(name: "ISCSIApp", dependencies: ["ISCSICore", "ConnectionLifecycle", "AppLocalization"]),
    .executableTarget(name: "ISCSICLI", dependencies: ["ISCSICore", "AppLocalization"]),
    .target(name: "DiskBridge", dependencies: ["ISCSICore"]),
    .executableTarget(name: "ISCSIBridge", dependencies: ["DiskBridge", "ISCSICore"]),
    .testTarget(name: "ISCSICoreTests", dependencies: ["ISCSICore", "DiskBridge", "ConnectionLifecycle", "AppLocalization"])
])
