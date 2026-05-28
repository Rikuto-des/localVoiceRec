import Foundation

// MARK: - LocalizedUserMessage
//
// 各エラー enum に対する UI 表示用メッセージ (日本語、actionable) を
// `localizedUserMessage` プロパティとして提供する。
//
// 方針:
// - case 名 (`String(describing:)`) はユーザーに見せない
// - 代わりに **次に何をすればよいか** を日本語で書く
// - ログ出力 (os.log) はここでは行わない。純粋関数として、必要なら UI 側で別途記録する。

extension AudioCaptureError {
    /// `lastError` などで UI に表示するための日本語メッセージ。
    public var localizedUserMessage: String {
        switch self {
        case .microphonePermissionDenied:
            return "マイクへのアクセス許可が必要です。システム設定 → プライバシーとセキュリティ → マイク で localVoiceRec を有効にしてください。"
        case .systemAudioPermissionDenied:
            return "システム音声を録音するには画面収録の許可が必要です。システム設定 → プライバシーとセキュリティ → 画面とシステムオーディオの収録 で localVoiceRec を有効にしてください。"
        case .engineStartFailed:
            return "オーディオエンジンを起動できませんでした。他のアプリがマイクを占有していないか確認し、再試行してください。"
        case .processTapCreateFailed, .aggregateDeviceCreateFailed:
            return "システム音声の取得に失敗しました。アプリを再起動するか、Mac を再起動して再試行してください。"
        case .alreadyRecording:
            return "既に録音中です。先に現在の録音を停止してください。"
        case .notRecording:
            return "録音は開始されていません。"
        case .fileWriteFailed:
            return "録音ファイルの書き込みに失敗しました。空き容量と書き込み権限を確認してください。"
        case .outputDirectoryUnavailable:
            return "録音保存先フォルダにアクセスできません。アプリの保存先設定を確認してください。"
        case .diskWriteFailure(let failureCount):
            return "録音ファイルの書き込みエラーが \(failureCount) 回連続で発生したため録音を停止しました。ディスクの空き容量と書き込み権限を確認してください。"
        }
    }
}

extension TranscriptionError {
    /// `lastError` などで UI に表示するための日本語メッセージ。
    public var localizedUserMessage: String {
        switch self {
        case .unsupportedLocale:
            return "選択された言語の文字起こしに対応していません。診断パネルでインストール済み Locale を確認してください。"
        case .assetInstallationFailed:
            return "文字起こしに必要なモデルのインストールに失敗しました。ネットワーク接続を確認して再試行してください。"
        case .analyzerFailed:
            return "文字起こし処理が中断されました。録音ファイルを確認し、再実行してください。"
        case .fileNotReadable:
            return "録音ファイルを読み込めません。ファイルが移動・削除されていないか確認してください。"
        case .cancelled:
            return "文字起こしはキャンセルされました。"
        }
    }
}

extension SummaryError {
    /// `lastError` などで UI に表示するための日本語メッセージ。
    public var localizedUserMessage: String {
        switch self {
        case .notAvailable:
            return "要約サービスが利用できません。Apple Intelligence の設定とモデルのダウンロード状況を確認してください。"
        case .generationFailed:
            return "要約の生成に失敗しました。少し待ってから再試行してください。"
        case .contextWindowExceeded:
            return "録音内容が要約モデルの上限を超えています。録音を分割するか、短い区間で再試行してください。"
        case .cancelled:
            return "要約生成はキャンセルされました。"
        case .decodingFailed:
            return "要約の解析に失敗しました。もう一度生成を試してください。"
        }
    }
}

extension RepositoryError {
    /// `lastError` などで UI に表示するための日本語メッセージ。
    public var localizedUserMessage: String {
        switch self {
        case .notFound:
            return "対象の録音が見つかりませんでした。一覧を更新してください。"
        case .ioFailed:
            return "データの読み書きに失敗しました。空き容量とアクセス権限を確認してください。"
        case .storeUnavailable:
            return "データストアにアクセスできません。アプリを再起動してください。"
        case .fileDeletionFailed:
            return "ファイルの削除に失敗しました。手動で Finder から削除してください。"
        }
    }
}
