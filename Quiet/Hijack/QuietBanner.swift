import AppKit
import SwiftUI

/// Notch island for Quiet — one persistent surface that morphs between states
/// (toast, meeting, recording, keep/discard) instead of swapping views, so
/// every change is a continuous spring morph the way the hardware island moves.
/// Intentionally no screen-parameter observers (those can re-enter on
/// `setFrame` and peg the CPU).
@MainActor
final class QuietBannerController {
    private var panel: NSPanel?
    private let model = IslandModel()
    private var hideWork: DispatchWorkItem?
    private var orderOutWork: DispatchWorkItem?
    private var isPersistent = false

    /// Resolves the pending Keep/Discard prompt, if one is showing.
    /// Nil'd before invocation so exactly one outcome ever fires.
    private var pendingKeepDiscard: ((_ keep: Bool) -> Void)?

    /// Brief toast (launch messages, “Notes saved”). Auto-hides.
    func show(message: String, duration: TimeInterval = 5) {
        resolvePendingAsKeep()
        isPersistent = false
        present(.toast(message: message))

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPersistent else { return }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Persistent island while a meeting is active. Call `hide()` on meeting end.
    /// `capturing` switches the passive guard state into the live recording
    /// state — animated level bars, pulsing record dot, elapsed timer.
    func showMeetingStatus(message: String = "Quiet · Meeting", capturing: Bool = false) {
        resolvePendingAsKeep()
        hideWork?.cancel()
        hideWork = nil
        isPersistent = true
        // The timer anchors to the first moment the meeting surfaced, surviving
        // guard → recording transitions.
        if !model.state.isMeeting {
            model.meetingStartedAt = Date()
        }
        present(.meeting(capturing: capturing))
    }

    /// Interactive post-call island with Keep / Discard buttons. Exactly one
    /// callback fires: Keep or Discard on click, or Keep automatically at the
    /// deadline — keep is the default, so notes are never stranded in staging
    /// by an unanswered prompt. The deadline is drawn as a depleting ring so
    /// the default outcome is visible, not a surprise.
    func showKeepDiscard(
        message: String,
        autoKeepAfter: TimeInterval = 60,
        onKeep: @escaping () -> Void,
        onDiscard: @escaping () -> Void
    ) {
        resolvePendingAsKeep()
        hideWork?.cancel()
        hideWork = nil
        isPersistent = true

        pendingKeepDiscard = { keep in
            if keep { onKeep() } else { onDiscard() }
        }
        model.onKeep = { [weak self] in self?.resolveKeepDiscard(keep: true) }
        model.onDiscard = { [weak self] in self?.resolveKeepDiscard(keep: false) }
        present(.keepDiscard(message: message, deadline: Date().addingTimeInterval(autoKeepAfter)))

        let work = DispatchWorkItem { [weak self] in
            guard let self, let resolve = self.pendingKeepDiscard else { return }
            self.pendingKeepDiscard = nil
            self.hideWork = nil
            // No response — keep is the default; collapse the island, then fire
            // Keep (after the collapse, so a "Notes saved" toast doesn't fight
            // the animation).
            self.collapse { resolve(true) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoKeepAfter, execute: work)
    }

    func hide() {
        // A still-pending prompt resolves as Keep, never silently drops.
        resolvePendingAsKeep()
        hideWork?.cancel()
        hideWork = nil
        isPersistent = false
        collapse()
    }

    /// Tear down completely (call on quit).
    func destroy() {
        hide()
        orderOutWork?.cancel()
        panel?.close()
        panel = nil
    }

    /// Button press on the Keep/Discard island: hide, then fire the outcome.
    /// The pending closure is taken out first so `hide()` can't resolve it as
    /// Keep, and firing last lets the outcome present its own toast cleanly.
    private func resolveKeepDiscard(keep: Bool) {
        guard let resolve = pendingKeepDiscard else { return }
        pendingKeepDiscard = nil
        hideWork?.cancel()
        hideWork = nil
        isPersistent = false
        collapse()
        resolve(keep)
    }

    /// Any newly presented state (next meeting starting, a toast) resolves a
    /// still-pending prompt as Keep so staged notes are never orphaned.
    private func resolvePendingAsKeep() {
        guard let resolve = pendingKeepDiscard else { return }
        pendingKeepDiscard = nil
        resolve(true)
    }

    /// Retracts the island back into the notch (spatial consistency: it leaves
    /// the way it arrived), then orders the panel out once the motion settles.
    private func collapse(then completion: (() -> Void)? = nil) {
        model.state = .hidden
        orderOutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
            completion?()
        }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func present(_ state: IslandState) {
        if panel == nil {
            createPanel()
        }
        guard let panel else { return }

        orderOutWork?.cancel()
        orderOutWork = nil
        position(panel)
        // Interactive only when there is something to press — passive states
        // must never swallow clicks near the notch.
        panel.ignoresMouseEvents = !state.isInteractive
        model.state = state
        panel.orderFrontRegardless()
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: IslandMetrics.panelWidth, height: IslandMetrics.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The island draws its own SwiftUI shadow — a window shadow on a mostly
        // transparent panel leaves ghost rectangles during morphs.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        // Keep/Discard buttons need clicks; `.nonactivatingPanel` (above) keeps
        // those clicks from stealing focus from the meeting app.
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = FirstMouseHostingView(rootView: IslandRootView(model: model))
        self.panel = panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let full = screen.frame
        let x = full.midX - IslandMetrics.panelWidth / 2
        let y = full.maxY - IslandMetrics.panelHeight
        panel.setFrame(NSRect(x: x, y: y, width: IslandMetrics.panelWidth, height: IslandMetrics.panelHeight), display: true)
    }
}

/// Hosting view that accepts the first click even though the panel never becomes
/// key — without this the first press on Keep/Discard would be swallowed.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - State

enum IslandState: Equatable {
    case hidden
    case toast(message: String)
    case meeting(capturing: Bool)
    case keepDiscard(message: String, deadline: Date)

    var isMeeting: Bool {
        if case .meeting = self { return true }
        return false
    }

    var isInteractive: Bool {
        if case .keepDiscard = self { return true }
        return false
    }
}

@MainActor
final class IslandModel: ObservableObject {
    @Published var state: IslandState = .hidden
    var meetingStartedAt: Date?
    var onKeep: (() -> Void)?
    var onDiscard: (() -> Void)?
}

enum IslandMetrics {
    static let panelWidth: CGFloat = 480
    static let panelHeight: CGFloat = 150
}

// MARK: - Root view

/// One island, four states. The shape morphs between them with a spring —
/// slight bounce, because a state change is an arrival — and content
/// cross-fades with a scale so text never slides through the black.
struct IslandRootView: View {
    @ObservedObject var model: IslandModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var morph: Animation {
        reduceMotion
            ? .easeOut(duration: 0.18)
            : .spring(response: 0.42, dampingFraction: 0.78)
    }

    var body: some View {
        let topInset = NSScreen.main?.safeAreaInsets.top ?? 0
        let hasNotch = topInset > 0

        ZStack(alignment: .top) {
            if model.state != .hidden {
                IslandSurface(hasNotch: hasNotch, topInset: topInset, state: model.state) {
                    content
                }
                .transition(
                    reduceMotion
                        ? .opacity
                        : .scale(scale: 0.4, anchor: .top).combined(with: .opacity)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(morph, value: model.state)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .hidden:
            EmptyView()
        case .toast(let message):
            ToastContent(message: message)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        case .meeting(let capturing):
            MeetingContent(capturing: capturing, startedAt: model.meetingStartedAt)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        case .keepDiscard(let message, let deadline):
            KeepDiscardContent(
                message: message,
                deadline: deadline,
                onKeep: { model.onKeep?() },
                onDiscard: { model.onDiscard?() }
            )
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}

/// The black surface itself. On notch screens the top edge is square so it
/// reads as the notch extending; elsewhere it is a floating capsule-ish card.
/// A faint top highlight catches light the way real hardware glass does.
private struct IslandSurface<Content: View>: View {
    let hasNotch: Bool
    let topInset: CGFloat
    let state: IslandState
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.top, hasNotch ? topInset + 4 : 10)
            .padding(.bottom, 10)
            .background {
                UnevenRoundedRectangle(
                    topLeadingRadius: hasNotch ? 0 : 18,
                    bottomLeadingRadius: 20,
                    bottomTrailingRadius: 20,
                    topTrailingRadius: hasNotch ? 0 : 18,
                    style: .continuous
                )
                .fill(.black)
                .overlay {
                    UnevenRoundedRectangle(
                        topLeadingRadius: hasNotch ? 0 : 18,
                        bottomLeadingRadius: 20,
                        bottomTrailingRadius: 20,
                        topTrailingRadius: hasNotch ? 0 : 18,
                        style: .continuous
                    )
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.14), .white.opacity(0.03), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
                }
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
            }
            .fixedSize()
    }
}

// MARK: - State content

private struct ToastContent: View {
    let message: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
            Text(message)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: 360)
    }
}

/// Live meeting status: guard mode is calm (still bars, soft green dot);
/// recording mode is alive (dancing bars, breathing red dot, elapsed time).
private struct MeetingContent: View {
    let capturing: Bool
    let startedAt: Date?

