import Foundation
@preconcurrency import AVFoundation
import Speech
import Contracts
import os.log

/// `TranscriptionService` の本実装。
///
/// macOS 26 で導入された `SpeechAnalyzer` + `SpeechTranscriber` を 2 つ用意し、
/// `Recording.micAudioURL` / `Recording.systemAudioURL` を並列に文字起こしする。
///
/// 同一 `locale` / `preset` で 2 つの transcriber を作るため、backing engine と
/// on-device モデルは共有される（Apple 公式仕様）。
public actor SpeechAnalyzerService: TranscriptionService {

    private static let logger = Logger(subsystem: "com.example.localVoiceRec", category: "transcription")

    // MARK: - Time sanitization

    /// `result.range.start.seconds` / `end.seconds` が NaN や逆転になっているケースを補正する。
    ///
    /// - NaN startSec → `previousEndSec` を引き継ぐ (時系列が前に飛ばないように)
    /// - NaN endSec   → `startSec` と同値 (= 0 幅セグメント) にしてから後段で最小幅補正
    /// - endSec < startSec → `endSec = startSec + 0.01` で最小幅補正
    ///
    /// 戻り値は `(start, end)`。観測時は `os.log.debug` に記録する。
    static func sanitizeTimes(
        startSec: Double,
        endSec: Double,
        previousEndSec: Double
    ) -> (start: Double, end: Double) {
        let s = startSec.isFinite ? startSec : previousEndSec
        var e = endSec.isFinite ? endSec : s
        if !startSec.isFinite || !endSec.isFinite {
            logger.debug("NaN times detected: rawStart=\(startSec) rawEnd=\(endSec) → s=\(s) e=\(e)")
        }
        if e < s {
            logger.debug("Inverted times: start=\(s) end=\(e) → adjusting end to start+0.01")
            e = s + 0.01
        }
        return (s, e)
    }

    // MARK: - State

    /// 進行中の解析 Task。`cancelAll()` でまとめてキャンセルする。
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    /// 進行中の analyzer。`cancelAll()` で `cancelAndFinishNow()` する。
    private var activeAnalyzers: [UUID: SpeechAnalyzer] = [:]

    // MARK: - Init

    public init() {}

    // MARK: - TranscriptionService

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

    // MARK: - Live transcription (P4.2)

    /// 録音中に PCM バッファを直接流し込み、isFinal 確定セグメントを yield する。
    ///
    /// 上流 `buffers` AsyncStream が finish したら、内部の inputBuilder を finish し、
    /// `finalizeAndFinishThroughEndOfInput` で残りの暫定結果を確定する。
    public nonisolated func transcribeLive(
        buffers: AsyncStream<AVAudioPCMBuffer>,
        inputFormat: AVAudioFormat,
        recordingID: UUID,
        source: TranscriptSegment.Source,
        locale: Locale?
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        // `AsyncStream<AVAudioPCMBuffer>` の element は非 Sendable のため、
        // Task closure capture を strict concurrency が嫌う。box に包んで
        // `@unchecked Sendable` で渡す。実体は consumer Task が単独で読み出すので
        // データレースは発生しない (AudioCaptureServiceImpl と同じ運用)。
        let box = LiveBufferBox(stream: buffers)
        return AsyncThrowingStream { (continuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation) in
            let task = Task.detached { [weak self] in
                guard let self else { continuation.finish(); return }
                await self.runLive(
                    buffers: box,
                    inputFormat: inputFormat,
                    recordingID: recordingID,
                    source: source,
                    locale: locale,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func runLive(
        buffers box: LiveBufferBox,
        inputFormat: AVAudioFormat,
        recordingID: UUID,
        source: TranscriptSegment.Source,
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

        // 2) Transcriber + Analyzer
        let transcriber = SpeechTranscriber(locale: resolvedLocale, preset: .transcription)
        do {
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await req.downloadAndInstall()
            }
        } catch {
            continuation.finish(throwing: TranscriptionError.assetInstallationFailed(message: String(describing: error)))
            return
        }
        let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let analyzerRunID = UUID()
        activeAnalyzers[analyzerRunID] = analyzer

        // 3) 結果消費 (isFinal のみ yield)、PCM 投入、analyzer 駆動を 1 つの
        //    `withThrowingTaskGroup` で並走させる。actor 境界を跨がず、
        //    AnalyzerInput 用 AsyncStream の continuation も中で作る。
        let driver = Task.detached { [weak self] in
            let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
            let inputBox = LiveAnalyzerInputBox(stream: inputSequence)

            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    // a) PCM 投入
                    group.addTask {
                        do {
                            try await Self.feedLiveBuffers(
                                buffers: box.stream,
                                inputFormat: inputFormat,
                                targetFormat: targetFormat,
                                inputBuilder: inputBuilder
                            )
                            inputBuilder.finish()
                        } catch {
                            inputBuilder.finish()
                            throw error
                        }
                    }
                    // b) analyzer 駆動 + finalize
                    group.addTask {
                        let lastSampleTime = try await analyzer.analyzeSequence(inputBox.stream)
                        if let lastSampleTime {
                            try await analyzer.finalizeAndFinish(through: lastSampleTime)
                        } else {
                            try await analyzer.finalizeAndFinishThroughEndOfInput()
                        }
                    }
                    // c) 結果消費 (isFinal のみ outer continuation へ)
                    group.addTask {
                        var previousEndSec: Double = 0
                        for try await result in transcriber.results {
                            try Task.checkCancellation()
                            guard result.isFinal else { continue }
                            let text = String(result.text.characters)
                            let rawStart = result.range.start.seconds
                            let rawEnd = result.range.end.seconds
                            let (s, e) = Self.sanitizeTimes(
                                startSec: rawStart,
                                endSec: rawEnd,
                                previousEndSec: previousEndSec
                            )
                            previousEndSec = e
                            continuation.yield(TranscriptSegment(
                                recordingID: recordingID,
                                source: source,
                                startSec: s,
                                endSec: e,
                                text: text,
                                isFinal: true
                            ))
                        }
                    }
                    try await group.waitForAll()
                }
                continuation.finish()
            } catch is CancellationError {
                await analyzer.cancelAndFinishNow()
                continuation.finish(throwing: TranscriptionError.cancelled)
            } catch let e as TranscriptionError {
                await analyzer.cancelAndFinishNow()
                continuation.finish(throwing: e)
            } catch {
                await analyzer.cancelAndFinishNow()
                continuation.finish(throwing: TranscriptionError.analyzerFailed(message: String(describing: error)))
            }
            await self?.cleanupLive(runID: runID, analyzerRunID: analyzerRunID)
        }

        activeTasks[runID] = driver
    }

    private func cleanupLive(runID: UUID, analyzerRunID: UUID) {
        activeAnalyzers.removeValue(forKey: analyzerRunID)
        activeTasks.removeValue(forKey: runID)
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

    // MARK: - Asset management

    /// 指定 locale の on-device asset をインストールする（必要なら DL する）。
    ///
    /// プロトコルではなく具象型の API。アプリ起動時の事前ロードに使う。
    /// 初回呼び出しから推論までのレイテンシを下げる。
    public func installAsset(for locale: Locale) async throws {
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
                var previousEndSec: Double = 0
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    let text = String(result.text.characters)
                    let rawStart = result.range.start.seconds
                    let rawEnd = result.range.end.seconds
                    let (s, e) = SpeechAnalyzerService.sanitizeTimes(
                        startSec: rawStart,
                        endSec: rawEnd,
                        previousEndSec: previousEndSec
                    )
                    // isFinal のみ前進カウンタを更新 (partial は揺れるため)
                    if result.isFinal {
                        previousEndSec = e
                    }
                    let segment = TranscriptSegment(
                        recordingID: recordingID,
                        source: source,
                        startSec: s,
                        endSec: e,
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
            // analyzeSequence は inputSequence が finish するまで返らない。
            // feedTask が inputBuilder.finish() を呼んで初めて完了するため、
            // この行の後では feedTask は実質終了している。
            // ただし feedTask が throw した場合はその例外を再 throw する必要があるため、
            // 念のため .value で待機する (この時点で既に完了済み or 完了直前)。
            let lastSampleTime = try await analyzer.analyzeSequence(inputSequence)
            try await feedTask.value
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
    ///
    /// 注: 本来 private 相当だが、P4.3 converter cache + reset の回帰テスト
    /// (`SpeechAnalyzerConverterCacheTests`) から呼び出すため `internal` で公開している。
    static func feedAudioFile(
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

        // P4.3: AVAudioConverter / outBuffer / ConverterFeedState は **ループ外で 1 度だけ
        // 確保**し、各イテレーションで再利用する。
        //
        // 旧コードはイテレーションごとに converter / outBuffer / state を新規 alloc していた。
        // コメントには「endOfStream 後の状態リークを避けるため」とあったが、Apple の
        // AVAudioConverter は `reset()` を呼ぶことで内部状態（sample-rate conversion buffer,
        // DSP state）を破棄でき、新しい stream として再利用できる。これはまさにこのケースの
        // ための API。毎チャンク alloc は不要なコストで、バッテリー最小化方針と矛盾していた。
        //
        // 注意: 各 chunk 投入時に input block が `.endOfStream` を返すモデルは維持する
        //       （converter は chunk 単位で「flush」されて tail samples を吐き出す）。
        //       次の chunk の前に `converter.reset()` を呼ぶことで、内部の filter state を
        //       初期化し、過去 chunk の影響が漏れない新しい stream として扱う。

        let needsConversion = inputFormat != outputFormat
        let converter: AVAudioConverter?
        let outBuffer: AVAudioPCMBuffer?
        let feedState: ConverterFeedState?
        if needsConversion {
            guard let conv = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw TranscriptionError.analyzerFailed(
                    message: "AVAudioConverter init failed (\(inputFormat) -> \(outputFormat))"
                )
            }
            // 出力 capacity は **最大入力フレーム数** に基づいて確保。実際の出力は frameLength
            // で示されるので、capacity 過剰でも問題ない。
            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(readFrameCapacity) * ratio + 1024)
            guard let outBuf = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outCapacity
            ) else {
                throw TranscriptionError.analyzerFailed(message: "Failed to allocate output PCM buffer")
            }
            converter = conv
            outBuffer = outBuf
            feedState = ConverterFeedState(buffer: inputBuffer)
        } else {
            converter = nil
            outBuffer = nil
            feedState = nil
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
            if needsConversion, let converter, let outBuffer, let feedState {
                // 新しい chunk を「新しい stream」として扱うため、converter / state を reset。
                // reset() は internal sample-rate conversion buffer と DSP state を破棄して
                // 次の stream を受け付け可能にする（Apple AVAudioConverter doc）。
                converter.reset()
                feedState.reset()
                outBuffer.frameLength = 0

                var convError: NSError?
                let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
                    feedState.next(outStatus: outStatus)
                }
                if status == .error, let convError {
                    throw TranscriptionError.analyzerFailed(message: "AVAudioConverter error: \(convError)")
                }
                if outBuffer.frameLength == 0 {
                    continue
                }
                // outBuffer は再利用するため、Analyzer に渡す前に **コピー** する必要がある。
                // （analyzer は async で消費するので、次イテレーションで上書きされると壊れる）
                guard let copied = outBuffer.copy() as? AVAudioPCMBuffer else {
                    throw TranscriptionError.analyzerFailed(message: "Failed to copy output PCM buffer")
                }
                buffer = copied
            } else {
                buffer = inputBuffer.copy() as? AVAudioPCMBuffer ?? inputBuffer
            }

            inputBuilder.yield(AnalyzerInput(buffer: buffer))
        }
    }

    /// Live PCM buffers (録音中の AsyncStream) を targetFormat に変換しながら
    /// `AnalyzerInput` として yield する。
    ///
    /// `feedAudioFile` と同様の converter 戦略を使うが、入力 buffer はストリームから
    /// やってくるため、`ConverterFeedState.setBuffer` で各 chunk ごとに差し替える。
    ///
    /// 入力 stream が finish (= 録音停止) すると `for await` ループを抜けて return し、
    /// 呼び出し側が inputBuilder.finish() を発火する。
    static func feedLiveBuffers(
        buffers: AsyncStream<AVAudioPCMBuffer>,
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat?,
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    ) async throws {
        let outputFormat = targetFormat ?? inputFormat
        let needsConversion = inputFormat != outputFormat

        let converter: AVAudioConverter?
        let feedState: ConverterFeedState?
        var outBuffer: AVAudioPCMBuffer? = nil
        var outCapacity: AVAudioFrameCount = 0

        if needsConversion {
            guard let conv = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw TranscriptionError.analyzerFailed(
                    message: "AVAudioConverter init failed (\(inputFormat) -> \(outputFormat))"
                )
            }
            // feedState は dummy buffer で init し、chunk 受領時に setBuffer() で差し替える。
            guard let dummy = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 1) else {
                throw TranscriptionError.analyzerFailed(message: "Failed to allocate dummy PCM buffer")
            }
            converter = conv
            feedState = ConverterFeedState(buffer: dummy)
        } else {
            converter = nil
            feedState = nil
        }

        for await chunk in buffers {
            try Task.checkCancellation()
            guard chunk.frameLength > 0 else { continue }

            let outBuf: AVAudioPCMBuffer
            if needsConversion, let converter, let feedState {
                // outBuffer 容量を必要に応じて (再) 確保。録音中の chunk size は可変なので
                // 安全側に最大値で確保しておき、不足時のみ再 alloc する。
                let ratio = outputFormat.sampleRate / inputFormat.sampleRate
                let needed = AVAudioFrameCount(Double(chunk.frameLength) * ratio + 1024)
                if outBuffer == nil || outCapacity < needed {
                    guard let nb = AVAudioPCMBuffer(
                        pcmFormat: outputFormat,
                        frameCapacity: needed
                    ) else {
                        throw TranscriptionError.analyzerFailed(message: "Failed to allocate output PCM buffer")
                    }
                    outBuffer = nb
                    outCapacity = needed
                }
                guard let outBuf2 = outBuffer else { continue }

                // chunk ごとに「新しい stream」として扱う (feedAudioFile と同戦略)。
                converter.reset()
                feedState.setBuffer(chunk)
                outBuf2.frameLength = 0

                var convError: NSError?
                let status = converter.convert(to: outBuf2, error: &convError) { _, outStatus in
                    feedState.next(outStatus: outStatus)
                }
                if status == .error, let convError {
                    throw TranscriptionError.analyzerFailed(message: "AVAudioConverter error: \(convError)")
                }
                if outBuf2.frameLength == 0 { continue }
                guard let copied = outBuf2.copy() as? AVAudioPCMBuffer else {
                    throw TranscriptionError.analyzerFailed(message: "Failed to copy output PCM buffer")
                }
                outBuf = copied
            } else {
                // 変換不要だが live stream の buffer は他の consumer (writer, accumulator)
                // と共有/再利用される可能性があるため、ASR 用にコピーして渡す。
                guard let copied = chunk.copy() as? AVAudioPCMBuffer else { continue }
                outBuf = copied
            }
            inputBuilder.yield(AnalyzerInput(buffer: outBuf))
        }
    }
}

