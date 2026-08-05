import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

struct OnboardingFlow: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var step: Step = .welcome

    enum Step {
        case welcome
        case scan
        case permissions
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
        HStack {
            Image(systemName: "waveform.circle.fill")
                .font(.largeTitle)
            VStack(alignment: .leading, spacing: 2) {
                Text("Quiet")
                    .font(.title2.weight(.semibold))
                Text("One notetaker. Zero noise.")
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
            Text("Quiet takes notes on your Mac with Apple speech and Apple Intelligence. On day zero it finds the notetakers you already have and handles them for you — no scavenger hunt in System Settings.")
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
            Text("Quiet lives in the menu bar. When a meeting starts it silences competing notetakers and shows a Quiet · Meeting status in the notch.")
                .foregroundStyle(.secondary)

            if !appState.installedCompetitors.isEmpty {
                Text("We’ll handle: " + appState.installedCompetitors.map(\.entry.name).joined(separator: ", "))
                    .font(.callout.weight(.medium))
            }

            Spacer()

            Button("Open Quiet") {
                appState.completeOnboarding()
                for window in NSApp.windows where window.title == "Quiet Setup" {
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

            Text("Quiet scanned for known meeting notetakers on this Mac.")
                .foregroundStyle(.secondary)

            if appState.installedCompetitors.isEmpty {
                ContentUnavailableView(
                    "No competing notetakers found",
                    systemImage: "checkmark.seal",
                    description: Text("If you install Otter, Fireflies, Granola, and friends later, Quiet will handle them during meetings. You can re-scan anytime in Settings.")
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
            return "Force-quit while Quiet runs · \(item.displayDetail)"
        case .quitOnQuietLaunch:
            return "Will quit when Quiet launches · \(item.displayDetail)"
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
            Text("Permissions for Quiet only")
                .font(.title3.weight(.medium))
            Text("Grant these once to Quiet. You don’t need to open notification settings for Otter, Zoom, or Chrome.")
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
