// swift-tools-version: 5.9
import PackageDescription

// This package exercises the exact Foundation-only production sources without
// requiring an iPhone, signing material, or Apple's location simulation service.
let package = Package(
    name: "WrapPinRailCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "RailCore", targets: ["RailCore"])],
    targets: [
        .target(name: "RailCore", path: "WrapPin/Features/Train/Core"),
        .testTarget(name: "RailCoreTests", dependencies: ["RailCore"], path: "Tests/RailCoreTests", exclude: ["Fixtures"])
    ]
)
