import SwiftUI
import UniformTypeIdentifiers
import Contracts

extension RecordingDetailView {
    // MARK: - Export

    /// 「ログを表示」ボタン + プレビューシート + (シート内からの) ファイル保存ダイアログ。
    /// SummarySection の `regenerateControls` 内から呼び出されて横並びで配置される。
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
        .sheet(item: $previewMinutes) { minutes in
            TranscriptPreviewSheet(minutes: minutes) { format in
                // シート内の「保存…」から呼ばれる: 保存ダイアログを fileExporter で開く
                Task { await prepareExport(format: format) }
            }
        }
        .fileExporter(
            isPresented: Binding(
                get: { exportDocument != nil },
                set: { newValue in
                    if !newValue { exportDocument = nil }
                }
            ),
            document: exportDocument,
            contentType: utType(for: exportFormat),
            defaultFilename: exportSuggestedName
        ) { result in
            switch result {
            case .success:
                exportDocument = nil
            case .failure(let error):
                viewModel.reportExportFailure("保存に失敗しました: \(error.localizedDescription)")
                exportDocument = nil
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

    /// シート内の「保存…」から呼ばれる: 指定フォーマットで fileExporter のドキュメントを準備。
    func prepareExport(format: ExportFormat) async {
        guard let recording = viewModel.selectedRecording else { return }
        isPreparingExport = true
        defer { isPreparingExport = false }
        do {
            let text = try await viewModel.exportText(for: recording, format: format)
            self.exportFormat = format
            self.exportSuggestedName = suggestedFilename(for: recording, format: format)
            self.exportDocument = MinutesExportDocument(text: text, format: format)
        } catch {
            viewModel.reportExportFailure("保存用データの生成に失敗しました: \(String(describing: error))")
        }
    }

    func suggestedFilename(for recording: Recording, format: ExportFormat) -> String {
        // X3.8: DateFormatter を都度生成しない (AppFormatters.exportFilenameDate を共有)
        let dateStr = AppFormatters.exportFilenameDate.string(from: recording.startedAt)
        let safeTitle = recording.title
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return "\(safeTitle)_\(dateStr)"
        // 拡張子は SwiftUI が contentType から自動で付与する
    }
}
