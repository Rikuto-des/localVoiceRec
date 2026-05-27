import Foundation
import CoreAudio
import AudioToolbox
import AVFAudio
import Synchronization
import os.log

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
///
/// ## 既知の落とし穴 (S10-A で実機調査)
/// - **silent buffers**: IOProc は呼ばれるが mDataByteSize=0 / 全ゼロのケース。
///   原因として最も多いのが TCC 権限の silent denial。`recvCount` / `nonZeroBufferCount` /
///   `recvBytesTotal` のカウンタで観測する。
/// - **CATapDescription の muteBehavior**: 明示的に `.unmuted` (=0) に設定する。
///   サイレント再生されると system 音は耳には聞こえるが tap に届く前にミュートされる可能性。
/// - **aggregate のキー**: `kAudioAggregateDeviceTapAutoStartKey` を有効化すると、
///   tap が「最初に音を受け取るまで」AudioDeviceStart が待ってくれる。
public final class SystemAudioTap: @unchecked Sendable {

    // MARK: - Logger
    private static let logger = Logger(subsystem: "com.example.localVoiceRec", category: "audio")

    // MARK: - Public

    public private(set) var captureFormat: AVAudioFormat
    public var droppedPushCount: Int { ring.droppedPushCount }

    /// IOProc 呼び出し回数 (デバッグ観測値)。
    public var ioProcCallCount: Int { _ioProcCallCount.value.load(ordering: .relaxed) }
    /// IOProc が「中身が全部ゼロでないバッファ」を観測した回数 (デバッグ観測値)。
    public var nonZeroBufferCount: Int { _nonZeroBufferCount.value.load(ordering: .relaxed) }
    /// IOProc が ring に push した合計バイト数 (デバッグ観測値)。
    public var receivedBytesTotal: Int { _recvBytesTotal.value.load(ordering: .relaxed) }

    /// 軽量な「IOProc が進んでいるか」スナップショット。watchdog 用。
    /// (ioProcCallCount, receivedBytesTotal) を 1 回の同期スナップショットで返す。
    /// 上位は一定間隔で呼び出し、両カウンタが進んでいなければ HW 切替 / 切断による
    /// IOProc 停止を疑える。
    public func flowSnapshot() -> (callCount: Int, bytesReceived: Int) {
        (ioProcCallCount, receivedBytesTotal)
    }

    // MARK: - Internal state

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var consumerTask: Task<Void, Never>?
    private var isRunning = false
    private let lock = NSLock()

    /// A5: デフォルト出力デバイス切替監視用 listener block。`start()` で登録、`stop()` で解除する。
    /// 現状は警告ログのみ。aggregate 再構築は Phase D 以降。
    private var defaultOutputDeviceListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputDeviceListenerInstalled = false

    /// Ring buffer 容量。48kHz × stereo × Float32 = 384 KB/sec。
    /// 2 秒分 ≒ 768 KB を確保する (一時的なジッタ吸収用)。
    private let ring: SPSCByteRingBuffer
    private let ringCapacityBytes: Int

    /// IOProc が ring 経由で渡してくる bytes-per-frame (キャッシュ)。
    private var bytesPerFrame: Int = 0

    /// 診断カウンタ。`Synchronization.Atomic` は ~Copyable のため、reference 型の box に包む。
    /// IOProc は box への参照を保持してインクリメントするだけなので RT-safe。
    private final class CounterBox: @unchecked Sendable {
        let value = Atomic<Int>(0)
    }
    private let _ioProcCallCount = CounterBox()
    private let _nonZeroBufferCount = CounterBox()
    private let _recvBytesTotal = CounterBox()

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
        Self.logger.debug("SystemAudioTap.init: ringCapacity=\(self.ringCapacityBytes) bytes")
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

        Self.logger.info("SystemAudioTap.start: begin")

        // ── Step 1: CATapDescription
        // Swift 上の正式 API 名は `init(stereoGlobalTapButExcludeProcesses:)` (Objective-C の
        // `initStereoGlobalTapButExcludeProcesses:` の refined Swift 名)。
        // 空配列を渡すと「除外プロセスゼロ＝全プロセスをタップ」となる。
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "localVoiceRec-systemTap"
        description.isPrivate = true   // Audio MIDI Setup に出さない
        // A3: 空 exclude 配列 + isExclusive=true で「除外プロセスゼロ＝全プロセスをタップ」の
        // 意味を仕様レベルで明確化。AudioCap サンプル準拠。
        description.isExclusive = true
        // A4: 明示的に `.unmuted`。raw 0 ではなく enum で書くことで意図を明示。
        description.muteBehavior = .unmuted
        // tap の UUID を明示生成 (auto-restore に影響する可能性があるため固定値を避ける)
        description.uuid = UUID()

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let createStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard createStatus == noErr, tapID != kAudioObjectUnknown else {
            Self.logger.error("AudioHardwareCreateProcessTap failed: status=\(createStatus) (\(AudioTapError.fourCC(createStatus), privacy: .public))")
            throw AudioTapError.tapCreationFailed(createStatus)
        }
        self.tapID = tapID
        Self.logger.info("AudioHardwareCreateProcessTap ok: tapID=\(tapID)")

