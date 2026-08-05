import AppKit
import ApplicationServices
import Foundation
import os.log

/// Layer B — dismiss competing **notetaker banners only**.
/// Deliberately narrow: never walk Zoom/Chrome/System Settings UI trees, and
/// only dismiss when a vendor marker (Otter, Granola, Fireflies…) co-occurs
/// with a generic notetaker phrase — a user's own "Meeting notes" reminder is
/// never eaten.
@MainActor
final class NotificationWatcher {
    private static let logger = Logger(subsystem: "notes.quiet.app", category: "NotificationWatcher")

    private var timer: Timer?
    private var isSweeping = false
    /// Window-created observers per notification-surface pid — kills a banner
    /// during its fade-in instead of on the next poll tick.
    private var observers: [pid_t: AXObserver] = [:]

    /// Vendor identity markers, matched as whole-word token subsequences.
    /// Derived from the catalog (entry names + notification title patterns)
    /// plus a builtin seed so an empty catalog still covers the big names.
    private let vendorMarkers: [String]

    /// Copy that only ever appears in a notetaker prompt — dismissible on its
    /// own. Zoom's web banner is literally just "Note-taking is available" +
    /// "Chrome", with no vendor word anywhere in the text.
    private static let strongPhrases: [String] = [
        "Note-taking is available",
        "Start Notetaker",
        "Start note taker",
        "Notetaker is ready",
        "Start taking notes",
        "Take notes with",
        "Meeting detected"
    ]

    /// Ambiguous copy a user's own reminder could contain — a vendor marker
    /// must also be present in the banner text before we dismiss.
    private static let weakPhrases: [String] = [
        "Take notes",
        "Meeting notes"
    ]

    /// Tokens the generic phrases are made of (plus filler like "Now" that
    /// competitors put in banner titles). A catalog string whose tokens are
    /// all generic carries no vendor identity and is discarded.
    /// "read" is here so Read AI's bare "Read" title pattern is discarded —
    /// it's a common English word, and "Read AI" (via its "ai" token) still
    /// carries vendor identity on its own.
    private static let genericTokens: Set<String> = [
        "meeting", "detected", "start", "notetaker", "note", "taking",
        "is", "available", "taker", "ready", "take", "notes", "with",
        "now", "browser", "helper", "helpers", "read"
    ]

    /// Known vendors, kept even if the bundled catalog fails to load.
    private static let builtinVendorMarkers: [String] = [
        "Otter", "Granola", "Fireflies", "Fathom", "AI Companion", "Notion"
    ]

    init(catalog: CompetitorCatalog) {
        let candidates = catalog.entries.map(\.name)
            + catalog.entries.flatMap(\.notificationTitlePatterns)
        let derived = candidates.filter { candidate in
            let tokens = NameTokenMatcher.tokens(of: candidate)
            return !tokens.isEmpty && !tokens.allSatisfy { Self.genericTokens.contains($0) }
        }
        self.vendorMarkers = Array(Set(derived + Self.builtinVendorMarkers))
    }

