import Foundation
import Synchronization

/// Single-Producer / Single-Consumer (SPSC) lock-free byte ring buffer.
///
/// - **Producer**: Core Audio IOProc (リアルタイムスレッド)
/// - **Consumer**: AsyncStream を駆動する通常タスク
///
/// 用途: process tap IOProc が受け取る生バイト列 (interleaved Float32 PCM が一般的)
/// を、ロックや malloc なしで通常スレッドに渡すこと。
/// 内部実装は `UnsafeMutableRawPointer` の固定長バッファ + アトミック read/write index。
///
/// ## RT セーフネス
/// - `push(_:count:)` は `memcpy` と 2 つの atomic store/load しか行わない (no lock / no alloc)。
/// - 容量が足りない場合は **古いデータを上書きしない**。push に失敗して `false` を返す
///   (ドロップ統計はカウンタで観測)。
/// - 容量はコンストラクタ時に固定。再アロケートは発生しない。
///
/// Note: Swift 6.0 `Synchronization.Atomic<Int>` を使用 (外部依存なし、std library)。
public final class SPSCByteRingBuffer: @unchecked Sendable {

    private let storage: UnsafeMutableRawPointer
    private let capacity: Int

    // head = 次に書き込む位置 (producer 専用 / consumer は read-only)
    // tail = 次に読み出す位置 (consumer 専用 / producer は read-only)
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)

    private let _droppedPushCount = Atomic<Int>(0)
    /// 失敗 push 回数 (デバッグ用観測値)。
    public var droppedPushCount: Int { _droppedPushCount.load(ordering: .relaxed) }

    /// - Parameter capacity: 内部バッファ容量 (バイト)。サンプルレート × フレームサイズ ×
    ///   バッファしたい秒数 を目安に確保する。
    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = UnsafeMutableRawPointer.allocate(
            byteCount: capacity,
            alignment: MemoryLayout<UInt8>.alignment
        )
    }

    deinit {
        storage.deallocate()
    }

    /// 現在書き込み可能なバイト数 (producer 視点)。
    public var availableForWrite: Int {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let used = (h - t + capacity) % capacity
        return capacity - used - 1
    }

    /// 現在読み出し可能なバイト数 (consumer 視点)。
    public var availableForRead: Int {
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .relaxed)
        return (h - t + capacity) % capacity
    }

    /// Producer (RT スレッド) から呼ぶ。バイト列を書き込む。
    /// 容量不足の場合は何も書かずに `false` を返す。
    @discardableResult
    public func push(_ src: UnsafeRawPointer, count: Int) -> Bool {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let used = (h - t + capacity) % capacity
        let free = capacity - used - 1
        if count > free {
            _droppedPushCount.wrappingAdd(1, ordering: .relaxed)
            return false
        }

        let firstChunk = min(count, capacity - h)
        memcpy(storage.advanced(by: h), src, firstChunk)
        if firstChunk < count {
            memcpy(storage, src.advanced(by: firstChunk), count - firstChunk)
        }
        let newHead = (h + count) % capacity
        head.store(newHead, ordering: .releasing)
        return true
    }

    /// Consumer から呼ぶ。`dst` に最大 `count` バイト読み出して実読み込み数を返す。
    @discardableResult
    public func pop(into dst: UnsafeMutableRawPointer, count: Int) -> Int {
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .relaxed)
        let used = (h - t + capacity) % capacity
        let toRead = min(count, used)
        if toRead == 0 { return 0 }

        let firstChunk = min(toRead, capacity - t)
        memcpy(dst, storage.advanced(by: t), firstChunk)
        if firstChunk < toRead {
            memcpy(dst.advanced(by: firstChunk), storage, toRead - firstChunk)
        }
        let newTail = (t + toRead) % capacity
        tail.store(newTail, ordering: .releasing)
        return toRead
    }
}
