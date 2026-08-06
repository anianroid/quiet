import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct GeneratedMeetingNotes {
    @Guide(description: "2-4 sentence overview of the meeting")
    var overview: String
    var decisions: [String]
    var actionItems: [String]
    var openQuestions: [String]
    @Guide(description: "Short 3-6 word meeting title")
    var title: String
}

@available(macOS 26.0, *)
@Generable
private struct MeetingSubstanceCheck {
    @Guide(description: "True when the transcript contains substantive discussion worth keeping; false for empty joins, mic checks, or stray fragments")
    var isSubstantive: Bool
}
#endif

@MainActor
final class NotesSummarizer {
    private let logger = Logger(subsystem: "notes.quiet.app", category: "NotesSummarizer")

    func summarize(transcript: String) async throws -> MeetingSummary {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return MeetingSummary(overview: "No speech detected.", decisions: [], actions: [], questions: [])
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                logger.info("Apple Intelligence unavailable; using transcript-only fallback summary")
                return fallbackSummary(from: trimmed, note: "Apple Intelligence is off")
            }
            do {
                return try await summarizeGuided(transcript: trimmed)
            } catch {
                logger.error("Guided generation failed, retrying with text prompt: \(error.localizedDescription, privacy: .public)")
            }
            do {
                return try await summarizeWithTextPrompt(transcript: trimmed)
            } catch {
                logger.error("Text-prompt summarization failed: \(error.localizedDescription, privacy: .public)")
                return fallbackSummary(from: trimmed, note: error.localizedDescription)
            }
        }
        #endif
        return fallbackSummary(from: trimmed, note: nil)
    }

    /// Cheap junk-meeting check: near-empty transcripts are junk, clearly long ones are
    /// substantive, and only the borderline middle asks the model. Never throws; any
    /// model failure defaults to true so real notes are never silently discarded.
    func isSubstantive(transcript: String) async -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = trimmed.split(whereSeparator: \.isWhitespace).count
        if wordCount < 40 { return false }
        if wordCount >= 200 { return true }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { return true }
            do {
                let session = LanguageModelSession()
                let prompt = """
                You are Quiet, a local meeting notes assistant. Decide whether this short transcript contains any substantive meeting content (discussion, decisions, plans) or is just noise like joining sounds, greetings, or mic checks.

                Transcript:
                \(trimmed.prefix(4_000))
                """
                let response = try await session.respond(to: prompt, generating: MeetingSubstanceCheck.self)
                return response.content.isSubstantive
            } catch {
                logger.error("Substance check failed, defaulting to substantive: \(error.localizedDescription, privacy: .public)")
                return true
            }
        }
        #endif
        return true
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func summarizeGuided(transcript: String) async throws -> MeetingSummary {
        let session = LanguageModelSession()
        let prompt = """
        You are Quiet, a local meeting notes assistant. From the transcript below, produce concise meeting notes. Leave decisions, action items, or open questions empty when the meeting had none.

        Transcript:
        \(transcript.prefix(12_000))
        """

        let response = try await session.respond(to: prompt, generating: GeneratedMeetingNotes.self)
        let notes = response.content
        var summary = MeetingSummary(
            overview: notes.overview.trimmingCharacters(in: .whitespacesAndNewlines),
            decisions: notes.decisions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            actions: notes.actionItems.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            questions: notes.openQuestions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        )
        let title = notes.title.trimmingCharacters(in: .whitespacesAndNewlines)
        summary.title = title.isEmpty ? nil : title
        return summary
    }

    @available(macOS 26.0, *)
    private func summarizeWithTextPrompt(transcript: String) async throws -> MeetingSummary {
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
    #endif

    /// Internal (not private) so unit tests can exercise the fallback parser.
    func parse(_ text: String) -> MeetingSummary {
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
