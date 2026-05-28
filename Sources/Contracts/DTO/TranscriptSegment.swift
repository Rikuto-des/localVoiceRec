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

    /// マイク回り込みで相手 (system) の音声を二重に拾った可能性が高いセグメントに立つフラグ。
    ///
    /// - 用途: VP/AEC を OFF にしたトレードオフで発生する「同一発話が mic / system 双方に乗る」
    ///   現象を後段で検出し、UI 表示やエクスポートから除外する判断に使う。
    /// - 判定: post-process (`CrossChannelEchoMarker.markEchoes`) が時間 overlap + テキスト
    ///   類似度で立てる。SpeechAnalyzer 段では常に `false`。
    /// - default あり: 既存テスト / DB マイグレーションを壊さないため。
    public let isLikelyEcho: Bool

    public init(
        id: UUID = UUID(),
        recordingID: UUID,
        source: Source,
        startSec: Double,
        endSec: Double,
        text: String,
        isFinal: Bool,
        isLikelyEcho: Bool = false
    ) {
        self.id = id
        self.recordingID = recordingID
        self.source = source
        self.startSec = startSec
        self.endSec = endSec
        self.text = text
        self.isFinal = isFinal
        self.isLikelyEcho = isLikelyEcho
    }

    // MARK: - Codable

    /// 過去ストレージとの後方互換のため `isLikelyEcho` は欠落時 `false` にフォールバックする。
    private enum CodingKeys: String, CodingKey {
        case id, recordingID, source, startSec, endSec, text, isFinal, isLikelyEcho
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.recordingID = try c.decode(UUID.self, forKey: .recordingID)
        self.source = try c.decode(Source.self, forKey: .source)
        self.startSec = try c.decode(Double.self, forKey: .startSec)
        self.endSec = try c.decode(Double.self, forKey: .endSec)
        self.text = try c.decode(String.self, forKey: .text)
        self.isFinal = try c.decode(Bool.self, forKey: .isFinal)
        self.isLikelyEcho = try c.decodeIfPresent(Bool.self, forKey: .isLikelyEcho) ?? false
    }
}
