import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision
import os.log

/// Layer C — suppress the floating "Start Notetaker" pills apps draw
/// themselves. These are ordinary app windows, not notifications, so Layer B
/// never sees them.
///
/// **No app list.** A window earns suppression by behaving like a notetaker
/// prompt — small, floating, and carrying unambiguous prompt copy — whoever
/// draws it. That matters because the offenders aren't only notetakers: a
/// dictation app or a calendar can grow a "Start Notetaker" button overnight,
/// and Quiet must handle it without shipping a new build.
///
/// The host app is never quit and no button that could *start* anything is
/// ever pressed — only close affordances, else the window is parked off-screen.
@MainActor
final class HostOverlayWatcher {
    nonisolated static let logger = Logger(subsystem: "notes.quiet.app", category: "HostOverlayWatcher")

    /// Electron does not reliably post AXWindowCreated for its notification
    /// panels, so polling is what actually catches a pill. Pills land in the
    /// seconds right after a meeting is detected, so that stretch is swept at
    /// near-frame rate — the pill is gone before it finishes fading in.
    /// Apps pop pills whenever they notice the call, not only at the start —
    /// Notion's lands ~30s in — so the fast cadence covers the whole meeting.
    /// Steady-state ticks cost one CoreGraphics call: when the set of small
    /// windows is unchanged there is no Accessibility traffic at all.
    /// Apps often notice a call before Quiet does — Notion's pill has landed a
    /// full second before meeting detection fired — so the idle cadence has to
    /// be fast enough to catch a pill that arrives *first*, not only one that
    /// arrives after Quiet is armed for a meeting. Both cadences are affordable
    /// because an unchanged window set costs a single CoreGraphics call.
    private static let idleInterval: TimeInterval = 0.1
    private static let meetingInterval: TimeInterval = 0.03

    /// Prompt pills are small. Anything taller is a real window we never touch.
    nonisolated static let maxOverlayHeight: CGFloat = 260
    /// Below this, a window is a shadow/tooltip artifact rather than a prompt.
    nonisolated static let minOverlayHeight: CGFloat = 24
    /// Electron apps also draw pills *inside* a much larger transparent
    /// container window (Wispr's is 480x570 at the screen-saver level), which
    /// the pill-size gate can never see. Containers are admitted only at
    /// elevated CG layers — a layer-0 window this tall is a real document.
    nonisolated static let maxContainerHeight: CGFloat = 800

    enum CandidateKind {
        /// A window that is itself pill-sized — dismissed or parked whole.
        case pill
        /// An oversized elevated-layer window that may host a pill. Acted on
        /// only with pixel evidence: closed, parked, or its host hidden.
        case container
    }

    /// Pure admission rule so tests can pin it. Menu-layer windows are never
    /// containers — a tall context menu is not a pill host.
    nonisolated static func candidateKind(height: CGFloat, width: CGFloat, layer: Int) -> CandidateKind? {
        guard width >= 80 else { return nil }
        if height >= minOverlayHeight && height <= maxOverlayHeight { return .pill }
        let popUpMenuLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let isMenuLayer = layer >= popUpMenuLayer && layer <= popUpMenuLayer + 1
        if layer > 0, !isMenuLayer, height <= maxContainerHeight { return .container }
        return nil
    }

    private var timer: Timer?
    private var isSweeping = false
    private var interval: TimeInterval = HostOverlayWatcher.idleInterval
    private var isMeetingActive = false
    /// Window set from the previous sweep — an unchanged set means nothing new
    /// can need suppressing, so the expensive half of the sweep is skipped.
    private var lastCandidateIDs: Set<CGWindowID> = []

    /// Process identity is fixed for the life of a pid, and looking it up is a
    /// LaunchServices round trip — cache it rather than paying per tick.
    private struct AppIdentity {
        let bundleID: String
        let name: String
    }
    private var appIdentities: [pid_t: AppIdentity] = [:]
    /// Apps told to expose their web content, so the switch is flipped once each.
    private var manualAccessibilityEnabled: Set<pid_t> = []
    /// Window-created observers, so apps that do post the event are handled
    /// without waiting for the next tick at all.
    private var observers: [pid_t: AXObserver] = [:]

