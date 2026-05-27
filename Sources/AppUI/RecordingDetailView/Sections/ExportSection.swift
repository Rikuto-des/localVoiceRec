import SwiftUI
import UniformTypeIdentifiers
import Contracts

extension RecordingDetailView {
    // MARK: - Export

    /// エクスポートボタン + 形式選択ダイアログ + fileExporter。
    /// SummarySection の `regenerateControls` 内から呼び出されて横並びで配置される。
    @ViewBuilder
    var exportControls: some View {
        Button {
            showFormatChooser = true
        } label: {
            Label("エクスポート", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(
            viewModel.selectedRecording == nil ||
            isPreparingExport ||
            viewModel.isTranscribingSelected ||
            viewModel.isSummarizingSelected
        )
        .help("議事録を Markdown / プレーンテキストでエクスポートします")
        .confirmationDialog(
            "エクスポート形式を選択",
            isPresented: $showFormatChooser,
            titleVisibility: .visible
        ) {
            ForEach(ExportFormat.allCases) { format in
                Button(format.displayName) {
                    Task { await prepareExport(format: format) }
                }
            }
            Button("キャンセル", role: .cancel) { }
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
                viewModel.reportExportFailure("エクスポートに失敗しました: \(error.localizedDescription)")
                exportDocument = nil
            }
        }
    }

    func utType(for format: ExportFormat) -> UTType {
        UTType(format.utTypeIdentifier) ?? (format == .markdown ? .plainText : .plainText)
    }

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
            viewModel.reportExportFailure("エクスポート用データの生成に失敗しました: \(String(describing: error))")
        }
    }

    func suggestedFilename(for recording: Recording, format: ExportFormat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyyMMdd"
        let dateStr = formatter.string(from: recording.startedAt)
        let safeTitle = recording.title
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return "\(safeTitle)_\(dateStr)"
        // 拡張子は SwiftUI が contentType から自動で付与する
        // 形式選択結果は exportFormat 経由で反映される
        // （format 引数自体は将来の拡張用に残しておく）
    }
}
