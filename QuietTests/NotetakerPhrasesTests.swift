import Testing

// Suppression is behavior-based, never a list of app bundle ids: an app earns
// suppression by popping prompt copy, whoever it is. These cases are drawn from
// real pills seen in the field.
struct NotetakerPhrasesTests {
    @Test func realWorldPillCopyIsRecognized() {
        // Notion's in-app pill (no vendor word in the actionable line).
        #expect(NotetakerPhrases.containsStrong("Start AI Meeting Note Transcribing opens Notion Start transcribing"))
        // Wispr Flow — a dictation app, not a notetaker, that grew a pill.
        #expect(NotetakerPhrases.containsStrong("Meeting detected Now Start Notetaker"))
        #expect(NotetakerPhrases.containsStrong("AI Meeting Note"))
        // "Start Wispr" is vendor copy — it lives in Competitors.json, not
        // here, and is covered by NotificationWatcherTests.
        #expect(!NotetakerPhrases.containsStrong("Start Wispr Notetaker"))
        // Zoom via Chrome: carries no vendor name at all.
        #expect(NotetakerPhrases.containsStrong("Note-taking is available Chrome"))
    }

    @Test func ambiguousCopyIsNotStrongOnItsOwn() {
        // These need a vendor marker before anything is dismissed.
        #expect(!NotetakerPhrases.containsStrong("Meeting notes"))
        #expect(!NotetakerPhrases.containsStrong("Take notes"))
        #expect(NotetakerPhrases.containsWeak("Meeting notes"))
        #expect(NotetakerPhrases.containsWeak("Take notes"))
    }

    @Test func ordinaryWindowTextIsNeverSuppressed() {
        for text in [
            "Duet Summer of Tokens",
            "Aug 2 – 8, 2026 · Notion Calendar",
            "Your meeting's ready",
            "Recording indicator",
            "Standup notes for tomorrow"
        ] {
            #expect(!NotetakerPhrases.containsStrong(text), "must not match: \(text)")
        }
    }
}
