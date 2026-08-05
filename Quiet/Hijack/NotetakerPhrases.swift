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
        "Meeting detected"
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
