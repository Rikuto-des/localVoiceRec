import Foundation
import Contracts

/// 録音ハードウェアを叩かない偽 AudioCaptureService。
/// UI 開発時にメニューバーから「開始」「停止」を操作できるだけのスタブ。
public actor FakeAudioCaptureService: AudioCaptureService {
    private let continuation: AsyncStream<CaptureState>.Continuation
    private nonisolated let stream: AsyncStream<CaptureState>
    private let levelContinuation: AsyncStream<AudioLevelSnapshot>.Continuation
    private nonisolated let levelStream: AsyncStream<AudioLevelSnapshot>
    private let liveTranscriptContinuation: AsyncStream<TranscriptSegment>.Continuation
    private nonisolated let liveTranscriptStream: AsyncStream<TranscriptSegment>
    private var startedAt: Date?
    private var session: CaptureSession?
    private var _currentState: CaptureState = .idle
    private var levelTask: Task<Void, Never>?

    public init() {
        var captured: AsyncStream<CaptureState>.Continuation!
        self.stream = AsyncStream<CaptureState>(
            bufferingPolicy: .bufferingNewest(1)
        ) { captured = $0 }
        self.continuation = captured
        // bufferingNewest(1) で初期値を 1 件積んでおく → 初回購読者が現在状態を取得できる
        captured.yield(.idle)

        var capturedLevels: AsyncStream<AudioLevelSnapshot>.Continuation!
        self.levelStream = AsyncStream<AudioLevelSnapshot>(
            bufferingPolicy: .bufferingNewest(2)
        ) { capturedLevels = $0 }
        self.levelContinuation = capturedLevels

        // テスト/Preview で live transcripts を任意 yield するために continuation を保持する。
        var capturedLive: AsyncStream<TranscriptSegment>.Continuation!
        self.liveTranscriptStream = AsyncStream<TranscriptSegment>(
            bufferingPolicy: .unbounded
        ) { capturedLive = $0 }
        self.liveTranscriptContinuation = capturedLive
    }

    /// テスト/Preview 用: live transcript セグメントを手動で yield する。
    public nonisolated func emitLiveTranscript(_ segment: TranscriptSegment) {
        liveTranscriptContinuation.yield(segment)
    }

    public var currentState: CaptureState { _currentState }

    public nonisolated var stateUpdates: AsyncStream<CaptureState> { stream }

    public nonisolated var liveAudioLevels: AsyncStream<AudioLevelSnapshot> { levelStream }

    public nonisolated var liveTranscripts: AsyncStream<TranscriptSegment> { liveTranscriptStream }

    private func transition(to next: CaptureState) {
        guard next != _currentState else { return }
        _currentState = next
        continuation.yield(next)
    }

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
        startLevelEmitter()
        return s
    }

    /// Mock 用: サイン波風のレベルを 100ms 間隔で emit する。
    private func startLevelEmitter() {
        levelTask?.cancel()
        let started = Date()
        let cont = levelContinuation
        levelTask = Task { [weak self] in
            var t: Double = 0
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(started)
                // mic: ゆっくり脈動する音声風 / system: わずかに高い周波数
                let micRms = Float(0.05 + 0.25 * abs(sin(t * .pi * 0.7)))
                let micPeak = Float(min(1.0, Double(micRms) * 2.5))
                let sysRms = Float(0.03 + 0.18 * abs(sin(t * .pi * 1.3 + 0.5)))
                let sysPeak = Float(min(1.0, Double(sysRms) * 2.2))
                cont.yield(AudioLevelSnapshot(
                    elapsedSec: elapsed,
                    micRMS: micRms, micPeak: micPeak,
                    systemRMS: sysRms, systemPeak: sysPeak
                ))
                t += 0.1
                try? await Task.sleep(nanoseconds: 100_000_000)
                if await self?.session == nil { break }
            }
        }
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
        levelTask?.cancel()
        levelTask = nil
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
