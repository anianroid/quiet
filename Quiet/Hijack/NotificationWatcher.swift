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
    private var isMeetingActive = false
    /// Window-created observers per notification-surface pid — kills a banner
    /// during its fade-in instead of on the next poll tick.
    private var observers: [pid_t: AXObserver] = [:]

    /// All prompt matching — generic phrases plus catalog-derived vendor rules
    /// — lives in the shared matcher so this layer can't drift from Layer C.
    private let matcher: NotetakerPromptMatcher

    init(catalog: CompetitorCatalog) {
        self.matcher = NotetakerPromptMatcher(catalog: catalog)
    }

    func start() {
        stop()
        Self.logger.notice("NotificationWatcher.start axTrusted=\(AXIsProcessTrusted()) markers=\(self.matcher.vendorMarkers.count)")
        guard AXIsProcessTrusted() else { return }
        let interval: TimeInterval = isMeetingActive ? 0.15 : 0.5
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
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

    func setMeetingActive(_ active: Bool) {
        guard active != isMeetingActive else { return }
        isMeetingActive = active
        if timer != nil { start() }
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
            let debug = UserDefaults.standard.bool(forKey: "quiet.axDump")
            // Banners live in AXSystemDialog windows — walking only those skips
            // the widget stacks and the app's entire menu tree every sweep.
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement] {
                for window in windows {
                    let subrole = copyString(window, kAXSubroleAttribute as String) ?? ""
                    // Prefer AXSystemDialog (banner chrome) but also walk other
                    // NC windows — macOS versions vary which subrole they use.
                    if !subrole.isEmpty && subrole != "AXSystemDialog" && subrole != "AXFloatingWindow" {
                        continue
                    }
                    if debug {
                        dumpTree(window, depth: 0, path: bid.isEmpty ? name : bid)
                    }
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
        guard depth < 10 else { return }

        let blob = elementTextBlob(element)
        if !blob.isEmpty, isNotetakerPrompt(blob), !blob.localizedCaseInsensitiveContains("Kamui") {
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

    /// A banner is a notetaker prompt when it contains a strong phrase, a weak
    /// phrase together with a vendor marker, or a catalog vendor's identity
    /// next to that vendor's own observed prompt copy. "Meeting notes" alone
    /// is never dismissed, nor is a vendor's name next to unrelated copy.
    ///
    /// Deliberately not gated on meeting state: vendors fire these banners off
    /// their own calendars and routinely beat Quiet's detector, which needs a
    /// live call window first — a gate on isMeetingActive is exactly the
    /// window the leaked banners used to arrive in.
    func isNotetakerPrompt(_ text: String) -> Bool {
        matcher.isNotetakerBanner(text)
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
