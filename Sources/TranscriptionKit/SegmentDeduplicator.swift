import Foundation
import Contracts

/// 「マイクへ回り込んで system 音声が二重転写された」mic セグメントを検出する post-process。
///
/// # 背景
/// localVoiceRec は AEC/VP を OFF にしている（音量や音質を犠牲にしないトレードオフ）。
/// その結果、スピーカーから出た相手 (system) の声をマイクが拾ってしまい、
/// 同じ発話が mic / system 両チャンネルに乗ることがある。
///
/// # 戦略
/// segments を post-process で走査し、mic セグメントが時間的に重なる system セグメントと
/// テキスト類似度も高ければ「相手の声の回り込み」と判定して `isLikelyEcho` を立てる。
/// 削除はしない（UI 側で薄表示 / Export 側で除外する）。
///
/// # アルゴリズム選定
/// 類似度は **正規化 Levenshtein 距離** を採用した。理由:
/// - SpeechAnalyzer は同じ音声でも 1〜2 文字の表記ゆれを出す（例: 「指味噌」vs「海味噌」）
/// - 文字数の差にも頑健（n-gram Jaccard は短文だと閾値設定が難しい）
/// - 依存ゼロ (Foundation のみ) で実装可能
/// - n*m DP だが、長文 (>180 chars) は早期に枝刈り (`maxLength` 差ガード) するため
///   実測で 1 時間分 transcript（数百セグメント）でも軽い
///
/// # 計算量
/// - 外側ループ: O(n) (mic セグメントごと)
/// - 内側: 時間ソート済の system セグメントに対し overlap 候補のみ参照するため、
///   平均 O(k) (k = overlap 候補数、通常 1〜2)
/// - 各候補の Levenshtein: O(L^2) (L = 文字数)
///
/// 1 時間 transcript ≈ 数百セグメント、平均 30 文字 → 全体で数百万 char-ops、
/// 数十 ms オーダーで完了する（実機 M1 で計測想定）。
public enum SegmentDeduplicator {

    /// 時間 overlap の最低割合（短い方の長さに対する重なり比率）。
    public static let overlapThreshold: Double = 0.5

    /// テキスト類似度（正規化 Levenshtein）の最低値。
    public static let textSimilarityThreshold: Double = 0.7

    /// 入力 segments に対し、相手の声の回り込みと判定された mic セグメントの
    /// `isLikelyEcho` を `true` にして返す。
    ///
    /// - 引数の `segments` は順序不問。内部で startSec 昇順にソートして処理する。
    /// - 戻り値の順序は入力と同じ（id を保つ）。
    /// - mic / system が一方しかなければ何も変えない。
    public static func markEchoes(segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !segments.isEmpty else { return segments }

        // system セグメントを時間順に並べる（overlap 探索の高速化）
        let systems = segments
            .filter { $0.source == .system }
            .sorted { $0.startSec < $1.startSec }
        guard !systems.isEmpty else { return segments }
        let hasMic = segments.contains(where: { $0.source == .mic })
        guard hasMic else { return segments }

        // id -> echo フラグ
        var echoIDs: Set<UUID> = []

        for seg in segments where seg.source == .mic {
            // 時間 overlap 候補: systems の中で seg.startSec...seg.endSec と交差し得るもの。
            // 線形走査でも数百件なら十分速いが、二分探索で下限を絞る。
            let lower = lowerBoundIndex(systems: systems, targetStart: seg.startSec)
            for i in lower..<systems.count {
                let sys = systems[i]
                if sys.startSec > seg.endSec {
                    break // 以降は時間的に交差しない
                }
                let ratio = overlapRatio(a: seg, b: sys)
                if ratio < overlapThreshold { continue }
                let sim = textSimilarity(seg.text, sys.text)
                if sim >= textSimilarityThreshold {
                    echoIDs.insert(seg.id)
                    break
                }
            }
        }

        guard !echoIDs.isEmpty else { return segments }
        return segments.map { seg in
            guard echoIDs.contains(seg.id) else { return seg }
            return TranscriptSegment(
                id: seg.id,
                recordingID: seg.recordingID,
                source: seg.source,
                startSec: seg.startSec,
                endSec: seg.endSec,
                text: seg.text,
                isFinal: seg.isFinal,
                isLikelyEcho: true
            )
        }
    }

