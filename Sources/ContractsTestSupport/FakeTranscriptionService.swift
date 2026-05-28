import Foundation
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
}
