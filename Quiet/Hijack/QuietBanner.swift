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

    /// Brief toast (launch messages, “Notes ready”). Auto-hides.
    func show(message: String, duration: TimeInterval = 5) {
        isPersistent = false
        present(message: message, style: .toast)

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
        hideWork?.cancel()
        hideWork = nil
        isPersistent = true
        present(message: message, style: .meeting)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        isPersistent = false
        panel?.orderOut(nil)
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
    }

    private func present(message: String, style: Style) {
        if panel == nil {
            createPanel()
        }
        guard let panel else { return }

        let viewStyle: NotchBannerView.Style = (style == .meeting) ? .meeting : .toast
        let hosting = NSHostingView(rootView: NotchBannerView(message: message, style: viewStyle))
        panel.contentView = hosting
        position(panel, compact: style == .meeting)
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
        self.panel = panel
    }

    private func position(_ panel: NSPanel, compact: Bool) {
        guard !isRepositioning else { return }
        isRepositioning = true
        defer { isRepositioning = false }

        guard let screen = NSScreen.main else { return }
        let full = screen.frame
        let topInset = screen.safeAreaInsets.top
        let width: CGFloat = compact ? 280 : 340
        let height: CGFloat = {
            if compact {
                return topInset > 0 ? max(topInset + 8, 36) : 44
            }
            return topInset > 0 ? topInset + 48 : 56
        }()
        let x = full.midX - width / 2
        let y = full.maxY - height
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }
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
