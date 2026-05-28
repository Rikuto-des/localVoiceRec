import Foundation
import Observation
import os
import Contracts
import TranscriptionKit

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

    /// 診断パネル用の情報（権限 / 利用可能 locale / 要約サービス状況）。
    public private(set) var diagnostics: DiagnosticsInfo = .empty

    /// `subscribeToCaptureState()` で開始した監視タスク。
    private var stateSubscriptionTask: Task<Void, Never>?
    /// `subscribeToAudioLevels()` で開始した監視タスク。
    private var audioLevelsTask: Task<Void, Never>?
    /// 進行中の自動パイプライン (録音 ID → Task)
    private var pipelineTasks: [UUID: Task<Void, Never>] = [:]
    /// `select` 経由で 1 回だけ自動 transcribe を試行済みの録音 ID。
    /// 手動「文字起こしを実行」が押されたらクリアして再試行を許可する。
    private var autoTranscribeAttempted: Set<UUID> = []

    /// search debounce 用の進行中タスク。次のキーストロークで cancel される。
    /// A12: 毎キーストローク fetch で SwiftData が刻まれる問題への対策。
    private var pendingSearchTask: Task<Void, Never>?

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
    /// 一覧表示用の、録音 ID ごとの状態キャッシュ（refreshList で更新）。
    public private(set) var recordingStatuses: [UUID: RecordingStatus] = [:]

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
        case let captureError as AudioCaptureError:
            switch captureError {
            case .microphonePermissionDenied:
                return "マイクへのアクセス許可が必要です。システム設定 → プライバシーとセキュリティ → マイク で localVoiceRec を有効にしてください。"
            case .systemAudioPermissionDenied:
                return "システム音声を録音するには画面収録の許可が必要です。システム設定 → プライバシーとセキュリティ → 画面とシステムオーディオの収録 で localVoiceRec を有効にしてください。"
            case .engineStartFailed:
                return "オーディオエンジンを起動できませんでした。他のアプリがマイクを占有していないか確認し、再試行してください。"
            case .processTapCreateFailed, .aggregateDeviceCreateFailed:
                return "システム音声の取得に失敗しました。アプリを再起動するか、Mac を再起動して再試行してください。"
            case .alreadyRecording:
                return "既に録音中です。先に現在の録音を停止してください。"
            case .notRecording:
                return "録音は開始されていません。"
            case .fileWriteFailed:
                return "録音ファイルの書き込みに失敗しました。空き容量と書き込み権限を確認してください。"
            case .outputDirectoryUnavailable:
                return "録音保存先フォルダにアクセスできません。アプリの保存先設定を確認してください。"
            case .diskWriteFailure(let failureCount):
                return "録音ファイルの書き込みエラーが \(failureCount) 回連続で発生したため録音を停止しました。ディスクの空き容量と書き込み権限を確認してください。"
            }

        case let transcriptionError as TranscriptionError:
            switch transcriptionError {
            case .unsupportedLocale:
                return "選択された言語の文字起こしに対応していません。診断パネルでインストール済み Locale を確認してください。"
            case .assetInstallationFailed:
                return "文字起こしに必要なモデルのインストールに失敗しました。ネットワーク接続を確認して再試行してください。"
            case .analyzerFailed:
                return "文字起こし処理が中断されました。録音ファイルを確認し、再実行してください。"
            case .fileNotReadable:
                return "録音ファイルを読み込めません。ファイルが移動・削除されていないか確認してください。"
            case .cancelled:
                return "文字起こしはキャンセルされました。"
            }

        case let summaryError as SummaryError:
            switch summaryError {
            case .notAvailable:
                return "要約サービスが利用できません。Apple Intelligence の設定とモデルのダウンロード状況を確認してください。"
            case .generationFailed:
                return "要約の生成に失敗しました。少し待ってから再試行してください。"
            case .contextWindowExceeded:
                return "録音内容が要約モデルの上限を超えています。録音を分割するか、短い区間で再試行してください。"
            case .cancelled:
                return "要約生成はキャンセルされました。"
            case .decodingFailed:
                return "要約の解析に失敗しました。もう一度生成を試してください。"
            }

        case let repoError as RepositoryError:
            switch repoError {
            case .notFound:
                return "対象の録音が見つかりませんでした。一覧を更新してください。"
            case .ioFailed:
                return "データの読み書きに失敗しました。空き容量とアクセス権限を確認してください。"
            case .storeUnavailable:
                return "データストアにアクセスできません。アプリを再起動してください。"
            case .fileDeletionFailed:
                return "ファイルの削除に失敗しました。手動で Finder から削除してください。"
            }

        default:
            return "予期しないエラーが発生しました。問題が続く場合はアプリを再起動してください。"
        }
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
                let cutoff = snap.elapsedSec - window
                self.audioLevels.removeAll { $0.elapsedSec < cutoff }
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
            // C3: 停止後に systemFlow を確認し、システム音声だけが完全無音だった場合に警告。
            // マイクが録れていない場合は別問題 (権限/HW) として警告を出さない (ノイズになる)。
            let finalFlow = await capture.systemFlowSnapshot()
            if micWasActive,
               let flow = finalFlow,
               (flow.bytesReceived == 0 || flow.nonZeroBufferCount == 0) {
                lastError = "システム音声が記録されませんでした。画面収録権限を確認してください（システム設定 → プライバシーとセキュリティ）"
            }
            // 診断パネルの systemFlow も最新化しておく
            await refreshDiagnostics()
            // 自動で文字起こし → 要約のパイプラインを開始（fire-and-forget）
            runAutoPipeline(for: recording)
        } catch {
            lastError = userMessage(for: error, context: "stopRecording")
        }
    }

    /// 自動要約を発火させるかの判定。
    ///
    /// Foundation Models (on-device 3B) は入力が極端に薄いと、もっともらしい内容を
    /// 捏造する (ハルシネーション)。例: 「うん」「あ」のような相槌だけの transcript で
    /// 「予算編成」「コスト削減」等の架空の議論内容を生成する。
    ///
    /// 自動要約は実コンテンツが一定量ある場合に限定する。閾値は実利テスト由来で
    /// **空白除去後 60 文字以上 かつ 5 セグメント以上** とする。これ未満の場合は
    /// 手動「要約を再生成」ボタンを押した時のみ要約する (ユーザーが明示的に判断)。
    static func hasSubstantiveContent(segments: [TranscriptSegment]) -> Bool {
        guard segments.count >= 5 else { return false }
        let totalChars = segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).count }
            .reduce(0, +)
        return totalChars >= 60
    }

    /// 録音停止後（および select で空 segments のとき）に呼ばれる、
    /// 文字起こし→要約の自動パイプライン。バックグラウンドで走る。
    private func runAutoPipeline(for recording: Recording) {
        pipelineTasks[recording.id]?.cancel()
        let task = Task { @MainActor [weak self] in
            // cancel パスでも必ずエントリ掃除 + 一覧バッジ更新
            defer {
                self?.pipelineTasks.removeValue(forKey: recording.id)
                Task { @MainActor [weak self] in await self?.refreshList() }
            }
            guard let self else { return }
            await self.transcribeRecording(recording)
            guard !Task.isCancelled else { return }
            // 要約は実コンテンツが一定量ある場合のみ自動発火する (ハルシネーション防止)。
            // 薄い入力でも手動「要約を再生成」ボタンからは実行可能。
            let saved = (try? await self.repository.loadSegments(for: recording.id)) ?? []
            if Self.hasSubstantiveContent(segments: saved) {
                await self.summarizeRecording(recording, segments: saved)
            }
        }
        pipelineTasks[recording.id] = task
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

    public func refreshList() async {
        do {
            // N+1 を避けるため、録音 + segments/summary の存在フラグを 1 fetch で取得する。
            let rows = try await repository.listWithStatus(limit: nil, offset: nil)
            var newRecordings: [Recording] = []
            newRecordings.reserveCapacity(rows.count)
            var map: [UUID: RecordingStatus] = [:]
            for row in rows {
                let r = row.recording
                newRecordings.append(r)
                if transcribingIDs.contains(r.id) {
                    map[r.id] = .transcribing
                } else if summarizingIDs.contains(r.id) {
                    map[r.id] = .summarizing
                } else if !row.hasSegments {
                    map[r.id] = emptyTranscriptIDs.contains(r.id) ? .emptyTranscript : .pending
                } else if row.hasSummary {
                    map[r.id] = .completed
                } else {
                    map[r.id] = .transcribed
                }
            }
            recordings = newRecordings
            recordingStatuses = map
            lastError = nil
        } catch {
            lastError = userMessage(for: error, context: "refreshList")
        }
    }

    /// 一覧表示用に、指定録音の現在状態を返す。
    public func status(for id: UUID) -> RecordingStatus {
        if transcribingIDs.contains(id) { return .transcribing }
        if summarizingIDs.contains(id) { return .summarizing }
        if emptyTranscriptIDs.contains(id), recordingStatuses[id] == nil {
            return .emptyTranscript
        }
        return recordingStatuses[id] ?? .pending
    }

    /// 入力デバウンス付きの検索エントリポイント。
    ///
    /// A12: `.searchable` が毎キーストロークで `search(query:)` を直接叩く UX 問題に対応。
    /// 進行中の検索タスクをキャンセルし、300ms 待ってからスナップショットされた最新の
    /// クエリで実行する。空文字なら `refreshList` を呼ぶ。
    public func searchDebounced(query: String) {
        pendingSearchTask?.cancel()
        let trimmed = query
        pendingSearchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            guard let self else { return }
            if trimmed.isEmpty {
                await self.refreshList()
            } else {
                await self.search(query: trimmed)
            }
        }
    }

    public func search(query: String) async {
        do {
            recordings = try await repository.search(query: query)
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
            segments = loadedSegments.sorted { $0.startSec < $1.startSec }
            summaryDocument = loadedSummary
            summaryAvailability = await summary.availability()
            lastError = nil

            // ─── 自動文字起こしトリガ（ユーザー要望: 文字起こしは自動 UX）───
            // 条件:
            //   1. segments が空
            //   2. すでに進行中のパイプラインが無い
            //   3. このセッションでまだ自動試行していない（無限ループ防止）
            if loadedSegments.isEmpty,
               pipelineTasks[recording.id] == nil,
               !autoTranscribeAttempted.contains(recording.id) {
                autoTranscribeAttempted.insert(recording.id)
                runAutoPipeline(for: recording)
            } else if !loadedSegments.isEmpty,
                      loadedSummary == nil,
                      case .available = summaryAvailability,
                      summarizingIDs.contains(recording.id) == false,
                      !autoTranscribeAttempted.contains(recording.id) {
                // segments はあるが要約だけ無い → 要約のみ自動実行
                autoTranscribeAttempted.insert(recording.id)
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
        autoTranscribeAttempted.remove(recording.id)
        transcribingIDs.insert(recording.id)
        defer { transcribingIDs.remove(recording.id) }

        // UI 上のクリアだけ。永続化レイヤは saveSegments の置換に任せる。
        if selectedRecording?.id == recording.id {
            segments = []
        }

        var collected: [TranscriptSegment] = []
        do {
            for try await segment in transcription.transcribe(recording: recording, locale: locale) {
                collected.append(segment)
                if selectedRecording?.id == recording.id {
                    segments = collected.sorted { $0.startSec < $1.startSec }
                }
            }
            // isFinal == true のものを優先。0 件なら collected を fallback（UX 退行防止）。
            let finalized = collected.filter(\.isFinal).sorted { $0.startSec < $1.startSec }
            let preDedup = finalized.isEmpty ? collected.sorted { $0.startSec < $1.startSec } : finalized
            // File-based 経路では cross-channel echo を検出してマーク。
            // (Live 経路では全 segment が揃わないため、ここでは適用しない)
            let toPersist = SegmentDeduplicator.markEchoes(segments: preDedup)

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
    public func refreshDiagnostics() async {
        let auth = await capture.authorizationStatus()
        let locales = await transcription.installedLocales()
        let summary = await self.summary.availability()
        let systemFlow = await capture.systemFlowSnapshot()
        diagnostics = DiagnosticsInfo(
            micAuthorization: auth.microphone,
            systemAudioAuthorization: auth.systemAudio,
            installedLocales: locales.map(\.identifier),
            summaryAvailability: summary,
            systemFlow: systemFlow
        )
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

// MARK: - Diagnostics

/// 診断パネルで表示する情報のスナップショット。
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
