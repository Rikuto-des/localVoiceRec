import Foundation

/// 録音中の音声レベルのスナップショット。
///
/// 波形 / レベルメーター表示用。マイクとシステム音声の片方だけ動いている／
/// 完全な無音、といった「目に見えない」異常を UI で可視化するために使う。
///
/// 値は **線形振幅 (0.0 〜 1.0)**。0 = 完全無音、1 = フルスケール。
/// dB 換算は `20 * log10(max(value, 1e-12))`。
public struct AudioLevelSnapshot: Sendable, Hashable, Codable {
    /// このスナップショットが対応する音声時刻（録音開始からの相対時刻、秒）。
    public let elapsedSec: Double

    /// マイク（自分の声）チャンネルの RMS。
    public let micRMS: Float
    /// マイクチャンネルのピーク振幅。
    public let micPeak: Float

    /// システム音声（相手の声）チャンネル（2ch ある場合は平均）の RMS。
    public let systemRMS: Float
    /// システム音声チャンネルのピーク振幅。
    public let systemPeak: Float

    public init(
        elapsedSec: Double,
        micRMS: Float,
        micPeak: Float,
        systemRMS: Float,
        systemPeak: Float
    ) {
        self.elapsedSec = elapsedSec
        self.micRMS = micRMS
        self.micPeak = micPeak
        self.systemRMS = systemRMS
        self.systemPeak = systemPeak
    }

    /// 静寂とみなす閾値（線形振幅）。-60 dBFS 相当。
    public static let silenceThreshold: Float = 0.001

    public var isMicSilent: Bool { micPeak < Self.silenceThreshold }
    public var isSystemSilent: Bool { systemPeak < Self.silenceThreshold }
}
