import Foundation

/// ExportKit 内で共有するフォーマッタ群。UI 側 `AppFormatters` とは独立。
enum ExportFormatters {
    /// 議事録ヘッダ用の日時。`yyyy-MM-dd HH:mm` 形式。
    static let headerDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// 期限表示用。`yyyy-MM-dd`。
    static let dueDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// セグメントの開始秒を `mm:ss` または 1 時間超なら `hh:mm:ss` 形式に整形する。
    static func timestamp(from seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// `duration` を「N 分」表記にする。1 時間以上のときは「H 時間 M 分」。
    static func durationLabel(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours) 時間 \(minutes) 分"
        }
        return "\(minutes) 分"
    }
}
