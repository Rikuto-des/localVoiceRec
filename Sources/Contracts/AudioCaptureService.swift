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
    /// 重いリソース（process tap, aggregate device, mic engine）を事前に確保しておく。
    /// 初回録音のレイテンシを下げるため、アプリ起動時の余裕タイミングで呼ぶ。
    func prewarm() async

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
}

public enum CaptureState: Sendable, Hashable {
    case idle
    case preparing
    case recording(startedAt: Date)
    case paused(startedAt: Date, pausedAt: Date)
    case finalizing
    case failed(error: AudioCaptureError)
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
