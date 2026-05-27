import Foundation
import Testing
@testable import AudioTapKit

/// `SystemAudioTap` のハードウェア非依存テスト。
///
/// 実機での `start()` テストは PoC (`AudioTapPoC`) に委ねる。
/// ここではコンストラクタと診断カウンタ API の初期値、`AudioTapError.fourCC` などの
/// 純関数的部分のみテストする。
@Suite("SystemAudioTap diagnostics")
struct SystemAudioTapDiagnosticsTests {

    @Test("init() → 診断カウンタは全て 0")
    func initialCounters() throws {
        let tap = try SystemAudioTap()
        #expect(tap.ioProcCallCount == 0)
        #expect(tap.nonZeroBufferCount == 0)
        #expect(tap.receivedBytesTotal == 0)
        #expect(tap.droppedPushCount == 0)
    }

    @Test("captureFormat 初期値は 48kHz Float32 stereo")
    func defaultFormat() throws {
        let tap = try SystemAudioTap()
        #expect(tap.captureFormat.sampleRate == 48_000)
        #expect(tap.captureFormat.channelCount == 2)
        #expect(tap.captureFormat.commonFormat == .pcmFormatFloat32)
    }

    @Test("AudioTapError.fourCC: noErr=0 は ASCII 不能なので raw=0 を返す")
    func fourCCNoErr() {
        let s = AudioTapError.fourCC(0)
        #expect(s == "raw=0")
    }

    @Test("AudioTapError.fourCC: 'auds' (4-char ASCII) を文字列化")
    func fourCCAsciiCode() {
        // 'a' 'u' 'd' 's' = 0x61756473
        let s = AudioTapError.fourCC(0x61756473)
        #expect(s == "'auds'")
    }
}
