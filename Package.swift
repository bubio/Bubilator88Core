// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "EmulatorCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "EmulatorCore",
            targets: ["EmulatorCore"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "Z80",
            swiftSettings: [
                .unsafeFlags(["-O"], .when(configuration: .debug)),
            ]
        ),
        .target(
            name: "FMSynthesis",
            swiftSettings: [
                .unsafeFlags(["-O"], .when(configuration: .debug)),
            ]
        ),
        .target(
            name: "Peripherals",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .unsafeFlags(["-O"], .when(configuration: .debug)),
            ]
        ),
        .target(
            name: "EmulatorCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                "Z80",
                "FMSynthesis",
                "Peripherals",
            ],
            swiftSettings: [
                .unsafeFlags(["-O"], .when(configuration: .debug)),
            ]
        ),
        .executableTarget(
            name: "BootTester",
            dependencies: ["EmulatorCore"]
        ),
        .testTarget(
            name: "EmulatorCoreTests",
            dependencies: ["EmulatorCore", "Z80", "FMSynthesis", "Peripherals"]
        ),
    ]
)
