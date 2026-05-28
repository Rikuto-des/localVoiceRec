import Foundation
import Observation
import Contracts

/// 録音一覧の表示状態 + 検索・ステータスキャッシュを保持する小さな sub-state。
///
/// Z1: 旧 `AppViewModel` から `recordings` / `recordingStatuses` / `searchDebounced` /
/// `search` / `refreshList` / `status(for:)` / `pendingSearchTask` を移設。
/// `AppViewModel` は本型を保持し、既存の `viewModel.recordings` 等の API を
/// computed property で本型へ委譲する。
///
/// 設計メモ:
/// - 進行中フラグ集合 (`transcribingIDs` / `summarizingIDs` / `emptyTranscriptIDs`)
///   は引き続き `AppViewModel` 側に持つ。`refreshList` 呼び出し時にこれらを
///   スナップショットとして渡してもらう構成にして、状態の二重所有を避ける。
/// - エラー時の UI メッセージ整形は `AppViewModel.userMessage(for:context:)` に集約。
///   ここではエラーを throw して呼び出し元に委ねる。
@Observable
@MainActor
final class RecordingListState {
    /// 一覧表示用の録音配列。
    private(set) var recordings: [Recording] = []
    /// 一覧表示用の、録音 ID ごとの状態キャッシュ（refreshList で更新）。
    private(set) var recordingStatuses: [UUID: RecordingStatus] = [:]

    /// search debounce 用の進行中タスク。次のキーストロークで cancel される。
    /// A12: 毎キーストローク fetch で SwiftData が刻まれる問題への対策。
    private var pendingSearchTask: Task<Void, Never>?

    private let repository: any RecordingRepository

    init(repository: any RecordingRepository) {
        self.repository = repository
    }

    /// `refreshList` 呼び出し時に必要な進行中フラグのスナップショット。
    /// AppViewModel 側で管理されている集合を渡す。
    struct InProgressFlags {
        let transcribingIDs: Set<UUID>
        let summarizingIDs: Set<UUID>
        let emptyTranscriptIDs: Set<UUID>
    }

    /// 一覧を最新化する。失敗時は throws するので呼び出し側で UI 用メッセージへ変換する。
    func refresh(flags: InProgressFlags) async throws {
        let rows = try await repository.listWithStatus(limit: nil, offset: nil)
        var newRecordings: [Recording] = []
        newRecordings.reserveCapacity(rows.count)
        var map: [UUID: RecordingStatus] = [:]
        for row in rows {
            let r = row.recording
            newRecordings.append(r)
            if flags.transcribingIDs.contains(r.id) {
                map[r.id] = .transcribing
            } else if flags.summarizingIDs.contains(r.id) {
                map[r.id] = .summarizing
            } else if !row.hasSegments {
                map[r.id] = flags.emptyTranscriptIDs.contains(r.id) ? .emptyTranscript : .pending
            } else if row.hasSummary {
                map[r.id] = .completed
            } else {
                map[r.id] = .transcribed
            }
        }
        recordings = newRecordings
        recordingStatuses = map
    }

    /// 検索を即時実行する (debounce なし)。失敗時は throws。
    func search(query: String) async throws {
        recordings = try await repository.search(query: query)
    }

    /// 入力デバウンス付きの検索エントリポイント。
    /// 進行中の検索タスクをキャンセルし、300ms 待ってから最新クエリで実行する。
    /// 空文字なら `refresh(flags:)` を `flagsProvider` 経由で取得して呼ぶ。
    func searchDebounced(
        query: String,
        flagsProvider: @escaping @MainActor () -> InProgressFlags,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        pendingSearchTask?.cancel()
        let trimmed = query
        pendingSearchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            guard let self else { return }
            do {
                if trimmed.isEmpty {
                    try await self.refresh(flags: flagsProvider())
                } else {
                    try await self.search(query: trimmed)
                }
            } catch {
                onError(error)
            }
        }
    }

    /// 一覧表示用に、指定録音の現在状態を返す。
    func status(for id: UUID, flags: InProgressFlags) -> RecordingStatus {
        if flags.transcribingIDs.contains(id) { return .transcribing }
        if flags.summarizingIDs.contains(id) { return .summarizing }
        if flags.emptyTranscriptIDs.contains(id), recordingStatuses[id] == nil {
            return .emptyTranscript
        }
        return recordingStatuses[id] ?? .pending
    }
}
