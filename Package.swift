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
        // Windows native port: C ABI shim built as a dynamic library (DLL).
        // The C# WinUI 3 shell loads this via P/Invoke. macOS continues to
        // static-link EmulatorCore through the Xcode project, unaffected.
        .library(
            name: "Bubilator88C",
            type: .dynamic,
            targets: ["CApi"]
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
            // fmgen's licence text and the record of our changes to it, kept
            // alongside the ported source rather than built into the target.
            exclude: [
                "fmgen-readme.txt",
                "fmgen-changes.md",
            ],
            swiftSettings: [
                .unsafeFlags(["-O"], .when(configuration: .debug)),
            ]
        ),
        // Plain values that cross from the machine to its users: which key,
        // which disk image, which monitor. The one module EmulatorCore
        // re-exports, so the parts below it can stay hidden.
        .target(
            name: "PC88Types",
            swiftSettings: [
                .unsafeFlags(["-O"], .when(configuration: .debug)),
            ]
        ),
        .target(
            name: "Peripherals",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                "PC88Types",
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
                "PC88Types",
            ],
            swiftSettings: [
                .unsafeFlags(["-O"], .when(configuration: .debug)),
            ]
        ),
        .target(
            name: "CApi",
            dependencies: [
                "EmulatorCore",
            ],
            swiftSettings: [
                .unsafeFlags(["-O"], .when(configuration: .debug)),
            ],
            // Windows: export the @_cdecl symbols from the DLL via a .def file
            // (Swift's @_cdecl does not emit __declspec(dllexport)). No-op on
            // macOS, so the existing static-link build is unaffected.
            linkerSettings: [
                .unsafeFlags(
                    ["-Xlinker", "/DEF:Sources/CApi/Bubilator88C.def"],
                    .when(platforms: [.windows])
                ),
            ]
        ),
        .executableTarget(
            name: "BootTester",
            dependencies: ["EmulatorCore", "Z80", "FMSynthesis", "Peripherals"]
        ),
        .testTarget(
            name: "EmulatorCoreTests",
            dependencies: ["EmulatorCore", "Z80", "FMSynthesis", "Peripherals", "PC88Types"]
        ),
    ]
)
