import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// 要約 5 セクションのビジュアル ID を集約する enum。
///
/// HIG: 色だけに依存せず、必ず SF Symbol アイコン + 日本語タイトルとペアで提示する。
/// アクセシビリティ・色弱配慮の両方を満たす。
enum SummarySectionKind: String, CaseIterable {
    case overview
    case decisions
    case actionItems
    case openQuestions
    case reviewItems

    var title: String {
        switch self {
        case .overview: return "概要"
        case .decisions: return "決定事項"
        case .actionItems: return "アクションアイテム"
        case .openQuestions: return "未解決の問い"
        case .reviewItems: return "次回レビュー項目"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "text.alignleft"
        case .decisions: return "checkmark.seal.fill"
        case .actionItems: return "target"
        case .openQuestions: return "questionmark.circle.fill"
        case .reviewItems: return "arrow.triangle.2.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .overview: return .accentColor
        case .decisions: return Color(nsColor: .systemGreen)
        case .actionItems: return Color(nsColor: .systemOrange)
        case .openQuestions: return Color(nsColor: .systemYellow)
        case .reviewItems: return Color(nsColor: .systemBlue)
        }
    }

    /// `DisclosureGroup` の初期展開状態。概要・決定事項・アクションは展開、それ以外は折りたたみ。
    var defaultsExpanded: Bool {
        switch self {
        case .overview, .decisions, .actionItems: return true
        case .openQuestions, .reviewItems: return false
        }
    }
}

/// セクションテキストをクリップボードへコピーするユーティリティ。
/// Markdown 風 ( `## タイトル` + bullet ) で書き出す。
enum SummaryClipboard {
    static func copy(title: String, lines: [String]) {
        let body = lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "- \($0)" }
            .joined(separator: "\n")
        let text = "## \(title)\n\n\(body.isEmpty ? "(なし)" : body)\n"
        write(text)
    }

    static func copy(title: String, paragraph: String) {
        let text = "## \(title)\n\n\(paragraph)\n"
        write(text)
    }

    static func write(_ text: String) {
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        #endif
    }
}
