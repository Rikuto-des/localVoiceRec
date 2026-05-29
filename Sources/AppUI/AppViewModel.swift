import Foundation
import Observation
import os
import Contracts
import SummaryKit

/// UI 層からのエラー文表示用ロガー。詳細な enum case 名は os.log にのみ残し、
/// `lastError` には日本語の actionable メッセージだけを入れる方針。
private let uiErrorLog = Logger(subsystem: "localVoiceRec.AppUI", category: "AppViewModel")

/// 一覧表示用の録音状態。
public enum RecordingStatus: Sendable, Hashable {
    case pending           // 文字起こし未実行
    case transcribing      // 文字起こし中
    case summarizing       // 要約生成中
    case transcribed       // 文字起こしのみ完了（要約なし）
    case completed         // 文字起こし + 要約完了
    case emptyTranscript   // 文字起こしを試行したが空（無音/未対応言語）
    case failed            // 直近の試行が失敗
}

/// アプリ全体の UI 状態を保持する ViewModel（オーケストレータ）。
///
/// Z1 で god object を 3 つの sub-state に分解した:
/// - `RecordingListState` … list / search / refreshList / status (`ViewModels/RecordingListState.swift`)
/// - `AutoPipelineCoordinator` … 録音停止 → transcribe → summary 自動連結 (`ViewModels/AutoPipelineCoordinator.swift`)
/// - `DiagnosticsState` … 権限 / locale / 要約 availability (`ViewModels/DiagnosticsState.swift`)
/// `hasSubstantiveContent` は `SummaryKit.SubstantiveContentChecker` に移設済み。
///
/// 既存 View からの API (`viewModel.recordings`, `viewModel.startRecording()` 等) は
/// 変更しない。本クラスでは sub-state への薄い委譲プロパティ + intent メソッドを提供する。
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

    // ─── Sub-states (Z1 分解) ───
    /// 録音一覧 / 検索 / ステータスキャッシュ。
    private let listState: RecordingListState
    /// 自動パイプライン (transcribe → summary) coordinator。
    private var autoPipeline: AutoPipelineCoordinator!
    /// 診断パネル用 state。
    private let diagnosticsState: DiagnosticsState

    // ─── 表示用 state (本クラスに残るもの) ───
    public private(set) var captureState: CaptureState = .idle
    public private(set) var selectedRecording: Recording?
    public private(set) var segments: [TranscriptSegment] = []
    public private(set) var summaryDocument: SummaryDocument?
    public private(set) var summaryAvailability: SummaryAvailability = .available
    /// View からも `nil` を代入してエラー表示を閉じられるよう setter を公開。
    /// 設定 (代入) は MainActor 隔離内のみ。
    public var lastError: String?
    public private(set) var isBusy: Bool = false
    /// 文字起こし進行中の録音 ID 集合
    public private(set) var transcribingIDs: Set<UUID> = []
    /// 要約生成中の録音 ID 集合
    public private(set) var summarizingIDs: Set<UUID> = []

    /// いずれかの録音で文字起こしが走っているか（既存 View 用の互換ラッパ）。
    public var isTranscribing: Bool { !transcribingIDs.isEmpty }
    /// いずれかの録音で要約生成が走っているか（既存 View 用の互換ラッパ）。
    public var isSummarizing: Bool { !summarizingIDs.isEmpty }

    /// 現在選択中の録音が文字起こし中か（View で「この録音」の進行表示に使う）。
    public var isTranscribingSelected: Bool {
        guard let id = selectedRecording?.id else { return false }
        return transcribingIDs.contains(id)
    }
    /// 現在選択中の録音が要約生成中か。
    public var isSummarizingSelected: Bool {
        guard let id = selectedRecording?.id else { return false }
        return summarizingIDs.contains(id)
    }

    // ─── Sub-state delegating properties (View 互換 API) ───
    /// `RecordingListState.recordings` への薄いラッパ。
    public var recordings: [Recording] { listState.recordings }
    /// `RecordingListState.recordingStatuses` への薄いラッパ。
    public var recordingStatuses: [UUID: RecordingStatus] { listState.recordingStatuses }
    /// `DiagnosticsState.diagnostics` への薄いラッパ。
    public var diagnostics: DiagnosticsInfo { diagnosticsState.diagnostics }

    /// `subscribeToCaptureState()` で開始した監視タスク。
    private var stateSubscriptionTask: Task<Void, Never>?
    /// `subscribeToAudioLevels()` で開始した監視タスク。
    private var audioLevelsTask: Task<Void, Never>?

    /// 録音中のレベルスナップショットの rolling buffer。
    /// **メニューバーポップアップを閉じても継続して更新される** ように、
    /// ViewModel 自身が `service.liveAudioLevels` を購読し、ここに保持する。
    /// View 側は `audioLevels` を読むだけ（subscribe しない）。
    public private(set) var audioLevels: [AudioLevelSnapshot] = []
    /// rolling buffer の保持秒数（描画用 window と整合）
    private let audioLevelsWindowSec: Double = 4.0
    /// 文字起こしが「無音/未検出」で終わった録音 ID。
    /// 失敗 (lastError) とは別の状態として UI で区別する。
    public private(set) var emptyTranscriptIDs: Set<UUID> = []

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
        self.listState = RecordingListState(repository: repository)
        self.diagnosticsState = DiagnosticsState(
            capture: capture,
            transcription: transcription,
            summary: summary
        )
        // AutoPipelineCoordinator は self メソッドを weak 参照する hooks で組み立てる。
        self.autoPipeline = AutoPipelineCoordinator(
            hooks: .init(
                transcribe: { [weak self] rec in await self?.transcribeRecording(rec) },
                summarize: { [weak self] rec, segs in await self?.summarizeRecording(rec, segments: segs) },
                loadSegments: { [weak self] id in
                    guard let self else { return [] }
                    return (try? await self.repository.loadSegments(for: id)) ?? []
                },
                refreshList: { [weak self] in await self?.refreshList() }
            )
        )
    }

    // 注: `Task` の自動キャンセルは `subscribeToCaptureState()` 再呼び出し時の
    // 既存タスクキャンセルでカバー。`deinit` からは MainActor isolated プロパティに
    // 触れないため、明示的なキャンセル API を View 側から呼ぶ運用とする。

    // MARK: - Error formatting

    /// `lastError` に入れる UI 向けメッセージを構築する。
    ///
    /// 方針:
    /// - case 名 (`String(describing:)`) はユーザーに見せない
    /// - 代わりに **次に何をすればよいか** を日本語で書く
    /// - 詳細は `uiErrorLog` (os.log) に流して開発者だけが見られるようにする
    func userMessage(for error: Error, context: String) -> String {
        // 開発者向けには case 名を含む詳細を残す
        uiErrorLog.error("\(context, privacy: .public): \(String(describing: error), privacy: .public)")

        switch error {
        case let e as AudioCaptureError: return e.localizedUserMessage
        case let e as TranscriptionError: return e.localizedUserMessage
        case let e as SummaryError: return e.localizedUserMessage
        case let e as RepositoryError: return e.localizedUserMessage
        default:
            return "予期しないエラーが発生しました。問題が続く場合はアプリを再起動してください。"
        }
    }

    // MARK: - 自動要約発火条件 (テスト互換シム)

    /// 旧 `static func hasSubstantiveContent` のテスト互換シム。
    /// 実体は `SummaryKit.SubstantiveContentChecker.isSubstantive(segments:)` に移設済み。
    /// View 層は本関数を呼ばない (閾値の知識は SummaryKit に集約)。
    static func hasSubstantiveContent(segments: [TranscriptSegment]) -> Bool {
        SubstantiveContentChecker.isSubstantive(segments: segments)
    }

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

    /// `capture.liveAudioLevels` を **ViewModel が永続的に購読** し、
    /// 直近 window 秒の rolling buffer を `audioLevels` に保持する。
    ///
    /// View 側はこの buffer を読むだけなので、メニューバーポップアップを閉じても
    /// 購読が継続し、再オープン時に空配列にならない。
    /// 通常は LocalVoiceRecApp.init から 1 回だけ呼ぶ運用。
    public func startObservingAudioLevels() {
        audioLevelsTask?.cancel()
        let stream = capture.liveAudioLevels
        let window = audioLevelsWindowSec
        audioLevelsTask = Task { @MainActor [weak self] in
            for await snap in stream {
                guard let self else { break }
                if Task.isCancelled { break }
                self.audioLevels.append(snap)
                // X3.7: 旧実装の `removeAll { ... }` は配列全体を走査して条件付き削除を
                // 行うため、buffer 内の **全要素** に対して closure 評価が走る (O(N))。
                // audioLevels は時系列に単調増加で append されるので、先頭から
                // cutoff 未満の要素を数えて `removeFirst(_:)` で一括除去する方が安い。
                // 通常は 0〜1 件の除去で済むため平均コストは O(1) になる。
                let cutoff = snap.elapsedSec - window
                var drop = 0
                for s in self.audioLevels {
                    if s.elapsedSec < cutoff { drop += 1 } else { break }
                }
                if drop > 0 {
                    self.audioLevels.removeFirst(drop)
                }
            }
        }
    }

    // MARK: - Intents: Permissions

    /// マイク（および可能ならシステム音声）の権限プロンプトを明示的に出す。
    /// `.notDetermined` のときに OS ダイアログを表示する目的。
    /// 既に `.authorized` / `.denied` なら no-op に近い（再描画用に diagnostics は更新）。
    public func requestAudioPermissions() async {
        _ = await capture.requestAuthorization()
        // system audio (Core Audio process tap) は事前 API が無く、
        // 初回の `capture.start()` で OS プロンプトが出る。
        await refreshDiagnostics()
    }

    // MARK: - Intents: Recording lifecycle

    public func startRecording() async {
        isBusy = true
        defer { isBusy = false }
        do {
            // 権限が未要求なら先に OS プロンプトを出す（録音が無音になる事故を防ぐ）。
            // mic / systemAudio (画面収録 TCC) のいずれかが notDetermined なら
            // `requestAuthorization()` を呼び、両プロンプトを順に表示させる。
            let current = await capture.authorizationStatus()
            if current.microphone == .notDetermined || current.systemAudio == .notDetermined {
                _ = await capture.requestAuthorization()
            }
            // 拒否されていたらここで中断
            let after = await capture.authorizationStatus()
            if after.microphone == .denied {
                lastError = "マイク権限が拒否されています。診断パネルから設定を開いて許可してください。"
                await refreshDiagnostics()
                return
            }
            if after.systemAudio == .denied {
                lastError = "画面収録権限（システム音声録音に必要）が拒否されています。システム設定 → プライバシーとセキュリティ → 画面収録 で本アプリを許可してください。"
                await refreshDiagnostics()
                return
            }
            let id = UUID()
            let dir = try AppPaths.recordingDirectory(for: id)
            _ = try await capture.start(in: dir, title: nil)
            captureState = await capture.currentState
            lastError = nil
        } catch {
            lastError = userMessage(for: error, context: "startRecording")
        }
    }

    public func stopRecording() async {
        isBusy = true
        defer { isBusy = false }
        // 停止直前のマイク観測値 (停止後は audioLevels が伸びないため、ここで撮っておく)。
        let micWasActive = audioLevels.contains { $0.micPeak >= AudioLevelSnapshot.silenceThreshold }
        do {
            let recording = try await capture.stop()
            captureState = await capture.currentState
            try await repository.create(recording)
            lastError = nil
            await refreshList()
            // C3: 停止後に systemFlow を確認し、システム音声 tap の IOProc が一度も
            // 発火しなかった場合だけ警告する (= 権限拒否 / HW 異常 の真の問題)。
            //
            // `nonZeroBufferCount == 0` は「IOProc は動いているが全サンプル無音」
            // を意味し、ユーザー側でシステム音声を何も再生しなかった (会議で
            // 自分だけ話していた等) という正常パターンに該当する。これを
            // 警告すると誤検知になるためチェックしない。
            // マイクが録れていない場合は別問題 (権限/HW) として警告を出さない (ノイズになる)。
            let finalFlow = await capture.systemFlowSnapshot()
            if micWasActive,
               let flow = finalFlow,
               flow.bytesReceived == 0 {
                lastError = "システム音声 tap が起動できませんでした。画面収録権限を確認してください（システム設定 → プライバシーとセキュリティ）"
            }
            // 診断パネルの systemFlow も最新化しておく
            await refreshDiagnostics()
            // 自動で文字起こし → 要約のパイプラインを開始（fire-and-forget）
            autoPipeline.run(for: recording)
        } catch {
            lastError = userMessage(for: error, context: "stopRecording")
        }
    }

    public func pauseRecording() async {
        do {
            try await capture.pause()
            captureState = await capture.currentState
            lastError = nil
        } catch {
            lastError = userMessage(for: error, context: "pauseRecording")
        }
    }

    public func resumeRecording() async {
        do {
            try await capture.resume()
            captureState = await capture.currentState
            lastError = nil
        } catch {
            lastError = userMessage(for: error, context: "resumeRecording")
        }
    }

    // MARK: - Intents: List / Detail

    /// 進行中フラグのスナップショットを `RecordingListState` 用に組む。
    private func currentInProgressFlags() -> RecordingListState.InProgressFlags {
        .init(
            transcribingIDs: transcribingIDs,
            summarizingIDs: summarizingIDs,
            emptyTranscriptIDs: emptyTranscriptIDs
        )
    }

    public func refreshList() async {
        do {
            try await listState.refresh(flags: currentInProgressFlags())
            lastError = nil
        } catch {
            lastError = userMessage(for: error, context: "refreshList")
        }
    }

    /// 一覧表示用に、指定録音の現在状態を返す。
    public func status(for id: UUID) -> RecordingStatus {
        listState.status(for: id, flags: currentInProgressFlags())
    }

    /// 入力デバウンス付きの検索エントリポイント。
    ///
    /// A12: `.searchable` が毎キーストロークで `search(query:)` を直接叩く UX 問題に対応。
    /// 実装は `RecordingListState.searchDebounced` に委譲。
    public func searchDebounced(query: String) {
        listState.searchDebounced(
            query: query,
            flagsProvider: { [weak self] in
                self?.currentInProgressFlags() ?? .init(
                    transcribingIDs: [], summarizingIDs: [], emptyTranscriptIDs: []
                )
            },
            onError: { [weak self] error in
                self?.lastError = self?.userMessage(for: error, context: "searchDebounced")
            }
        )
    }

    public func search(query: String) async {
        do {
            try await listState.search(query: query)
            lastError = nil
        } catch {
            lastError = userMessage(for: error, context: "search")
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
            // X2.1: TOCTOU ガード — 並行ロード中にユーザーが別録音を選び直したら、
            // 後着の結果を反映しない (別録音の segments/summary が出てしまう問題を防止)。
            // transcribeRecording / summarizeRecording 内の同種ガードと整合。
            guard selectedRecording?.id == recording.id else { return }
            segments = loadedSegments.sorted { $0.startSec < $1.startSec }
            summaryDocument = loadedSummary
            summaryAvailability = await summary.availability()
            // availability() 中にも別録音に切り替わった可能性をケア
            guard selectedRecording?.id == recording.id else { return }
            lastError = nil

            // ─── 自動文字起こしトリガ（ユーザー要望: 文字起こしは自動 UX）───
            // 条件:
            //   1. segments が空
            //   2. すでに進行中のパイプラインが無い
            //   3. このセッションでまだ自動試行していない（無限ループ防止）
            if loadedSegments.isEmpty,
               !autoPipeline.isRunning(for: recording.id),
               !autoPipeline.hasAttemptedAutoTranscribe(for: recording.id) {
                autoPipeline.markAutoTranscribeAttempted(for: recording.id)
                autoPipeline.run(for: recording)
            } else if !loadedSegments.isEmpty,
                      loadedSummary == nil,
                      case .available = summaryAvailability,
                      summarizingIDs.contains(recording.id) == false,
                      !autoPipeline.hasAttemptedAutoTranscribe(for: recording.id) {
                // segments はあるが要約だけ無い → 要約のみ自動実行
                autoPipeline.markAutoTranscribeAttempted(for: recording.id)
                let target = loadedSegments.sorted { $0.startSec < $1.startSec }
                Task { @MainActor [weak self] in
                    await self?.summarizeRecording(recording, segments: target)
                }
            }
        } catch {
            lastError = userMessage(for: error, context: "select")
        }
    }

    public func clearSelection() {
        selectedRecording = nil
        segments = []
        summaryDocument = nil
    }

    // MARK: - Intents: Transcription

    /// 指定録音を文字起こしし、結果を repository に保存する。
    /// 選択中の録音であれば `segments` を逐次更新して UI に反映する。
    ///
    /// 既に segments を持つ録音に対しても呼べる（再実行）。
    ///
    /// 設計メモ:
    /// - 進行中フラグは `transcribingIDs` (Set) に id を入れる方式。複数録音同時可。
    /// - `RecordingRepositoryImpl.saveSegments` は置換セマンティクスなので、
    ///   ここで事前に `deleteSegments` を呼ぶ必要なし。**失敗時の意図せぬデータ消失も防ぐ。**
    /// - `isFinal == true` のものを永続化するが、final が一切来なかった場合は
    ///   collected を fallback として保存する（無音録音 / モデル quirk 対策）。
    public func transcribeRecording(_ recording: Recording, locale: Locale? = nil) async {
        guard !transcribingIDs.contains(recording.id) else { return }
        // 手動で押されたら自動試行フラグはクリア（再試行を解禁）
        autoPipeline.clearAttempted(for: recording.id)
        transcribingIDs.insert(recording.id)
        defer { transcribingIDs.remove(recording.id) }

        // UI 上のクリアだけ。永続化レイヤは saveSegments の置換に任せる。
        if selectedRecording?.id == recording.id {
            segments = []
        }

        // X3.2: collected は到着順を保持し、segments (UI 用) は insertion-sort で挿入する。
        // 旧実装は 1 segment 到着ごとに `collected.sorted(by:)` を呼んでおり、
        // N 個受信する間に O(N² log N) のソートが走っていた。Speech は概ね time order で
        // 流すが、確定タイミングが前後する可能性があるため整合性のため挿入位置探索は
        // 末尾線形 (新しいものほど末尾に来やすい仮定で平均 O(1) に近い) を採る。
        //
        // さらに UI 更新は 200ms 以上経過したタイミングだけに間引き、@Observable の
        // 再描画頻度を抑える (バーストで segment が来る間の中間描画を省く)。
        var collected: [TranscriptSegment] = []
        let isSelected = { [weak self] in self?.selectedRecording?.id == recording.id }
        do {
            var sortedForUI: [TranscriptSegment] = []
            var lastUIFlush = ContinuousClock.now
            let uiFlushInterval: Duration = .milliseconds(200)
            for try await segment in transcription.transcribe(recording: recording, locale: locale) {
                collected.append(segment)
                if isSelected() {
                    // 末尾から挿入位置を探す (最新の startSec は通常末尾に近い)。
                    var idx = sortedForUI.count
                    while idx > 0 && sortedForUI[idx - 1].startSec > segment.startSec {
                        idx -= 1
                    }
                    sortedForUI.insert(segment, at: idx)

                    // 200ms ごとに UI へ flush。最後の 1 件は break 後にコミットされる。
                    let now = ContinuousClock.now
                    if now - lastUIFlush >= uiFlushInterval {
                        segments = sortedForUI
                        lastUIFlush = now
                    }
                }
            }
            // ループ終了時に未 flush 分があれば反映 (`==` は Duration を比較できないので
            // 端数なくキャッチアップ目的で常に代入)。
            if isSelected() {
                segments = sortedForUI
            }
            // isFinal == true のものを優先。0 件なら collected を fallback（UX 退行防止）。
            // X3.2: 既に collected 全件が必要なので、ここでの最終 sort は 1 回だけ走る。
            let finalized = collected.filter(\.isFinal).sorted { $0.startSec < $1.startSec }
            let preDedup = finalized.isEmpty ? collected.sorted { $0.startSec < $1.startSec } : finalized
            // 録音冒頭の SpeechAnalyzer 幻覚 (「相手 00:00:00 あ」) を除外。
            let preEcho = PhantomLeadingSegmentFilter.drop(segments: preDedup)
            // File-based 経路では cross-channel echo を検出してマーク。
            // (Live 経路では全 segment が揃わないため、ここでは適用しない)
            let toPersist = CrossChannelEchoMarker.markEchoes(segments: preEcho)

            if toPersist.isEmpty {
                // 完全に何も拾えなかった = 無音か未対応言語の可能性。既存データは消さない。
                emptyTranscriptIDs.insert(recording.id)
                if selectedRecording?.id == recording.id {
                    segments = (try? await repository.loadSegments(for: recording.id)) ?? []
                }
                return
            }

            emptyTranscriptIDs.remove(recording.id)
            try await repository.saveSegments(toPersist, for: recording.id)
            if selectedRecording?.id == recording.id {
                segments = toPersist
            }
            lastError = nil
        } catch {
            lastError = userMessage(for: error, context: "transcribeRecording")
            // 失敗時は repository から既存 segments を復元して、過去データが消えたように見せない
            if selectedRecording?.id == recording.id {
                segments = (try? await repository.loadSegments(for: recording.id)) ?? []
            }
        }
    }

    // MARK: - Intents: Summary

    /// 指定録音について要約を生成し、repository に保存する。
    /// `segments` が空のときは何もしない。
    public func summarizeRecording(_ recording: Recording, segments: [TranscriptSegment]? = nil) async {
        let target = segments ?? self.segments
        guard !target.isEmpty else { return }
        guard !summarizingIDs.contains(recording.id) else { return }

        // availability を最新化
        summaryAvailability = await summary.availability()
        guard case .available = summaryAvailability else {
            lastError = "要約サービスが利用できません"
            return
        }

        summarizingIDs.insert(recording.id)
        defer { summarizingIDs.remove(recording.id) }

        do {
            let newSummary = try await summary.generate(
                from: target,
                recordingID: recording.id
            )
            try await repository.saveSummary(newSummary)
            if selectedRecording?.id == recording.id {
                summaryDocument = newSummary
            }
            lastError = nil
        } catch {
            lastError = userMessage(for: error, context: "summarizeRecording")
        }
    }

    public func regenerateSummary(hint: String? = nil) async {
        guard let recording = selectedRecording else { return }
        guard !segments.isEmpty else {
            lastError = "文字起こしがまだありません。先に文字起こしを実行してください。"
            return
        }
        guard !summarizingIDs.contains(recording.id) else { return }

        // availability を最新化
        summaryAvailability = await summary.availability()
        guard case .available = summaryAvailability else {
            lastError = "要約サービスが利用できません"
            return
        }

        summarizingIDs.insert(recording.id)
        defer { summarizingIDs.remove(recording.id) }

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
            lastError = userMessage(for: error, context: "regenerateSummary")
        }
    }

    // MARK: - Intents: Export

    /// Repository から最新の segments / summary を読み出し、`MeetingMinutes` を構築する。
    ///
    /// View 層は `.fileExporter` のドキュメント生成時にこのメソッドを呼ぶ。
    /// 失敗時は throws する（呼び出し側で `lastError` への反映を行う）。
    func makeMinutes(for recording: Recording) async throws -> MeetingMinutes {
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
    func exportText(for recording: Recording, format: ExportFormat) async throws -> String {
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
    func reportExportFailure(_ message: String) {
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
            lastError = userMessage(for: error, context: "deleteRecording")
        }
    }

    // MARK: - Intents: Diagnostics

    /// 診断情報（権限・locale・要約 availability）を取得し直す。
    /// View 側の `.task` で初回 + 「更新」ボタンで再取得する。
    /// 実装は `DiagnosticsState.refresh()` に委譲。
    public func refreshDiagnostics() async {
        await diagnosticsState.refresh()
    }

    // MARK: - Intents: Bulk retry

    /// `pending` / `emptyTranscript` / `failed` 状態の録音すべてに対して順に
    /// `transcribeRecording` を呼ぶ。失敗してもループは継続する。
    public func retryAllPendingTranscriptions() async {
        // 現在のスナップショットを撮ってからループ（途中で recordings が変わるのを避ける）
        let snapshot = recordings
        for recording in snapshot {
            let status = self.status(for: recording.id)
            switch status {
            case .pending, .emptyTranscript, .failed:
                await transcribeRecording(recording)
            case .transcribing, .summarizing, .transcribed, .completed:
                continue
            }
        }
        await refreshList()
    }

    // MARK: - Derived state helpers

    /// 録音中相当か（recording / paused / preparing / finalizing / interrupted）
    public var isCapturing: Bool {
        switch captureState {
        case .recording, .paused, .preparing, .finalizing, .interrupted:
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
        case .idle, .preparing, .paused, .finalizing, .failed, .interrupted:
            return false
        }
    }

    /// 一時停止中
    public var isPaused: Bool {
        switch captureState {
        case .paused:
            return true
        case .idle, .preparing, .recording, .finalizing, .failed, .interrupted:
            return false
        }
    }
}

// `DiagnosticsInfo` 構造体は Z1 で `Sources/AppUI/ViewModels/DiagnosticsState.swift` に移動済み。
