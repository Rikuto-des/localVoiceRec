import Foundation
import Testing
@testable import AppUI
import Contracts

/// `TranscriptSegmentFilter.apply` の検索 / 話者フィルタ / echo 抑制ロジック検証。
@Suite("TranscriptSegmentFilter.apply")
struct TranscriptSegmentListFilterTests {

    private static let rid = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!

    private static func seg(
        source: TranscriptSegment.Source,
        text: String,
        echo: Bool = false,
        start: Double = 0
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: UUID(),
            recordingID: rid,
            source: source,
            startSec: start,
            endSec: start + 1.0,
            text: text,
            isFinal: true,
            isLikelyEcho: echo
        )
    }

    @Test("query 空 + all + hideEcho=false → 全件返る")
    func noFilterReturnsAll() {
        let segs = [
            Self.seg(source: .mic, text: "hello"),
            Self.seg(source: .system, text: "world"),
            Self.seg(source: .mic, text: "again", echo: true),
        ]
        let out = TranscriptSegmentFilter.apply(segs, query: "", filter: .all, hideEcho: false)
        #expect(out.count == 3)
    }

    @Test("hideEcho=true → isLikelyEcho が除外される")
    func hideEchoFiltersOutEcho() {
        let segs = [
            Self.seg(source: .mic, text: "normal"),
            Self.seg(source: .mic, text: "回り込み", echo: true),
        ]
        let out = TranscriptSegmentFilter.apply(segs, query: "", filter: .all, hideEcho: true)
        #expect(out.count == 1)
        #expect(out.first?.text == "normal")
    }

    @Test("filter=.mic → mic のみ")
    func micFilter() {
        let segs = [
            Self.seg(source: .mic, text: "mine"),
            Self.seg(source: .system, text: "theirs"),
        ]
        let out = TranscriptSegmentFilter.apply(segs, query: "", filter: .mic, hideEcho: false)
        #expect(out.count == 1)
        #expect(out.first?.source == .mic)
    }

    @Test("filter=.system → system のみ")
    func systemFilter() {
        let segs = [
            Self.seg(source: .mic, text: "mine"),
            Self.seg(source: .system, text: "theirs"),
        ]
        let out = TranscriptSegmentFilter.apply(segs, query: "", filter: .system, hideEcho: false)
        #expect(out.count == 1)
        #expect(out.first?.source == .system)
    }

    @Test("query 部分一致 (case insensitive)")
    func querySubstringCaseInsensitive() {
        let segs = [
            Self.seg(source: .mic, text: "Hello WORLD"),
            Self.seg(source: .mic, text: "goodbye"),
        ]
        let out = TranscriptSegmentFilter.apply(segs, query: "world", filter: .all, hideEcho: false)
        #expect(out.count == 1)
    }

    @Test("query は前後空白が trim される")
    func queryTrimmed() {
        let segs = [Self.seg(source: .mic, text: "abc")]
        let out = TranscriptSegmentFilter.apply(segs, query: "  abc  ", filter: .all, hideEcho: false)
        #expect(out.count == 1)
    }

    @Test("query が全空白 → 全件 (trim 後 empty 扱い)")
    func queryAllWhitespace() {
        let segs = [Self.seg(source: .mic, text: "a"), Self.seg(source: .system, text: "b")]
        let out = TranscriptSegmentFilter.apply(segs, query: "   ", filter: .all, hideEcho: false)
        #expect(out.count == 2)
    }

    @Test("hideEcho + filter=.system → echo 除外と system 限定の AND")
    func hideEchoAndSpeakerFilterCombine() {
        let segs = [
            Self.seg(source: .mic, text: "x"),
            Self.seg(source: .system, text: "y"),
            Self.seg(source: .mic, text: "z", echo: true),
            Self.seg(source: .system, text: "w", echo: true),
        ]
        let out = TranscriptSegmentFilter.apply(segs, query: "", filter: .system, hideEcho: true)
        // system かつ echo でないもの: "y"
        #expect(out.count == 1)
        #expect(out.first?.text == "y")
    }
}
