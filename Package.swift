// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "T3Notch",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "T3Notch",
            path: "Sources/T3Notch",
            linkerSettings: [.linkedFramework("Carbon")]
        ),
    ]
)
