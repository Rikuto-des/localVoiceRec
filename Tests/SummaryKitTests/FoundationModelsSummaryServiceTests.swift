import Foundation
import Testing
@testable import SummaryKit
import Contracts

/// `FoundationModelsSummaryService` の単体テスト。
///
/// Foundation Models は実機 + Apple Intelligence 有効環境でのみ動くため、
/// 実推論を伴うテストは `.available` でない場合 skip 扱いとする。
@Suite("FoundationModelsSummaryService")
struct FoundationModelsSummaryServiceTests {

    @Test("availability() は何らかの値を返す")
    func availabilityIsCallable() async {
        let svc = FoundationModelsSummaryService()
        let a = await svc.availability()
        // どの値であっても OK。enum の網羅でケースが落ちないことを確認する。
        switch a {
        case .available, .unavailable:
            #expect(Bool(true))
        }
    }

    @Test("prewarm() は availability に関わらず例外を投げない")
    func prewarmDoesNotThrow() async {
        let svc = FoundationModelsSummaryService()
        await svc.prewarm()
        #expect(Bool(true))
    }

    @Test("flatten は isFinal=true のみを含み、source と text を結合する")
    func flattenFiltersAndJoins() {
        let rid = UUID()
        let segs: [TranscriptSegment] = [
            TranscriptSegment(recordingID: rid, source: .mic, startSec: 0, endSec: 1, text: "こんにちは", isFinal: true),
            TranscriptSegment(recordingID: rid, source: .system, startSec: 1, endSec: 2, text: "暫定です", isFinal: false),
            TranscriptSegment(recordingID: rid, source: .system, startSec: 2, endSec: 3, text: "了解です", isFinal: true),
        ]
        let s = FoundationModelsSummaryService.flatten(segments: segs)
        #expect(s.contains("mic: こんにちは"))
        #expect(s.contains("system: 了解です"))
        #expect(!s.contains("暫定です"))
    }

    @Test("truncateIfNeeded は閾値以下の入力をそのまま返す")
    func truncatePassesThroughShortInput() {
        let s = String(repeating: "あ", count: 100)
        #expect(FoundationModelsSummaryService.truncateIfNeeded(s) == s)
    }

    @Test("truncateIfNeeded は閾値超過時に短縮し中略マーカーを含む")
    func truncateShortensLongInput() {
        let s = String(repeating: "あ", count: 20_000)
        let out = FoundationModelsSummaryService.truncateIfNeeded(s)
        #expect(out.count < s.count)
        #expect(out.contains("中略"))
    }

    @Test("makeDocument は draft を SummaryDocument に変換する")
    func makeDocumentMapping() {
        let rid = UUID()
        let draft = FoundationModelsSummaryService.MeetingSummaryDraft(
            overview: "概要文",
            decisions: ["決定A", "決定B"],
            actionItems: [
                .init(title: "資料作成", assignee: "山田", dueDateString: "2026-06-01"),
                .init(title: "レビュー", assignee: "", dueDateString: ""),
            ],
            openQuestions: ["要確認"],
            reviewItems: ["次回確認項目"]
        )
        let doc = FoundationModelsSummaryService.makeDocument(from: draft, recordingID: rid)

        #expect(doc.recordingID == rid)
        #expect(doc.overview == "概要文")
        #expect(doc.decisions == ["決定A", "決定B"])
        #expect(doc.actionItems.count == 2)
        #expect(doc.actionItems[0].title == "資料作成")
        #expect(doc.actionItems[0].assignee == "山田")
        #expect(doc.actionItems[0].dueDate != nil)
        #expect(doc.actionItems[1].assignee == nil)
        #expect(doc.actionItems[1].dueDate == nil)
        #expect(doc.openQuestions == ["要確認"])
        #expect(doc.reviewItems == ["次回確認項目"])
    }

    @Test("parseDate は ISO 8601 と yyyy-MM-dd 両方を扱える")
    func parseDateHandlesFormats() {
        #expect(FoundationModelsSummaryService.parseDate("2026-06-01") != nil)
        #expect(FoundationModelsSummaryService.parseDate("2026-06-01T10:00:00Z") != nil)
        #expect(FoundationModelsSummaryService.parseDate("2026/06/01") != nil)
        #expect(FoundationModelsSummaryService.parseDate("not-a-date") == nil)
        #expect(FoundationModelsSummaryService.parseDate("") == nil)
    }

    @Test("availability が .available でない場合、generate は notAvailable を投げる")
    func generateThrowsWhenUnavailable() async throws {
        let svc = FoundationModelsSummaryService()
        let a = await svc.availability()
        guard case .unavailable(let reason) = a else {
            // 実機 Apple Intelligence ON 環境では skip
            return
        }

        let rid = UUID()
        let segs: [TranscriptSegment] = [
            TranscriptSegment(recordingID: rid, source: .mic, startSec: 0, endSec: 1, text: "テスト", isFinal: true)
        ]

        do {
            _ = try await svc.generate(from: segs, recordingID: rid)
            Issue.record("unavailable のはずなのに generate が成功した")
        } catch let error as SummaryError {
            if case .notAvailable(let r) = error {
                #expect(r == reason)
            } else {
                Issue.record("予期しないエラー型: \(error)")
            }
        }
    }

    @Test("実機で .available の場合に最小入力で要約が返る（unavailable なら skip）")
    func generateEndToEndOnRealDevice() async throws {
        let svc = FoundationModelsSummaryService()
        let a = await svc.availability()
        guard case .available = a else {
            // 環境制約により skip
            return
        }

        let rid = UUID()
        let segs: [TranscriptSegment] = [
            TranscriptSegment(recordingID: rid, source: .mic, startSec: 0, endSec: 2,
                              text: "本日は新サービスのリリース日程について議論します。", isFinal: true),
            TranscriptSegment(recordingID: rid, source: .system, startSec: 2, endSec: 5,
                              text: "リリースは来月の15日に確定したいです。担当は山田さんで。", isFinal: true),
            TranscriptSegment(recordingID: rid, source: .mic, startSec: 5, endSec: 8,
                              text: "了解しました。それでは予算面は次回確認しましょう。", isFinal: true),
        ]

        let doc = try await svc.generate(from: segs, recordingID: rid)
        #expect(doc.recordingID == rid)
        #expect(!doc.overview.isEmpty)
    }
}
