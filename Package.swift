// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GitChop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GitChop", targets: ["GitChop"]),
    ],
    targets: [
        .executableTarget(
            name: "GitChop",
            path: "Sources/GitChop"
        ),
    ]
)
