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

    @Test("flowSnapshot() は (callCount, bytesReceived) を返す — 初期は (0,0)")
    func flowSnapshotInitial() throws {
        let tap = try SystemAudioTap()
        let snap = tap.flowSnapshot()
        #expect(snap.callCount == 0)
        #expect(snap.bytesReceived == 0)
    }
}

/// `MicCapture` の宣言的 API のテスト (HW なし)。
///
/// 実 engine.start() は CI/サンドボックスで失敗するため、
/// ここでは onConfigurationChange の install/差し替えが副作用なくできることだけ確認する。
@Suite("MicCapture API")
struct MicCaptureAPITests {

    @Test("onConfigurationChange は nil で初期化される")
    func handlerDefaultsToNil() {
        let mic = MicCapture(voiceProcessingEnabled: false)
        #expect(mic.onConfigurationChange == nil)
    }

    @Test("onConfigurationChange は差し替え可能")
    func handlerIsSettable() {
        let mic = MicCapture(voiceProcessingEnabled: false)
        let called = LockedBool()
        mic.onConfigurationChange = { called.set(true) }
        // 手動で発火させて代入の正当性を確認
        mic.onConfigurationChange?()
        #expect(called.value == true)
    }
}

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var _v: Bool = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _v }
    func set(_ v: Bool) { lock.lock(); _v = v; lock.unlock() }
}