        // ── Step 2: Tap UID 取得
        let tapUID = try Self.readTapUID(tapID: tapID)
        Self.logger.info("Tap UID: \(tapUID as String, privacy: .public)")

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
        Self.logger.info("Tap stream format: sr=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) bpf=\(asbd.mBytesPerFrame) bitsPerCh=\(asbd.mBitsPerChannel) flags=0x\(String(asbd.mFormatFlags, radix: 16))")

        // ── Step 4: Aggregate device を作る (tap を含むため UID と TapList を指定)
        //
        // 重要: `kAudioAggregateDeviceTapAutoStartKey: 1` を付けると、
        // AudioDeviceStart は「tap が最初の音を受け取るまで」待つ → silent IOProc 呼び出しが
        // 開始されず、無音バッファを書き続ける問題を緩和する。
        // (private aggregate device 必須。`kAudioAggregateDeviceIsPrivateKey: 1` と併用)
        //
        // A2: aggregate device に「どの出力デバイスに対する tap か」を紐付ける必要がある。
        //   `kAudioAggregateDeviceMainSubDeviceKey` と `kAudioAggregateDeviceSubDeviceListKey`
        //   を欠くと、tap は「出力先未確定」となり実機で全ゼロバッファになる (確定原因)。
        //   AudioCap サンプル準拠で、現在のデフォルト出力デバイスを取得して紐付ける。
        let outputUID = try Self.readDefaultOutputDeviceUID()
        Self.logger.info("Default output device UID: \(outputUID as String, privacy: .public)")

        // A1: `kAudioSubTapUIDKey` の値は **tap オブジェクトの UID (kAudioTapPropertyUID で取得した
        //   CFString)** ではなく、`CATapDescription.uuid.uuidString` を渡す必要がある。
        //   Apple 公式サンプル AudioCap/ProcessTap.swift 準拠。これを取り違えると IOProc は
        //   呼ばれるが常に全ゼロバッファになる (確定原因)。
        let subTapUIDString = description.uuid.uuidString
        Self.logger.info("Sub-tap UID (description.uuid): \(subTapUIDString, privacy: .public) — tap kAudioTapPropertyUID was: \(tapUID as String, privacy: .public)")

