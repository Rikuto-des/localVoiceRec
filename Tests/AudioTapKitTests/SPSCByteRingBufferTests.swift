import Foundation
import Testing
@testable import AudioTapKit

/// `SPSCByteRingBuffer` の境界条件・wrap-around・overflow ポリシー検証。
///
/// 実装メモ:
/// - capacity N のリングバッファは内部的に 1 slot を「空 vs 満」判定に予約する。
///   そのため実使用可能な容量は `capacity - 1` バイト。
/// - overflow policy: 新しい push を drop する (古いデータは温存)。droppedPushCount が
///   増える。
@Suite("SPSCByteRingBuffer")
struct SPSCByteRingBufferTests {

    /// 指定バイト数 (`0..<count` を順に書いた) のテストデータを作る。
    private static func makeBytes(_ count: Int, offset: UInt8 = 0) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 + Int(offset)) }
    }

    @Test("wrap-around: head/tail がバッファ末尾を跨いでも正しく取り出せる")
    func wrapAround() {
        let buf = SPSCByteRingBuffer(capacity: 100)
        // 1) 60 push
        let first = Self.makeBytes(60, offset: 1)
        first.withUnsafeBufferPointer { ptr in
            #expect(buf.push(ptr.baseAddress!, count: 60) == true)
        }
        #expect(buf.availableForRead == 60)

        // 2) 40 pop
        var out1 = [UInt8](repeating: 0, count: 40)
        let read1 = out1.withUnsafeMutableBufferPointer { ptr in
            buf.pop(into: ptr.baseAddress!, count: 40)
        }
        #expect(read1 == 40)
        #expect(out1 == Array(first.prefix(40)))
        #expect(buf.availableForRead == 20)

        // 3) 50 push — head が wrap して 0..<? に戻る
        let second = Self.makeBytes(50, offset: 100)
        second.withUnsafeBufferPointer { ptr in
            #expect(buf.push(ptr.baseAddress!, count: 50) == true)
        }
        #expect(buf.availableForRead == 70)

        // 4) 50 pop — wrap 境界の memcpy が正しく動くこと
        var out2 = [UInt8](repeating: 0, count: 50)
        let read2 = out2.withUnsafeMutableBufferPointer { ptr in
            buf.pop(into: ptr.baseAddress!, count: 50)
        }
        #expect(read2 == 50)
        // expected: 残り 20 バイト (first[40..<60]) + 30 バイト (second[0..<30])
        let expected = Array(first.suffix(20)) + Array(second.prefix(30))
        #expect(out2 == expected)
        #expect(buf.availableForRead == 20)
    }

    @Test("overflow: 容量を超える push は drop され droppedPushCount が増える")
    func overflowDropsAndIncrements() {
        let buf = SPSCByteRingBuffer(capacity: 100)
        // 容量 100 (実使用可能は 99 バイト)。
        // 1 回 99 バイト push → 成功。
        let chunk1 = Self.makeBytes(99)
        chunk1.withUnsafeBufferPointer { ptr in
            #expect(buf.push(ptr.baseAddress!, count: 99) == true)
        }
        #expect(buf.droppedPushCount == 0)

        // さらに 50 バイト push 試行 → 容量不足で drop (新しい方が捨てられる)。
        // ※ 期待挙動: push は false を返し、buffer 内のデータは変化しない (古い 99 バイト保持)。
        let chunk2 = Self.makeBytes(50, offset: 200)
        chunk2.withUnsafeBufferPointer { ptr in
            #expect(buf.push(ptr.baseAddress!, count: 50) == false)
        }
        #expect(buf.droppedPushCount == 1)

        // さらに 200 バイト push 試行 (capacity を上回るサイズ) → drop。
        let chunk3 = Self.makeBytes(200, offset: 50)
        chunk3.withUnsafeBufferPointer { ptr in
            #expect(buf.push(ptr.baseAddress!, count: 200) == false)
        }
        #expect(buf.droppedPushCount == 2)

        // 既存データは破壊されていない (古いデータ保持ポリシー)。
        var out = [UInt8](repeating: 0, count: 99)
        let read = out.withUnsafeMutableBufferPointer { ptr in
            buf.pop(into: ptr.baseAddress!, count: 99)
        }
        #expect(read == 99)
        #expect(out == chunk1)
    }

    @Test("full capacity boundary: 99 push 成功、100 push 目で drop (capacity-1 ポリシー)")
    func fullCapacityBoundary() {
        // 実装は SPSC リングバッファの標準パターンで、capacity N のうち
        // 1 slot を「空 vs 満」判定用に予約する。実使用可能は N-1 = 99。
        let buf = SPSCByteRingBuffer(capacity: 100)
        let bytes99 = Self.makeBytes(99)
        bytes99.withUnsafeBufferPointer { ptr in
            #expect(buf.push(ptr.baseAddress!, count: 99) == true)
        }
        #expect(buf.availableForRead == 99)
        #expect(buf.availableForWrite == 0)

        // 100 バイト目 (= +1) は drop されるべき。
        let extra: [UInt8] = [0xFF]
        extra.withUnsafeBufferPointer { ptr in
            #expect(buf.push(ptr.baseAddress!, count: 1) == false)
        }
        #expect(buf.droppedPushCount == 1)
        #expect(buf.availableForRead == 99)
    }

    @Test("pop on empty: 0 バイト返却、no crash")
    func popOnEmpty() {
        let buf = SPSCByteRingBuffer(capacity: 100)
        #expect(buf.availableForRead == 0)
        var out = [UInt8](repeating: 0, count: 16)
        let read = out.withUnsafeMutableBufferPointer { ptr in
            buf.pop(into: ptr.baseAddress!, count: 16)
        }
        #expect(read == 0)
        // 2 回目も同様
        let read2 = out.withUnsafeMutableBufferPointer { ptr in
            buf.pop(into: ptr.baseAddress!, count: 1)
        }
        #expect(read2 == 0)
    }

    @Test("drain 後の状態: pop しきった後に再度 push/pop しても正しく動く")
    func drainAndReusePreservesIntegrity() {
        // 注: SPSCByteRingBuffer には close() API が無いため、
        // テスト名を「drain 後の再利用」に変更。 close ポリシーが将来導入されたら
        // 別 test を追加する。
        let buf = SPSCByteRingBuffer(capacity: 100)
        let a = Self.makeBytes(50, offset: 1)
        a.withUnsafeBufferPointer { ptr in
            #expect(buf.push(ptr.baseAddress!, count: 50) == true)
        }
        // 50 pop して空に
        var out = [UInt8](repeating: 0, count: 50)
        let read = out.withUnsafeMutableBufferPointer { ptr in
            buf.pop(into: ptr.baseAddress!, count: 50)
        }
        #expect(read == 50)
        #expect(out == a)
        #expect(buf.availableForRead == 0)

        // 再度 push 可能 (drop されない)
        let b = Self.makeBytes(70, offset: 100)
        b.withUnsafeBufferPointer { ptr in
            #expect(buf.push(ptr.baseAddress!, count: 70) == true)
        }
        #expect(buf.droppedPushCount == 0)
        var out2 = [UInt8](repeating: 0, count: 70)
        let read2 = out2.withUnsafeMutableBufferPointer { ptr in
            buf.pop(into: ptr.baseAddress!, count: 70)
        }
        #expect(read2 == 70)
        #expect(out2 == b)
    }
}