    // MARK: - Overlap

    /// `a` と `b` の時間 overlap を、「短い方の長さ」に対する比率で返す。
    /// 互いに 0 幅 / 逆転している場合は 0 を返す。
    static func overlapRatio(a: TranscriptSegment, b: TranscriptSegment) -> Double {
        let aLen = max(0.0, a.endSec - a.startSec)
        let bLen = max(0.0, b.endSec - b.startSec)
        let shorter = min(aLen, bLen)
        guard shorter > 0 else { return 0 }
        let overlap = max(0.0, min(a.endSec, b.endSec) - max(a.startSec, b.startSec))
        return overlap / shorter
    }

    /// 時間ソート済 `systems` の中で、`startSec <= targetStart` を満たす最後の要素の index を返す。
    /// 該当が無ければ 0。overlap 候補は (lower-1, lower, lower+1, ...) のあたりに集中するため、
    /// safety margin として 1 つ前から見始める。
    private static func lowerBoundIndex(systems: [TranscriptSegment], targetStart: Double) -> Int {
        // upper_bound 風の二分探索
        var lo = 0
        var hi = systems.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if systems[mid].startSec <= targetStart {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return max(0, lo - 1)
    }

    // MARK: - Text similarity (normalized Levenshtein)

    /// 2 文字列の類似度 (0...1)。1 = 完全一致。
    /// 正規化 Levenshtein 距離: `1 - editDistance / max(len_a, len_b)`。
    public static func textSimilarity(_ a: String, _ b: String) -> Double {
        let na = normalize(a)
        let nb = normalize(b)
        if na.isEmpty && nb.isEmpty { return 1.0 }
        if na.isEmpty || nb.isEmpty { return 0.0 }
        let aChars = Array(na)
        let bChars = Array(nb)
        let maxLen = max(aChars.count, bChars.count)
        // 早期枝刈り: 文字数差が maxLen の半分以上なら閾値を超えない（>0.5 になりえない）
        let diff = abs(aChars.count - bChars.count)
        let upperBoundSim = 1.0 - Double(diff) / Double(maxLen)
        if upperBoundSim < textSimilarityThreshold - 0.05 {
            // 早期 return しても safe (sim は upperBoundSim 以下)
            return upperBoundSim
        }
        let dist = levenshtein(aChars, bChars)
        return 1.0 - Double(dist) / Double(maxLen)
    }

    /// 比較用に文字列を正規化: 前後空白除去 + 全角空白 / 句読点ノイズの除去。
    /// 日本語の「、。」「,.」「!?」等は ASR の表記ゆれが大きいため取り除く。
    private static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // 句読点・記号を除去（ASR が揺れやすい）
        let stripCharset: Set<Character> = ["、", "。", ",", ".", "!", "?", "！", "？", " ", "\u{3000}"]
        t.removeAll { stripCharset.contains($0) }
        return t
    }

    /// 古典的 Levenshtein 距離 (O(n*m), O(min(n,m)) 空間)。
    /// 短い方を内側 (列) にして 1 行ぶんの DP を保持する。
    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        // 常に b を短い側にする
        let (s, t) = a.count <= b.count ? (b, a) : (a, b)
        let n = s.count
        let m = t.count
        if m == 0 { return n }
        var prev = Array(0...m)
        var curr = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            curr[0] = i
            let si = s[i - 1]
            for j in 1...m {
                let cost = si == t[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,        // deletion
                    curr[j - 1] + 1,    // insertion
                    prev[j - 1] + cost  // substitution
                )
            }
            swap(&prev, &curr)
        }
        return prev[m]
    }
}
