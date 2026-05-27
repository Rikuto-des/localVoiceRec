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
/// - 終了は `.borderless` + role: .destructive
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
            if shouldShowLiveTranscript {
                LiveTranscriptStrip(
                    segments: viewModel.liveTranscriptSegments,
                    isRecording: viewModel.isActivelyRecording || viewModel.isPaused
                )
                .transition(reduceMotion ? .identity : .opacity.animation(.easeInOut(duration: 0.5)))
            }
            controlButtons
            if let lastError = viewModel.lastError {
                Label(lastError, systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.error)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("エラー: \(lastError)")
            }
            Divider()
            footer
        }
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

    // MARK: - Derived

    /// 録音中、もしくは停止直後の grace period 中 (バッファに残りあり) は表示する。
    private var shouldShowLiveTranscript: Bool {
        if viewModel.isActivelyRecording || viewModel.isPaused { return true }
        // 停止直後、segments がまだ残っていれば 0.5s フェード用に保持
        return !viewModel.liveTranscriptSegments.isEmpty
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
            badge(text: "一時停止", systemImage: "pause.circle.fill", tint: Theme.Palette.warning)
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
            Text("メニューバーから録音を開始できます")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .preparing:
            Text("ハードウェアを準備しています…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .recording(let startedAt):
            Text("開始: \(startedAt.formatted(date: .omitted, time: .standard))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case .paused(let startedAt, _):
            Text("一時停止中（開始: \(startedAt.formatted(date: .omitted, time: .standard))）")
                .font(.footnote)
                .foregroundStyle(Theme.Palette.warning)
                .monospacedDigit()
        case .finalizing:
            Text("ファイルを保存しています…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .failed(let error):
            Text("失敗: \(String(describing: error))")
                .font(.footnote)
                .foregroundStyle(Theme.Palette.error)
        case .interrupted(let reason, _, _):
            Text("録音が中断されました (\(Self.label(for: reason)))。停止してから再度開始してください。")
                .font(.footnote)
                .foregroundStyle(Theme.Palette.warning)
        }
    }

    private static func label(for reason: InterruptionReason) -> String {
        switch reason {
        case .engineConfigurationChanged: return "オーディオ機器の変更"
        case .systemWillSleep: return "スリープ"
        case .audioFlowStalled: return "信号停止"
        }
    }

    @ViewBuilder
    private var controlButtons: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if viewModel.isActivelyRecording {
                Button {
                    Task { await viewModel.pauseRecording() }
                } label: {
                    Label("一時停止", systemImage: "pause.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help("録音を一時停止します")

                Button(role: .destructive) {
                    Task { await viewModel.stopRecording() }
                } label: {
                    Label("停止", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.recording)
                .help("録音を停止して保存します")
            } else if viewModel.isPaused {
                Button {
                    Task { await viewModel.resumeRecording() }
                } label: {
                    Label("再開", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .help("録音を再開します")

                Button(role: .destructive) {
                    Task { await viewModel.stopRecording() }
                } label: {
                    Label("停止", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help("録音を停止して保存します")
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
                .help("マイク + システム音声の録音を開始します")
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

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("終了")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q")
            .controlSize(.regular)
            .help("localVoiceRec を終了します (⌘Q)")
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
