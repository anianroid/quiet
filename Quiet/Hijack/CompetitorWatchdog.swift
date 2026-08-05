import AppKit
import Foundation
import os.log

/// Keeps known notetaker sidecars quit **while Quiet is armed**.
/// Solves the race where Granola/Fireflies notify before a meeting-start kill.
@MainActor
final class CompetitorWatchdog {
    private let processController: ProcessController
    private var timer: Timer?
    private var onActions: (([HijackAction]) -> Void)?
    /// Avoid spamming the UI log every tick while holding the same apps dead.
    private var lastLoggedNames: Set<String> = []

    private let logger = Logger(subsystem: "notes.quiet.app", category: "CompetitorWatchdog")

    init(processController: ProcessController) {
        self.processController = processController
    }

    func start(onActions: (([HijackAction]) -> Void)? = nil) {
        stop()
        self.onActions = onActions
        lastLoggedNames = []
        logger.info("Watchdog armed")
        // Immediate pass — don't wait for first tick / meeting detect.
        tick()
        // Login Items (Granola/Fireflies/Fathom) respawn fast — poll hard.
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    func stop() {
        if timer != nil {
            logger.info("Watchdog stopped")
        }
        timer?.invalidate()
        timer = nil
        lastLoggedNames = []
    }

    private func tick() {
        // Cheap on purpose: suspendCompetitors works from
        // NSWorkspace.shared.runningApplications alone. The installed-apps disk
        // scan runs on launch, settings open, and app-launch notifications —
        // never on the 0.6s tick.
        let actions = processController.suspendCompetitors(from: [])
        guard !actions.isEmpty else {
            lastLoggedNames = []
            return
        }
        let names = Set(actions.map(\.competitorName))
        // Only notify UI when the set of held-off apps changes (or first kill).
        if names != lastLoggedNames {
            lastLoggedNames = names
            logger.info("Holding off: \(names.sorted().joined(separator: ", "), privacy: .public)")
            onActions?(actions)
        }
    }
}
