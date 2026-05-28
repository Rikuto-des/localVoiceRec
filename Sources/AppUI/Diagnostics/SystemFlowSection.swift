import SwiftUI
import Contracts

/// 診断パネルの「システム音声 flow」セクション。
///
/// C2: SystemAudioTap IOProc カウンタを表示する。
/// `callCount > 0 && nonZeroBufferCount == 0` のとき、TCC silent denial を疑う赤バナーを出す。
///
/// 挙動は旧 DiagnosticsPanel.systemFlowSection と完全に同一。
struct SystemFlowSection: View {
    let flow: SystemFlowSnapshot

    var body: some View {
        let suspiciousSilentDenial = flow.callCount > 0 && flow.nonZeroBufferCount == 0
        DiagnosticsSectionStyles.section(title: "システム音声 flow") {
            // X4.8: 技術用語の日本語ラベル化。元の用語は .help() のツールチップに退避し、
            // エンジニアのデバッグ時には hover で復元できる。
            DiagnosticsSectionStyles.row(
                label: "システム音声の信号検出",
                value: "\(flow.callCount)",
                isWarning: false,
                help: "IOProc 呼び出し回数"
            )
            DiagnosticsSectionStyles.row(
                label: "受信データ量",
                value: "\(flow.bytesReceived)",
                isWarning: flow.callCount > 0 && flow.bytesReceived == 0,
                help: "受信バイト (bytesReceived)"
            )
            DiagnosticsSectionStyles.row(
                label: "実音検出回数",
                value: "\(flow.nonZeroBufferCount)",
                isWarning: suspiciousSilentDenial,
                help: "非ゼロバッファ (nonZeroBufferCount)"
            )
            DiagnosticsSectionStyles.row(
                label: "破棄バッファ数",
                value: "\(flow.droppedPushCount)",
                isWarning: flow.droppedPushCount > 0,
                help: "ドロップ (droppedPushCount)"
            )
            if suspiciousSilentDenial {
                Label {
                    Text("システム音声の信号検出は発生していますが、実音データがゼロです。画面収録権限を確認してください。")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                }
                .font(.caption)
                .padding(Theme.Spacing.sm)
                .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
