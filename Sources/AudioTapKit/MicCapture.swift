import Foundation
import AVFAudio
import AVFoundation

/// `AVAudioEngine.inputNode` 経由でマイク音声を取得する。
///
/// ## 設計
/// - `installTap` のコールバックは通常スレッド (audio I/O queue) で呼ばれる。`AVAudioPCMBuffer`
///   を直接 `AsyncStream` に yield して問題なし (Process Tap の IOProc のような RT 制約は無い)。
/// - 出力 format は **ハードウェア由来** の `inputFormat(forBus:)`。再サンプル/変換は consumer 側責務。
/// - 同期 ` start() ` ではなく `async` を採用しているのは Contract 全体と粒度を揃えるため。
public final class MicCapture: @unchecked Sendable {

    public enum State {
        case idle
        case running
    }

    private let engine = AVAudioEngine()
    private let bus: AVAudioNodeBus = 0
    private let bufferSize: AVAudioFrameCount

    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var state: State = .idle
    private let lock = NSLock()

    /// マイクが提供するハードウェア format。`start()` 後に有効。
    public private(set) var captureFormat: AVAudioFormat

    public init(bufferSize: AVAudioFrameCount = 4096) {
        self.bufferSize = bufferSize
        // engine.inputNode は engine 取得時点で利用可。format は実機 hardware に依存。
        self.captureFormat = engine.inputNode.inputFormat(forBus: 0)
    }

    /// マイクを起動して PCM バッファのストリームを返す。
    ///
    /// **権限要求**: 呼び出し前に `AVCaptureDevice.requestAccess(for: .audio)` で
    /// マイク権限を許可させること。本メソッド内では再要求しない。
    public func start() throws -> AsyncStream<AVAudioPCMBuffer> {
        lock.lock()
        defer { lock.unlock() }
        if state == .running { throw AudioTapError.alreadyRunning }

        // installTap の format に nil を渡すと hardware format が使われるが、
        // Contract 上のテスト容易性のため明示的に取得して保存しておく。
        let fmt = engine.inputNode.inputFormat(forBus: bus)
        self.captureFormat = fmt

        let (stream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        self.continuation = cont

        let consumerCont = cont
        engine.inputNode.installTap(
            onBus: bus,
            bufferSize: bufferSize,
            format: fmt
        ) { buffer, _ in
            // buffer は AVAudioEngine の内部プールから来るため、消費前に再利用される可能性がある。
            // → コピーして yield する (consumer 側で WAV 書き込み等を行うため)。
            Self.yieldCopy(of: buffer, into: consumerCont)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: bus)
            self.continuation?.finish()
            self.continuation = nil
            throw AudioTapError.engineStartFailed(error.localizedDescription)
        }
        state = .running
        return stream
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard state == .running else { return }
        engine.inputNode.removeTap(onBus: bus)
        engine.stop()
        continuation?.finish()
        continuation = nil
        state = .idle
    }

    private static func yieldCopy(
        of src: AVAudioPCMBuffer,
        into cont: AsyncStream<AVAudioPCMBuffer>.Continuation
    ) {
        guard let copy = copyBuffer(src) else { return }
        // AVAudioPCMBuffer は非 Sendable。box 経由で region 移譲を成立させる。
        let box = UncheckedSendableBox(copy)
        cont.yield(box.value)
    }

    /// AVAudioPCMBuffer をディープコピーする。tap callback が再利用するバッファに対応する。
    private static func copyBuffer(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: src.format,
            frameCapacity: src.frameCapacity
        ) else { return nil }
        copy.frameLength = src.frameLength

        let channels = Int(src.format.channelCount)
        let frames = Int(src.frameLength)

        switch src.format.commonFormat {
        case .pcmFormatFloat32:
            if let s = src.floatChannelData, let d = copy.floatChannelData {
                if src.format.isInterleaved {
                    memcpy(d[0], s[0], frames * channels * MemoryLayout<Float>.size)
                } else {
                    for ch in 0..<channels {
                        memcpy(d[ch], s[ch], frames * MemoryLayout<Float>.size)
                    }
                }
            }
        case .pcmFormatInt16:
            if let s = src.int16ChannelData, let d = copy.int16ChannelData {
                if src.format.isInterleaved {
                    memcpy(d[0], s[0], frames * channels * MemoryLayout<Int16>.size)
                } else {
                    for ch in 0..<channels {
                        memcpy(d[ch], s[ch], frames * MemoryLayout<Int16>.size)
                    }
                }
            }
        case .pcmFormatInt32:
            if let s = src.int32ChannelData, let d = copy.int32ChannelData {
                if src.format.isInterleaved {
                    memcpy(d[0], s[0], frames * channels * MemoryLayout<Int32>.size)
                } else {
                    for ch in 0..<channels {
                        memcpy(d[ch], s[ch], frames * MemoryLayout<Int32>.size)
                    }
                }
            }
        case .pcmFormatFloat64:
            if let s = src.audioBufferList.pointee.mBuffers.mData,
               let d = copy.audioBufferList.pointee.mBuffers.mData {
                memcpy(d, s, Int(src.audioBufferList.pointee.mBuffers.mDataByteSize))
            }
        case .otherFormat:
            return nil
        @unknown default:
            return nil
        }
        return copy
    }
}
