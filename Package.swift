// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "macwm",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "macwm", targets: ["macwm"]),
    ],
    targets: [
        .target(name: "MacWMCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "macwm",
            dependencies: ["MacWMCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MacWMTests",
            dependencies: ["MacWMCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