        let aggUID = UUID().uuidString
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "localVoiceRec-aggregate",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceTapAutoStartKey as String: 1,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: subTapUIDString,
                    kAudioSubTapDriftCompensationKey as String: 0,
                    kAudioSubTapExtraInputLatencyKey as String: 0,
                ] as [String: Any]
            ]
        ]
        var aggID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
        guard aggStatus == noErr, aggID != kAudioObjectUnknown else {
            Self.logger.error("AudioHardwareCreateAggregateDevice failed: status=\(aggStatus) (\(AudioTapError.fourCC(aggStatus), privacy: .public))")
            AudioHardwareDestroyProcessTap(tapID)
            self.tapID = kAudioObjectUnknown
            throw AudioTapError.aggregateDeviceCreationFailed(aggStatus)
        }
        self.aggregateDeviceID = aggID
        Self.logger.info("AudioHardwareCreateAggregateDevice ok: aggID=\(aggID) uid=\(aggUID, privacy: .public)")

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
        let callCounter = self._ioProcCallCount
        let nonZeroCounter = self._nonZeroBufferCount
        let recvBytesCounter = self._recvBytesTotal
        var procID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inputData, _, _, _ in
            // RT スレッド。malloc / lock / ARC を踏まない (Atomic は OK)。
            // tap からは input 側に書き込まれる (Core Audio HAL の仕様)。
            //
            // `UnsafeMutableAudioBufferListPointer` は `UnsafeMutablePointer<AudioBufferList>` を
            // 取るので、const cast して wrap する (中身は読み取り専用に扱う)。
            callCounter.value.wrappingAdd(1, ordering: .relaxed)
            let mutPtr = UnsafeMutablePointer<AudioBufferList>(mutating: inputData)
            let blp = UnsafeMutableAudioBufferListPointer(mutPtr)
            var bufNonZero = false
            for buf in blp {
                guard let data = buf.mData else { continue }
                let count = Int(buf.mDataByteSize)
                if count > 0 {
                    // RT-safe silence detection: 最初の数 Float32 サンプルだけ peek
                    // (全数走査は重いので、最初の 16 サンプルでスポットチェック)
                    if !bufNonZero {
                        let probeCount = min(count / MemoryLayout<Float32>.size, 16)
                        let fp = data.assumingMemoryBound(to: Float32.self)
                        for i in 0..<probeCount where fp[i] != 0 {
                            bufNonZero = true
                            break
                        }
                    }
                    _ = ringRef.push(UnsafeRawPointer(data), count: count)
                    recvBytesCounter.value.wrappingAdd(count, ordering: .relaxed)
                }
            }
            if bufNonZero {
                nonZeroCounter.value.wrappingAdd(1, ordering: .relaxed)
            }
        }
        guard ioStatus == noErr, let procID else {
            Self.logger.error("AudioDeviceCreateIOProcIDWithBlock failed: status=\(ioStatus) (\(AudioTapError.fourCC(ioStatus), privacy: .public))")
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
        Self.logger.info("IOProc created")

        // ── Step 7: device start (ここで初回 TCC プロンプト)
        let startStatus = AudioDeviceStart(aggID, procID)
        guard startStatus == noErr else {
            Self.logger.error("AudioDeviceStart failed: status=\(startStatus) (\(AudioTapError.fourCC(startStatus), privacy: .public)) — TCC denial の可能性")
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
        Self.logger.info("AudioDeviceStart ok — capturing")

        // A5: デフォルト出力デバイス切替の監視 (警告ログのみ)。
        Self.installDefaultOutputDeviceListener(on: self)

        isRunning = true
        return stream
    }

    /// A5 helper: `kAudioHardwarePropertyDefaultOutputDevice` の変化を監視。
    /// 録音中にユーザーが出力先 (Bluetooth 等) を切り替えると aggregate が古いデバイスのまま
    /// 残り無音化するため、警告ログを残す。aggregate 再構築は Phase D 以降。
    private static func installDefaultOutputDeviceListener(on tap: SystemAudioTap) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            // 新しい UID を取得して比較ログ
            do {
                let newUID = try Self.readDefaultOutputDeviceUID()
                Self.logger.warning("Default output device changed → UID=\(newUID, privacy: .public). aggregate device は古い出力に紐付いたままのため、システム音声が無音化する可能性があります。録音を停止 → 再開してください (Phase D で自動再構築予定)。")
            } catch {
                Self.logger.warning("Default output device changed, but UID read failed: \(String(describing: error), privacy: .public)")
            }
        }
        let st = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            nil,
            block
        )
        if st == noErr {
            tap.defaultOutputDeviceListener = block
            tap.defaultOutputDeviceListenerInstalled = true
            Self.logger.info("Default output device listener installed")
        } else {
            Self.logger.warning("AudioObjectAddPropertyListenerBlock(defaultOutputDevice) failed: status=\(st) — 出力切替検知は無効です")
        }
    }

    private static func removeDefaultOutputDeviceListener(on tap: SystemAudioTap) {
        guard tap.defaultOutputDeviceListenerInstalled, let block = tap.defaultOutputDeviceListener else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let st = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            nil,
            block
        )
        if st != noErr {
            Self.logger.warning("AudioObjectRemovePropertyListenerBlock(defaultOutputDevice) failed: status=\(st)")
        }
        tap.defaultOutputDeviceListener = nil
        tap.defaultOutputDeviceListenerInstalled = false
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

        let callCount = _ioProcCallCount.value.load(ordering: .relaxed)
        let nonZeroCount = _nonZeroBufferCount.value.load(ordering: .relaxed)
        let recvBytes = _recvBytesTotal.value.load(ordering: .relaxed)
        Self.logger.info("SystemAudioTap.stop: ioProcCalls=\(callCount) nonZeroBuffers=\(nonZeroCount) bytesReceived=\(recvBytes) droppedPushes=\(self.ring.droppedPushCount)")
        // ── 無音バッファのみだった場合は、TCC 拒否の可能性を強く警告する。
        // (kTCCServiceAudioCapture は AudioDeviceStart 自体は noErr のままで silent buffer を返す)
        if callCount >= 10 && nonZeroCount == 0 && recvBytes > 0 {
            Self.logger.error("SystemAudioTap: \(callCount) IOProc calls received \(recvBytes) bytes but ALL ZERO. 強い疑い → kTCCServiceAudioCapture (システム音声録音 TCC) が拒否されている。システム設定 → プライバシーとセキュリティ → 「システム音声録音」(または旧名 “マイク” 配下) でアプリの許可状況を確認してください。")
        }

        // A5: listener を先に解除 (デバイス破棄前)
        Self.removeDefaultOutputDeviceListener(on: self)

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

    /// 現在のデフォルト出力デバイスの UID を取得する。
    ///
    /// aggregate device 構築時に `kAudioAggregateDeviceMainSubDeviceKey` と
    /// `kAudioAggregateDeviceSubDeviceListKey` で紐付けるために必要。
    /// 失敗時は silent fail させずに throw する (silent failure 防止)。
    private static func readDefaultOutputDeviceUID() throws -> String {
        // 1) デフォルト出力デバイスの AudioObjectID
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size: UInt32 = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        )
        guard st == noErr, deviceID != kAudioObjectUnknown else {
            throw AudioTapError.defaultOutputDeviceUnavailable(st)
        }

        // 2) そのデバイスの UID (CFString)
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var uidSize: UInt32 = UInt32(MemoryLayout<CFString?>.size)
        let st2 = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, ptr)
        }
        guard st2 == noErr, let uid else {
            throw AudioTapError.outputDeviceUIDUnavailable(st2)
        }
        return uid.takeRetainedValue() as String
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
