// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KLMSync",
    defaultLocalization: "ko",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "KLMSShared", targets: ["KLMSShared"]),
        .executable(name: "KLMSMac", targets: ["KLMSMac"]),
        .executable(name: "KLMSiOS", targets: ["KLMSiOS"]),
    ],
    targets: [
        .target(
            name: "KLMSShared"
        ),
        .executableTarget(
            name: "KLMSMac",
            dependencies: ["KLMSShared"],
            resources: [
                .copy("Resources/EnginePayload"),
            ]
        ),
        .executableTarget(
            name: "KLMSiOS",
            dependencies: ["KLMSShared"]
        ),
        .testTarget(
            name: "KLMSSharedTests",
            dependencies: ["KLMSShared"],
            resources: [
                .process("Fixtures"),
            ]
        ),
        .testTarget(
            name: "KLMSMacTests",
            dependencies: ["KLMSMac"]
        ),
    ]
)