    var body: some View {
        HStack(spacing: 9) {
            StatusDot(recording: capturing)
            Text("Quiet")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            WaveformBars(active: capturing)
            if let startedAt {
                ElapsedTime(since: startedAt)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Green = guarding (competitors silenced, nothing recorded).
/// Red + breathing glow = audio is being captured. The distinction is the
/// honest part of the design: recording never looks idle.
private struct StatusDot: View {
    let recording: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !recording || reduceMotion)) { context in
            let phase = (sin(context.date.timeIntervalSinceReferenceDate * (2 * .pi / 1.8)) + 1) / 2
            let pulse = recording && !reduceMotion ? phase : 1
            Circle()
                .fill(recording ? Color(red: 1.0, green: 0.23, blue: 0.19) : Color(red: 0.2, green: 0.84, blue: 0.29))
                .frame(width: 7, height: 7)
                .opacity(recording ? 0.55 + 0.45 * pulse : 1)
                .scaleEffect(recording ? 0.85 + 0.3 * pulse : 1)
                .shadow(
                    color: (recording ? Color.red : .green).opacity(recording ? 0.5 * pulse : 0.35),
                    radius: recording ? 4 : 2.5
                )
        }
        .frame(width: 10, height: 10)
        .accessibilityLabel(recording ? "Recording" : "Guarding")
    }
}

/// Five capsule bars. Recording: each dances on its own sine phase, like a
/// level meter. Idle/reduced motion: a still, quiet waveform.
private struct WaveformBars: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let stillHeights: [CGFloat] = [5, 9, 12, 8, 5]
    private static let phases: [Double] = [0.0, 1.3, 2.6, 0.7, 1.9]
    private static let speeds: [Double] = [7.1, 8.3, 6.2, 9.0, 7.7]

