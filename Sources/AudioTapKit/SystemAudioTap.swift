import Foundation
import CoreAudio
import AudioToolbox
import AVFAudio
import Synchronization

/// Core Audio process tap + aggregate device によるシステム音声収録。
///
/// ## 仕組み
/// 1. `CATapDescription` で「全プロセス stereo mixdown」の tap を作成
///    (Objective-C 由来の `initStereoMixdownOfProcesses:` を空配列で呼ぶ → 全プロセス対象)。
///    - `initStereoMixdownOfProcesses:` を空配列で呼んだときの挙動が「全プロセス」になるかは
///      ヘッダ仕様としては **未確定**。安全策として `initStereoGlobalTapButExcludeProcesses:`
///      (空配列を渡せば全プロセスタップ) を採用する。
/// 2. `AudioHardwareCreateProcessTap` で tap を生成 → `kAudioTapPropertyUID` を取得。
/// 3. `AudioHardwareCreateAggregateDevice` で `kAudioAggregateDeviceUIDKey` を持つ
///    private aggregate device を作成し、`kAudioAggregateDeviceTapListKey` に tap UID 配列を渡す。
/// 4. `AudioDeviceCreateIOProcIDWithBlock` で IOProc を登録 → `AudioDeviceStart`。
///    IOProc では受け取った `AudioBufferList` の中身を ring buffer に memcpy するだけ。
/// 5. consumer Task が ring buffer をポーリングし、`AVAudioPCMBuffer` を構築して
///    `AsyncStream` に yield する。
///
/// ## RT セーフネス
/// - IOProc 内: ring buffer への `memcpy` のみ。`AVAudioPCMBuffer` 生成は consumer 側。
/// - `AudioObjectGetPropertyData` 系は事前に format / UID をキャッシュ。RT 内では呼ばない。
///
/// ## 権限
/// - 初回 `AudioDeviceStart` で OS が「システム音声録音」TCC プロンプトを表示する。
/// - 拒否された場合、`AudioDeviceStart` が non-zero status を返す
///   (具体的な status 値は **未確定**)。
public final class SystemAudioTap: @unchecked Sendable {

    // MARK: - Public

    public private(set) var captureFormat: AVAudioFormat
    public var droppedPushCount: Int { ring.droppedPushCount }

    // MARK: - Internal state

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var consumerTask: Task<Void, Never>?
    private var isRunning = false
    private let lock = NSLock()

    /// Ring buffer 容量。48kHz × stereo × Float32 = 384 KB/sec。
    /// 2 秒分 ≒ 768 KB を確保する (一時的なジッタ吸収用)。
    private let ring: SPSCByteRingBuffer
    private let ringCapacityBytes: Int

    /// IOProc が ring 経由で渡してくる bytes-per-frame (キャッシュ)。
    private var bytesPerFrame: Int = 0

    // MARK: - Init

