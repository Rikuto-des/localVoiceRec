import Foundation

/// マイク + システム音声を 2ch で同時録音するサービス。
///
/// ## 設計上の重要事項
/// - **マイク**: `AVAudioEngine.inputNode.installTap` で取得
/// - **システム音声**: Core Audio process tap (`AudioHardwareCreateProcessTap`) + aggregate device
/// - process tap の IOProc はリアルタイムスレッドで動くため、ring buffer 経由でしか
///   actor 境界の外に出さない。AVAudioPCMBuffer の生成は consumer 側で行う
/// - 結果は 2 つの独立した WAV ファイルとして書き出す（話者分離はチャンネルで確定）
/// - サンプルレート/フォーマットは hardware 由来。SpeechAnalyzer に渡す前段で
///   `AVAudioConverter` により `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`
///   に合わせて変換する（変換責務は TranscriptionService 側）
public protocol AudioCaptureService: Sendable {
    /// マイクとシステム音声の権限状況を取得。
    func authorizationStatus() async -> AudioAuthorizationStatus

    /// 権限が `.notDetermined` のものを要求する。実際の OS ダイアログが出る。
    @discardableResult
    func requestAuthorization() async -> AudioAuthorizationStatus

    /// 録音開始。`outputDirectory` 配下に 2 つの WAV ファイルを作成し、URL を `CaptureSession` で返す。
    /// `title` が nil の場合は日時から自動生成。
    func start(in outputDirectory: URL, title: String?) async throws -> CaptureSession

    /// 一時停止。ファイル書き込みを止めるがハードウェアエンジンは維持。
    func pause() async throws

    /// 一時停止からの再開。
    func resume() async throws

    /// 録音終了。ファイルをクローズし、完成した `Recording` を返す。
    func stop() async throws -> Recording

    /// 現在の録音状態（同期的に取得）。
    /// UI 初期描画で `stateUpdates` 購読前にスナップショットを取る用途。
    var currentState: CaptureState { get async }

    /// 状態変更の通知。
    ///
    /// ## セマンティクス（実装契約）
    /// - **cold stream**: 購読開始時点で `currentState` を 1 回必ず yield してから変更を流す
    /// - **distinct-until-changed**: 同一値を連続して yield しない
    /// - **buffering**: `.bufferingNewest(1)` を使い、遅い consumer の場合は最新だけ届く
    var stateUpdates: AsyncStream<CaptureState> { get }

    /// 録音中のレベル（RMS / Peak）スナップショットを流すストリーム。
    /// 波形 / レベルメーター UI 用。録音中以外は yield しない（または静寂を yield する）。
    ///
    /// ## セマンティクス
    /// - 録音中は概ね **10〜30 Hz** (33ms 〜 100ms ごと) で yield することを推奨
    /// - bufferingPolicy は `.bufferingNewest(2)` を推奨（最新だけ届けば十分）
    /// - 録音停止時に finish() するか否かは実装依存。consumer は途中切断を許容する。
    var liveAudioLevels: AsyncStream<AudioLevelSnapshot> { get }
}

public enum CaptureState: Sendable, Hashable {
    case idle
    case preparing
    case recording(startedAt: Date)
    case paused(startedAt: Date, pausedAt: Date)
    case finalizing
    case failed(error: AudioCaptureError)
    /// 録音が外部要因 (HW 切替・スリープ・engine config change など) で中断された状態。
    /// 内部的には `pause` 同様に書き込みは止まり、ハードウェアも停止している可能性がある。
    /// 上位 (UI) はユーザーに通知し、必要なら明示的に停止/再開操作を促す。
    case interrupted(reason: InterruptionReason, startedAt: Date, interruptedAt: Date)
}

/// 録音が中断された理由。`CaptureState.interrupted(reason:)` で運ばれる。
public enum InterruptionReason: Sendable, Hashable {
    /// `AVAudioEngineConfigurationChange` 通知。HW 切替 (Bluetooth 接続/切断, USB マイク抜き差し) など。
    case engineConfigurationChanged
    /// `NSWorkspace.willSleepNotification`。OS がスリープに入ろうとしている。
    case systemWillSleep
    /// IOProc / マイクから一定時間データが届かない (watchdog 検知)。
    case audioFlowStalled
}

public struct CaptureSession: Sendable, Hashable {
    public let id: UUID
    public let startedAt: Date
    public let micAudioURL: URL
    public let systemAudioURL: URL
    public let title: String

    public init(id: UUID, startedAt: Date, micAudioURL: URL, systemAudioURL: URL, title: String) {
        self.id = id
        self.startedAt = startedAt
        self.micAudioURL = micAudioURL
        self.systemAudioURL = systemAudioURL
        self.title = title
    }
}

public struct AudioAuthorizationStatus: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case authorized
        case denied
        case notDetermined
    }
    public let microphone: State
    public let systemAudio: State

    public init(microphone: State, systemAudio: State) {
        self.microphone = microphone
        self.systemAudio = systemAudio
    }

    public var allAuthorized: Bool {
        microphone == .authorized && systemAudio == .authorized
    }
}

public enum AudioCaptureError: Error, Sendable, Hashable {
    case microphonePermissionDenied
    case systemAudioPermissionDenied
    case engineStartFailed(message: String)
    case processTapCreateFailed(status: Int32)
    case aggregateDeviceCreateFailed(status: Int32)
    case alreadyRecording
    case notRecording
    case fileWriteFailed(message: String)
    case outputDirectoryUnavailable(URL)
}
