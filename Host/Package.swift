// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SimNapHost",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "SimulatorNetworkHostCore", targets: ["SimulatorNetworkHostCore"]),
        .executable(name: "simulator-network", targets: ["simulator-network"]),
        .executable(name: "simulator-network-menubar", targets: ["simulator-network-menubar"])
    ],
    dependencies: [
        .package(name: "SimNap", path: ".."),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "SimulatorNetworkHostCore",
            dependencies: [
                .product(name: "SimulatorNetworkCore", package: "SimNap")
            ]
        ),
        .executableTarget(
            name: "simulator-network",
            dependencies: [
                "SimulatorNetworkHostCore",
                .product(name: "SimulatorNetworkCore", package: "SimNap"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(
            name: "simulator-network-menubar",
            dependencies: [
                "SimulatorNetworkHostCore",
                .product(name: "SimulatorNetworkCore", package: "SimNap")
            ]
        )
    ]
)
