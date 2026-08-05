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

    func start() {
        stop()
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
    }

    private func sweep() {
        guard !isSweeping else { return }
        isSweeping = true
        defer { isSweeping = false }

        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier, Self.watchedBundleIds.contains(bid) else { continue }
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else { continue }

            for window in windows {
                guard isOverlaySized(window) else { continue }
                var blob = ""
                collectText(window, into: &blob, depth: 0)
                guard !blob.isEmpty,
                      Self.overlayPhrases.contains(where: { blob.localizedCaseInsensitiveContains($0) }),
                      !blob.localizedCaseInsensitiveContains("Quiet")
                else { continue }

                let closed = dismiss(window)
                Self.logger.notice("Host overlay (\(app.localizedName ?? bid, privacy: .public)) \(closed ? "dismissed" : "matched but not dismissable", privacy: .public): \(String(blob.prefix(120)), privacy: .public)")
            }
        }
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
        guard depth < 6 else { return false }
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
        guard depth < 6, blob.count < 600 else { return }
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
