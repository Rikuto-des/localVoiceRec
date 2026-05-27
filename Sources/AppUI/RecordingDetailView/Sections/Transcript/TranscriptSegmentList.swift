import SwiftUI
import Contracts

/// 検索バー + フィルタチップ + セグメント一覧を束ねるホスト View。
///
/// 親 (`TranscriptSection`) からは `segments` と `hideEcho`/`searchQuery` の
/// `Binding` を受け取り、フィルタリングと表示はここで完結させる。
struct TranscriptSegmentList: View {
    let segments: [TranscriptSegment]
    @Binding var hideEcho: Bool

    @State private var query: String = ""
    @State private var debouncedQuery: String = ""
    @State private var filter: SpeakerFilter = .all
    @FocusState var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            TranscriptSearchBar(
                query: $query,
                filter: $filter,
                hideEcho: $hideEcho,
                matchCount: matchCount,
                isSearchFocused: $isSearchFocused
            )
            .onChange(of: query) { _, newValue in
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if query == newValue {
                        debouncedQuery = newValue
                    }
                }
            }
            .onAppear {
                debouncedQuery = query
            }

            if filteredSegments.isEmpty {
                emptyFilterBox
            } else {
                ForEach(filteredSegments) { seg in
                    TranscriptSegmentRow(
                        segment: seg,
                        highlightQuery: debouncedQuery,
                        onCopy: {},
                        onPlayFromHere: {}
                    )
                }
            }
        }
        .onKeyPress(.init("f"), phases: .down) { press in
            if press.modifiers.contains(.command) {
                isSearchFocused = true
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Derived

    private var filteredSegments: [TranscriptSegment] {
        let trimmed = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return segments.filter { seg in
            if hideEcho && seg.isLikelyEcho { return false }
            if !filter.includes(seg.source) { return false }
            if !trimmed.isEmpty {
                if seg.text.range(of: trimmed, options: [.caseInsensitive]) == nil {
                    return false
                }
            }
            return true
        }
    }

    private var matchCount: Int {
        let trimmed = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return segments.reduce(0) { count, seg in
            count + (seg.text.range(of: trimmed, options: [.caseInsensitive]) != nil ? 1 : 0)
        }
    }

    @ViewBuilder
    private var emptyFilterBox: some View {
        VStack(alignment: .center, spacing: Theme.Spacing.xs) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("一致するセグメントがありません")
                .font(.subheadline)
                .fontWeight(.medium)
            Text("検索語句やフィルタ条件を見直してください。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(Theme.Spacing.lg)
        .subtleSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("一致するセグメントがありません")
    }
}

#if DEBUG
#Preview {
    let rid = UUID()
    return TranscriptSegmentList(
        segments: [
            TranscriptSegment(recordingID: rid, source: .mic, startSec: 0, endSec: 3,
                              text: "では、本日のアジェンダから確認していきます。", isFinal: true),
            TranscriptSegment(recordingID: rid, source: .system, startSec: 4, endSec: 7,
                              text: "了解しました。アジェンダを共有します。", isFinal: true),
            TranscriptSegment(recordingID: rid, source: .system, startSec: 8, endSec: 9,
                              text: "（回り込み）", isFinal: true, isLikelyEcho: true),
        ],
        hideEcho: .constant(true)
    )
    .padding()
    .frame(width: 580)
}
#endif
