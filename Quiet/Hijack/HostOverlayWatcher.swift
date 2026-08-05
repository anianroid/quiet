import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os.log

/// Layer C — suppress the floating "Start Notetaker" pills apps draw
/// themselves. These are ordinary app windows, not notifications, so Layer B
/// never sees them.
///
/// **No app list.** A window earns suppression by behaving like a notetaker
/// prompt — small, floating, and carrying unambiguous prompt copy — whoever
/// draws it. That matters because the offenders aren't only notetakers: a
/// dictation app or a calendar can grow a "Start Notetaker" button overnight,
/// and Quiet must handle it without shipping a new build.
///
/// The host app is never quit and no button that could *start* anything is
/// ever pressed — only close affordances, else the window is parked off-screen.
@MainActor
final class HostOverlayWatcher {
    private static let logger = Logger(subsystem: "notes.quiet.app", category: "HostOverlayWatcher")

    /// Electron does not reliably post AXWindowCreated for its notification
    /// panels, so the poll is what actually catches a pill. During a meeting it
    /// runs fast enough to beat the fade-in.
    private static let idleInterval: TimeInterval = 1.0
    private static let meetingInterval: TimeInterval = 0.1

    /// Prompt pills are small. Anything taller is a real window we never touch.
    private static let maxOverlayHeight: CGFloat = 260
    /// Below this, a window is a shadow/tooltip artifact rather than a prompt.
    private static let minOverlayHeight: CGFloat = 24

    private var timer: Timer?
    private var isSweeping = false
    private var interval: TimeInterval = HostOverlayWatcher.idleInterval
    /// Apps told to expose their web content, so the switch is flipped once each.
    private var manualAccessibilityEnabled: Set<pid_t> = []

    func start() {
        stop()
        Self.logger.notice("HostOverlayWatcher.start axTrusted=\(AXIsProcessTrusted()) interval=\(self.interval)")
        guard AXIsProcessTrusted() else { return }
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
    }

    /// Meeting start is exactly when hosts pop their pills — poll hard for the
    /// duration so a pill is hidden within ~100ms instead of up to a second.
    func setMeetingActive(_ active: Bool) {
        let next = active ? Self.meetingInterval : Self.idleInterval
        guard next != interval else { return }
        interval = next
        if timer != nil {
            start()
        }
    }

    private func sweep() {
        guard !isSweeping else { return }
        isSweeping = true
        defer { isSweeping = false }

        // CoreGraphics narrows ~60 running apps to the handful owning a small
        // floating window — one cheap call instead of AX round-trips per app.
        for pid in candidatePIDs() {
            inspect(pid: pid)
        }
    }

    /// PIDs owning an on-screen window small enough to be a prompt pill.
    private func candidatePIDs() -> Set<pid_t> {
        let options = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var pids: Set<pid_t> = []
        for window in info {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID else { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let height = bounds["Height"] as? CGFloat,
                  height >= Self.minOverlayHeight, height <= Self.maxOverlayHeight else { continue }
            pids.insert(pid)
        }
        return pids
    }

    private func inspect(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        let bundleID = app.bundleIdentifier ?? ""
        // Apple's own surfaces are Layer B's job (Notification Center) or system
        // UI we must never touch.
        guard !bundleID.hasPrefix("com.apple."), bundleID != Bundle.main.bundleIdentifier else { return }

        let appElement = AXUIElementCreateApplication(pid)
        if !manualAccessibilityEnabled.contains(pid) {
            // Electron only emits its web-content AX tree when an assistive
            // client asks; without this the pill's text reads as empty.
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            manualAccessibilityEnabled.insert(pid)
        }

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return }

        let debug = UserDefaults.standard.bool(forKey: "quiet.axDump")
        for window in windows {
            guard isOverlaySized(window), !isOffScreen(window) else { continue }

            var blob = ""
            collectText(window, into: &blob, depth: 0)
            if debug {
                let subrole = copyString(window, kAXSubroleAttribute as String) ?? ""
                Self.logger.notice("OVERLAYDUMP \(bundleID, privacy: .public) size=\(self.windowSizeDescription(window), privacy: .public) sub=\(subrole, privacy: .public) text=\(String(blob.prefix(200)), privacy: .public)")
            }

            // Strong copy only — never the ambiguous "Meeting notes" wording a
            // user's own reminder might carry.
            guard !blob.isEmpty,
                  NotetakerPhrases.containsStrong(blob),
                  !blob.localizedCaseInsensitiveContains("Quiet")
            else { continue }

            if debug {
                dumpSubtree(window, depth: 0, path: bundleID)
            }
            let strategy = dismiss(window)
            Self.logger.notice("Overlay (\(app.localizedName ?? bundleID, privacy: .public)) \(strategy, privacy: .public): \(String(blob.prefix(120)), privacy: .public)")
        }
    }

