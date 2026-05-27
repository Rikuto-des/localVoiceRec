import Foundation
@preconcurrency import AVFAudio
@preconcurrency import AVFoundation
import Contracts
import AudioTapKit
import os.log
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// 本番 `AudioCaptureService` 実装。
///
/// ## 設計
/// - actor で状態を保護。`stateUpdates` は nonisolated AsyncStream で外部へ通知。
/// - `MicCapture` と `SystemAudioTap` から得る `AsyncStream<AVAudioPCMBuffer>` を
///   detached Task で消費し、`WAVFileWriter` に書き込む。
/// - `pause()/resume()` は `Atomic<Bool>` ベースの書き込みフラグで切替。
///   ハードウェアは止めない (PCM はリングバッファに流れ続けるが、writer をスキップする)。
/// - 失敗時のクリーンアップを徹底し、状態が崩れたまま再 start できなくならないようにする。
///
/// ## レベルメーター (S10-A)
/// - 各 consumer Task は `WriterSink.write` → `LevelAccumulator.add(buffer)` も呼ぶ。
/// - 別の emit Task が 100ms ごとに mic / system の RMS / Peak をスナップショットし、
///   `levelContinuation.yield(...)` する。`Task.sleep` ベースなので録音停止時に cancel する。
///
/// ## 並行性
/// - actor 自体は `Sendable` (Swift 6)。`MicCapture` / `SystemAudioTap` は `@unchecked Sendable`。
/// - consumer Task は `Task.detached` で起こし、actor の状態を直接触らずに自己完結する。
///   writer / pause flag は box 経由で共有 (`WriterSink`)。
public actor AudioCaptureServiceImpl: AudioCaptureService {

    // MARK: - Logger

    private static let logger = Logger(subsystem: "com.example.localVoiceRec", category: "audio")

    // MARK: - State stream

    private let stateContinuation: AsyncStream<CaptureState>.Continuation
    private nonisolated let stateStream: AsyncStream<CaptureState>

    public nonisolated var stateUpdates: AsyncStream<CaptureState> { stateStream }

    // MARK: - Audio level stream

    private let levelContinuation: AsyncStream<AudioLevelSnapshot>.Continuation
    private nonisolated let levelStream: AsyncStream<AudioLevelSnapshot>

    public nonisolated var liveAudioLevels: AsyncStream<AudioLevelSnapshot> { levelStream }

    // MARK: - Live transcript stream (P4.2)

    /// 録音中 fan-out で投機 ASR から流れてくる isFinal セグメント。
    /// `transcription` を init 時に渡し、`liveTranscriptionEnabled == true` の場合のみ
    /// 実値が yield される。それ以外は録音停止に合わせて空のまま終わる。
    private let liveTranscriptContinuation: AsyncStream<TranscriptSegment>.Continuation
    private nonisolated let liveTranscriptStream: AsyncStream<TranscriptSegment>

    public nonisolated var liveTranscripts: AsyncStream<TranscriptSegment> { liveTranscriptStream }

    /// Live ASR (録音中 fan-out → SpeechAnalyzer) 用の依存。nil なら live ASR は使わない。
    private let liveTranscription: (any TranscriptionService)?
    /// Live ASR を使うかどうか。`liveTranscription` が non-nil かつこのフラグが true のときに有効。
    private let liveTranscriptionEnabled: Bool
    /// Live ASR の locale。nil ならシステムデフォルト。
    private let liveTranscriptionLocale: Locale?

    private var _currentState: CaptureState = .idle
    public var currentState: CaptureState { _currentState }

    // MARK: - Active session

    /// 現在録音中のリソース束。`nil` なら idle。
    private var active: ActiveSession?

    // MARK: - System notification observers (sleep / wake)

    /// `NSWorkspace.willSleepNotification` 監視トークン。actor 初期化時に install し、
    /// deinit で remove する。録音中以外は no-op で受け流す。
    /// notification handler は任意スレッドで呼ばれるため、`Task { await self.handleInterruption(...) }`
    /// で actor に hop してから状態更新する。
    private nonisolated(unsafe) var willSleepObserver: NSObjectProtocol?
    private nonisolated(unsafe) var didWakeObserver: NSObjectProtocol?
    private let observersLock = NSLock()

    // MARK: - Init

    /// 既定 init: live ASR を使わない (post-stop transcribe を従来どおり使うクライアント向け)。
    public init() {
        self.init(liveTranscription: nil, liveTranscriptionEnabled: false, liveTranscriptionLocale: nil)
    }

    /// Live ASR (P4.2) 対応 init。`liveTranscription` を渡すと録音中の fan-out で
    /// 同時にストリーミング文字起こしが走り、結果は `liveTranscripts` AsyncStream に
    /// 流れる。`liveTranscriptionEnabled = false` の場合は依存だけ受け取って何もしない
    /// (後方互換のため existing call site から段階的に切り替え可能)。
    public init(
        liveTranscription: (any TranscriptionService)?,
        liveTranscriptionEnabled: Bool,
        liveTranscriptionLocale: Locale?
    ) {
        self.liveTranscription = liveTranscription
        self.liveTranscriptionEnabled = liveTranscriptionEnabled && liveTranscription != nil
        self.liveTranscriptionLocale = liveTranscriptionLocale

        // bufferingPolicy: 旧実装は `.unbounded` だったが、現状 UI は live transcript を
        // 購読していない (P4.5 で撤去)。consumer なしで `.unbounded` だと segment が
        // 永続的に actor (= アプリ寿命) 内に積まれてしまうため、上限を 100 に絞り
        // 古いものから捨てる方針に変更。将来 live ASR UI を再導入した際にも
        // 「最新の文脈のみ」あれば十分。
        var liveCaptured: AsyncStream<TranscriptSegment>.Continuation!
        self.liveTranscriptStream = AsyncStream<TranscriptSegment>(
            bufferingPolicy: .bufferingNewest(100)
        ) { liveCaptured = $0 }
        self.liveTranscriptContinuation = liveCaptured

        var captured: AsyncStream<CaptureState>.Continuation!
        self.stateStream = AsyncStream<CaptureState>(
            bufferingPolicy: .bufferingNewest(1)
        ) { captured = $0 }
        self.stateContinuation = captured
        // 初期値を 1 件積んでおく → 初回購読者が現在状態を取得できる
        captured.yield(.idle)

        var levelCaptured: AsyncStream<AudioLevelSnapshot>.Continuation!
        self.levelStream = AsyncStream<AudioLevelSnapshot>(
            bufferingPolicy: .bufferingNewest(2)
        ) { levelCaptured = $0 }
        self.levelContinuation = levelCaptured

        // ── スリープ / 復帰の購読 ──
        // NSWorkspace.shared.notificationCenter は OS スリープ前後のイベントを配信する。
        // 録音中にスリープに入ると IOProc / AVAudioEngine が暗黙停止し、
        // 復帰しても自動再開されないことがある (ハードウェア構成にも依存)。
        // ここで観測し、`interrupted(.systemWillSleep)` に遷移させてユーザーに通知する。
        #if canImport(AppKit)
        let nc = NSWorkspace.shared.notificationCenter
        let willSleep = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleInterruption(reason: .systemWillSleep) }
        }
        let didWake = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            // 復帰時は自動再開しない方針。UI が `.interrupted` を見て
            // ユーザーに明示的な操作 (停止 or 新規開始) を促す。
            Self.logger.info("NSWorkspace.didWakeNotification: 録音は再開しません — ユーザー操作待ち")
        }
        observersLock.lock()
        willSleepObserver = willSleep
        didWakeObserver = didWake
        observersLock.unlock()
        #endif
    }

    deinit {
        #if canImport(AppKit)
        observersLock.lock()
        let w = willSleepObserver
        let d = didWakeObserver
        willSleepObserver = nil
        didWakeObserver = nil
        observersLock.unlock()
        let nc = NSWorkspace.shared.notificationCenter
        if let w { nc.removeObserver(w) }
        if let d { nc.removeObserver(d) }
        #endif
    }

    // MARK: - Interruption handling

    /// 録音中に外部要因 (スリープ / HW 切替 / IOProc 停止) で中断された場合に呼ぶ。
    /// 状態を `.interrupted(reason:)` に遷移させ、書き込みを止める (ハードウェアは
    /// 既に止まっている可能性があるが、念のため明示停止する)。
    /// 上位 (UI) は `stateUpdates` を経由してこの遷移を観測し、ユーザーに通知する。
    func handleInterruption(reason: InterruptionReason) {
        guard let active else { return }
        let startedAt: Date
        switch _currentState {
        case .recording(let t): startedAt = t
        case .paused(let t, _): startedAt = t
        case .interrupted:
            // 既に interrupted — 冪等
            return
        default:
            return
        }
        Self.logger.info("AudioCaptureServiceImpl.handleInterruption: reason=\(String(describing: reason))")
        // 書き込みは止める (ハードウェアは reason 別で振る舞いが違うため触らない)
        active.micSink.setPaused(true)
        active.systemSink.setPaused(true)
        transition(to: .interrupted(reason: reason, startedAt: startedAt, interruptedAt: Date()))
    }

    /// Disk watchdog から呼ばれる。ディスク書き込みが連続失敗したケースで、
    /// 録音継続しても無音ファイルが伸びるだけなので `.failed` に遷移させて
    /// ハードウェア / writer を停止する。
    /// 上位 (UI) は `stateUpdates` で `.failed(.diskWriteFailure)` を観測し、
    /// ユーザーに「ディスク容量を確認してください」等の通知を出す。
    func handleDiskWriteFailure(failureCount: Int) {
        guard let active else { return }
        switch _currentState {
        case .recording, .paused:
            break
        default:
            return
        }
        Self.logger.error("AudioCaptureServiceImpl.handleDiskWriteFailure: failureCount=\(failureCount)")
        // 書き込みを止め、ハードウェアも停止する。`stop()` 相当のクリーンアップは行わず、
        // active のクリアは `.failed` 観測後にユーザー操作 (新規 start) で上書きされる前提。
        active.micSink.setPaused(true)
        active.systemSink.setPaused(true)
        active.mic.stop()
        active.tap.stop()
        active.levelEmitTask.cancel()
        active.watchdogTask.cancel()
        active.diskWatchdogTask.cancel()
        // writer を閉じてファイルを flush しておく (途中までは有効なデータ)
        active.micSink.close()
        active.systemSink.close()
        transition(to: .failed(error: .diskWriteFailure(failureCount: failureCount)))
        self.active = nil
    }

    // MARK: - State transition

    private func transition(to next: CaptureState) {
        guard next != _currentState else { return }
        _currentState = next
        stateContinuation.yield(next)
    }

    // MARK: - Authorization

    public func authorizationStatus() async -> AudioAuthorizationStatus {
        let mic = Self.mapAVAuthStatus(AVCaptureDevice.authorizationStatus(for: .audio))
        // System Audio (Core Audio process tap) は事前 query API が無いが、
        // **画面収録権限 (TCC: ScreenCapture)** は process tap の前提条件として
        // 同じ TCC スイッチで制御されている。CGPreflightScreenCaptureAccess() は
        // - true: TCC で画面収録が許可されている (= process tap も使える前提)
        // - false: 未許可 / 未要求
        // を返す。プロンプトは出さない (= preflight)。
        //
        // 動作確認方法:
        //   1. システム設定 → プライバシーとセキュリティ → 画面収録 で本アプリを
        //      OFF にして再起動 → preflight が false → `.notDetermined` (実績なし時)
        //   2. ON にして再起動 → preflight が true → `.authorized`
        //
        // Sandbox 環境について: 過去の検証で App Sandbox + Hardened Runtime 配下でも
        // CGPreflight/CGRequestScreenCaptureAccess は機能することを確認済み
        // (entitlements は不要。TCC へのアクセスのみ)。
        //
        // フォールバック: preflight が false でも、過去に non-zero audio を取得できた
        // 実績 (`SystemAudioCaptureFlag`) があれば `.authorized` 扱いにする
        // (TCC キャッシュずれの保険)。
        let systemState: AudioAuthorizationStatus.State
        #if canImport(CoreGraphics)
        if CGPreflightScreenCaptureAccess() {
            systemState = .authorized
        } else if SystemAudioCaptureFlag.everCaptured() {
            systemState = .authorized
        } else {
            systemState = .notDetermined
        }
        #else
        systemState = SystemAudioCaptureFlag.everCaptured() ? .authorized : .notDetermined
        #endif
        return AudioAuthorizationStatus(microphone: mic, systemAudio: systemState)
    }

    @discardableResult
    public func requestAuthorization() async -> AudioAuthorizationStatus {
        // マイクのみ事前要求できる。
        let micGranted: Bool = await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
        let mic: AudioAuthorizationStatus.State = micGranted ? .authorized : .denied

        // 画面収録権限を明示的に要求する。CGRequestScreenCaptureAccess() は同期 API で
        // - 既に許可済み → true を即返す (プロンプトなし)
        // - 未要求/拒否 → TCC プロンプトを出して結果を返す (false の場合は「設定アプリ
        //   を開く必要あり」状態。CGRequest は OS に依存して再プロンプトしないことが多い)
        // process tap (システム音声録音) は同じ TCC スイッチで制御されているため、
        // ここで明示要求しておくことで初回録音時の「無音問題」を回避できる。
        //
        // 動作確認方法:
        //   1. TCC リセット: `tccutil reset ScreenCapture com.example.localVoiceRec`
        //   2. アプリ起動 → requestAuthorization() 呼び出し → プロンプト出現を確認
        //   3. 許可 → 返り値 true / 拒否 → false
        //
        // Sandbox 環境について: App Sandbox 配下でも CGRequest は機能する
        // (過去事例で確認済み。専用 entitlement は不要)。
        let systemState: AudioAuthorizationStatus.State
        #if canImport(CoreGraphics)
        let screenGranted = CGRequestScreenCaptureAccess()
        if screenGranted {
            systemState = .authorized
        } else if SystemAudioCaptureFlag.everCaptured() {
            // 過去実績フォールバック (TCC キャッシュずれや preflight false but tap works
            // の保険)。
            systemState = .authorized
        } else {
            // CGRequest が false を返したケース: ユーザーが拒否したか、すでに拒否済みで
            // 再プロンプトされなかった。`.denied` として明示する (UI 側で設定アプリへの
            // 案内を出せる)。
            systemState = .denied
        }
        #else
        systemState = SystemAudioCaptureFlag.everCaptured() ? .authorized : .notDetermined
        #endif
        return AudioAuthorizationStatus(microphone: mic, systemAudio: systemState)
    }

    private static func mapAVAuthStatus(_ s: AVAuthorizationStatus) -> AudioAuthorizationStatus.State {
        switch s {
        case .authorized: return .authorized
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    // MARK: - start

    public func start(in outputDirectory: URL, title: String?) async throws -> CaptureSession {
        if active != nil {
            throw AudioCaptureError.alreadyRecording
        }
        transition(to: .preparing)

        let sessionID = UUID()
        let now = Date()
        let resolvedTitle = title ?? Self.defaultTitle(at: now)

        // ── 出力ディレクトリ準備
        // outputDirectory は呼び出し側（ViewModel）が `AppPaths.recordingDirectory(for: id)`
        // で生成済みの一意ディレクトリ。ここで更に UUID 層を作らない（二重ネスト防止）。
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            let err = AudioCaptureError.outputDirectoryUnavailable(outputDirectory)
            transition(to: .failed(error: err))
            throw err
        }
        // 録音ファイルは WAV (Linear PCM) で保存する。
        //
        // 注: 旧 .alac 既定は撤回。Voice Processing (AUVoiceProcessing IO) を
        // 有効にしたマイク入力 (Float32 / 16kHz / mono) を ALAC エンコーダに
        // 流すと `com.apple.coreaudio.avfaudio エラー 1685348671 ('dta?')`
        // が発生し、ファイル書き込み/読み込みが失敗する。
        // ALAC は Int16/24 のみ対応で Float32 を内部変換できないため。
        //
        // 再導入するには mic 側を事前に Float32 → Int16 へ手動変換するか、
        // Voice Processing を切る必要がある。AEC のメリットを優先して WAV を採用。
        let audioContainer: WAVFileWriter.Format = .wav
        let ext = audioContainer.fileExtension
        let micURL = outputDirectory.appendingPathComponent("mic.\(ext)")
        let systemURL = outputDirectory.appendingPathComponent("system.\(ext)")

        // ── MicCapture 起動
        let mic = MicCapture(bufferSize: 4096)
        // HW 切替 (AirPods 接続/切断, USB マイク抜き差し) で AVAudioEngine が暗黙停止する。
        // その瞬間に notification handler が呼ばれるため、actor に hop して状態更新する。
        mic.onConfigurationChange = { [weak self] in
            guard let self else { return }
            Task { await self.handleInterruption(reason: .engineConfigurationChanged) }
        }
        let micStream: AsyncStream<AVAudioPCMBuffer>
        do {
            micStream = try mic.start()
        } catch {
            let err = Self.translate(error)
            transition(to: .failed(error: err))
            throw err
        }

        // ── SystemAudioTap 起動
        let tap: SystemAudioTap
        do {
            tap = try SystemAudioTap()
        } catch {
            mic.stop()
            let err = Self.translate(error)
            transition(to: .failed(error: err))
            throw err
        }
        let systemStream: AsyncStream<AVAudioPCMBuffer>
        do {
            systemStream = try tap.start()
        } catch {
            mic.stop()
            let err = Self.translate(error)
            transition(to: .failed(error: err))
            throw err
        }

        // ── 可逆音声ライタ準備 (Linear PCM / WAV)
        let micWriter: WAVFileWriter
        let systemWriter: WAVFileWriter
        do {
            micWriter = try WAVFileWriter(url: micURL, format: mic.captureFormat, containerFormat: audioContainer)
        } catch {
            mic.stop()
            tap.stop()
            let err = Self.translate(error)
            transition(to: .failed(error: err))
            throw err
        }
        do {
            systemWriter = try WAVFileWriter(url: systemURL, format: tap.captureFormat, containerFormat: audioContainer)
        } catch {
            mic.stop()
            tap.stop()
            micWriter.close()
            let err = Self.translate(error)
            transition(to: .failed(error: err))
            throw err
        }

        // ── consumer Tasks (detached) と LevelAccumulator
        let micAccumulator = LevelAccumulator()
        let systemAccumulator = LevelAccumulator()

        // ── Live ASR fan-out (P4.1 + P4.2)
        // `liveTranscription` が設定され、`liveTranscriptionEnabled == true` の場合、
        // 録音中の PCM を 3 並列で (a) writer / (b) accumulator / (c) ASR feed に流す。
        // ASR feed は WriterSink 内部から continuation.yield されるため、追加 Task は
        // ASR 結果を outer liveTranscripts に転送する purpose のみ。
        let micASRFeed: AsyncStream<AVAudioPCMBuffer>.Continuation?
        let systemASRFeed: AsyncStream<AVAudioPCMBuffer>.Continuation?
        let liveASRTasks: [Task<Void, Never>]
        if liveTranscriptionEnabled, let transcription = liveTranscription {
            var micCap: AsyncStream<AVAudioPCMBuffer>.Continuation!
            let micFeedStream = AsyncStream<AVAudioPCMBuffer>(
                bufferingPolicy: .bufferingNewest(64)
            ) { micCap = $0 }
            var sysCap: AsyncStream<AVAudioPCMBuffer>.Continuation!
            let systemFeedStream = AsyncStream<AVAudioPCMBuffer>(
                bufferingPolicy: .bufferingNewest(64)
            ) { sysCap = $0 }
            micASRFeed = micCap
            systemASRFeed = sysCap

            // sessionID を引数に渡して recordingID として使う (stop() で同じ id を Recording に乗せる)
            let recordingID = sessionID
            let liveCont = self.liveTranscriptContinuation
            let locale = self.liveTranscriptionLocale
            let micCaptureFormat = mic.captureFormat
            let sysCaptureFormat = tap.captureFormat

            let micResults = transcription.transcribeLive(
                buffers: micFeedStream,
                inputFormat: micCaptureFormat,
                recordingID: recordingID,
                source: .mic,
                locale: locale
            )
            let systemResults = transcription.transcribeLive(
                buffers: systemFeedStream,
                inputFormat: sysCaptureFormat,
                recordingID: recordingID,
                source: .system,
                locale: locale
            )

            let micForwardTask = Task.detached(priority: .userInitiated) {
                do {
                    for try await seg in micResults {
                        liveCont.yield(seg)
                    }
                } catch {
                    // live ASR の失敗は録音継続を妨げない (best-effort)。
                    Self.logger.error("live ASR (mic) failed: \(String(describing: error))")
                }
            }
            let systemForwardTask = Task.detached(priority: .userInitiated) {
                do {
                    for try await seg in systemResults {
                        liveCont.yield(seg)
                    }
                } catch {
                    Self.logger.error("live ASR (system) failed: \(String(describing: error))")
                }
            }
            liveASRTasks = [micForwardTask, systemForwardTask]
        } else {
            micASRFeed = nil
            systemASRFeed = nil
            liveASRTasks = []
        }

        let micSink = WriterSink(writer: micWriter, accumulator: micAccumulator, liveASRFeed: micASRFeed)
        let systemSink = WriterSink(writer: systemWriter, accumulator: systemAccumulator, liveASRFeed: systemASRFeed)

        let micTask = Task.detached(priority: .userInitiated) {
            await Self.consume(stream: micStream, sink: micSink)
        }
        let systemTask = Task.detached(priority: .userInitiated) {
            await Self.consume(stream: systemStream, sink: systemSink)
        }

        // ── Level emit task: 100ms ごとに RMS/Peak スナップショットを yield
        let levelCont = self.levelContinuation
        let startedAtCopy = now
        let levelEmitTask = Task.detached(priority: .utility) {
            // 開始ログ
            Self.logger.debug("level emit task started")
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                if Task.isCancelled { break }
                let (mr, mp) = micAccumulator.snapshot()
                let (sr, sp) = systemAccumulator.snapshot()
                let elapsed = Date().timeIntervalSince(startedAtCopy)
                // システム音声が無音閾値を超えた = 実際にキャプチャできている。
                // この事実を永続化して以降は `.authorized` 扱いにする (UX バグ修正)。
                if sp >= AudioLevelSnapshot.silenceThreshold {
                    SystemAudioCaptureFlag.markCaptured()
                }
                levelCont.yield(AudioLevelSnapshot(
                    elapsedSec: elapsed,
                    micRMS: mr,
                    micPeak: mp,
                    systemRMS: sr,
                    systemPeak: sp
                ))
            }
            Self.logger.debug("level emit task ended")
        }

        // ── Watchdog task: IOProc が「一度は流れた後に」止まったら .interrupted(.audioFlowStalled)
        //
        // 重要: 録音開始直後はシステム音声を再生していないことが多く (会議開始前など)、
        // callCount は HW から呼ばれていても bytesReceived が 0 のままになる。
        // 「一度も flow が無かった」状態を「stalled」と誤判定すると、ユーザーが
        // 録音中だと思って待っている間に `.interrupted` 三角マークが出てしまう。
        //
        // 修正後の判定:
        //   - `hasFlowedOnce` フラグを持ち、bytesReceived > 0 を 1 回でも観測したら true
        //   - flow が一度も無い間は stall 判定をスキップ (= 単なる「無音待機」とみなす)
        //   - flow があった後に callCount/bytes が停滞 → 真の HW 切断 / 切替を疑う
        //
        // 判定間隔は 2 秒、連続 2 回停滞で fire (約 4 秒以上の停止)。
        let tapRef = tap
        let watchdogTask = Task.detached(priority: .utility) { [weak self] in
            var lastCallCount = tapRef.flowSnapshot().callCount
            var lastBytes = tapRef.flowSnapshot().bytesReceived
            var stallStreak = 0
            var hasFlowedOnce = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
                if Task.isCancelled { break }
                let snap = tapRef.flowSnapshot()
                if snap.bytesReceived > 0 {
                    hasFlowedOnce = true
                }
                // 録音中以外 (paused, interrupted など) は判定をスキップしてリセット。
                let state = await self?.currentState
                if case .recording = state, hasFlowedOnce {
                    if snap.callCount == lastCallCount && snap.bytesReceived == lastBytes {
                        stallStreak += 1
                    } else {
                        stallStreak = 0
                    }
                    if stallStreak >= 2 {
                        // 約 4 秒以上カウンタが進まない → HW 切替 / 切断を疑う。
                        Self.logger.error("Watchdog: IOProc stalled after flow (callCount=\(snap.callCount), bytes=\(snap.bytesReceived))")
                        await self?.handleInterruption(reason: .audioFlowStalled)
                        stallStreak = 0
                    }
                } else {
                    stallStreak = 0
                }
                lastCallCount = snap.callCount
                lastBytes = snap.bytesReceived
            }
        }

        // ── Disk write watchdog: WriterSink.failureCount が閾値超で .failed に遷移
        // ディスク満杯 / I/O エラーで write が連続失敗しても録音は無音継続してしまう
        // 「サイレントフェイル」を観測可能にして、上位 UI が気付けるようにする。
        let diskFailureThreshold = 5
        let micSinkRef = micSink
        let systemSinkRef = systemSink
        let diskWatchdogTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
                if Task.isCancelled { break }
                let state = await self?.currentState
                // 録音中 or 中断中以外 (idle/preparing/finalizing/failed) はカウントしない
                switch state {
                case .recording, .paused:
                    break
                default:
                    continue
                }
                let total = micSinkRef.failureCount + systemSinkRef.failureCount
                if total > diskFailureThreshold {
                    Self.logger.error("Disk watchdog: write failures total=\(total), promoting to .failed")
                    await self?.handleDiskWriteFailure(failureCount: total)
                    break
                }
            }
        }

        // ── ActiveSession を構築
        let session = CaptureSession(
            id: sessionID,
            startedAt: now,
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            title: resolvedTitle
        )
        active = ActiveSession(
            session: session,
            mic: mic,
            tap: tap,
            micSink: micSink,
            systemSink: systemSink,
            micTask: micTask,
            systemTask: systemTask,
            levelEmitTask: levelEmitTask,
            watchdogTask: watchdogTask,
            diskWatchdogTask: diskWatchdogTask,
            liveASRTasks: liveASRTasks
        )
        Self.logger.info("AudioCaptureServiceImpl.start: micFormat=\(String(describing: mic.captureFormat)) sysFormat=\(String(describing: tap.captureFormat))")
        transition(to: .recording(startedAt: now))
        return session
    }

    // MARK: - pause / resume

    public func pause() async throws {
        guard let active else { throw AudioCaptureError.notRecording }
        switch _currentState {
        case .recording(let startedAt):
            active.micSink.setPaused(true)
            active.systemSink.setPaused(true)
            transition(to: .paused(startedAt: startedAt, pausedAt: Date()))
        case .paused:
            // 冪等: すでに paused なら何もしない
            return
        default:
            throw AudioCaptureError.notRecording
        }
    }

    public func resume() async throws {
        guard let active else { throw AudioCaptureError.notRecording }
        switch _currentState {
        case .paused(let startedAt, _):
            active.micSink.setPaused(false)
            active.systemSink.setPaused(false)
            transition(to: .recording(startedAt: startedAt))
        case .recording:
            return
        default:
            throw AudioCaptureError.notRecording
        }
    }

    // MARK: - stop

    public func stop() async throws -> Recording {
        guard let active else { throw AudioCaptureError.notRecording }
        let startedAt: Date
        switch _currentState {
        case .recording(let t): startedAt = t
        case .paused(let t, _): startedAt = t
        case .interrupted(_, let t, _): startedAt = t
        default:
            throw AudioCaptureError.notRecording
        }
        transition(to: .finalizing)

        // level emit / watchdog は先に止める (空 snapshot の余分な yield を防ぐ)
        active.levelEmitTask.cancel()
        active.watchdogTask.cancel()
        active.diskWatchdogTask.cancel()

        // ハードウェア停止 → ストリームの finish が伝搬 → consumer Task が自然終了する。
        active.mic.stop()
        active.tap.stop()

        // consumer の終了待ち
        _ = await active.micTask.value
        _ = await active.systemTask.value
        _ = await active.levelEmitTask.value
        _ = await active.watchdogTask.value
        _ = await active.diskWatchdogTask.value

        // 失敗カウンタはセッションごとに 0 からカウントするためここでリセット。
        // (sink 自体は close 後に破棄されるが、参照が残った場合の安全策)
        active.micSink.resetFailureCount()
        active.systemSink.resetFailureCount()

        // writer を明示 close (AVAudioFile は ARC で flush するが、シーケンスポイントとして残す)
        // この close() 内で live ASR feed continuation も finish() され、
        // transcribeLive 側で finalizeAndFinish が回って残りの isFinal が確定する。
        active.micSink.close()
        active.systemSink.close()

        // Live ASR forwarding Task の完了待ち (transcribeLive が finish() を呼ぶまで)。
        // best-effort: 何かしらの異常で stuck しても本筋 (Recording 返却) を止めないように
        // 最大数秒のタイムアウトを設ける。
        if !active.liveASRTasks.isEmpty {
            await withTaskGroup(of: Void.self) { group in
                for t in active.liveASRTasks {
                    group.addTask {
                        _ = await t.value
                    }
                }
                // タイムアウト用 Task
                group.addTask {
                    try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
                }
                // 全 forward 完了 or タイムアウトのどちらか先に来た方で抜ける
                _ = await group.next()
                group.cancelAll()
            }
        }

        let endedAt = Date()
        let recording = Recording(
            id: active.session.id,
            title: active.session.title,
            startedAt: startedAt,
            endedAt: endedAt,
            micAudioURL: active.session.micAudioURL,
            systemAudioURL: active.session.systemAudioURL
        )
        self.active = nil
        transition(to: .idle)
        return recording
    }

    // MARK: - Consumer

    /// stream を最後まで消費し、各バッファを sink (`WriterSink`) に渡す。
    /// pause 中は sink 側で no-op となる (ハードウェアは止めない)。
    private static func consume(
        stream: AsyncStream<AVAudioPCMBuffer>,
        sink: WriterSink
    ) async {
        for await buffer in stream {
            sink.write(buffer)
        }
    }

    // MARK: - Error translation

    /// `AudioTapError` ほかを `Contracts.AudioCaptureError` に翻訳する。
    static func translate(_ error: Error) -> AudioCaptureError {
        if let e = error as? AudioCaptureError { return e }
        guard let e = error as? AudioTapError else {
            return .engineStartFailed(message: error.localizedDescription)
        }
        switch e {
        case .tapCreationFailed(let s):
            return .processTapCreateFailed(status: s)
        case .aggregateDeviceCreationFailed(let s):
            return .aggregateDeviceCreateFailed(status: s)
        case .ioProcCreationFailed(let s):
            return .processTapCreateFailed(status: s)
        case .deviceStartFailed(let s):
            // システム音声権限拒否は OSStatus 値で確定できないため、
            // 既存の processTapCreateFailed にマップ (UI 側で fourCC を表示)。
            return .processTapCreateFailed(status: s)
        case .engineStartFailed(let m):
            return .engineStartFailed(message: m)
        case .tapUIDUnavailable(let s):
            return .processTapCreateFailed(status: s)
        case .streamFormatUnavailable(let s):
            return .processTapCreateFailed(status: s)
        case .defaultOutputDeviceUnavailable(let s):
            return .aggregateDeviceCreateFailed(status: s)
        case .outputDeviceUIDUnavailable(let s):
            return .aggregateDeviceCreateFailed(status: s)
        case .fileCreationFailed(let m):
            return .fileWriteFailed(message: m)
        case .alreadyRunning:
            return .alreadyRecording
        case .notRunning:
            return .notRecording
        case .osStatus(let label, let s):
            return .engineStartFailed(message: "\(label): OSStatus=\(s)")
        }
    }

    // MARK: - Defaults

    private static func defaultTitle(at date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return "Meeting \(df.string(from: date))"
    }
}

