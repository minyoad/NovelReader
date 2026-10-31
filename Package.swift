// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NovelReader",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // An xtool project should contain exactly one library product,
        // representing the main app.
        .library(
            name: "NovelReader",
            targets: ["NovelReader"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .target(
            name: "NovelKit",
            dependencies: ["SwiftSoup"]
        ),
        .target(
            name: "NovelReader",
            dependencies: ["NovelKit"]
        ),
        .testTarget(
            name: "NovelKitTests",
            dependencies: ["NovelKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
