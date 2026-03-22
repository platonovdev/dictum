// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OneBtnVoice",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "OneBtnVoice", targets: ["OneBtnVoice"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.16.0")
    ],
    targets: [
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
                .product(name: "WhisperKit", package: "WhisperKit")
            ]
        ),
        .target(
            name: "Presentation",
            dependencies: ["Domain", "Application"]
        ),
        .executableTarget(
            name: "OneBtnVoice",
            dependencies: ["Domain", "Application", "Infrastructure", "Presentation"],
            path: "Sources/OneBtnVoiceApp",
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
