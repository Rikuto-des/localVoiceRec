import Foundation

/// アプリ内のファイル配置の単一情報源。
///
/// AudioCapture が書き出す WAV、DataStore が永続化する DB、UI が参照するパスは
/// すべてここを経由する。これにより `Recording.micAudioURL` などの URL prefix が
/// 一意に決まり、SwiftData 層で「絶対パスを保存するか相対パスを保存するか」の
/// 設計判断ができるようになる（推奨: SwiftData は相対パスで保存、ロード時に再構築）。
///
/// **凍結ファイル**。S2 並列フェーズ中の編集は禁止。
public enum AppPaths {
    /// アプリの Application Support ルート。
    /// 例: `~/Library/Containers/<bundle-id>/Data/Library/Application Support/localVoiceRec/`
    public static func appSupportRoot() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appendingPathComponent("localVoiceRec", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 録音 WAV を格納するルート。
    /// 例: `<appSupportRoot>/Recordings/`
    public static func recordingsRoot() throws -> URL {
        let root = try appSupportRoot().appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 特定の録音のディレクトリ。
    /// 例: `<recordingsRoot>/<UUID>/`
    /// この配下に `mic.wav`, `system.wav` を置く。
    public static func recordingDirectory(for id: UUID) throws -> URL {
        let dir = try recordingsRoot().appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// SwiftData の DB ファイル URL。
    /// 例: `<appSupportRoot>/Store.sqlite`
    public static func storeURL() throws -> URL {
        try appSupportRoot().appendingPathComponent("Store.sqlite")
    }

    /// ある URL を `recordingsRoot()` 基準の相対パスに変換する。
    /// SwiftData @Model で永続化する際、絶対パスではなく相対パスを保存するためのヘルパ。
    /// ルート外の URL を渡したら nil。
    public static func relativePath(of url: URL, base: URL) -> String? {
        let normalizedURL = url.standardizedFileURL.path
        let normalizedBase = base.standardizedFileURL.path
        guard normalizedURL.hasPrefix(normalizedBase) else { return nil }
        let suffix = String(normalizedURL.dropFirst(normalizedBase.count))
        return suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
    }

    /// 相対パスを `recordingsRoot()` 配下の URL に再構築。
    public static func resolveRecordingURL(_ relative: String) throws -> URL {
        try recordingsRoot().appendingPathComponent(relative)
    }
}
