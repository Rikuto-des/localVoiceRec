import Foundation
import Testing
@testable import Contracts

@Suite("CrossChannelEchoMarker")
struct CrossChannelEchoMarkerTests {

    private static let rid = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

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

    // MARK: - Happy path

    @Test("完全一致 + 時間 overlap → mic に echo マーク")
    func exactMatchOverlapMarksMic() {
        let micID = UUID()
        let sysID = UUID()
        let segs = [
            Self.seg(source: .mic, start: 1.0, end: 4.0, text: "皆さんこんばんは。今日は夜食を作ります。", id: micID),
            Self.seg(source: .system, start: 1.05, end: 4.1, text: "皆さんこんばんは。今日は夜食を作ります。", id: sysID),
        ]
        let out = CrossChannelEchoMarker.markEchoes(segments: segs)
        let mic = out.first { $0.id == micID }!
        let sys = out.first { $0.id == sysID }!
        #expect(mic.isLikelyEcho == true)
        #expect(sys.isLikelyEcho == false)
    }

    @Test("ASR 表記ゆれ (1〜2 文字違い) でも echo として検出する")
    func slightAsrVariantStillMatches() {
        let micID = UUID()
        let segs = [
            // 指味噌 (mic) vs 海味噌 (system) のような 1 文字違いを再現
            Self.seg(source: .mic, start: 0.0, end: 3.0, text: "はいはい、指味噌確定これです", id: micID),
            Self.seg(source: .system, start: 0.0, end: 3.0, text: "はいはい、海味噌確定これです"),
        ]
        let out = CrossChannelEchoMarker.markEchoes(segments: segs)
        #expect(out.first { $0.id == micID }!.isLikelyEcho == true)
    }

    // MARK: - Negative cases

    @Test("部分一致 (類似度 < 0.7) → echo マークしない")
    func partialMatchNotMarked() {
        let micID = UUID()
        let segs = [
            Self.seg(source: .mic, start: 0.0, end: 3.0, text: "今日は天気がいいですね", id: micID),
            Self.seg(source: .system, start: 0.0, end: 3.0, text: "明日は雨が降るそうですよ"),
        ]
        let out = CrossChannelEchoMarker.markEchoes(segments: segs)
        #expect(out.first { $0.id == micID }!.isLikelyEcho == false)
    }

    @Test("時間 overlap なし → echo マークしない")
    func noTimeOverlapNotMarked() {
        let micID = UUID()
        let segs = [
            Self.seg(source: .mic, start: 0.0, end: 2.0, text: "皆さんこんばんは", id: micID),
            Self.seg(source: .system, start: 10.0, end: 12.0, text: "皆さんこんばんは"),
        ]
        let out = CrossChannelEchoMarker.markEchoes(segments: segs)
        #expect(out.first { $0.id == micID }!.isLikelyEcho == false)
    }

    @Test("時間 overlap が短すぎる (< 50%) → echo マークしない")
    func smallOverlapNotMarked() {
        // mic: 0.0..1.0 (len 1.0), sys: 0.9..2.0 → overlap 0.1 / shorter 1.0 = 10%
        let micID = UUID()
        let segs = [
            Self.seg(source: .mic, start: 0.0, end: 1.0, text: "皆さんこんばんは", id: micID),
            Self.seg(source: .system, start: 0.9, end: 2.0, text: "皆さんこんばんは"),
        ]
        let out = CrossChannelEchoMarker.markEchoes(segments: segs)
        #expect(out.first { $0.id == micID }!.isLikelyEcho == false)
    }

    @Test("mic のみ → echo マークしない")
    func micOnlyNoEcho() {
        let segs = [
            Self.seg(source: .mic, start: 0, end: 2, text: "テスト"),
            Self.seg(source: .mic, start: 2, end: 4, text: "テスト"),
        ]
        let out = CrossChannelEchoMarker.markEchoes(segments: segs)
        #expect(out.allSatisfy { !$0.isLikelyEcho })
    }

