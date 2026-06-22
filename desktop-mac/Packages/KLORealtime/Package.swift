// swift-tools-version: 6.0
//
// Local vendored copy of swift-realtime-openai (m1guelpf, MIT licensed).
// See Vendor-Attribution/README.md for the rationale and upgrade path.
import PackageDescription

let package = Package(
    name: "KLORealtime",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        // Module name matches upstream so RealtimeBridge.swift's
        // `import RealtimeAPI` resolves without source changes.
        .library(name: "RealtimeAPI", targets: ["RealtimeAPI"]),
    ],
    dependencies: [
        // Binary WebRTC framework from LiveKit — kept as an upstream
        // package because vendoring a ~100MB xcframework would be
        // wasteful and LiveKit publishes it on a steady cadence anyway.
        .package(url: "https://github.com/livekit/webrtc-xcframework.git", branch: "main"),
        // MetaCodable is the @Codable macro upstream uses for the
        // wire-format types in Sources/Core/Models. Stays upstream
        // because it's a Swift macro infrastructure dep that's hard
        // to vendor cleanly.
        .package(url: "https://github.com/SwiftyLab/MetaCodable.git", .upToNextMajor(from: "1.0.0")),
    ],
    targets: [
        .target(name: "Core", dependencies: [
            .product(name: "MetaCodable", package: "MetaCodable"),
            .product(name: "HelperCoders", package: "MetaCodable"),
        ]),
        .target(name: "WebSocket", dependencies: ["Core"]),
        .target(name: "UI", dependencies: ["Core", "WebRTC"]),
        .target(
            name: "WebRTC",
            dependencies: [
                "Core",
                .product(name: "LiveKitWebRTC", package: "webrtc-xcframework"),
            ]
        ),
        .target(name: "RealtimeAPI", dependencies: ["Core", "WebSocket", "WebRTC", "UI"]),
    ],
)
