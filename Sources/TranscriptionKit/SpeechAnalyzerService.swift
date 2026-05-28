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

    private static let logger = Logger(subsystem: AppIdentifiers.logSubsystem, category: "transcription")

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

    /// 進行中の解析 Task。`cleanup` 時に破棄する。
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    /// 進行中の analyzer。`cleanup` 時に破棄する。
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

    /// `run` の前段で実行する事前検査の結果。
    private struct RunPreflight {
        let resolvedLocale: Locale
        let micTranscriber: SpeechTranscriber
        let systemTranscriber: SpeechTranscriber
    }

    /// locale 解決 + ファイル存在チェック + transcriber 構築 + asset 確保 をまとめる。
    /// 失敗時は continuation を finish して nil を返す。
    private static func preflight(
        recording: Recording,
        locale: Locale?,
        continuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation
    ) async -> RunPreflight? {
        // 1) ロケール解決
        let baseLocale = locale ?? Locale.current
        guard let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: baseLocale) else {
            continuation.finish(throwing: TranscriptionError.unsupportedLocale(identifier: baseLocale.identifier))
            return nil
        }

        // 2) ファイル存在チェック（早期に上げる）
        let fm = FileManager.default
        if !fm.fileExists(atPath: recording.micAudioURL.path) {
            continuation.finish(throwing: TranscriptionError.fileNotReadable(recording.micAudioURL))
            return nil
        }
        if !fm.fileExists(atPath: recording.systemAudioURL.path) {
            continuation.finish(throwing: TranscriptionError.fileNotReadable(recording.systemAudioURL))
            return nil
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
            return nil
        }

        return RunPreflight(
            resolvedLocale: resolvedLocale,
            micTranscriber: micTranscriber,
            systemTranscriber: systemTranscriber
        )
    }

    /// 2 ファイル分の解析を並列で起動し、結果を outer continuation に流す。
    private func run(
        recording: Recording,
        locale: Locale?,
        continuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation
    ) async {
        let runID = UUID()

        guard let pre = await Self.preflight(
            recording: recording,
            locale: locale,
            continuation: continuation
        ) else { return }

        // 5) ベスト format
        let micAudioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [pre.micTranscriber])
        let systemAudioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [pre.systemTranscriber])

        // 6) 2 本の analyzer
        let micAnalyzer = SpeechAnalyzer(modules: [pre.micTranscriber])
        let systemAnalyzer = SpeechAnalyzer(modules: [pre.systemTranscriber])

        let micRunID = UUID()
        let systemRunID = UUID()
        activeAnalyzers[micRunID] = micAnalyzer
        activeAnalyzers[systemRunID] = systemAnalyzer

        let recordingID = recording.id

        // 7) 並列実行
        let driver = Task { [weak self] in
            do {
                try await Self.runBothChannels(
                    recording: recording,
                    recordingID: recordingID,
                    micTranscriber: pre.micTranscriber,
                    systemTranscriber: pre.systemTranscriber,
                    micAnalyzer: micAnalyzer,
                    systemAnalyzer: systemAnalyzer,
                    micAudioFormat: micAudioFormat,
                    systemAudioFormat: systemAudioFormat,
                    continuation: continuation
                )
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

    /// mic / system の `process` を並列起動して両方の完了を待つ。
    private static func runBothChannels(
        recording: Recording,
        recordingID: UUID,
        micTranscriber: SpeechTranscriber,
        systemTranscriber: SpeechTranscriber,
        micAnalyzer: SpeechAnalyzer,
        systemAnalyzer: SpeechAnalyzer,
        micAudioFormat: AVAudioFormat?,
        systemAudioFormat: AVAudioFormat?,
        continuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await process(
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
                try await process(
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
        let audioFile = try openAudioFile(url: url)

        // 入力 sequence
        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)

        // 結果消費 Task
        let resultsTask = makeResultsConsumerTask(
            transcriber: transcriber,
            recordingID: recordingID,
            source: source,
            continuation: continuation
        )

        // PCM 投入 Task
        let feedTask = makeFeedTask(
            audioFile: audioFile,
            targetFormat: audioFormat,
            inputBuilder: inputBuilder
        )

        // analyzer を回す
        do {
            try await runAnalyzer(
                analyzer: analyzer,
                inputSequence: inputSequence,
                feedTask: feedTask,
                resultsTask: resultsTask
            )
        } catch is CancellationError {
            await cancelAll(analyzer: analyzer, feedTask: feedTask, resultsTask: resultsTask)
            throw TranscriptionError.cancelled
        } catch let e as TranscriptionError {
            await cancelAll(analyzer: analyzer, feedTask: feedTask, resultsTask: resultsTask)
            throw e
        } catch {
            await cancelAll(analyzer: analyzer, feedTask: feedTask, resultsTask: resultsTask)
            throw TranscriptionError.analyzerFailed(message: String(describing: error))
        }
    }

    /// `AVAudioFile(forReading:)` を `TranscriptionError` に包んで開く。
    private static func openAudioFile(url: URL) throws -> AVAudioFile {
        do {
            return try AVAudioFile(forReading: url)
        } catch {
            throw TranscriptionError.analyzerFailed(message: "AVAudioFile open failed for \(url.lastPathComponent): \(error)")
        }
    }

    /// `transcriber.results` を消費して outer continuation に yield する Task を作る。
    private static func makeResultsConsumerTask(
        transcriber: SpeechTranscriber,
        recordingID: UUID,
        source: TranscriptSegment.Source,
        continuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation
    ) -> Task<Void, Error> {
        Task<Void, Error> {
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
    }

    /// PCM を変換しつつ analyzer に流し込む Task を作る。
    private static func makeFeedTask(
        audioFile: AVAudioFile,
        targetFormat: AVAudioFormat?,
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    ) -> Task<Void, Error> {
        Task<Void, Error> {
            defer { inputBuilder.finish() }
            try feedAudioFile(
                audioFile: audioFile,
                targetFormat: targetFormat,
                inputBuilder: inputBuilder
            )
        }
    }

    /// analyzer.analyzeSequence → feedTask.value → finalize → resultsTask.value の一連を実行する。
    private static func runAnalyzer(
        analyzer: SpeechAnalyzer,
        inputSequence: AsyncStream<AnalyzerInput>,
        feedTask: Task<Void, Error>,
        resultsTask: Task<Void, Error>
    ) async throws {
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
    }

    /// analyzer + 各 Task をまとめてキャンセルする。
    private static func cancelAll(
        analyzer: SpeechAnalyzer,
        feedTask: Task<Void, Error>,
        resultsTask: Task<Void, Error>
    ) async {
        await analyzer.cancelAndFinishNow()
        feedTask.cancel()
        resultsTask.cancel()
    }

    // MARK: - Audio feeding

    /// `feedAudioFile` 内部で使う converter / 出力 buffer / feed state の組。
    /// `needsConversion == false` の場合は全て nil。
    private struct ConverterContext {
        let needsConversion: Bool
        let converter: AVAudioConverter?
        let outBuffer: AVAudioPCMBuffer?
        let feedState: ConverterFeedState?
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

        let ctx = try makeConverterContext(
            inputFormat: inputFormat,
            outputFormat: outputFormat,
            readFrameCapacity: readFrameCapacity,
            inputBuffer: inputBuffer
        )

        while true {
            try Task.checkCancellation()

            // 残量を計算。AVAudioFile.read(into:) は最終 partial read で
            // nilError を返すことがあるため、残量に合わせて frameCount を明示する。
            guard try readNextChunk(
                audioFile: audioFile,
                inputBuffer: inputBuffer,
                readFrameCapacity: readFrameCapacity
            ) else {
                break  // EOF
            }

            // 変換 (or 同 format パススルー) してから yield
            if let converted = try convertChunk(inputBuffer: inputBuffer, context: ctx) {
                inputBuilder.yield(AnalyzerInput(buffer: converted))
            }
        }
    }

    /// converter / 出力 buffer / feed state をループ前に 1 度だけ確保する。
    ///
    /// P4.3: AVAudioConverter / outBuffer / ConverterFeedState は **ループ外で 1 度だけ
    /// 確保**し、各イテレーションで再利用する。
    ///
    /// 旧コードはイテレーションごとに converter / outBuffer / state を新規 alloc していた。
    /// コメントには「endOfStream 後の状態リークを避けるため」とあったが、Apple の
    /// AVAudioConverter は `reset()` を呼ぶことで内部状態（sample-rate conversion buffer,
    /// DSP state）を破棄でき、新しい stream として再利用できる。これはまさにこのケースの
    /// ための API。毎チャンク alloc は不要なコストで、バッテリー最小化方針と矛盾していた。
    ///
    /// 注意: 各 chunk 投入時に input block が `.endOfStream` を返すモデルは維持する
    ///       （converter は chunk 単位で「flush」されて tail samples を吐き出す）。
    ///       次の chunk の前に `converter.reset()` を呼ぶことで、内部の filter state を
    ///       初期化し、過去 chunk の影響が漏れない新しい stream として扱う。
    private static func makeConverterContext(
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        readFrameCapacity: AVAudioFrameCount,
        inputBuffer: AVAudioPCMBuffer
    ) throws -> ConverterContext {
        let needsConversion = inputFormat != outputFormat
        guard needsConversion else {
            return ConverterContext(needsConversion: false, converter: nil, outBuffer: nil, feedState: nil)
        }
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
        return ConverterContext(
            needsConversion: true,
            converter: conv,
            outBuffer: outBuf,
            feedState: ConverterFeedState(buffer: inputBuffer)
        )
    }

    /// 次の chunk を `inputBuffer` に読み込む。EOF なら `false` を返してループを抜けさせる。
    private static func readNextChunk(
        audioFile: AVAudioFile,
        inputBuffer: AVAudioPCMBuffer,
        readFrameCapacity: AVAudioFrameCount
    ) throws -> Bool {
        let remaining = audioFile.length - audioFile.framePosition
        if remaining <= 0 {
            return false  // 正常 EOF
        }
        let toRead = AVAudioFrameCount(min(Int64(readFrameCapacity), remaining))

        inputBuffer.frameLength = 0
        do {
            try audioFile.read(into: inputBuffer, frameCount: toRead)
        } catch {
            throw TranscriptionError.analyzerFailed(message: "AVAudioFile.read failed for \(audioFile.url.lastPathComponent) at \(audioFile.framePosition)/\(audioFile.length): \(error)")
        }
        if inputBuffer.frameLength == 0 {
            return false  // EOF (念のため)
        }
        return true
    }

    /// 1 chunk を変換 (or パススルー) してコピーされた buffer を返す。
    /// converter が 0 フレームを吐いた場合は `nil` を返す (= スキップ)。
    private static func convertChunk(
        inputBuffer: AVAudioPCMBuffer,
        context ctx: ConverterContext
    ) throws -> AVAudioPCMBuffer? {
        if ctx.needsConversion,
           let converter = ctx.converter,
           let outBuffer = ctx.outBuffer,
           let feedState = ctx.feedState {
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
                return nil
            }
            // outBuffer は再利用するため、Analyzer に渡す前に **コピー** する必要がある。
            // （analyzer は async で消費するので、次イテレーションで上書きされると壊れる）
            guard let copied = outBuffer.copy() as? AVAudioPCMBuffer else {
                throw TranscriptionError.analyzerFailed(message: "Failed to copy output PCM buffer")
            }
            return copied
        } else {
            return inputBuffer.copy() as? AVAudioPCMBuffer ?? inputBuffer
        }
    }
}

/// `AVAudioConverter.convert(to:error:withInputFrom:)` の入力ブロックに渡す状態。
/// チャンク 1 個ぶんを 1 度だけ供給し、2 回目の呼び出しで `.endOfStream` を返す
/// 「ワンショット供給」モード。
///
/// P4.3: converter を再利用するようにしたため、state も **同じインスタンスを reset() で
/// 再利用** する。各 chunk 開始前に `reset()` を呼んで `supplied` を初期化する。
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
