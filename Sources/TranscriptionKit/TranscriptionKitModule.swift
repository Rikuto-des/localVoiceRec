import Foundation
import Contracts

/// TranscriptionKit モジュールのエントリ。`SpeechAnalyzer` ベースの `TranscriptionService` 実装を返す。
public enum TranscriptionKitModule {
    public static func makeService() -> any TranscriptionService {
        SpeechAnalyzerService()
    }
}
