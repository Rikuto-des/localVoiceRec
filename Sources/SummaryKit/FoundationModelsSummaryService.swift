import Foundation
import Contracts
import FoundationModels

/// Foundation Models (Apple Intelligence オンデバイス LLM) を使った `SummaryService` 実装。
///
/// 設計メモ:
/// - `@Generable` 構造体 `MeetingSummaryDraft` に直接生成させ、`SummaryDocument` への変換責務は本サービス内に閉じる。
/// - 入力上限は 4,096 tokens。日本語は概ね 1 文字 ≒ 1 token のため、安全側で **16,000 文字** を上限の目安にし、
///   超えたら冒頭と末尾を優先する切り詰めで対応する（最小実装）。
/// - 1 actor = 1 session の直列利用で `concurrentRequests` を回避。
public actor FoundationModelsSummaryService: SummaryService {

    // MARK: - Generable Draft 型

    @Generable(description: "会議の文字起こしから抽出した構造化要約のドラフト")
    struct MeetingSummaryDraft {
        @Guide(description: "会議全体の概要を 2〜4 文の日本語で述べる")
        var overview: String

        @Guide(description: "会議中に下された決定事項を、簡潔な日本語の文で列挙する")
        var decisions: [String]

        @Guide(description: "アクションアイテム（誰が何をいつまでに）を一覧にする")
        var actionItems: [DraftActionItem]

        @Guide(description: "未解決の問い・疑問点を簡潔に列挙する")
        var openQuestions: [String]

        @Guide(description: "次回レビュー時に確認すべき項目を列挙する")
        var reviewItems: [String]
    }

    @Generable(description: "アクションアイテムのドラフト")
    struct DraftActionItem {
        @Guide(description: "アクションアイテムの短い見出し（日本語）")
        var title: String

        @Guide(description: "担当者の名前。不明な場合は空文字列にする")
        var assignee: String

        @Guide(description: "期日（ISO 8601 形式 'yyyy-MM-dd' または 'yyyy-MM-ddTHH:mm:ssZ'）。不明な場合は空文字列にする")
        var dueDateString: String
    }

    // MARK: - 設定

    /// プロンプト全体（instructions + 文字起こし）に許容する概算文字数。
    /// 日本語は 1 文字 ≒ 1 token なので、出力分の余裕を残して安全側に倒している。
    private static let maxTranscriptCharacters: Int = 16_000

    private static let instructions: String = """
        あなたは日本の会社で議事録作成を担当する優秀なアシスタントです。
        与えられた会議の文字起こしを読み、決定事項・アクションアイテム・未解決の問い・次回レビュー項目を整理した
        構造化要約を日本語で作成してください。

        【最優先のルール — 厳守】
        文字起こしに**実際に書かれていない事項を絶対に捏造しないこと**。
        以下のいずれかに該当する場合は、ハルシネーションを避けるため空の要約を返してください:
        - 文字起こしが「うん」「あ」「ええ」「はい」「そうですね」等の相槌・フィラーワードだけで構成されている
        - 文字起こしの全文字数が概ね 60 文字未満
        - 議題・決定・アクションを抽出できるだけの実質的な発話が含まれていない
        - 業務・会議として成立する内容が読み取れない

        空の要約を返す場合のフォーマット:
        - overview: 「要約を生成できる十分な内容がありません」
        - decisions / actionItems / openQuestions / reviewItems: 空配列 []

        【十分な内容がある場合のフォーマット】
        - overview は 2〜4 文の自然な日本語で会議の目的と結論を要約する
        - decisions は会議中に下された具体的な決定事項のみを列挙する
        - actionItems は「誰が・何を・いつまでに」を明確にする。担当者や期日が不明な場合は空文字列を入れる
        - openQuestions は会議中に解決しなかった疑問点を列挙する
        - reviewItems は次回ミーティングで確認すべき項目を列挙する

        ヘイトスピーチや差別的表現を含めないこと。
        繰り返しますが、文字起こしに無い数字・日付・人名・組織名・予算・案件名等を**絶対に**生成しないこと。
        """

    // MARK: - State

    private var session: LanguageModelSession?

    // MARK: - Init

    public init() {}

    // MARK: - SummaryService

    public func availability() async -> SummaryAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(reason: .appleIntelligenceNotEnabled)
        case .unavailable(.deviceNotEligible):
            return .unavailable(reason: .deviceNotEligible)
        case .unavailable(.modelNotReady):
            return .unavailable(reason: .modelNotReady)
        case .unavailable:
            // 将来追加される理由はひとまず modelNotReady 扱い（再試行を促す）
            return .unavailable(reason: .modelNotReady)
        }
    }

    public func generate(
        from segments: [TranscriptSegment],
        recordingID: UUID
    ) async throws -> SummaryDocument {
        try await respondAndBuild(
            segments: segments,
            recordingID: recordingID,
            hint: nil
        )
    }

    public func regenerate(
        from segments: [TranscriptSegment],
        recordingID: UUID,
        hint: String?
    ) async throws -> SummaryDocument {
        try await respondAndBuild(
            segments: segments,
            recordingID: recordingID,
            hint: hint
        )
    }

    // MARK: - 内部実装

    private func respondAndBuild(
        segments: [TranscriptSegment],
        recordingID: UUID,
        hint: String?
    ) async throws -> SummaryDocument {
        // availability ガード
        switch await availability() {
        case .available:
            break
        case .unavailable(let reason):
            throw SummaryError.notAvailable(reason: reason)
        }

        let transcript = Self.flatten(segments: segments)
        let trimmed = Self.truncateIfNeeded(transcript)

        var promptBody = "次の会議の文字起こしを構造化要約にしてください。\n\n--- 文字起こし開始 ---\n"
        promptBody += trimmed
        promptBody += "\n--- 文字起こし終了 ---\n"
        if let hint, !hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            promptBody += "\n追加の指示: \(hint)\n"
        }

        let session = ensureSession()

        let response: LanguageModelSession.Response<MeetingSummaryDraft>
        do {
            response = try await session.respond(
                to: promptBody,
                generating: MeetingSummaryDraft.self
            )
        } catch let error as LanguageModelSession.GenerationError {
            // セッションが汚染された可能性があるので、再生成しやすいよう破棄
            self.session = nil
            throw Self.translate(error)
        } catch is CancellationError {
            throw SummaryError.cancelled
        } catch {
            throw SummaryError.generationFailed(message: String(describing: error))
        }

        return Self.makeDocument(
            from: response.content,
            recordingID: recordingID
        )
    }

    private func ensureSession() -> LanguageModelSession {
        if let session { return session }
        let s = LanguageModelSession(instructions: Self.instructions)
        self.session = s
        return s
    }

    // MARK: - Pure helpers

    static func flatten(segments: [TranscriptSegment]) -> String {
        segments
            .filter { $0.isFinal }
            .map { "\($0.source.rawValue): \($0.text)" }
            .joined(separator: "\n")
    }

    /// 単純な「冒頭と末尾を優先」の切り詰め。
    static func truncateIfNeeded(_ text: String) -> String {
        guard text.count > maxTranscriptCharacters else { return text }
        let half = maxTranscriptCharacters / 2
        let headEnd = text.index(text.startIndex, offsetBy: half)
        let tailStart = text.index(text.endIndex, offsetBy: -half)
        let head = text[text.startIndex..<headEnd]
        let tail = text[tailStart..<text.endIndex]
        return "\(head)\n\n…（中略：文字起こしが長すぎたため省略）…\n\n\(tail)"
    }

    static func makeDocument(
        from draft: MeetingSummaryDraft,
        recordingID: UUID
    ) -> SummaryDocument {
        let actionItems: [ActionItem] = draft.actionItems.map { d in
            let assignee = d.assignee.trimmingCharacters(in: .whitespacesAndNewlines)
            let dueRaw = d.dueDateString.trimmingCharacters(in: .whitespacesAndNewlines)
            return ActionItem(
                title: d.title,
                assignee: assignee.isEmpty ? nil : assignee,
                dueDate: dueRaw.isEmpty ? nil : parseDate(dueRaw)
            )
        }
        return SummaryDocument(
            recordingID: recordingID,
            overview: draft.overview,
            decisions: draft.decisions,
            actionItems: actionItems,
            openQuestions: draft.openQuestions,
            reviewItems: draft.reviewItems
        )
    }

    static func parseDate(_ s: String) -> Date? {
        // ISO 8601 (yyyy-MM-ddTHH:mm:ssZ) を最優先
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        // 年月日のみ
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        for fmt in ["yyyy-MM-dd", "yyyy/MM/dd", "yyyy-MM-dd HH:mm:ss"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func translate(_ error: LanguageModelSession.GenerationError) -> SummaryError {
        switch error {
        case .exceededContextWindowSize:
            return .contextWindowExceeded
        case .assetsUnavailable(let ctx):
            // Apple Intelligence OFF or モデル未 DL の可能性。情報を伝えつつ notAvailable に寄せる
            return .notAvailable(reason: inferUnavailableReason(from: ctx.debugDescription))
        case .decodingFailure(let ctx):
            return .decodingFailed(message: ctx.debugDescription)
        case .guardrailViolation(let ctx),
             .refusal(_, let ctx),
             .rateLimited(let ctx),
             .concurrentRequests(let ctx),
             .unsupportedGuide(let ctx),
             .unsupportedLanguageOrLocale(let ctx):
            return .generationFailed(message: ctx.debugDescription)
        @unknown default:
            return .generationFailed(message: String(describing: error))
        }
    }

    private static func inferUnavailableReason(from message: String) -> SummaryAvailability.UnavailableReason {
        let m = message.lowercased()
        if m.contains("not enabled") || m.contains("intelligence") {
            return .appleIntelligenceNotEnabled
        }
        if m.contains("not eligible") || m.contains("device") {
            return .deviceNotEligible
        }
        return .modelNotReady
    }
}
