import SwiftUI

/// アプリ全体で使うレイアウト・色のトークン。
///
/// HIG 準拠の方針:
/// - 色はシステムセマンティックカラー（`Color(nsColor:)`）に集約し、Dark/Light に追随
/// - サイズはすべて 8 ポイントグリッド
/// - 角丸は `controlCornerRadius` 系の値に合わせる
/// - Hardcoded `Color.red` / `Color.orange` などはここでのみ間接化（直接使用は禁止）
enum Theme {
    // MARK: - Spacing (8pt grid)
    enum Spacing {
        /// 4pt — 同種アイコン + ラベルの内側余白などに限定
        static let xs: CGFloat = 4
        /// 8pt — 標準の最小余白
        static let sm: CGFloat = 8
        /// 12pt — フォーム内のセクション要素間
        static let md: CGFloat = 12
        /// 16pt — セクション内のブロック間
        static let lg: CGFloat = 16
        /// 24pt — セクション間 (大)
        static let xl: CGFloat = 24
    }

    // MARK: - Layout
    enum Layout {
        static let menuBarWidth: CGFloat = 340
        static let listWindowMinWidth: CGFloat = 720
        static let listWindowMinHeight: CGFloat = 480
        static let listPaneMinWidth: CGFloat = 260
        static let detailPaneMinWidth: CGFloat = 420
        /// 標準カードの角丸 (HIG: medium controls)
        static let cornerRadius: CGFloat = 10
        /// 小さな pill / inline badge 用
        static let pillCornerRadius: CGFloat = 6
        static let bubbleMaxWidth: CGFloat = 320
    }

    // MARK: - Semantic colors
    /// セマンティックカラーパレット。
    ///
    /// 必ず `NSColor` のシステム色か `.accentColor` / `.primary` / `.secondary` を経由する。
    /// 直接 `Color.red` などを使うのは UI レイヤでは禁止 (ここに追加して再利用すること)。
    enum Palette {
        // ─── Recording state ───
        /// 録音中の赤。`systemRed` はライト/ダークでコントラスト調整済み。
        static let recording = Color(nsColor: .systemRed)
        /// 一時停止 / 警告の橙。
        static let warning = Color(nsColor: .systemOrange)
        /// 成功 / 完了の緑。
        static let success = Color(nsColor: .systemGreen)
        /// エラーの赤 (recording と同色だがセマンティクスで分離)。
        static let error = Color(nsColor: .systemRed)
        /// A10: システム音声 (相手) の波形・バブル等で使う色。
        /// 旧実装は `warning` (オレンジ) を共有していたが、Diagnostics の警告と
        /// 意味衝突するため別系統 (indigo) に分離。Light/Dark どちらでもコントラスト良好。
        static let systemAudio = Color(nsColor: .systemIndigo)

        // ─── Chat bubble ───
        /// 自分 (mic) のチャットバブル背景。アクセントカラーを尊重しつつ視認性を確保。
        static let micBubble = Color.accentColor
        /// 自分のチャットバブル前景。アクセント上で読める白系。
        ///
        /// HIG: アクセントの上に白を載せると Dark/Light どちらでも視認性が出やすい。
        static let micText = Color.white
        /// 相手 (system) のチャットバブル背景。
        static let systemBubble = Color(nsColor: .controlBackgroundColor)
        /// 相手のチャットバブル前景。
        static let systemText = Color.primary

        // ─── Background fills ───
        /// 一段奥のコントロール背景 (`Form` の row 風)
        static let surfaceSecondary = Color(nsColor: .controlBackgroundColor)
        /// 入力欄背景
        static let textField = Color(nsColor: .textBackgroundColor)
        /// 罫線 (薄い区切り)。HIG: separator は明示色ではなく `Divider` を優先。
        static let separator = Color(nsColor: .separatorColor)
    }
}

/// よく使う日付/時間のフォーマッタ。
///
/// `DateFormatter` / `ISO8601DateFormatter` は生成コストが高く、setter (`dateFormat` 等)
/// が走るたびに内部の format cache が無効化される。アプリ全体で頻繁に呼ばれる箇所では
/// **static let** で 1 度だけ生成して使い回す方針 (X3.8)。
///
/// `DateFormatter` は thread-safe (Apple foundation 公式) なので
/// nonisolated にしておいて差し支えない。
enum AppFormatters {
    // X3.8: DateFormatter / ISO8601DateFormatter は thread-safe (Apple foundation 公式)。
    // 都度生成すると CFLocale / CFDateFormatter の cache が無効化されるので static let
    // で共有する。macOS 26 SDK では DateFormatter は Sendable に昇格しているため
    // 修飾子は不要。ISO8601DateFormatter は未昇格なので nonisolated(unsafe)。
    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f
    }()

    /// エクスポートファイル名のサフィックス用 (yyyyMMdd, ja_JP)。
    static let exportFilenameDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    /// 診断ログ用 ISO-8601 (fractional seconds 付き)。
    nonisolated(unsafe) static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// 秒数を `mm:ss` 表記にする。`12.5` → `00:12`、`75.0` → `01:15`。
    static func timestamp(from seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// 秒数を `hh:mm:ss` 表記にする。`75.0` → `00:01:15`。
    static func timestampHMS(from seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// VoiceOver 用の読み上げ表記。`75.0` → `0時1分15秒`。
    static func timestampHMSSpoken(from seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return "\(h)時\(m)分\(s)秒"
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

// MARK: - Convenience view modifiers

extension View {
    /// HIG 準拠の "card" 背景を当てる（`.regularMaterial` ベース、フォールバックは controlBackground）。
    /// セクションを軽く浮かせる用途に使う。
    func cardSurface(cornerRadius: CGFloat = Theme.Layout.cornerRadius) -> some View {
        self.background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Theme.Palette.separator.opacity(0.4), lineWidth: 0.5)
        )
    }

    /// より控えめな塗り (フォーム行など)。Material を使わず `controlBackgroundColor` を使う。
    func subtleSurface(cornerRadius: CGFloat = Theme.Layout.cornerRadius) -> some View {
        self.background(
            Theme.Palette.surfaceSecondary,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}
