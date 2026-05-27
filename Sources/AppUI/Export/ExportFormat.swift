import Foundation

/// 議事録エクスポートの出力形式。
///
/// SwiftUI `.fileExporter` 側で `UTType` を組み立てる際は
/// `utTypeIdentifier` を渡す前提。直接 `UTType` を返さないのは ExportKit 自体が
/// UniformTypeIdentifiers を import せず、依存を Contracts のみに抑えるため。
enum ExportFormat: String, Sendable, CaseIterable, Identifiable, Hashable {
    case markdown
    case plainText

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .markdown: return "Markdown (.md)"
        case .plainText: return "プレーンテキスト (.txt)"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .plainText: return "txt"
        }
    }

    var utTypeIdentifier: String {
        switch self {
        case .markdown: return "net.daringfireball.markdown"
        case .plainText: return "public.plain-text"
        }
    }
}
