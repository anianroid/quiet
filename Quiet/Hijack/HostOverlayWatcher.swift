import AppKit
import ApplicationServices
import Foundation
import os.log

/// Layer C — dismiss the floating "Start Notetaker" pills that host apps draw
/// themselves (Notion's meeting-detect overlay, Notion Calendar's notetaker
/// pill). These are app windows, not notifications, so Layer B never sees them.
///
/// Deliberately narrow: only the listed host apps, only small floating panels
/// (never a main window), and only when the panel's text is unambiguous
/// notetaker-prompt copy. The host app itself is never quit.
@MainActor
final class HostOverlayWatcher {
    private static let logger = Logger(subsystem: "notes.quiet.app", category: "HostOverlayWatcher")

    /// Hosts known to draw their own meeting-detect overlays.
    private static let watchedBundleIds: Set<String> = [
        "notion.id",           // Notion — "Start AI Meeting Note / Start transcribing"
        "com.cron.electron"    // Notion Calendar — "Meeting detected / Start Notetaker"
    ]

    /// Overlay pills are short; anything taller is a real window we never touch.
    private static let maxOverlayHeight: CGFloat = 260

    /// Unambiguous prompt copy drawn on the overlays themselves.
    private static let overlayPhrases: [String] = [
        "Start AI Meeting Note",
        "Start transcribing",
        "Start Notetaker",
        "Notetaker is ready",
        "Note-taking is available",
        "Meeting detected"
    ]

    private var timer: Timer?
    private var isSweeping = false
    /// Window-created observers per host pid — the instant-suppression path.
    /// The poll timer stays as the safety net for windows the observer misses.
    private var observers: [pid_t: AXObserver] = [:]

    func start() {
        stop()
        Self.logger.notice("HostOverlayWatcher.start axTrusted=\(AXIsProcessTrusted())")
        guard AXIsProcessTrusted() else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
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

    /// Dismissal-on-poll means a pill is visible for up to a second. Observing
    /// AXWindowCreated fires while the overlay is still fading in, so it never
    /// visually lands.
    private func ensureObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }

        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<HostOverlayWatcher>.fromOpaque(refcon).takeUnretainedValue()
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

    /// Observers die with their process — drop entries for quit hosts so a
    /// relaunched app gets a fresh observer on its new pid.
    private func pruneDeadObservers(livePIDs: Set<pid_t>) {
        for pid in observers.keys where !livePIDs.contains(pid) {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
        }
    }

    private func sweep() {
        guard !isSweeping else { return }
        isSweeping = true
        defer { isSweeping = false }

        let debug = UserDefaults.standard.bool(forKey: "quiet.axDump")
        var livePIDs: Set<pid_t> = []
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier, Self.watchedBundleIds.contains(bid) else { continue }
            livePIDs.insert(app.processIdentifier)
            ensureObserver(for: app)
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            // Electron only emits its web-content AX tree when an assistive
            // client asks for it — without this the overlay windows are blank.
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else {
                if debug {
                    Self.logger.notice("OVERLAYDUMP \(bid, privacy: .public): no AX windows")
                }
                continue
            }

            for window in windows {
                let sized = isOverlaySized(window)
                var blob = ""
                collectText(window, into: &blob, depth: 0)
                if debug {
                    let subrole = copyString(window, kAXSubroleAttribute as String) ?? ""
                    Self.logger.notice("OVERLAYDUMP \(bid, privacy: .public) size=\(self.windowSizeDescription(window), privacy: .public) sub=\(subrole, privacy: .public) overlaySized=\(sized) text=\(String(blob.prefix(200)), privacy: .public)")
                }
                guard sized else { continue }
                guard !blob.isEmpty,
                      Self.overlayPhrases.contains(where: { blob.localizedCaseInsensitiveContains($0) }),
                      !blob.localizedCaseInsensitiveContains("Quiet")
                else { continue }

                let closed = dismiss(window)
                Self.logger.notice("Host overlay (\(app.localizedName ?? bid, privacy: .public)) \(closed ? "dismissed" : "matched but not dismissable", privacy: .public): \(String(blob.prefix(120)), privacy: .public)")
            }
        }
        pruneDeadObservers(livePIDs: livePIDs)
    }

    private func windowSizeDescription(_ window: AXUIElement) -> String {
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let value = sizeRef, CFGetTypeID(value) == AXValueGetTypeID() else { return "?" }
        var size = CGSize.zero
        AXValueGetValue(value as! AXValue, .cgSize, &size)
        return "\(Int(size.width))x\(Int(size.height))"
    }

    private func isOverlaySized(_ window: AXUIElement) -> Bool {
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return false
        }
        var size = CGSize.zero
        guard let value = sizeRef, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cgSize, &size) else { return false }
        return size.height > 0 && size.height < Self.maxOverlayHeight
    }

    private func dismiss(_ window: AXUIElement) -> Bool {
        // Named close action on the window itself, a close/dismiss button in
        // the subtree, then AXCancel — in order of least surprising behavior.
        if performNamedCloseAction(on: window) { return true }
        if pressCloseButton(in: window, depth: 0) { return true }
        return AXUIElementPerformAction(window, kAXCancelAction as CFString) == .success
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
                    || label == "×" {
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
        // Electron AX trees nest web content 10+ levels deep — depth must
        // reach through AXWebArea wrappers to the overlay's actual labels.
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

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
