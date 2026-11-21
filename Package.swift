// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "agy-cs",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "agy-cs", targets: ["agy-cs"])
    ],
    targets: [
        .target(
            name: "AgyAccount",
            path: "Sources/AgyAccount",
            resources: [
                .copy("i18n")
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "agy-cs",
            dependencies: ["AgyAccount"],
            path: "Sources/agy-cs",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "AgyAccountTests",
            dependencies: ["AgyAccount"],
            path: "Tests/AgyAccountTests"
        )
    ]
)
