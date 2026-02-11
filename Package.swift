// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GroqDictate",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "GroqDictate",
            path: "Sources",
            swiftSettings: [
                .unsafeFlags(["-Osize"], .when(configuration: .release)),
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-dead_strip"]),
                .linkedFramework("Cocoa"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Security"),
            ]
        )
    ]
)
