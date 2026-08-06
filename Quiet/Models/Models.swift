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
    /// True for host apps that pop meeting pills but must never be quit or
    /// suspended (the user's workspace, a dictation tool) — only their
    /// pill-sized floating windows are suppressed during meetings.
    var popsMeetingPills: Bool? = nil
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

/// Which side of the call a transcript segment came from.
/// System audio is everyone else on the call; the mic is the user.
enum TranscriptSource: String, Codable, Sendable {
    case system
    case mic

    /// Speaker prefix used when rendering the transcript.
    var speakerLabel: String {
        switch self {
        case .system: return "Them"
        case .mic: return "Me"
        }
    }
}

struct TranscriptSegment: Identifiable, Hashable, Sendable {
    let id = UUID()
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let isFinal: Bool
    let source: TranscriptSource
}

struct MeetingSummary: Hashable, Sendable {
    var overview: String
    var decisions: [String]
    var actions: [String]
    var questions: [String]
    /// Short model-generated meeting title; nil when Apple Intelligence is unavailable.
    var title: String? = nil
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