    var body: some View {
        let animating = active && !reduceMotion
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(active ? Color.white : Color.white.opacity(0.45))
                        .frame(width: 2.5, height: height(bar: i, time: t, animating: animating))
                }
            }
        }
        .frame(height: 14)
    }

    private func height(bar: Int, time: TimeInterval, animating: Bool) -> CGFloat {
        guard animating else { return Self.stillHeights[bar] }
        let wave = (sin(time * Self.speeds[bar] + Self.phases[bar]) + 1) / 2
        return 4 + wave * 10
    }
}

private struct ElapsedTime: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(since)))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.65))
                .contentTransition(.numericText())
        }
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

/// Post-call prompt: gist line, then Discard / Keep. The ring around Keep
/// depletes toward the auto-keep deadline — the default action is shown, not
/// sprung on the user.
private struct KeepDiscardContent: View {
    let message: String
    let deadline: Date
    let onKeep: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                Text(message)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: 380)

            HStack(spacing: 8) {
                IslandButton(prominent: false, action: onDiscard) {
                    Text("Discard")
                }
                IslandButton(prominent: true, action: onKeep) {
                    HStack(spacing: 6) {
                        AutoKeepRing(deadline: deadline)
                        Text("Keep")
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct IslandButton<Label: View>: View {
    let prominent: Bool
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var isPressed = false

    var body: some View {
        label
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(prominent ? .black : .white.opacity(0.85))
            .padding(.horizontal, prominent ? 16 : 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(prominent ? Color.white : Color.white.opacity(0.14)))
            // Feedback on press-down, not on release.
            .scaleEffect(isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 1.0), value: isPressed)
            .contentShape(Capsule())
            .onLongPressGesture(
                minimumDuration: .infinity,
                perform: {},
                onPressingChanged: { pressing in
                    isPressed = pressing
                    if !pressing { action() }
                }
            )
            .accessibilityAddTraits(.isButton)
    }
}

/// Thin ring that empties as the auto-keep deadline approaches.
private struct AutoKeepRing: View {
    let deadline: Date
    /// Matches the controller's default auto-keep window.
    private static let total: TimeInterval = 60

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let remaining = max(0, deadline.timeIntervalSince(context.date))
            let progress = min(1, remaining / Self.total)
            ZStack {
                Circle()
                    .stroke(Color.black.opacity(0.15), lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.black.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 11, height: 11)
        }
        .accessibilityHidden(true)
    }
}
