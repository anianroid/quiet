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
    private static let maxOverlayHeight: CGFloat = 260
    /// Below this, a window is a shadow/tooltip artifact rather than a prompt.
    private static let minOverlayHeight: CGFloat = 24

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
    }
    private var ocrVerdicts: [CGWindowID: OCRVerdict] = [:]
    private var ocrPending: Set<CGWindowID> = []
    private static let ocrRecheckInterval: TimeInterval = 3
    /// Screen Recording is optional for this layer — say so once, not per sweep.
    private var loggedCaptureUnavailable = false

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
    }

    /// Meeting start is exactly when apps pop their pills — sweep at frame rate
    /// through that window so nothing is on screen long enough to register.
    func setMeetingActive(_ active: Bool) {
        isMeetingActive = active
        if active {
            // Learned offenders get observers armed before their pill exists.
            armObserversForLearnedApps()
        }
        retune()
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
        let learned = learnedPillApps
        guard !learned.isEmpty else { return }
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, learned.contains(bundleID) else { continue }
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

    /// An on-screen window small enough to be a prompt pill, as CoreGraphics
    /// sees it. CG is the source of truth for geometry because floating panels
    /// (Electron's pills) are routinely absent from an app's AX windows list.
    private struct Candidate {
        let pid: pid_t
        let windowID: CGWindowID
        let frame: CGRect
    }

    private func sweep() {
        guard !isSweeping else { return }
        isSweeping = true
        defer { isSweeping = false }

        // One cheap CG call narrows ~60 running apps to the few owning a small
        // floating window; only those get AX round-trips.
        let found = candidates()
        let ids = Set(found.map(\.windowID))

        // Nothing appeared or disappeared since the last tick, and no capture is
        // in flight — no window can have become a prompt, so skip the AX work.
        // This is what makes a 30ms cadence affordable for a whole meeting.
        if ids == lastCandidateIDs, ocrPending.isEmpty, !hasActionableVerdict(in: ids) {
            return
        }
        lastCandidateIDs = ids

        for candidate in found {
            inspect(candidate)
        }
        pruneVerdicts(seen: ids)
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
                  height >= Self.minOverlayHeight, height <= Self.maxOverlayHeight,
                  width >= 80 else { continue }
            found.append(Candidate(pid: pid, windowID: windowID, frame: CGRect(x: x, y: y, width: width, height: height)))
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

        guard let window = resolveWindow(for: candidate) else {
            if UserDefaults.standard.bool(forKey: "quiet.axDump") {
                Self.logger.notice("OVERLAYDUMP \(bundleID, privacy: .public) frame=\(candidate.frame.debugDescription, privacy: .public): no AX element resolved")
            }
            return
        }
        // Critical safety gate: a hit-test can climb past a pill into the app's
        // main window, and parking that off-screen would be destructive. Only
        // ever act on an element that is itself pill-sized.
        guard isOverlaySized(window), !isOffScreen(window) else {
            if UserDefaults.standard.bool(forKey: "quiet.axDump") {
                Self.logger.notice("OVERLAYDUMP \(bundleID, privacy: .public) resolved to \(self.windowSizeDescription(window), privacy: .public) — too large, skipped")
            }
            return
        }

        var blob = ""
        collectText(window, into: &blob, depth: 0)
        let debug = UserDefaults.standard.bool(forKey: "quiet.axDump")
        if debug {
            let subrole = copyString(window, kAXSubroleAttribute as String) ?? ""
            Self.logger.notice("OVERLAYDUMP \(bundleID, privacy: .public) size=\(self.windowSizeDescription(window), privacy: .public) sub=\(subrole, privacy: .public) text=\(String(blob.prefix(200)), privacy: .public)")
        }

        // Strong copy only — never the ambiguous "Meeting notes" wording a
        // user's own reminder might carry.
        let axSaysPrompt = !blob.isEmpty
            && NotetakerPhrases.containsStrong(blob)
            && !blob.localizedCaseInsensitiveContains("Quiet")

        // Apps that expose no Accessibility content (Wispr Flow) can only be
        // identified by reading their pixels.
        let verdict = ocrVerdicts[candidate.windowID]
        let pixelsSayPrompt = verdict?.isNotetakerPrompt ?? false
        if !axSaysPrompt && !pixelsSayPrompt {
            requestPixelRead(for: candidate)
            return
        }

        if debug {
            dumpSubtree(window, depth: 0, path: bundleID)
        }
        let evidence = axSaysPrompt ? String(blob.prefix(120)) : String((verdict?.text ?? "").prefix(120))
        let source = axSaysPrompt ? "ax" : "pixels"
        let strategy = dismiss(window)
        learn(bundleID: bundleID, pid: candidate.pid)
        Self.logger.notice("Overlay (\(identity.name.isEmpty ? bundleID : identity.name, privacy: .public)) \(strategy, privacy: .public) [\(source, privacy: .public)]: \(evidence, privacy: .public)")
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
            let text = await Self.recognizeText(windowID: windowID)
            guard let self else { return }
            self.ocrPending.remove(windowID)
            guard let text else {
                // No capture — Screen Recording is off. AX-only from here.
                if !self.loggedCaptureUnavailable {
                    self.loggedCaptureUnavailable = true
                    Self.logger.notice("Pixel reading unavailable (Screen Recording not granted) — overlay suppression is Accessibility-only for apps that expose no AX content")
                }
                return
            }
            let isPrompt = NotetakerPhrases.containsStrong(text)
                && !text.localizedCaseInsensitiveContains("Quiet")
            self.ocrVerdicts[windowID] = OCRVerdict(
                isNotetakerPrompt: isPrompt,
                checkedAt: Date(),
                text: text
            )
            // Logged either way: a prompt Quiet read but judged benign is the
            // failure mode that is otherwise invisible in the field.
            Self.logger.notice("Pixel read \(isPrompt ? "MATCH" : "no-match", privacy: .public) window \(windowID): \(String(text.prefix(140)), privacy: .public)")
        }
    }

    /// Drops verdicts for windows that no longer exist so the cache can't grow
    /// without bound over a long session.
    private func pruneVerdicts(seen: Set<CGWindowID>) {
        guard ocrVerdicts.count > 64 else { return }
        ocrVerdicts = ocrVerdicts.filter { seen.contains($0.key) }
    }

    /// Finds the AX element for a CG window. The app's AX windows list is tried
    /// first, then a hit-test at the window's centre — floating panels (which is
    /// what these pills are) are frequently missing from that list entirely.
    private func resolveWindow(for candidate: Candidate) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(candidate.pid)
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {
            for window in windows {
                guard let position = windowPosition(window), let size = windowSize(window) else { continue }
                // Same origin and roughly the same size as the CG window.
                if abs(position.x - candidate.frame.origin.x) < 4,
                   abs(position.y - candidate.frame.origin.y) < 4,
                   abs(size.height - candidate.frame.height) < 8 {
                    return window
                }
            }
        }
        return hitTestWindow(at: CGPoint(x: candidate.frame.midX, y: candidate.frame.midY), pid: candidate.pid)
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

    /// A pill already parked stays handled — re-moving it every tick would spam
    /// the log to no visible effect.
    private func isOffScreen(_ window: AXUIElement) -> Bool {
        guard let point = windowPosition(window) else { return false }
        return point.x < -20_000
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
    nonisolated static func recognizeText(windowID: CGWindowID) async -> String? {
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
        // Prompt copy is large and high-contrast — accuracy costs more than it buys.
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
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
            found.append(Candidate(pid: pid, windowID: windowID, frame: CGRect(x: x, y: y, width: width, height: height)))
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
                let ocr = await Self.recognizeText(windowID: windowID) ?? "<no capture>"
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
