import SwiftUI
import Contracts

/// 折りたたみ式の診断パネル。
///
/// 「録音されていなさそう / 文字起こしが出ない」というユーザー訴えに対し、
/// 原因切り分けに必要な情報をまとめて表示する:
///
/// - マイク / システム音声の権限状態
/// - インストール済み Speech locale
/// - Foundation Models 要約サービスの availability
/// - 選択中の録音のファイル URL / 静的波形（任意）
///
/// ## HIG 準拠ポイント
/// - セクション名は `caption.bold()` + `.secondary` (Form の section title 風)
/// - 警告は色 + アイコンの 2 要素で表現
/// - 設定アプリへの遷移ボタンは `.bordered` + `.controlSize(.small)`
struct DiagnosticsPanel: View {
    @Bindable var viewModel: AppViewModel
    @State private var isExpanded: Bool = false
    @State private var isRefreshing: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
                .padding(.top, Theme.Spacing.sm)
        } label: {
            HStack {
                Label("診断情報", systemImage: "stethoscope")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if isRefreshing {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("診断情報を更新中")
                }
            }
        }
        .padding(Theme.Spacing.md)
        .subtleSurface()
        .task {
            await refresh()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            section(title: "権限") {
                row(
                    label: "マイク",
                    value: stateLabel(viewModel.diagnostics.micAuthorization),
                    isWarning: viewModel.diagnostics.micAuthorization != .authorized
                )
                row(
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

            Divider()

            section(title: "文字起こし") {
                if viewModel.diagnostics.installedLocales.isEmpty {
                    row(label: "Locale", value: "未インストール", isWarning: true)
                } else {
                    row(
                        label: "Locale",
                        value: viewModel.diagnostics.installedLocales.joined(separator: ", "),
                        isWarning: false
                    )
                }
            }

            Divider()

            section(title: "要約") {
                row(
                    label: "ステータス",
                    value: availabilityLabel(viewModel.diagnostics.summaryAvailability),
                    isWarning: !isSummaryAvailable
                )
            }

            if let recording = viewModel.selectedRecording {
                Divider()
                section(title: "選択中の録音ファイル") {
                    filePathRow(label: "mic", url: recording.micAudioURL)
                    filePathRow(label: "system", url: recording.systemAudioURL)
                }
            }

            HStack {
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRefreshing)
                .help("診断情報を取得し直します")
            }
            .padding(.top, Theme.Spacing.xs)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func row(label: String, value: String, isWarning: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: Theme.Spacing.xs) {
                if isWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Palette.warning)
                        .font(.caption)
                        .accessibilityHidden(true)
                }
                Text(value)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(isWarning ? Theme.Palette.warning : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)\(isWarning ? "（要確認）" : "")")
    }

    private func filePathRow(label: String, url: URL) -> some View {
        let path = url.path
        return HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Text(path)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Button {
                copyToClipboard(path)
            } label: {
                Image(systemName: "doc.on.doc")
                    .accessibilityLabel("\(label) ファイルパスをコピー")
            }
            .buttonStyle(.borderless)
            .help("ファイルパスをコピー")
            Button {
                FinderReveal.reveal(url)
            } label: {
                Image(systemName: "magnifyingglass")
                    .accessibilityLabel("\(label) ファイルを Finder で表示")
            }
            .buttonStyle(.borderless)
            .help("Finder で表示")
        }
    }

    // MARK: - Permission help boxes

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
                Text("一度「拒否」した権限は、システム設定からのみ許可に変更できます。")
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
                    Label("システム設定を開く", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("プライバシーとセキュリティ設定を開きます")
            }
        }
        .padding(.top, Theme.Spacing.xs)
    }

    private func openSystemSettings() {
        // プライバシー設定 → マイク
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Formatting

    private func stateLabel(_ state: AudioAuthorizationStatus.State) -> String {
        switch state {
        case .authorized: return "許可済み"
        case .denied: return "拒否"
        case .notDetermined: return "未要求"
        }
    }

    private func availabilityLabel(_ avail: SummaryAvailability) -> String {
        switch avail {
        case .available: return "利用可能"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "端末非対応"
            case .appleIntelligenceNotEnabled: return "AI 無効"
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

    // MARK: - Actions

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await viewModel.refreshDiagnostics()
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

#Preview("Diagnostics") {
    DiagnosticsPanel(
        viewModel: AppViewModel(
            capture: FakeAudioCaptureService(),
            repository: InMemoryRecordingRepository(seed: [SampleData.recording]),
            transcription: FakeTranscriptionService(),
            summary: FakeSummaryService()
        )
    )
    .padding()
    .frame(width: 360)
}

#Preview("Diagnostics (Dark)") {
    DiagnosticsPanel(
        viewModel: AppViewModel(
            capture: FakeAudioCaptureService(),
            repository: InMemoryRecordingRepository(seed: [SampleData.recording]),
            transcription: FakeTranscriptionService(),
            summary: FakeSummaryService()
        )
    )
    .padding()
    .frame(width: 360)
    .preferredColorScheme(.dark)
}
