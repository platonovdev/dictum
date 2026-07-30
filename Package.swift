// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dictum",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Dictum", targets: ["Dictum"]),
        .executable(name: "DictatorTranscriber", targets: ["DictatorTranscriber"])
    ],
    dependencies: [],
    targets: [
        .binaryTarget(
            name: "WhisperCpp",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.1/whisper-v1.9.1-xcframework.zip",
            checksum: "8c3ecbe73f48b0cb9318fc3058264f951ab336fd530e82c4ccdd2298d1311a4c"
        ),
        .target(
            name: "Domain"
        ),
        .target(
            name: "Application",
            dependencies: ["Domain"]
        ),
        .target(
            name: "Infrastructure",
            dependencies: [
                "Domain",
                "Application",
                "WhisperCpp"
            ],
            resources: [
                .copy("Resources/FeedbackSounds")
            ]
        ),
        .target(
            name: "Presentation",
            dependencies: ["Domain", "Application"]
        ),
        .executableTarget(
            name: "Dictum",
            dependencies: ["Domain", "Application", "Infrastructure", "Presentation"],
            path: "Sources/OneBtnVoiceApp",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .executableTarget(
            name: "DictatorTranscriber",
            dependencies: ["Domain", "Application", "Infrastructure"],
            path: "Sources/DictatorTranscriber",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .testTarget(
            name: "DomainTests",
            dependencies: ["Domain"],
            path: "Tests/DomainTests"
        ),
        .testTarget(
            name: "ApplicationTests",
            dependencies: ["Domain", "Application", "Infrastructure"],
            path: "Tests/ApplicationTests"
        ),
        .testTarget(
            name: "PresentationTests",
            dependencies: ["Domain", "Application", "Presentation"],
            path: "Tests/PresentationTests"
        )
    ]
)
