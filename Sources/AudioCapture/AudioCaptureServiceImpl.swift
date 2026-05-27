import Foundation
import AVFAudio
import AVFoundation
import Contracts
import AudioTapKit
import os.log
#if canImport(AppKit)
import AppKit
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

    public init() {
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

    // MARK: - State transition

    private func transition(to next: CaptureState) {
        guard next != _currentState else { return }
        _currentState = next
        stateContinuation.yield(next)
    }

    // MARK: - prewarm

    /// `MicCapture` と `SystemAudioTap` を「インスタンス化だけ」しておくことで
    /// 初回録音時のレイテンシを下げる。`SystemAudioTap.init` は軽量 (HAL を叩かない)。
    /// 実 `start()` は録音開始まで遅延させる (TCC プロンプトを意図せず出さないため)。
    public func prewarm() async {
        // 現状は no-op。`SystemAudioTap()` / `MicCapture()` をここで生成して保持しても
        // hold するだけではほぼ効果が無く、誤って `start()` するとプロンプトが出るリスクがあるため。
        // 将来、ハードウェア probe (e.g. inputFormat 取得) を行う場合の hook として残す。
    }

    // MARK: - Authorization

    public func authorizationStatus() async -> AudioAuthorizationStatus {
        let mic = Self.mapAVAuthStatus(AVCaptureDevice.authorizationStatus(for: .audio))
        // System Audio (Core Audio process tap) は事前 query API が無いため、
        // 過去に non-zero audio を取得できた実績 (`SystemAudioCaptureFlag`) を採用する。
        // 実績ありなら `.authorized`、無ければ `.notDetermined` を返す。
        // (実体験ベース。TCC で許可しているのに「未要求」表示になる UX バグの解消)
        let systemState: AudioAuthorizationStatus.State =
            SystemAudioCaptureFlag.everCaptured() ? .authorized : .notDetermined
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
        // System Audio は初回 `tap.start()` で OS プロンプトが出る前提。ここでは判定不能。
        // ただし過去実績があれば `.authorized` を返す（許可済みの再表示用）。
        let systemState: AudioAuthorizationStatus.State =
            SystemAudioCaptureFlag.everCaptured() ? .authorized : .notDetermined
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
        // 録音ファイルは ALAC (Apple Lossless, m4a コンテナ) で保存する。
        // PCM (WAV) 比で約 50-70% のサイズ削減。可逆圧縮なので品質劣化なし。
        // 既存の .wav 録音 (旧バージョン) も AVAudioFile で読めるので互換性は維持される。
        let audioContainer: WAVFileWriter.Format = .alac
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

        // ── 可逆音声ライタ準備 (ALAC / .m4a)
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
        let micSink = WriterSink(writer: micWriter, accumulator: micAccumulator)
        let systemSink = WriterSink(writer: systemWriter, accumulator: systemAccumulator)

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

        // ── Watchdog task: IOProc が一定時間止まったら .interrupted(.audioFlowStalled)
        // 簡易実装: 2 秒ごとに tap.flowSnapshot() を読み、前回と同値が 2 回連続したら fire。
        // (= 約 4 秒以上 IOProc が進んでいない)
        let tapRef = tap
        let watchdogTask = Task.detached(priority: .utility) { [weak self] in
            var lastCallCount = tapRef.flowSnapshot().callCount
            var lastBytes = tapRef.flowSnapshot().bytesReceived
            var stallStreak = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
                if Task.isCancelled { break }
                let snap = tapRef.flowSnapshot()
                // 録音中以外 (paused, interrupted など) は判定をスキップしてリセット。
                let state = await self?.currentState
                if case .recording = state {
                    if snap.callCount == lastCallCount && snap.bytesReceived == lastBytes {
                        stallStreak += 1
                    } else {
                        stallStreak = 0
                    }
                    if stallStreak >= 2 {
                        // 約 4 秒以上カウンタが進まない → HW 切替 / 切断を疑う。
                        Self.logger.error("Watchdog: IOProc stalled (callCount=\(snap.callCount), bytes=\(snap.bytesReceived))")
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
            watchdogTask: watchdogTask
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

        // ハードウェア停止 → ストリームの finish が伝搬 → consumer Task が自然終了する。
        active.mic.stop()
        active.tap.stop()

        // consumer の終了待ち
        _ = await active.micTask.value
        _ = await active.systemTask.value
        _ = await active.levelEmitTask.value
        _ = await active.watchdogTask.value

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

    /// テスト用に override 可能な store。デフォルトは `.standard`。
    nonisolated(unsafe) static var store: UserDefaults = .standard

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
}

// MARK: - WriterSink

/// detached consumer Task と actor の双方から触る writer + pause フラグ。
///
/// `NSLock` で writer の write/close と pause フラグを保護する。
/// pause 中は write を no-op にする (ハードウェアは止めず PCM だけ捨てる)。
/// `LevelAccumulator` への投入は **pause 中も行う** (UI のレベルメーターは録音中も
/// pause 中も「実音」を見せたい想定。ファイル書き込みのみ止める)。
final class WriterSink: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.example.localVoiceRec", category: "audio.write")
    private let lock = NSLock()
    private var writer: WAVFileWriter?
    private var paused: Bool = false
    private var closed: Bool = false
    private var writeFailureCount: Int = 0
    private let accumulator: LevelAccumulator

    init(writer: WAVFileWriter, accumulator: LevelAccumulator) {
        self.writer = writer
        self.accumulator = accumulator
    }

    /// 累積 write 失敗回数 (UI/診断用)。
    /// ディスク満杯・I/O エラー等のサイレントフェイルを観測可能にする。
    var failureCount: Int {
        lock.lock(); defer { lock.unlock() }
        return writeFailureCount
    }

    func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        lock.unlock()
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        // レベル計算は pause 中も継続 (UI 用)
        accumulator.add(buffer)

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
