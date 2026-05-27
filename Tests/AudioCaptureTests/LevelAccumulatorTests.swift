import Foundation
import AVFAudio
import Testing
@testable import AudioCapture

/// `LevelAccumulator` の単体テスト。
///
/// AVAudioPCMBuffer を直接食わせて RMS / Peak が想定通り計算されるかを確認する。
/// 100ms snapshot ループの統合テストはハードウェア依存のため別途。
@Suite("LevelAccumulator")
struct LevelAccumulatorTests {

    // MARK: - Helpers

    private func makeFloat32Buffer(
        channels: AVAudioChannelCount,
        interleaved: Bool,
        frames: AVAudioFrameCount,
        fill: (_ channel: Int, _ frame: Int) -> Float
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: channels,
            interleaved: interleaved
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let chs = Int(channels)
        if interleaved {
            let base = buffer.floatChannelData![0]
            for i in 0..<Int(frames) {
                for ch in 0..<chs {
                    base[i * chs + ch] = fill(ch, i)
                }
            }
        } else {
            for ch in 0..<chs {
                let p = buffer.floatChannelData![ch]
                for i in 0..<Int(frames) {
                    p[i] = fill(ch, i)
                }
            }
        }
        return buffer
    }

    // MARK: - Tests

    @Test("空バッファ追加 → snapshot は (0, 0)")
    func emptySnapshot() {
        let acc = LevelAccumulator()
        let (rms, peak) = acc.snapshot()
        #expect(rms == 0)
        #expect(peak == 0)
    }

    @Test("全ゼロバッファ → RMS=0, Peak=0")
    func silenceBuffer() {
        let acc = LevelAccumulator()
        let buf = makeFloat32Buffer(channels: 1, interleaved: false, frames: 1024) { _, _ in 0 }
        acc.add(buf)
        let (rms, peak) = acc.snapshot()
        #expect(rms == 0)
        #expect(peak == 0)
    }

    @Test("一定値 0.5 (1ch planar) → RMS≈0.5, Peak=0.5")
    func constantHalfMono() {
        let acc = LevelAccumulator()
        let buf = makeFloat32Buffer(channels: 1, interleaved: false, frames: 1024) { _, _ in 0.5 }
        acc.add(buf)
        let (rms, peak) = acc.snapshot()
        #expect(abs(rms - 0.5) < 1e-5)
        #expect(abs(peak - 0.5) < 1e-5)
    }

    @Test("一定値 0.5 (2ch interleaved) → RMS≈0.5, Peak=0.5")
    func constantHalfStereoInterleaved() {
        let acc = LevelAccumulator()
        let buf = makeFloat32Buffer(channels: 2, interleaved: true, frames: 1024) { _, _ in 0.5 }
        acc.add(buf)
        let (rms, peak) = acc.snapshot()
        #expect(abs(rms - 0.5) < 1e-5)
        #expect(abs(peak - 0.5) < 1e-5)
    }

    @Test("片チャンネルだけ 0.8、もう一方 0 (2ch planar) → Peak=0.8")
    func oneChannelLoud() {
        let acc = LevelAccumulator()
        let buf = makeFloat32Buffer(channels: 2, interleaved: false, frames: 512) { ch, _ in
            ch == 0 ? 0.8 : 0.0
        }
        acc.add(buf)
        let (rms, peak) = acc.snapshot()
        // RMS = sqrt((0.8^2 * 512 + 0 * 512) / 1024) = sqrt(0.32) ≈ 0.566
        #expect(abs(rms - Float(0.32.squareRoot())) < 1e-4)
        #expect(abs(peak - 0.8) < 1e-5)
    }

    @Test("snapshot 後は内部状態がリセットされる")
    func snapshotResets() {
        let acc = LevelAccumulator()
        let buf = makeFloat32Buffer(channels: 1, interleaved: false, frames: 256) { _, _ in 0.5 }
        acc.add(buf)
        _ = acc.snapshot()
        let (rms2, peak2) = acc.snapshot()
        #expect(rms2 == 0)
        #expect(peak2 == 0)
    }

    @Test("複数バッファを累積 → 結合 RMS が正しい")
    func multipleBuffersAccumulate() {
        let acc = LevelAccumulator()
        let b1 = makeFloat32Buffer(channels: 1, interleaved: false, frames: 512) { _, _ in 0.5 }
        let b2 = makeFloat32Buffer(channels: 1, interleaved: false, frames: 512) { _, _ in -0.5 }
        acc.add(b1)
        acc.add(b2)
        let (rms, peak) = acc.snapshot()
        // 全 1024 サンプル、|v|=0.5 → RMS=0.5, Peak=0.5
        #expect(abs(rms - 0.5) < 1e-5)
        #expect(abs(peak - 0.5) < 1e-5)
    }

    @Test("Int16 フォーマット → スケーリング込みで RMS が計算される")
    func int16Buffer() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        )!
        let frames: AVAudioFrameCount = 1024
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let p = buf.int16ChannelData![0]
        // 16384 → 0.5 fullscale
        for i in 0..<Int(frames) {
            p[i] = 16384
        }
        let acc = LevelAccumulator()
        acc.add(buf)
        let (rms, peak) = acc.snapshot()
        #expect(abs(rms - 0.5) < 1e-3)
        #expect(abs(peak - 0.5) < 1e-3)
    }
}
