import Foundation
import Contracts

/// AudioCapture モジュールのエントリ。`AudioCaptureService` 実装のファクトリを提供する。
public enum AudioCaptureModule {
    /// 本番 `AudioCaptureService` を返す。actor インスタンスが新規生成される。
    public static func makeService() -> any AudioCaptureService {
        AudioCaptureServiceImpl()
    }
}
