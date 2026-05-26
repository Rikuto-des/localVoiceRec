import SwiftUI

/// アプリ全体で使うレイアウト・色のトークン。
enum Theme {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Layout {
        static let menuBarWidth: CGFloat = 340
        static let listWindowMinWidth: CGFloat = 720
        static let listWindowMinHeight: CGFloat = 480
        static let listPaneMinWidth: CGFloat = 260
        static let detailPaneMinWidth: CGFloat = 420
        static let cornerRadius: CGFloat = 10
        static let bubbleMaxWidth: CGFloat = 320
    }

    enum Palette {
        static let micBubble = Color.accentColor.opacity(0.85)
        static let micText = Color.white
        static let systemBubble = Color(nsColor: .controlBackgroundColor)
        static let systemText = Color.primary
        static let recordingRed = Color.red
    }
}

/// よく使う日付/時間のフォーマッタ。
enum AppFormatters {
    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f
    }()

    /// 秒数を `mm:ss` 表記にする。`12.5` → `00:12`、`75.0` → `01:15`。
    static func timestamp(from seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// 録音継続時間を `H時間M分S秒` 表記にする（時間が 0 なら省略）。
    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours)時間\(minutes)分\(secs)秒"
        } else if minutes > 0 {
            return "\(minutes)分\(secs)秒"
        } else {
            return "\(secs)秒"
        }
    }
}
