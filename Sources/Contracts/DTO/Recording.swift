import Foundation

/// 1 回分の会議録音。マイクとシステム音声の 2 ファイルを参照する。
///
/// このまま UI に渡せる値型。SwiftData @Model とは別物で、DataStore 層が変換する。
public struct Recording: Sendable, Identifiable, Hashable, Codable {
    public let id: UUID
    public let title: String
    public let startedAt: Date
    public let endedAt: Date
    public let micAudioURL: URL
    public let systemAudioURL: URL
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date,
        endedAt: Date,
        micAudioURL: URL,
        systemAudioURL: URL,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.micAudioURL = micAudioURL
        self.systemAudioURL = systemAudioURL
        self.createdAt = createdAt
    }

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}
