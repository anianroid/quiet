import AppKit
import Foundation

/// Keeps known notetaker sidecars quit **while Quiet is armed**.
/// Solves the race where Granola/Fireflies notify before a meeting-start kill.
@MainActor
final class CompetitorWatchdog {
    private let processController: ProcessController
    private let scanner: CompetitorScanner
    private var timer: Timer?
    private var onActions: (([HijackAction]) -> Void)?
    /// Avoid spamming the UI log every tick while holding the same apps dead.
    private var lastLoggedNames: Set<String> = []

    init(processController: ProcessController, scanner: CompetitorScanner) {
        self.processController = processController
        self.scanner = scanner
    }

    func start(onActions: (([HijackAction]) -> Void)? = nil) {
        stop()
        self.onActions = onActions
        lastLoggedNames = []
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
        timer?.invalidate()
        timer = nil
        lastLoggedNames = []
    }

    private func tick() {
        let installed = scanner.scan()
        let actions = processController.suspendCompetitors(from: installed)
        guard !actions.isEmpty else {
            lastLoggedNames = []
            return
        }
        let names = Set(actions.map(\.competitorName))
        // Only notify UI when the set of held-off apps changes (or first kill).
        if names != lastLoggedNames {
            lastLoggedNames = names
            onActions?(actions)
        }
    }
}
