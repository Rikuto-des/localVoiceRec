import Foundation
import AVFoundation
import AVFAudio
import AudioTapKit
import Darwin

// MARK: - Configuration

let captureDuration: TimeInterval = {
    if let s = ProcessInfo.processInfo.environment["POC_DURATION"], let d = Double(s) {
        return d
    }
    return 30.0
}()
let outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Tools/AudioTapPoC/output", isDirectory: true)

// MARK: - Logging

func stderrPrintln(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}

func info(_ msg: String) {
    print("[AudioTapPoC] " + msg)
}

func fail(_ msg: String) -> Never {
    stderrPrintln("[AudioTapPoC][error] " + msg)
    exit(1)
}

// MARK: - Permission helpers

@MainActor
func ensureMicrophonePermission() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return true
    case .notDetermined:
        info("Requesting microphone permission ...")
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                c.resume(returning: granted)
            }
        }
    case .denied, .restricted:
        return false
    @unknown default:
        return false
    }
}

// MARK: - Resource info helpers

func currentRSSBytes() -> Int64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int64(info.resident_size) : -1
}

func currentCPUSeconds() -> Double {
    var info = task_thread_times_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return -1 }
    let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000.0
    let sys  = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000.0
    return user + sys
}

// MARK: - Signal handling (Ctrl+C)

final class ManagedFlag: @unchecked Sendable {
    private var v = false
    private let lock = NSLock()
    func set() { lock.lock(); v = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return v }
}

let stopRequested = ManagedFlag()

func installSignalHandlers() {
    signal(SIGINT, { _ in stopRequested.set() })
    signal(SIGTERM, { _ in stopRequested.set() })
}

// MARK: - Main

@main
struct AudioTapPoC {
    static func main() async {
        setbuf(stdout, nil)  // line buffering 強制 (crash 直前の print も flush される)
        installSignalHandlers()
        info("AudioTapKit version: \(AudioTapKit.version)")
        info("Capture duration: \(captureDuration) s")
        info("Output directory: \(outputDir.path)")

        // 1. ディレクトリ準備
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            fail("Could not create output directory: \(error.localizedDescription)")
        }
        let micURL = outputDir.appendingPathComponent("mic.wav")
        let sysURL = outputDir.appendingPathComponent("system.wav")
        // 既存ファイルを削除 (上書き)
        try? FileManager.default.removeItem(at: micURL)
        try? FileManager.default.removeItem(at: sysURL)

        // 2. マイク権限要求
        let micGranted = await ensureMicrophonePermission()
        if !micGranted {
            fail("Microphone permission denied. macOS の システム設定 → プライバシーとセキュリティ → マイク を確認。")
        }
        info("Microphone permission: granted")
        info("System audio permission: 初回 SystemAudioTap.start() で OS ダイアログが出ます。")

        // 3. インスタンス生成
        let mic = MicCapture(bufferSize: 4096)
        let tap: SystemAudioTap
        do { tap = try SystemAudioTap() } catch {
            fail("SystemAudioTap init failed: \(error)")
        }

        // 4. start
        let micStream: AsyncStream<AVAudioPCMBuffer>
        let sysStream: AsyncStream<AVAudioPCMBuffer>
        let captureStart = Date()
        do {
            micStream = try mic.start()
            info("Mic started. format = \(mic.captureFormat)")
        } catch {
            fail("MicCapture.start failed: \(error)")
        }
        do {
            sysStream = try tap.start()
            info("System tap started. format = \(tap.captureFormat)")
        } catch {
            mic.stop()
            fail("SystemAudioTap.start failed: \(error). " +
                 "システム音声録音 (System Audio Recording) 権限の許可が必要な可能性があります。")
        }

        // 5. ファイルライター
        let micWriter: WAVFileWriter
        let sysWriter: WAVFileWriter
        do {
            micWriter = try WAVFileWriter(url: micURL, format: mic.captureFormat)
            sysWriter = try WAVFileWriter(url: sysURL, format: tap.captureFormat)
        } catch {
            mic.stop()
            tap.stop()
            fail("WAV writer create failed: \(error)")
        }

        // 6. 並列消費 (各 Task でストリームを読みつつ WAV へ書き込み)
        let micState = StreamState()
        let sysState = StreamState()

        async let micRun: Void = consume(stream: micStream, writer: micWriter, label: "mic", state: micState)
        async let sysRun: Void = consume(stream: sysStream, writer: sysWriter, label: "sys", state: sysState)

