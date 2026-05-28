import Foundation
import Testing
@testable import AppUI
import Contracts
import ContractsTestSupport

/// `AppViewModel.hasSubstantiveContent` の境界とそれが自動 summarize 発火を
/// 制御することの統合検証。
@MainActor
@Suite("AppViewModel — hasSubstantiveContent / auto-summary gating")
struct AppViewModelAutoPipelineTests {

    private static let rid = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!

    private static func seg(_ index: Int, text: String) -> TranscriptSegment {
        TranscriptSegment(
            id: UUID(),
            recordingID: rid,
            source: .mic,
            startSec: Double(index),
            endSec: Double(index) + 1.0,
            text: text,
            isFinal: true
        )
    }

    // MARK: - 境界 (静的関数)

    @Test("segments.count < 5 → false")
    func tooFewSegmentsIsFalse() {
        let segs = (0..<4).map { Self.seg($0, text: String(repeating: "あ", count: 30)) }
        #expect(AppViewModel.hasSubstantiveContent(segments: segs) == false)
    }

    @Test("count >= 5 だが totalChars < 60 → false (相槌だけのケース)")
    func enoughSegmentsButTooFewCharsIsFalse() {
        // 5 セグメント × 「うん」(2文字) = 10文字 << 60
        let segs = (0..<5).map { Self.seg($0, text: "うん") }
        #expect(AppViewModel.hasSubstantiveContent(segments: segs) == false)
    }

    @Test("count >= 5 かつ totalChars >= 60 → true")
    func enoughSegmentsAndCharsIsTrue() {
        // 5 セグメント × 12文字 = 60文字 (== 60 で含む)
        let segs = (0..<5).map { Self.seg($0, text: "これはテスト発話です。") }
        // "これはテスト発話です。" = 11 chars (trimming whitespace; trailing 。は数える)
        // 念のため確実に60以上にするため少し長い文を使う
        let longer = (0..<5).map { Self.seg($0, text: "これはテストの長めの発話文です。") }
        #expect(AppViewModel.hasSubstantiveContent(segments: longer) == true)
        // 5セグ未満なら false にちゃんと落ちる二重チェック
        #expect(AppViewModel.hasSubstantiveContent(segments: Array(longer.prefix(4))) == false)
        _ = segs
    }

    @Test("trimming: 前後空白は文字数にカウントしない")
    func leadingTrailingWhitespaceStripped() {
        // 5 セグメントだが各「あ」+ 大量の空白だけ
        let segs = (0..<5).map { Self.seg($0, text: "  あ  ") }
        // trim 後は各 1 文字 → 合計 5 文字
        #expect(AppViewModel.hasSubstantiveContent(segments: segs) == false)
    }

    // MARK: - 統合: 自動 summarize が薄い transcript で走らない

    @Test("FakeTranscriptionService で薄い transcript → stopRecording 後 summary は生成されない")
    func runAutoPipelineSkipsSummaryForSparseTranscript() async throws {
        // FakeTranscriptionService を相槌だけで埋める
        let recordingID = UUID()
        let sparseSamples: [TranscriptSegment] = (0..<5).map { i in
            TranscriptSegment(
                id: UUID(),
                recordingID: recordingID, // recordingID は transcribe 内で書き換わらない
                source: .mic,
                startSec: Double(i) * 0.5,
                endSec: Double(i) * 0.5 + 0.3,
                text: "うん",
                isFinal: true
            )
        }
        let capture = FakeAudioCaptureService()
        let repo = InMemoryRecordingRepository()
        let transcription = FakeTranscriptionService(samples: sparseSamples)
        let summary = FakeSummaryService(availability: .available)
        let vm = AppViewModel(
            capture: capture,
            repository: repo,
            transcription: transcription,
            summary: summary
        )

        await vm.startRecording()
        await vm.stopRecording()
        #expect(vm.recordings.count == 1)
        let rec = vm.recordings[0]

        // パイプライン完了まで待つ (transcribe は走るが summary はスキップされる想定)
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if !vm.transcribingIDs.contains(rec.id),
               !vm.summarizingIDs.contains(rec.id) {
                // segments が一度でも保存されたか確認
                if let segs = try? await repo.loadSegments(for: rec.id), !segs.isEmpty {
                    break
                }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        // transcribe は完了 (segments 保存) しているはず
        let saved = try await repo.loadSegments(for: rec.id)
        #expect(saved.isEmpty == false, "transcribe 自体は走るべき")

        // 重要: 自動 summarize はスキップされる (薄い transcript)
        let summaryDoc = try await repo.loadSummary(for: rec.id)
        #expect(summaryDoc == nil, "薄い transcript の場合、自動 summary は走らない (ハルシネーション防止)")
    }

    @Test("FakeTranscriptionService で十分な transcript → 自動 summary が走る")
    func runAutoPipelineRunsSummaryForRichTranscript() async throws {
        let recordingID = UUID()
        let richSamples: [TranscriptSegment] = (0..<6).map { i in
            TranscriptSegment(
                id: UUID(),
                recordingID: recordingID,
                source: .mic,
                startSec: Double(i),
                endSec: Double(i) + 1.5,
                text: "これは比較的長めの発話で本日の議題について議論しています。",
                isFinal: true
            )
        }
        let capture = FakeAudioCaptureService()
        let repo = InMemoryRecordingRepository()
        let transcription = FakeTranscriptionService(samples: richSamples)
        let summary = FakeSummaryService(availability: .available)
        let vm = AppViewModel(
            capture: capture,
            repository: repo,
            transcription: transcription,
            summary: summary
        )

        await vm.startRecording()
        await vm.stopRecording()
        let rec = vm.recordings[0]

        // パイプライン完了 (summary 生成完了) まで待つ
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if let s = try? await repo.loadSummary(for: rec.id), s != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let summaryDoc = try await repo.loadSummary(for: rec.id)
        #expect(summaryDoc != nil, "十分な transcript なら自動 summary が走るべき")
    }
}
