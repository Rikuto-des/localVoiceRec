import SwiftUI
import Contracts

/// 文字起こし内検索 + フィルタ。
///
/// - リアルタイム filter (View 側で debounce: 親が `searchQuery` を即時反映、`debouncedQuery` を 200ms 後に確定)
/// - フィルタ chip: 全て / 自分 / 相手
/// - 「回り込み除外」トグル
struct TranscriptSearchBar: View {
    @Binding var query: String
    @Binding var filter: SpeakerFilter
    @Binding var hideEcho: Bool
    let matchCount: Int
    /// 入力欄にフォーカスするためのトリガ
    @FocusState.Binding var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("文字起こし内を検索", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .accessibilityLabel("文字起こし内を検索")
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("検索をクリア")
                    .accessibilityLabel("検索をクリア")
                }
                if !query.isEmpty {
                    Text(matchCount > 0 ? "\(matchCount) 件一致" : "一致なし")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(matchCount > 0 ? .secondary : Theme.Palette.warning)
                        .accessibilityLabel(matchCount > 0 ? "\(matchCount) 件一致" : "一致なし")
                }
                if query.isEmpty && !isSearchFocused {
                    Text("⌘F")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Theme.Palette.separator.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                        )
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 6)
            .background(
                Theme.Palette.textField,
                in: RoundedRectangle(cornerRadius: Theme.Layout.inputCornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Layout.inputCornerRadius, style: .continuous)
                    .strokeBorder(Theme.Palette.separator, lineWidth: 0.5)
            )

            HStack(spacing: Theme.Spacing.sm) {
                Picker("話者フィルタ", selection: $filter) {
                    ForEach(SpeakerFilter.allCases, id: \.self) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("話者で文字起こしを絞り込みます")
                .accessibilityLabel("話者フィルタ")
                Spacer()
                Toggle(isOn: $hideEcho) {
                    Text("回り込みを除外")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("相手の声がマイクに回り込んだ可能性のあるセグメントを隠す")
            }
        }
    }
}

/// 話者フィルタ。
enum SpeakerFilter: CaseIterable, Hashable {
    case all
    case mic
    case system

    var label: String {
        switch self {
        case .all: return "全て"
        case .mic: return "自分"
        case .system: return "相手"
        }
    }

    var help: String {
        switch self {
        case .all: return "全ての話者を表示"
        case .mic: return "自分 (マイク) のみ"
        case .system: return "相手 (システム音声) のみ"
        }
    }

    func includes(_ source: TranscriptSegment.Source) -> Bool {
        switch self {
        case .all: return true
        case .mic: return source == .mic
        case .system: return source == .system
        }
    }
}

#if DEBUG
private struct PreviewWrapper: View {
    @State var q = ""
    @State var f: SpeakerFilter = .all
    @State var hide = true
    @FocusState var focus: Bool
    var body: some View {
        TranscriptSearchBar(
            query: $q, filter: $f, hideEcho: $hide,
            matchCount: 0, isSearchFocused: $focus
        )
        .padding()
        .frame(width: 520)
    }
}

#Preview {
    PreviewWrapper()
}
#endif
