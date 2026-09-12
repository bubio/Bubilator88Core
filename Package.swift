// swift-tools-version: 6.1

import PackageDescription

// The core runs about ten times slower at -Onone, too slow to play in a Debug
// build, so it is optimised in every configuration.
//
// SwiftPM refuses unsafe flags in a dependency pinned by version. Release tags
// therefore point at a commit of their own where this is empty, made by
// scripts/tag-release.sh; main keeps the flag. Nothing else in this file may
// use unsafeFlags, or tagging breaks.
let alwaysOptimize: [SwiftSetting] = [
    .unsafeFlags(["-O"], .when(configuration: .debug)),
]

let package = Package(
    name: "Bubilator88Core",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "Bubilator88Core",
            targets: ["Bubilator88Core"]
        ),
        // Windows native port: C ABI shim built as a dynamic library (DLL).
        // The C# WinUI 3 shell loads this via P/Invoke. macOS continues to
        // static-link Bubilator88Core through the Xcode project, unaffected.
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
            swiftSettings: alwaysOptimize
        ),
        .target(
            name: "FMSynthesis",
            // fmgen's licence text and the record of our changes to it, kept
            // alongside the ported source rather than built into the target.
            exclude: [
                "fmgen-readme.txt",
                "fmgen-changes.md",
            ],
            swiftSettings: alwaysOptimize
        ),
        // Plain values that cross from the machine to its users: which key,
        // which disk image, which monitor, which boot mode. The one module
        // Bubilator88Core re-exports, so the parts below it can stay hidden.
        .target(
            name: "PC88Types",
            swiftSettings: alwaysOptimize
        ),
        .target(
            name: "Peripherals",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                "PC88Types",
            ],
            swiftSettings: alwaysOptimize
        ),
        .target(
            name: "Bubilator88Core",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                "Z80",
                "FMSynthesis",
                "Peripherals",
                "PC88Types",
            ],
            swiftSettings: alwaysOptimize
        ),
        .target(
            name: "CApi",
            dependencies: [
                "Bubilator88Core",
            ],
            // The @_cdecl functions are public, and Swift exports public
            // symbols from a Windows DLL by itself; no .def file is needed.
            // CI checks the DLL's export table against the @_cdecl names.
            swiftSettings: alwaysOptimize
        ),
        .executableTarget(
            name: "BootTester",
            dependencies: ["Bubilator88Core", "Z80", "FMSynthesis", "Peripherals"]
        ),
        .testTarget(
            name: "Bubilator88CoreTests",
            dependencies: ["Bubilator88Core", "Z80", "FMSynthesis", "Peripherals", "PC88Types"]
        ),
    ]
)
