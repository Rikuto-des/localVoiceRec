import Foundation

/// 録音ハードウェアを叩かない偽 AudioCaptureService。
/// UI 開発時にメニューバーから「開始」「停止」を操作できるだけのスタブ。
public actor FakeAudioCaptureService: AudioCaptureService {
    private let continuation: AsyncStream<CaptureState>.Continuation
    private nonisolated let _state: AsyncStream<CaptureState>
    private var startedAt: Date?
    private var session: CaptureSession?

    public init() {
        var captured: AsyncStream<CaptureState>.Continuation!
        self._state = AsyncStream<CaptureState> { captured = $0 }
        self.continuation = captured
        captured.yield(.idle)
    }

    public nonisolated var state: AsyncStream<CaptureState> { _state }

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
        continuation.yield(.recording(startedAt: now))
        return s
    }

    public func pause() async throws {
        guard let started = startedAt else { throw AudioCaptureError.notRecording }
        continuation.yield(.paused(startedAt: started, pausedAt: Date()))
    }

    public func resume() async throws {
        guard let started = startedAt else { throw AudioCaptureError.notRecording }
        continuation.yield(.recording(startedAt: started))
    }

    public func stop() async throws -> Recording {
        guard let s = session, let started = startedAt else {
            throw AudioCaptureError.notRecording
        }
        continuation.yield(.finalizing)
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
        continuation.yield(.idle)
        return recording
    }

    private static func defaultTitle(at date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return "Meeting \(df.string(from: date))"
    }
}
