import Foundation

/// The copy that identifies a notetaker prompt, shared by every suppression
/// layer so they can't drift apart.
///
/// Quiet does not keep a list of apps to silence — an app earns suppression by
/// *behaving* like a notetaker (popping a prompt), not by being on a list.
/// Vendors ship new notetakers constantly, and apps that aren't notetakers at
/// all (dictation tools, calendars) grow "Start Notetaker" buttons.
enum NotetakerPhrases {
    /// Copy that only ever appears in a notetaker prompt. Enough on its own —
    /// Zoom's web banner reads "Note-taking is available / Chrome", with no
    /// vendor name anywhere in it.
    static let strong: [String] = [
        "Note-taking is available",
        "Start Notetaker",
        "Start note taker",
        "Notetaker is ready",
        "Start taking notes",
        "Take notes with",
        "Start AI Meeting Note",
        "Start transcribing",
        "Meeting detected",
        "AI Meeting Note"
    ]

    /// Copy a user's own reminder could plausibly contain. Needs a vendor
    /// marker alongside it before anything is dismissed.
    static let weak: [String] = [
        "Take notes",
        "Meeting notes"
    ]

    static func containsStrong(_ text: String) -> Bool {
        strong.contains { text.localizedCaseInsensitiveContains($0) }
    }

    static func containsWeak(_ text: String) -> Bool {
        weak.contains { text.localizedCaseInsensitiveContains($0) }
    }
}

/// Catalog-derived prompt detection shared by the notification and overlay
/// layers. The phrases above stay in code because they are vendor-free;
/// everything vendor-specific — names and each vendor's own observed prompt
/// copy — lives in Competitors.json and is derived here, never a list in code.
///
/// Nothing in this matcher is gated on meeting state. Vendors fire their
/// prompts off their own calendars and routinely beat Quiet's detector, which
/// needs a live call window before it flips — a meeting-state gate is exactly
/// the window the leaked prompts arrive in.
struct NotetakerPromptMatcher {
    /// One catalog vendor's identity terms next to that vendor's own observed
    /// prompt copy. Identity alone never matches, and copy alone never matches
    /// — both halves must appear in the same text.
    struct VendorRule {
        let identityTerms: [String]
        let promptPatterns: [String]
    }

    /// Vendor identity markers, matched as whole-word token subsequences.
    /// Derived from the catalog (entry names + notification title patterns)
    /// plus a builtin seed so an empty catalog still covers the big names.
    let vendorMarkers: [String]
    let vendorRules: [VendorRule]

    /// Tokens the generic phrases are made of (plus filler like "Now" that
    /// competitors put in banner titles). A catalog string whose tokens are
    /// all generic carries no vendor identity and is discarded as a marker.
    /// "read" is here so Read AI's bare "Read" title pattern is discarded —
    /// it's a common English word, and "Read AI" (via its "ai" token) still
    /// carries vendor identity on its own.
    private static let genericTokens: Set<String> = [
        "meeting", "detected", "start", "starting", "notetaker", "note",
        "taking", "is", "available", "taker", "ready", "take", "notes",
        "with", "now", "browser", "helper", "helpers", "read"
    ]

    /// Known vendors, kept even if the bundled catalog fails to load.
    private static let builtinVendorMarkers: [String] = [
        "Otter", "Granola", "Fireflies", "Fathom", "AI Companion", "Notion",
        "Wispr", "Wispr Flow"
    ]

    init(catalog: CompetitorCatalog) {
        let candidates = catalog.entries.map(\.name)
            + catalog.entries.flatMap(\.notificationTitlePatterns)
        let derived = candidates.filter { candidate in
            let tokens = NameTokenMatcher.tokens(of: candidate)
            return !tokens.isEmpty && !tokens.allSatisfy { Self.genericTokens.contains($0) }
        }
        self.vendorMarkers = Array(Set(derived + Self.builtinVendorMarkers))
        self.vendorRules = catalog.entries.compactMap(Self.vendorRule(for:))
    }

    /// Notification Center rule: a strong phrase alone, a weak phrase next to
    /// a vendor marker, or a vendor's identity next to its own prompt copy.
    /// A user's own "Meeting notes" reminder matches none of these.
    func isNotetakerBanner(_ text: String) -> Bool {
        if NotetakerPhrases.containsStrong(text) { return true }
        if NotetakerPhrases.containsWeak(text),
           NameTokenMatcher.name(text, matchesAnyOf: vendorMarkers) {
            return true
        }
        return matchesVendorPromptCopy(text)
    }

    /// App-drawn window rule: strong copy or a vendor's own prompt copy. The
    /// weak-phrase path is deliberately absent here — a pill-sized Notion
    /// popover showing a page titled "Meeting notes" must never be suppressed.
    func isNotetakerPill(_ text: String) -> Bool {
        if NotetakerPhrases.containsStrong(text) { return true }
        return matchesVendorPromptCopy(text)
    }

    private func matchesVendorPromptCopy(_ text: String) -> Bool {
        vendorRules.contains { rule in
            NameTokenMatcher.name(text, matchesAnyOf: rule.identityTerms)
                && rule.promptPatterns.contains { text.localizedCaseInsensitiveContains($0) }
        }
    }

    /// Builds a rule from one catalog entry. Entries whose own name is all
    /// generic tokens ("Browser meeting helpers") get no rule: a browser
    /// relays third parties' notifications, so its name next to prompt-ish
    /// copy is a website ping, not a notetaker. Patterns that merely restate
    /// the vendor's identity ("Otter", "Notion AI") carry no prompt content
    /// and are dropped; an entry with no content patterns left gets no rule.
    private static func vendorRule(for entry: CompetitorEntry) -> VendorRule? {
        let nameTokens = NameTokenMatcher.tokens(of: entry.name)
        guard !nameTokens.isEmpty,
              !nameTokens.allSatisfy({ genericTokens.contains($0) }) else { return nil }

        let identityTerms = ([entry.name] + entry.appNameHints)
            .filter { !NameTokenMatcher.tokens(of: $0).isEmpty }
        let identityTokens = Set(identityTerms.flatMap { NameTokenMatcher.tokens(of: $0) })
        let patterns = (entry.notificationTitlePatterns + entry.notificationBodyPatterns)
            .filter { pattern in
                let tokens = NameTokenMatcher.tokens(of: pattern)
                return !tokens.isEmpty && !tokens.allSatisfy { identityTokens.contains($0) }
            }
        guard !patterns.isEmpty else { return nil }
        return VendorRule(identityTerms: identityTerms, promptPatterns: Array(Set(patterns)))
    }
}