/// `AVAudioConverter.convert(to:error:withInputFrom:)` の入力ブロックに渡す状態。
/// チャンク 1 個ぶんを 1 度だけ供給し、2 回目の呼び出しで `.endOfStream` を返す
/// 「ワンショット供給」モード。
///
/// P4.3: converter を再利用するようにしたため、state も **同じインスタンスを reset() で
/// 再利用** する。各 chunk 開始前に `reset()` を呼んで `supplied` を初期化する。
/// `AsyncStream<AVAudioPCMBuffer>` を Task 境界をまたいで運ぶための箱。
///
/// `AVAudioPCMBuffer` は非 Sendable なため、`AsyncStream<AVAudioPCMBuffer>` も
/// 厳密には Sendable ではない。ただし本コードでは consumer Task が単独で stream を
/// 消費する (= データレースは発生しない) ため、`@unchecked Sendable` で渡す。
final class LiveBufferBox: @unchecked Sendable {
    let stream: AsyncStream<AVAudioPCMBuffer>
    init(stream: AsyncStream<AVAudioPCMBuffer>) {
        self.stream = stream
    }
}

/// `AsyncStream<AnalyzerInput>` 用の同等の箱。
final class LiveAnalyzerInputBox: @unchecked Sendable {
    let stream: AsyncStream<AnalyzerInput>
    init(stream: AsyncStream<AnalyzerInput>) {
        self.stream = stream
    }
}

final class ConverterFeedState: @unchecked Sendable {
    private var supplied = false
    private var buffer: AVAudioPCMBuffer

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    /// 次の chunk 用に「未供給」状態に戻す。
    func reset() {
        supplied = false
    }

    /// live モード用: chunk ごとに違う入力 buffer を供給したい場合に差し替える。
    /// reset() 相当も同時に行う。
    func setBuffer(_ buf: AVAudioPCMBuffer) {
        self.buffer = buf
        self.supplied = false
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
