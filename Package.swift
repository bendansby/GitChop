// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GitChop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GitChop", targets: ["GitChop"]),
    ],
    dependencies: [
        // Sparkle handles auto-update. Binary XCFramework, so swift build
        // links it cleanly. The framework bundle still needs to live at
        // GitChop.app/Contents/Frameworks/Sparkle.framework — that's
        // copied in by scripts/build-app.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "GitChop",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/GitChop"
        ),
    ]
)
