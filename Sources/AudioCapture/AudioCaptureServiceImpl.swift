import Foundation
@preconcurrency import AVFAudio
@preconcurrency import AVFoundation
import Accelerate
import CoreAudio
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

    private static let logger = Logger(subsystem: AppIdentifiers.logSubsystem, category: "audio")

    // MARK: - State stream

    private let stateContinuation: AsyncStream<CaptureState>.Continuation
    private nonisolated let stateStream: AsyncStream<CaptureState>

    public nonisolated var stateUpdates: AsyncStream<CaptureState> { stateStream }

    // MARK: - Audio level stream

    private let levelContinuation: AsyncStream<AudioLevelSnapshot>.Continuation
    private nonisolated let levelStream: AsyncStream<AudioLevelSnapshot>

    public nonisolated var liveAudioLevels: AsyncStream<AudioLevelSnapshot> { levelStream }

    private var _currentState: CaptureState = .idle
    public var currentState: CaptureState { _currentState }

    // MARK: - Active session

    /// 現在録音中のリソース束。`nil` なら idle。
    private var active: ActiveSession?

    /// 直近セッションの SystemAudioTap flow スナップショット (停止後も保持).
    /// `systemFlowSnapshot()` は録音中はライブ、停止後はこの値を返す。
    private var lastSystemFlow: SystemFlowSnapshot?

    // MARK: - System notification observers (sleep / wake)

    /// `NSWorkspace.willSleepNotification` / `didWakeNotification` の購読を保持するハンドル。
    ///
    /// ## なぜ別 class か
    /// Swift actor の deinit は actor isolated プロパティに触れない。observer の
    /// `removeObserver` を deinit で確実に呼ぶには「actor の外側に住むオブジェクト」が必要。
    /// `SystemNotificationObserverHandle` を別 class として持ち、その class 自身の deinit
    /// で removeObserver する。actor の release と同時に handle も release されるため、
    /// クリーンアップは自動 (旧実装の deinit + `NSLock` は不要になった)。
    ///
    /// actor isolated な `let` で保持できているのは、`SystemNotificationObserverHandle.init`
    /// に actor の self を直接渡さず、`WeakActorBox` を経由しているため (`init` 中に
    /// self を closure capture できない制約の回避)。
    private let observerHandle: SystemNotificationObserverHandle?

    // MARK: - Init

    public init() {
        // X2.5: `var x: AsyncStream<T>.Continuation!` パターンは認知負荷が高いので、
        // Swift 5.9+ の `AsyncStream.makeStream(of:)` に統一する。
        let stateStream = AsyncStream<CaptureState>.makeStream(
            of: CaptureState.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.stateStream = stateStream.stream
        self.stateContinuation = stateStream.continuation
        // 初期値を 1 件積んでおく → 初回購読者が現在状態を取得できる
        stateStream.continuation.yield(.idle)

        let levelStream = AsyncStream<AudioLevelSnapshot>.makeStream(
            of: AudioLevelSnapshot.self,
            bufferingPolicy: .bufferingNewest(2)
        )
        self.levelStream = levelStream.stream
        self.levelContinuation = levelStream.continuation

        // ── スリープ / 復帰の購読 ──
        // NSWorkspace.shared.notificationCenter は OS スリープ前後のイベントを配信する。
        // 録音中にスリープに入ると IOProc / AVAudioEngine が暗黙停止し、復帰しても自動再開
        // されないことがある (ハードウェア構成にも依存)。observer で `interrupted(.systemWillSleep)`
        // に遷移させてユーザーに通知する。
        //
        // observer の closure 内では actor の self を触りたいが、init 中の closure では
        // self capture できない (actor isolated init 制約)。そこで `WeakActorBox` という
        // 後付けで self を埋められる小箱を渡しておき、init 末尾で `setValue(self)` する。
        #if canImport(AppKit)
        let weakBox = WeakActorBox<AudioCaptureServiceImpl>()
        self.observerHandle = SystemNotificationObserverHandle(
            onWillSleep: {
                guard let actor = weakBox.value else { return }
                Task { await actor.handleInterruption(reason: .systemWillSleep) }
            },
            onDidWake: {
                // 復帰時は自動再開しない方針。UI が `.interrupted` を見て
                // ユーザーに明示的な操作 (停止 or 新規開始) を促す。
                Self.logger.info("NSWorkspace.didWakeNotification: 録音は再開しません — ユーザー操作待ち")
            }
        )
        // ここまでで self の全プロパティが初期化済み → self を box に格納できる。
        weakBox.setValue(self)
        #else
        self.observerHandle = nil
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

    /// 録音を開始する。各 helper が個別のリソース起動を担い、エラー時は
    /// この本体で roll-back (mic.stop / tap.stop / writer.close) する。
    /// 行数が長くなりすぎないよう、HW 起動 / writer 準備 / Task 群構築は
    /// それぞれ専用 helper に切り出している。
    public func start(in outputDirectory: URL, title: String?) async throws -> CaptureSession {
        if active != nil {
            throw AudioCaptureError.alreadyRecording
        }
        transition(to: .preparing)

        let sessionID = UUID()
        let now = Date()
        let resolvedTitle = title ?? Self.defaultTitle(at: now)

        // ── 出力ディレクトリ準備
        try prepareOutputDirectory(in: outputDirectory)
        let ext = WAVFileWriter.Format.wav.fileExtension
        let micURL = outputDirectory.appendingPathComponent("mic.\(ext)")
        let systemURL = outputDirectory.appendingPathComponent("system.\(ext)")

        // ── MicCapture 起動
        let (mic, micStream): (MicCapture, AsyncStream<AVAudioPCMBuffer>)
        do {
            (mic, micStream) = try startMicCapture()
        } catch {
            let err = Self.translate(error)
            transition(to: .failed(error: err))
            throw err
        }

        // ── SystemAudioTap 起動 (失敗時は mic を巻き戻す)
        let tap: SystemAudioTap
        let systemStream: AsyncStream<AVAudioPCMBuffer>
        do {
            (tap, systemStream) = try startSystemAudioTap()
        } catch {
            mic.stop()
            let err = Self.translate(error)
            transition(to: .failed(error: err))
            throw err
        }

        // ── 可逆音声ライタ準備 (失敗時は mic + tap を巻き戻す)
        let writers: (mic: WAVFileWriter, system: WAVFileWriter)
        do {
            writers = try setupWriters(micURL: micURL, micFormat: mic.captureFormat,
                                       systemURL: systemURL, systemFormat: tap.captureFormat)
        } catch {
            mic.stop()
            tap.stop()
            let err = Self.translate(error)
            transition(to: .failed(error: err))
            throw err
        }

        // ── Accumulator / Sink / Consumer Tasks
        // consumer Task は detached で起動し、ハードウェアが止まる (= stream finish) と自然終了する。
        // helper に切り出さない理由: AsyncStream<AVAudioPCMBuffer> の `sending` 制約で
        // 別メソッドへの委譲がコンパイルエラーになるため、ここでインライン展開している。
        let (micAccumulator, systemAccumulator) = setupLevelAccumulators()
        let micSink = WriterSink(writer: writers.mic, accumulator: micAccumulator)
        let systemSink = WriterSink(writer: writers.system, accumulator: systemAccumulator)
        let micTask = Task.detached(priority: .userInitiated) { await Self.consume(stream: micStream, sink: micSink) }
        let systemTask = Task.detached(priority: .userInitiated) { await Self.consume(stream: systemStream, sink: systemSink) }

        // ── Level emit task / watchdog 群
        let levelEmitTask = startLevelEmitTask(startedAt: now, micAccumulator: micAccumulator, systemAccumulator: systemAccumulator)
        let (watchdogTask, diskWatchdogTask) = startWatchdogTasks(tap: tap, micSink: micSink, systemSink: systemSink)

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
            diskWatchdogTask: diskWatchdogTask
        )
        // 新セッション開始 → 旧 flow スナップショットを破棄
        lastSystemFlow = nil
        Self.logStartSession(sessionID: sessionID, micFormat: mic.captureFormat, systemFormat: tap.captureFormat)
        transition(to: .recording(startedAt: now))
        return session
    }

    /// 録音開始ログを「1 行 JSON 風」に出力する (C5)。
    /// トラブルシュート時に session id / フォーマット / 既定出力デバイスがログだけで把握できるよう、
    /// session id + mic/system format + default output device 名を 1 行にまとめる。
    private nonisolated static func logStartSession(
        sessionID: UUID, micFormat: AVAudioFormat, systemFormat: AVAudioFormat
    ) {
        let outputName = currentDefaultOutputDeviceName() ?? "<unknown>"
        let micFmt = describeFormat(micFormat)
        let sysFmt = describeFormat(systemFormat)
        logger.info("start session: id=\(sessionID.uuidString, privacy: .public) micFormat=\(micFmt, privacy: .public) sysFormat=\(sysFmt, privacy: .public) output=\(outputName, privacy: .public)")
    }

    // MARK: - start helpers

    /// 出力ディレクトリを作成する。失敗時は `.failed` 遷移後 `outputDirectoryUnavailable` を投げる。
    /// `outputDirectory` は呼び出し側 (ViewModel) が `AppPaths.recordingDirectory(for: id)`
    /// で生成済みの一意ディレクトリ。ここで更に UUID 層を作らない (二重ネスト防止)。
    private func prepareOutputDirectory(in outputDirectory: URL) throws {
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            let err = AudioCaptureError.outputDirectoryUnavailable(outputDirectory)
            transition(to: .failed(error: err))
            throw err
        }
    }

    /// `MicCapture` を起動し、PCM ストリームを返す。HW 設定変更時の
    /// `onConfigurationChange` も併せて install する。
    /// 失敗時は raw error を re-throw する (呼び出し側で `translate` + state 遷移)。
    ///
    /// `nonisolated`: 返り値の `AsyncStream<AVAudioPCMBuffer>` を呼び出し側で
    /// detached Task に渡せるよう、self-isolated region を作らないようにしている
    /// (Swift 6 strict concurrency)。`onConfigurationChange` は weak self capture で安全。
    private nonisolated func startMicCapture() throws -> (MicCapture, AsyncStream<AVAudioPCMBuffer>) {
        let mic = MicCapture(bufferSize: 4096)
        // HW 切替 (AirPods 接続/切断, USB マイク抜き差し) で AVAudioEngine が暗黙停止する。
        // その瞬間に notification handler が呼ばれるため、actor に hop して状態更新する。
        mic.onConfigurationChange = { [weak self] in
            guard let self else { return }
            Task { await self.handleInterruption(reason: .engineConfigurationChanged) }
        }
        let stream = try mic.start()
        return (mic, stream)
    }

    /// `SystemAudioTap` を生成し起動して、PCM ストリームを返す。
    /// 失敗時は raw error を re-throw する (呼び出し側で mic.stop / translate / state 遷移)。
    ///
    /// `nonisolated`: `startMicCapture` と同様に、返り値の stream を detached Task に渡せるよう
    /// self-isolated region を作らない設計にしている。
    private nonisolated func startSystemAudioTap() throws -> (SystemAudioTap, AsyncStream<AVAudioPCMBuffer>) {
        let tap = try SystemAudioTap()
        let stream = try tap.start()
        return (tap, stream)
    }

    /// WAV writer を mic / system 用に 2 つ作る。
    /// system writer 作成に失敗した場合のみ mic writer を close する内部 roll-back を持つが、
    /// mic.stop / tap.stop は呼び出し側で行う (helper は HW を知らない)。
    private func setupWriters(
        micURL: URL, micFormat: AVAudioFormat,
        systemURL: URL, systemFormat: AVAudioFormat
    ) throws -> (mic: WAVFileWriter, system: WAVFileWriter) {
        let micWriter = try WAVFileWriter(url: micURL, format: micFormat)
        do {
            let systemWriter = try WAVFileWriter(url: systemURL, format: systemFormat)
            return (micWriter, systemWriter)
        } catch {
            // system writer 作成失敗 → 既に作った mic writer は close して file handle を解放
            micWriter.close()
            throw error
        }
    }

    /// レベルメーター用の `LevelAccumulator` を mic / system 用に 2 つ作る。
    /// 副作用なしの純粋なファクトリ。
    private func setupLevelAccumulators() -> (mic: LevelAccumulator, system: LevelAccumulator) {
        return (LevelAccumulator(), LevelAccumulator())
    }

    /// 100ms ごとに RMS/Peak スナップショットを `levelContinuation` に yield する Task を起動する。
    /// システム音声が無音閾値を超えたら `SystemAudioCaptureFlag.markCaptured()` を呼ぶ (UX バグ保険)。
    private func startLevelEmitTask(
        startedAt: Date,
        micAccumulator: LevelAccumulator,
        systemAccumulator: LevelAccumulator
    ) -> Task<Void, Never> {
        let levelCont = self.levelContinuation
        return Task.detached(priority: .utility) {
            Self.logger.debug("level emit task started")
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                if Task.isCancelled { break }
                let (mr, mp) = micAccumulator.snapshot()
                let (sr, sp) = systemAccumulator.snapshot()
                let elapsed = Date().timeIntervalSince(startedAt)
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
    }

    /// HW flow watchdog (IOProc stall 検知) と disk write watchdog の Task を 2 つ起動する。
    ///
    /// ## HW flow watchdog
    /// - 録音開始直後はシステム音声を再生していないことが多く (会議開始前など)、
    ///   callCount は HW から呼ばれていても bytesReceived が 0 のまま。
    ///   「一度も flow が無かった」状態を「stalled」と誤判定すると、ユーザーが
    ///   録音中だと思って待っている間に `.interrupted` 三角マークが出てしまう。
    /// - `hasFlowedOnce` フラグを持ち、bytesReceived > 0 を 1 回でも観測したら true
    /// - flow があった後に callCount/bytes が停滞 → 真の HW 切断 / 切替を疑う
    /// - 判定間隔 2 秒、連続 2 回停滞で fire (約 4 秒以上の停止)
    ///
    /// ## Disk watchdog
    /// - `WriterSink.failureCount` が閾値超で `.failed(.diskWriteFailure)` に遷移
    /// - ディスク満杯 / I/O エラーのサイレントフェイルを観測可能にする
    private func startWatchdogTasks(
        tap: SystemAudioTap,
        micSink: WriterSink,
        systemSink: WriterSink
    ) -> (flow: Task<Void, Never>, disk: Task<Void, Never>) {
        // ── HW flow watchdog
        let tapRef = tap
        let flowTask = Task.detached(priority: .utility) { [weak self] in
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

        // ── Disk write watchdog
        let diskFailureThreshold = 5
        let micSinkRef = micSink
        let systemSinkRef = systemSink
        let diskTask = Task.detached(priority: .utility) { [weak self] in
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

        return (flowTask, diskTask)
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

        // ハードウェア停止前に最終 flow スナップショットを取得 (stop() 後はゼロに戻る可能性があるため)
        let finalSystemFlow = SystemFlowSnapshot(
            callCount: active.tap.ioProcCallCount,
            bytesReceived: active.tap.receivedBytesTotal,
            nonZeroBufferCount: active.tap.nonZeroBufferCount,
            droppedPushCount: active.tap.droppedPushCount
        )
        lastSystemFlow = finalSystemFlow

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
        active.micSink.close()
        active.systemSink.close()

        let endedAt = Date()
        let recording = Recording(
            id: active.session.id,
            title: active.session.title,
            startedAt: startedAt,
            endedAt: endedAt,
            micAudioURL: active.session.micAudioURL,
            systemAudioURL: active.session.systemAudioURL
        )

        // C6: 録音停止ログを「1 行 JSON 風」に詳細化。最終カウンタを 1 箇所にまとめる。
        let duration = endedAt.timeIntervalSince(startedAt)
        let micBytes = active.micSink.bytesWritten
        let sysBytes = active.systemSink.bytesWritten
        let writerFailures = active.micSink.failureCount + active.systemSink.failureCount
        Self.logger.info(
            "stop session: id=\(active.session.id.uuidString, privacy: .public) duration=\(duration, format: .fixed(precision: 2)) micBytes=\(micBytes) sysBytes=\(sysBytes) callCount=\(finalSystemFlow.callCount) nonZero=\(finalSystemFlow.nonZeroBufferCount) drops=\(finalSystemFlow.droppedPushCount) writerFailures=\(writerFailures)"
        )

        self.active = nil
        transition(to: .idle)
        return recording
    }

    // MARK: - System flow snapshot

    public func systemFlowSnapshot() async -> SystemFlowSnapshot? {
        // 録音中はライブカウンタを反映、停止後は最後のセッションのスナップショットを返す。
        if let active {
            return SystemFlowSnapshot(
                callCount: active.tap.ioProcCallCount,
                bytesReceived: active.tap.receivedBytesTotal,
                nonZeroBufferCount: active.tap.nonZeroBufferCount,
                droppedPushCount: active.tap.droppedPushCount
            )
        }
        return lastSystemFlow
    }

    // MARK: - Default output device (logging helper)

    /// `kAudioHardwarePropertyDefaultOutputDevice` から既定出力デバイス名を取得する。
    /// 取得失敗時は `nil` を返す。
    ///
    /// 起動時ログに含めることで、ユーザーから「録音が無音」と報告された際に
    /// AirPods など Bluetooth 出力に切り替わっていないかを後追いで確認できる。
    nonisolated static func currentDefaultOutputDeviceName() -> String? {
        var devID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID
        )
        guard status == noErr, devID != kAudioObjectUnknown else { return nil }
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        let nstatus = withUnsafeMutablePointer(to: &nameRef) { ptr in
            AudioObjectGetPropertyData(devID, &nameAddr, 0, nil, &nameSize, ptr)
        }
        guard nstatus == noErr, let nameRef else { return nil }
        return nameRef.takeRetainedValue() as String
    }

    /// AVAudioFormat を 1 行表現にする (start ログ用)。
    nonisolated static func describeFormat(_ format: AVAudioFormat) -> String {
        let sr = Int(format.sampleRate)
        let ch = format.channelCount
        let common: String
        switch format.commonFormat {
        case .pcmFormatFloat32: common = "f32"
        case .pcmFormatFloat64: common = "f64"
        case .pcmFormatInt16: common = "i16"
        case .pcmFormatInt32: common = "i32"
        case .otherFormat: common = "other"
        @unknown default: common = "?"
        }
        let interleaved = format.isInterleaved ? "i" : "p"
        return "\(sr)Hz/\(ch)ch/\(common)/\(interleaved)"
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

    /// X3.8: defaultTitle 用の DateFormatter。
    /// 録音停止のたびに `DateFormatter()` を作ると `dateFormat` 設定で内部キャッシュが
    /// 無効化されるため、static let で 1 度だけ生成して使い回す。
    /// macOS 26 SDK では DateFormatter は Sendable のため修飾子不要。
    private static let defaultTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static func defaultTitle(at date: Date) -> String {
        return "Meeting \(defaultTitleFormatter.string(from: date))"
    }
}

// MARK: - WeakActorBox

/// `init` 中に self を closure capture できない actor の制約を回避するための小箱。
///
/// 使い方:
/// ```
/// let box = WeakActorBox<MyActor>()
/// let observer = SomeObserver(callback: { box.value?.doSomething() })  // self を直接 capture しない
/// box.setValue(self)  // 全プロパティ初期化後に self をセット
/// ```
///
/// `value` は weak で保持する → actor の release を妨げない。
final class WeakActorBox<T: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _value: T?

    init() {}

    var value: T? {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    func setValue(_ value: T) {
        lock.lock()
        _value = value
        lock.unlock()
    }
}

// MARK: - SystemNotificationObserverHandle

/// `NSWorkspace.willSleepNotification` / `didWakeNotification` の購読を保持するハンドル。
///
/// なぜ別 class に切り出すか:
/// - `AudioCaptureServiceImpl` は actor。actor の deinit は actor isolated プロパティに
///   触れないため、observer の removeObserver を deinit で確実に呼ぶには
///   「actor isolation の外にある別オブジェクト」が必要になる。
/// - actor が `let observerHandle: SystemNotificationObserverHandle?` を保持し、
///   actor の release と共にこの handle も release → handle 自身の deinit で
///   removeObserver される、というライフサイクルにする。
///
/// `@unchecked Sendable`: 中身の `[NSObjectProtocol]` は init で 1 度だけ書いて以降は読み取り専用
/// (deinit でのみ消費)。closure は escape 後 main queue で呼ばれる。
final class SystemNotificationObserverHandle: @unchecked Sendable {
    #if canImport(AppKit)
    private let tokens: [NSObjectProtocol]
    #endif

    init(
        onWillSleep: @escaping @Sendable () -> Void,
        onDidWake: @escaping @Sendable () -> Void
    ) {
        #if canImport(AppKit)
        let nc = NSWorkspace.shared.notificationCenter
        let willSleep = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            onWillSleep()
        }
        let didWake = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            onDidWake()
        }
        self.tokens = [willSleep, didWake]
        #endif
    }

    deinit {
        #if canImport(AppKit)
        let nc = NSWorkspace.shared.notificationCenter
        for t in tokens {
            nc.removeObserver(t)
        }
        #endif
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
    static let key = AppIdentifiers.userDefaultsKey("systemAudio.everCaptured")

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
}

// MARK: - WriterSink

/// detached consumer Task と actor の双方から触る writer + pause フラグ。
///
/// `NSLock` で writer の write/close と pause フラグを保護する。
/// pause 中は write を no-op にする (ハードウェアは止めず PCM だけ捨てる)。
/// `LevelAccumulator` への投入は **pause 中も行う** (UI のレベルメーターは録音中も
/// pause 中も「実音」を見せたい想定。ファイル書き込みのみ止める)。
final class WriterSink: @unchecked Sendable {
    private static let logger = Logger(subsystem: AppIdentifiers.logSubsystem, category: "audio.write")
    private let lock = NSLock()
    private var writer: WAVFileWriter?
    private var paused: Bool = false
    private var closed: Bool = false
    private var writeFailureCount: Int = 0
    /// 書き込み済み (writer.write 成功) の累積バイト数。stop ログ等で使う観測値。
    private var writeBytesTotal: Int = 0
    private let accumulator: LevelAccumulator

    init(
        writer: WAVFileWriter,
        accumulator: LevelAccumulator
    ) {
        self.writer = writer
        self.accumulator = accumulator
    }

    /// 累積 write 失敗回数 (UI/診断用)。
    /// ディスク満杯・I/O エラー等のサイレントフェイルを観測可能にする。
    var failureCount: Int {
        lock.lock(); defer { lock.unlock() }
        return writeFailureCount
    }

    /// 累積書き込みバイト数 (write 成功時のみ加算)。stop ログで mic/system の出力量を比較するのに使う。
    var bytesWritten: Int {
        lock.lock(); defer { lock.unlock() }
        return writeBytesTotal
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
        // レベル計算は pause 中も継続 (UI 用)
        accumulator.add(buffer)

        // X3.6: 旧実装は 1 buffer あたり NSLock を 3 回取得していた。これを
        // **1 回のロック** にまとめ、必要な状態 (paused/closed/writer) を
        // 一度に取得する。書き込み後の bytesTotal/failureCount 更新だけは、
        // wave 書き込み (I/O) をロック内で実行しないよう **後追いで 1 回** 取得する設計に留める。
        lock.lock()
        let isClosed = closed
        let isPaused = paused
        let w = writer
        lock.unlock()

        guard !isClosed, !isPaused, let w else { return }
        do {
            try w.write(buffer)
            // 書き込み成功 → バイト数を加算 (frameLength * bytesPerFrame)
            let bpf = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
            let frames = Int(buffer.frameLength)
            if bpf > 0 && frames > 0 {
                lock.lock()
                writeBytesTotal += bpf * frames
                lock.unlock()
            }
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
        lock.unlock()
        w?.close()
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
            // X3.5: Float32 経路は Accelerate (vDSP) で SIMD 化。
            // - 二乗和: vDSP_svesq → 一発で sum(x²) を返す
            // - 振幅ピーク: vDSP_maxmgv → 一発で max(|x|) を返す
            // 旧実装は per-sample Swift ループで abs/乗算/比較を回しており、
            // 100ms 分 (~ 4800 sample × 2ch) を毎 buffer 計算する常駐コストが大きかった。
            if buffer.format.isInterleaved {
                if let base = buffer.floatChannelData?[0] {
                    let total = vDSP_Length(frames * channels)
                    var sumSq: Float = 0
                    var peak: Float = 0
                    vDSP_svesq(base, 1, &sumSq, total)
                    vDSP_maxmgv(base, 1, &peak, total)
                    localSumSq = Double(sumSq)
                    if peak > localPeak { localPeak = peak }
                    localCount = Int(total)
                }
            } else {
                if let chs = buffer.floatChannelData {
                    let len = vDSP_Length(frames)
                    for ch in 0..<channels {
                        let p = chs[ch]
                        var sumSq: Float = 0
                        var peak: Float = 0
                        vDSP_svesq(p, 1, &sumSq, len)
                        vDSP_maxmgv(p, 1, &peak, len)
                        localSumSq += Double(sumSq)
                        if peak > localPeak { localPeak = peak }
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
