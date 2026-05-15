// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "FlowType",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/soniqo/speech-swift.git", from: "0.0.15"),
    ],
    targets: [
        .executableTarget(
            name: "FlowType",
            dependencies: [
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
            ],
            path: "Sources/flowtype",
            resources: [
                .copy("Resources/tech_terms.json"),
                .copy("Resources/filler_words.json"),
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/status_bar_icon.png"),
                .copy("Resources/status_bar_icon@2x.png"),
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
