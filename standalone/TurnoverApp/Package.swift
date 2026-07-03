// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TurnoverApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Turnover", targets: ["Turnover"]),
    ],
    targets: [
        .executableTarget(
            name: "Turnover",
            path: "Sources/Turnover"
        ),
    ]
)
