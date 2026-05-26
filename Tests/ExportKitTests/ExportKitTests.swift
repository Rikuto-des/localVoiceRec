import Foundation
import Testing
@testable import ExportKit
import Contracts

@Suite("ExportKit")
struct ExportKitTests {

    // MARK: - Test fixtures

    /// 決定的な値を持つ Recording。サンプルではなくテスト用に明示的に組み立てる。
    private static func fixtureRecording() -> Recording {
        // 2026-05-27 14:30 JST 開始、15:30 JST 終了
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let start = cal.date(from: DateComponents(year: 2026, month: 5, day: 27, hour: 14, minute: 30))!
        let end = cal.date(from: DateComponents(year: 2026, month: 5, day: 27, hour: 15, minute: 30))!

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return Recording(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            title: "テスト議事録",
            startedAt: start,
            endedAt: end,
            micAudioURL: tmp.appendingPathComponent("mic.wav"),
            systemAudioURL: tmp.appendingPathComponent("sys.wav"),
            createdAt: end
        )
    }

    private static func fixtureSegments(for id: UUID) -> [TranscriptSegment] {
        [
            TranscriptSegment(
                recordingID: id, source: .mic,
                startSec: 0, endSec: 3,
                text: "おはようございます。", isFinal: true
            ),
            TranscriptSegment(
                recordingID: id, source: .system,
                startSec: 3.5, endSec: 7.8,
                text: "本日もよろしくお願いします。", isFinal: true
            ),
            // 1 時間超の動作確認
            TranscriptSegment(
                recordingID: id, source: .mic,
                startSec: 3725, endSec: 3730,
                text: "まとめに入ります。", isFinal: true
            ),
        ]
    }

    private static func fixtureSummary(for id: UUID) -> SummaryDocument {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let generated = cal.date(from: DateComponents(year: 2026, month: 5, day: 27, hour: 15, minute: 31))!

        return SummaryDocument(
            recordingID: id,
            overview: "本日の議題と次回までの宿題を整理した。",
            decisions: [
                "次回までに設計レビューを完了させる",
                "リリース日は 6 月末で確定",
            ],
            actionItems: [
                ActionItem(title: "設計書を更新", assignee: "Rikuto", dueDate: cal.date(from: DateComponents(year: 2026, month: 6, day: 1))),
                ActionItem(title: "レビュアー手配", assignee: nil, dueDate: nil),
            ],
            openQuestions: ["UI の最終確認方法をどうするか"],
            reviewItems: ["entitlements の最終確認"],
            generatedAt: generated
        )
    }

    // MARK: - MarkdownExporter

    @Test("空セグメント・要約なしでも落ちない")
    func markdownEmpty() {
        let recording = Self.fixtureRecording()
        let minutes = MeetingMinutes(recording: recording, segments: [], summary: nil)
        let md = MarkdownExporter.render(minutes)

        #expect(md.contains("# テスト議事録"))
        #expect(md.contains("## 文字起こし"))
        #expect(md.contains("（文字起こしはありません）"))
        // 要約なしのときは要約セクションが含まれないこと
        #expect(!md.contains("## 概要"))
        #expect(!md.contains("## 決定事項"))
    }

    @Test("要約あり Markdown に主要セクションがすべて含まれる")
    func markdownWithSummary() {
        let recording = Self.fixtureRecording()
        let segments = Self.fixtureSegments(for: recording.id)
        let summary = Self.fixtureSummary(for: recording.id)
        let minutes = MeetingMinutes(recording: recording, segments: segments, summary: summary)

        let md = MarkdownExporter.render(minutes)

        #expect(md.contains("# テスト議事録"))
        #expect(md.contains("- **日時**:"))
        #expect(md.contains("(60 分)") || md.contains("1 時間"))
        #expect(md.contains("- **生成日時**:"))

        #expect(md.contains("## 概要"))
        #expect(md.contains("本日の議題と次回までの宿題を整理した。"))

        #expect(md.contains("## 決定事項"))
        #expect(md.contains("- 次回までに設計レビューを完了させる"))
        #expect(md.contains("- リリース日は 6 月末で確定"))

        #expect(md.contains("## アクションアイテム"))
        #expect(md.contains("- [ ] 設計書を更新（担当: Rikuto, 期限: 2026-06-01）"))
        #expect(md.contains("- [ ] レビュアー手配（担当: 未割当）"))

        #expect(md.contains("## 未解決の問い"))
        #expect(md.contains("- UI の最終確認方法をどうするか"))

        #expect(md.contains("## レビュー項目"))
        #expect(md.contains("- entitlements の最終確認"))

        #expect(md.contains("## 文字起こし"))
        #expect(md.contains("**[00:00] mic**: おはようございます。"))
        #expect(md.contains("**[00:04] system**: 本日もよろしくお願いします。"))
        // 1 時間超は hh:mm:ss にフォールバック
        #expect(md.contains("**[01:02:05] mic**: まとめに入ります。"))
    }

