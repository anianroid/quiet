import Testing

// The text-prompt fallback parser: structured OVERVIEW/DECISIONS/ACTIONS/
// QUESTIONS extraction, with a raw-prefix fallback for unstructured output.
@MainActor
struct NotesSummarizerTests {
    @Test func parsesStructuredResponse() {
        let text = """
        OVERVIEW:
        We discussed the Q3 roadmap.
        Ship dates were agreed.

        DECISIONS:
        - Ship v0.1 on Friday
        - None

        ACTIONS:
        - Ani to write tests
        - Priya to update the deck

        QUESTIONS:
        - None
        """
        let summary = NotesSummarizer().parse(text)
        #expect(summary.overview == "We discussed the Q3 roadmap. Ship dates were agreed.")
        #expect(summary.decisions == ["Ship v0.1 on Friday"])
        #expect(summary.actions == ["Ani to write tests", "Priya to update the deck"])
        #expect(summary.questions.isEmpty)
        #expect(summary.title == nil)
    }

    @Test func noneBulletsAreFilteredCaseInsensitively() {
        let text = """
        OVERVIEW:
        Short sync.

        DECISIONS:
        - NONE

        ACTIONS:
        - none

        QUESTIONS:
        - What about pricing?
        """
        let summary = NotesSummarizer().parse(text)
        #expect(summary.decisions.isEmpty)
        #expect(summary.actions.isEmpty)
        #expect(summary.questions == ["What about pricing?"])
    }

    @Test func fallsBackToRawPrefixWhenUnstructured() {
        let text = "The model refused to follow the format entirely."
        let summary = NotesSummarizer().parse(text)
        #expect(summary.overview == text)
        #expect(summary.decisions.isEmpty)
        #expect(summary.actions.isEmpty)
        #expect(summary.questions.isEmpty)
    }

    @Test func unstructuredFallbackIsCappedAt400Characters() {
        let text = String(repeating: "a", count: 1_000)
        let summary = NotesSummarizer().parse(text)
        #expect(summary.overview.count == 400)
    }
}
