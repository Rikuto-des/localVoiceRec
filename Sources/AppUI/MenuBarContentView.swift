import SwiftUI
import AppKit
import Contracts
#if DEBUG
import ContractsTestSupport
#endif

/// メニューバーをクリックしたときに表示される小ウィンドウ。
///
/// 録音操作（開始 / 停止 / 一時停止 / 再開）と、録音一覧ウィンドウへの導線を提供する。
///
/// ## HIG 準拠ポイント
/// - 主操作 (録音開始 / 停止) は `.borderedProminent` + `.controlSize(.large)`
/// - 補助操作 (一時停止 / 再開) は `.bordered`
/// - 終了は macOS 標準メニュー (⌘Q) に委譲（ポップアップには配置しない）
/// - 状態バッジは色 + テキスト + アイコンの 3 要素 (色だけに依存しない)
/// - すべてのボタンに `.help()` を付与
struct MenuBarContentView: View {
    @Bindable var viewModel: AppViewModel
    let captureService: any AudioCaptureService
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            header
            Divider()
            statusDescription
            if viewModel.isActivelyRecording || viewModel.isPaused {
                LiveWaveformView(viewModel: viewModel)
                    .padding(.vertical, Theme.Spacing.xs)
                    .transition(reduceMotion ? .identity : .opacity)
            }
            controlButtons
            if let lastError = viewModel.lastError {
                // A8: 末尾に閉じるボタン。A11: 長文時は help でフルテキストをツールチップ提供。
                HStack(alignment: .top, spacing: Theme.Spacing.xs) {
                    Label(lastError, systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.footnote)
                        .foregroundStyle(Theme.Palette.error)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(lastError)
                        .accessibilityLabel("エラー: \(lastError)")
                    Spacer(minLength: Theme.Spacing.xs)
                    Button {
                        viewModel.lastError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("このエラーメッセージを閉じる")
                    .accessibilityLabel("エラーメッセージを閉じる")
                }
            }
            Divider()
            footer
        }
        .symbolRenderingMode(.hierarchical)
        .padding(Theme.Spacing.lg)
        .frame(width: Theme.Layout.menuBarWidth)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: viewModel.captureState)
        .task {
            await viewModel.subscribeToCaptureState()
        }
        .task {
            await viewModel.refreshList()
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("localVoiceRec")
                .font(.headline)
            Spacer()
            statusBadge
        }
    }

    /// 状態バッジ — 色 + アイコン + テキストの 3 要素で表現 (HIG: アクセシビリティ)。
    @ViewBuilder
    private var statusBadge: some View {
        switch viewModel.captureState {
        case .idle:
            badge(text: "待機中", systemImage: "circle", tint: .secondary)
        case .preparing:
            badge(text: "準備中", systemImage: "hourglass", tint: .secondary)
        case .recording:
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(Theme.Palette.recording)
                    .symbolEffect(.pulse, options: reduceMotion ? .nonRepeating : .repeating)
                    .accessibilityHidden(true)
                Text("録音中")
                    .font(.caption.bold())
                    .foregroundStyle(Theme.Palette.recording)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("録音中")
        case .paused:
            badge(text: "一時停止", systemImage: "pause.circle.fill", tint: Theme.Palette.paused)
        case .finalizing:
            badge(text: "保存中", systemImage: "arrow.down.circle", tint: .secondary)
        case .failed:
            badge(text: "エラー", systemImage: "exclamationmark.circle.fill", tint: Theme.Palette.error)
        case .interrupted:
            badge(text: "中断", systemImage: "exclamationmark.triangle.fill", tint: Theme.Palette.warning)
        }
    }

    private func badge(text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption.bold())
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    @ViewBuilder
    private var statusDescription: some View {
        switch viewModel.captureState {
        case .idle:
            Text("録音を開始する準備ができています（⌘R）")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .preparing:
            Text("ハードウェアを準備しています…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .recording(let startedAt):
            // A9: 開始時刻に加えて経過時間 (mm:ss) を秒単位で更新表示する。
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("開始: \(startedAt.formatted(date: .omitted, time: .standard))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                TimelineView(.periodic(from: startedAt, by: 1.0)) { context in
                    Text("経過: \(Self.elapsedString(from: startedAt, to: context.date))")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Theme.Palette.recording)
                        .accessibilityLabel("録音経過時間 \(Self.elapsedString(from: startedAt, to: context.date))")
                }
            }
        case .paused(let startedAt, let pausedAt):
            // A9: 一時停止時も「停止地点までの経過」を出す（pausedAt 基準で固定）
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("一時停止中（開始: \(startedAt.formatted(date: .omitted, time: .standard))）")
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.paused)
                    .monospacedDigit()
                Text("経過: \(Self.elapsedString(from: startedAt, to: pausedAt))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .finalizing:
            HStack(spacing: Theme.Spacing.xs) {
                ProgressView()
                    .controlSize(.small)
                Text("ファイルを保存しています…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .failed:
            // A2: enum case 名 (`String(describing:)`) を出さない。
            // 具体的なメッセージは lastError 側で表示される。
            Text("録音中にエラーが発生しました。詳細は下のメッセージをご確認ください。")
                .font(.footnote)
                .foregroundStyle(Theme.Palette.error)
        case .interrupted(let reason, _, _):
            // A1: 中断時は「停止して保存」の操作を必ず案内する。
            Text("録音が中断されました（\(Self.label(for: reason))）。「録音を停止して保存」を押すと、ここまでの内容を保存できます。")
                .font(.footnote)
                .foregroundStyle(Theme.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 録音中経過時間を `mm:ss` (1 時間を超えるとき `h:mm:ss`) で表示する。
    private static func elapsedString(from startedAt: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(startedAt).rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    private static func label(for reason: InterruptionReason) -> String {
        switch reason {
        case .engineConfigurationChanged: return "オーディオ機器の変更"
        case .systemWillSleep: return "スリープ"
        case .audioFlowStalled: return "信号停止"
        }
    }

    /// A1: 中断 (`.interrupted`) かどうか。else 分岐に巻き込まれて
    /// 「録音開始」(disabled) で詰まる UX デッドロックを防ぐため独立判定。
    private var isInterrupted: Bool {
        if case .interrupted = viewModel.captureState { return true }
        return false
    }

    @ViewBuilder
    private var controlButtons: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if isInterrupted {
                // A1: interrupted は「停止して保存」専用ボタン（復旧不能の bug 修正）
                Button(role: .destructive) {
                    Task { await viewModel.stopRecording() }
                } label: {
                    Label("録音を停止して保存", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.recording)
                .keyboardShortcut(".", modifiers: .command) // A3
                .help("中断された録音を停止し、ここまでの内容を保存します (⌘.)")
            } else if viewModel.isActivelyRecording {
                Button {
                    Task { await viewModel.pauseRecording() }
                } label: {
                    Label("一時停止", systemImage: "pause.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("p", modifiers: .command) // A3
                .help("録音を一時停止します (⌘P)")

                Button(role: .destructive) {
                    Task { await viewModel.stopRecording() }
                } label: {
                    Label("停止", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.recording)
                .keyboardShortcut(".", modifiers: .command) // A3
                .help("録音を停止して保存します (⌘.)")
            } else if viewModel.isPaused {
                Button {
                    Task { await viewModel.resumeRecording() }
                } label: {
                    Label("再開", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("p", modifiers: .command) // A3 (一時停止と同じトグル)
                .help("録音を再開します (⌘P)")

                Button(role: .destructive) {
                    Task { await viewModel.stopRecording() }
                } label: {
                    Label("停止", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(".", modifiers: .command) // A3
                .help("録音を停止して保存します (⌘.)")
            } else {
                Button {
                    Task { await viewModel.startRecording() }
                } label: {
                    Label("録音開始", systemImage: "record.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.recording)
                .disabled(viewModel.isBusy || viewModel.isCapturing)
                .keyboardShortcut("r", modifiers: .command) // A3
                .help("マイク + システム音声の録音を開始します (⌘R)")
            }
        }
        .controlSize(.large)
    }

    private var footer: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Button {
                openRecordingListWindow()
            } label: {
                Label("録音一覧を開く", systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("過去の録音と文字起こしを表示します")
        }
    }

    /// 録音一覧ウィンドウを開いて **最前面に持ってくる**。
    ///
    /// LSUIElement=YES のメニューバーアプリでは `openWindow` だけだとウィンドウが
    /// 背面に開く（他アプリが key のまま）ことがある。明示的に Activate + Order Front。
    /// 既に開いているウィンドウなら再オープンせず、既存のものをフォアグラウンド化する。
    private func openRecordingListWindow() {
        // 既存ウィンドウを探す（タイトルベース、フォールバックは ID マッチ）
        let listWindow = NSApp.windows.first { win in
            // SwiftUI が作るウィンドウは identifier に scene id を持つ
            win.identifier?.rawValue.contains(RecordingListWindowID) == true
                || win.title == "録音一覧"
        }

        if let existing = listWindow {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
        } else {
            // 初回オープン
            openWindow(id: RecordingListWindowID)
            // SwiftUI の Window が生成されるまでわずかに待つ
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                if let w = NSApp.windows.first(where: {
                    $0.identifier?.rawValue.contains(RecordingListWindowID) == true
                        || $0.title == "録音一覧"
                }) {
                    w.makeKeyAndOrderFront(nil)
                    w.orderFrontRegardless()
                }
            }
        }
    }
}

#if DEBUG
#Preview("Idle") {
    let capture = FakeAudioCaptureService()
    return MenuBarContentView(
        viewModel: AppViewModel(
            capture: capture,
            repository: InMemoryRecordingRepository(seed: [SampleData.recording]),
            transcription: FakeTranscriptionService(),
            summary: FakeSummaryService()
        ),
        captureService: capture
    )
}

#Preview("Idle (Dark)") {
    let capture = FakeAudioCaptureService()
    return MenuBarContentView(
        viewModel: AppViewModel(
            capture: capture,
            repository: InMemoryRecordingRepository(seed: [SampleData.recording]),
            transcription: FakeTranscriptionService(),
            summary: FakeSummaryService()
        ),
        captureService: capture
    )
    .preferredColorScheme(.dark)
}
#endif