// MARK: - SystemAudioCaptureFlag

/// システム音声を「過去に実際に取得できた」記録を `UserDefaults` で永続化する。
///
/// macOS の Core Audio process tap には事前 query API が無いため、
/// `authorizationStatus()` は本来 `.notDetermined` しか返せない。
/// しかしユーザーは TCC で許可しているケースが多く、実体験と乖離する。
///
/// 解決策: **一度でも non-zero (>= silenceThreshold) なシステム音声が観測できたら**
/// その bundle (= UserDefaults スコープ) 内で `.authorized` 扱いにする。
/// 再インストールや別 bundle id では再度 `.notDetermined` に戻る (TCC と整合)。
///
/// 寿命: bundle 単位の UserDefaults。ユーザーが「設定を初期化」したい場合は
/// UserDefaults をリセットする他ない (UI からの reset は今回は提供しない)。
enum SystemAudioCaptureFlag {
    /// UserDefaults キー。namespace 衝突を避けるため逆ドメイン記法。
    static let key = "com.example.localVoiceRec.systemAudio.everCaptured"

    /// テスト用に override 可能な store。本番ビルドでは `.standard` で固定し、
    /// `#if DEBUG` 時のみ書き換え可能 (= テストハーネスからの差し替え専用)。
    #if DEBUG
    nonisolated(unsafe) static var store: UserDefaults = .standard
    #else
    nonisolated(unsafe) static let store: UserDefaults = .standard
    #endif

