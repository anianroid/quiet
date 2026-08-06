import AppKit
import Foundation
import SwiftUI

/// One-time “Quiet owns notes” — turn off host-built-in AI notetakers
/// (Zoom AI Companion, Notion AI notes). Quiet never quits those host apps.
struct HostOwnsNotesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var wisprBusy = false
    var showsContinue: Bool = false
    var onContinue: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Kamui owns notes")
                .font(.title3.weight(.medium))

            Text("Sidecar apps (Granola, Fireflies…) are quit automatically during meetings and free to use otherwise. Zoom and Notion stay open — turn off their built-in Take notes prompts once.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if appState.isZoomInstalled {
                hostCard(
                    title: "Zoom AI Companion",
                    steps: "Open Zoom → Settings → AI Companion → turn off meeting note-taking / “Offer to take notes” (wording varies by Zoom version).",
                    done: appState.hostZoomNotesDisabled,
                    openTitle: "Open Zoom",
                    open: { appState.openZoomForHostSetup() },
                    onMarkDone: { appState.hostZoomNotesDisabled = true },
                    onUndo: { appState.hostZoomNotesDisabled = false }
                )
            }

            if appState.isNotionInstalled {
                hostCard(
                    title: "Notion AI meeting notes",
                    steps: "Open Notion → Settings → Notion AI (or Meetings) → disable meeting notes / auto notetaker prompts if present.",
                    done: appState.hostNotionNotesDisabled,
                    openTitle: "Open Notion",
                    open: { appState.openNotionForHostSetup() },
                    onMarkDone: { appState.hostNotionNotesDisabled = true },
                    onUndo: { appState.hostNotionNotesDisabled = false }
                )
            }

            if appState.isNotionCalendarInstalled {
                hostCard(
                    title: "Notion Calendar Notetaker",
                    steps: "Open Notion Calendar → Settings → Notetaker (or Meetings) → turn off the automatic “Start Notetaker” pill for detected meetings.",
                    done: appState.hostNotionCalendarNotesDisabled,
                    openTitle: "Open Notion Calendar",
                    open: { appState.openNotionCalendarForHostSetup() },
                    onMarkDone: { appState.hostNotionCalendarNotesDisabled = true },
                    onUndo: { appState.hostNotionCalendarNotesDisabled = false }
                )
            }

            if appState.isWisprInstalled {
            wisprCard
        }

        if !appState.isZoomInstalled && !appState.isNotionInstalled
            && !appState.isNotionCalendarInstalled && !appState.isWisprInstalled {
                ContentUnavailableView(
                    "No Zoom or Notion found",
                    systemImage: "checkmark.seal",
                    description: Text("If you install them later, come back here to turn off their built-in Take notes prompts.")
                )
                .frame(maxHeight: 160)
            }

            if appState.hostOwnsNotesComplete {
                Label("Host prompts handled", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.medium))
            }

            Spacer(minLength: 0)

            if showsContinue {
                HStack {
                    Button("Skip for now") { onContinue?() }
                    Spacer()
                    Button(appState.hostOwnsNotesComplete ? "Continue" : "I’ve done this") {
                        appState.markInstalledHostsNotesDone()
                        onContinue?()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// Wispr's step is the one host Quiet can do itself: its meeting
    /// detection lives in a JSON config, so this is a button, not a
    /// walkthrough. Wispr restarts once; dictation is untouched.
    private var wisprCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: appState.wisprNotesSilenced ? "checkmark.circle.fill" : "bell.badge")
                    .foregroundStyle(appState.wisprNotesSilenced ? .green : .orange)
                Text("Wispr Flow Notetaker")
                    .font(.body.weight(.semibold))
                Spacer()
                if appState.wisprNotesSilenced {
                    Text("Done")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            Text("Wispr watches for meetings and pops a “Start Notetaker” pill. Kamui can turn that off in Wispr's own settings — dictation keeps working. Wispr restarts once.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !appState.wisprNotesSilenced {
                Button(wisprBusy ? "Silencing…" : "Silence automatically") {
                    wisprBusy = true
                    Task {
                        await appState.setWisprNotetakerSilenced(true)
                        wisprBusy = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(wisprBusy)
            } else {
                Button("Undo") {
                    wisprBusy = true
                    Task {
                        await appState.setWisprNotetakerSilenced(false)
                        wisprBusy = false
                    }
                }
                .font(.caption)
                .disabled(wisprBusy)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func hostCard(
        title: String,
        steps: String,
        done: Bool,
        openTitle: String,
        open: @escaping () -> Void,
        onMarkDone: @escaping () -> Void,
        onUndo: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: done ? "checkmark.circle.fill" : "bell.badge")
                    .foregroundStyle(done ? .green : .orange)
                Text(title)
                    .font(.body.weight(.semibold))
                Spacer()
                if done {
                    Text("Done")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            Text(steps)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !done {
                HStack {
                    Button(openTitle, action: open)
                    Button("Mark done", action: onMarkDone)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Button("Undo", action: onUndo)
                    .font(.caption)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
