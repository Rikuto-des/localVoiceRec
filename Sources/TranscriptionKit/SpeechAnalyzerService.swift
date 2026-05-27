import Foundation
@preconcurrency import AVFoundation
import Speech
import Contracts

/// `TranscriptionService` の本実装。
///
/// macOS 26 で導入された `SpeechAnalyzer` + `SpeechTranscriber` を 2 つ用意し、
/// `Recording.micAudioURL` / `Recording.systemAudioURL` を並列に文字起こしする。
///
/// 同一 `locale` / `preset` で 2 つの transcriber を作るため、backing engine と
/// on-device モデルは共有される（Apple 公式仕様）。
public actor SpeechAnalyzerService: TranscriptionService {

    // MARK: - State

    /// 進行中の解析 Task。`cancelAll()` でまとめてキャンセルする。
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    /// 進行中の analyzer。`cancelAll()` で `cancelAndFinishNow()` する。
    private var activeAnalyzers: [UUID: SpeechAnalyzer] = [:]

    // MARK: - Init

    public init() {}

    // MARK: - TranscriptionService

    public func prewarm(locale: Locale) async throws {
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unsupportedLocale(identifier: locale.identifier)
        }
        let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw TranscriptionError.assetInstallationFailed(message: String(describing: error))
        }
    }

    public func installedLocales() async -> [Locale] {
        await SpeechTranscriber.installedLocales
    }

    public nonisolated func transcribe(
        recording: Recording,
        locale: Locale?
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.run(recording: recording, locale: locale, continuation: continuation)
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func cancelAll() async {
        for (_, analyzer) in activeAnalyzers {
            await analyzer.cancelAndFinishNow()
        }
        activeAnalyzers.removeAll()
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
    }

    // MARK: - Driver

    /// 2 ファイル分の解析を並列で起動し、結果を outer continuation に流す。
    private func run(
        recording: Recording,
        locale: Locale?,
        continuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation
    ) async {
        let runID = UUID()

        // 1) ロケール解決
        let baseLocale = locale ?? Locale.current
        guard let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: baseLocale) else {
            continuation.finish(throwing: TranscriptionError.unsupportedLocale(identifier: baseLocale.identifier))
            return
        }

        // 2) ファイル存在チェック（早期に上げる）
        let fm = FileManager.default
        if !fm.fileExists(atPath: recording.micAudioURL.path) {
            continuation.finish(throwing: TranscriptionError.fileNotReadable(recording.micAudioURL))
            return
        }
        if !fm.fileExists(atPath: recording.systemAudioURL.path) {
            continuation.finish(throwing: TranscriptionError.fileNotReadable(recording.systemAudioURL))
            return
        }

        // 3) 2 つの transcriber（同一 locale / preset でバックエンド共有）
        let micTranscriber = SpeechTranscriber(locale: resolvedLocale, preset: .transcription)
        let systemTranscriber = SpeechTranscriber(locale: resolvedLocale, preset: .transcription)

        // 4) Asset 確保（installed なら nil で skip）
        do {
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [micTranscriber, systemTranscriber]) {
                try await req.downloadAndInstall()
            }
        } catch {
            continuation.finish(throwing: TranscriptionError.assetInstallationFailed(message: String(describing: error)))
            return
        }

        // 5) ベスト format
        let micAudioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [micTranscriber])
        let systemAudioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [systemTranscriber])

        // 6) 2 本の analyzer
        let micAnalyzer = SpeechAnalyzer(modules: [micTranscriber])
        let systemAnalyzer = SpeechAnalyzer(modules: [systemTranscriber])

        let micRunID = UUID()
        let systemRunID = UUID()
        activeAnalyzers[micRunID] = micAnalyzer
        activeAnalyzers[systemRunID] = systemAnalyzer

        let recordingID = recording.id

        // 7) 並列実行
        let driver = Task { [weak self] in
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await Self.process(
                            url: recording.micAudioURL,
                            audioFormat: micAudioFormat,
                            transcriber: micTranscriber,
                            analyzer: micAnalyzer,
                            recordingID: recordingID,
                            source: .mic,
                            continuation: continuation
                        )
                    }
                    group.addTask {
                        try await Self.process(
                            url: recording.systemAudioURL,
                            audioFormat: systemAudioFormat,
                            transcriber: systemTranscriber,
                            analyzer: systemAnalyzer,
                            recordingID: recordingID,
                            source: .system,
                            continuation: continuation
                        )
                    }
                    try await group.waitForAll()
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: TranscriptionError.cancelled)
            } catch let e as TranscriptionError {
                continuation.finish(throwing: e)
            } catch {
                continuation.finish(throwing: TranscriptionError.analyzerFailed(message: String(describing: error)))
            }
            await self?.cleanup(runID: runID, micRunID: micRunID, systemRunID: systemRunID)
        }

        activeTasks[runID] = driver
    }

    private func cleanup(runID: UUID, micRunID: UUID, systemRunID: UUID) {
        activeAnalyzers.removeValue(forKey: micRunID)
        activeAnalyzers.removeValue(forKey: systemRunID)
        activeTasks.removeValue(forKey: runID)
    }

    // MARK: - Per-channel processing

    /// 1 ファイル分の処理。
    /// - 入力 PCM を `audioFormat` に変換しながら `AnalyzerInput` として流し込む。
    /// - 並行して `transcriber.results` を消費して outer continuation へ。
    private static func process(
        url: URL,
        audioFormat: AVAudioFormat?,
        transcriber: SpeechTranscriber,
        analyzer: SpeechAnalyzer,
        recordingID: UUID,
        source: TranscriptSegment.Source,
        continuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation
    ) async throws {
        // 入力ファイルを開く
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw TranscriptionError.analyzerFailed(message: "AVAudioFile open failed for \(url.lastPathComponent): \(error)")
        }

        // 入力 sequence
        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)

        // 結果消費 Task
        let resultsTask = Task<Void, Error> {
            do {
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    let text = String(result.text.characters)
                    let startSec = result.range.start.seconds
                    let endSec = result.range.end.seconds
                    let segment = TranscriptSegment(
                        recordingID: recordingID,
                        source: source,
                        startSec: startSec.isFinite ? startSec : 0,
                        endSec: endSec.isFinite ? endSec : 0,
                        text: text,
                        isFinal: result.isFinal
                    )
                    continuation.yield(segment)
                }
            } catch is CancellationError {
                throw TranscriptionError.cancelled
            } catch {
                throw TranscriptionError.analyzerFailed(message: String(describing: error))
            }
        }

        // PCM 投入 Task
        let feedTask = Task<Void, Error> {
            defer { inputBuilder.finish() }
            try feedAudioFile(
                audioFile: audioFile,
                targetFormat: audioFormat,
                inputBuilder: inputBuilder
            )
        }

        // analyzer を回す
        do {
            let lastSampleTime = try await analyzer.analyzeSequence(inputSequence)
            try await feedTask.value  // 投入完了を待つ（finish 済み）
            if let lastSampleTime {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            try await resultsTask.value
        } catch is CancellationError {
            await analyzer.cancelAndFinishNow()
            feedTask.cancel()
            resultsTask.cancel()
            throw TranscriptionError.cancelled
        } catch let e as TranscriptionError {
            await analyzer.cancelAndFinishNow()
            feedTask.cancel()
            resultsTask.cancel()
            throw e
        } catch {
            await analyzer.cancelAndFinishNow()
            feedTask.cancel()
            resultsTask.cancel()
            throw TranscriptionError.analyzerFailed(message: String(describing: error))
        }
    }

    /// `AVAudioFile` を順次読み出して `targetFormat` に変換、`AnalyzerInput` として yield する。
    private static func feedAudioFile(
        audioFile: AVAudioFile,
        targetFormat: AVAudioFormat?,
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    ) throws {
        let inputFormat = audioFile.processingFormat
        let outputFormat = targetFormat ?? inputFormat

        // 1 回の読み込みフレーム数（~0.5 秒程度を目安）
        let readFrameCapacity: AVAudioFrameCount = AVAudioFrameCount(max(1024, Int(inputFormat.sampleRate / 2)))

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: readFrameCapacity
        ) else {
            throw TranscriptionError.analyzerFailed(message: "Failed to allocate input PCM buffer")
        }

        let converter: AVAudioConverter?
        if inputFormat == outputFormat {
            converter = nil
        } else {
            guard let c = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw TranscriptionError.analyzerFailed(
                    message: "AVAudioConverter init failed (\(inputFormat) -> \(outputFormat))"
                )
            }
            converter = c
        }

        while true {
            try Task.checkCancellation()

            // 残量を計算。AVAudioFile.read(into:) は最終 partial read で
            // nilError を返すことがあるため、残量に合わせて frameCount を明示する。
            let remaining = audioFile.length - audioFile.framePosition
            if remaining <= 0 {
                break  // 正常 EOF
            }
            let toRead = AVAudioFrameCount(min(Int64(readFrameCapacity), remaining))

            inputBuffer.frameLength = 0
            do {
                try audioFile.read(into: inputBuffer, frameCount: toRead)
            } catch {
                throw TranscriptionError.analyzerFailed(message: "AVAudioFile.read failed for \(audioFile.url.lastPathComponent) at \(audioFile.framePosition)/\(audioFile.length): \(error)")
            }
            if inputBuffer.frameLength == 0 {
                break  // EOF (念のため)
            }

            let buffer: AVAudioPCMBuffer
            if let converter {
                // 出力 capacity は入力フレーム × (出レート/入レート) + マージン
                let ratio = outputFormat.sampleRate / inputFormat.sampleRate
                let outCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 1024)
                guard let outBuffer = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: outCapacity
                ) else {
                    throw TranscriptionError.analyzerFailed(message: "Failed to allocate output PCM buffer")
                }
                let state = ConverterFeedState(buffer: inputBuffer)
                var convError: NSError?
                let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
                    state.next(outStatus: outStatus)
                }
                if status == .error, let convError {
                    throw TranscriptionError.analyzerFailed(message: "AVAudioConverter error: \(convError)")
                }
                if outBuffer.frameLength == 0 {
                    continue
                }
                buffer = outBuffer
            } else {
                buffer = inputBuffer.copy() as? AVAudioPCMBuffer ?? inputBuffer
            }

            inputBuilder.yield(AnalyzerInput(buffer: buffer))
        }
    }
}

/// `AVAudioConverter.convert(to:error:withInputFrom:)` の入力ブロックに渡す状態。
/// var を `@Sendable` クロージャでキャプチャすると警告になるため、参照型に閉じ込めて回避する。
private final class ConverterFeedState: @unchecked Sendable {
    private var supplied = false
    private let buffer: AVAudioPCMBuffer

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if supplied {
            outStatus.pointee = .endOfStream
            return nil
        }
        supplied = true
        outStatus.pointee = .haveData
        return buffer
    }
}
