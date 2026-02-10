// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GroqDictate",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "GroqDictate",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("Security"),
            ]
        )
    ]
)
