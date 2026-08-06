import AppKit
import Foundation
import os.log

/// Turns off Wispr Flow's meeting detection at the source — the setting that
/// pops its "Meeting detected · Start Notetaker" pill. Unlike Zoom or Notion,
/// Wispr keeps this in a JSON config Quiet can edit directly, so this host
/// step is one click instead of a settings walkthrough. Dictation is
/// untouched; only meeting auto-detection and its calendar notifications go.
///
/// The edit is only safe with Wispr quit — Electron rewrites the file on
/// exit, clobbering a live edit — so the flow is: quit, re-read, patch,
/// relaunch (only if it was running). The first edit leaves a
/// `config.json.quiet-backup` beside the original.
@MainActor
enum WisprSilencer {
    private static let logger = Logger(subsystem: "notes.quiet.app", category: "WisprSilencer")
    private static let bundleID = "com.electron.wispr-flow"
    /// Both flags live under prefs.user. `autoDetectMeetingsEnabled` is the
    /// pill; `notetakerCalendarNotificationsEnabled` is its calendar pings.
    private static let flags = ["autoDetectMeetingsEnabled", "notetakerCalendarNotificationsEnabled"]

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wispr Flow/config.json")
    }

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
            || FileManager.default.fileExists(atPath: "/Applications/Wispr Flow.app")
    }

    /// nil when Wispr's config is missing or unreadable.
    static func isSilenced() -> Bool? {
        guard let user = readUserPrefs() else { return nil }
        return flags.allSatisfy { (user[$0] as? Bool) == false }
    }

    /// Quits Wispr, flips the flags, relaunches it if it was running.
    /// Returns true when the config on disk ends up in the requested state.
    static func setSilenced(_ silenced: Bool) async -> Bool {
        let url = configURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.notice("Wispr config not found at \(url.path, privacy: .public)")
            return false
        }
        let backup = url.appendingPathExtension("quiet-backup")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: url, to: backup)
        }

        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.terminate()
        }
        for _ in 0..<10 where !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            try? await Task.sleep(for: .milliseconds(500))
        }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.forceTerminate()
        }
        try? await Task.sleep(for: .milliseconds(300))

        // Read only after the quit settles — Wispr rewrites this file on exit.
        guard var root = readRoot(),
              var prefs = root["prefs"] as? [String: Any],
              var user = prefs["user"] as? [String: Any] else {
            logger.error("Wispr config unreadable — not modified")
            return false
        }
        for flag in flags {
            user[flag] = !silenced
        }
        prefs["user"] = user
        root["prefs"] = prefs
        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Wispr config write failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        if wasRunning, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
        let landed = isSilenced() == silenced
        logger.notice("Wispr notetaker \(silenced ? "silenced" : "re-enabled", privacy: .public) (relaunched: \(wasRunning)) verified=\(landed)")
        return landed
    }

    private static func readRoot() -> [String: Any]? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func readUserPrefs() -> [String: Any]? {
        guard let root = readRoot(), let prefs = root["prefs"] as? [String: Any] else { return nil }
        return prefs["user"] as? [String: Any]
    }
}
