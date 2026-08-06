import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os.log

enum MeetingEvent: Sendable {
    case started(source: String)
    case ended
}

/// Detects meetings the same way whether they're scheduled or impromptu:
/// by the live call surface (Meet/Zoom/Teams window), never by calendar.
actor MeetingDetector {
    private static let logger = Logger(subsystem: "notes.quiet.app", category: "MeetingDetector")

    private let meetingBundleIds: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.webex.meetingmanager",
        "com.apple.FaceTime"
    ]

    private var wasInMeeting = false
    private var lastSignalAt: Date = .distantPast

    /// How long the meeting signal must be continuously absent before `.ended`
    /// fires. Browser tab titles vanish when the user switches tabs; without
    /// this debounce every tab switch would flap start/end. `.started` still
    /// fires immediately — silencing must be instant.
    private let endDebounceSeconds: TimeInterval = 20

    func events() -> AsyncStream<MeetingEvent> {
        AsyncStream { continuation in
            let task = Task {
                // Fresh stream, fresh state — after pause()/resumeNow() during
                // a still-running meeting, a stale `wasInMeeting` would
                // suppress `.started` for the rest of that meeting.
                self.wasInMeeting = false
                self.lastSignalAt = .distantPast
                while !Task.isCancelled {
                    let source = await self.detectSource()
                    if let source {
                        self.lastSignalAt = Date()
                        if !self.wasInMeeting {
                            self.wasInMeeting = true
                            Self.logger.info("Meeting started, source: \(source, privacy: .public)")
                            continuation.yield(.started(source: source))
                        }
                    } else if self.wasInMeeting,
                              Date().timeIntervalSince(self.lastSignalAt) >= self.endDebounceSeconds {
                        self.wasInMeeting = false
                        Self.logger.info("Meeting ended (signal absent for \(Int(self.endDebounceSeconds))s)")
                        continuation.yield(.ended)
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func detectSource() async -> String? {
        // 1) Live browser call (impromptu OR scheduled — same path).
        if let browserMeet = browserMeetingSignal() {
            return browserMeet
        }

        // 2) Native meeting apps with an on-screen window.
        for app in NSWorkspace.shared.runningApplications {
            if let bid = app.bundleIdentifier, meetingBundleIds.contains(bid) {
                if appIsInLiveMeeting(app, bundleID: bid) {
                    return app.localizedName ?? bid
                }
            }
        }

        return nil
    }

    /// Zoom's home/login window is a tall window too — merely having Zoom
    /// open must never count as a meeting. A live call is identified by its
    /// window title; only when no titles are readable at all does the
    /// tall-window heuristic apply, so detection never goes fully blind.
    private func appIsInLiveMeeting(_ app: NSRunningApplication, bundleID: String) -> Bool {
        guard bundleID == "us.zoom.xos" else {
            return appOwnsOnScreenWindow(app)
        }
        let titles = windowTitles(for: app)
        guard !titles.isEmpty else { return appOwnsOnScreenWindow(app) }
        return titles.contains { zoomTitleIndicatesMeeting($0) }
    }

    /// `nonisolated` + internal so unit tests can exercise it directly.
    /// "Zoom Workplace" (home), "Settings", and "Sign In" never match.
    nonisolated func zoomTitleIndicatesMeeting(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower.contains("zoom meeting")
            || lower.contains("zoom webinar")
            || lower.contains("meeting controls")
            || lower.contains("zoom share")
    }

    /// All readable window titles for one app — CG when Screen Recording is
    /// granted, the app's own AX windows otherwise.
    private func windowTitles(for app: NSRunningApplication) -> [String] {
        let pid = app.processIdentifier
        let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        var titles: [String] = []
        if let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] {
            for window in info {
                guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                      let title = window[kCGWindowName as String] as? String,
                      !title.isEmpty else { continue }
                titles.append(title)
            }
        }
        if !titles.isEmpty { return titles }

        guard AXIsProcessTrusted() else { return [] }
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return [] }
        for window in windows {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String, !title.isEmpty {
                titles.append(title)
            }
        }
        return titles
    }

    private func browserMeetingSignal() -> String? {
        // Pass 1: CG window list (works when Screen Recording is granted)
        let cgTitles = cgWindowTitles()
        for (owner, title) in cgTitles {
            if let label = classifyMeetingWindow(owner: owner, title: title) {
                return label
            }
        }

        // Pass 2 is a fallback for when window titles are invisible — without
        // Screen Recording, CG reports every title as empty. Walking browser AX
        // trees costs more than everything else Quiet does combined, so it only
        // runs when pass 1 genuinely could not see, not merely when it found no
        // meeting.
        guard cgTitles.isEmpty else { return nil }

        for (owner, title) in axBrowserWindowTitles() {
            if let label = classifyMeetingWindow(owner: owner, title: title) {
                return label
            }
        }

        return nil
    }

    private func cgWindowTitles() -> [(String, String)] {
        let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var out: [(String, String)] = []
        for window in info {
            let owner = (window[kCGWindowOwnerName as String] as? String) ?? ""
            let title = (window[kCGWindowName as String] as? String) ?? ""
            if !title.isEmpty {
                out.append((owner, title))
            }
        }
        return out
    }

    private func axBrowserWindowTitles() -> [(String, String)] {
        guard AXIsProcessTrusted() else { return [] }

        let browserHints = ["chrome", "arc", "brave", "edge", "safari", "firefox", "comet"]
        var out: [(String, String)] = []

        for app in NSWorkspace.shared.runningApplications {
            let name = (app.localizedName ?? "").lowercased()
            guard browserHints.contains(where: { name.contains($0) }) else { continue }

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else { continue }

            for window in windows {
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let title = titleRef as? String,
                   !title.isEmpty {
                    out.append((app.localizedName ?? name, title))
                }

                // Chrome sometimes puts the tab title on a child AXStaticText / AXTab
                collectAXTitles(window, owner: app.localizedName ?? name, into: &out, depth: 0)
            }
        }
        return out
    }

    private func collectAXTitles(_ element: AXUIElement, owner: String, into: inout [(String, String)], depth: Int) {
        guard depth < 4 else { return }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }

        for child in children {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String,
               !title.isEmpty,
               title.lowercased().contains("meet") || title.lowercased().contains("zoom") {
                into.append((owner, title))
            }
            collectAXTitles(child, owner: owner, into: &into, depth: depth + 1)
        }
    }

    /// Pure classification of a window (owner, title) into a meeting label.
    /// `nonisolated` + internal so unit tests can exercise it directly.
    nonisolated func classifyMeetingWindow(owner: String, title: String) -> String? {
        let ownerLower = owner.lowercased()
        let titleLower = title.lowercased()
        let isBrowser =
            ownerLower.contains("chrome")
            || ownerLower.contains("arc")
            || ownerLower.contains("brave")
            || ownerLower.contains("edge")
            || ownerLower.contains("safari")
            || ownerLower.contains("firefox")
            || ownerLower.contains("comet")

        if titleLower.contains("meet.google.com")
            || titleLower.contains("google meet")
            || (isBrowser && titleLower.contains("meet") && (
                titleLower.contains("instant meeting")
                || titleLower.range(of: #"[a-z]{3}-[a-z]{4}-[a-z]{3}"#, options: .regularExpression) != nil
                || titleLower.hasPrefix("meet -")
                || titleLower.contains(" - meet")
                || titleLower.contains("meet –")
                || titleLower.contains("meet —")
            )) {
            return "Google Meet"
        }

        if titleLower.contains("zoom.us") || (isBrowser && titleLower.contains("zoom meeting")) {
            return "Zoom (browser)"
        }

        if titleLower.contains("teams.microsoft.com")
            || (isBrowser && titleLower.contains("microsoft teams")) {
            return "Teams (browser)"
        }

        if titleLower.contains("webex.com") {
            return "Webex (browser)"
        }

        return nil
    }

    /// True only when the app owns a real on-screen window (> 80 pt tall).
    /// Never falls back to "the app is running" — an idle Zoom in the
    /// background must not count as a meeting.
    private func appOwnsOnScreenWindow(_ app: NSRunningApplication) -> Bool {
        let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            // CG window list unavailable (no Screen Recording) — fall back to
            // the app's AX windows, not to "running".
            return axAppOwnsTallWindow(app)
        }
        let ownerCandidates = [app.localizedName, app.bundleIdentifier].compactMap { $0?.lowercased() }
        for window in info {
            let owner = ((window[kCGWindowOwnerName as String] as? String) ?? "").lowercased()
            guard !owner.isEmpty else { continue }
            let height = (window[kCGWindowBounds as String] as? [String: Any])?["Height"] as? CGFloat ?? 0
            guard height > 80 else { continue }
            if ownerCandidates.contains(where: { owner.contains($0) }) {
                return true
            }
        }
        return false
    }

    /// AX fallback for `appOwnsOnScreenWindow`: asks the app itself for its
    /// windows and applies the same > 80 pt height bar.
    private func axAppOwnsTallWindow(_ app: NSRunningApplication) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return false }

        for window in windows {
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let raw = sizeRef,
                  CFGetTypeID(raw) == AXValueGetTypeID() else { continue }
            var size = CGSize.zero
            if AXValueGetValue(raw as! AXValue, .cgSize, &size), size.height > 80 {
                return true
            }
        }
        return false
    }
}
