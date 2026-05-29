import Foundation

/// 詳細ビューの「文字起こし / 要約」のタブ選択値。
///
/// 長文字起こし(300+ 行)で下部の要約にアクセスしにくくなる問題への対策として、
/// 詳細ビューの中央セクションをタブ式 (Picker `.segmented`) に切り替える。
/// 各セクションが画面全幅を独占できるので、長さに関係なくジャンプ 1 クリックで到達できる。
///
/// 診断 (Diagnostics) はタブには含めず、最下部の折り畳みセクションのまま (副次的な情報)。
enum DetailSectionTab: String, CaseIterable, Identifiable, Sendable, Hashable {
    case transcript
    case summary

    var id: String { rawValue }

    /// セグメント Picker / a11y ラベルに使う表示名。
    var label: String {
        switch self {
        case .transcript: return "文字起こし"
        case .summary:    return "要約"
        }
    }

    /// セグメント Picker のアイコン (補助、HIG 的にラベル+アイコンが見やすい)。
    var systemImage: String {
        switch self {
        case .transcript: return "text.bubble"
        case .summary:    return "doc.text"
        }
    }
}
