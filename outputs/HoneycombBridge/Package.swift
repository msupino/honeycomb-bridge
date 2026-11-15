// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HoneycombBridge",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "honeycomb-probe", targets: ["Probe"]),
        .executable(name: "honeycomb-usb-read", targets: ["USBRead"]),
        .executable(name: "honeycomb-bridge", targets: ["Bridge"]),
        .executable(name: "honeycomb-monitor", targets: ["Monitor"])
    ],
    targets: [
        .executableTarget(name: "Probe", path: "Sources/Probe", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [
            .linkedFramework("Foundation"), .linkedFramework("IOKit")
        ]),
        .executableTarget(name: "USBRead", path: "Sources/USBRead", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [
            .linkedFramework("Foundation"), .linkedFramework("IOKit"), .linkedFramework("Security")
        ]),
        .executableTarget(name: "Bridge", path: "Sources/Bridge"),
        .executableTarget(name: "Monitor", path: "Sources/Monitor"),
        .testTarget(name: "BridgeTests", dependencies: ["Bridge"]),
        .testTarget(name: "MonitorTests", dependencies: ["Monitor"])
    ]
)
