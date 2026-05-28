import Foundation
import Observation
import Contracts

/// 診断パネルで表示する情報のスナップショット。
/// Z1: 旧 `AppViewModel.swift` から本ファイルへ移動。
public struct DiagnosticsInfo: Sendable, Equatable {
    public let micAuthorization: AudioAuthorizationStatus.State
    public let systemAudioAuthorization: AudioAuthorizationStatus.State
    /// `Locale.identifier` の文字列配列（例: `"ja_JP"`, `"en_US"`）。
    public let installedLocales: [String]
    public let summaryAvailability: SummaryAvailability
    /// SystemAudioTap の IOProc カウンタ。録音中はライブ値、停止後は最終スナップショット。
    /// SystemAudioTap が存在しない実装 (Fake 等) では `nil`。
    public let systemFlow: SystemFlowSnapshot?

    public init(
        micAuthorization: AudioAuthorizationStatus.State,
        systemAudioAuthorization: AudioAuthorizationStatus.State,
        installedLocales: [String],
        summaryAvailability: SummaryAvailability,
        systemFlow: SystemFlowSnapshot? = nil
    ) {
        self.micAuthorization = micAuthorization
        self.systemAudioAuthorization = systemAudioAuthorization
        self.installedLocales = installedLocales
        self.summaryAvailability = summaryAvailability
        self.systemFlow = systemFlow
    }

    public static let empty = DiagnosticsInfo(
        micAuthorization: .notDetermined,
        systemAudioAuthorization: .notDetermined,
        installedLocales: [],
        summaryAvailability: .available,
        systemFlow: nil
    )
}

/// 診断パネル用のステートを保持する小さな sub-state。
///
/// Z1: 旧 `AppViewModel` から `diagnostics` / `refreshDiagnostics()` を移設。
/// `AppViewModel` は本型を保持し、`viewModel.diagnostics` / `viewModel.refreshDiagnostics()`
/// の既存 API を本型への委譲で提供する。
@Observable
@MainActor
final class DiagnosticsState {
    /// 診断パネル用の情報（権限 / 利用可能 locale / 要約サービス状況）。
    private(set) var diagnostics: DiagnosticsInfo = .empty

    private let capture: any AudioCaptureService
    private let transcription: any TranscriptionService
    private let summary: any SummaryService

    init(
        capture: any AudioCaptureService,
        transcription: any TranscriptionService,
        summary: any SummaryService
    ) {
        self.capture = capture
        self.transcription = transcription
        self.summary = summary
    }

    /// 診断情報（権限・locale・要約 availability）を取得し直す。
    /// View 側の `.task` で初回 + 「更新」ボタンで再取得する。
    func refresh() async {
        let auth = await capture.authorizationStatus()
        let locales = await transcription.installedLocales()
        let avail = await summary.availability()
        let systemFlow = await capture.systemFlowSnapshot()
        diagnostics = DiagnosticsInfo(
            micAuthorization: auth.microphone,
            systemAudioAuthorization: auth.systemAudio,
            installedLocales: locales.map(\.identifier),
            summaryAvailability: avail,
            systemFlow: systemFlow
        )
    }
}
