import Foundation
import Observation
import Contracts
import ExportKit

/// アプリ全体の UI 状態を保持する ViewModel。
///
/// すべてのサービス呼び出しを ViewModel 内に閉じ込め、View からは intent メソッド経由で
/// 操作する。`@Observable` により SwiftUI が自動的に変更を追跡する。
///
/// 設計上の重要事項:
/// - `MainActor` に固定。UI スレッドからのみアクセス可能。
/// - すべての async メソッドは `do-catch` でエラーをキャッチし、`lastError` に格納する。
/// - `subscribeToCaptureState()` で `capture.stateUpdates` を購読し、`captureState` を更新する。
@Observable
@MainActor
public final class AppViewModel {
    // ─── Services（DI） ───
    private let capture: any AudioCaptureService
    private let repository: any RecordingRepository
    private let transcription: any TranscriptionService
    private let summary: any SummaryService

    // ─── 表示用 state ───
    public private(set) var captureState: CaptureState = .idle
    public private(set) var recordings: [Recording] = []
    public private(set) var selectedRecording: Recording?
    public private(set) var segments: [TranscriptSegment] = []
    public private(set) var summaryDocument: SummaryDocument?
    public private(set) var summaryAvailability: SummaryAvailability = .available
    public private(set) var lastError: String?
    public private(set) var isBusy: Bool = false

    /// `subscribeToCaptureState()` で開始した監視タスク。
    private var stateSubscriptionTask: Task<Void, Never>?

    public init(
        capture: any AudioCaptureService,
        repository: any RecordingRepository,
        transcription: any TranscriptionService,
        summary: any SummaryService
    ) {
        self.capture = capture
        self.repository = repository
        self.transcription = transcription
        self.summary = summary
    }

    // 注: `Task` の自動キャンセルは `subscribeToCaptureState()` 再呼び出し時の
    // 既存タスクキャンセルでカバー。`deinit` からは MainActor isolated プロパティに
    // 触れないため、明示的なキャンセル API を View 側から呼ぶ運用とする。

    // MARK: - State subscription

    /// `capture.stateUpdates` を購読し、状態変更を `captureState` に反映する。
    /// View の `.task { ... }` から呼ぶ想定。重複起動を防ぐため内部でタスクをガードする。
    public func subscribeToCaptureState() async {
        // 初期スナップショット
        captureState = await capture.currentState

        // 既存タスクがあればキャンセル
        stateSubscriptionTask?.cancel()

        let stream = capture.stateUpdates
        let task = Task { @MainActor [weak self] in
            for await s in stream {
                guard let self else { break }
                if Task.isCancelled { break }
                self.captureState = s
            }
        }
        stateSubscriptionTask = task
    }

    // MARK: - Intents: Recording lifecycle