    private func isOverlaySized(_ window: AXUIElement) -> Bool {
        guard let size = windowSize(window) else { return false }
        return size.height >= Self.minOverlayHeight && size.height <= Self.maxOverlayHeight
    }

    private func windowSize(_ window: AXUIElement) -> CGSize? {
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let value = sizeRef, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private func windowSizeDescription(_ window: AXUIElement) -> String {
        guard let size = windowSize(window) else { return "?" }
        return "\(Int(size.width))x\(Int(size.height))"
    }

    /// A pill already parked stays handled — re-moving it every tick would spam
    /// the log to no visible effect.
    private func isOffScreen(_ window: AXUIElement) -> Bool {
        guard let point = windowPosition(window) else { return false }
        return point.x < -20_000
    }

    private func windowPosition(_ window: AXUIElement) -> CGPoint? {
        var positionRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              let value = positionRef, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    /// Ladder from least to most forceful. Notion's pill exposes no close
    /// affordance at all, so the last rung moves the window off every screen —
    /// it can't be seen, nothing is clicked, and the host app keeps running.
    private func dismiss(_ window: AXUIElement) -> String {
        if performNamedCloseAction(on: window) { return "dismissed via named action" }
        if pressCloseButton(in: window, depth: 0) { return "dismissed via close button" }
        if AXUIElementPerformAction(window, kAXCancelAction as CFString) == .success {
            return "dismissed via AXCancel"
        }
        if moveOffScreen(window) { return "moved off-screen" }
        return "matched but not dismissable"
    }

    private func moveOffScreen(_ window: AXUIElement) -> Bool {
        var offscreen = CGPoint(x: -30_000, y: -30_000)
        guard let value = AXValueCreate(.cgPoint, &offscreen) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

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

    /// Presses only close/dismiss affordances — never a button that could start
    /// a recording.
    private func pressCloseButton(in element: AXUIElement, depth: Int) -> Bool {
        guard depth < 14 else { return false }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return false }

        for child in children {
            let role = copyString(child, kAXRoleAttribute as String) ?? ""
            if role == (kAXButtonRole as String) {
                let label = [
                    copyString(child, kAXTitleAttribute as String),
                    copyString(child, kAXDescriptionAttribute as String)
                ].compactMap { $0 }.joined(separator: " ")
                if label.localizedCaseInsensitiveContains("close")
                    || label.localizedCaseInsensitiveContains("dismiss")
                    || label == "×" || label == "✕" {
                    if AXUIElementPerformAction(child, kAXPressAction as CFString) == .success {
                        return true
                    }
                }
            }
            if pressCloseButton(in: child, depth: depth + 1) { return true }
        }
        return false
    }

    private func collectText(_ element: AXUIElement, into blob: inout String, depth: Int) {
        // Electron nests web content deeply — the walk must reach past the
        // AXWebArea wrappers to the pill's actual labels.
        guard depth < 14, blob.count < 1500 else { return }
        for attribute in [kAXTitleAttribute as String, kAXDescriptionAttribute as String, kAXValueAttribute as String] {
            if let text = copyString(element, attribute), !text.isEmpty {
                blob += (blob.isEmpty ? "" : " ") + text
            }
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            collectText(child, into: &blob, depth: depth + 1)
        }
    }

    /// Diagnostics only — the matched overlay's element tree, so a cleaner close
    /// affordance can be found without needing another live meeting.
    private func dumpSubtree(_ element: AXUIElement, depth: Int, path: String) {
        guard depth < 12 else { return }
        let role = copyString(element, kAXRoleAttribute as String) ?? "?"
        let title = copyString(element, kAXTitleAttribute as String) ?? ""
        let desc = copyString(element, kAXDescriptionAttribute as String) ?? ""
        var actionsRef: CFArray?
        var actions: [String] = []
        if AXUIElementCopyActionNames(element, &actionsRef) == .success, let list = actionsRef as? [String] {
            actions = list
        }
        if !title.isEmpty || !desc.isEmpty || !actions.isEmpty {
            Self.logger.notice("OVERLAYTREE \(path, privacy: .public) role=\(role, privacy: .public) actions=\(actions.joined(separator: "|"), privacy: .public) title=\(title, privacy: .public) desc=\(desc, privacy: .public)")
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for (i, child) in children.enumerated() {
            dumpSubtree(child, depth: depth + 1, path: path + "/\(i)")
        }
    }

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
