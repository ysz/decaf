// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Decaf",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Decaf",
            path: "Sources/decaf",
            exclude: ["Resources"]
        )
    ]
)
