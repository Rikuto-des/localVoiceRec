import SwiftUI

/// 診断パネルの「診断ログをコピー」ボタンとその UX。
///
/// 直近 5 分の os.log エントリを取得 → クリップボードへコピー → 1.6 秒間チェックマーク表示。
/// 取得失敗時はアラート。`DiagnosticsLogCollecting` で OSLogStore 依存を分離してあるため、
/// プレビュー / テストではモック差し替え可能。
struct LogCopySection: View {
    /// ログ取得実装。デフォルトは本番 `OSLogStore` を叩く実装。
    let collector: any DiagnosticsLogCollecting

    @State private var copyState: CopyState = .idle
    @State private var copyAlert: CopyAlert?

    private enum CopyState: Equatable {
        case idle
        case copying
        case success
    }

    private struct CopyAlert: Identifiable {
        let id = UUID()
        let message: String
    }

    init(collector: any DiagnosticsLogCollecting = DiagnosticsLogCollector()) {
        self.collector = collector
    }

    var body: some View {
        Button {
            Task { await copyDiagnosticsLog() }
        } label: {
            if copyState == .success {
                Label("✓ コピーしました", systemImage: "checkmark.circle.fill")
            } else {
                Label("診断ログをコピー", systemImage: "doc.on.clipboard")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(copyState == .copying)
        .help("直近 5 分の os.log エントリをクリップボードへ")
        .alert(item: $copyAlert) { alert in
            Alert(
                title: Text("診断ログのコピー"),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    /// C4: 直近 5 分の os.log エントリを取得し、テキスト化してクリップボードへコピーする。
    /// OSLogStore 周りは `DiagnosticsLogCollector` に分離済み。
    private func copyDiagnosticsLog() async {
        copyState = .copying
        defer {
            if copyState == .copying { copyState = .idle }
        }
        let result = await collector.collectRecentLogs(
            durationSec: 300,
            maxEntries: 500,
            maxBytes: 100_000
        )
        switch result {
        case .success(let text):
            copyToClipboard(text)
            copyState = .success
            // 1.6 秒後に idle に戻す
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                if copyState == .success { copyState = .idle }
            }
        case .failure(let message):
            copyState = .idle
            copyAlert = CopyAlert(message: message)
        }
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
