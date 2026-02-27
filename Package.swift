// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "knob",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "knob-driver", type: .static, targets: ["knob-driver"]),
    ],
    targets: [
        .target(name: "EQCore"),
        .target(name: "CAPlugIn"),
        .target(
            name: "knob-driver",
            dependencies: ["CAPlugIn"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
            ]
        ),
        .executableTarget(
            name: "knobd",
            dependencies: ["EQCore"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .executableTarget(
            name: "knob",
            dependencies: ["EQCore"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "knob-ipc",
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
    ]
)
