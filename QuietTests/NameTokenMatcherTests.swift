import Testing

// Whole-word token matching — the guard against "Spotter" dying for
// sharing letters with "Otter".
struct NameTokenMatcherTests {
    @Test func spotterNeverMatchesOtter() {
        #expect(!NameTokenMatcher.name("Spotter", matchesHint: "Otter"))
        #expect(!NameTokenMatcher.name("Spotter Helper", matchesAnyOf: ["Otter"]))
        #expect(!NameTokenMatcher.name("Plotter", matchesHint: "Otter"))
    }

    @Test func granolaHelperRendererMatchesGranola() {
        #expect(NameTokenMatcher.name("Granola Helper (Renderer)", matchesHint: "Granola"))
        #expect(NameTokenMatcher.name("Granola Helper (GPU)", matchesAnyOf: ["Granola"]))
    }

    @Test func multiTokenHintsRequireOrderedSubsequence() {
        #expect(NameTokenMatcher.name("Read AI Helper", matchesHint: "Read AI"))
        #expect(!NameTokenMatcher.name("AI Read", matchesHint: "Read AI"))
    }

    @Test func tokensAreLowercasedLetterRuns() {
        #expect(NameTokenMatcher.tokens(of: "Granola Helper (Renderer)") == ["granola", "helper", "renderer"])
        #expect(NameTokenMatcher.tokens(of: "tl;dv") == ["tl", "dv"])
    }

    @Test func emptyHintNeverMatches() {
        #expect(!NameTokenMatcher.name("Otter", matchesHint: ""))
        #expect(!NameTokenMatcher.name("Otter", matchesAnyOf: []))
        #expect(!NameTokenMatcher.name("Otter", matchesAnyOf: ["  ", "()"]))
    }

    @Test func matchIsCaseInsensitive() {
        #expect(NameTokenMatcher.name("OTTER.AI", matchesHint: "otter"))
    }
}

// The kill switch must never fire on meeting hosts, browsers, or dictation.
struct ProtectedNameTests {
    private let controller = ProcessController(catalog: CompetitorCatalog(entries: []))

    @Test func hostsBrowsersAndSettingsAreProtected() {
        let protected = [
            "zoom.us", "Google Chrome", "Safari", "Microsoft Edge",
            "Brave Browser", "Arc", "Firefox", "Microsoft Teams",
            "System Settings", "System Preferences", "Wispr Flow", "Webex"
        ]
        for name in protected {
            #expect(controller.isProtectedName(name), "\(name) must be protected")
        }
    }

    @Test func competitorNotetakersAreNotProtected() {
        let killable = ["Otter", "Granola", "Granola Helper (Renderer)", "Fireflies", "Fathom", "tl;dv"]
        for name in killable {
            #expect(!controller.isProtectedName(name), "\(name) must not be protected")
        }
    }
}