    @Test("system のみ → echo マークしない (mic がないので原理的に対象なし)")
    func systemOnlyNoEcho() {
        let segs = [
            Self.seg(source: .system, start: 0, end: 2, text: "テスト"),
            Self.seg(source: .system, start: 2, end: 4, text: "テスト"),
        ]
        let out = CrossChannelEchoMarker.markEchoes(segments: segs)
        #expect(out.allSatisfy { !$0.isLikelyEcho })
    }

    @Test("空入力 → 空のまま")
    func emptyInput() {
        let out = CrossChannelEchoMarker.markEchoes(segments: [])
        #expect(out.isEmpty)
    }

    @Test("system は echo マークの対象外 (mic だけが対象)")
    func systemNotMarked() {
        let sysID = UUID()
        let segs = [
            Self.seg(source: .mic, start: 0.0, end: 3.0, text: "皆さんこんばんは"),
            Self.seg(source: .system, start: 0.0, end: 3.0, text: "皆さんこんばんは", id: sysID),
        ]
        let out = CrossChannelEchoMarker.markEchoes(segments: segs)
        #expect(out.first { $0.id == sysID }!.isLikelyEcho == false)
    }

    // MARK: - Similarity unit

    @Test("textSimilarity: 完全一致 = 1.0")
    func similarityExact() {
        #expect(CrossChannelEchoMarker.textSimilarity("こんばんは", "こんばんは") == 1.0)
    }

    @Test("textSimilarity: 句読点の差は無視される")
    func similarityPunctuation() {
        let sim = CrossChannelEchoMarker.textSimilarity("皆さんこんばんは。", "皆さんこんばんは")
        #expect(sim == 1.0)
    }

    @Test("textSimilarity: 完全に違う文字列は閾値を割る")
    func similarityDifferent() {
        let sim = CrossChannelEchoMarker.textSimilarity("おはようございます", "夜食を作っています")
        #expect(sim < 0.7)
    }

    // MARK: - Performance / scale

    @Test("長文 (200 文字超) + 100 セグメントでも 1 秒未満で完了する")
    func performanceLongText() {
        let base = String(repeating: "この長いテキストはマイク回り込みで重複する可能性があります。", count: 6)
        // 約 200 文字超
        var segs: [TranscriptSegment] = []
        for i in 0..<100 {
            let start = Double(i) * 5.0
            let end = start + 4.0
            segs.append(Self.seg(source: .mic, start: start, end: end, text: base))
            segs.append(Self.seg(source: .system, start: start + 0.1, end: end + 0.1, text: base))
        }
        let begin = Date()
        let out = CrossChannelEchoMarker.markEchoes(segments: segs)
        let elapsed = Date().timeIntervalSince(begin)
        #expect(elapsed < 1.0)
        // mic 全てが echo マークされていることも確認
        let micEchoes = out.filter { $0.source == .mic && $0.isLikelyEcho }.count
        #expect(micEchoes == 100)
    }

