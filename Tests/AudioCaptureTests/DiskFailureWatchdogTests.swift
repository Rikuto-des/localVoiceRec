import Foundation
import Testing
import Contracts
@testable import AudioCapture

/// `AudioCaptureServiceImpl.handleDiskWriteFailure` の状態遷移検証。
///
/// 注: `active` の inject は `ActiveSession` 内に MicCapture / SystemAudioTap など
/// ハードウェア依存リソースが多数含まれており、テスト環境で組み立てるのが現実的でない。
/// そのためここでは **観測可能な早期 return 経路 (idle / failed 状態時の no-op)** と
/// **エラー型 mapping** を検証する。実際の "recording → failed" 遷移は、CI/sandbox 環境では
/// `withKnownIssue` でガードしつつ実機 (run-on-mac) で別途検証する想定。
@Suite("DiskFailureWatchdog — handleDiskWriteFailure")
struct DiskFailureWatchdogTests {

    @Test("idle で handleDiskWriteFailure を呼んでも状態は idle のまま (no-op)")
    func handleDiskWriteFailureFromIdleIsNoop() async {
        let svc = AudioCaptureServiceImpl()
        await svc.handleDiskWriteFailure(failureCount: 5)
        let state = await svc.currentState
        #expect(state == .idle, "active == nil なら遷移しない")
    }

    @Test("idle で複数回呼んでも state は idle のまま (冪等)")
    func handleDiskWriteFailureIdempotentFromIdle() async {
        let svc = AudioCaptureServiceImpl()
        for _ in 0..<3 {
            await svc.handleDiskWriteFailure(failureCount: Int.random(in: 1...100))
        }
        #expect(await svc.currentState == .idle)
    }

    @Test("AudioCaptureError.diskWriteFailure は failureCount を保持する (Hashable / Equatable)")
    func diskWriteFailureErrorCarriesCount() {
        let a = AudioCaptureError.diskWriteFailure(failureCount: 7)
        let b = AudioCaptureError.diskWriteFailure(failureCount: 7)
        let c = AudioCaptureError.diskWriteFailure(failureCount: 8)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("実録音から handleDiskWriteFailure を直接呼ぶと .failed(.diskWriteFailure) へ遷移する")
    func handleDiskWriteFailureTransitionsToFailed() async throws {
        // 実機環境で start() が成功する前提のテスト。
        // CI / sandbox では disabled。
        // start() 自体が HW 依存で throw する可能性があるため、その場合は
        // known issue としてスキップする (テスト失敗にしない)。
        let svc = AudioCaptureServiceImpl()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskWatchdog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var started = false
        do {
            _ = try await svc.start(in: tmpDir, title: "diskwd")
            started = true
        } catch {
            // CI / sandbox 環境ではマイク or process tap が初期化できないので skip。
            withKnownIssue(
                "AudioCaptureServiceImpl.start() failed in this environment (HW 依存)",
                isIntermittent: true
            ) {
                Issue.record("start() threw \(error) — テスト環境では HW を初期化できない")
            }
        }

        guard started else { return }

        await svc.handleDiskWriteFailure(failureCount: 42)
        let state = await svc.currentState
        switch state {
        case .failed(let err):
            #expect(err == .diskWriteFailure(failureCount: 42))
        default:
            Issue.record("Expected .failed(.diskWriteFailure), got \(state)")
        }
    }
}
