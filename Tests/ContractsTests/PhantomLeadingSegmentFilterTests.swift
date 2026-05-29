import Foundation
import Testing
@testable import Contracts

@Suite("PhantomLeadingSegmentFilter")
struct PhantomLeadingSegmentFilterTests {

    private static let rid = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private static func seg(
        source: TranscriptSegment.Source,
        start: Double,
        end: Double,
        text: String,
        id: UUID = UUID()
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            recordingID: rid,
            source: source,
            startSec: start,
            endSec: end,
            text: text,
            isFinal: true
        )
    }

    @Test("system 冒頭 0 秒の「あ」はドロップ")
    func dropsLeadingSystemA() {
        let segs = [
            Self.seg(source: .system, start: 0.0, end: 0.2, text: "あ"),
            Self.seg(source: .system, start: 1.5, end: 3.0, text: "おはようございます"),
        ]
        let out = PhantomLeadingSegmentFilter.drop(segments: segs)
        #expect(out.count == 1)
        #expect(out.first?.text == "おはようございます")
    }

    @Test("mic 側の「あ」は保持 (VP/AEC で幻覚は出ない前提)")
    func keepsLeadingMicA() {
        let segs = [
            Self.seg(source: .mic, start: 0.0, end: 0.2, text: "あ"),
        ]
        let out = PhantomLeadingSegmentFilter.drop(segments: segs)
        #expect(out.count == 1)
    }

    @Test("冒頭ウィンドウ (0.5s) を超える「あ」は実発話とみなして保持")
    func keepsLateA() {
        let segs = [
            Self.seg(source: .system, start: 1.2, end: 1.5, text: "あ"),
        ]
        let out = PhantomLeadingSegmentFilter.drop(segments: segs)
        #expect(out.count == 1)
    }

    @Test("冒頭でも「あの」のような実発話は保持")
    func keepsLeadingSubstantialText() {
        let segs = [
            Self.seg(source: .system, start: 0.0, end: 0.4, text: "あの、お時間よろしいですか"),
        ]
        let out = PhantomLeadingSegmentFilter.drop(segments: segs)
        #expect(out.count == 1)
    }

    @Test("「ん」「うん」「ああ」等の典型相槌幻覚もドロップ")
    func dropsCommonPhantomVariants() {
        let segs = [
            Self.seg(source: .system, start: 0.0, end: 0.1, text: "ん"),
            Self.seg(source: .system, start: 0.1, end: 0.2, text: "うん"),
            Self.seg(source: .system, start: 0.2, end: 0.3, text: "ああ"),
        ]
        let out = PhantomLeadingSegmentFilter.drop(segments: segs)
        #expect(out.isEmpty)
    }

    @Test("前後空白付きの「 あ 」もドロップ")
    func handlesWhitespace() {
        let segs = [
            Self.seg(source: .system, start: 0.0, end: 0.1, text: "  あ  "),
        ]
        let out = PhantomLeadingSegmentFilter.drop(segments: segs)
        #expect(out.isEmpty)
    }

    @Test("順序は保持される")
    func preservesOrder() {
        let segs = [
            Self.seg(source: .system, start: 0.0, end: 0.1, text: "あ"),
            Self.seg(source: .mic,    start: 0.5, end: 1.0, text: "こんにちは"),
            Self.seg(source: .system, start: 1.2, end: 2.0, text: "はい、よろしくお願いします"),
        ]
        let out = PhantomLeadingSegmentFilter.drop(segments: segs)
        #expect(out.count == 2)
        #expect(out[0].source == .mic)
        #expect(out[1].source == .system)
    }
}
