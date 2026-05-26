import Foundation

/// Foundation Models による構造化要約サービス。
///
/// ## 設計上の重要事項
/// - `LanguageModelSession` + `@Generable` を使った構造化出力
/// - **4,096 tokens の入力上限**（公式仕様）。長い会議は chunk 化が必要だが、実装層の責務
/// - `availability` は 4 状態を取り得るので UI は分岐ハンドリング必須
/// - `prewarm(promptPrefix:)` を呼ぶ場合、実推論の **1 秒以上前** に呼ぶこと（公式ガイド）
/// - `respond(to:schema:)` で一括生成。ストリーミングは UX が必要なら別途
public protocol SummaryService: Sendable {
    /// 現時点でモデルが使えるか。UI 側で要約ボタンの有効/無効を制御する。
    func availability() async -> SummaryAvailability

    /// セッション初期化 + プロンプトプレフィックスのウォームアップ。
    /// 実推論の 1 秒以上前に呼ぶこと。
    func prewarm() async

    /// 文字起こし結果から要約を生成。
    /// segments は時刻順にソートされている前提。実装側で適宜 chunk 化する。
    func generate(
        from segments: [TranscriptSegment],
        recordingID: UUID
    ) async throws -> SummaryDocument

    /// 同じ素材から再生成。`hint` でフォーカスを変えられる（例: "決定事項だけ重点的に"）。
    func regenerate(
        from segments: [TranscriptSegment],
        recordingID: UUID,
        hint: String?
    ) async throws -> SummaryDocument
}

public enum SummaryAvailability: Sendable, Hashable {
    case available
    case unavailable(reason: UnavailableReason)

    public enum UnavailableReason: Sendable, Hashable {
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        case unsupportedOS
    }
}

public enum SummaryError: Error, Sendable, Hashable {
    case notAvailable(reason: SummaryAvailability.UnavailableReason)
    case generationFailed(message: String)
    /// 入力が 4,096 tokens を超え、かつ chunk 化でも処理しきれなかった
    case contextWindowExceeded
    case cancelled
    case decodingFailed(message: String)
}
