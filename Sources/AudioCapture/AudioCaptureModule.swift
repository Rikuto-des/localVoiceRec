import Foundation
import Contracts

/// AudioCapture モジュールのエントリ。`AudioCaptureService` 実装のファクトリを提供する。
public enum AudioCaptureModule {
    /// P4.5: 録音中のライブ文字起こしを既定で有効化するためのコンパイル時定数。
    ///
    /// 一旦 false に倒したい場合 (開発ビルドで重さを比較したい等) はここを書き換える。
    /// UI からの切替は提供しない (ユーザーが触れない方が事故が少ない)。
    public static let liveTranscriptionEnabledByDefault: Bool = true

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
