// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnchorOverlay",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AnchorOverlay", targets: ["AnchorOverlay"]),
               .executable(name: "OverlayBench", targets: ["OverlayBench"]),
               .executable(name: "OverlayChecks", targets: ["OverlayChecks"]),
               .executable(name: "OverlayRegression", targets: ["OverlayRegression"])],
    targets: [
        .target(name: "AnchorOverlayCore"),
        .executableTarget(name: "AnchorOverlay", dependencies: ["AnchorOverlayCore"]),
        .executableTarget(name: "OverlayBench", dependencies: ["AnchorOverlayCore"]),
        .executableTarget(name: "OverlayChecks", dependencies: ["AnchorOverlayCore"]),
        .executableTarget(name: "OverlayRegression", dependencies: ["AnchorOverlayCore"]),
        .testTarget(name: "AnchorOverlayCoreTests", dependencies: ["AnchorOverlayCore"])
    ],
    swiftLanguageModes: [.v5]
)
