import Foundation

/// SwiftUI Previews / S2 並列開発 / テストで使うサンプル値。
public enum SampleData {
    public static let recording: Recording = {
        let now = Date()
        let started = now.addingTimeInterval(-1800) // 30 min before
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return Recording(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            title: "Sample Meeting",
            startedAt: started,
            endedAt: now,
            micAudioURL: dir.appendingPathComponent("sample_mic.wav"),
            systemAudioURL: dir.appendingPathComponent("sample_sys.wav")
        )
    }()

    public static let segments: [TranscriptSegment] = [
        TranscriptSegment(
            recordingID: recording.id, source: .mic,
            startSec: 0.0, endSec: 3.2,
            text: "では、本日のアジェンダから確認していきます。",
            isFinal: true
        ),
        TranscriptSegment(
            recordingID: recording.id, source: .system,
            startSec: 3.5, endSec: 7.4,
            text: "了解しました。まず Phase 0 の進捗からお願いできますか。",
            isFinal: true
        ),
        TranscriptSegment(
            recordingID: recording.id, source: .mic,
            startSec: 7.8, endSec: 14.2,
            text: "Process tap の検証は完了し、2ch を分離したファイルが取得できています。",
            isFinal: true
        ),
    ]

    public static let summary = SummaryDocument(
        recordingID: recording.id,
        overview: "Phase 0 の進捗確認と Phase 1 の方針議論を実施。",
        decisions: [
            "Phase 0 PoC は今週中に完了させる",
            "Phase 1 から SwiftPM 中心構成で進める",
        ],
        actionItems: [
            ActionItem(title: "PoC の発見事項を docs にまとめる", assignee: "Rikuto", dueDate: nil),
            ActionItem(title: "Contracts のレビュー依頼を出す", assignee: nil, dueDate: nil),
        ],
        openQuestions: [
            "保存データのアプリレベル暗号化の要否",
        ],
        reviewItems: [
            "entitlements の最終確認",
            "TCC ダイアログのコピー",
        ]
    )
}
