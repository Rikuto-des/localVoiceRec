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
/// - voiceProcessingEnabled = true (既定) の場合、macOS の AUVoiceProcessing IO が
///   有効化され、システム標準のエコーキャンセル (AEC) / ノイズサプレッション / AGC が
///   入力に適用される。会議録音時にスピーカーから出た相手の声がマイクに回り込むのを
///   システムレベルで除去する。format は 16kHz mono に固定される副作用がある点に注意。
public final class MicCapture: @unchecked Sendable {

    public enum State {
        case idle
        case running
    }

    private let engine = AVAudioEngine()
    private let bus: AVAudioNodeBus = 0
    private let bufferSize: AVAudioFrameCount
    private let voiceProcessingEnabled: Bool

    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var state: State = .idle
    private let lock = NSLock()

    /// AsyncStream のバッファ上限を超えてドロップされたバッファ数を計上する shared box。
    /// audio I/O thread の tap closure と UI スレッドの両方から触るため
    /// NSLock 保護下で増加・読み出しを行う。
    /// `SystemAudioTap.droppedPushCount` に相当する観測値で、診断 UI に出すと
    /// 「録音が壊れているのに sync 系では気付けない」ケースを早期検出できる。
    final class DropCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count: Int = 0
        func increment() {
            lock.lock(); _count += 1; lock.unlock()
        }
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return _count
        }
    }
    private let dropCounter = DropCounter()
    /// AsyncStream のバッファ上限を超えてドロップされたバッファ数。
    public var droppedBufferCount: Int { dropCounter.count }

    /// マイクが提供する format。`start()` 後に有効 (voice processing 適用後)。
    public private(set) var captureFormat: AVAudioFormat

    public init(
        bufferSize: AVAudioFrameCount = 4096,
        voiceProcessingEnabled: Bool = true
    ) {
        self.bufferSize = bufferSize
        self.voiceProcessingEnabled = voiceProcessingEnabled
        // engine.inputNode は engine 取得時点で利用可。format は実機 hardware に依存。
        // (voice processing 有効時は start() 内で再取得する)
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

        // ★ Voice Processing (AEC + NS + AGC) を有効化 ★
        // installTap より前、engine.prepare() より前に呼ぶ必要がある。
        // 失敗してもマイク自体は動かしたいので、エラーは log だけ出して継続する。
        if voiceProcessingEnabled {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
            } catch {
                // 一部のデバイス・format ではサポートされない。raw キャプチャに fallback。
                // os.log は AudioCapture モジュール側に既にあるので、ここでは print も避け、
                // 上位に伝える情報は state machine ではなく副作用としての format に乗せる。
            }
        }

        // installTap の format は voice processing 後の format で取得する必要がある。
        // (voice processing が有効だと typically 16kHz mono Float32 に固定される)
        let fmt = engine.inputNode.inputFormat(forBus: bus)
        self.captureFormat = fmt

        let (stream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        self.continuation = cont

        let consumerCont = cont
        // tap closure には self を取らせず、必要な値だけ局所キャプチャする
        // (audio I/O thread から MicCapture を直接参照させない)。
        let dropCounter = self.dropCounter
        engine.inputNode.installTap(
            onBus: bus,
            bufferSize: bufferSize,
            format: fmt
        ) { buffer, _ in
            // buffer は AVAudioEngine の内部プールから来るため、消費前に再利用される可能性がある。
            // → コピーして yield する (consumer 側で WAV 書き込み等を行うため)。
            Self.yieldCopy(of: buffer, into: consumerCont, dropCounter: dropCounter)
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
        into cont: AsyncStream<AVAudioPCMBuffer>.Continuation,
        dropCounter: DropCounter
    ) {
        guard let copy = copyBuffer(src) else { return }
        // AVAudioPCMBuffer は非 Sendable。box 経由で region 移譲を成立させる。
        let box = UncheckedSendableBox(copy)
        switch cont.yield(box.value) {
        case .dropped:
            // AsyncStream の bufferingNewest(N) 上限を超え、古いバッファが silent drop された。
            // 録音中の drop は文字起こしの欠落につながるため、観測値として計上する。
            dropCounter.increment()
        case .enqueued, .terminated:
            break
        @unknown default:
            break
        }
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
