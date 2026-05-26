import Foundation

/// `AVAudioPCMBuffer` のような非 Sendable な class を AsyncStream 越しに転送するための薄い箱。
///
/// **使用上の不変条件**: 生成側はこの box に詰めた直後に元参照を捨て、consumer は box から取り出した
/// バッファを唯一の所有者として扱う。違反するとデータ競合が起きる。
public struct UncheckedSendableBox<T>: @unchecked Sendable {
    public let value: T
    public init(_ value: T) { self.value = value }
}