    static func everCaptured() -> Bool {
        store.bool(forKey: key)
    }

    static func markCaptured() {
        // 既に true ならスキップ (write を減らす)
        if store.bool(forKey: key) { return }
        store.set(true, forKey: key)
    }

    /// テスト用のリセット。
    static func reset() {
        store.removeObject(forKey: key)
    }
}

// MARK: - ActiveSession

/// 録音中に保持するリソース束。
private struct ActiveSession {
    let session: CaptureSession
    let mic: MicCapture
    let tap: SystemAudioTap
    let micSink: WriterSink
    let systemSink: WriterSink
    let micTask: Task<Void, Never>
    let systemTask: Task<Void, Never>
    let levelEmitTask: Task<Void, Never>
    let watchdogTask: Task<Void, Never>
    /// ディスク書き込み失敗 watchdog Task。
    /// `WriterSink.failureCount` が閾値超で `.failed(.diskWriteFailure)` に遷移させる。
    let diskWatchdogTask: Task<Void, Never>
    /// Live ASR (P4.2) の結果転送 Task。`liveTranscription` 無効時は空。
    let liveASRTasks: [Task<Void, Never>]
}

// MARK: - WriterSink

/// detached consumer Task と actor の双方から触る writer + pause フラグ。
///
/// `NSLock` で writer の write/close と pause フラグを保護する。
/// pause 中は write を no-op にする (ハードウェアは止めず PCM だけ捨てる)。
/// `LevelAccumulator` への投入は **pause 中も行う** (UI のレベルメーターは録音中も
/// pause 中も「実音」を見せたい想定。ファイル書き込みのみ止める)。
///
/// ## P4.1 fan-out
/// オプションで **live ASR feed continuation** を保持し、各 PCM buffer を
/// (a) 書き込み、(b) レベル累積、(c) live ASR の 3 経路に **同一 buffer を**
/// fan-out する。callback 型の fan-out (= broadcast pattern ではなく
/// 「複数 consumer をその場で同期呼び出し」) を採ることで、buffer の memcpy を
/// 増やさず投機 ASR を 1-pass で走らせられる。
/// 設計上の合意点: pause 中も live ASR feed には buffer を流す
/// (level meter と同じ「録音以外の用途」扱い)。pause 中の文字起こしは
/// 後で破棄する選択肢もあるが、上位レイヤでフィルタする方が責務分離しやすい。
final class WriterSink: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.example.localVoiceRec", category: "audio.write")
    private let lock = NSLock()
    private var writer: WAVFileWriter?
    private var paused: Bool = false
    private var closed: Bool = false
    private var writeFailureCount: Int = 0
    private let accumulator: LevelAccumulator
    /// Live ASR feed の continuation。`nil` なら fan-out しない (post-stop transcribe のみ)。
    /// finish() は close() で呼ばれる。
    private var liveASRFeed: AsyncStream<AVAudioPCMBuffer>.Continuation?

    init(
        writer: WAVFileWriter,
        accumulator: LevelAccumulator,
        liveASRFeed: AsyncStream<AVAudioPCMBuffer>.Continuation? = nil
    ) {
        self.writer = writer
        self.accumulator = accumulator
        self.liveASRFeed = liveASRFeed
    }

    /// 累積 write 失敗回数 (UI/診断用)。
    /// ディスク満杯・I/O エラー等のサイレントフェイルを観測可能にする。
    var failureCount: Int {
        lock.lock(); defer { lock.unlock() }
        return writeFailureCount
    }

    /// 失敗カウンタをリセットする (録音停止時に呼ぶ)。
    func resetFailureCount() {
        lock.lock()
        writeFailureCount = 0
        lock.unlock()
    }

    func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        lock.unlock()
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        // ── Fan-out 経路 1: レベル計算は pause 中も継続 (UI 用)
        accumulator.add(buffer)

        // ── Fan-out 経路 2: live ASR feed (もし有効なら)。
        // 同期 yield。AsyncStream は内部でロックを持つので thread-safe。
        // pause 中も流す方針 (上位で破棄するか維持するか決める)。
        lock.lock()
        let feed = liveASRFeed
        let isClosed = closed
        lock.unlock()
        if !isClosed, let feed {
            feed.yield(buffer)
        }

        lock.lock()
        let shouldWrite = !paused && !closed
        let w = writer
        lock.unlock()
        guard shouldWrite, let w else { return }
        do {
            try w.write(buffer)
        } catch {
            // ストリームは継続させる (途中で潰さない) が、サイレントフェイルを避けるため
            // 失敗回数を計上し、os.log にも 1 件ごとに記録する。
            // ディスク満杯・I/O エラー時、actor 側が failureCount を監視して
            // 必要なら state.failed へ昇格できる。
            lock.lock()
            writeFailureCount += 1
            let count = writeFailureCount
            lock.unlock()
            Self.logger.error(
                "WriterSink.write failed (count=\(count)): \(String(describing: error))"
            )
        }
    }

    func close() {
        lock.lock()
        closed = true
        let w = writer
        writer = nil
        let feed = liveASRFeed
        liveASRFeed = nil
        lock.unlock()
        w?.close()
        // Live ASR feed を finish: 上流が止まったことを ASR 側に伝え、
        // finalizeAndFinish が呼ばれて残りの isFinal セグメントが確定する。
        feed?.finish()
    }
}

