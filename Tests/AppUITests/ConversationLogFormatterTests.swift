import Testing
import Foundation
@testable import AppUI
import Contracts

@Suite("ConversationLogFormatter")
struct ConversationLogFormatterTests {

    private static let rid = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private static let start = Date(timeIntervalSince1970: 1_716_796_800) // arbitrary fixed
    private static let end   = Date(timeIntervalSince1970: 1_716_797_400) // +10min

    private static func recording(title: String = "テスト会議") -> Recording {
        Recording(
            id: rid,
            title: title,
            startedAt: start,
            endedAt: end,
            micAudioURL: URL(fileURLWithPath: "/tmp/mic.wav"),
            systemAudioURL: URL(fileURLWithPath: "/tmp/sys.wav")
        )
    }

    private static func seg(
        source: TranscriptSegment.Source,
        start: Double,
        end: Double,
        text: String,
        echo: Bool = false
    ) -> TranscriptSegment {
        TranscriptSegment(
            recordingID: rid,
            source: source,
            startSec: start,
            endSec: end,
            text: text,
            isFinal: true,
            isLikelyEcho: echo
        )
    }

    @Test("空セグメントなら「発話が検出されませんでした」を返す")
    func emptyOutput() {
        let minutes = MeetingMinutes(recording: Self.recording(), segments: [], summary: nil)
        let out = ConversationLogFormatter.render(minutes)
        #expect(out.contains("発話が検出されませんでした"))
        #expect(out.contains("テスト会議"))
    }

    @Test("話者ラベルは自分 / 相手にマッピングされる")
    func speakerLabels() {
        let segs = [
            Self.seg(source: .mic,    start: 0,  end: 2, text: "はじめます"),
            Self.seg(source: .system, start: 3,  end: 5, text: "よろしく"),
        ]
        let minutes = MeetingMinutes(recording: Self.recording(), segments: segs, summary: nil)
        let out = ConversationLogFormatter.render(minutes)
        #expect(out.contains("自分"))
        #expect(out.contains("相手"))
        #expect(!out.contains("mic"))
        #expect(!out.contains("system"))
    }

    @Test("発話の順序は startSec 昇順、発話間は空行で区切られる")
    func orderingAndSpacing() {
        let segs = [
            Self.seg(source: .system, start: 5, end: 7, text: "2 番目"),
            Self.seg(source: .mic,    start: 1, end: 3, text: "1 番目"),
        ]
        let minutes = MeetingMinutes(recording: Self.recording(), segments: segs, summary: nil)
        let out = ConversationLogFormatter.render(minutes)
        let firstIdx = out.range(of: "1 番目")?.lowerBound
        let secondIdx = out.range(of: "2 番目")?.lowerBound
        #expect(firstIdx != nil && secondIdx != nil)
        #expect(firstIdx! < secondIdx!)
        // 発話ごとに空行(連続改行)を含むこと
        #expect(out.contains("1 番目\n\n"))
    }

    @Test("タイムスタンプは mm:ss (1 時間未満) / hh:mm:ss (1 時間以上)")
    func timestampFormat() {
        // 1 時間未満 → mm:ss。 65.5 sec は四捨五入で 66 → 01:06
        let segsShort = [
            Self.seg(source: .mic, start: 65.5, end: 70, text: "テスト1"),
        ]
        let outShort = ConversationLogFormatter.render(
            MeetingMinutes(recording: Self.recording(), segments: segsShort, summary: nil)
        )
        #expect(outShort.contains("01:06"))

        // 1 時間以上 → hh:mm:ss。 3665 sec → 01:01:05
        let segsLong = [
            Self.seg(source: .system, start: 3665, end: 3670, text: "テスト2"),
        ]
        let outLong = ConversationLogFormatter.render(
            MeetingMinutes(recording: Self.recording(), segments: segsLong, summary: nil)
        )
        #expect(outLong.contains("01:01:05"))
    }

    @Test("isLikelyEcho セグメントはデフォルトで除外される")
    func excludesEcho() {
        let segs = [
            Self.seg(source: .mic,    start: 1, end: 2, text: "本物の発話"),
            Self.seg(source: .mic,    start: 3, end: 4, text: "回り込み", echo: true),
        ]
        let minutes = MeetingMinutes(recording: Self.recording(), segments: segs, summary: nil)
        let out = ConversationLogFormatter.render(minutes)
        #expect(out.contains("本物の発話"))
        #expect(!out.contains("回り込み"))
    }

    @Test("テキストの前後空白はトリムされる、空 text はスキップ")
    func trimsAndSkipsEmpty() {
        let segs = [
            Self.seg(source: .mic, start: 1, end: 2, text: "  はい  "),
            Self.seg(source: .mic, start: 3, end: 4, text: "   "),  // skip
            Self.seg(source: .mic, start: 5, end: 6, text: "次"),
        ]
        let minutes = MeetingMinutes(recording: Self.recording(), segments: segs, summary: nil)
        let out = ConversationLogFormatter.render(minutes)
        #expect(out.contains("はい\n"))
        #expect(out.contains("次\n"))
        // 空エントリ分のヘッダは出ない
        #expect(out.components(separatedBy: "自分  ").count - 1 == 2)
    }
}
