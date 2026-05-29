import Foundation
import Contracts

/// `MeetingMinutes` を「会話ログ」形式のプレーンテキストに整形する。
///
/// チャットアプリのトーク履歴のような見た目で、Slack / Notion / メール本文に
/// そのまま貼り付けて読めることを意図する。
///
/// フォーマット:
/// ```
/// <タイトル>
/// <録音開始日時>
///
/// 自分  00:00:03
/// では本日のアジェンダから。
///
/// 相手  00:00:07
/// よろしくお願いします。
/// ```
///
/// - 話者ラベルは `自分 / 相手` (チャンネルベース、AI 推定なし)。
/// - タイムスタンプは録音開始からの経過時間 (`hh:mm:ss`)。
/// - 1 発話 = 2 行 (見出し行 + 本文)、発話間は空行で区切る。
/// - `isLikelyEcho` のセグメントは `MeetingMinutes.renderableSegments` 側で除外済み。
enum ConversationLogFormatter {
    static func render(_ minutes: MeetingMinutes) -> String {
        var out = ""

        // ─── ヘッダ ───
        out += "\(minutes.recording.title)\n"
        out += "\(ExportFormatters.headerDateTime.string(from: minutes.recording.startedAt))\n"
        out += "\n"

        // ─── 会話本体 ───
        let segments = minutes.renderableSegments.sorted { $0.startSec < $1.startSec }
        guard !segments.isEmpty else {
            out += "(発話が検出されませんでした)\n"
            return out
        }
        for seg in segments {
            let speaker = seg.source == .mic ? "自分" : "相手"
            let ts = ExportFormatters.timestamp(from: seg.startSec)
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            out += "\(speaker)  \(ts)\n"
            out += "\(text)\n"
            out += "\n"
        }
        return out
    }
}
