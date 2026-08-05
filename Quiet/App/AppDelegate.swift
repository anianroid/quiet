import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var setupWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if !UserDefaults.standard.bool(forKey: "quiet.hasCompletedOnboarding") {
            Task { @MainActor in
                self.presentSetupIfNeeded()
            }
        } else {
            // Confirm relaunch picked up Accessibility / monitoring.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                // Ask macOS to show Quiet in Accessibility if missing.
                let promptKey = "AXTrustedCheckOptionPrompt"
                let opts = [promptKey: true] as CFDictionary
                let ax = AXIsProcessTrustedWithOptions(opts)

                let msg: String
                if ax {
                    if AppState.shared.hostOwnsNotesComplete {
                        msg = "Quiet is armed"
                    } else {
                        msg = "Quiet armed — finish Quiet owns notes in Settings"
                    }
                } else {
                    msg = "Turn ON Quiet in Settings → Privacy & Security → Accessibility"
                }
                AppState.shared.quietBanner.show(message: msg, duration: 5)
                AppState.shared.statusMessage = msg
                AppState.shared.refreshPermissions()
                if ax, AppState.shared.dismissBannersEnabled {
                    AppState.shared.notificationWatcher.start()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            AppState.shared.quietBanner.destroy()
            AppState.shared.notificationWatcher.stop()
        }
    }

    @MainActor
    func presentSetupIfNeeded() {
        if setupWindowController?.window?.isVisible == true { return }

        let root = OnboardingFlow()
            .environmentObject(AppState.shared)
            .frame(minWidth: 520, minHeight: 460)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Quiet Setup"
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        setupWindowController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }
}
