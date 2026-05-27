import Foundation
import Testing
import SwiftData
@testable import Contracts
@testable import DataStore

/// `listWithStatus` の N+1 防止検証。
///
/// 観点:
/// - 100 件投入 → `listWithStatus` 1 回呼び出しが妥当な時間 (< 1s) で完了する。
/// - 比較用 (diagnostic) として `list()` + 各 recording 個別 `loadSegments`/`loadSummary`
///   ループの所要時間を測り、N+1 アンチパターンとの差分を観測可能にする。
///
/// アサーションは絶対値 (CI のばらつきを考慮して緩めに設定) のみ。
@Suite("RecordingRepositoryImpl — listWithStatus performance")
struct ListWithStatusPerformanceTests {

    private func makeInMemoryRepo() throws -> RecordingRepositoryImpl {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: RecordingEntity.self, SegmentEntity.self, SummaryEntity.self,
            configurations: config
        )
        return RecordingRepositoryImpl(container: container)
    }

    private func makeRecording(seq: Int) throws -> Recording {
        let root = try AppPaths.recordingsRoot()
        let id = UUID()
        let dir = root.appendingPathComponent(id.uuidString, isDirectory: true)
        return Recording(
            id: id,
            title: "Meeting \(seq)",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(seq * 60)),
            endedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(seq * 60 + 30)),
            micAudioURL: dir.appendingPathComponent("mic.wav"),
            systemAudioURL: dir.appendingPathComponent("system.wav")
        )
    }

    @Test("100 件 listWithStatus が 1 秒以内に完了する (N+1 がないこと)")
    func listWithStatus100RecordsCompletesQuickly() async throws {
        let repo = try makeInMemoryRepo()
        let count = 100
        // 半数の録音に segments / summary を付与 (= status の分岐網羅)。
        for i in 0..<count {
            let rec = try makeRecording(seq: i)
            try await repo.create(rec)
            if i % 2 == 0 {
                let seg = TranscriptSegment(
                    recordingID: rec.id, source: .mic,
                    startSec: 0, endSec: 1.0, text: "x", isFinal: true
                )
                try await repo.saveSegments([seg], for: rec.id)
            }
            if i % 3 == 0 {
                let sum = SummaryDocument(
                    recordingID: rec.id,
                    overview: "o",
                    decisions: [],
                    actionItems: [],
                    openQuestions: [],
                    reviewItems: []
                )
                try await repo.saveSummary(sum)
            }
        }

        // 計測: listWithStatus
        let start = Date()
        let rows = try await repo.listWithStatus(limit: nil, offset: nil)
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        #expect(rows.count == count)
        // 緩めの上限 (in-memory SwiftData なら通常 100ms 以下。CI 余裕で 1s)。
        #expect(elapsedMs < 1000, "listWithStatus took \(elapsedMs)ms for \(count) recordings — possible N+1")

        // 整合性: hasSegments / hasSummary が正しい
        var segCount = 0
        var sumCount = 0
        for row in rows {
            if row.hasSegments { segCount += 1 }
            if row.hasSummary { sumCount += 1 }
        }
        // 50 件 (偶数) が segments を持つ
        #expect(segCount == 50)
        // ceil(100/3) = 34 件が summary を持つ
        #expect(sumCount == 34)
    }

    @Test("diagnostic: list + 個別 loadSegments/loadSummary ループの所要時間を計測 (assert なし)",
          .disabled("Diagnostic only — run manually to compare N+1 vs batched"))
    func diagnosticNPlusOneBaseline() async throws {
        let repo = try makeInMemoryRepo()
        let count = 100
        for i in 0..<count {
            let rec = try makeRecording(seq: i)
            try await repo.create(rec)
            if i % 2 == 0 {
                let seg = TranscriptSegment(
                    recordingID: rec.id, source: .mic,
                    startSec: 0, endSec: 1, text: "x", isFinal: true
                )
                try await repo.saveSegments([seg], for: rec.id)
            }
        }
        let start = Date()
        let list = try await repo.list(limit: nil, offset: nil)
        for r in list {
            _ = try await repo.loadSegments(for: r.id)
            _ = try await repo.loadSummary(for: r.id)
        }
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        // 観測値を吐くだけ (assertion なし)
        print("[diagnostic] N+1 baseline: \(elapsedMs)ms for \(count) records")
    }
}
