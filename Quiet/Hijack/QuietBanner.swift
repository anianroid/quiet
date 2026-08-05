import AppKit
import SwiftUI

/// Notch / top-center status for Quiet.
/// Intentionally simple — no screen-parameter observers (those can re-enter on
/// `setFrame` and peg the CPU).
@MainActor
final class QuietBannerController {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var isRepositioning = false
    private var isPersistent = false

    /// Resolves the pending Keep/Discard prompt, if one is showing.
    /// Nil'd before invocation so exactly one outcome ever fires.
    private var pendingKeepDiscard: ((_ keep: Bool) -> Void)?

    /// Bumped on every present/hide so an in-flight fade-out completion from a
    /// superseded state never orders out a freshly shown panel.
    private var fadeGeneration = 0

    /// Brief toast (launch messages, “Notes saved”). Auto-hides.
    func show(message: String, duration: TimeInterval = 5) {
        resolvePendingAsKeep()
        isPersistent = false
        present(rootView: NotchBannerView(message: message, style: .toast), style: .toast)

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPersistent else { return }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Persistent island while a meeting is active. Call `hide()` on meeting end.
    func showMeetingStatus(message: String = "Quiet · Meeting") {
        resolvePendingAsKeep()
        hideWork?.cancel()
        hideWork = nil
        isPersistent = true
        present(rootView: NotchBannerView(message: message, style: .meeting), style: .meeting)
    }

    /// Interactive post-call island with Keep / Discard buttons. Exactly one
    /// callback fires: Keep or Discard on click, or Keep automatically after
    /// `autoKeepAfter` with a fade-out — keep is the default, so notes are never
    /// stranded in staging by an unanswered prompt.
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

        let view = KeepDiscardBannerView(
            message: message,
            onKeep: { [weak self] in self?.resolveKeepDiscard(keep: true) },
            onDiscard: { [weak self] in self?.resolveKeepDiscard(keep: false) }
        )
        present(rootView: view, style: .keepDiscard)

        let work = DispatchWorkItem { [weak self] in
            guard let self, let resolve = self.pendingKeepDiscard else { return }
            self.pendingKeepDiscard = nil
            self.hideWork = nil
            // No response — keep is the default; fade the island, then fire Keep
            // (after the fade, so a "Notes saved" toast doesn't fight the animation).
            self.fadeOutThenHide { resolve(true) }
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
        fadeGeneration += 1
        panel?.orderOut(nil)
        panel?.alphaValue = 1
    }

    /// Tear down completely (call on quit).
    func destroy() {
        hide()
        panel?.close()
        panel = nil
    }

    private enum Style {
        case toast
        case meeting
        case keepDiscard
    }

    /// Button press on the Keep/Discard island: hide, then fire the outcome.
    /// The pending closure is taken out first so `hide()` can't resolve it as
    /// Keep, and firing last lets the outcome present its own toast cleanly.
    private func resolveKeepDiscard(keep: Bool) {
        guard let resolve = pendingKeepDiscard else { return }
        pendingKeepDiscard = nil
        hideWork?.cancel()
        hideWork = nil
        hide()
        resolve(keep)
    }

    /// Any newly presented state (next meeting starting, a toast) resolves a
    /// still-pending prompt as Keep so staged notes are never orphaned.
    private func resolvePendingAsKeep() {
        fireKeepDiscard(keep: true)
    }

    private func fireKeepDiscard(keep: Bool) {
        guard let resolve = pendingKeepDiscard else { return }
        pendingKeepDiscard = nil
        resolve(keep)
    }

    /// Fades the panel out, orders it out, then runs `completion`. The completion
    /// always runs — even if a newer present superseded the fade — so a Keep
    /// resolution riding on it is never dropped.
    private func fadeOutThenHide(then completion: (() -> Void)? = nil) {
        isPersistent = false
        guard let panel, panel.isVisible else {
            hide()
            completion?()
            return
        }
        fadeGeneration += 1
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            panel.animator().alphaValue = 0
        }
        let work = DispatchWorkItem { [weak self] in
            if let self, self.fadeGeneration == generation {
                self.panel?.orderOut(nil)
                self.panel?.alphaValue = 1
            }
            completion?()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    private func present<Content: View>(rootView: Content, style: Style) {
        if panel == nil {
            createPanel()
        }
        guard let panel else { return }

        fadeGeneration += 1
        // Zero-duration animator set replaces any in-flight fade animation
        // instead of racing it.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.contentView = FirstMouseHostingView(rootView: rootView)
        position(panel, style: style)
        panel.orderFrontRegardless()
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        // Keep/Discard buttons need clicks; `.nonactivatingPanel` (above) keeps
        // those clicks from stealing focus from the meeting app.
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        self.panel = panel
    }

    private func position(_ panel: NSPanel, style: Style) {
        guard !isRepositioning else { return }
        isRepositioning = true
        defer { isRepositioning = false }

        guard let screen = NSScreen.main else { return }
        let full = screen.frame
        let topInset = screen.safeAreaInsets.top
        let width: CGFloat
        let height: CGFloat
        switch style {
        case .toast:
            width = 340
            height = topInset > 0 ? topInset + 48 : 56
        case .meeting:
            width = 280
            height = topInset > 0 ? max(topInset + 8, 36) : 44
        case .keepDiscard:
            width = 420
            height = topInset > 0 ? topInset + 92 : 104
        }
        let x = full.midX - width / 2
        let y = full.maxY - height
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }
}

/// Hosting view that accepts the first click even though the panel never becomes
/// key — without this the first press on Keep/Discard would be swallowed.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct NotchBannerView: View {
    enum Style {
        case toast
        case meeting
    }

    let message: String
    var style: Style = .toast

    var body: some View {
        let hasNotch = (NSScreen.main?.safeAreaInsets.top ?? 0) > 0

        VStack(spacing: 0) {
            if style == .meeting {
                Capsule()
                    .fill(Color.black)
                    .frame(width: hasNotch ? 168 : 200, height: hasNotch ? 28 : 34)
                    .overlay {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 6, height: 6)
                            Image(systemName: "waveform")
                                .font(.system(size: 10, weight: .bold))
                            Text(message)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .padding(.top, hasNotch ? 4 : 0)
                    }
                    .padding(.top, hasNotch ? 2 : 6)
            } else if hasNotch {
                Capsule()
                    .fill(Color.black)
                    .frame(width: 200, height: 30)
                    .overlay {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform")
                                .font(.system(size: 10, weight: .bold))
                            Text("Quiet")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .padding(.top, 6)
                    }

                Text(message)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.black))
                    .padding(.horizontal, 16)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.circle.fill")
                    Text(message)
                        .lineLimit(2)
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.92)))
                .padding(6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Post-call prompt island: summary gist on top, Keep / Discard below.
/// On notch screens the black rect extends the notch downward like an island.
private struct KeepDiscardBannerView: View {
    let message: String
    let onKeep: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        let topInset = NSScreen.main?.safeAreaInsets.top ?? 0
        let hasNotch = topInset > 0

        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                Image(systemName: "waveform")
                    .font(.system(size: 10, weight: .bold))
                Text(message)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Button(action: onDiscard) {
                    Text("Discard")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)

                Button(action: onKeep) {
                    Text("Keep")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, hasNotch ? topInset + 6 : 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.black))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
