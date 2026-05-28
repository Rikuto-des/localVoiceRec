import Foundation
import Contracts
import SummaryKit

/// 録音停止後 / 録音選択後の「文字起こし → 要約」自動パイプラインを管理する coordinator。
///
/// Z1: 旧 `AppViewModel` から `pipelineTasks` / `autoTranscribeAttempted` / `runAutoPipeline(for:)`
/// を移設。`hasSubstantiveContent` は `SummaryKit.SubstantiveContentChecker.isSubstantive(segments:)`
/// に切り出し済み (`Sources/SummaryKit/SubstantiveContentChecker.swift`)。
///
/// 設計メモ:
/// - 本 coordinator は **AppViewModel 上に MainActor 隔離で生存** する。実際の
///   `transcribeRecording` / `summarizeRecording` / `refreshList` の実装は AppViewModel が
///   保持しており、それらをクロージャとして注入する (依存の循環を避ける)。
/// - `pipelineTasks` の cancel & 掃除責務はこのクラスに閉じる。
/// - `autoTranscribeAttempted` は「`select` 経由の自動 transcribe を 1 回だけ試したか」を
///   覚えておく一回限りガード。手動 `transcribeRecording` 呼び出し時に `clearAttempted(for:)`
///   で解除されるべき。
@MainActor
final class AutoPipelineCoordinator {
    /// 進行中の自動パイプライン (録音 ID → Task)
    private var pipelineTasks: [UUID: Task<Void, Never>] = [:]
    /// `select` 経由で 1 回だけ自動 transcribe を試行済みの録音 ID。
    /// 手動「文字起こしを実行」が押されたらクリアして再試行を許可する。
    private var autoTranscribeAttempted: Set<UUID> = []

    /// AppViewModel から注入される協調 closure。
    struct Hooks {
        let transcribe: @MainActor (Recording) async -> Void
        let summarize: @MainActor (Recording, [TranscriptSegment]) async -> Void
        let loadSegments: @MainActor (UUID) async -> [TranscriptSegment]
        let refreshList: @MainActor () async -> Void
    }

    private let hooks: Hooks

    init(hooks: Hooks) {
        self.hooks = hooks
    }

    /// 指定録音についてパイプラインが実行中か。
    func isRunning(for id: UUID) -> Bool {
        pipelineTasks[id] != nil
    }

    /// `select` 経由でこの録音について自動 transcribe を試行済みか。
    func hasAttemptedAutoTranscribe(for id: UUID) -> Bool {
        autoTranscribeAttempted.contains(id)
    }

    /// 自動試行済みフラグを立てる。
    func markAutoTranscribeAttempted(for id: UUID) {
        autoTranscribeAttempted.insert(id)
    }

    /// 手動 transcribe が押された時など、再試行を許可するためにフラグを解除する。
    func clearAttempted(for id: UUID) {
        autoTranscribeAttempted.remove(id)
    }

    /// 録音停止後（および select で空 segments のとき）に呼ばれる、
    /// 文字起こし→要約の自動パイプライン。バックグラウンドで走る。
    ///
    /// 要約は `SubstantiveContentChecker.isSubstantive(segments:)` を満たすときのみ
    /// 自動発火する (ハルシネーション防止)。薄い入力でも手動「要約を再生成」からは可能。
    func run(for recording: Recording) {
        pipelineTasks[recording.id]?.cancel()
        let hooks = self.hooks
        let task = Task { @MainActor [weak self] in
            defer {
                self?.pipelineTasks.removeValue(forKey: recording.id)
                Task { @MainActor in await hooks.refreshList() }
            }
            await hooks.transcribe(recording)
            guard !Task.isCancelled else { return }
            let saved = await hooks.loadSegments(recording.id)
            if SubstantiveContentChecker.isSubstantive(segments: saved) {
                await hooks.summarize(recording, saved)
            }
        }
        pipelineTasks[recording.id] = task
    }
}
