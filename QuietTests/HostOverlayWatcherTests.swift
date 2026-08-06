import CoreGraphics
import Foundation
import Testing

// The persistent-HUD exemption is the one path that can leave a competitor
// pill on screen for a whole meeting, so its threshold is pinned here.
// Vendors fire pills off their own calendar/lobby signals and beat Quiet's
// detector by the whole lobby wait — a pill that landed a minute early is
// still a pill, while a dictation HUD predates the meeting by many minutes.
struct HostOverlayWatcherTests {
    @Test func lobbyAgedPillsAreNotExemptAsHUDs() {
        let now = Date()
        let firstSeen: [CGWindowID: Date] = [
            10: now.addingTimeInterval(-1),    // landed alongside detection
            11: now.addingTimeInterval(-45),   // landed during the lobby wait
            12: now.addingTimeInterval(-90),   // slow detection, still a pill
            13: now.addingTimeInterval(-3600)  // all-day dictation HUD
        ]
        let huds = HostOverlayWatcher.persistentHUDs(firstSeenAt: firstSeen, now: now)
        #expect(huds == [13])
    }

    @Test func emptyFirstSeenExemptsNothing() {
        #expect(HostOverlayWatcher.persistentHUDs(firstSeenAt: [:], now: Date()).isEmpty)
    }

    // Wispr draws its pill inside a 480x570 transparent container at the
    // screen-saver CG layer — far over the pill-size cap, so it must be
    // admitted as a container. Layer-0 windows that tall are real documents,
    // and tall menu-layer windows are context menus; neither qualifies.
    @Test func oversizedElevatedWindowsAreContainers() {
        #expect(HostOverlayWatcher.candidateKind(height: 570, width: 480, layer: 1000) == .container)
        #expect(HostOverlayWatcher.candidateKind(height: 49, width: 540, layer: 3) == .pill)
        #expect(HostOverlayWatcher.candidateKind(height: 570, width: 480, layer: 0) == nil)
        #expect(HostOverlayWatcher.candidateKind(height: 400, width: 300, layer: Int(CGWindowLevelForKey(.popUpMenuWindow))) == nil)
        #expect(HostOverlayWatcher.candidateKind(height: 900, width: 480, layer: 1000) == nil)
        #expect(HostOverlayWatcher.candidateKind(height: 570, width: 40, layer: 1000) == nil)
    }

    // Vision boxes are normalized with origin at the image's bottom-left;
    // screen rects are Quartz (top-left). A pill in the vertical middle of a
    // window must land at the window's middle in screen coordinates.
    @Test func normalizedTextBoxConvertsToQuartzScreenRect() {
        let windowFrame = CGRect(x: 516, y: 412, width: 480, height: 570)
        let union = CGRect(x: 0.25, y: 0.4, width: 0.5, height: 0.2)
        let rect = HostOverlayWatcher.quartzRect(ofNormalized: union, inWindowFrame: windowFrame)
        let expected = CGRect(x: 636, y: 640, width: 240, height: 114)
        #expect(abs(rect.origin.x - expected.origin.x) < 0.01)
        #expect(abs(rect.origin.y - expected.origin.y) < 0.01)
        #expect(abs(rect.width - expected.width) < 0.01)
        #expect(abs(rect.height - expected.height) < 0.01)
    }
}
