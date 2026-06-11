// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MatterServer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MatterServer",
            path: "Sources/MatterServer"
        )
    ],
    swiftLanguageModes: [.v5]
)
