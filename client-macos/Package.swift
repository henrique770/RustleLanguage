// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RustleLanguage",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "RustleLanguage",
            path: "Sources/RustleLanguage",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
            ]
        )
    ]
)
