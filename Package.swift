// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SmartRingKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "SmartRingKit", targets: ["SmartRingKit"]),
        .executable(name: "smart-ring", targets: ["smart-ring"])
    ],
    targets: [
        .target(name: "SmartRingKit", path: "platforms/apple/Sources/SmartRingKit"),
        .executableTarget(name: "smart-ring", dependencies: ["SmartRingKit"],
                          path: "platforms/apple/Sources/smart-ring"),
        .testTarget(name: "SmartRingKitTests", dependencies: ["SmartRingKit"],
                    path: "platforms/apple/Tests/SmartRingKitTests")
    ]
)