    func start() {
        stop()
        Self.logger.notice("NotificationWatcher.start axTrusted=\(AXIsProcessTrusted()) markers=\(self.vendorMarkers.count)")
        guard AXIsProcessTrusted() else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sweep()
            }
        }
        sweep()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers.removeAll()
    }

    private func ensureObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }

        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<NotificationWatcher>.fromOpaque(refcon).takeUnretainedValue()
            // The observer's run loop source lives on the main run loop.
            MainActor.assumeIsolated {
                watcher.sweep()
            }
        }

        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let appElement = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(
            observer,
            appElement,
            kAXWindowCreatedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque()
        )
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func sweep() {
        guard !isSweeping else { return }
        isSweeping = true
        defer { isSweeping = false }

        // ONLY Notification Center / usernoted — never Zoom, Chrome, Notion, or Settings.
        for app in NSWorkspace.shared.runningApplications {
            let bid = app.bundleIdentifier ?? ""
            let name = (app.localizedName ?? "").lowercased()
            let isNotificationSurface =
                bid == "com.apple.notificationcenterui"
                || bid == "com.apple.usernoted"
                || bid.contains("UserNotification")
                || bid.contains("usernoted")
                || name == "notification center"
                || name.contains("usernoted")

            guard isNotificationSurface else { continue }
            ensureObserver(for: app)
            let element = AXUIElementCreateApplication(app.processIdentifier)
            if UserDefaults.standard.bool(forKey: "quiet.axDump") {
                dumpTree(element, depth: 0, path: bid.isEmpty ? name : bid)
            }
            // Banners live in AXSystemDialog windows — walking only those skips
            // the widget stacks and the app's entire menu tree every sweep.
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement] {
                for window in windows {
                    let subrole = copyString(window, kAXSubroleAttribute as String) ?? ""
                    guard subrole == "AXSystemDialog" else { continue }
                    dismissMatchingBanners(in: window, depth: 0)
                }
            } else {
                dismissMatchingBanners(in: element, depth: 0)
            }
        }
    }

    /// Diagnostics only — logs the Notification Center AX tree at notice level.
    private func dumpTree(_ element: AXUIElement, depth: Int, path: String) {
        guard depth < 14 else { return }
        let role = copyString(element, kAXRoleAttribute as String) ?? "?"
        let subrole = copyString(element, kAXSubroleAttribute as String) ?? ""
        let blob = elementTextBlob(element)
        var actionsRef: CFArray?
        var actions: [String] = []
        if AXUIElementCopyActionNames(element, &actionsRef) == .success,
           let list = actionsRef as? [String] {
            actions = list
        }
        if !blob.isEmpty || !actions.isEmpty || !subrole.isEmpty {
            Self.logger.notice("AXDUMP d\(depth) \(path, privacy: .public) role=\(role, privacy: .public) sub=\(subrole, privacy: .public) actions=\(actions.joined(separator: ","), privacy: .public) text=\(String(blob.prefix(100)), privacy: .public)")
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for (i, child) in children.enumerated() {
            dumpTree(child, depth: depth + 1, path: path + "/\(i)")
        }
    }

    private func dismissMatchingBanners(in element: AXUIElement, depth: Int) {
        guard depth < 6 else { return }

        let blob = elementTextBlob(element)
        if !blob.isEmpty, isNotetakerPrompt(blob), !blob.localizedCaseInsensitiveContains("Quiet") {
            // macOS 26 banners expose a custom named Close action (not AXPress
            // on a close button, not AXCancel) — perform it verbatim, with the
            // legacy paths kept as fallbacks for older banner styles.
            let closed = performNamedCloseAction(on: element)
                || pressCloseButton(in: element)
                || AXUIElementPerformAction(element, kAXCancelAction as CFString) == .success
            Self.logger.notice("Notetaker banner \(closed ? "dismissed" : "matched but not dismissable", privacy: .public): \(String(blob.prefix(120)), privacy: .public)")
            return
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            dismissMatchingBanners(in: child, depth: depth + 1)
        }
    }

    /// A banner is a notetaker prompt when it contains a strong phrase, or a
    /// weak phrase together with a vendor marker. "Meeting notes" alone is
    /// never dismissed.
    func isNotetakerPrompt(_ text: String) -> Bool {
        if Self.strongPhrases.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        guard Self.weakPhrases.contains(where: { text.localizedCaseInsensitiveContains($0) }) else {
            return false
        }
        return NameTokenMatcher.name(text, matchesAnyOf: vendorMarkers)
    }

    private func elementTextBlob(_ element: AXUIElement) -> String {
        [
            copyString(element, kAXTitleAttribute as String),
            copyString(element, kAXDescriptionAttribute as String),
            copyString(element, kAXValueAttribute as String)
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    /// Performs the element's own named close action — the action names on
    /// macOS 26 banners are opaque descriptor strings ("…,Name:Close"), so
    /// match by substring and pass the raw string back verbatim.
    private func performNamedCloseAction(on element: AXUIElement) -> Bool {
        var actionsRef: CFArray?
        guard AXUIElementCopyActionNames(element, &actionsRef) == .success,
              let actions = actionsRef as? [String] else { return false }
        for action in actions where action.localizedCaseInsensitiveContains("close") {
            if AXUIElementPerformAction(element, action as CFString) == .success {
                return true
            }
        }
        return false
    }

    private func pressCloseButton(in element: AXUIElement) -> Bool {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return false }

        for child in children {
            let role = copyString(child, kAXRoleAttribute as String) ?? ""
            let title = copyString(child, kAXTitleAttribute as String) ?? ""
            let desc = copyString(child, kAXDescriptionAttribute as String) ?? ""
            if role == (kAXButtonRole as String),
               title.localizedCaseInsensitiveContains("close")
                || desc.localizedCaseInsensitiveContains("close")
                || title == "×" {
                AXUIElementPerformAction(child, kAXPressAction as CFString)
                return true
            }
        }
        return false
    }

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
