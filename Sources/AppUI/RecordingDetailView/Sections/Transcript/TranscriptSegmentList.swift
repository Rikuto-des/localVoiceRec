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
        .onReceive(NotificationCenter.default.publisher(for: .focusTranscriptSearch)) { _ in
            isSearchFocused = true
        }
    }

    // MARK: - Derived

    private var filteredSegments: [TranscriptSegment] {
        TranscriptSegmentFilter.apply(
            segments,
            query: debouncedQuery,
            filter: filter,
            hideEcho: hideEcho
        )
    }

    private var matchCount: Int {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
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
            Text("検索語句やフィルタ条件を変更してみてください。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                query = ""
                debouncedQuery = ""
                filter = .all
            } label: {
                Label("検索とフィルタをリセット", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, Theme.Spacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(Theme.Spacing.lg)
        .subtleSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("一致するセグメントがありません")
    }
}

/// `TranscriptSegmentList.filteredSegments` 相当の純関数版。
///
/// テストから SwiftUI View struct のメタタイプにアクセスすると runtime が
/// 不安定になる (`swiftpm-testing-helper` の SIGTRAP) ため、ロジックは
/// View 外の独立した namespace に切り出している。
enum TranscriptSegmentFilter {
    /// 引数:
    /// - `query`: 検索クエリ (前後空白は trim される)
    /// - `filter`: 話者フィルタ
    /// - `hideEcho`: true なら `isLikelyEcho` を除外
    static func apply(
        _ segments: [TranscriptSegment],
        query: String,
        filter: SpeakerFilter,
        hideEcho: Bool
    ) -> [TranscriptSegment] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
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
