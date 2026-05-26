import SwiftUI
import Contracts

/// メニューバーをクリックしたときに開く小ウィンドウの最小実装。
/// S2-C で本格的なビューに差し替える。
struct MenuBarContentView: View {
    let capture: any AudioCaptureService
    let repository: any RecordingRepository
    let transcription: any TranscriptionService
    let summary: any SummaryService

    @State private var currentState: CaptureState = .idle
    @State private var lastError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("localVoiceRec")
                    .font(.headline)
                Spacer()
                statusBadge
            }
            Divider()

            statusDescription

            HStack {
                Button(action: handleStart) {
                    Label("録音開始", systemImage: "record.circle")
                }
                .disabled(isRecording)

                Button(action: handleStop) {
                    Label("停止", systemImage: "stop.circle")
                }
                .disabled(!isRecording)
            }

            if let lastError {
                Text(lastError)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Divider()
            Button("終了") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 320)
        .task { await subscribeState() }
    }

    private var isRecording: Bool {
        switch currentState {
        case .recording, .paused, .preparing, .finalizing: return true
        case .idle, .failed: return false
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch currentState {
        case .idle:
            Text("待機中").foregroundStyle(.secondary)
        case .preparing:
            Text("準備中").foregroundStyle(.secondary)
        case .recording:
            Label("録音中", systemImage: "circle.fill").foregroundStyle(.red)
        case .paused:
            Text("一時停止").foregroundStyle(.orange)
        case .finalizing:
            Text("保存中").foregroundStyle(.secondary)
        case .failed:
            Text("エラー").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var statusDescription: some View {
        switch currentState {
        case .idle:
            Text("メニューバーから録音を開始できます").font(.caption).foregroundStyle(.secondary)
        case .preparing:
            Text("ハードウェアを準備しています...").font(.caption)
        case .recording(let startedAt):
            Text("開始 \(startedAt.formatted(date: .omitted, time: .standard))").font(.caption)
        case .paused(let startedAt, _):
            Text("一時停止中（開始 \(startedAt.formatted(date: .omitted, time: .standard)))").font(.caption)
        case .finalizing:
            Text("ファイルを保存しています...").font(.caption)
        case .failed(let error):
            Text(String(describing: error)).font(.caption).foregroundStyle(.red)
        }
    }

    private func handleStart() {
        Task {
            do {
                let dir = FileManager.default.temporaryDirectory
                _ = try await capture.start(in: dir, title: nil)
                lastError = nil
            } catch {
                lastError = "開始失敗: \(error)"
            }
        }
    }

    private func handleStop() {
        Task {
            do {
                _ = try await capture.stop()
                lastError = nil
            } catch {
                lastError = "停止失敗: \(error)"
            }
        }
    }

    private func subscribeState() async {
        for await s in capture.stateUpdates {
            currentState = s
        }
    }
}
