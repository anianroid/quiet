import Foundation

enum CompetitorPolicy: String, Codable, Sendable {
    case suspendDuringMeeting
    case quitOnQuietLaunch
    case ignore
}

struct CompetitorEntry: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let bundleIds: [String]
    let helperProcessNames: [String]
    let appNameHints: [String]
    let notificationTitlePatterns: [String]
    let notificationBodyPatterns: [String]
    let policy: CompetitorPolicy
}

struct InstalledCompetitor: Identifiable, Hashable, Sendable {
    var id: String { entry.id }
    let entry: CompetitorEntry
    let matchedBundleId: String?
    let matchedAppPath: String?
    let isRunning: Bool

    var displayDetail: String {
        if let matchedAppPath {
            return URL(fileURLWithPath: matchedAppPath).lastPathComponent
        }
        if let matchedBundleId {
            return matchedBundleId
        }
        return isRunning ? "Running helper" : "Detected"
    }
}

struct HijackAction: Identifiable, Hashable, Sendable {
    let id = UUID()
    let competitorName: String
    let action: String
    let at: Date
}

struct TranscriptSegment: Identifiable, Hashable, Sendable {
    let id = UUID()
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let isFinal: Bool
}

struct MeetingSummary: Hashable, Sendable {
    var overview: String
    var decisions: [String]
    var actions: [String]
    var questions: [String]
}

struct MeetingSession: Identifiable, Hashable, Sendable {
    let id: UUID
    var startedAt: Date
    var endedAt: Date?
    var sourceApp: String
    var hijackLog: [HijackAction]
    var transcriptSegments: [TranscriptSegment]
    var summary: MeetingSummary?
    var notesPath: URL?
}