    @Test("空 list は『（なし）』表記")
    func markdownEmptyLists() {
        let recording = Self.fixtureRecording()
        let summary = SummaryDocument(
            recordingID: recording.id,
            overview: "",
            decisions: [],
            actionItems: [],
            openQuestions: [],
            reviewItems: [],
            generatedAt: Date()
        )
        let minutes = MeetingMinutes(recording: recording, segments: [], summary: summary)
        let md = MarkdownExporter.render(minutes)

        #expect(md.contains("（記載なし）"))
        #expect(md.contains("- （なし）"))
    }

    @Test("セグメントは時刻順にソートされる")
    func markdownSortsSegments() {
        let recording = Self.fixtureRecording()
        // わざと逆順
        let segments: [TranscriptSegment] = [
            TranscriptSegment(recordingID: recording.id, source: .mic, startSec: 10, endSec: 12, text: "後", isFinal: true),
            TranscriptSegment(recordingID: recording.id, source: .system, startSec: 1, endSec: 2, text: "先", isFinal: true),
        ]
        let minutes = MeetingMinutes(recording: recording, segments: segments, summary: nil)
        let md = MarkdownExporter.render(minutes)

        let idxFirst = md.range(of: "先")!.lowerBound
        let idxSecond = md.range(of: "後")!.lowerBound
        #expect(idxFirst < idxSecond)
    }

    // MARK: - PlainTextExporter

    @Test("プレーンテキストは Markdown 記号を含まない")
    func plainTextHasNoMarkdownSymbols() {
        let recording = Self.fixtureRecording()
        let segments = Self.fixtureSegments(for: recording.id)
        let summary = Self.fixtureSummary(for: recording.id)
        let minutes = MeetingMinutes(recording: recording, segments: segments, summary: summary)

        let txt = PlainTextExporter.render(minutes)

        // 見出し / 太字 / Markdown 箇条書きの記号がないこと
        #expect(!txt.contains("# "))
        #expect(!txt.contains("## "))
        #expect(!txt.contains("**"))
        // Markdown 箇条書きハイフン「- 」は使わない（YYYY-MM-DD などのハイフンは許容するため "- " 単独で検査）
        #expect(!txt.contains("\n- "))
        #expect(!txt.contains("\n* "))
        // 引用記号も使わない
        #expect(!txt.contains("\n> "))

        // 必須の文字列は含まれる
        #expect(txt.contains("テスト議事録"))
        #expect(txt.contains("■ 概要"))
        #expect(txt.contains("■ 文字起こし"))
        #expect(txt.contains("・次回までに設計レビューを完了させる"))
        #expect(txt.contains("[00:00] mic: おはようございます。"))
        #expect(txt.contains("[01:02:05] mic: まとめに入ります。"))
    }

    @Test("プレーンテキストは要約なしでも落ちない")
    func plainTextEmpty() {
        let recording = Self.fixtureRecording()
        let minutes = MeetingMinutes(recording: recording, segments: [], summary: nil)
        let txt = PlainTextExporter.render(minutes)

        #expect(txt.contains("テスト議事録"))
        #expect(txt.contains("■ 文字起こし"))
        #expect(txt.contains("（文字起こしはありません）"))
        #expect(!txt.contains("■ 概要"))
    }

    // MARK: - ExportFormat

    @Test("ExportFormat の拡張子と UTType")
    func exportFormatMetadata() {
        #expect(ExportFormat.markdown.fileExtension == "md")
        #expect(ExportFormat.plainText.fileExtension == "txt")
        #expect(ExportFormat.markdown.utTypeIdentifier == "net.daringfireball.markdown")
        #expect(ExportFormat.plainText.utTypeIdentifier == "public.plain-text")
        #expect(ExportFormat.allCases.count == 2)
    }

    // MARK: - Timestamp formatter

    @Test("タイムスタンプは mm:ss / hh:mm:ss を切り替える")
    func timestampFormat() {
        #expect(ExportFormatters.timestamp(from: 0) == "00:00")
        #expect(ExportFormatters.timestamp(from: 12.4) == "00:12")
        #expect(ExportFormatters.timestamp(from: 75.0) == "01:15")
        #expect(ExportFormatters.timestamp(from: 3599) == "59:59")
        #expect(ExportFormatters.timestamp(from: 3600) == "01:00:00")
        #expect(ExportFormatters.timestamp(from: 3725) == "01:02:05")
    }
}
