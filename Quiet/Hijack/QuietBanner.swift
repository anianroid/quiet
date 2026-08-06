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
    func showMeetingStatus(message: String = "Kamui · Meeting", capturing: Bool = false) {
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
    static let panelWidth: CGFloat = 620
    static let panelHeight: CGFloat = 170
}

/// The physical notch, so the island can wrap it instead of hanging below it.
/// `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` are the menu-bar strips either
/// side of the notch; what they don't cover is the notch itself.
struct NotchGeometry {
    let width: CGFloat
    let height: CGFloat
    var hasNotch: Bool { width > 0 && height > 0 }

    static var current: NotchGeometry {
        guard let screen = NSScreen.main,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else {
            return NotchGeometry(width: 0, height: 0)
        }
        let width = screen.frame.width - left.width - right.width
        guard width > 1 else { return NotchGeometry(width: 0, height: 0) }
        return NotchGeometry(width: width, height: screen.safeAreaInsets.top)
    }

    /// Menu bar height on the current screen — the compact meeting bar must
    /// be exactly this tall on displays without a notch. Falls back to the
    /// status bar thickness when the menu bar is set to auto-hide.
    static var menuBarHeight: CGFloat {
        guard let screen = NSScreen.main else { return 24 }
        let height = screen.frame.maxY - screen.visibleFrame.maxY
        return height > 1 ? height : NSStatusBar.system.thickness
    }
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
        let notch = NotchGeometry.current

        ZStack(alignment: .top) {
            if model.state != .hidden {
                surface(notch: notch)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .scale(scale: 0.55, anchor: .top).combined(with: .opacity)
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(morph, value: model.state)
    }

    /// Compact states wrap the notch: content sits in the ears either side of
    /// it, at exactly notch height, so the hardware cutout appears to widen
    /// rather than gain a tab beneath it. Expanded states grow downward from
    /// that same surface.
    @ViewBuilder
    private func surface(notch: NotchGeometry) -> some View {
        switch model.state {
        case .hidden:
            EmptyView()

        case .meeting(let capturing):
            if notch.hasNotch {
                NotchWrapSurface(notch: notch) {
                    HStack(spacing: 7) {
                        if capturing {
                            StatusDot(recording: true)
                        }
                        WaveformBars(active: capturing)
                    }
                } trailing: {
                    if let startedAt = model.meetingStartedAt {
                        ElapsedTime(since: startedAt)
                    }
                }
            } else {
                MenuBarSurface {
                    MeetingContent(capturing: capturing, startedAt: model.meetingStartedAt)
                }
            }

        case .toast(let message):
            ExpandedSurface(notch: notch) {
                ToastContent(message: message)
            }

        case .keepDiscard(let message, let deadline):
            ExpandedSurface(notch: notch) {
                KeepDiscardContent(
                    message: message,
                    deadline: deadline,
                    onKeep: { model.onKeep?() },
                    onDiscard: { model.onDiscard?() }
                )
            }
        }
    }
}

/// Black surface flush to the top of the display, spanning the notch plus an
/// ear on each side. Bottom corners are rounded, top corners square, and the
/// notch column is left empty — the hardware is already black there, so the
/// result reads as one continuous cutout.
private struct NotchWrapSurface<Leading: View, Trailing: View>: View {
    let notch: NotchGeometry
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            leading
                .padding(.leading, 14)
                .padding(.trailing, 10)
            Color.clear.frame(width: notch.width)
            trailing
                .padding(.leading, 10)
                .padding(.trailing, 14)
        }
        .frame(height: notch.height)
        .background {
            UnevenRoundedRectangle(
                bottomLeadingRadius: 14,
                bottomTrailingRadius: 14,
                style: .continuous
            )
            .fill(.black)
            .overlay {
                UnevenRoundedRectangle(
                    bottomLeadingRadius: 14,
                    bottomTrailingRadius: 14,
                    style: .continuous
                )
                .strokeBorder(
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.10)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
            }
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        }
        .fixedSize()
    }
}

/// Compact meeting bar for displays without a notch: exactly menu-bar height,
/// flush to the top edge with square shoulders and rounded feet — the same
/// silhouette as the notch ears, without a notch to wrap.
private struct MenuBarSurface<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 14)
            .frame(height: NotchGeometry.menuBarHeight)
            .background {
                UnevenRoundedRectangle(
                    bottomLeadingRadius: 14,
                    bottomTrailingRadius: 14,
                    style: .continuous
                )
                .fill(.black)
                .overlay {
                    UnevenRoundedRectangle(
                        bottomLeadingRadius: 14,
                        bottomTrailingRadius: 14,
                        style: .continuous
                    )
                    .strokeBorder(
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.10)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
                }
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            }
            .fixedSize()
    }
}

/// Taller states. On a notch display this still starts flush at the top with
/// square shoulders, so it grows out of the notch rather than floating below.
private struct ExpandedSurface<Content: View>: View {
    let notch: NotchGeometry
    @ViewBuilder var content: Content

    var body: some View {
        let radius: CGFloat = notch.hasNotch ? 0 : 16
        content
            .padding(.horizontal, 18)
            .padding(.top, notch.hasNotch ? notch.height + 6 : 12)
            .padding(.bottom, 12)
            .background {
                UnevenRoundedRectangle(
                    topLeadingRadius: radius,
                    bottomLeadingRadius: 20,
                    bottomTrailingRadius: 20,
                    topTrailingRadius: radius,
                    style: .continuous
                )
                .fill(.black)
                .overlay {
                    UnevenRoundedRectangle(
                        topLeadingRadius: radius,
                        bottomLeadingRadius: 20,
                        bottomTrailingRadius: 20,
                        topTrailingRadius: radius,
                        style: .continuous
                    )
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.12), .white.opacity(0.02), .clear],
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

/// The Kamui mark — the app's namesake Mangekyō. The dimension notifiers get
/// pulled into is always turning: `ambient` keeps it in a slow continuous
/// spin; otherwise it makes one settling turn when it appears. Reduced
/// motion renders it still.
struct KamuiMark: View {
    var size: CGFloat = 16
    var ambient = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spun = false

    /// One ambient revolution takes this long — present, never distracting.
    private static let ambientPeriod: TimeInterval = 18

    var body: some View {
        if ambient, !reduceMotion {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let turn = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: Self.ambientPeriod) / Self.ambientPeriod
                mark.rotationEffect(.degrees(turn * 360))
            }
        } else {
            mark
                .rotationEffect(.degrees(spun || reduceMotion ? 0 : -180))
                .opacity(spun || reduceMotion ? 1 : 0.4)
                .onAppear {
                    withAnimation(.spring(response: 0.8, dampingFraction: 0.8)) {
                        spun = true
                    }
                }
        }
    }

    private var mark: some View {
        Image("KamuiMark")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct ToastContent: View {
    let message: String

    var body: some View {
        HStack(spacing: 7) {
            KamuiMark(size: 14)
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

/// Live meeting status: guard mode is calm (still dim bars, nothing else);
/// recording mode is alive (dancing bars, breathing red dot, elapsed time).
/// No wordmark and no idle dot — the bar should read as a system state, not
/// an app announcing itself.
private struct MeetingContent: View {
    let capturing: Bool
    let startedAt: Date?

    var body: some View {
        HStack(spacing: 9) {
            if capturing {
                StatusDot(recording: true)
            }
            WaveformBars(active: capturing)
            if let startedAt {
                ElapsedTime(since: startedAt)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Red + breathing glow = audio is being captured — shown only while
/// recording, and recording never looks idle. Guard mode shows no dot at all.
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
