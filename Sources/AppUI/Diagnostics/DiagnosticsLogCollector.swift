import Foundation
import OSLog
import Contracts

/// 診断ログ収集の結果。UI 側でエラー時はアラートを出したいので、成否を区別して返す。
public enum DiagnosticsLogCollectionResult: Sendable, Equatable {
    /// 取得成功。`text` はフォーマット済みのログテキスト（エントリが無い場合はその旨）。
    case success(text: String)
    /// 取得失敗。`message` は人間可読のエラー文。
    case failure(message: String)
}

/// 診断ログ収集のプロトコル。テストでは差し替え可能にしておく。
///
/// 実装側は `OSLogStore` を裏で叩くため、本番依存を `DiagnosticsLogCollector`
/// に閉じ込めておくことで View レイヤーの SwiftUI 部分を純粋な表示ロジックに保つ。
public protocol DiagnosticsLogCollecting: Sendable {
    /// 指定された期間の os.log エントリを取得し、テキスト化して返す。
    ///
    /// - Parameters:
    ///   - durationSec: 何秒前までを対象にするか (例: 300 = 直近 5 分)
    ///   - maxEntries: 返却する最大行数
    ///   - maxBytes: テキスト全体の概算最大バイト数
    func collectRecentLogs(
        durationSec: TimeInterval,
        maxEntries: Int,
        maxBytes: Int
    ) async -> DiagnosticsLogCollectionResult
}

/// `OSLogStore` を使った本番実装。
///
/// ## OSLogStore の制約 (旧 DiagnosticsPanel から踏襲)
/// - macOS 12+ が必要。
/// - 非サンドボックスのアプリは `.local` ストアを開ける。サンドボックス下では
///   `OSLogEntryLog.subsystem` フィルタが効くが、他プロセスのログにはアクセス不可。
/// - 取得は同期的でログ件数によっては時間がかかるため、`Task.detached` でオフメイン実行。
/// - 件数 / バイト数の上限を設けてアプリが固まらないようにする (デフォルト 500 件 / 100KB)。
///
/// フォーマット: `[timestamp] [level] [category] message`
public struct DiagnosticsLogCollector: DiagnosticsLogCollecting {
    private let subsystem: String

    public init(subsystem: String = AppIdentifiers.logSubsystem) {
        self.subsystem = subsystem
    }

    public func collectRecentLogs(
        durationSec: TimeInterval,
        maxEntries: Int,
        maxBytes: Int
    ) async -> DiagnosticsLogCollectionResult {
        let subsystem = self.subsystem
        let result: Result<String, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let store = try OSLogStore.local()
                let since = Date().addingTimeInterval(-durationSec)
                let position = store.position(date: since)
                let predicate = NSPredicate(format: "subsystem == %@", subsystem)
                let entries = try store.getEntries(at: position, matching: predicate)

                var lines: [String] = []
                var totalBytes = 0
                // X3.8: 都度生成せず、共有 static フォーマッタを参照
                let dateFmt = AppFormatters.iso8601Fractional

                for case let entry as OSLogEntryLog in entries {
                    let level = Self.levelLabel(entry.level)
                    let line = "[\(dateFmt.string(from: entry.date))] [\(level)] [\(entry.category)] \(entry.composedMessage)"
                    let byteEstimate = line.utf8.count + 1
                    if lines.count >= maxEntries || totalBytes + byteEstimate > maxBytes {
                        lines.append("--- truncated (limit reached) ---")
                        break
                    }
                    lines.append(line)
                    totalBytes += byteEstimate
                }
                if lines.isEmpty {
                    let minutes = Int(durationSec / 60)
                    lines.append("(no log entries in last \(minutes) minutes for subsystem \(subsystem))")
                }
                return .success(lines.joined(separator: "\n"))
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let text):
            return .success(text: text)
        case .failure(let error):
            return .failure(message: "ログ取得に失敗しました: \(error.localizedDescription)")
        }
    }

    private static func levelLabel(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        case .undefined: return "undefined"
        @unknown default: return "?"
        }
    }
}
