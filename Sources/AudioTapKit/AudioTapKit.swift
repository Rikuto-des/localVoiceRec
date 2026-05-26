import Foundation

/// AudioTapKit — Core Audio process tap + AVAudioEngine の薄いラッパ。
///
/// Phase 0 PoC (`AudioTapPoC`) と本番 `AudioCapture` モジュール両方から利用する。
///
/// 公開型:
/// - ``SystemAudioTap``: Core Audio process tap + aggregate device によるシステム音声収録
/// - ``MicCapture``: `AVAudioEngine.inputNode` によるマイク収録
/// - ``WAVFileWriter``: `AVAudioFile` 薄ラップの WAV ライタ
/// - ``AudioTapError``: 共通エラー
public enum AudioTapKit {
    /// 動作確認用のバージョン文字列 (S1 PoC 実装)。
    public static let version: String = "0.1.0-poc"
}
