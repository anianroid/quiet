import AVFoundation
import AppKit
import ApplicationServices
import Combine
import Foundation
import SwiftUI
import os.log

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Keys.onboarding) }
    }

    /// Hold Otter/Granola/Fireflies quit **during meetings only**. Outside a
    /// meeting every app runs freely — the user may open any notetaker; only
    /// its meeting prompts are suppressed (banner + overlay layers).
    @Published var quitCompetitorsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(quitCompetitorsEnabled, forKey: Keys.quitCompetitors)
            // The watchdog only ever runs during a live meeting.
            guard isMeetingActive else { return }
            if quitCompetitorsEnabled {
                armCompetitorWatchdog()
            } else {
                // Turning the hold off mid-meeting thaws immediately.
                competitorWatchdog.stop()
                recordHijackActions(processController.resumeSuspendedCompetitors())
            }
        }
    }

    /// Dismiss banners via Accessibility (Notification Center only). On by default.
    @Published var dismissBannersEnabled: Bool {
        didSet { UserDefaults.standard.set(dismissBannersEnabled, forKey: Keys.dismissBanners) }
    }

    @Published var autoCaptureEnabled: Bool {
        didSet { UserDefaults.standard.set(autoCaptureEnabled, forKey: Keys.autoCapture) }
    }

    /// One-time: user turned off Zoom’s built-in Take notes / AI Companion.
    @Published var hostZoomNotesDisabled: Bool {
        didSet { UserDefaults.standard.set(hostZoomNotesDisabled, forKey: Keys.hostZoom) }
    }

    /// One-time: user turned off Notion AI meeting notes prompts.
    @Published var hostNotionNotesDisabled: Bool {
        didSet { UserDefaults.standard.set(hostNotionNotesDisabled, forKey: Keys.hostNotion) }
    }

    /// One-time: user turned off Notion Calendar's notetaker pill.
    @Published var hostNotionCalendarNotesDisabled: Bool {
        didSet { UserDefaults.standard.set(hostNotionCalendarNotesDisabled, forKey: Keys.hostNotionCalendar) }
    }

    /// One-time: Wispr Flow's meeting auto-detection turned off. Read from
    /// Wispr's own config (not a stored flag) so it survives reinstalls and
    /// reflects changes made inside Wispr itself.
    @Published var wisprNotesSilenced = false

    /// While paused Quiet stops guarding entirely — watchdog, banner dismissal,
    /// and meeting detection are off until `pausedUntil` (or Resume now).
    @Published var isPaused = false
    @Published var pausedUntil: Date?

    @Published var installedCompetitors: [InstalledCompetitor] = []
    @Published var lastScanAt: Date?
    @Published var isMeetingActive = false
    @Published var isCapturing = false
    @Published var liveTranscript = ""
    @Published var hijackLog: [HijackAction] = []
    @Published var currentSession: MeetingSession?
    @Published var latestNotesURL: URL?
    @Published var statusMessage = "Idle"
    @Published var permissionSnapshot = PermissionStatus()

    let catalog: CompetitorCatalog
    let scanner: CompetitorScanner
    let processController: ProcessController
    let notificationWatcher: NotificationWatcher
    let hostOverlayWatcher: HostOverlayWatcher
    let quietBanner: QuietBannerController
    let meetingDetector: MeetingDetector
    let audioCapture: AudioCaptureSession
    let micCapture: MicCaptureSession
    let summarizer: NotesSummarizer
    let notesStore: NotesStore
    let competitorWatchdog: CompetitorWatchdog

    private let logger = Logger(subsystem: "notes.quiet.app", category: "Pipeline")
    private var detectorTask: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?
    private var appLaunchObserver: NSObjectProtocol?
    private var meetingTranscriber: MeetingTranscriber?
    private var transcriptTask: Task<Void, Never>?
    /// Startup of the capture pipeline is slow (asset check, model load) —
    /// kept so handleMeetingEnded can cancel a pipeline still arming.
    private var captureStartTask: Task<Void, Never>?

    // Live transcript merge state: finals append, volatiles replace per source.
    private var finalizedLines: [String] = []
    private var volatileBySource: [TranscriptSource: String] = [:]

    /// Checkpoint file for the in-flight transcript — a crash mid-meeting becomes
    /// "Recovered notes" on next launch instead of a lost meeting.
    private var inflightURL: URL?

    private var notesRootURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs.appendingPathComponent("Kamui", isDirectory: true)
    }

    /// One-time brand migration: notes lived in Documents/Quiet before the
    /// app became Kamui. Old folder moves whole; nothing merges.
    private func migrateLegacyNotesFolder() {
        let fm = FileManager.default
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        let legacy = docs.appendingPathComponent("Quiet", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path),
              !fm.fileExists(atPath: notesRootURL.path) else { return }
        try? fm.moveItem(at: legacy, to: notesRootURL)
    }

    private enum Keys {
        static let onboarding = "quiet.hasCompletedOnboarding"
        static let quitCompetitors = "quiet.quitCompetitorsEnabled"
        static let dismissBanners = "quiet.dismissBannersEnabled"
        static let autoCapture = "quiet.autoCaptureEnabled"
        static let hostZoom = "quiet.hostNotesDisabled.zoom"
        static let hostNotion = "quiet.hostNotesDisabled.notion"
        static let hostNotionCalendar = "quiet.hostNotesDisabled.notionCalendar"
    }


    var isZoomInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "us.zoom.xos") != nil
            || FileManager.default.fileExists(atPath: "/Applications/zoom.us.app")
    }

    var isNotionInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "notion.id") != nil
            || FileManager.default.fileExists(atPath: "/Applications/Notion.app")
    }

    var isNotionCalendarInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.cron.electron") != nil
            || FileManager.default.fileExists(atPath: "/Applications/Notion Calendar.app")
    }

    var isWisprInstalled: Bool { WisprSilencer.isInstalled }

    /// True when every installed host that can spam Take notes is marked done.
    var hostOwnsNotesComplete: Bool {
        let zoomOK = !isZoomInstalled || hostZoomNotesDisabled
        let notionOK = !isNotionInstalled || hostNotionNotesDisabled
        let notionCalOK = !isNotionCalendarInstalled || hostNotionCalendarNotesDisabled
        let wisprOK = !isWisprInstalled || wisprNotesSilenced
        return zoomOK && notionOK && notionCalOK && wisprOK
    }

    func refreshWisprSilenced() {
        wisprNotesSilenced = WisprSilencer.isSilenced() ?? false
    }

    /// Flips Wispr's meeting detection at the source (its own config) —
    /// quits, patches, relaunches. Dictation is untouched.
    func setWisprNotetakerSilenced(_ silenced: Bool) async {
        let landed = await WisprSilencer.setSilenced(silenced)
        refreshWisprSilenced()
        statusMessage = landed
            ? (silenced ? "Wispr notetaker silenced at the source" : "Wispr notetaker re-enabled")
            : "Couldn't update Wispr's settings — is it installed?"
    }

    private init() {
        self.catalog = CompetitorCatalog.loadBundled()
        self.scanner = CompetitorScanner(catalog: catalog)
        self.processController = ProcessController(catalog: catalog)
        self.notificationWatcher = NotificationWatcher(catalog: catalog)
        self.hostOverlayWatcher = HostOverlayWatcher(catalog: catalog)
        self.quietBanner = QuietBannerController()
        self.meetingDetector = MeetingDetector()
        self.audioCapture = AudioCaptureSession()
        self.micCapture = MicCaptureSession()
        self.summarizer = NotesSummarizer()
        self.notesStore = NotesStore()
        self.competitorWatchdog = CompetitorWatchdog(processController: processController)

        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Keys.onboarding)
        self.quitCompetitorsEnabled = UserDefaults.standard.object(forKey: Keys.quitCompetitors) as? Bool ?? true
        self.dismissBannersEnabled = UserDefaults.standard.object(forKey: Keys.dismissBanners) as? Bool ?? true
        // New pipeline — default stays off until it survives a real meeting, then flips.
        self.autoCaptureEnabled = UserDefaults.standard.object(forKey: Keys.autoCapture) as? Bool ?? false
        self.hostZoomNotesDisabled = UserDefaults.standard.bool(forKey: Keys.hostZoom)
        self.hostNotionNotesDisabled = UserDefaults.standard.bool(forKey: Keys.hostNotion)
        self.hostNotionCalendarNotesDisabled = UserDefaults.standard.bool(forKey: Keys.hostNotionCalendar)
        // Orphan setting removed — quitCompetitorsEnabled is the one kill switch.
        UserDefaults.standard.removeObject(forKey: "quiet.hijackEnabled")

        // Every prompt pulled into the notch gets one ripple on the island.
        hostOverlayWatcher.onSwallow = { [weak quietBanner] in
            quietBanner?.acknowledgeSwallow()
        }

        refreshPermissions()
        refreshWisprSilenced()
        // A previous session that crashed mid-meeting may have left a
        // competitor frozen. Thaw everything before doing anything else.
        processController.thawEveryCompetitor()
        installedCompetitors = scanner.scan()
        lastScanAt = Date()
        migrateLegacyNotesFolder()
        recoverOrphanedTranscripts()

        // Debug only: hold the island in its meeting/recording state so the
        // design can be reviewed without joining a call.
        // `defaults write notes.quiet.app quiet.debugIslandState -string recording`
        if let debugState = UserDefaults.standard.string(forKey: "quiet.debugIslandState") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.quietBanner.showMeetingStatus(
                    message: "Kamui · Meeting",
                    capturing: debugState == "recording"
                )
            }
        }

        if hasCompletedOnboarding {
            startMonitoring()
        } else {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func openZoomForHostSetup() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "us.zoom.xos") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/zoom.us.app"))
        }
    }

    func openNotionForHostSetup() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "notion.id") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Notion.app"))
        }
    }

    func openNotionCalendarForHostSetup() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.cron.electron") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Notion Calendar.app"))
        }
    }

    func markInstalledHostsNotesDone() {
        if isZoomInstalled { hostZoomNotesDisabled = true }
        if isNotionInstalled { hostNotionNotesDisabled = true }
        if isNotionCalendarInstalled { hostNotionCalendarNotesDisabled = true }
        // Wispr's step is automatable — do it rather than mark it.
        if isWisprInstalled, !wisprNotesSilenced {
            Task { await setWisprNotetakerSilenced(true) }
        }
    }

    func rescanCompetitors() {
        installedCompetitors = scanner.scan()
        lastScanAt = Date()
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        startMonitoring()
        statusMessage = "Ready — Kamui will handle meetings"
    }

    func refreshPermissions() {
        permissionSnapshot = PermissionStatus.current()
    }

    func startMonitoring() {
        logger.notice("startMonitoring paused=\(self.isPaused) dismissBanners=\(self.dismissBannersEnabled) quitCompetitors=\(self.quitCompetitorsEnabled)")
        // Nothing arms while paused — resumeNow() calls back in when the hour is up.
        guard !isPaused else { return }
        detectorTask?.cancel()

        // Competitors are held down only while a meeting is live — outside
        // meetings the user is free to open and use any notetaker, and only
        // its meeting prompts get suppressed. Ensure nothing is left armed
        // from a previous state.
        competitorWatchdog.stop()

        if dismissBannersEnabled {
            notificationWatcher.start()
            hostOverlayWatcher.start()
        } else {
            notificationWatcher.stop()
            hostOverlayWatcher.stop()
        }

        // The watchdog tick never touches disk, so refresh the installed list
        // whenever any app launches (plus launch and settings open).
        if appLaunchObserver == nil {
            appLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    AppState.shared.rescanCompetitors()
                }
            }
        }

        detectorTask = Task { [weak self] in
            guard let self else { return }
            for await event in await meetingDetector.events() {
                switch event {
                case .started(let source):
                    await self.handleMeetingStarted(source: source)
                case .ended:
                    await self.handleMeetingEnded()
                }
            }
        }
    }

    /// Pauses all guarding (watchdog, banner dismissal, meeting detection) and
    /// schedules an automatic resume — the intentional "let me use Otter once" path.
    func pause(for duration: TimeInterval = 3600) {
        guard !isPaused else { return }

        // A live session ends cleanly first so its notes aren't stranded.
        if isMeetingActive {
            Task { await self.handleMeetingEnded() }
        }

        isPaused = true
        let until = Date().addingTimeInterval(duration)
        pausedUntil = until

        detectorTask?.cancel()
        detectorTask = nil
        competitorWatchdog.stop()
        recordHijackActions(processController.resumeSuspendedCompetitors())
        notificationWatcher.stop()
        hostOverlayWatcher.stop()

        statusMessage = "Paused until \(until.formatted(date: .omitted, time: .shortened))"
        logger.info("Paused monitoring for \(Int(duration), privacy: .public)s")

        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.resumeNow()
        }
    }

    func resumeNow() {
        guard isPaused else { return }
        resumeTask?.cancel()
        resumeTask = nil
        isPaused = false
        pausedUntil = nil
        statusMessage = "Ready — Kamui will handle meetings"
        logger.info("Resumed monitoring")
        startMonitoring()
    }

    /// Newest first, bounded so weeks of watchdog kills can't grow without limit.
    private func recordHijackActions(_ actions: [HijackAction]) {
        hijackLog.insert(contentsOf: actions, at: 0)
        if hijackLog.count > 200 {
            hijackLog.removeLast(hijackLog.count - 200)
        }
    }

    func manualStart() async {
        await handleMeetingStarted(source: "Manual")
    }

    func manualStop() async {
        await handleMeetingEnded()
    }

    private func handleMeetingStarted(source: String) async {
        guard !isMeetingActive else { return }
        isMeetingActive = true
        statusMessage = "Meeting detected — \(source)"

        // Fresh scan so newly launched helpers (Granola/Fireflies) are in scope.
        rescanCompetitors()

        var session = MeetingSession(
            id: UUID(),
            startedAt: Date(),
            endedAt: nil,
            sourceApp: source,
            hijackLog: [],
            transcriptSegments: [],
            summary: nil,
            notesPath: nil
        )

        if quitCompetitorsEnabled {
            let actions = processController.suspendCompetitors(from: installedCompetitors)
            session.hijackLog.append(contentsOf: actions)
            recordHijackActions(actions)
            let names = actions.map(\.competitorName).joined(separator: ", ")
            if !names.isEmpty {
                statusMessage = "Meeting detected — silenced \(names)"
            }
            // Hold respawns and late launches down for the rest of the meeting.
            armCompetitorWatchdog()
        }

        if dismissBannersEnabled {
            notificationWatcher.start()
            hostOverlayWatcher.start()
            notificationWatcher.setMeetingActive(true)
            hostOverlayWatcher.setMeetingActive(true)
        }

        // Persistent notch island for the meeting — not a 5s toast.
        quietBanner.showMeetingStatus(message: "Kamui · Meeting")
        currentSession = session

        // Guard boundary: any capture/transcription failure leaves the guardian
        // running with competitors held — capture is strictly additive.
        if autoCaptureEnabled {
            let sessionID = session.id
            captureStartTask?.cancel()
            captureStartTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.beginCapturePipeline(sessionID: sessionID)
                    // The meeting may have ended while the pipeline was
                    // suspended (asset check, model load) — never resurrect
                    // capture or the Capturing island for an ended session.
                    guard self.isMeetingActive, self.currentSession?.id == sessionID else {
                        await self.tearDownStaleCapture()
                        return
                    }
                    self.isCapturing = true
                    self.statusMessage = "Capturing — \(source)"
                    self.quietBanner.showMeetingStatus(message: "Kamui · Capturing", capturing: true)
                } catch is CancellationError {
                    // handleMeetingEnded cancelled us mid-startup — undo
                    // whatever half of the pipeline already came up.
                    await self.tearDownStaleCapture()
                } catch {
                    self.logger.error("Capture pipeline failed to start: \(error.localizedDescription, privacy: .public)")
                    self.audioCapture.stop()
                    self.micCapture.stop()
                    self.isCapturing = false
                    guard self.isMeetingActive, self.currentSession?.id == sessionID else { return }
                    self.statusMessage = "Holding competitors; capture off — \(error.localizedDescription)"
                    self.quietBanner.showMeetingStatus(message: "Kamui · Meeting")
                }
            }
        } else {
            statusMessage = "Meeting detected — \(source). Competitors held."
        }
    }

    private func beginCapturePipeline(sessionID: UUID) async throws {
        // Check only — the model downloads during onboarding/Settings, never mid-meeting.
        guard await TranscriptionAssets.isInstalled() else {
            throw TranscriptionAssetError.modelNotInstalled
        }
        // The asset check suspends — bail before touching audio if the
        // meeting ended (handleMeetingEnded cancels captureStartTask).
        try Task.checkCancellation()

        finalizedLines = []
        volatileBySource = [:]
        liveTranscript = ""
        inflightURL = notesRootURL.appendingPathComponent(".inflight-\(sessionID.uuidString).md")

        let systemStream = try audioCapture.start()
        var micStream: AsyncStream<PCMBufferBox>?
        do {
            micStream = try micCapture.start()
        } catch {
            // Mic failure degrades to system-only — half a transcript beats none.
            logger.warning("Mic capture unavailable, continuing system-only: \(error.localizedDescription, privacy: .public)")
        }

        let transcriber = MeetingTranscriber()
        meetingTranscriber = transcriber
        let segments = await transcriber.start(systemAudio: systemStream, micAudio: micStream)
        // Model load inside transcriber.start is the widest suspension window —
        // if the meeting ended during it, unwind instead of arming transcription.
        try Task.checkCancellation()

        transcriptTask?.cancel()
        transcriptTask = Task { [weak self] in
            for await segment in segments {
                guard let self else { return }
                self.ingest(segment)
            }
        }
    }

    /// Unwinds whatever a stale startup task brought up after the meeting
    /// already ended — capture must never outlive its meeting.
    private func tearDownStaleCapture() async {
        audioCapture.stop()
        micCapture.stop()
        if let transcriber = meetingTranscriber {
            await transcriber.finish()
            meetingTranscriber = nil
        }
        transcriptTask?.cancel()
        transcriptTask = nil
        isCapturing = false
    }

    private func ingest(_ segment: TranscriptSegment) {
        // Only finals belong in the session record — volatiles are replaced, not
        // accumulated, and would grow without bound over a long meeting.
        if segment.isFinal {
            currentSession?.transcriptSegments.append(segment)
            volatileBySource[segment.source] = nil
            finalizedLines.append(segment.source.speakerLabel + ": " + segment.text)
            checkpointTranscript()
        } else {
            volatileBySource[segment.source] = segment.text
        }
        liveTranscript = Self.mergeTranscript(finalized: finalizedLines, volatile: volatileBySource)
    }

    /// Renders the live transcript: finalized lines first, then per-source volatiles
    /// (which each new partial result replaces), all with Me:/Them: prefixes.
    static func mergeTranscript(finalized: [String], volatile: [TranscriptSource: String]) -> String {
        var lines = finalized
        for source in [TranscriptSource.system, .mic] {
            if let text = volatile[source], !text.isEmpty {
                lines.append(source.speakerLabel + ": " + text)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func checkpointTranscript() {
        guard let inflightURL else { return }
        do {
            try FileManager.default.createDirectory(at: notesRootURL, withIntermediateDirectories: true)
            try finalizedLines.joined(separator: "\n").write(to: inflightURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Transcript checkpoint failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Promotes `.inflight-*` checkpoints left by a crash into visible "Recovered notes"
    /// so an interrupted meeting is never a lost meeting.
    private func recoverOrphanedTranscripts() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: notesRootURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"

        for orphan in contents where orphan.lastPathComponent.hasPrefix(".inflight-") && orphan.pathExtension == "md" {
            guard let transcript = try? String(contentsOf: orphan, encoding: .utf8),
                  !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                try? fm.removeItem(at: orphan)
                continue
            }
            let modified = (try? orphan.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let folder = notesRootURL.appendingPathComponent(formatter.string(from: modified) + "-Recovered", isDirectory: true)
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let notesURL = folder.appendingPathComponent("Notes.md")
                let notes = """
                # Recovered notes

                Kamui quit unexpectedly during this meeting. The transcript below was \
                checkpointed live and recovered on launch.
                """
                try notes.write(to: notesURL, atomically: true, encoding: .utf8)
                try ("# Transcript\n\n" + transcript).write(
                    to: folder.appendingPathComponent("Transcript.md"),
                    atomically: true,
                    encoding: .utf8
                )
                try fm.removeItem(at: orphan)
                latestNotesURL = notesURL
                statusMessage = "Recovered notes from an interrupted meeting"
                logger.info("Recovered in-flight transcript to \(folder.lastPathComponent, privacy: .public)")
            } catch {
                logger.error("Failed to recover \(orphan.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Holds competitors down for the duration of a meeting — respawns and
    /// late launches included. Never runs outside one.
    private func armCompetitorWatchdog() {
        competitorWatchdog.start { [weak self] actions in
            guard let self else { return }
            self.recordHijackActions(actions)
            self.currentSession?.hijackLog.append(contentsOf: actions)
        }
    }

    private func handleMeetingEnded() async {
        guard isMeetingActive else { return }
        isMeetingActive = false
        isCapturing = false
        competitorWatchdog.stop()
        // Thaw before anything that can throw or suspend — a frozen notetaker
        // must never outlive the meeting that froze it.
        recordHijackActions(processController.resumeSuspendedCompetitors())
        hostOverlayWatcher.setMeetingActive(false)
        notificationWatcher.setMeetingActive(false)
        quietBanner.hide()

        // A pipeline still starting up must not finish arming after the end.
        captureStartTask?.cancel()
        captureStartTask = nil

        // Stop capture first so both audio streams finish, then let the transcriber
        // finalize — the last final segments flow through the stream before it ends.
        audioCapture.stop()
        micCapture.stop()
        if let transcriber = meetingTranscriber {
            await transcriber.finish()
            meetingTranscriber = nil
        }
        await transcriptTask?.value
        transcriptTask = nil

        guard var session = currentSession else { return }
        session.endedAt = Date()

        let transcript = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let checkpoint = inflightURL

        // Reset live merge state up-front — the Keep/Discard flow works from
        // `session` and disk, and the next meeting must start clean.
        liveTranscript = ""
        finalizedLines = []
        volatileBySource = [:]
        inflightURL = nil

        guard !transcript.isEmpty else {
            commitEndedSession(session, ifStillCurrent: session.id)
            statusMessage = "Meeting ended"
            removeCheckpoint(checkpoint)
            return
        }

        // Junk meetings (joined and left, mic checks) never earn a prompt —
        // the elegant behavior is not asking.
        guard await summarizer.isSubstantive(transcript: transcript) else {
            logger.info("Transcript judged not substantive — discarding without prompt")
            commitEndedSession(nil, ifStillCurrent: session.id)
            statusMessage = "Meeting ended"
            removeCheckpoint(checkpoint)
            return
        }

        var summary: MeetingSummary?
        do {
            summary = try await summarizer.summarize(transcript: transcript)
        } catch {
            // Summarization failure still offers Keep/Discard with the raw transcript.
            logger.error("Summarization failed: \(error.localizedDescription, privacy: .public)")
        }
        session.summary = summary

        do {
            _ = try notesStore.writePending(session: session, transcript: transcript, summary: summary)
        } catch {
            // Keep the checkpoint: the transcript surfaces as Recovered notes next launch.
            logger.error("Failed to stage notes: \(error.localizedDescription, privacy: .public)")
            commitEndedSession(session, ifStillCurrent: session.id)
            statusMessage = "Notes staging failed: \(error.localizedDescription)"
            return
        }

        commitEndedSession(session, ifStillCurrent: session.id)
        statusMessage = "Notes ready — Keep or Discard?"
        quietBanner.showKeepDiscard(
            message: Self.keepDiscardMessage(summary: summary),
            onKeep: { [weak self] in self?.resolveKeep(session: session, checkpoint: checkpoint) },
            onDiscard: { [weak self] in self?.resolveDiscard(session: session, checkpoint: checkpoint) }
        )
    }

    /// Writes back the ended session only while it is still the current one —
    /// isSubstantive/summarize suspend for seconds, during which a new meeting
    /// can start, and its live record must never be clobbered by an ended one.
    private func commitEndedSession(_ session: MeetingSession?, ifStillCurrent id: UUID) {
        if currentSession?.id == id {
            currentSession = session
        }
    }

    /// One-line notch prompt: "Kamui · Notes ready — 3 actions · 1 decision — <gist>".
    static func keepDiscardMessage(summary: MeetingSummary?) -> String {
        guard let summary else {
            return "Kamui · Summary unavailable — transcript saved"
        }
        let actions = pluralized(summary.actions.count, "action")
        let decisions = pluralized(summary.decisions.count, "decision")
        var message = "Kamui · Notes ready — \(actions) · \(decisions)"
        if let gist = gist(for: summary) {
            message += " — " + gist
        }
        return message
    }

    private static func pluralized(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)" + (count == 1 ? "" : "s")
    }

    /// The model-generated title when present, else the first sentence of the overview.
    private static func gist(for summary: MeetingSummary) -> String? {
        if let title = summary.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        let overview = summary.overview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !overview.isEmpty else { return nil }
        let sentence = overview.prefix(while: { !".!?".contains($0) })
        return String(sentence.prefix(60))
    }

    private func resolveKeep(session: MeetingSession, checkpoint: URL?) {
        do {
            let url = try notesStore.keep(session: session)
            if currentSession?.id == session.id {
                currentSession?.notesPath = url
            }
            latestNotesURL = url
            statusMessage = "Notes saved"
            quietBanner.show(message: "Notes saved", duration: 4)
            removeCheckpoint(checkpoint)
        } catch {
            // Staged notes stay in .pending and the checkpoint stays — nothing is lost.
            logger.error("Keeping notes failed: \(error.localizedDescription, privacy: .public)")
            statusMessage = "Saving notes failed: \(error.localizedDescription)"
        }
    }

    private func resolveDiscard(session: MeetingSession, checkpoint: URL?) {
        notesStore.discardPending(sessionID: session.id)
        if currentSession?.id == session.id {
            // Discard means nothing persists — including the in-memory transcript.
            currentSession = nil
        }
        statusMessage = "Notes discarded"
        removeCheckpoint(checkpoint)
        logger.info("Discarded notes for session \(session.id.uuidString, privacy: .public)")
    }

    private func removeCheckpoint(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

struct PermissionStatus: Equatable {
    var screenRecording = false
    var microphone = false
    var accessibility = false

    static func current() -> PermissionStatus {
        var status = PermissionStatus()
        status.screenRecording = CGPreflightScreenCaptureAccess()
        status.accessibility = AXIsProcessTrusted()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            status.microphone = true
        default:
            status.microphone = false
        }
        return status
    }
}