    /// Apps observed popping a notetaker pill, learned at runtime and persisted
    /// — never a shipped list. Whatever a user has installed teaches Quiet on
    /// first sight, and from then on that app is watched from meeting start.
    private(set) var learnedPillApps: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.learnedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.learnedKey) }
    }
    private static let learnedKey = "quiet.learnedPillApps"

    /// Pixel-read verdicts per window, for apps whose UI is invisible to
    /// Accessibility. Cached so each window costs one capture, re-checked while
    /// a meeting is running because a pill can appear inside an existing window.
    private struct OCRVerdict {
        let isNotetakerPrompt: Bool
        let checkedAt: Date
        let text: String
        /// Where the recognized text sits, in Quartz screen coordinates.
        let promptRect: CGRect?
    }
    private var ocrVerdicts: [CGWindowID: OCRVerdict] = [:]
    private var ocrPending: Set<CGWindowID> = []
    private static let ocrRecheckInterval: TimeInterval = 3
    /// Screen Recording is optional for this layer — say so once, not per sweep.
    private var loggedCaptureUnavailable = false

    /// Host apps that pop notetaker pills Kamui must never leave on screen.
    /// These are never force-quit (Notion is the user's workspace; Wispr is
    /// dictation) — only their prompt windows are dismissed, parked, or hidden.
    /// Windows already on screen for a few seconds before the meeting are
    /// treated as persistent HUDs (Wispr's dictation bar) and left alone.
    /// Derived from the catalog's popsMeetingPills entries — never a list
    /// in code.
    private let hostPillBundleIds: Set<String>

    /// Shared with Layer B so window text and banner text are judged by the
    /// same catalog-derived rules.
    private let matcher: NotetakerPromptMatcher

    init(catalog: CompetitorCatalog) {
        self.hostPillBundleIds = catalog.pillHostBundleIds
        self.matcher = NotetakerPromptMatcher(catalog: catalog)
    }

    /// When each candidate window ID was first observed. Used to tell a
    /// meeting-triggered pill from a pre-existing floating HUD.
    private var firstSeenAt: [CGWindowID: Date] = [:]
    private var meetingStartedAt: Date?
    /// Pill-sized windows that were already sitting on screen before the
    /// meeting started — dictation HUDs, not prompts.
    private var persistentBeforeMeeting: Set<CGWindowID> = []

    /// Containers parked off-screen during a meeting, with the position to
    /// restore at meeting end. Parking is the no-drawing suppression: the
    /// whole transparent container (pill included) moves off every display.
    /// Nothing is ever painted over the user's screen.
    private var parked: [CGWindowID: (window: AXUIElement, original: CGPoint)] = [:]
    /// Host apps hidden as the last rung — unhidden at meeting end.
    private var hiddenHosts: Set<pid_t> = []
    /// Per-window backoff so a failing suppression ladder is retried every
    /// couple of seconds, not at sweep cadence.
    private var lastSuppressAttempt: [CGWindowID: Date] = [:]
    /// Containers already logged as "confirming via pixels" — once per
    /// sighting, not once per 30ms tick.
    private var announcedContainers: Set<CGWindowID> = []

    func start() {
        stop()
        Self.logger.notice("HostOverlayWatcher.start axTrusted=\(AXIsProcessTrusted()) interval=\(self.interval)")
        guard AXIsProcessTrusted() else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sweep()
            }
        }
        sweep()
        if UserDefaults.standard.bool(forKey: "quiet.axProbe") {
            probeCandidates()
            // Electron builds its AX tree lazily after AXManualAccessibility is
            // set — a second pass shows whether the content becomes readable.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                self?.probeCandidates()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers.removeAll()
        restoreSuppressed()
    }

    /// Meeting start is exactly when apps pop their pills — sweep at frame rate
    /// through that window so nothing is on screen long enough to register.
    func setMeetingActive(_ active: Bool) {
        isMeetingActive = active
        if active {
            let now = Date()
            meetingStartedAt = now
            persistentBeforeMeeting = Self.persistentHUDs(firstSeenAt: firstSeenAt, now: now)
            logHUDExemptions(at: now)
            // Force the next tick to re-inspect windows already on screen —
            // the unchanged-set fast path must not skip a pill that landed
            // before the meeting was detected.
            lastCandidateIDs = []
            armObserversForLearnedApps()
        } else {
            meetingStartedAt = nil
            persistentBeforeMeeting = []
            restoreSuppressed()
        }
        retune()
    }

    /// How long a window must predate the meeting to be treated as a
    /// persistent HUD (Wispr's dictation bar) instead of a meeting pill.
    /// Vendors fire pills off their own calendar/lobby signals and beat
    /// Quiet's detector by the whole lobby wait — Wispr's pill has landed
    /// 30-60s early, and detection is slower still without Screen Recording.
    /// A true HUD predates the meeting by many minutes, not by a lobby.
    nonisolated static let preMeetingHUDAge: TimeInterval = 120

    /// Pure so tests can pin the threshold: window IDs first seen more than
    /// `preMeetingHUDAge` before `now`.
    nonisolated static func persistentHUDs(firstSeenAt: [CGWindowID: Date], now: Date) -> Set<CGWindowID> {
        Set(firstSeenAt.compactMap { id, seen in
            now.timeIntervalSince(seen) > preMeetingHUDAge ? id : nil
        })
    }

    /// The HUD exemption is the one path that can leave a competitor pill on
    /// screen for a whole meeting — it must never be silent. One CG pass at
    /// meeting start, host-pill apps only.
    private func logHUDExemptions(at now: Date) {
        guard !persistentBeforeMeeting.isEmpty else { return }
        for candidate in candidates() where persistentBeforeMeeting.contains(candidate.windowID) {
            guard let app = NSRunningApplication(processIdentifier: candidate.pid),
                  let bundleID = app.bundleIdentifier,
                  hostPillBundleIds.contains(bundleID) else { continue }
            let age = Int(now.timeIntervalSince(firstSeenAt[candidate.windowID] ?? now))
            Self.logger.notice("Pre-meeting HUD exemption: window \(candidate.windowID) of \(bundleID, privacy: .public) on screen \(age)s before the meeting — identity suppression will skip it")
        }
    }

    /// Picks the sweep cadence for the moment and restarts the timer only when
    /// it actually changes.
    private func retune() {
        let next = isMeetingActive ? Self.meetingInterval : Self.idleInterval
        guard next != interval else { return }
        interval = next
        if timer != nil { start() }
    }

    /// Registers window-created observers on apps already known to pop pills, so
    /// the ones that do post the event are handled with no polling latency.
    private func armObserversForLearnedApps() {
        let watched = learnedPillApps.union(hostPillBundleIds)
        guard !watched.isEmpty else { return }
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, watched.contains(bundleID) else { continue }
            ensureObserver(for: app.processIdentifier)
        }
    }

    private func ensureObserver(for pid: pid_t) {
        guard observers[pid] == nil else { return }

        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<HostOverlayWatcher>.fromOpaque(refcon).takeUnretainedValue()
            // The observer's run loop source lives on the main run loop.
            MainActor.assumeIsolated {
                watcher.sweep()
            }
        }

        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        AXObserverAddNotification(
            observer,
            AXUIElementCreateApplication(pid),
            kAXWindowCreatedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque()
        )
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    /// Records an app as a pill-popper the first time one is caught, and extends
    /// the burst — pills tend to arrive in waves from several apps at once.
    private func learn(bundleID: String, pid: pid_t) {
        ensureObserver(for: pid)
        var learned = learnedPillApps
        guard !bundleID.isEmpty, !learned.contains(bundleID) else { return }
        learned.insert(bundleID)
        learnedPillApps = learned
        Self.logger.notice("Learned pill app: \(bundleID, privacy: .public) (now watched from meeting start)")
    }

    /// An on-screen window that could be (or host) a prompt pill, as
    /// CoreGraphics sees it. CG is the source of truth for geometry because
    /// floating panels (Electron's pills) are routinely absent from an app's
    /// AX windows list.
    private struct Candidate {
        let pid: pid_t
        let windowID: CGWindowID
        let frame: CGRect
        let layer: Int
        let kind: CandidateKind
    }

    private func sweep() {
        guard !isSweeping else { return }
        isSweeping = true
        defer { isSweeping = false }

        // One cheap CG call narrows ~60 running apps to the few owning a small
        // floating window; only those get AX round-trips.
        let found = candidates()
        let ids = Set(found.map(\.windowID))
        let now = Date()
        let previouslySeen = lastCandidateIDs
        for id in ids {
            // A window that left the candidate set and returned is "new" —
            // CGWindowID reuse must not inherit a stale first-seen time.
            if firstSeenAt[id] == nil || !previouslySeen.contains(id) {
                firstSeenAt[id] = now
            }
        }
        if firstSeenAt.count > 128 {
            firstSeenAt = firstSeenAt.filter { ids.contains($0.key) }
        }

        // Nothing appeared or disappeared since the last tick, and no capture is
        // in flight — no window can have become a prompt, so skip the AX work.
        // A container due for a pixel re-read still forces a full pass: its
        // pill appears *inside* an existing window, which never changes the
        // candidate set.
        let containerDue = isMeetingActive && found.contains { candidate in
            candidate.kind == .container && (
                ocrVerdicts[candidate.windowID].map {
                    now.timeIntervalSince($0.checkedAt) > Self.ocrRecheckInterval
                } ?? true
            )
        }
        if ids == lastCandidateIDs, ocrPending.isEmpty, !hasActionableVerdict(in: ids), !containerDue {
            return
        }
        lastCandidateIDs = ids

        for candidate in found {
            inspect(candidate)
        }
        pruneVerdicts(seen: ids)
        lastSuppressAttempt = lastSuppressAttempt.filter { ids.contains($0.key) }
        announcedContainers.formIntersection(ids)
    }

    /// True when a pixel read has come back positive for a window still on
    /// screen — that verdict lands asynchronously and must be acted on even
    /// though the window set itself did not change.
    private func hasActionableVerdict(in ids: Set<CGWindowID>) -> Bool {
        ids.contains { ocrVerdicts[$0]?.isNotetakerPrompt == true }
    }

    private func candidates() -> [Candidate] {
        let options = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var found: [Candidate] = []
        for window in info {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID else { continue }
            guard let windowID = window[kCGWindowNumber as String] as? CGWindowID else { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat, let height = bounds["Height"] as? CGFloat,
                  height >= Self.minOverlayHeight else { continue }
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            guard let kind = Self.candidateKind(height: height, width: width, layer: layer) else { continue }
            found.append(Candidate(pid: pid, windowID: windowID, frame: CGRect(x: x, y: y, width: width, height: height), layer: layer, kind: kind))
        }
        return found
    }

    private func inspect(_ candidate: Candidate) {
        // Looking an app up by pid is a LaunchServices round trip; at a 30ms
        // cadence that has to happen once per process, not once per tick.
        let identity: AppIdentity
        if let cached = appIdentities[candidate.pid] {
            identity = cached
        } else {
            guard let app = NSRunningApplication(processIdentifier: candidate.pid) else { return }
            identity = AppIdentity(bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? "")
            appIdentities[candidate.pid] = identity
        }
        let bundleID = identity.bundleID
        // Apple's own surfaces are Layer B's job (Notification Center) or system
        // UI we must never touch.
        guard !bundleID.hasPrefix("com.apple."), bundleID != Bundle.main.bundleIdentifier else { return }

        if !manualAccessibilityEnabled.contains(candidate.pid) {
            // Electron only emits its web-content AX tree when an assistive
            // client asks; without this the pill's text reads as empty.
            let appElement = AXUIElementCreateApplication(candidate.pid)
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            manualAccessibilityEnabled.insert(candidate.pid)
        }

        // Known hosts (Notion / Wispr): during a meeting, any pill-sized window
        // that wasn't already on screen is covered from CG geometry — no AX or
        // OCR required. That is what actually silences them when Electron lies
        // about Accessibility and Screen Recording is missing.
        // Context/popup menus live at the popup-menu CG layer — never cover
        // those, or Notion's right-click menus go black mid-meeting.
        let popUpMenuLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let isMenuLayer = candidate.layer >= popUpMenuLayer && candidate.layer <= popUpMenuLayer + 1
        let hostIdentitySaysPrompt = isMeetingActive
            && hostPillBundleIds.contains(bundleID)
            && !persistentBeforeMeeting.contains(candidate.windowID)
            && !isMenuLayer

        let window = resolveWindow(for: candidate)
        let debug = UserDefaults.standard.bool(forKey: "quiet.axDump")
        if debug {
            let resolved = window.map { self.windowSizeDescription($0) } ?? "nil"
            Self.logger.notice("OVERLAYDUMP \(bundleID, privacy: .public) cg=\(candidate.frame.debugDescription, privacy: .public) ax=\(resolved, privacy: .public) host=\(hostIdentitySaysPrompt)")
        }

        // AX size gate only applies when we would move an AX element. Covering
        // from CG is always safe for a CG-filtered pill-sized candidate.
        let axOverlay = window.flatMap { isOverlaySized($0) ? $0 : nil }

        var blob = ""
        if let axOverlay {
            collectText(axOverlay, into: &blob, depth: 0)
        }

        let axSaysPrompt = !blob.isEmpty
            && matcher.isNotetakerPill(blob)
            && !blob.localizedCaseInsensitiveContains("Kamui")

        let verdict = ocrVerdicts[candidate.windowID]
        let pixelsSayPrompt = verdict?.isNotetakerPrompt ?? false

        if !axSaysPrompt && !pixelsSayPrompt && !hostIdentitySaysPrompt {
            requestPixelRead(for: candidate)
            return
        }

        let evidence: String
        let source: String
        if axSaysPrompt {
            evidence = String(blob.prefix(120))
            source = "ax"
        } else if pixelsSayPrompt {
            evidence = String((verdict?.text ?? "").prefix(120))
            source = "pixels"
        } else {
            evidence = "host pill during meeting"
            source = "identity"
        }
        let label = identity.name.isEmpty ? bundleID : identity.name

        // A failing ladder is retried every couple of seconds, never at sweep
        // cadence — AX calls to a stuck Electron process are not free.
        let now = Date()
        if let last = lastSuppressAttempt[candidate.windowID], now.timeIntervalSince(last) < 2 {
            return
        }
        lastSuppressAttempt[candidate.windowID] = now

        if candidate.kind == .container {
            // Nothing is ever drawn over the user's screen. A container pill
            // is suppressed for real or not at all — and a container is only
            // ever moved on pixel evidence, never on identity alone.
            guard pixelsSayPrompt else {
                requestPixelRead(for: candidate)
                if announcedContainers.insert(candidate.windowID).inserted {
                    Self.logger.notice("Container (\(label, privacy: .public)) flagged [\(source, privacy: .public)] — confirming via pixels before acting")
                }
                return
            }
            let strategy = suppressContainer(candidate)
            learn(bundleID: bundleID, pid: candidate.pid)
            Self.logger.notice("Container (\(label, privacy: .public)) \(strategy, privacy: .public) [\(source, privacy: .public)]: \(evidence, privacy: .public)")
            return
        }

        // Pills: the AX dismissal ladder, ending in an off-screen park.
        var strategy = "matched but not dismissable — pill left visible"
        if let axOverlay {
            strategy = dismiss(axOverlay)
        }
        learn(bundleID: bundleID, pid: candidate.pid)
        Self.logger.notice("Overlay (\(label, privacy: .public)) \(strategy, privacy: .public) [\(source, privacy: .public)]: \(evidence, privacy: .public)")
    }

    /// Suppression ladder for container pills — every rung removes the pill
    /// from the screen for real. Parked windows and hidden hosts are restored
    /// when the meeting ends.
    private func suppressContainer(_ candidate: Candidate) -> String {
        if let window = containerAXWindow(for: candidate) {
            if performNamedCloseAction(on: window) { return "closed via named action" }
            if park(window, candidate: candidate) { return "parked off-screen (restores after the meeting)" }
        }
        if let app = NSRunningApplication(processIdentifier: candidate.pid), !app.isHidden, app.hide() {
            hiddenHosts.insert(candidate.pid)
            return "host app hidden (unhides after the meeting)"
        }
        return "matched but not suppressible — pill left visible"
    }

    /// The AX element for a container action must be the container itself —
    /// same frame within tolerance — never a hit-test that climbed into the
    /// app's real window.
    private func containerAXWindow(for candidate: Candidate) -> AXUIElement? {
        guard let window = resolveWindow(for: candidate),
              let size = windowSize(window),
              abs(size.width - candidate.frame.width) < 24,
              abs(size.height - candidate.frame.height) < 24 else { return nil }
        return window
    }

    /// Moves the container off every display and verifies the write landed —
    /// Electron routinely returns success while ignoring the move.
    private func park(_ window: AXUIElement, candidate: Candidate) -> Bool {
        if parked[candidate.windowID] != nil { return true }
        guard let original = windowPosition(window),
              moveOffScreen(window),
              let moved = windowPosition(window),
              moved.x < -10_000 else { return false }
        parked[candidate.windowID] = (window, original)
        return true
    }

    /// Puts everything back the way it was: parked containers return to their
    /// original positions, hidden hosts unhide. Runs at meeting end and stop.
    private func restoreSuppressed() {
        for (id, entry) in parked {
            var point = entry.original
            if let value = AXValueCreate(.cgPoint, &point) {
                AXUIElementSetAttributeValue(entry.window, kAXPositionAttribute as CFString, value)
            }
            Self.logger.notice("Restored parked container window \(id)")
        }
        parked.removeAll()
        for pid in hiddenHosts {
            NSRunningApplication(processIdentifier: pid)?.unhide()
            Self.logger.notice("Unhid host app pid \(pid)")
        }
        hiddenHosts.removeAll()
        lastSuppressAttempt.removeAll()
        announcedContainers.removeAll()
    }

    /// Captures and reads a candidate's pixels once, caching the verdict. The
    /// next sweep (100ms later during a meeting) acts on the result.
    private func requestPixelRead(for candidate: Candidate) {
        let windowID = candidate.windowID
        guard !ocrPending.contains(windowID) else { return }
        if let existing = ocrVerdicts[windowID] {
            // A pill can appear inside a window already judged benign, but only
            // re-read while a meeting is running.
            let stale = Date().timeIntervalSince(existing.checkedAt) > Self.ocrRecheckInterval
            guard stale, interval == Self.meetingInterval else { return }
        }

        ocrPending.insert(windowID)
        Task { @MainActor [weak self] in
            let read = await Self.recognizeText(windowID: windowID)
            guard let self else { return }
            self.ocrPending.remove(windowID)
            guard let read else {
                // Distinguish the two failure shapes: no permission is a
                // durable state worth one loud line; anything else (stream
                // contention with Quiet's own audio capture) is transient —
                // no verdict is cached, so the next sweep retries.
                if !CGPreflightScreenCaptureAccess(), !self.loggedCaptureUnavailable {
                    self.loggedCaptureUnavailable = true
                    Self.logger.notice("Pixel reading unavailable (Screen Recording not granted) — Wispr-style AX-blind pills fall back to identity suppression during meetings")
                }
                return
            }
            let isPrompt = !read.text.isEmpty
                && self.matcher.isNotetakerPill(read.text)
                && !read.text.localizedCaseInsensitiveContains("Kamui")
            let previous = self.ocrVerdicts[windowID]
            self.ocrVerdicts[windowID] = OCRVerdict(
                isNotetakerPrompt: isPrompt,
                checkedAt: Date(),
                text: read.text,
                promptRect: read.textRect.isNull ? nil : read.textRect
            )
            // Re-reads run every few seconds during a meeting — log only when
            // the verdict or the text actually changed, or the log drowns.
            let changed = previous?.isNotetakerPrompt != isPrompt || previous?.text != read.text
            if isPrompt {
                if changed {
                    Self.logger.notice("Pixel read MATCH window \(windowID): \(String(read.text.prefix(140)), privacy: .public)")
                }
                // Act on this tick — don't wait for the next timer fire.
                self.sweep()
            } else if changed, !read.text.isEmpty {
                Self.logger.notice("Pixel read no-match window \(windowID): \(String(read.text.prefix(140)), privacy: .public)")
            }
        }
    }

    /// Drops verdicts for windows that no longer exist so the cache can't grow
    /// without bound over a long session.
    private func pruneVerdicts(seen: Set<CGWindowID>) {
        guard ocrVerdicts.count > 64 else { return }
        ocrVerdicts = ocrVerdicts.filter { seen.contains($0.key) }
    }

    /// Finds the AX element for a CG window. Tries the app's AX windows list
    /// first, then hit-tests. Coordinates are probed in both Quartz (CG) space
    /// and Y-flipped Accessibility space — macOS versions disagree, and the
    /// previous single-space path silently returned nil and skipped the pill.
    private func resolveWindow(for candidate: Candidate) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(candidate.pid)
        let quartz = candidate.frame
        let flipped = Self.accessibilityFrame(fromQuartz: quartz)

        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {
            for window in windows {
                guard let position = windowPosition(window), let size = windowSize(window) else { continue }
                for origin in [quartz.origin, flipped.origin] {
                    if abs(position.x - origin.x) < 8,
                       abs(position.y - origin.y) < 8,
                       abs(size.height - quartz.height) < 12 {
                        return window
                    }
                }
                // Same size + X, Y within the window height — tolerates origin
                // top-left vs bottom-left mismatch without a full flip.
                if abs(position.x - quartz.origin.x) < 8,
                   abs(size.height - quartz.height) < 12,
                   abs(size.width - quartz.width) < 24 {
                    return window
                }
            }
        }

        for point in [
            CGPoint(x: quartz.midX, y: quartz.midY),
            CGPoint(x: flipped.midX, y: flipped.midY)
        ] {
            if let hit = hitTestWindow(at: point, pid: candidate.pid) {
                return hit
            }
        }
        return nil
    }

    /// Converts a Quartz (CGWindowBounds) rect into Accessibility / top-left
    /// global coordinates. Primary display height is the flip axis.
    private static func accessibilityFrame(fromQuartz quartz: CGRect) -> CGRect {
        let flip = NSScreen.screens.map(\.frame.maxY).max() ?? quartz.maxY
        return CGRect(
            x: quartz.origin.x,
            y: flip - quartz.origin.y - quartz.height,
            width: quartz.width,
            height: quartz.height
        )
    }

    /// Walks up from whatever element sits under `point` to its containing
    /// window, ignoring hits that belong to a different process.
    private func hitTestWindow(at point: CGPoint, pid: pid_t) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &elementRef) == .success,
              let element = elementRef else { return nil }

        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success, elementPID == pid else { return nil }

        for attribute in [kAXWindowAttribute as String, kAXTopLevelUIElementAttribute as String] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success, let ref {
                return (ref as! AXUIElement)
            }
        }

        // Neither attribute is exposed — climb the parent chain to the window.
        var current = element
        for _ in 0..<14 {
            if copyString(current, kAXRoleAttribute as String) == (kAXWindowRole as String) { return current }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parentRef else { return nil }
            current = (parentRef as! AXUIElement)
        }
        return nil
    }

    private func isOverlaySized(_ window: AXUIElement) -> Bool {
        guard let size = windowSize(window) else { return false }
        return size.height >= Self.minOverlayHeight && size.height <= Self.maxOverlayHeight
    }

    private func windowSize(_ window: AXUIElement) -> CGSize? {
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let value = sizeRef, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private func windowSizeDescription(_ window: AXUIElement) -> String {
        guard let size = windowSize(window) else { return "?" }
        return "\(Int(size.width))x\(Int(size.height))"
    }

    private func windowPosition(_ window: AXUIElement) -> CGPoint? {
        var positionRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              let value = positionRef, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    /// Ladder from least to most forceful. Notion's pill exposes no close
    /// affordance at all, so the last rung moves the window off every screen —
    /// it can't be seen, nothing is clicked, and the host app keeps running.
    /// Callers always place a Quiet cover as well: Electron often ignores the
    /// AXPosition write while reporting success.
    private func dismiss(_ window: AXUIElement) -> String {
        if performNamedCloseAction(on: window) { return "dismissed via named action" }
        if pressCloseButton(in: window, depth: 0) { return "dismissed via close button" }
        if AXUIElementPerformAction(window, kAXCancelAction as CFString) == .success {
            return "dismissed via AXCancel"
        }
        if moveOffScreen(window) { return "moved off-screen" }
        return "matched but not dismissable"
    }

    private func moveOffScreen(_ window: AXUIElement) -> Bool {
        var offscreen = CGPoint(x: -30_000, y: -30_000)
        guard let value = AXValueCreate(.cgPoint, &offscreen) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    private func performNamedCloseAction(on element: AXUIElement) -> Bool {
        var actionsRef: CFArray?
        guard AXUIElementCopyActionNames(element, &actionsRef) == .success,
              let actions = actionsRef as? [String] else { return false }
        for action in actions where action.localizedCaseInsensitiveContains("close") {
            if AXUIElementPerformAction(element, action as CFString) == .success {
                return true
            }
        }
        return false
    }

    /// Presses only close/dismiss affordances — never a button that could start
    /// a recording.
    private func pressCloseButton(in element: AXUIElement, depth: Int) -> Bool {
        guard depth < 14 else { return false }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return false }

        for child in children {
            let role = copyString(child, kAXRoleAttribute as String) ?? ""
            if role == (kAXButtonRole as String) {
                let label = [
                    copyString(child, kAXTitleAttribute as String),
                    copyString(child, kAXDescriptionAttribute as String)
                ].compactMap { $0 }.joined(separator: " ")
                if label.localizedCaseInsensitiveContains("close")
                    || label.localizedCaseInsensitiveContains("dismiss")
                    || label == "×" || label == "✕" {
                    if AXUIElementPerformAction(child, kAXPressAction as CFString) == .success {
                        return true
                    }
                }
            }
            if pressCloseButton(in: child, depth: depth + 1) { return true }
        }
        return false
    }

    private func collectText(_ element: AXUIElement, into blob: inout String, depth: Int) {
        // Electron nests web content deeply — the walk must reach past the
        // AXWebArea wrappers to the pill's actual labels.
        guard depth < 14, blob.count < 1500 else { return }
        for attribute in [kAXTitleAttribute as String, kAXDescriptionAttribute as String, kAXValueAttribute as String] {
            if let text = copyString(element, attribute), !text.isEmpty {
                blob += (blob.isEmpty ? "" : " ") + text
            }
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            collectText(child, into: &blob, depth: depth + 1)
        }
    }

    /// Reads a window's text from its pixels, on-device, via Vision.
    ///
    /// Some apps (Wispr Flow) render their pills with no Accessibility content
    /// at all — the AX tree reports only a window title. Nothing text-based can
    /// identify those, so Quiet reads what the user sees instead. Local, no
    /// network, and app-agnostic by construction.
    nonisolated static func recognizeText(windowID: CGWindowID) async -> (text: String, textRect: CGRect)? {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            logger.error("OCR: shareable content failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            logger.error("OCR: window \(windowID) not in \(content.windows.count) shareable windows")
            return nil
        }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * 2)
        configuration.height = Int(window.frame.height * 2)
        configuration.showsCursor = false
        configuration.captureResolution = .best

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: configuration
            )
        } catch {
            logger.error("OCR: capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let request = VNRecognizeTextRequest()
        // Small pills are low-pixel; fast mode misreads Wispr as noise.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        let observations = request.results ?? []
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        // A successful read of an empty surface is a real verdict (a container
        // between pills), distinct from a failed capture, which returns nil.
        var union = CGRect.null
        for observation in observations {
            union = union.union(observation.boundingBox)
        }
        let textRect = union.isNull
            ? CGRect.null
            : Self.quartzRect(ofNormalized: union, inWindowFrame: window.frame).insetBy(dx: -10, dy: -10)
        return (text: lines.joined(separator: " "), textRect: textRect)
    }

    /// Converts a union of Vision bounding boxes (normalized, origin at the
    /// image's bottom-left) into Quartz screen coordinates of the source
    /// window — this is how a pill is located *inside* a container window.
    nonisolated static func quartzRect(ofNormalized union: CGRect, inWindowFrame frame: CGRect) -> CGRect {
        CGRect(
            x: frame.origin.x + union.minX * frame.width,
            y: frame.origin.y + (1 - union.maxY) * frame.height,
            width: union.width * frame.width,
            height: union.height * frame.height
        )
    }

    /// Diagnostics only — reports, for every small on-screen window, whether an
    /// AX element resolves and what text it carries. Verifies the resolution
    /// path against real floating panels without needing a live meeting.
    func probeCandidates() {
        // Deliberately looser than the live gate so third-party floating panels
        // above the pill size cap still report whether they resolve.
        let options = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        let info = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
        var found: [Candidate] = []
        for window in info {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let windowID = window[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat, let height = bounds["Height"] as? CGFloat,
                  height >= Self.minOverlayHeight, height <= 700, width >= 80 else { continue }
            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            guard !bundleID.hasPrefix("com.apple.") else { continue }
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let kind = Self.candidateKind(height: height, width: width, layer: layer) ?? .pill
            found.append(Candidate(pid: pid, windowID: windowID, frame: CGRect(x: x, y: y, width: width, height: height), layer: layer, kind: kind))
        }

        Self.logger.notice("CANDIDATEPROBE \(found.count) third-party window(s)")
        for candidate in found {
            let app = NSRunningApplication(processIdentifier: candidate.pid)
            let label = app?.localizedName ?? app?.bundleIdentifier ?? "pid \(candidate.pid)"
            // Same switch the live path flips — without it Electron reports only
            // the window title and the pill's copy is invisible.
            AXUIElementSetAttributeValue(
                AXUIElementCreateApplication(candidate.pid),
                "AXManualAccessibility" as CFString,
                kCFBooleanTrue
            )
            guard let window = resolveWindow(for: candidate) else {
                Self.logger.notice("CANDIDATEPROBE \(label, privacy: .public) frame=\(candidate.frame.debugDescription, privacy: .public): UNRESOLVED")
                continue
            }
            var blob = ""
            collectText(window, into: &blob, depth: 0)
            let size = windowSizeDescription(window)
            let windowID = candidate.windowID
            Task { @MainActor in
                let ocr = await Self.recognizeText(windowID: windowID)?.text ?? "<no capture>"
                Self.logger.notice("CANDIDATEPROBE \(label, privacy: .public) resolved=\(size, privacy: .public) ax=\(String(blob.prefix(60)), privacy: .public) OCR=\(String(ocr.prefix(140)), privacy: .public)")
            }
        }
    }

    /// Diagnostics only — the matched overlay's element tree, so a cleaner close
    /// affordance can be found without needing another live meeting.
    private func dumpSubtree(_ element: AXUIElement, depth: Int, path: String) {
        guard depth < 12 else { return }
        let role = copyString(element, kAXRoleAttribute as String) ?? "?"
        let title = copyString(element, kAXTitleAttribute as String) ?? ""
        let desc = copyString(element, kAXDescriptionAttribute as String) ?? ""
        var actionsRef: CFArray?
        var actions: [String] = []
        if AXUIElementCopyActionNames(element, &actionsRef) == .success, let list = actionsRef as? [String] {
            actions = list
        }
        if !title.isEmpty || !desc.isEmpty || !actions.isEmpty {
            Self.logger.notice("OVERLAYTREE \(path, privacy: .public) role=\(role, privacy: .public) actions=\(actions.joined(separator: "|"), privacy: .public) title=\(title, privacy: .public) desc=\(desc, privacy: .public)")
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for (i, child) in children.enumerated() {
            dumpSubtree(child, depth: depth + 1, path: path + "/\(i)")
        }
    }

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
