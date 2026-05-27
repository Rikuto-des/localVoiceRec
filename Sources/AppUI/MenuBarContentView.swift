import SwiftUI
import AppKit
import Contracts

/// メニューバーをクリックしたときに表示される小ウィンドウ。
///
/// 録音操作（開始 / 停止 / 一時停止 / 再開）と、録音一覧ウィンドウへの導線を提供する。
struct MenuBarContentView: View {
    @Bindable var viewModel: AppViewModel
    let captureService: any AudioCaptureService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            header
            Divider()
            statusDescription
            if viewModel.isActivelyRecording || viewModel.isPaused {
                LiveWaveformView(service: captureService)
                    .padding(.vertical, Theme.Spacing.xs)
            }
            controlButtons
            if let lastError = viewModel.lastError {
                Text(lastError)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(Theme.Spacing.lg)
        .frame(width: Theme.Layout.menuBarWidth)
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

    @ViewBuilder
    private var statusBadge: some View {
        switch viewModel.captureState {
        case .idle:
            badge(text: "待機中", color: .secondary)
        case .preparing:
            badge(text: "準備中", color: .secondary)
        case .recording:
            HStack(spacing: Theme.Spacing.xs) {
                Circle()
                    .fill(Theme.Palette.recordingRed)
                    .frame(width: 8, height: 8)
                Text("録音中")
                    .font(.caption.bold())
                    .foregroundStyle(Theme.Palette.recordingRed)
            }
        case .paused:
            badge(text: "一時停止", color: .orange)
        case .finalizing:
            badge(text: "保存中", color: .secondary)
        case .failed:
            badge(text: "エラー", color: .red)
        }
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.bold())
            .foregroundStyle(color)
    }

    @ViewBuilder
    private var statusDescription: some View {
        switch viewModel.captureState {
        case .idle:
            Text("メニューバーから録音を開始できます")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .preparing:
            Text("ハードウェアを準備しています…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .recording(let startedAt):
            Text("開始: \(startedAt.formatted(date: .omitted, time: .standard))")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .paused(let startedAt, _):
            Text("一時停止中（開始: \(startedAt.formatted(date: .omitted, time: .standard))）")
                .font(.caption)
                .foregroundStyle(.orange)
        case .finalizing:
            Text("ファイルを保存しています…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let error):
            Text("失敗: \(String(describing: error))")
                .font(.caption)
                .foregroundStyle(.red)
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
                }
                Button(role: .destructive) {
                    Task { await viewModel.stopRecording() }
                } label: {
                    Label("停止", systemImage: "stop.circle.fill")
                }
            } else if viewModel.isPaused {
                Button {
                    Task { await viewModel.resumeRecording() }
                } label: {
                    Label("再開", systemImage: "play.circle")
                }
                Button(role: .destructive) {
                    Task { await viewModel.stopRecording() }
                } label: {
                    Label("停止", systemImage: "stop.circle.fill")
                }
            } else {
                Button {
                    Task { await viewModel.startRecording() }
                } label: {
                    Label("録音開始", systemImage: "record.circle")
                }
                .disabled(viewModel.isBusy || viewModel.isCapturing)
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
            .controlSize(.regular)

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("終了")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut("q")
            .controlSize(.regular)
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