    /// - Throws: 初期 format 解決に失敗した場合 ``AudioTapError``
    public init() throws {
        // 暫定 format。`start()` で実 stream format に更新する。
        // 多くの Mac は 48 kHz Float32 stereo。
        guard let initialFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ) else {
            throw AudioTapError.streamFormatUnavailable(-1)
        }
        self.captureFormat = initialFormat
        self.ringCapacityBytes = 48_000 * 2 * MemoryLayout<Float>.size * 2  // 2 秒
        self.ring = SPSCByteRingBuffer(capacity: ringCapacityBytes)
    }

    deinit {
        // 念のためクリーンアップ
        syncStop()
    }

    // MARK: - Start / Stop

    /// Process tap + aggregate device を生成し、IOProc を開始。
    /// PCM バッファのストリームを返す。
    public func start() throws -> AsyncStream<AVAudioPCMBuffer> {
        lock.lock()
        defer { lock.unlock() }
        if isRunning { throw AudioTapError.alreadyRunning }

        // ── Step 1: CATapDescription
        // Swift 上の正式 API 名は `init(stereoGlobalTapButExcludeProcesses:)` (Objective-C の
        // `initStereoGlobalTapButExcludeProcesses:` の refined Swift 名)。
        // 空配列を渡すと「除外プロセスゼロ＝全プロセスをタップ」となる。
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "localVoiceRec-systemTap"
        description.isPrivate = true   // Audio MIDI Setup に出さない
        description.muteBehavior = CATapMuteBehavior(rawValue: 0) ?? description.muteBehavior  // CATapUnmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let createStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard createStatus == noErr, tapID != kAudioObjectUnknown else {
            throw AudioTapError.tapCreationFailed(createStatus)
        }
        self.tapID = tapID

        // ── Step 2: Tap UID 取得
        let tapUID = try Self.readTapUID(tapID: tapID)

        // ── Step 3: tap の stream format を取得して captureFormat を確定
        var asbd = try Self.readTapStreamFormat(tapID: tapID)
        let avFormatOpt: AVAudioFormat? = withUnsafePointer(to: &asbd) { p in
            AVAudioFormat(streamDescription: p)
        }
        guard let avFormat = avFormatOpt else {
            AudioHardwareDestroyProcessTap(tapID)
            throw AudioTapError.streamFormatUnavailable(-1)
        }
        self.captureFormat = avFormat
        self.bytesPerFrame = Int(asbd.mBytesPerFrame)

        // ── Step 4: Aggregate device を作る (tap を含むため UID と TapList を指定)
        let aggUID = UUID().uuidString
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "localVoiceRec-aggregate",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID as String,
                    kAudioSubTapDriftCompensationKey as String: 0
                ]
            ]
        ]
        var aggID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
        guard aggStatus == noErr, aggID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            self.tapID = kAudioObjectUnknown
            throw AudioTapError.aggregateDeviceCreationFailed(aggStatus)
        }
        self.aggregateDeviceID = aggID

        // ── Step 5: AsyncStream + consumer task
        let (stream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        self.continuation = cont

        let bpf = self.bytesPerFrame
        let ring = self.ring
        let format = self.captureFormat
        // Consumer: ring buffer をポーリングして PCM バッファ化。
        // 終了条件は Task.isCancelled (`stop()` 内で `consumerTask?.cancel()` を呼ぶ)。
        self.consumerTask = Task.detached(priority: .userInitiated) {
            await Self.runConsumer(ring: ring, format: format, bytesPerFrame: bpf, continuation: cont)
        }

        // ── Step 6: IOProc を登録 (block 版)
        let ringRef = self.ring
        var procID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inputData, _, _, _ in
            // RT スレッド。malloc / lock / ARC を踏まない。
            // tap からは input 側に書き込まれる (Core Audio HAL の仕様)。
            //
            // `UnsafeMutableAudioBufferListPointer` は `UnsafeMutablePointer<AudioBufferList>` を
            // 取るので、const cast して wrap する (中身は読み取り専用に扱う)。
            let mutPtr = UnsafeMutablePointer<AudioBufferList>(mutating: inputData)
            let blp = UnsafeMutableAudioBufferListPointer(mutPtr)
            for buf in blp {
                guard let data = buf.mData else { continue }
                let count = Int(buf.mDataByteSize)
                if count > 0 {
                    _ = ringRef.push(UnsafeRawPointer(data), count: count)
                }
            }
        }
        guard ioStatus == noErr, let procID else {
            // cleanup
            AudioHardwareDestroyAggregateDevice(aggID)
            AudioHardwareDestroyProcessTap(tapID)
            self.aggregateDeviceID = kAudioObjectUnknown
            self.tapID = kAudioObjectUnknown
            self.continuation = nil
            self.consumerTask?.cancel()
            self.consumerTask = nil
            throw AudioTapError.ioProcCreationFailed(ioStatus)
        }
        self.ioProcID = procID

        // ── Step 7: device start (ここで初回 TCC プロンプト)
        let startStatus = AudioDeviceStart(aggID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggID, procID)
            AudioHardwareDestroyAggregateDevice(aggID)
            AudioHardwareDestroyProcessTap(tapID)
            self.aggregateDeviceID = kAudioObjectUnknown
            self.tapID = kAudioObjectUnknown
            self.ioProcID = nil
            self.continuation = nil
            self.consumerTask?.cancel()
            self.consumerTask = nil
            throw AudioTapError.deviceStartFailed(startStatus)
        }

        isRunning = true
        return stream
    }

    /// 停止 + クリーンアップ。
    public func stop() {
        syncStop()
    }

    // 同期版 (deinit からも呼べる)
    private func syncStop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        isRunning = false

        if let procID = ioProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            self.ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        consumerTask?.cancel()
        consumerTask = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Helpers

    private static func readTapUID(tapID: AudioObjectID) throws -> CFString {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = UInt32(MemoryLayout<CFString?>.size)
        var uid: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let uid else {
            throw AudioTapError.tapUIDUnavailable(status)
        }
        return uid.takeRetainedValue()
    }

    private static func readTapStreamFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size: UInt32 = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            throw AudioTapError.streamFormatUnavailable(status)
        }
        return asbd
    }

    // Consumer: ring buffer をポーリング → PCM buffer 構築 → yield
    private static func runConsumer(
        ring: SPSCByteRingBuffer,
        format: AVAudioFormat,
        bytesPerFrame: Int,
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    ) async {
        // 1 回の yield で出すフレーム数 (約 20 ms)
        let framesPerChunk = max(256, Int(format.sampleRate) / 50)
        let bytesPerChunk = framesPerChunk * max(bytesPerFrame, 1)

        // Reusable scratch buffer
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: bytesPerChunk, alignment: 16)
        defer { scratch.deallocate() }

        while !Task.isCancelled {
            if ring.availableForRead >= bytesPerChunk {
                let n = ring.pop(into: scratch, count: bytesPerChunk)
                if n > 0 {
                    yieldBuffer(scratch, byteCount: n, format: format, into: continuation)
                }
            } else {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        // 残データを flush
        let remaining = ring.availableForRead
        let aligned = (remaining / max(bytesPerFrame, 1)) * max(bytesPerFrame, 1)
        if aligned > 0 {
            let tmp = UnsafeMutableRawPointer.allocate(byteCount: aligned, alignment: 16)
            defer { tmp.deallocate() }
            let n = ring.pop(into: tmp, count: aligned)
            if n > 0 {
                yieldBuffer(tmp, byteCount: n, format: format, into: continuation)
            }
        }
        continuation.finish()
    }

    /// `makeBuffer` → `yield` のセットを 1 関数にして `sending` 移譲を成立させる。
    /// AVAudioPCMBuffer は非 Sendable だが、ここで生成した直後に yield するだけなので
    /// region-based isolation 的には移譲完了とみなせる。コンパイラが追えない場合は
    /// `UncheckedSendableBox` 経由で `value` を取り出し直して渡す。
    private static func yieldBuffer(
        _ src: UnsafeRawPointer,
        byteCount: Int,
        format: AVAudioFormat,
        into continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    ) {
        guard let buf = makeBuffer(from: src, byteCount: byteCount, format: format) else { return }
        let box = UncheckedSendableBox(buf)
        continuation.yield(box.value)
    }

    private static func makeBuffer(
        from src: UnsafeRawPointer,
        byteCount: Int,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let frames = AVAudioFrameCount(byteCount / bytesPerFrame)
        guard frames > 0 else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames

        let abl = buffer.audioBufferList.pointee
        let blp = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)

        if format.isInterleaved || abl.mNumberBuffers == 1 {
            // 1 本のバッファに全データ
            if let dst = blp[0].mData {
                memcpy(dst, src, byteCount)
            }
        } else {
            // non-interleaved planar: src は interleaved 想定だと崩れるが、
            // Core Audio tap は通常 non-interleaved planar を返さない (planar 単一が普通)。
            // 安全のため、入力 byteCount を全 channel に均等分割して per-channel copy する。
            let channels = Int(format.channelCount)
            let bytesPerChannel = byteCount / channels
            for ch in 0..<channels {
                if let dst = blp[ch].mData {
                    memcpy(dst, src.advanced(by: ch * bytesPerChannel), bytesPerChannel)
                }
            }
        }
        return buffer
    }
}
