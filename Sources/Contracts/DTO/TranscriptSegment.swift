import Foundation

/// 文字起こしの 1 phrase 単位の結果。
///
/// チャンネル (`source`) によって話者を確定する設計（AI 推定に頼らない）。
public struct TranscriptSegment: Sendable, Identifiable, Hashable, Codable {
    public enum Source: String, Sendable, Codable, CaseIterable, Hashable {
        /// 自分の声（AVAudioEngine マイク入力）
        case mic
        /// 相手の声（Core Audio process tap によるシステム音声）
        case system
    }

    public let id: UUID
    public let recordingID: UUID
    public let source: Source

    /// 音声開始からの秒数（録音開始 = 0）
    public let startSec: Double
    public let endSec: Double

    public let text: String

    /// SpeechAnalyzer が "暫定" として吐く中間結果は false。
    /// 永続化は基本 `isFinal == true` のものだけにする想定だが、Contract レベルでは両方許容。
    public let isFinal: Bool

    public init(
        id: UUID = UUID(),
        recordingID: UUID,
        source: Source,
        startSec: Double,
        endSec: Double,
        text: String,
        isFinal: Bool
    ) {
        self.id = id
        self.recordingID = recordingID
        self.source = source
        self.startSec = startSec
        self.endSec = endSec
        self.text = text
        self.isFinal = isFinal
    }
}