        // 7. 時間管理 (キャンセル監視)
        let deadlineTask = Task {
            let stepNs: UInt64 = 200_000_000
            let totalNs = UInt64(captureDuration * 1_000_000_000)
            var elapsed: UInt64 = 0
            while elapsed < totalNs {
                if stopRequested.get() {
                    info("Ctrl+C 受信。graceful shutdown へ。")
                    return
                }
                try? await Task.sleep(nanoseconds: stepNs)
                elapsed += stepNs
            }
        }

        let cpu0 = currentCPUSeconds()
        let rss0 = currentRSSBytes()
        await deadlineTask.value

        // 8. 停止
        info("Stopping ...")
        mic.stop()
        tap.stop()

        // consumer Task の自然終了を待つ (continuation.finish() 後 stream は終了する)
        _ = await micRun
        _ = await sysRun
        let captureEnd = Date()

        // 9. 出力情報
        let elapsedReal = captureEnd.timeIntervalSince(captureStart)
        let cpu1 = currentCPUSeconds()
        let rss1 = currentRSSBytes()
        let cpuDelta = cpu1 - cpu0
        let cpuPct = elapsedReal > 0 ? (cpuDelta / elapsedReal) * 100 : 0

        info("=== Results ===")
        let micFrames = micState.frames
        let sysFrames = sysState.frames
        let micSeconds = Double(micFrames) / mic.captureFormat.sampleRate
        let sysSeconds = Double(sysFrames) / tap.captureFormat.sampleRate

        info("mic.wav: \(micURL.path)")
        info("  format: sr=\(mic.captureFormat.sampleRate) Hz, ch=\(mic.captureFormat.channelCount), commonFormat=\(describe(mic.captureFormat.commonFormat))")
        info("  frames captured: \(micFrames), buffers: \(micState.buffers), duration: \(String(format: "%.3f", micSeconds)) s")
        info("system.wav: \(sysURL.path)")
        info("  format: sr=\(tap.captureFormat.sampleRate) Hz, ch=\(tap.captureFormat.channelCount), commonFormat=\(describe(tap.captureFormat.commonFormat))")
        info("  frames captured: \(sysFrames), buffers: \(sysState.buffers), duration: \(String(format: "%.3f", sysSeconds)) s")
        info("Real elapsed: \(String(format: "%.3f", elapsedReal)) s")
        info("Drift mic vs real:  \(String(format: "%+.3f", micSeconds - elapsedReal)) s")
        info("Drift sys vs real:  \(String(format: "%+.3f", sysSeconds - elapsedReal)) s")
        info("Tap dropped pushes (ring full): \(tap.droppedPushCount)")
        info("Tap IOProc calls:                \(tap.ioProcCallCount)")
        info("Tap non-zero buffers observed:   \(tap.nonZeroBufferCount)")
        info("Tap bytes received total:        \(tap.receivedBytesTotal)")
        info("CPU: \(String(format: "%.3f", cpuDelta)) s used over \(String(format: "%.3f", elapsedReal)) s wall (\(String(format: "%.1f", cpuPct))%)")
        info("Memory: rss before=\(rss0) bytes, after=\(rss1) bytes, peak-ish delta=\(rss1 - rss0)")
    }
}

// MARK: - Consumer

final class StreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var _frames: AVAudioFramePosition = 0
    private var _buffers: Int = 0
    var frames: AVAudioFramePosition { lock.lock(); defer { lock.unlock() }; return _frames }
    var buffers: Int { lock.lock(); defer { lock.unlock() }; return _buffers }
    func add(frames: AVAudioFramePosition) {
        lock.lock(); _frames += frames; _buffers += 1; lock.unlock()
    }
}

func consume(
    stream: AsyncStream<AVAudioPCMBuffer>,
    writer: WAVFileWriter,
    label: String,
    state: StreamState
) async {
    for await buffer in stream {
        do {
            try writer.write(buffer)
            state.add(frames: AVAudioFramePosition(buffer.frameLength))
        } catch {
            stderrPrintln("[\(label)] write failed: \(error.localizedDescription)")
        }
    }
    writer.close()
}

// MARK: - Helpers

func describe(_ f: AVAudioCommonFormat) -> String {
    switch f {
    case .pcmFormatFloat32: return "Float32"
    case .pcmFormatFloat64: return "Float64"
    case .pcmFormatInt16:   return "Int16"
    case .pcmFormatInt32:   return "Int32"
    case .otherFormat:      return "Other"
    @unknown default:       return "Unknown"
    }
}
