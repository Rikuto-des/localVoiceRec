import Foundation
import Contracts

/// 文字起こし結果が「要約に値する実コンテンツ」を含むかを判定する純粋ロジック。
///
/// 旧 `AppViewModel.hasSubstantiveContent(segments:)` から Z1 で移設。
///
/// Foundation Models (on-device 3B) は入力が極端に薄いと、もっともらしい内容を
/// 捏造する (ハルシネーション)。例: 「うん」「あ」のような相槌だけの transcript で
/// 「予算編成」「コスト削減」等の架空の議論内容を生成する。
///
/// 自動要約は実コンテンツが一定量ある場合に限定する。閾値は実利テスト由来で
/// **空白除去後 60 文字以上 かつ 5 セグメント以上** とする。これ未満の場合は
/// 手動「要約を再生成」ボタンを押した時のみ要約する (ユーザーが明示的に判断)。
///
/// View 層がこの閾値を意識しなくて済むよう、SummaryKit に集約する。
public enum SubstantiveContentChecker {
    /// 自動要約発火条件を満たすかを返す。
    public static func isSubstantive(segments: [TranscriptSegment]) -> Bool {
        guard segments.count >= 5 else { return false }
        let totalChars = segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).count }
            .reduce(0, +)
        return totalChars >= 60
    }
}
