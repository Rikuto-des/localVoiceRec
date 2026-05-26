import Foundation

/// 録音ハードウェアを叩かない偽 AudioCaptureService。
/// UI 開発時にメニューバーから「開始」「停止」を操作できるだけのスタブ。
public actor FakeAudioCaptureService: AudioCaptureService {
    private let continuation: AsyncStream<CaptureState>.Continuation
    private nonisolated let stream: AsyncStream<CaptureState>
    private var startedAt: Date?
    private var session: CaptureSession?
    private var _currentState: CaptureState = .idle

    public init() {
        var captured: AsyncStream<CaptureState>.Continuation!
        self.stream = AsyncStream<CaptureState>(
            bufferingPolicy: .bufferingNewest(1)
        ) { captured = $0 }
        self.continuation = captured
        // bufferingNewest(1) で初期値を 1 件積んでおく → 初回購読者が現在状態を取得できる
        captured.yield(.idle)
    }

    public var currentState: CaptureState { _currentState }

    public nonisolated var stateUpdates: AsyncStream<CaptureState> { stream }

    private func transition(to next: CaptureState) {
        guard next != _currentState else { return }
        _currentState = next
        continuation.yield(next)
    }

    public func prewarm() async {}

    public func authorizationStatus() async -> AudioAuthorizationStatus {
        AudioAuthorizationStatus(microphone: .authorized, systemAudio: .authorized)
    }

    public func requestAuthorization() async -> AudioAuthorizationStatus {
        AudioAuthorizationStatus(microphone: .authorized, systemAudio: .authorized)
    }

    public func start(in outputDirectory: URL, title: String?) async throws -> CaptureSession {
        guard session == nil else { throw AudioCaptureError.alreadyRecording }
        let now = Date()
        let id = UUID()
        let resolvedTitle = title ?? Self.defaultTitle(at: now)
        let mic = outputDirectory.appendingPathComponent("\(id.uuidString)_mic.wav")
        let sys = outputDirectory.appendingPathComponent("\(id.uuidString)_sys.wav")
        let s = CaptureSession(id: id, startedAt: now, micAudioURL: mic, systemAudioURL: sys, title: resolvedTitle)
        startedAt = now
        session = s
        transition(to: .recording(startedAt: now))
        return s
    }

    public func pause() async throws {
        guard let started = startedAt else { throw AudioCaptureError.notRecording }
        transition(to: .paused(startedAt: started, pausedAt: Date()))
    }

    public func resume() async throws {
        guard let started = startedAt else { throw AudioCaptureError.notRecording }
        transition(to: .recording(startedAt: started))
    }

    public func stop() async throws -> Recording {
        guard let s = session, let started = startedAt else {
            throw AudioCaptureError.notRecording
        }
        transition(to: .finalizing)
        let endedAt = Date()
        let recording = Recording(
            id: s.id,
            title: s.title,
            startedAt: started,
            endedAt: endedAt,
            micAudioURL: s.micAudioURL,
            systemAudioURL: s.systemAudioURL
        )
        session = nil
        startedAt = nil
        transition(to: .idle)
        return recording
    }

    private static func defaultTitle(at date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return "Meeting \(df.string(from: date))"
    }
}
