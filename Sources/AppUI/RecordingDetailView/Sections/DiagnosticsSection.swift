import SwiftUI

extension RecordingDetailView {
    // MARK: - Diagnostics

    /// 診断パネル（実体は `Sources/AppUI/Diagnostics/DiagnosticsPanel.swift`）への薄いラッパ。
    /// 本ファイルはセクション分割の対称性を保つために存在する。
    @ViewBuilder
    var diagnosticsSection: some View {
        DiagnosticsPanel(viewModel: viewModel)
    }
}
