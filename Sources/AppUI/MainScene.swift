import SwiftUI
import Contracts

/// アプリ全体のシーン定義。
///
/// MenuBarExtra（メニューバー本体）と、録音一覧を表示する Window を持つ。
/// 各サービスをプロトコル経由で受け取り、`AppViewModel` を 1 つだけ生成して
/// すべての子ビューに渡す。
public struct MainScene: Scene {
    @State private var viewModel: AppViewModel
    private let captureService: any AudioCaptureService

    public init(
        capture: any AudioCaptureService,
        repository: any RecordingRepository,
        transcription: any TranscriptionService,
        summary: any SummaryService
    ) {
        self.captureService = capture
        let vm = AppViewModel(
            capture: capture,
            repository: repository,
            transcription: transcription,
            summary: summary
        )
        // ViewModel が永続的に audioLevels を購読開始。
        // メニューバーポップアップが閉じても更新が止まらないため。
        vm.startObservingAudioLevels()
        _viewModel = State(initialValue: vm)
    }

    public var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(viewModel: viewModel, captureService: captureService)
        } label: {
            MenuBarLabel(
                state: viewModel.captureState,
                isProcessing: viewModel.isTranscribing || viewModel.isSummarizing
            )
        }
        .menuBarExtraStyle(.window)

        Window("録音一覧", id: RecordingListWindowID) {
            RecordingListView(viewModel: viewModel)
        }
        .defaultSize(
            width: Theme.Layout.listWindowMinWidth,
            height: Theme.Layout.listWindowMinHeight
        )
        .windowResizability(.contentMinSize)
        // A3: 「録音」メニュー — メインメニューに正式登録して、ウィンドウが
        // フォアグラウンドのときに ⌘R / ⌘. / ⌘P でグローバル操作できるようにする。
        // メニューバーポップアップを開かなくても録音制御が可能。
        .commands {
            RecordingCommands(viewModel: viewModel)
        }
    }
}

/// A3: 「録音」メニュー。`CommandMenu` でメインメニューにマウントされる。
///
/// MenuBarExtra (LSUIElement=YES) なアプリでも、Window がフォアグラウンドであれば
/// 通常のメインメニューが表示される。ショートカットはどの状態でも有効。
private struct RecordingCommands: Commands {
    @Bindable var viewModel: AppViewModel

    var body: some Commands {
        CommandMenu("録音") {
            Button(primaryActionLabel) {
                Task { await primaryAction() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(primaryActionDisabled)

            Button("停止") {
                Task { await viewModel.stopRecording() }
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!viewModel.isCapturing)

            Button(viewModel.isPaused ? "再開" : "一時停止") {
                Task { await togglePause() }
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(!viewModel.isActivelyRecording && !viewModel.isPaused)
        }
    }

    /// ⌘R: idle/failed のときは「開始」、それ以外（録音中など）は「停止」のトグル。
    private var primaryActionLabel: String {
        if viewModel.isCapturing { return "録音を停止" }
        return "録音を開始"
    }

    private var primaryActionDisabled: Bool {
        if case .interrupted = viewModel.captureState {
            return false // 中断時は停止して保存できるよう開放
        }
        // preparing / finalizing は連打防止
        switch viewModel.captureState {
        case .preparing, .finalizing: return true
        default: return viewModel.isBusy && !viewModel.isCapturing
        }
    }

    private func primaryAction() async {
        if viewModel.isCapturing {
            await viewModel.stopRecording()
        } else {
            await viewModel.startRecording()
        }
    }

    private func togglePause() async {
        if viewModel.isPaused {
            await viewModel.resumeRecording()
        } else if viewModel.isActivelyRecording {
            await viewModel.pauseRecording()
        }
    }
}

/// メニューバーアイコン。
///
/// HIG (Menu bar extras): モノクロームのテンプレートが原則だが、録音中だけは
/// 「進行中操作」を一目で伝えるため `systemRed` の `record.circle.fill` に切り替える。
/// その他は SF Symbol のシンプルなアイコンに留め、必要なときだけ `symbolEffect` を使う。
///
/// 状態:
/// - recording: 赤丸 (pulse)
/// - paused: pause.circle (橙)
/// - preparing / finalizing: ローディング系
/// - failed: 警告
/// - idle + processing: マイク + パルス
/// - idle: シンプルなマイク
private struct MenuBarLabel: View {
    let state: CaptureState
    let isProcessing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch state {
            case .recording:
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .symbolEffect(.pulse, options: reduceMotion ? .nonRepeating : .repeating)
                    .accessibilityLabel("録音中")
            case .paused:
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .accessibilityLabel("一時停止中")
            case .preparing:
                Image(systemName: "mic.circle")
                    .accessibilityLabel("準備中")
            case .finalizing:
                Image(systemName: "arrow.down.circle")
                    .accessibilityLabel("保存中")
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .accessibilityLabel("録音エラー")
            case .interrupted:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .accessibilityLabel("録音中断")
            case .idle:
                if isProcessing {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .symbolEffect(.pulse, options: reduceMotion ? .nonRepeating : .repeating)
                        .accessibilityLabel("処理中")
                } else {
                    Image("MenubarMark", bundle: .main)
                        .renderingMode(.template)
                        .accessibilityLabel("localVoiceRec")
                }
            }
        }
    }
}
