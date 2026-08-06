import AppKit
import CoreGraphics
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

        if appState.isPaused {
            if let until = appState.pausedUntil {
                Text("Paused until \(until.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
            }
            Button("Resume now") {
                appState.resumeNow()
            }
        } else {
            Button("Pause Kamui for 1 hour") {
                appState.pause()
            }
        }

        Divider()

        Button("Settings…") {
            openWindow(id: "settings")
        }

        if !appState.hostOwnsNotesComplete {
            Button("Kamui owns notes…") {
                openWindow(id: "settings")
            }
        }

        Button("Quit & reopen Kamui") {
            relaunchQuiet()
        }

        Button("Quit Kamui") {
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
                Toggle("Freeze competing notetakers during meetings", isOn: $appState.quitCompetitorsEnabled)
                Text("Freezes Granola / Fireflies / Otter / Fathom (and helpers) for the call, then resumes them. Nothing is quit; Zoom, Chrome, and Notion are never touched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Dismiss Zoom/notetaker banners in Notification Center", isOn: $appState.dismissBannersEnabled)
                Text("Also hides in-app pills (Notion, Wispr). Needs Accessibility; Screen Recording helps for AX-blind apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Take notes during meetings (beta)", isOn: $appState.autoCaptureEnabled)
                Text("On-device transcription and summaries — audio never leaves this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SpeechModelRow()

                Section("Permissions") {
                    LabeledContent("Screen & System Audio") {
                        Text(appState.permissionSnapshot.screenRecording ? "Granted" : "Missing — needed to hide Wispr pills")
                    }
                    LabeledContent("Microphone") {
                        Text(appState.permissionSnapshot.microphone ? "Granted" : "Missing")
                    }
                    LabeledContent("Accessibility") {
                        Text(appState.permissionSnapshot.accessibility ? "Granted" : "Missing")
                    }
                    Button("Refresh permissions") { appState.refreshPermissions() }
                    if !appState.permissionSnapshot.screenRecording {
                        Button("Grant Screen Recording") {
                            CGRequestScreenCaptureAccess()
                            appState.refreshPermissions()
                        }
                    }
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

/// Settings row for the on-device speech model: shows the installed state and
/// drives the download with progress when the model is missing.
private struct SpeechModelRow: View {
    @State private var assetState: TranscriptionAssets.State?
    @State private var progress: Double = 0
    @State private var errorText: String?

    var body: some View {
        LabeledContent("Speech model") {
            switch assetState {
            case nil:
                Text("Checking…")
                    .foregroundStyle(.secondary)
            case .installed:
                Text("Installed")
            case .unavailable:
                Text("Not available on this Mac")
                    .foregroundStyle(.secondary)
            case .unsupportedLocale:
                Text("Language not supported yet")
                    .foregroundStyle(.secondary)
            case .downloading:
                ProgressView(value: progress)
                    .frame(width: 140)
            case .notInstalled:
                Button("Download") {
                    Task { await download() }
                }
            }
        }
        .task {
            assetState = await TranscriptionAssets.state()
        }

        if let errorText {
            Text(errorText)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func download() async {
        assetState = .downloading
        progress = 0
        errorText = nil
        do {
            // Capture only the (Sendable) binding — the view struct itself is not.
            let progressBinding = $progress
            try await TranscriptionAssets.ensureInstalled { value in
                Task { @MainActor in progressBinding.wrappedValue = value }
            }
            assetState = .installed
        } catch {
            errorText = error.localizedDescription
            assetState = await TranscriptionAssets.state()
        }
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
