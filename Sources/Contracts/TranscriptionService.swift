import Foundation

/// 録音済みの 2 ファイルを SpeechAnalyzer で並列に文字起こしするサービス。
///
/// ## 設計上の重要事項
/// - macOS 26 の **SpeechAnalyzer + SpeechTranscriber** を使う（`SFSpeechRecognizer` は使わない）
/// - 2 つの `SpeechTranscriber` を **同一 locale / preset** で生成すると backing engine が
///   共有され、メモリ上のモデルは 1 セットで済む（公式仕様）
/// - 入力は `AVAudioFile`（録音済み WAV）を渡す `analyzeSequence(from:)` または
///   `start(inputAudioFile:finishAfterFile:)` を使う設計を想定
/// - サンプルレート変換は実装側で `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`
///   を取得し、必要に応じて `AVAudioConverter` で行う
/// - **オフライン保証**: `SpeechTranscriber.installedLocales` に含まれる locale を使う限り
///   ネットワーク不要。Asset DL は別 API (`AssetInventory.assetInstallationRequest`) で
///   管理者が事前に行う運用とする
public protocol TranscriptionService: Sendable {
    /// 端末にインストール済みで使える locale 一覧。
    /// アプリ UI で「日本語/英語」を選ばせる前に確認する。
    func installedLocales() async -> [Locale]

    /// 録音の 2 ファイルを並列で文字起こしする。
    /// 結果は phrase ごとに `TranscriptSegment` として yield される。順序は時間順保証なし
    /// （2 系統が独立にやってくる）。consumer 側で `startSec` でソートする想定。
    ///
    /// `locale == nil` の場合は端末の現在ロケールを自動正規化する。
    func transcribe(
        recording: Recording,
        locale: Locale?
    ) -> AsyncThrowingStream<TranscriptSegment, Error>

    /// 進行中のすべての文字起こしを中断。
    func cancelAll() async
}

public enum TranscriptionError: Error, Sendable, Hashable {
    case unsupportedLocale(identifier: String)
    /// 必要な on-device asset が未インストールで、かつ DL もできなかった
    case assetInstallationFailed(message: String)
    case analyzerFailed(message: String)
    case fileNotReadable(URL)
    case cancelled
}
