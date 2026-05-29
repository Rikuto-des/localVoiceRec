import Foundation

/// 録音冒頭で SpeechAnalyzer が無音/起動トランジェントを 1 モーラの母音として
/// 幻覚するパターン (例: 「相手 00:00:00 あ」) をドロップする post-process。
///
/// # 背景
/// Apple の on-device SpeechAnalyzer は、極短かつ信号がほぼ無い入力に対して
/// 「あ」「ん」「うん」のような相槌相当の出力を吐くことがある。
/// SystemAudioTap 側はマイクと違い AUVoiceProcessing 等の前処理が無いため
/// 起動直後の DC オフセットや初期バッファでこの幻覚が高確率で発生する。
///
/// # 戦略
/// 録音冒頭 (startSec < `leadingWindowSec`) かつ system チャンネルの、
/// 既知の幻覚パターンに一致する短セグメントだけを除去する。
/// mic 側は VP/AEC で前処理されており幻覚は出にくいので対象外。
/// 真の発話 (時間が十分長い、startSec が冒頭ではない、文字数が多い) には触らない。
public enum PhantomLeadingSegmentFilter {

    /// 「冒頭」と見なす時刻 (秒)。これより後の「あ」は実発話の可能性が高いので残す。
    public static let leadingWindowSec: Double = 0.5

    /// 幻覚として除外する text の集合 (正規化後)。
    /// 1 モーラ母音 + 短い相槌のみ。これ以外は実発話とみなす。
    private static let phantomTexts: Set<String> = [
        "あ", "い", "う", "え", "お", "ん",
        "ア", "イ", "ウ", "エ", "オ", "ン",
        "うん", "ああ", "んー",
    ]

    /// 入力 segments から冒頭幻覚に一致するものを除外して返す。
    /// 順序は保持する。
    public static func drop(segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.filter { !isPhantomLeading($0) }
    }

    static func isPhantomLeading(_ seg: TranscriptSegment) -> Bool {
        guard seg.source == .system else { return false }
        guard seg.startSec < leadingWindowSec else { return false }
        let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return phantomTexts.contains(trimmed)
    }
}
