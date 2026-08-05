import Testing

// Layer B dismissal rule: strong phrases ("Note-taking is available",
// "Start Notetaker"…) only ever appear in notetaker prompts and dismiss on
// their own — Zoom's web banner carries no vendor word at all. Weak phrases
// ("Take notes", "Meeting notes") need a vendor marker too, so a user's own
// "Meeting notes" reminder is never eaten.
@MainActor
struct NotificationWatcherTests {
    private static func makeWatcher() -> NotificationWatcher {
        let otter = CompetitorEntry(
            id: "otter",
            name: "Otter",
            bundleIds: ["com.otter.mac"],
            helperProcessNames: [],
            appNameHints: ["Otter"],
            // "Meeting detected" is all generic tokens — the watcher must
            // discard it as a vendor marker.
            notificationTitlePatterns: ["Otter", "Meeting detected"],
            notificationBodyPatterns: [],
            policy: .suspendDuringMeeting
        )
        return NotificationWatcher(catalog: CompetitorCatalog(entries: [otter]))
    }

    @Test func weakPhraseAloneIsNeverDismissed() {
        let watcher = Self.makeWatcher()
        #expect(!watcher.isNotetakerPrompt("Meeting notes"))
        #expect(!watcher.isNotetakerPrompt("Meeting notes — Standup at 10am"))
        #expect(!watcher.isNotetakerPrompt("Take notes now"))
    }

    @Test func strongPhraseAloneIsDismissed() {
        let watcher = Self.makeWatcher()
        // Zoom's web banner via Chrome: no vendor word anywhere in the text.
        #expect(watcher.isNotetakerPrompt("Note-taking is available Chrome"))
        #expect(watcher.isNotetakerPrompt("Meeting detected"))
        #expect(watcher.isNotetakerPrompt("Start Notetaker"))
    }

    @Test func vendorMarkerAloneIsNeverDismissed() {
        let watcher = Self.makeWatcher()
        #expect(!watcher.isNotetakerPrompt("Otter needs an update"))
        #expect(!watcher.isNotetakerPrompt("Granola 2.0 is out"))
    }

    @Test func vendorPlusGenericPhraseIsDismissed() {
        let watcher = Self.makeWatcher()
        #expect(watcher.isNotetakerPrompt("Otter — Meeting detected. Start Notetaker?"))
        #expect(watcher.isNotetakerPrompt("Granola Meeting detected"))
        #expect(watcher.isNotetakerPrompt("Take notes with Fireflies"))
        #expect(watcher.isNotetakerPrompt("Fathom — Notetaker is ready"))
    }

    @Test func builtinVendorsSurviveAnEmptyCatalog() {
        let watcher = NotificationWatcher(catalog: CompetitorCatalog(entries: []))
        #expect(watcher.isNotetakerPrompt("Otter — Meeting detected"))
        #expect(!watcher.isNotetakerPrompt("Meeting notes"))
    }

    @Test func spotterIsNotOtterInBannerText() {
        let watcher = Self.makeWatcher()
        // Weak phrase + near-miss vendor name: token matching must not fire.
        #expect(!watcher.isNotetakerPrompt("Spotter — Take notes"))
    }

    // Read AI ships a bare "Read" title pattern — a common English word that
    // must never become a vendor marker, while "Read AI" itself still matches.
    @Test func bareReadPatternCarriesNoVendorIdentity() {
        let readAI = CompetitorEntry(
            id: "read-ai",
            name: "Read AI",
            bundleIds: [],
            helperProcessNames: [],
            appNameHints: ["Read AI"],
            notificationTitlePatterns: ["Meeting detected", "Read"],
            notificationBodyPatterns: [],
            policy: .suspendDuringMeeting
        )
        let watcher = NotificationWatcher(catalog: CompetitorCatalog(entries: [readAI]))
        #expect(!watcher.isNotetakerPrompt("Can you read the meeting notes from yesterday?"))
        #expect(!watcher.isNotetakerPrompt("Take notes and read the brief"))
        #expect(watcher.isNotetakerPrompt("Read AI — Meeting detected"))
    }
}
