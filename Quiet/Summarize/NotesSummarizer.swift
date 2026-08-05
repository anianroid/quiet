import Foundation
import FoundationModels

@MainActor
final class NotesSummarizer {
    func summarize(transcript: String) async throws -> MeetingSummary {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return MeetingSummary(overview: "No speech detected.", decisions: [], actions: [], questions: [])
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                return try await summarizeWithFoundationModels(transcript: trimmed)
            } catch {
                return fallbackSummary(from: trimmed, note: error.localizedDescription)
            }
        }
        #endif
        return fallbackSummary(from: trimmed, note: nil)
    }

    @available(macOS 26.0, *)
    private func summarizeWithFoundationModels(transcript: String) async throws -> MeetingSummary {
        let session = LanguageModelSession()
        let prompt = """
        You are Quiet, a local meeting notes assistant. From the transcript below, produce concise meeting notes.

        Return exactly this structure:
        OVERVIEW:
        <2-4 sentences>

        DECISIONS:
        - <decision or "None">

        ACTIONS:
        - <action item or "None">

        QUESTIONS:
        - <open question or "None">

        Transcript:
        \(transcript.prefix(12_000))
        """

        let response = try await session.respond(to: prompt)
        return parse(response.content)
    }

    private func parse(_ text: String) -> MeetingSummary {
        func section(_ name: String) -> String {
            let pattern = "\(name):\\s*([\\s\\S]*?)(?=\\n[A-Z]+:|$)"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return "" }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range),
                  let r = Range(match.range(at: 1), in: text) else { return "" }
            return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func bullets(_ body: String) -> [String] {
            body
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .map { line in
                    var s = line
                    if s.hasPrefix("-") { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
                    return s
                }
                .filter { !$0.isEmpty && $0.lowercased() != "none" }
        }

        let overview = section("OVERVIEW").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingSummary(
            overview: overview.isEmpty ? String(text.prefix(400)) : overview,
            decisions: bullets(section("DECISIONS")),
            actions: bullets(section("ACTIONS")),
            questions: bullets(section("QUESTIONS"))
        )
    }

    private func fallbackSummary(from transcript: String, note: String?) -> MeetingSummary {
        let preview = String(transcript.prefix(500))
        let overview = note.map { "Transcript captured. On-device summary unavailable (\($0)). Preview: \(preview)" }
            ?? "Transcript captured. Preview: \(preview)"
        return MeetingSummary(overview: overview, decisions: [], actions: [], questions: [])
    }
}
