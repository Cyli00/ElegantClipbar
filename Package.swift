// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ElegantClipbar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ElegantClipbar", targets: ["ElegantClipbar"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .executableTarget(
            name: "ElegantClipbar",
            dependencies: ["CSQLite"],
            path: "Sources/ElegantClipbar",
            resources: [
                .copy("Resources/BrandIcon.png"),
                .copy("Resources/StatusIconTemplate.png"),
            ]
        ),
        .testTarget(
            name: "ElegantClipbarTests",
            dependencies: ["ElegantClipbar"],
            path: "Tests/ElegantClipbarTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
