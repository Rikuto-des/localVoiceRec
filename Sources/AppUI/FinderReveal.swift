import AppKit
import Foundation
import Contracts

/// Finder で録音ファイル / フォルダを開くための薄ラッパ。
///
/// macOS の App Sandbox 配下でも、**自分の Container 内のファイル** であれば
/// 追加 entitlement なしで `NSWorkspace.activateFileViewerSelecting` / `open(_:)`
/// が動く。User-selected の外側を開く場合のみ
/// `com.apple.security.files.user-selected.read-write` が必要だが、本アプリは
/// すべての録音を Container 配下に置くため不要。
enum FinderReveal {

    /// 録音の保存ディレクトリ（mic.wav と system.wav が入っているフォルダ）を
    /// Finder で開く。
    ///
    /// `Recording.micAudioURL` の親ディレクトリを開く設計。両 wav は同じ
    /// `<recordingDir>/` に置かれるためどちらの URL でも結果は同じ。
    static func openRecordingFolder(for recording: Recording) {
        let dir = recording.micAudioURL.deletingLastPathComponent()
        openFolder(dir)
    }

    /// 任意のフォルダを Finder で開く。
    static func openFolder(_ url: URL) {
        // フォルダが存在しない場合は親階層をたどる
        var target = url
        let fm = FileManager.default
        while !fm.fileExists(atPath: target.path) {
            let parent = target.deletingLastPathComponent()
            if parent == target { return } // root に到達
            target = parent
        }
        NSWorkspace.shared.open(target)
    }

    /// 指定ファイル（複数可）を Finder で選択状態にして開く。
    /// 単一ファイルなら親フォルダが開き、そのファイルがハイライトされる。
    static func reveal(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            // ファイルが無い場合は親フォルダだけ開く（録音失敗時など）
            openFolder(url.deletingLastPathComponent())
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 複数ファイルをまとめて選択して Finder を開く。
    static func reveal(_ urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            if let first = urls.first {
                openFolder(first.deletingLastPathComponent())
            }
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(existing)
    }
}
