import AppKit
import SwiftUI

/// Classic menu-bar dropdown (not the notch island).
struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(appState.statusMessage)
            .font(.caption)

        if appState.isMeetingActive {
            Text("Meeting: \(appState.currentSession?.sourceApp ?? "active")")
        }

        Divider()

        if appState.isMeetingActive {
            Button("Stop session") {
                Task { await appState.manualStop() }
            }
        } else {
            Button("Mark meeting active") {
                Task { await appState.manualStart() }
            }
        }

        Button("Scan competitors") {
            appState.rescanCompetitors()
            openWindow(id: "settings")
        }

        if appState.latestNotesURL != nil {
            Button("Open latest notes") {
                openWindow(id: "notes")
            }
        }

        Divider()

        Button("Settings…") {
            openWindow(id: "settings")
        }

        if !appState.hostOwnsNotesComplete {
            Button("Quiet owns notes…") {
                openWindow(id: "settings")
            }
        }

        Button("Quit & reopen Quiet") {
            relaunchQuiet()
        }

        Button("Quit Quiet") {
            NSApp.terminate(nil)
        }
    }
}

private func relaunchQuiet() {
    let url = Bundle.main.bundleURL
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NSApp.terminate(nil)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            Form {
                Toggle("Force-quit competing notetakers while Quiet runs", isOn: $appState.quitCompetitorsEnabled)
                Text("Quits Granola / Fireflies / Otter / Fathom (and helpers). Never quits Zoom, Chrome, or Notion.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Dismiss Zoom/notetaker banners in Notification Center", isOn: $appState.dismissBannersEnabled)
                Text("Accessibility, Notification Center only — backup for host Take notes prompts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Auto-capture (experimental — can crash Quiet)", isOn: $appState.autoCaptureEnabled)
                Text("Leave OFF. Silencing works without capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Section("Permissions") {
                    LabeledContent("Screen & System Audio") {
                        Text(appState.permissionSnapshot.screenRecording ? "Granted" : "Missing")
                    }
                    LabeledContent("Microphone") {
                        Text(appState.permissionSnapshot.microphone ? "Granted" : "Missing")
                    }
                    LabeledContent("Accessibility") {
                        Text(appState.permissionSnapshot.accessibility ? "Granted" : "Missing")
                    }
                    Button("Refresh permissions") { appState.refreshPermissions() }
                }

                Section("This session") {
                    if appState.hijackLog.isEmpty {
                        Text("Nothing silenced yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.hijackLog.prefix(12)) { item in
                            Text("\(item.competitorName) — \(item.action)")
                        }
                    }
                }
            }
            .padding()
            .tabItem { Label("General", systemImage: "gear") }

            HostOwnsNotesView(showsContinue: false)
                .padding()
                .tabItem { Label("Host notes", systemImage: "bell.slash") }

            CompetitorScanView(showsContinue: false)
                .padding()
                .tabItem { Label("Competitors", systemImage: "eye") }
                .onAppear { appState.rescanCompetitors() }
        }
        .padding(.top, 8)
    }
}

struct NotesViewer: View {
    @EnvironmentObject private var appState: AppState
    @State private var text = "No notes yet."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Meeting notes")
                    .font(.title2.weight(.semibold))
                Spacer()
                if let url = appState.latestNotesURL {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }

            ScrollView {
                Text(text)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .onAppear(perform: load)
        .onChange(of: appState.latestNotesURL) { _, _ in load() }
    }

    private func load() {
        guard let url = appState.latestNotesURL,
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            if let summary = appState.currentSession?.summary {
                text = summary.overview
            }
            return
        }
        text = contents
    }
}
