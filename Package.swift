// swift-tools-version: 5.9
import PackageDescription

let privacyInfoPlistLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-Xlinker", "-sectcreate",
        "-Xlinker", "__TEXT",
        "-Xlinker", "__info_plist",
        "-Xlinker", "Support/VoiceChatInfo.plist"
    ])
]

let package = Package(
    name: "VoiceChat",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "VoiceChatCore", targets: ["VoiceChatCore"]),
        .executable(name: "voice-chat", targets: ["VoiceChatCLI"]),
        .executable(name: "VoiceChatMacApp", targets: ["VoiceChatMacApp"])
    ],
    targets: [
        .target(name: "VoiceChatCore"),
        .executableTarget(
            name: "VoiceChatCLI",
            dependencies: ["VoiceChatCore"],
            linkerSettings: privacyInfoPlistLinkerSettings
        ),
        .executableTarget(
            name: "VoiceChatMacApp",
            dependencies: ["VoiceChatCore"],
            linkerSettings: privacyInfoPlistLinkerSettings
        ),
        .testTarget(
            name: "VoiceChatCoreTests",
            dependencies: ["VoiceChatCore"]
        )
    ]
)
