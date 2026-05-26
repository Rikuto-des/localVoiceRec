import Foundation
import Contracts

/// SummaryKit モジュールのエントリ。Foundation Models による `SummaryService` 実装を提供する factory。
public enum SummaryKitModule {
    /// アプリ層で使う既定の `SummaryService` 実装を返す。
    public static func makeService() -> any SummaryService {
        FoundationModelsSummaryService()
    }
}
