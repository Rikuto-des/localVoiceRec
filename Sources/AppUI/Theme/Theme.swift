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
        /// 入力フィールドの角丸 (TextField / SearchField)
        static let inputCornerRadius: CGFloat = 8
        /// チャットバブルの角丸 (やや丸め)
        static let bubbleCornerRadius: CGFloat = 12
        /// 小さな pill / inline badge 用
        static let pillCornerRadius: CGFloat = 6
        static let bubbleMaxWidth: CGFloat = 480
        /// セクション本文の Label アイコンの幅 (Summary block container 等)
        static let iconLeading: CGFloat = 20
        /// hairline 罫線 (0.5pt)
        static let hairline: CGFloat = 0.5
        /// 通常の罫線
        static let border: CGFloat = 1
    }

    // MARK: - Typography ramp
    /// アプリ全体で使う型階層トークン。
    ///
    /// HIG の Dynamic Type 階層 (`largeTitle`/`title*`/`headline`/...) を統一的に
    /// 役割名にマッピングし、各 view が `.headline.weight(.semibold)` のような
    /// アドホックな組み合わせを書かないようにする。
    enum Typography {
        /// 詳細ビューのメインタイトル (録音タイトル等)。macOS detail pane では
        /// `.title2` だと大きすぎる傾向があるため `.title3` を採用。
        static let detailTitle: Font = .title3.weight(.semibold)
        /// セクション見出し (文字起こし / 要約 / 録音波形 など)
        static let sectionTitle: Font = .headline
        /// セクション内ブロックの見出し (Overview / Decisions など)
        static let subsectionTitle: Font = .subheadline.weight(.semibold)
        /// 本文 (チャットバブル等)
        static let body: Font = .body
        /// 本文補足
        static let bodySecondary: Font = .footnote
        /// メタ情報 (件数 / タイムスタンプ)、桁揃え数値
        static let metadata: Font = .caption.monospacedDigit()
        /// pill / badge の小ラベル
        static let pill: Font = .caption2.monospacedDigit()
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
        /// 警告/中断の橙。`paused` (黄) と意味分離。
        static let warning = Color(nsColor: .systemOrange)
        /// 一時停止 (ユーザー操作) の黄。`warning` と区別する。
        static let paused = Color(nsColor: .systemYellow)
        /// 成功 / 完了の緑。
        static let success = Color(nsColor: .systemGreen)
        /// 情報メッセージ (notice) の青。
        static let info = Color(nsColor: .systemBlue)
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

    /// VoiceOver 用の読み上げ表記。`75.0` → `1分15秒`、`3675.0` → `1時間1分15秒`。
    /// X4.9: 0 時のときは「0時」を省略し、VoiceOver の冗長な読み上げを避ける。
    static func timestampHMSSpoken(from seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return "\(h)時間\(m)分\(s)秒"
        }
        return "\(m)分\(s)秒"
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

/// セマンティック callout の色合い。
enum CalloutTone {
    case info, success, warning, error

    fileprivate var color: Color {
        switch self {
        case .info: return Theme.Palette.info
        case .success: return Theme.Palette.success
        case .warning: return Theme.Palette.warning
        case .error: return Theme.Palette.error
        }
    }

    fileprivate var systemImage: String {
        switch self {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "exclamationmark.octagon.fill"
        }
    }
}

extension View {
    /// HIG 準拠の "card" 背景を当てる（`.regularMaterial` ベース、Reduce Transparency 時は solid fill）。
    /// セクションを軽く浮かせる親 surface に使う。
    func cardSurface(cornerRadius: CGFloat = Theme.Layout.cornerRadius) -> some View {
        modifier(CardSurfaceModifier(cornerRadius: cornerRadius))
    }

    /// より控えめな塗り (フォーム行など)。Material を使わず `controlBackgroundColor` を使う。
    /// 子要素 surface として使う (card の中の block)。
    func subtleSurface(cornerRadius: CGFloat = Theme.Layout.cornerRadius) -> some View {
        self.background(
            Theme.Palette.surfaceSecondary,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }

    /// セマンティック callout バナー (info / success / warning / error)。
    /// 旧実装は各 view で同じ `tint.opacity(0.12)` + `tint.opacity(0.4)` 0.5pt の枠を
    /// 手書きしていたが、本 modifier に集約することで一貫性とアクセシビリティ
    /// (Reduce Transparency 対応) を担保する。
    func calloutBanner(tone: CalloutTone, cornerRadius: CGFloat = Theme.Layout.cornerRadius) -> some View {
        modifier(CalloutBannerModifier(tone: tone, cornerRadius: cornerRadius))
    }
}

private struct CardSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return Group {
            if reduceTransparency {
                content.background(Theme.Palette.surfaceSecondary, in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
            }
        }
        .overlay(
            shape.strokeBorder(Theme.Palette.separator.opacity(0.4), lineWidth: Theme.Layout.hairline)
        )
    }
}

private struct CalloutBannerModifier: ViewModifier {
    let tone: CalloutTone
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let bgOpacity = reduceTransparency ? 0.22 : 0.12
        return content
            .padding(Theme.Spacing.sm)
            .background(tone.color.opacity(bgOpacity), in: shape)
            .overlay(shape.strokeBorder(tone.color.opacity(0.4), lineWidth: Theme.Layout.hairline))
    }
}

/// アイコン付き callout — 文字列 + 任意の trailing view (主に Button) を渡すと
/// 標準的なレイアウトで `calloutBanner(tone:)` を適用する。
struct CalloutView<Trailing: View>: View {
    let tone: CalloutTone
    let title: String?
    let message: String
    @ViewBuilder let trailing: () -> Trailing

    init(tone: CalloutTone, title: String? = nil, message: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.tone = tone
        self.title = title
        self.message = message
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: tone.systemImage)
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                if let title {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                }
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .calloutBanner(tone: tone)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title.map { "\($0). \(message)" } ?? message)
    }
}
