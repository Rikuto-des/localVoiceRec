import SwiftUI
import Contracts

/// 診断パネルの「権限」セクション。
///
/// マイク / システム音声の権限状況を表示し、未要求 / 拒否済みに応じて
/// 「権限を要求」ボタン or 「設定を開く」ボタンを出し分ける。
///
/// 挙動は旧 DiagnosticsPanel の該当ブロックと完全に同一。
struct PermissionsSection: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        DiagnosticsSectionStyles.section(title: "権限") {
            DiagnosticsSectionStyles.row(
                label: "マイク",
                value: stateLabel(viewModel.diagnostics.micAuthorization),
                isWarning: viewModel.diagnostics.micAuthorization != .authorized
            )
            DiagnosticsSectionStyles.row(
                label: "システム音声",
                value: stateLabel(viewModel.diagnostics.systemAudioAuthorization),
                isWarning: viewModel.diagnostics.systemAudioAuthorization != .authorized
            )
            if viewModel.diagnostics.systemAudioAuthorization == .notDetermined {
                Text("システム音声は事前確認 API が無いため、初回録音で実音が取れた時点で「許可済み」になります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 未要求のときは権限プロンプトを出すボタンを表示
            if viewModel.diagnostics.micAuthorization == .notDetermined ||
               viewModel.diagnostics.systemAudioAuthorization == .notDetermined {
                permissionHelpBox
            }
            // 拒否済みのときは設定アプリへの誘導
            if viewModel.diagnostics.micAuthorization == .denied ||
               viewModel.diagnostics.systemAudioAuthorization == .denied {
                deniedHelpBox
            }
        }
    }

    // MARK: - Help boxes

    @ViewBuilder
    private var permissionHelpBox: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("OS にまだ権限を問い合わせていません。下のボタンを押すと、マイクとシステム音声録音の権限ダイアログが表示されます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button {
                    Task { await viewModel.requestAudioPermissions() }
                } label: {
                    Label("権限を要求", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("マイクとシステム音声の権限を OS に問い合わせます")
            }
        }
        .padding(.top, Theme.Spacing.xs)
    }

    @ViewBuilder
    private var deniedHelpBox: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label {
                // A7: 拒否されている対象に応じてどこを開けばよいかを明示
                Text(deniedHelpMessage)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(Theme.Palette.warning)
            }
            .font(.caption)
            .foregroundStyle(.primary)
            HStack {
                Spacer()
                Button {
                    openSystemSettings()
                } label: {
                    Label(openSettingsButtonLabel, systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("該当のプライバシー設定ペインを開きます")
            }
        }
        .padding(.top, Theme.Spacing.xs)
    }

    /// A7: 拒否対象に応じたガイド文。
    /// X4.11: `deniedHelpBox` は少なくとも片方が denied のときだけ表示されるため、
    /// (false, false) 分岐は到達不能 — 削除した。
    private var deniedHelpMessage: String {
        let micDenied = viewModel.diagnostics.micAuthorization == .denied
        let systemDenied = viewModel.diagnostics.systemAudioAuthorization == .denied
        if micDenied && systemDenied {
            return "マイクと画面収録の両方が拒否されています。システム設定でそれぞれ localVoiceRec を有効にしてください。まずマイクの設定を開きます。"
        } else if micDenied {
            return "マイクの権限が拒否されています。システム設定 → プライバシーとセキュリティ → マイク で localVoiceRec を許可してください。"
        } else {
            // systemDenied — `deniedHelpBox` の出現条件より、ここでは必ず true。
            return "システム音声 (画面とシステムオーディオの収録) が拒否されています。システム設定で localVoiceRec を許可してください。"
        }
    }

    private var openSettingsButtonLabel: String {
        let micDenied = viewModel.diagnostics.micAuthorization == .denied
        let systemDenied = viewModel.diagnostics.systemAudioAuthorization == .denied
        if !micDenied && systemDenied {
            return "画面収録設定を開く"
        }
        return "マイク設定を開く"
    }

    /// A7: 拒否されているパーミッションごとに開くべき設定ペインを変える。
    /// 旧実装は常にマイクのみへ飛ばしていたため、画面収録 (システム音声) を拒否した
    /// ユーザーが「マイクしか出てこない」と混乱していた問題への対策。
    private func openSystemSettings() {
        let micDenied = viewModel.diagnostics.micAuthorization == .denied
        let systemDenied = viewModel.diagnostics.systemAudioAuthorization == .denied

        // 両方拒否ならマイクを優先（必要なら次のステップでシステム音声側を開く運用）。
        // どちらでもなければ既存通りマイクへ。
        let targetURLString: String
        if micDenied {
            targetURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        } else if systemDenied {
            targetURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        } else {
            targetURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        }
        if let url = URL(string: targetURLString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func stateLabel(_ state: AudioAuthorizationStatus.State) -> String {
        switch state {
        case .authorized: return "許可済み"
        case .denied: return "拒否"
        case .notDetermined: return "未要求"
        }
    }
}
