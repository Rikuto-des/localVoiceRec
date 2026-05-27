import Foundation
@preconcurrency import AVFoundation
import Contracts

/// SpeechAnalyzer を叩かない偽 TranscriptionService。サンプルセグメントを yield するだけ。
public actor FakeTranscriptionService: TranscriptionService {
    private var samples: [TranscriptSegment]

    public init(samples: [TranscriptSegment] = []) {
        self.samples = samples
    }

    public func installedLocales() async -> [Locale] {
        [Locale(identifier: "ja-JP"), Locale(identifier: "en-US")]
    }

    public nonisolated func transcribe(
        recording: Recording,
        locale: Locale?
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else { continuation.finish(); return }
                let s = await self.samples
                if s.isEmpty {
                    // 入力された Recording に紐づく雛形を 2 件返す
                    let now = recording.startedAt
                    _ = now
                    continuation.yield(TranscriptSegment(
                        recordingID: recording.id, source: .mic,
                        startSec: 0.0, endSec: 2.5,
                        text: "おはようございます、本日の会議を始めます。",
                        isFinal: true
                    ))
                    continuation.yield(TranscriptSegment(
                        recordingID: recording.id, source: .system,
                        startSec: 2.8, endSec: 5.0,
                        text: "よろしくお願いします。",
                        isFinal: true
                    ))
                } else {
                    for sample in s { continuation.yield(sample) }
                }
                continuation.finish()
            }
        }
    }

    public func cancelAll() async {}

    /// テスト stub: 上流 stream をドレインし、終了時に 1 件の isFinal セグメントを返す。
    /// 「上流の finish が後段の finalize に伝播する」最低限の動作だけを保証。
    public nonisolated func transcribeLive(
        buffers: AsyncStream<AVAudioPCMBuffer>,
        inputFormat: AVAudioFormat,
        recordingID: UUID,
        source: TranscriptSegment.Source,
        locale: Locale?
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        // 非 Sendable element を Task に渡すため box 経由 (本物の実装と同じ運用)。
        let box = FakeLiveBox(stream: buffers)
        let sampleRate = inputFormat.sampleRate
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                var frameCount: AVAudioFramePosition = 0
                for await buf in box.stream {
                    frameCount += AVAudioFramePosition(buf.frameLength)
                }
                let endSec = sampleRate > 0
                    ? Double(frameCount) / sampleRate
                    : 0
                continuation.yield(TranscriptSegment(
                    recordingID: recordingID,
                    source: source,
                    startSec: 0,
                    endSec: endSec,
                    text: "[fake live transcript]",
                    isFinal: true
                ))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private final class FakeLiveBox: @unchecked Sendable {
    let stream: AsyncStream<AVAudioPCMBuffer>
    init(stream: AsyncStream<AVAudioPCMBuffer>) { self.stream = stream }
}
