// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SimNap",
    platforms: [
        .iOS(.v14),
        .macOS(.v12)
    ],
    products: [
        .library(name: "SimulatorNetworkCore", targets: ["SimulatorNetworkCore"])
    ],
    targets: [
        .target(name: "SimulatorNetworkCore", path: "SimulatorNetworkCore")
    ]
)
