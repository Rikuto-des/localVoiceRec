import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Contracts

extension RecordingDetailView {
    // MARK: - Export (ログ表示シート + AppKit 保存パネル)

    /// 「ログを表示」ボタン + プレビューシート + (シート閉じた後の) `NSSavePanel` 保存ダイアログ。
    ///
    /// ## 保存フローを `NSSavePanel` にした経緯
    /// 以前は SwiftUI の `.fileExporter` を親 View に attach していたが、
    /// SwiftUI はひとつの View に対して同時に複数の sheet 系 modal を提示できないため、
    /// シート (`.sheet(item:)`) が開いている間に `.fileExporter` を発火しても保存ダイアログが
    /// 出ない (待機して何も起きないように見える) というバグになっていた。
    ///
    /// 対処として:
    /// 1. シート内「保存…」を押すと、format を `pendingSaveFormat` に保存しつつ
    ///    シートを即座に `dismiss()` する (TranscriptPreviewSheet 側)。
    /// 2. シートの `onDismiss` で `pendingSaveFormat` を見て、AppKit の `NSSavePanel` を
    ///    直接呼ぶ (SwiftUI の presentation manager と競合しない)。
    @ViewBuilder
    var exportControls: some View {
        Button {
            Task { await preparePreview() }
        } label: {
            Label(isPreparingPreview ? "読み込み中…" : "ログを表示",
                  systemImage: isPreparingPreview ? "ellipsis" : "doc.text.magnifyingglass")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(
            viewModel.selectedRecording == nil ||
            isPreparingPreview ||
            isPreparingExport ||
            viewModel.isTranscribingSelected ||
            viewModel.isSummarizingSelected
        )
        .help("会話ログ / Markdown プレビューを開いて、コピーまたは保存できます")
        .sheet(item: $previewMinutes,
               onDismiss: {
                    // シートが閉じてから保存パネルを出す (SwiftUI の sheet 同時提示制約を回避)
                    guard let format = pendingSaveFormat else { return }
                    pendingSaveFormat = nil
                    Task { await runSavePanel(format: format) }
               }) { minutes in
            TranscriptPreviewSheet(minutes: minutes) { format in
                // シート内の「保存…」が呼ぶ closure。フォーマットを覚えるだけ。
                // 実際の NSSavePanel 起動は onDismiss 側。
                pendingSaveFormat = format
            }
        }
    }

    func utType(for format: ExportFormat) -> UTType {
        UTType(format.utTypeIdentifier) ?? .plainText
    }

    /// 「ログを表示」押下時。MeetingMinutes をロードしてシートを開く。
    func preparePreview() async {
        guard let recording = viewModel.selectedRecording else { return }
        isPreparingPreview = true
        defer { isPreparingPreview = false }
        do {
            let minutes = try await viewModel.makeMinutes(for: recording)
            previewMinutes = minutes
        } catch {
            viewModel.reportExportFailure("プレビュー用データの生成に失敗しました: \(String(describing: error))")
        }
    }

    /// シートが閉じた後に呼ばれる: 指定フォーマットで NSSavePanel を起動して保存する。
    @MainActor
    func runSavePanel(format: ExportFormat) async {
        guard let recording = viewModel.selectedRecording else { return }
        isPreparingExport = true
        defer { isPreparingExport = false }

        // テキスト生成 (失敗したらエラー表示してそこで終わり)
        let text: String
        do {
            text = try await viewModel.exportText(for: recording, format: format)
        } catch {
            viewModel.reportExportFailure("保存用データの生成に失敗しました: \(error.localizedDescription)")
            return
        }

        // AppKit の保存パネル
        let panel = NSSavePanel()
        panel.title = "ログを保存"
        panel.nameFieldStringValue = suggestedFilename(for: recording, format: format)
        panel.allowedContentTypes = [utType(for: format)]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        // System.allowedContentTypes に拡張子を強制 → ユーザーが消しても安全
        panel.allowsOtherFileTypes = false

        let response = await withCheckedContinuation { (cont: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            panel.begin { cont.resume(returning: $0) }
        }
        guard response == .OK, let url = panel.url else { return } // キャンセルは沈黙
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            viewModel.reportExportFailure("保存に失敗しました: \(error.localizedDescription)")
        }
    }

    func suggestedFilename(for recording: Recording, format: ExportFormat) -> String {
        // X3.8: DateFormatter を都度生成しない (AppFormatters.exportFilenameDate を共有)
        let dateStr = AppFormatters.exportFilenameDate.string(from: recording.startedAt)
        let safeTitle = recording.title
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        // NSSavePanel は allowedContentTypes から拡張子を自動付与するが、
        // ユーザーがファイル名欄を編集する場合に備えて拡張子も足しておく。
        return "\(safeTitle)_\(dateStr).\(format.fileExtension)"
    }
}
