import SwiftUI

@main
struct QuietApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        // Classic menu-bar icon (always visible in the menu bar, separate from notch UI).
        MenuBarExtra("Quiet", systemImage: appState.menuBarSymbolName) {
            MenuBarView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.menu)

        Window("Quiet Setup", id: "onboarding") {
            OnboardingFlow()
                .environmentObject(appState)
                .frame(minWidth: 520, minHeight: 460)
        }

        Window("Quiet Settings", id: "settings") {
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
}
