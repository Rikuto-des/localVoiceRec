import SwiftUI
import Contracts

/// 診断パネルの「文字起こし」「要約」セクション。
///
/// Speech locale のインストール状況と Apple Intelligence / Foundation Models
/// 要約サービスの availability を一行ずつ表示する。
///
/// 挙動は旧 DiagnosticsPanel の該当ブロックと完全に同一。
struct SummaryAvailabilitySection: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            DiagnosticsSectionStyles.section(title: "文字起こし") {
                if viewModel.diagnostics.installedLocales.isEmpty {
                    DiagnosticsSectionStyles.row(label: "Locale", value: "未インストール", isWarning: true)
                } else {
                    DiagnosticsSectionStyles.row(
                        label: "Locale",
                        value: viewModel.diagnostics.installedLocales.joined(separator: ", "),
                        isWarning: false
                    )
                }
            }

            Divider()

            DiagnosticsSectionStyles.section(title: "要約") {
                DiagnosticsSectionStyles.row(
                    label: "ステータス",
                    value: availabilityLabel(viewModel.diagnostics.summaryAvailability),
                    isWarning: !isSummaryAvailable
                )
            }
        }
    }

    private func availabilityLabel(_ avail: SummaryAvailability) -> String {
        switch avail {
        case .available: return "利用可能"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "端末非対応"
            case .appleIntelligenceNotEnabled: return "Apple Intelligence が無効"
            case .modelNotReady: return "モデル準備中"
            case .unsupportedOS: return "OS 非対応"
            }
        }
    }

    private var isSummaryAvailable: Bool {
        if case .available = viewModel.diagnostics.summaryAvailability {
            return true
        }
        return false
    }
}
