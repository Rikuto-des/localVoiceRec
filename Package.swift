// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "localVoiceRec",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "Contracts", targets: ["Contracts"]),
        .library(name: "ContractsTestSupport", targets: ["ContractsTestSupport"]),
        .library(name: "AudioTapKit", targets: ["AudioTapKit"]),
        .library(name: "AudioCapture", targets: ["AudioCapture"]),
        .library(name: "DataStore", targets: ["DataStore"]),
        .library(name: "TranscriptionKit", targets: ["TranscriptionKit"]),
        .library(name: "SummaryKit", targets: ["SummaryKit"]),
        .library(name: "AppUI", targets: ["AppUI"]),
        .executable(name: "AudioTapPoC", targets: ["AudioTapPoC"]),
        .executable(name: "E2EProbe", targets: ["E2EProbe"]),
    ],
    targets: [
        // ─── Foundational ───
        .target(
            name: "Contracts",
            path: "Sources/Contracts"
        ),
        .target(
            name: "ContractsTestSupport",
            dependencies: ["Contracts"],
            path: "Sources/ContractsTestSupport"
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
            dependencies: ["Contracts", "ContractsTestSupport", "TranscriptionKit"],
            path: "Sources/AppUI"
        ),

        // ─── PoC CLI (Phase 0) ───
        .executableTarget(
            name: "AudioTapPoC",
            dependencies: ["AudioTapKit"],
            path: "Tools/AudioTapPoC",
            exclude: ["output"]
        ),

        // ─── E2E Probe CLI (S9) — PoC 出力を transcribe + summarize して stdout に出す ───
        .executableTarget(
            name: "E2EProbe",
            dependencies: ["Contracts", "TranscriptionKit", "SummaryKit"],
            path: "Tools/E2EProbe"
        ),

        // ─── Tests (placeholder; populated as modules mature) ───
        .testTarget(
            name: "ContractsTests",
            dependencies: ["Contracts", "ContractsTestSupport"],
            path: "Tests/ContractsTests"
        ),
        .testTarget(
            name: "DataStoreTests",
            dependencies: ["DataStore", "Contracts"],
            path: "Tests/DataStoreTests"
        ),
        .testTarget(
            name: "AudioCaptureTests",
            dependencies: ["AudioCapture", "AudioTapKit", "Contracts", "ContractsTestSupport"],
            path: "Tests/AudioCaptureTests"
        ),
        .testTarget(
            name: "AudioTapKitTests",
            dependencies: ["AudioTapKit"],
            path: "Tests/AudioTapKitTests"
        ),
        .testTarget(
            name: "TranscriptionKitTests",
            dependencies: ["TranscriptionKit", "Contracts"],
            path: "Tests/TranscriptionKitTests"
        ),
        .testTarget(
            name: "SummaryKitTests",
            dependencies: ["SummaryKit", "Contracts"],
            path: "Tests/SummaryKitTests"
        ),
        .testTarget(
            name: "AppUITests",
            dependencies: ["AppUI", "Contracts", "ContractsTestSupport"],
            path: "Tests/AppUITests"
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["TranscriptionKit", "Contracts"],
            path: "Tests/IntegrationTests"
        ),
    ]
)
