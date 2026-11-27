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
            exclude: [
                "i18n/README.md"
            ],
            resources: [
                .embedInCode("i18n/zh-Hans.txt"),
                .embedInCode("i18n/zh-Hant.txt"),
                .embedInCode("i18n/en.txt"),
                .embedInCode("i18n/ja.txt")
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "AgyMenuBar",
            dependencies: ["AgyAccount"],
            path: "Sources/AgyMenuBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .executableTarget(
            name: "agy-cs",
            dependencies: ["AgyAccount", "AgyMenuBar"],
            path: "Sources/agy-cs"
        ),
        .testTarget(
            name: "AgyAccountTests",
            dependencies: ["AgyAccount", "AgyMenuBar"],
            path: "Tests/AgyAccountTests"
        )
    ]
)
