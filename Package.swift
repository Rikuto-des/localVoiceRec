// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "localVoiceRec",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "Contracts", targets: ["Contracts"]),
        .library(name: "AudioTapKit", targets: ["AudioTapKit"]),
        .library(name: "AudioCapture", targets: ["AudioCapture"]),
        .library(name: "DataStore", targets: ["DataStore"]),
        .library(name: "TranscriptionKit", targets: ["TranscriptionKit"]),
        .library(name: "SummaryKit", targets: ["SummaryKit"]),
        .library(name: "AppUI", targets: ["AppUI"]),
        .executable(name: "AudioTapPoC", targets: ["AudioTapPoC"]),
    ],
    targets: [
        // ─── Foundational ───
        .target(
            name: "Contracts",
            path: "Sources/Contracts"
        ),

        // ─── Phase 0 / Phase 1 audio ───
        .target(
            name: "AudioTapKit",
            dependencies: ["Contracts"],
            path: "Sources/AudioTapKit"
        ),
        .target(
            name: "AudioCapture",
            dependencies: ["Contracts", "AudioTapKit"],
            path: "Sources/AudioCapture"
        ),

        // ─── Persistence ───
        .target(
            name: "DataStore",
            dependencies: ["Contracts"],
            path: "Sources/DataStore"
        ),

        // ─── ML pipelines ───
        .target(
            name: "TranscriptionKit",
            dependencies: ["Contracts"],
            path: "Sources/TranscriptionKit"
        ),
        .target(
            name: "SummaryKit",
            dependencies: ["Contracts"],
            path: "Sources/SummaryKit"
        ),

        // ─── UI ───
        .target(
            name: "AppUI",
            dependencies: ["Contracts"],
            path: "Sources/AppUI"
        ),

        // ─── PoC CLI (Phase 0) ───
        .executableTarget(
            name: "AudioTapPoC",
            dependencies: ["AudioTapKit"],
            path: "Tools/AudioTapPoC"
        ),

        // ─── Tests (placeholder; populated as modules mature) ───
        .testTarget(
            name: "ContractsTests",
            dependencies: ["Contracts"],
            path: "Tests/ContractsTests"
        ),
        .testTarget(
            name: "DataStoreTests",
            dependencies: ["DataStore", "Contracts"],
            path: "Tests/DataStoreTests"
        ),
        .testTarget(
            name: "AudioCaptureTests",
            dependencies: ["AudioCapture", "AudioTapKit", "Contracts"],
            path: "Tests/AudioCaptureTests"
        ),
    ]
)
