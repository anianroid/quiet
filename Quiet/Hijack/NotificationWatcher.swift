import AppKit
import ApplicationServices
import Foundation

/// Layer B — dismiss competing **notetaker banners only**.
/// Deliberately narrow: never walk Zoom/Chrome/System Settings UI trees.
@MainActor
final class NotificationWatcher {
    private let catalog: CompetitorCatalog
    private var timer: Timer?
    private var patterns: [String] = []
    private var isSweeping = false

    /// Precise notetaker-prompt copy. Avoid lone vendor names that match unrelated banners.
    private static let builtinPatterns: [String] = [
        "Meeting detected",
        "Start Notetaker",
        "Note-taking is available",
        "Start note taker",
        "Notetaker is ready",
        "Take notes with",
        "Take notes",
        "AI Companion",
        "Start taking notes",
        "Meeting notes"
    ]

    init(catalog: CompetitorCatalog) {
        self.catalog = catalog
        let catalogPrecise = catalog.dismissPatterns.filter { pattern in
            let p = pattern.lowercased()
            return p.contains("meeting detected")
                || p.contains("notetaker")
                || p.contains("note-taking is available")
                || p.contains("take notes")
                || p.contains("start notetaker")
                || p.contains("ai companion")
                || p.contains("meeting notes")
                || p.contains("start taking notes")
        }
        self.patterns = Array(Set(Self.builtinPatterns + catalogPrecise))
    }

    func start() {
        stop()
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
            let element = AXUIElementCreateApplication(app.processIdentifier)
            dismissMatchingBanners(in: element, depth: 0)
        }
    }

    private func dismissMatchingBanners(in element: AXUIElement, depth: Int) {
        guard depth < 6 else { return }

        let blob = elementTextBlob(element)
        if !blob.isEmpty, isNotetakerPrompt(blob), !blob.localizedCaseInsensitiveContains("Quiet") {
            _ = pressCloseButton(in: element)
            AXUIElementPerformAction(element, kAXCancelAction as CFString)
            return
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            dismissMatchingBanners(in: child, depth: depth + 1)
        }
    }

    private func isNotetakerPrompt(_ text: String) -> Bool {
        patterns.contains { text.localizedCaseInsensitiveContains($0) }
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
