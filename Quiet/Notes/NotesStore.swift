import Foundation

struct NotesStore: Sendable {
    private var rootURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs.appendingPathComponent("Quiet", isDirectory: true)
    }

    func write(session: MeetingSession, transcript: String, summary: MeetingSummary) throws -> URL {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let folderName = formatter.string(from: session.startedAt) + "-" + session.sourceApp
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let folder = rootURL.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let notesURL = folder.appendingPathComponent("Notes.md")
        let transcriptURL = folder.appendingPathComponent("Transcript.md")

        let notes = renderNotes(session: session, summary: summary)
        try notes.write(to: notesURL, atomically: true, encoding: .utf8)
        try ("# Transcript\n\n" + transcript).write(to: transcriptURL, atomically: true, encoding: .utf8)
        return notesURL
    }

    private func renderNotes(session: MeetingSession, summary: MeetingSummary) -> String {
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
