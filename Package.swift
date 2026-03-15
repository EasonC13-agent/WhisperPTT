// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WhisperPTT",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "WhisperPTT",
            path: "Sources"
        )
    ]
)
