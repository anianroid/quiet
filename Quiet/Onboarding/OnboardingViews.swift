import AppKit
import ApplicationServices
import AVFoundation
import FoundationModels
import SwiftUI

struct OnboardingFlow: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var step: Step = .welcome

    enum Step {
        case welcome
        case scan
        case permissions
        case speechModel
        case hostOwnsNotes
        case done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case .welcome:
                    welcome
                case .scan:
                    CompetitorScanView(showsContinue: true) {
                        step = .permissions
                    }
                case .permissions:
                    PermissionsView {
                        step = .speechModel
                    }
                case .speechModel:
                    SpeechModelSetupView {
                        step = .hostOwnsNotes
                    }
                case .hostOwnsNotes:
                    HostOwnsNotesView(showsContinue: true) {
                        step = .done
                    }
                case .done:
                    done
                }
            }
            .padding(24)
            Spacer(minLength: 0)
        }
        .onAppear {
            appState.rescanCompetitors()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            KamuiMark(size: 36, ambient: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Kamui")
                    .font(.title2.weight(.semibold))
                Text("Sends every other notetaker to another dimension.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Meetings shouldn’t open three notetakers.")
                .font(.title3.weight(.medium))
            Text("Kamui takes notes on your Mac with Apple speech and Apple Intelligence. On day zero it finds the notetakers you already have and handles them for you — no scavenger hunt in System Settings.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button("Scan my Mac") {
                appState.rescanCompetitors()
                step = .scan
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("You’re set")
                .font(.title3.weight(.medium))
            Text("Kamui lives in the menu bar. When a meeting starts it silences competing notetakers and shows a Kamui · Meeting status in the notch.")
                .foregroundStyle(.secondary)

            if !appState.installedCompetitors.isEmpty {
                Text("We’ll handle: " + appState.installedCompetitors.map(\.entry.name).joined(separator: ", "))
                    .font(.callout.weight(.medium))
            }

            Spacer()

            Button("Open Kamui") {
                appState.completeOnboarding()
                for window in NSApp.windows where window.title == "Kamui Setup" {
                    window.close()
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }
}

struct CompetitorScanView: View {
    @EnvironmentObject private var appState: AppState
    var showsContinue: Bool = true
    var onContinue: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("We’ll handle")
                .font(.title3.weight(.medium))

            Text("Kamui scanned for known meeting notetakers on this Mac.")
                .foregroundStyle(.secondary)

            if appState.installedCompetitors.isEmpty {
                ContentUnavailableView(
                    "No competing notetakers found",
                    systemImage: "checkmark.seal",
                    description: Text("If you install Otter, Fireflies, Granola, and friends later, Kamui will handle them during meetings. You can re-scan anytime in Settings.")
                )
                .frame(maxHeight: 220)
            } else {
                List(appState.installedCompetitors) { item in
                    HStack {
                        Image(systemName: item.entry.policy == .ignore ? "bell.badge" : "xmark.circle")
                            .foregroundStyle(item.entry.policy == .ignore ? .orange : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.entry.name)
                                .font(.body.weight(.medium))
                            Text(detail(for: item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(item.isRunning ? "Running" : "Installed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 180, maxHeight: 260)
                .listStyle(.inset)
            }

            HStack {
                Button("Scan again") {
                    appState.rescanCompetitors()
                }
                Spacer()
                if showsContinue {
                    Button("Looks good") {
                        onContinue?()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func detail(for item: InstalledCompetitor) -> String {
        switch item.entry.policy {
        case .suspendDuringMeeting:
            return "Quit during meetings · \(item.displayDetail)"
        case .quitOnQuietLaunch:
            return "Will quit when Kamui launches · \(item.displayDetail)"
        case .ignore:
            return "Host kept open; turn off built-in notes once · \(item.displayDetail)"
        }
    }
}

struct PermissionsView: View {
    @EnvironmentObject private var appState: AppState
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions for Kamui only")
                .font(.title3.weight(.medium))
            Text("Grant these once to Kamui. You don’t need to open notification settings for Otter, Zoom, or Chrome.")
                .foregroundStyle(.secondary)

            permissionRow(
                title: "Screen & System Audio",
                subtitle: "Hear the meeting without joining as a bot",
                ok: appState.permissionSnapshot.screenRecording,
                actionTitle: "Enable"
            ) {
                _ = CGRequestScreenCaptureAccess()
                appState.refreshPermissions()
            }

            permissionRow(
                title: "Microphone",
                subtitle: "Include what you say in the transcript",
                ok: appState.permissionSnapshot.microphone,
                actionTitle: "Enable"
            ) {
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    Task { @MainActor in appState.refreshPermissions() }
                }
            }

            permissionRow(
                title: "Accessibility",
                subtitle: "Dismiss competing “Start Notetaker” banners",
                ok: appState.permissionSnapshot.accessibility,
                actionTitle: "Open Settings"
            ) {
                let promptKey = "AXTrustedCheckOptionPrompt"
                let opts = [promptKey: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
                appState.refreshPermissions()
            }

            Spacer()

            HStack {
                Button("Refresh") { appState.refreshPermissions() }
                Spacer()
                Button("Continue") { onContinue() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { appState.refreshPermissions() }
    }

    private func permissionRow(
        title: String,
        subtitle: String,
        ok: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok {
                Button(actionTitle, action: action)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SpeechModelSetupView: View {
    var onContinue: () -> Void

    @State private var phase: Phase = .checking
    @State private var progress: Double = 0
    @State private var appleIntelligenceAvailable = true

    enum Phase: Equatable {
        case checking
        case downloading
        case installed
        case unavailable
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download the speech model")
                .font(.title3.weight(.medium))
            Text("Kamui transcribes on this Mac — audio never touches a server. One download now means your first meeting works even offline.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            statusRow

            if !appleIntelligenceAvailable {
                Label(
                    "Turn on Apple Intelligence for summaries — transcripts work either way.",
                    systemImage: "sparkles"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                if case .failed = phase {
                    Button("Try again") {
                        Task { await download() }
                    }
                }
                Spacer()
                Button("Continue") { onContinue() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(phase == .checking || phase == .downloading)
            }
        }
        .task {
            if case .available = SystemLanguageModel.default.availability {
                appleIntelligenceAvailable = true
            } else {
                appleIntelligenceAvailable = false
            }
            await download()
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch phase {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking installed models…").foregroundStyle(.secondary)
            }
        case .downloading:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                Text("Downloading the on-device speech model…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .installed:
            Label("Speech model ready — transcription works offline.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .unavailable:
            Label("On-device transcription isn’t available for your language yet. Kamui still silences competitors during meetings.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .failed(let detail):
            Label("Download failed: \(detail)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func download() async {
        switch await TranscriptionAssets.state() {
        case .installed:
            phase = .installed
            return
        case .unavailable, .unsupportedLocale:
            phase = .unavailable
            return
        case .notInstalled, .downloading:
            break
        }

        phase = .downloading
        do {
            // Capture only the (Sendable) binding — the view struct itself is not.
            let progressBinding = $progress
            try await TranscriptionAssets.ensureInstalled { value in
                Task { @MainActor in progressBinding.wrappedValue = value }
            }
            phase = .installed
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
