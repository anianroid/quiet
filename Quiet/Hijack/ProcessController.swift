import AppKit
import Darwin
import Foundation
import os.log

/// Whole-word matcher for competitor app/process names.
///
/// Substring hint matching is dangerous: "Spotter" contains "Otter", so an
/// unrelated app would get killed for sharing letters with a notetaker. This
/// matcher tokenizes names on non-letter boundaries and requires every hint
/// token to appear as a whole token, in order — "Spotter" never matches
/// "Otter", while "Granola Helper (Renderer)" still matches "Granola".
enum NameTokenMatcher {
    /// Lowercased letter runs: "Granola Helper (Renderer)" → ["granola", "helper", "renderer"].
    static func tokens(of name: String) -> [String] {
        name.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }

    /// True when the hint's tokens appear as an ordered subsequence of the
    /// name's tokens ("Read AI" matches "Read AI Helper" but not "AI Read").
    static func name(_ name: String, matchesHint hint: String) -> Bool {
        containsSubsequence(nameTokens: tokens(of: name), hintTokens: tokens(of: hint))
    }

    static func name(_ name: String, matchesAnyOf hints: [String]) -> Bool {
        let nameTokens = tokens(of: name)
        return hints.contains { containsSubsequence(nameTokens: nameTokens, hintTokens: tokens(of: $0)) }
    }

    private static func containsSubsequence(nameTokens: [String], hintTokens: [String]) -> Bool {
        guard !hintTokens.isEmpty else { return false }
        var remaining = hintTokens[...]
        for token in nameTokens where token == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return false
    }
}

struct ProcessController: Sendable {
    let catalog: CompetitorCatalog

    private static let logger = Logger(subsystem: "notes.quiet.app", category: "ProcessController")

    private static let protectedBundleIds: Set<String> = [
        "notes.quiet.app",
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.webex.meetingmanager",
        "com.apple.FaceTime",
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "com.apple.systempreferences",
        "com.electron.wispr-flow", // dictation — not a meeting notetaker
        "com.electron.wispr-flow.accessibility-mac-app"
    ]

    private static let protectedNameFragments = [
        "zoom", "chrome", "safari", "edge", "brave", "arc", "firefox",
        "teams", "webex", "settings", "system settings", "preference", "wispr"
    ]

    /// Bundle-id prefixes that identify an entire Electron notetaker family
    /// (main app + Helper / GPU / Renderer children).
    private static let competitorBundlePrefixes = [
        "com.granola.",
        "ai.granola.",
        "ai.fireflies.",
        "com.fireflies.",
        "com.otter.",
        "ai.otter.",
        "com.otterai.",
        "com.fathom.",
        "so.fathom.",
        "com.read.ai",
        "ai.read.",
        "com.tldv.",
        "io.tldv.",
        "com.circleback.",
        "ai.circleback.",
        "com.sembly.",
        "ai.sembly.",
        "com.meetgeek.",
        "ai.meetgeek."
    ]

    /// Path fragments under /Applications (and helpers) for nuclear path matching.
    private static let competitorPathFragments = [
        "/Granola.app/",
        "/Fireflies.app/",
        "/Otter.app/",
        "/Fathom.app/",
        "/Read AI.app/",
        "/tl;dv.app/",
        "/tldv.app/",
        "/Circleback.app/",
        "/Sembly.app/",
        "/MeetGeek.app/",
        "GranolaMacWebcam"
    ]

    /// PIDs already judged harmless. Reading `bundleIdentifier`, `localizedName`
    /// and `bundleURL` costs a LaunchServices round trip each, and the watchdog
    /// re-runs several times a second over ~150 processes — so each pid is
    /// judged exactly once. A pid's identity never changes, so the verdict
    /// cannot go stale; entries are dropped when the process exits.
    @MainActor private static var benignPIDs: Set<pid_t> = []

