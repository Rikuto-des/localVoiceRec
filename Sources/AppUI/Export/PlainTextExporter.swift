import Foundation
import Contracts

/// `MeetingMinutes` をプレーンテキストの議事録に整形する。
///
/// Markdown を素朴に剥がしたバージョン:
/// - 見出し記号 `#` を取り除き、前後に空行を挟む
/// - 箇条書きの `-` `*` `+` 先頭記号を `・` に置換
/// - 太字 / 強調 (`**`, `*`, `__`, `_`) を除去
/// - 引用 (`>`) 行頭を除去
/// - 水平線 `---` は空行に潰す
enum PlainTextExporter {
    static func render(_ minutes: MeetingMinutes) -> String {
        var out = ""

        // ─── ヘッダ ───
        out += "\(minutes.recording.title)\n"
        out += String(repeating: "=", count: max(4, minutes.recording.title.count)) + "\n\n"

        let startStr = ExportFormatters.headerDateTime.string(from: minutes.recording.startedAt)
        let endStr = ExportFormatters.headerDateTime.string(from: minutes.recording.endedAt)
        let durationStr = ExportFormatters.durationLabel(minutes.recording.duration)
        out += "日時: \(startStr) 〜 \(endStr) (\(durationStr))\n"

        if let summary = minutes.summary {
            let genStr = ExportFormatters.headerDateTime.string(from: summary.generatedAt)
            out += "生成日時: \(genStr)\n"
        }
        out += "\n"

        // ─── 要約セクション ───
        if let summary = minutes.summary {
            out += section(title: "概要")
            let overview = summary.overview.trimmingCharacters(in: .whitespacesAndNewlines)
            out += overview.isEmpty ? "（記載なし）\n\n" : "\(overview)\n\n"

            out += section(title: "決定事項")
            out += renderBulletList(summary.decisions)
            out += "\n"

            out += section(title: "アクションアイテム")
            out += renderActionItems(summary.actionItems)
            out += "\n"

            out += section(title: "未解決の問い")
            out += renderBulletList(summary.openQuestions)
            out += "\n"

            out += section(title: "レビュー項目")
            out += renderBulletList(summary.reviewItems)
            out += "\n"
        }

        // ─── 文字起こしセクション ───
        out += section(title: "文字起こし")
        out += "（話者は mic = 自分、system = 相手）\n\n"

        let sorted = minutes.segments.sorted { $0.startSec < $1.startSec }
        if sorted.isEmpty {
            out += "（文字起こしはありません）\n"
        } else {
            for segment in sorted {
                let ts = ExportFormatters.timestamp(from: segment.startSec)
                let speaker = segment.source.rawValue
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                out += "[\(ts)] \(speaker): \(text)\n"
            }
        }

        return out
    }

    // MARK: - Helpers

    private static func section(title: String) -> String {
        "■ \(title)\n\n"
    }

    private static func renderBulletList(_ items: [String]) -> String {
        if items.isEmpty {
            return "・（なし）\n"
        }
        var s = ""
        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            s += "・\(trimmed)\n"
        }
        return s
    }

    private static func renderActionItems(_ items: [ActionItem]) -> String {
        if items.isEmpty {
            return "・（なし）\n"
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
            s += "・[ ] \(title)（\(meta.joined(separator: ", "))）\n"
        }
        return s
    }
}