// MARK: - LevelAccumulator

/// AVAudioPCMBuffer から RMS / Peak を累積計算するための、スレッドセーフな小さな箱。
///
/// - producer: WriterSink.write (consumer Task = detached priority .userInitiated)
/// - consumer: level emit Task (100ms ごとに snapshot を取って reset)
///
/// 設計:
/// - `sumSq` を `Double` で累積 (Float32 で 100ms 分加算すると精度が落ちるため)
/// - 全 channel をミックスした「総合 RMS」を計算する (mic は 1ch、system は 2ch でも平均)
/// - snapshot は (rms, peak) の線形振幅。dB 換算は呼び出し側 (Contract で定義済)
final class LevelAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var sumSq: Double = 0
    private var sampleCount: Int = 0
    private var peakValue: Float = 0

    /// AVAudioPCMBuffer からサンプルを読み取り、二乗和 / sample 数 / peak を更新する。
    /// Float32 / Int16 / Int32 をサポート。それ以外は no-op (リスクとしてログだけ出す)。
    func add(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let channels = Int(buffer.format.channelCount)
        guard channels > 0 else { return }

        var localSumSq: Double = 0
        var localPeak: Float = 0
        var localCount: Int = 0

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            if buffer.format.isInterleaved {
                // 1 本のバッファに全 ch interleave
                if let base = buffer.floatChannelData?[0] {
                    let total = frames * channels
                    for i in 0..<total {
                        let v = base[i]
                        let a = abs(v)
                        if a > localPeak { localPeak = a }
                        localSumSq += Double(v) * Double(v)
                    }
                    localCount = total
                }
            } else {
                // planar: ch ごとに別ポインタ
                if let chs = buffer.floatChannelData {
                    for ch in 0..<channels {
                        let p = chs[ch]
                        for i in 0..<frames {
                            let v = p[i]
                            let a = abs(v)
                            if a > localPeak { localPeak = a }
                            localSumSq += Double(v) * Double(v)
                        }
                    }
                    localCount = frames * channels
                }
            }
        case .pcmFormatInt16:
            let scale: Float = 1.0 / 32768.0
            if buffer.format.isInterleaved {
                if let base = buffer.int16ChannelData?[0] {
                    let total = frames * channels
                    for i in 0..<total {
                        let v = Float(base[i]) * scale
                        let a = abs(v)
                        if a > localPeak { localPeak = a }
                        localSumSq += Double(v) * Double(v)
                    }
                    localCount = total
                }
            } else if let chs = buffer.int16ChannelData {
                for ch in 0..<channels {
                    let p = chs[ch]
                    for i in 0..<frames {
                        let v = Float(p[i]) * scale
                        let a = abs(v)
                        if a > localPeak { localPeak = a }
                        localSumSq += Double(v) * Double(v)
                    }
                }
                localCount = frames * channels
            }
        case .pcmFormatInt32:
            let scale: Float = 1.0 / 2147483648.0
            if buffer.format.isInterleaved {
                if let base = buffer.int32ChannelData?[0] {
                    let total = frames * channels
                    for i in 0..<total {
                        let v = Float(base[i]) * scale
                        let a = abs(v)
                        if a > localPeak { localPeak = a }
                        localSumSq += Double(v) * Double(v)
                    }
                    localCount = total
                }
            } else if let chs = buffer.int32ChannelData {
                for ch in 0..<channels {
                    let p = chs[ch]
                    for i in 0..<frames {
                        let v = Float(p[i]) * scale
                        let a = abs(v)
                        if a > localPeak { localPeak = a }
                        localSumSq += Double(v) * Double(v)
                    }
                }
                localCount = frames * channels
            }
        default:
            // 未サポートのフォーマット (Float64 / otherFormat)。レベルは無視。
            return
        }

        lock.lock()
        sumSq += localSumSq
        sampleCount += localCount
        if localPeak > peakValue { peakValue = localPeak }
        lock.unlock()
    }

    /// 現在の累積から (rms, peak) を計算して返し、内部状態をリセットする。
    /// 累積が空の場合は (0, 0) を返す (UI 側で「無音」として扱える)。
    func snapshot() -> (rms: Float, peak: Float) {
        lock.lock()
        let s = sumSq
        let n = sampleCount
        let p = peakValue
        sumSq = 0
        sampleCount = 0
        peakValue = 0
        lock.unlock()
        guard n > 0 else { return (0, 0) }
        let rms = Float((s / Double(n)).squareRoot())
        return (rms, p)
    }
}
