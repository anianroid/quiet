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
        "com.electron.wispr-flow" // dictation — not a meeting notetaker
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

    @MainActor
    func suspendCompetitors(from installed: [InstalledCompetitor]) -> [HijackAction] {
        var actions: [HijackAction] = []
        let running = NSWorkspace.shared.runningApplications
        var seenPIDs = Set<pid_t>()

        // Pass 1: anything whose bundle id is in the notetaker family.
        for app in running {
            guard let bid = app.bundleIdentifier else { continue }
            guard Self.competitorBundlePrefixes.contains(where: { bid.hasPrefix($0) || bid == $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
                    || catalog.entries.contains(where: { $0.bundleIds.contains(bid) && $0.policy == .suspendDuringMeeting })
            else { continue }
            guard !Self.protectedBundleIds.contains(bid) else { continue }
            guard !(app.localizedName.map { isProtectedName($0) } ?? false) else { continue }

            let label = catalog.entries.first(where: { $0.bundleIds.contains(bid) })?.name
                ?? app.localizedName
                ?? bid
            let ok = terminate(app, label: label)
            seenPIDs.insert(app.processIdentifier)
            actions.append(HijackAction(competitorName: label, action: ok ? "force_quit" : "terminate_failed", at: Date()))
        }

        // Pass 2: name-based helpers (Granola Helper (Renderer), etc.)
        for entry in catalog.entries where entry.policy == .suspendDuringMeeting {
            for app in running {
                guard !seenPIDs.contains(app.processIdentifier) else { continue }
                guard shouldTerminateByName(app: app, entry: entry) else { continue }
                let ok = terminate(app, label: entry.name)
                seenPIDs.insert(app.processIdentifier)
                if !actions.contains(where: { $0.competitorName == entry.name && $0.action == "force_quit" }) {
                    actions.append(HijackAction(competitorName: entry.name, action: ok ? "force_quit" : "terminate_failed", at: Date()))
                }
            }
        }

        // Pass 3: path-based orphans Electron may leave without a matching bundle id.
        for app in running {
            guard !seenPIDs.contains(app.processIdentifier) else { continue }
            guard let url = app.bundleURL?.path ?? app.executableURL?.path else { continue }
            guard Self.competitorPathFragments.contains(where: { url.contains($0) }) else { continue }
            if let bid = app.bundleIdentifier, Self.protectedBundleIds.contains(bid) { continue }
            if let name = app.localizedName, isProtectedName(name) { continue }

            let label = app.localizedName ?? url
            let ok = terminate(app, label: label)
            seenPIDs.insert(app.processIdentifier)
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
