import SwiftUI
import AppKit
import Contracts

/// 会話ログ / Markdown プレビューを並べて表示し、コピー or 保存できるシート。
///
/// 既存の `エクスポート` → `fileExporter` のフローは「保存ダイアログ → 別アプリで開いて
/// コピー → 貼り付け」と手数が多かったため、in-app プレビュー + ワンクリックコピーに切り替える。
/// ファイル保存もシート内のセカンダリアクションとして残す。
struct TranscriptPreviewSheet: View {
    let minutes: MeetingMinutes
    let onRequestSave: (ExportFormat) -> Void

    @State private var tab: Tab = .conversation
    @State private var copiedFlash: Bool = false
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case conversation
        case markdown
        var id: String { rawValue }
        var label: String {
            switch self {
            case .conversation: return "会話ログ"
            case .markdown:     return "Markdown プレビュー"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 520, idealHeight: 640)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Text(t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .labelsHidden()

            Spacer()

            Button {
                copyCurrentTabToClipboard()
            } label: {
                Label(copiedFlash ? "コピーしました" : "コピー",
                      systemImage: copiedFlash ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut("c", modifiers: [.command])
            .help("現在のタブのテキストをクリップボードへコピー (⌘C)")

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("閉じる")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch tab {
                case .conversation:
                    Text(conversationText)
                        .font(.system(.body, design: .default))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .markdown:
                    MarkdownRenderedView(text: markdownText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("貼り付け先: Slack / Notion / メール 等")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("会話ログ (.txt) として保存…") {
                    onRequestSave(.plainText)
                }
                Button("Markdown (.md) として保存…") {
                    onRequestSave(.markdown)
                }
            } label: {
                Label("ファイルに保存…", systemImage: "square.and.arrow.down")
                    .labelStyle(.titleAndIcon)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Rendering

    private var conversationText: String {
        ConversationLogFormatter.render(minutes)
    }

    private var markdownText: String {
        MarkdownExporter.render(minutes)
    }

    private func copyCurrentTabToClipboard() {
        let text = (tab == .conversation) ? conversationText : markdownText
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        copiedFlash = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copiedFlash = false
        }
    }
}

// MARK: - Markdown render

/// 軽量な Markdown レンダラ。
///
/// 議事録テンプレートに必要な範囲だけ対応する:
/// - `# / ## / ### 見出し`
/// - `- ` 箇条書き
/// - `- [ ] / - [x]` チェックリスト
/// - `> ` 引用
/// - `---` 水平線
/// - 行内: `**bold** / *italic* / `code` / [link](url)` は AttributedString に委譲
///
/// 完全な Markdown を再現せず「md_viewer 風に読める」最小実装。
struct MarkdownRenderedView: View {
    let text: String

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                row(for: line)
            }
        }
    }

    @ViewBuilder
    private func row(for line: String) -> some View {
        if line.hasPrefix("# ") {
            Text(attributed(String(line.dropFirst(2))))
                .font(.system(.title, design: .default).weight(.bold))
                .padding(.top, 14)
                .padding(.bottom, 4)
        } else if line.hasPrefix("## ") {
            Text(attributed(String(line.dropFirst(3))))
                .font(.system(.title2, design: .default).weight(.semibold))
                .padding(.top, 12)
                .padding(.bottom, 3)
        } else if line.hasPrefix("### ") {
            Text(attributed(String(line.dropFirst(4))))
                .font(.system(.title3, design: .default).weight(.semibold))
                .padding(.top, 8)
        } else if line.hasPrefix("- [ ] ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "square").foregroundStyle(.secondary).font(.callout)
                Text(attributed(String(line.dropFirst(6))))
            }
        } else if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "checkmark.square.fill").foregroundStyle(.secondary).font(.callout)
                Text(attributed(String(line.dropFirst(6))))
            }
        } else if line.hasPrefix("- ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(attributed(String(line.dropFirst(2))))
            }
        } else if line.hasPrefix("> ") {
            Text(attributed(String(line.dropFirst(2))))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 2)
                }
        } else if line.hasPrefix("---") || line.hasPrefix("***") {
            Divider().padding(.vertical, 6)
        } else if line.isEmpty {
            Spacer().frame(height: 6)
        } else {
            Text(attributed(line))
        }
    }

    private func attributed(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}
