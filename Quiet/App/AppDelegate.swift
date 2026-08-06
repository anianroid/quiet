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
                    msg = AppState.shared.hostOwnsNotesComplete
                        ? "Armed"
                        : "Armed — finish setup in Settings"
                } else {
                    msg = "Turn on Kamui in System Settings → Accessibility"
                }
                AppState.shared.quietBanner.show(message: msg, duration: 5)
                AppState.shared.statusMessage = msg
                AppState.shared.refreshPermissions()
                // startMonitoring already armed both watchers; this re-asserts
                // Notification Center after the Accessibility prompt settles.
                if ax, AppState.shared.dismissBannersEnabled {
                    AppState.shared.notificationWatcher.start()
                    AppState.shared.hostOverlayWatcher.start()
                }

                // Screen Recording backs both note capture and reading prompts
                // that expose no Accessibility text. macOS silently invalidates
                // the grant whenever the binary changes, so ask again when the
                // preflight says it is missing.
                if !CGPreflightScreenCaptureAccess() {
                    CGRequestScreenCaptureAccess()
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
        window.title = "Kamui Setup"
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        setupWindowController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }
}