    @MainActor
    func suspendCompetitors(from installed: [InstalledCompetitor]) -> [HijackAction] {
        var actions: [HijackAction] = []
        let running = NSWorkspace.shared.runningApplications
        Self.benignPIDs.formIntersection(Set(running.map(\.processIdentifier)))

        for app in running {
            // processIdentifier is a local read; everything below is not.
            guard !Self.benignPIDs.contains(app.processIdentifier) else { continue }
            guard let label = competitorLabel(for: app) else {
                Self.benignPIDs.insert(app.processIdentifier)
                continue
            }
            let ok = terminate(app, label: label)
            actions.append(HijackAction(competitorName: label, action: ok ? "force_quit" : "terminate_failed", at: Date()))
        }

        _ = installed
        return actions
    }

    /// Kills the app and logs the outcome under one competitor label.
    private func terminate(_ app: NSRunningApplication, label: String) -> Bool {
        let pid = app.processIdentifier
        let ok = hardKill(app)
        if ok {
            Self.logger.info("Force-quit \(label, privacy: .public) (pid \(pid))")
        } else {
            Self.logger.error("Failed to terminate \(label, privacy: .public) (pid \(pid))")
        }
        return ok
    }

    /// The display name to log a kill under, or nil when the app must be left
    /// alone. Combines what used to be three separate passes — bundle-id family,
    /// catalog name hints, and Electron path fragments — into one judgement per
    /// process, so each app's identity is read a single time.
    private func competitorLabel(for app: NSRunningApplication) -> String? {
        let bundleID = app.bundleIdentifier
        let name = app.localizedName

        if let bundleID, Self.protectedBundleIds.contains(bundleID) { return nil }
        if let name, isProtectedName(name) { return nil }
        if let bundleID, bundleID.hasPrefix("com.apple.") { return nil }

        // Bundle id belongs to a known notetaker family, or to a catalog entry
        // marked for suspension.
        if let bundleID {
            let isFamily = Self.competitorBundlePrefixes.contains {
                bundleID.hasPrefix($0) || bundleID == $0.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            }
            let catalogEntry = catalog.entries.first {
                $0.bundleIds.contains(bundleID) && $0.policy == .suspendDuringMeeting
            }
            if isFamily || catalogEntry != nil {
                return catalogEntry?.name ?? name ?? bundleID
            }
        }

        // Helper processes named after a catalog entry ("Granola Helper (GPU)").
        if let name {
            for entry in catalog.entries where entry.policy == .suspendDuringMeeting {
                let hints = entry.helperProcessNames + entry.appNameHints
                if NameTokenMatcher.name(name, matchesAnyOf: hints) {
                    return entry.name
                }
            }
        }

        // Orphans Electron leaves without a matching bundle id.
        if let path = app.bundleURL?.path ?? app.executableURL?.path,
           Self.competitorPathFragments.contains(where: { path.contains($0) }) {
            return name ?? path
        }

        return nil
    }

    /// Electron notetakers ignore soft quit. Soft-ask once, then forceTerminate + SIGKILL.
    private func hardKill(_ app: NSRunningApplication) -> Bool {
        if app.isTerminated { return true }

        let pid = app.processIdentifier
        guard pid > 1 else { return false }

        _ = app.terminate()
        if app.isTerminated { return true }

        _ = app.forceTerminate()
        if app.isTerminated { return true }

        // Last resort — NSRunningApplication sometimes fails on sandboxed Electron helpers.
        kill(pid, SIGKILL)
        usleep(50_000)
        return app.isTerminated || kill(pid, 0) != 0
    }

    private func shouldTerminateByName(app: NSRunningApplication, entry: CompetitorEntry) -> Bool {
        if let bid = app.bundleIdentifier {
            if Self.protectedBundleIds.contains(bid) || bid.hasPrefix("com.apple.") { return false }
        }
        guard let name = app.localizedName else { return false }
        if isProtectedName(name) { return false }

        let hints = entry.helperProcessNames + entry.appNameHints
        return NameTokenMatcher.name(name, matchesAnyOf: hints)
    }

    /// Internal (not private) so unit tests can verify protected names are never terminated.
    func isProtectedName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return Self.protectedNameFragments.contains(where: { lower.contains($0) })
    }
}
