import Foundation
import Contracts

/// AudioCapture モジュールのエントリ。`AudioCaptureService` 実装のファクトリを提供する。
public enum AudioCaptureModule {
    /// Live ASR (録音中ストリーミング文字起こし) の既定値。
    ///
    /// UI 撤去に合わせて既定で OFF。`transcribeLive` API 自体と
    /// `AudioCaptureService.liveTranscripts` プロトコル定義は残してあるため、
    /// 将来再導入したい場合は `makeService(transcription:enableLiveTranscription:)`
    /// の第 2 引数で true を渡すか、ここを true に戻すだけで配線が復活する。
    public static let liveTranscriptionEnabledByDefault: Bool = false

    /// 本番 `AudioCaptureService` を返す。actor インスタンスが新規生成される。
    ///
    /// 後方互換用: live ASR 無効で生成する。新しい呼び出し側は
    /// `makeService(transcription:)` を使うこと。
    public static func makeService() -> any AudioCaptureService {
        AudioCaptureServiceImpl()
    }

    /// Live ASR (録音中ストリーミング文字起こし) を有効化した実装を返す。
    ///
    /// `transcription` には `TranscriptionKitModule.makeService()` の戻り値をそのまま渡す。
    /// `enableLiveTranscription` を明示的に上書きしたい場合のみ第 2 引数を渡す。
    public static func makeService(
        transcription: any TranscriptionService,
        enableLiveTranscription: Bool = liveTranscriptionEnabledByDefault,
        liveTranscriptionLocale: Locale? = nil
    ) -> any AudioCaptureService {
        AudioCaptureServiceImpl(
            liveTranscription: transcription,
            liveTranscriptionEnabled: enableLiveTranscription,
            liveTranscriptionLocale: liveTranscriptionLocale
        )
    }
}