    public func startRecording() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let id = UUID()
            let dir = try AppPaths.recordingDirectory(for: id)
            _ = try await capture.start(in: dir, title: nil)
            captureState = await capture.currentState
            lastError = nil
        } catch {
            lastError = "録音開始に失敗しました: \(String(describing: error))"
        }
    }

    public func stopRecording() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let recording = try await capture.stop()
            captureState = await capture.currentState
            try await repository.create(recording)
            lastError = nil
            await refreshList()
        } catch {
            lastError = "録音停止に失敗しました: \(String(describing: error))"
        }
    }

    public func pauseRecording() async {
        do {
            try await capture.pause()
            captureState = await capture.currentState
            lastError = nil
        } catch {
            lastError = "一時停止に失敗しました: \(String(describing: error))"
        }
    }

    public func resumeRecording() async {
        do {
            try await capture.resume()
            captureState = await capture.currentState
            lastError = nil
        } catch {
            lastError = "再開に失敗しました: \(String(describing: error))"
        }
    }

    // MARK: - Intents: List / Detail

    public func refreshList() async {
        do {
            recordings = try await repository.list(limit: nil, offset: nil)
            lastError = nil
        } catch {
            lastError = "一覧の読み込みに失敗しました: \(String(describing: error))"
        }
    }

    public func search(query: String) async {
        do {
            recordings = try await repository.search(query: query)
            lastError = nil
        } catch {
            lastError = "検索に失敗しました: \(String(describing: error))"
        }
    }

    public func select(_ recording: Recording) async {
        selectedRecording = recording
        segments = []
        summaryDocument = nil
        do {
            async let segmentsAsync = repository.loadSegments(for: recording.id)
            async let summaryAsync = repository.loadSummary(for: recording.id)
            let loadedSegments = try await segmentsAsync
            let loadedSummary = try await summaryAsync
            segments = loadedSegments.sorted { $0.startSec < $1.startSec }
            summaryDocument = loadedSummary
            summaryAvailability = await summary.availability()
            lastError = nil
        } catch {
            lastError = "詳細の読み込みに失敗しました: \(String(describing: error))"
        }
    }

    public func clearSelection() {
        selectedRecording = nil
        segments = []
        summaryDocument = nil
    }

    // MARK: - Intents: Summary

    public func regenerateSummary(hint: String? = nil) async {
        guard let recording = selectedRecording else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let newSummary = try await summary.regenerate(
                from: segments,
                recordingID: recording.id,
                hint: hint
            )
            try await repository.saveSummary(newSummary)
            summaryDocument = newSummary
            lastError = nil
        } catch {
            lastError = "要約の再生成に失敗しました: \(String(describing: error))"
        }
    }

    // MARK: - Intents: Export

    /// Repository から最新の segments / summary を読み出し、`MeetingMinutes` を構築する。
    ///
    /// View 層は `.fileExporter` のドキュメント生成時にこのメソッドを呼ぶ。
    /// 失敗時は throws する（呼び出し側で `lastError` への反映を行う）。
    public func makeMinutes(for recording: Recording) async throws -> MeetingMinutes {
        let loadedSegments = try await repository.loadSegments(for: recording.id)
        let loadedSummary = try await repository.loadSummary(for: recording.id)
        let sorted = loadedSegments.sorted { $0.startSec < $1.startSec }
        return MeetingMinutes(
            recording: recording,
            segments: sorted,
            summary: loadedSummary
        )
    }

    /// 指定フォーマットでエクスポート用テキストを生成する。
    public func exportText(for recording: Recording, format: ExportFormat) async throws -> String {
        let minutes = try await makeMinutes(for: recording)
        switch format {
        case .markdown:
            return MarkdownExporter.render(minutes)
        case .plainText:
            return PlainTextExporter.render(minutes)
        }
    }

    /// エクスポート完了 / 失敗時の UI 通知用フック。
    /// View 側で `lastError` を更新したい場合に使う簡易セッタ。
    public func reportExportFailure(_ message: String) {
        lastError = message
    }

    // MARK: - Intents: Delete

    public func deleteRecording(_ recording: Recording) async {
        do {
            try await repository.delete(id: recording.id, deleteFilesImmediately: true)
            if selectedRecording?.id == recording.id {
                clearSelection()
            }
            await refreshList()
            lastError = nil
        } catch {
            lastError = "削除に失敗しました: \(String(describing: error))"
        }
    }

    // MARK: - Derived state helpers

    /// 録音中相当か（recording / paused / preparing / finalizing）
    public var isCapturing: Bool {
        switch captureState {
        case .recording, .paused, .preparing, .finalizing:
            return true
        case .idle, .failed:
            return false
        }
    }

    /// 録音中（停止可能）
    public var isActivelyRecording: Bool {
        switch captureState {
        case .recording:
            return true
        case .idle, .preparing, .paused, .finalizing, .failed:
            return false
        }
    }

    /// 一時停止中
    public var isPaused: Bool {
        switch captureState {
        case .paused:
            return true
        case .idle, .preparing, .recording, .finalizing, .failed:
            return false
        }
    }
}
