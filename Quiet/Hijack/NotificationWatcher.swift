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

    /// Vendor identity markers, matched as whole-word token subsequences.
    /// Derived from the catalog (entry names + notification title patterns)
    /// plus a builtin seed so an empty catalog still covers the big names.
    private let vendorMarkers: [String]

    /// Generic notetaker-prompt copy. Never sufficient alone — a vendor marker
    /// must also be present in the banner text before we dismiss.
    private static let genericPhrases: [String] = [
        "Meeting detected",
        "Start Notetaker",
        "Note-taking is available",
        "Start note taker",
        "Notetaker is ready",
        "Take notes with",
        "Take notes",
        "Start taking notes",
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
            Self.logger.info("Dismissing notetaker banner: \(String(blob.prefix(120)), privacy: .public)")
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

    /// A banner is a notetaker prompt only when a generic phrase AND a vendor
    /// marker are both present. "Meeting notes" alone is never dismissed.
    func isNotetakerPrompt(_ text: String) -> Bool {
        guard Self.genericPhrases.contains(where: { text.localizedCaseInsensitiveContains($0) }) else {
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
