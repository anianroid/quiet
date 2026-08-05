import AppKit
import ApplicationServices
import CoreGraphics
import EventKit
import Foundation

enum MeetingEvent: Sendable {
    case started(source: String)
    case ended
}

/// Detects meetings the same way whether they're scheduled or impromptu:
/// by the live call surface (Meet/Zoom/Teams window), not by calendar alone.
/// Calendar is only a soft assist when the meeting app is already open.
actor MeetingDetector {
    private let meetingBundleIds: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.webex.meetingmanager",
        "com.apple.FaceTime"
    ]

    private var wasInMeeting = false

    func events() -> AsyncStream<MeetingEvent> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    let source = await self.detectSource()
                    let inMeeting = source != nil
                    if inMeeting, !self.wasInMeeting, let source {
                        self.wasInMeeting = true
                        continuation.yield(.started(source: source))
                    } else if !inMeeting, self.wasInMeeting {
                        self.wasInMeeting = false
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

        let running = NSWorkspace.shared.runningApplications

        // 2) Native meeting apps with an on-screen window.
        for app in running {
            if let bid = app.bundleIdentifier, meetingBundleIds.contains(bid) {
                if appOwnsOnScreenWindow(bundleId: bid, ownerName: app.localizedName) {
                    return app.localizedName ?? bid
                }
            }
        }

        // 3) Soft assist: calendar says a call is now + host app / browser is up
        //    (covers scheduled Meet tabs whose title is just "Standup").
        if let cal = await calendarMeetingHint() {
            if running.contains(where: { meetingBundleIds.contains($0.bundleIdentifier ?? "") }) {
                return cal.hostLabel
            }
            if cal.isBrowserMeet, running.contains(where: { isBrowser($0) }) {
                return "Google Meet"
            }
        }

        return nil
    }

    private func isBrowser(_ app: NSRunningApplication) -> Bool {
        let bid = app.bundleIdentifier ?? ""
        let name = (app.localizedName ?? "").lowercased()
        return [
            "com.google.Chrome",
            "company.thebrowser.Browser",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "com.apple.Safari",
            "org.mozilla.firefox"
        ].contains(bid)
            || name.contains("chrome")
            || name.contains("arc")
            || name.contains("brave")
            || name.contains("edge")
            || name.contains("safari")
    }

    private func browserMeetingSignal() -> String? {
        // Pass 1: CG window list (works when Screen Recording is granted)
        for (owner, title) in cgWindowTitles() {
            if let label = classifyMeetingWindow(owner: owner, title: title) {
                return label
            }
        }

        // Pass 2: Accessibility titles on browser processes (works with Accessibility)
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

    private func classifyMeetingWindow(owner: String, title: String) -> String? {
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

    private func appOwnsOnScreenWindow(bundleId: String, ownerName: String?) -> Bool {
        let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
        }
        let ownerCandidates = [ownerName, bundleId].compactMap { $0?.lowercased() }
        for window in info {
            let owner = ((window[kCGWindowOwnerName as String] as? String) ?? "").lowercased()
            let height = (window[kCGWindowBounds as String] as? [String: Any])?["Height"] as? CGFloat ?? 0
            guard height > 80 else { continue }
            if ownerCandidates.contains(where: { owner.contains($0) }) || owner.contains("zoom") || owner.contains("teams") {
                return true
            }
        }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }

    private struct CalendarHint {
        let isBrowserMeet: Bool
        let hostLabel: String
    }

    private func calendarMeetingHint() async -> CalendarHint? {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else { return nil }

        let now = Date()
        let window = DateInterval(start: now.addingTimeInterval(-5 * 60), end: now.addingTimeInterval(5 * 60))
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: nil)
        let events = store.events(matching: predicate)

        for event in events {
            let blob = ((event.title ?? "") + " " + (event.notes ?? "") + " " + (event.location ?? "") + " " + (event.url?.absoluteString ?? "")).lowercased()
            if blob.contains("meet.google") || blob.contains("meet.google.com") {
                return CalendarHint(isBrowserMeet: true, hostLabel: "Google Meet")
            }
            if blob.contains("zoom.us") {
                return CalendarHint(isBrowserMeet: false, hostLabel: "zoom.us")
            }
            if blob.contains("teams.microsoft") || blob.contains("teams.live.com") {
                return CalendarHint(isBrowserMeet: false, hostLabel: "Microsoft Teams")
            }
            if blob.contains("webex") {
                return CalendarHint(isBrowserMeet: false, hostLabel: "Webex")
            }
        }
        return nil
    }
}
