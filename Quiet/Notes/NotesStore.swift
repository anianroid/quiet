import Foundation

/// Writes meeting notes to `~/Documents/Quiet`. Notes land in a hidden
/// `.pending/<session>/` staging folder first; the post-call Keep/Discard
/// prompt then promotes them into the visible root or deletes them.
struct NotesStore: Sendable {
    private var rootURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs.appendingPathComponent("Quiet", isDirectory: true)
    }

    private var pendingRootURL: URL {
        rootURL.appendingPathComponent(".pending", isDirectory: true)
    }

    /// Stages notes for the Keep/Discard prompt. A nil summary means
    /// summarization failed — the raw transcript is still staged.
    /// Returns the staged Notes.md URL.
    func writePending(session: MeetingSession, transcript: String, summary: MeetingSummary?) throws -> URL {
        let folder = pendingFolder(for: session.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let notesURL = folder.appendingPathComponent("Notes.md")
        let transcriptURL = folder.appendingPathComponent("Transcript.md")

        let notes = renderNotes(session: session, summary: summary)
        try notes.write(to: notesURL, atomically: true, encoding: .utf8)
        try ("# Transcript\n\n" + transcript).write(to: transcriptURL, atomically: true, encoding: .utf8)
        return notesURL
    }

    /// Keep: moves the staged folder into the visible notes root, named
    /// "yyyy-MM-dd <title>" when the summary produced a title, falling back to
    /// the timestamp+source naming otherwise. Returns the final Notes.md URL.
    func keep(session: MeetingSession) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let destination = uniqueDestination(named: folderName(for: session))
        try fm.moveItem(at: pendingFolder(for: session.id), to: destination)
        return destination.appendingPathComponent("Notes.md")
    }

    /// Discard: deletes the staged folder. Nothing persists.
    func discardPending(sessionID: UUID) {
        try? FileManager.default.removeItem(at: pendingFolder(for: sessionID))
    }

    private func pendingFolder(for sessionID: UUID) -> URL {
        pendingRootURL.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    private func folderName(for session: MeetingSession) -> String {
        let formatter = DateFormatter()
        if let title = session.summary?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            formatter.dateFormat = "yyyy-MM-dd"
            let safeTitle = title
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            return formatter.string(from: session.startedAt) + " " + safeTitle
        }
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: session.startedAt) + "-" + session.sourceApp
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    /// Two meetings can share a day and a title ("Standup"); suffix until free.
    private func uniqueDestination(named name: String) -> URL {
        let fm = FileManager.default
        var candidate = rootURL.appendingPathComponent(name, isDirectory: true)
        var attempt = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = rootURL.appendingPathComponent("\(name) \(attempt)", isDirectory: true)
            attempt += 1
        }
        return candidate
    }

    private func renderNotes(session: MeetingSession, summary: MeetingSummary?) -> String {
        var lines: [String] = [
            "# Quiet notes",
            "",
            "- Started: \(session.startedAt.formatted())",
            "- Source: \(session.sourceApp)",
            ""
        ]

        if !session.hijackLog.isEmpty {
            lines.append("## Silenced this session")
            for action in session.hijackLog {
                lines.append("- \(action.competitorName): \(action.action)")
            }
            lines.append("")
        }

        lines.append("## Summary")
        guard let summary else {
            lines.append("Summary unavailable — transcript saved.")
            lines.append("")
            lines.append("_Generated on-device by Quiet. Audio never left this Mac._")
            return lines.joined(separator: "\n")
        }
        lines.append(summary.overview)
        lines.append("")

        lines.append("## Decisions")
        if summary.decisions.isEmpty {
            lines.append("- None captured")
        } else {
            summary.decisions.forEach { lines.append("- \($0)") }
        }
        lines.append("")

        lines.append("## Action items")
        if summary.actions.isEmpty {
            lines.append("- None captured")
        } else {
            summary.actions.forEach { lines.append("- \($0)") }
        }
        lines.append("")

        lines.append("## Open questions")
        if summary.questions.isEmpty {
            lines.append("- None captured")
        } else {
            summary.questions.forEach { lines.append("- \($0)") }
        }
        lines.append("")
        lines.append("_Generated on-device by Quiet. Audio never left this Mac._")
        return lines.joined(separator: "\n")
    }
}
