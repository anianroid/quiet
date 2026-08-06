import AppKit
import SwiftUI

@main
struct QuietApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        // Classic menu-bar icon (always visible in the menu bar, separate from notch UI).
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(nsImage: menuBarIcon)
        }
        .menuBarExtraStyle(.menu)

        Window("Kamui Setup", id: "onboarding") {
            OnboardingFlow()
                .environmentObject(appState)
                .frame(minWidth: 520, minHeight: 460)
        }

        Window("Kamui Settings", id: "settings") {
            SettingsView()
                .environmentObject(appState)
                .frame(minWidth: 520, minHeight: 420)
        }

        Window("Meeting Notes", id: "notes") {
            NotesViewer()
                .environmentObject(appState)
                .frame(minWidth: 560, minHeight: 420)
        }
    }

    private var menuBarIcon: NSImage {
        if appState.isPaused { return MenuBarIcon.paused }
        if appState.isCapturing { return MenuBarIcon.capturing }
        return MenuBarIcon.normal
    }
}

/// Menu bar renditions of the mark — the one place it stays full-color, it IS
/// the brand. Paused dims it; capturing adds a red dot so recording is never
/// invisible even with the notch island out of view.
private enum MenuBarIcon {
    static let normal = make(alpha: 1, recordingDot: false)
    static let paused = make(alpha: 0.4, recordingDot: false)
    static let capturing = make(alpha: 1, recordingDot: true)

    private static func make(alpha: CGFloat, recordingDot: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSImage(named: "KamuiMark")?.draw(
                in: rect.insetBy(dx: 0.5, dy: 0.5),
                from: .zero,
                operation: .sourceOver,
                fraction: alpha
            )
            if recordingDot {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 6, y: 0, width: 6, height: 6)).fill()
            }
            return true
        }
        // Full-color on purpose — template rendering would flatten the mark
        // into a black disc.
        image.isTemplate = false
        return image
    }
}
