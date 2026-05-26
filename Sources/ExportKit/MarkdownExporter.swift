import Foundation
import Contracts

/// `MeetingMinutes` を Markdown 文字列に整形する。
///
/// 出力形式は仕様で固定（タスク S6-A）:
/// - H1: タイトル
/// - 箇条書きメタ情報（日時 / 生成日時）
/// - H2: 概要 / 決定事項 / アクションアイテム / 未解決の問い / レビュー項目
/// - `---` の区切り
/// - H2: 文字起こし（タイムスタンプつき）
public enum MarkdownExporter {
    public static func render(_ minutes: MeetingMinutes) -> String {
        var out = ""

        // ─── ヘッダ ───
        out += "# \(minutes.recording.title)\n\n"

        let startStr = ExportFormatters.headerDateTime.string(from: minutes.recording.startedAt)
        let endStr = ExportFormatters.headerDateTime.string(from: minutes.recording.endedAt)
        let durationStr = ExportFormatters.durationLabel(minutes.recording.duration)
        out += "- **日時**: \(startStr) 〜 \(endStr) (\(durationStr))\n"

        if let summary = minutes.summary {
            let genStr = ExportFormatters.headerDateTime.string(from: summary.generatedAt)
            out += "- **生成日時**: \(genStr)\n"
        }
        out += "\n"

        // ─── 要約セクション ───
        if let summary = minutes.summary {
            out += "## 概要\n\n"
            let overview = summary.overview.trimmingCharacters(in: .whitespacesAndNewlines)
            if overview.isEmpty {
                out += "（記載なし）\n\n"
            } else {
                out += "\(overview)\n\n"
            }

            out += "## 決定事項\n\n"
            out += renderBulletList(summary.decisions)
            out += "\n"

            out += "## アクションアイテム\n\n"
            out += renderActionItems(summary.actionItems)
            out += "\n"

            out += "## 未解決の問い\n\n"
            out += renderBulletList(summary.openQuestions)
            out += "\n"

            out += "## レビュー項目\n\n"
            out += renderBulletList(summary.reviewItems)
            out += "\n"

            out += "---\n\n"
        }

        // ─── 文字起こしセクション ───
        out += "## 文字起こし\n\n"
        out += "> 話者は **mic** = 自分、**system** = 相手\n\n"

        let sorted = minutes.segments.sorted { $0.startSec < $1.startSec }
        if sorted.isEmpty {
            out += "（文字起こしはありません）\n"
        } else {
            for segment in sorted {
                let ts = ExportFormatters.timestamp(from: segment.startSec)
                let speaker = segment.source.rawValue
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                out += "**[\(ts)] \(speaker)**: \(text)\n\n"
            }
        }

        return out
    }

    // MARK: - Helpers

    private static func renderBulletList(_ items: [String]) -> String {
        if items.isEmpty {
            return "- （なし）\n"
        }
        var s = ""
        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            s += "- \(trimmed)\n"
        }
        return s
    }

    private static func renderActionItems(_ items: [ActionItem]) -> String {
        if items.isEmpty {
            return "- （なし）\n"
        }
        var s = ""
        for item in items {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let assignee = item.assignee?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var meta: [String] = []
            meta.append("担当: \(assignee.isEmpty ? "未割当" : assignee)")
            if let due = item.dueDate {
                meta.append("期限: \(ExportFormatters.dueDate.string(from: due))")
            }
            s += "- [ ] \(title)（\(meta.joined(separator: ", "))）\n"
        }
        return s
    }
}
