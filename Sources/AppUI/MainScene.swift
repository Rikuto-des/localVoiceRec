import SwiftUI
import Contracts

/// アプリ全体のシーン定義。
///
/// MenuBarExtra（メニューバー本体）と、録音一覧を表示する Window を持つ。
/// 各サービスをプロトコル経由で受け取り、`AppViewModel` を 1 つだけ生成して
/// すべての子ビューに渡す。
public struct MainScene: Scene {
    @State private var viewModel: AppViewModel

    public init(
        capture: any AudioCaptureService,
        repository: any RecordingRepository,
        transcription: any TranscriptionService,
        summary: any SummaryService
    ) {
        _viewModel = State(
            initialValue: AppViewModel(
                capture: capture,
                repository: repository,
                transcription: transcription,
                summary: summary
            )
        )
    }

    public var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(viewModel: viewModel)
        } label: {
            MenuBarLabel(state: viewModel.captureState)
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
    }
}

/// メニューバーアイコン。録音中は赤丸、停止中は通常のマイク。
private struct MenuBarLabel: View {
    let state: CaptureState

    var body: some View {
        switch state {
        case .recording:
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
        case .paused:
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
        case .preparing, .finalizing:
            Image(systemName: "mic.circle")
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.red)
        case .idle:
            Image(systemName: "mic.fill")
        }
    }
}