    @Test("入力順序は保持される (id でマッピング可能)")
    func preservesOrder() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let segs = [
            Self.seg(source: .system, start: 0, end: 2, text: "A", id: id1),
            Self.seg(source: .mic, start: 4, end: 6, text: "B", id: id2),
            Self.seg(source: .system, start: 8, end: 10, text: "C", id: id3),
        ]
        let out = CrossChannelEchoMarker.markEchoes(segments: segs)
        #expect(out.map(\.id) == [id1, id2, id3])
    }

    // MARK: - Threshold boundary

    @Test("overlap が ちょうど 50% (= threshold 0.5) → echo マークされる (>= 包含側)")
    func overlapAtExactlyFiftyPercentMarks() {
        // mic: 0.0..2.0 (len 2.0), sys: 1.0..2.0 (len 1.0)
        // overlap = min(2.0, 2.0) - max(0.0, 1.0) = 1.0
        // shorter = min(2.0, 1.0) = 1.0 → ratio = 1.0 / 1.0 = 1.0 (>= 0.5 OK)
        // ちょうど 0.5 のケース: mic 0.0..2.0 (len 2.0), sys 1.0..3.0 (len 2.0)
        // overlap = min(2.0, 3.0) - max(0.0, 1.0) = 1.0
        // shorter = 2.0 → ratio = 0.5
        let micID = UUID()
        let segs = [
            Self.seg(source: .mic, start: 0.0, end: 2.0, text: "皆さんこんばんは", id: micID),
            Self.seg(source: .system, start: 1.0, end: 3.0, text: "皆さんこんばんは"),
        ]
        let out = CrossChannelEchoMarker.markEchoes(segments: segs)
        #expect(out.first { $0.id == micID }!.isLikelyEcho == true,
                "0.5 ちょうど は overlapThreshold に含まれる (>= 比較)")
    }

    @Test("overlap が 0.49 (threshold 未満) → echo マークされない")
    func overlapJustBelowFiftyPercentNotMarked() {
        // mic 0.0..2.0 (len 2.0), sys 1.02..3.02 (len 2.0)
        // overlap = 2.0 - 1.02 = 0.98 → ratio = 0.49
        let micID = UUID()
        let segs = [
            Self.seg(source: .mic, start: 0.0, end: 2.0, text: "皆さんこんばんは", id: micID),
            Self.seg(source: .system, start: 1.02, end: 3.02, text: "皆さんこんばんは"),
        ]
        let out = CrossChannelEchoMarker.markEchoes(segments: segs)
        #expect(out.first { $0.id == micID }!.isLikelyEcho == false,
                "0.49 (< 0.5) は閾値未満で echo マークされない")
    }

    @Test("textSimilarity がちょうど 0.7 → echo として含まれる (>= threshold)")
    func similarityAtExactlySeventyPercentIncluded() {
        // 10 文字 vs 10 文字、3 文字異なる → 距離 3 → 類似度 = 1 - 3/10 = 0.7
        let a = "あいうえおかきくけこ"
        let b = "あいうえおかきXYZ" // 末尾 3 文字違い
        let sim = CrossChannelEchoMarker.textSimilarity(a, b)
        #expect(abs(sim - 0.7) < 0.001, "実測類似度 \(sim) ≒ 0.7")
        #expect(sim >= CrossChannelEchoMarker.textSimilarityThreshold,
                "0.7 ちょうどは threshold (>=) に含まれる")
    }

    @Test("textSimilarity が 0.69 → echo として除外される")
    func similarityJustBelowSeventyPercentExcluded() {
        // 10 文字 vs 10 文字、4 文字異なる → 距離 4 → 類似度 = 1 - 4/10 = 0.6
        // 0.69 ピッタリは整数距離で作れないので、近い値 (0.6 < 0.7) で boundary を確認。
        let a = "あいうえおかきくけこ"
        let b = "あいうえおWXYZ?" // 4 文字違い
        let sim = CrossChannelEchoMarker.textSimilarity(a, b)
        #expect(sim < CrossChannelEchoMarker.textSimilarityThreshold,
                "実測類似度 \(sim) は 0.7 未満で除外されるべき")
    }

    @Test("isLikelyEcho 以外のフィールドは保持される")
    func preservesOtherFields() {
        let micID = UUID()
        let segs = [
            TranscriptSegment(
                id: micID,
                recordingID: Self.rid,
                source: .mic,
                startSec: 0.5,
                endSec: 3.5,
                text: "皆さんこんばんは。今日は夜食を作ります。",
                isFinal: true
            ),
            Self.seg(source: .system, start: 0.5, end: 3.5, text: "皆さんこんばんは。今日は夜食を作ります。"),
        ]
        let out = CrossChannelEchoMarker.markEchoes(segments: segs)
        let mic = out.first { $0.id == micID }!
        #expect(mic.startSec == 0.5)
        #expect(mic.endSec == 3.5)
        #expect(mic.text == "皆さんこんばんは。今日は夜食を作ります。")
        #expect(mic.isFinal == true)
        #expect(mic.isLikelyEcho == true)
    }
}
