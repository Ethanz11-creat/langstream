// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "FlowType",
    platforms: [
        .macOS(.v14) // 设置支持的系统版本
    ],
    targets: [
        .executableTarget(
            name: "FlowType",
            dependencies: [],
            path: "Sources/flowtype",
            resources: [
                .copy("Resources/tech_terms.json"),
                .copy("Resources/filler_words.json"),
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/status_bar_icon.png"),
                .copy("Resources/status_bar_icon@2x.png")
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]) // 允许使用 @main
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech")
            ]
        ),
    ]
)
