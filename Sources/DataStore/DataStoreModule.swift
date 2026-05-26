import Foundation
import Contracts

/// DataStore モジュールのエントリ。
/// 実装本体は `RecordingRepositoryImpl`（SwiftData ベース）。
public enum DataStoreModule {
    /// デフォルト構成の Repository を返す（`AppPaths.storeURL()` 配下に on-disk store を作る）。
    public static func makeRepository() throws -> any RecordingRepository {
        try RecordingRepositoryImpl()
    }
}
