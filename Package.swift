// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "T3Notch",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "T3Notch",
            path: "Sources/T3Notch",
            linkerSettings: [.linkedFramework("Carbon")]
        ),
    ]
)
