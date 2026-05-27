import Foundation
import Contracts
import TranscriptionKit
import SummaryKit

// MARK: - Helpers

func stderrPrintln(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}

func info(_ msg: String) { print("[E2EProbe] " + msg) }

func fail(_ msg: String) -> Never {
    stderrPrintln("[E2EProbe][error] " + msg)
    exit(1)
}

// PoC が書き出す WAV の場所
let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let micURL = cwd.appendingPathComponent("Tools/AudioTapPoC/output/mic.wav")
let sysURL = cwd.appendingPathComponent("Tools/AudioTapPoC/output/system.wav")

@main
struct E2EProbe {
    static func main() async {
        let fm = FileManager.default
        guard fm.fileExists(atPath: micURL.path), fm.fileExists(atPath: sysURL.path) else {
            fail("PoC output not found at \(micURL.path) / \(sysURL.path). Run `POC_DURATION=30 swift run AudioTapPoC` first.")
        }

        info("micURL = \(micURL.path)")
        info("sysURL = \(sysURL.path)")

        let now = Date()
        let recording = Recording(
            title: "E2E Probe",
            startedAt: now.addingTimeInterval(-30),
            endedAt: now,
            micAudioURL: micURL,
            systemAudioURL: sysURL
        )

        // --- 1. Transcribe ---
        let svc = SpeechAnalyzerService()
        let locales = await svc.installedLocales()
        info("installedLocales count = \(locales.count)")
        if locales.isEmpty {
            fail("No installed on-device locales. Install one via System Settings → Apple Intelligence first.")
        }

        let startTranscribe = Date()
        var segments: [TranscriptSegment] = []
        do {
            for try await seg in svc.transcribe(recording: recording, locale: nil) {
                segments.append(seg)
                let src = seg.source.rawValue
                let sStr = String(format: "%.3f", seg.startSec)
                let eStr = String(format: "%.3f", seg.endSec)
                info("[\(src)] \(sStr)-\(eStr) (isFinal=\(seg.isFinal)): \(seg.text)")
            }
        } catch {
            fail("Transcribe failed: \(error)")
        }
        let transcribeElapsed = Date().timeIntervalSince(startTranscribe)
        info("Transcribe finished in \(String(format: "%.3f", transcribeElapsed)) s, segments = \(segments.count)")

        let micCount = segments.filter { $0.source == .mic && $0.isFinal }.count
        let sysCount = segments.filter { $0.source == .system && $0.isFinal }.count
        info("final segments: mic=\(micCount) system=\(sysCount)")

        // --- 2. Summarize ---
        let summary = FoundationModelsSummaryService()
        let avail = await summary.availability()
        info("Summary availability = \(avail)")
        switch avail {
        case .available:
            break
        case .unavailable(let r):
            info("Skipping summary (unavailable: \(r))")
            return
        }

        let finalSegments = segments.filter { $0.isFinal }
        if finalSegments.isEmpty {
            info("No final segments — skipping summary generation.")
            return
        }

        let startSummary = Date()
        do {
            let doc = try await summary.generate(from: finalSegments, recordingID: recording.id)
            let elapsed = Date().timeIntervalSince(startSummary)
            info("Summary generated in \(String(format: "%.3f", elapsed)) s")
            info("--- Overview ---")
            print(doc.overview)
            info("--- Decisions (\(doc.decisions.count)) ---")
            doc.decisions.forEach { print(" - \($0)") }
            info("--- Action Items (\(doc.actionItems.count)) ---")
            doc.actionItems.forEach { ai in
                let assignee = ai.assignee ?? "-"
                let due = ai.dueDate.map { "\($0)" } ?? "-"
                print(" - \(ai.title) [assignee=\(assignee), due=\(due)]")
            }
            info("--- Open Questions (\(doc.openQuestions.count)) ---")
            doc.openQuestions.forEach { print(" - \($0)") }
            info("--- Review Items (\(doc.reviewItems.count)) ---")
            doc.reviewItems.forEach { print(" - \($0)") }
        } catch {
            fail("Summary failed: \(error)")
        }
    }
}
