import Foundation

/// アプリ全体で使う識別子の単一情報源。
///
/// `Logger(subsystem:)` の prefix・`UserDefaults` のキー prefix・`OSLogStore` の
/// `subsystem ==` predicate などで使う文字列を 1 箇所に集約する。
///
/// 将来 real domain（例: `dev.rikuto.localvoicerec`）への切替を 1 箇所の差分で
/// 行えるようにするための ABI 境界。
///
/// 注意: `App/Info.plist` の `CFBundleIdentifier` は plist の制約上文字列リテラル
/// 必須のため、ここでは集約できない。bundle id を変更する際は plist も同時に追従する。
public enum AppIdentifiers {
    /// `CFBundleIdentifier` と一致させる。
    public static let bundleIdentifier = "com.example.localVoiceRec"

    /// `Logger(subsystem:)` で使うルート subsystem。
    public static let logSubsystem = bundleIdentifier

    /// suffix 付きのサブシステム文字列を生成する（例: `"audio.mic"`）。
    public static func logSubsystem(suffix: String) -> String {
        "\(bundleIdentifier).\(suffix)"
    }

    /// `UserDefaults` キーを bundle id で名前空間化する。
    public static func userDefaultsKey(_ name: String) -> String {
        "\(bundleIdentifier).\(name)"
    }
}
