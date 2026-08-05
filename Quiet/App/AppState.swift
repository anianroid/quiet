import AVFoundation
import AppKit
import ApplicationServices
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Keys.onboarding) }
    }

    @Published var hijackEnabled: Bool {
        didSet { UserDefaults.standard.set(hijackEnabled, forKey: Keys.hijack) }
    }

    /// Force-quit Otter/Granola/Fireflies while Quiet is armed. Safe — no Accessibility UI walking.
    @Published var quitCompetitorsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(quitCompetitorsEnabled, forKey: Keys.quitCompetitors)
            // Re-arm / disarm watchdog when the toggle flips while monitoring.
            if hasCompletedOnboarding {
                startMonitoring()
            }
        }
    }

    /// Dismiss banners via Accessibility (Notification Center only). Off by default after the freeze.
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
    let quietBanner: QuietBannerController
    let meetingDetector: MeetingDetector
    let audioCapture: AudioCaptureSession
    let speechService: SpeechTranscriberService
    let summarizer: NotesSummarizer
    let notesStore: NotesStore
    let competitorWatchdog: CompetitorWatchdog

    private var detectorTask: Task<Void, Never>?

    private enum Keys {
        static let onboarding = "quiet.hasCompletedOnboarding"
        static let hijack = "quiet.hijackEnabled"
        static let quitCompetitors = "quiet.quitCompetitorsEnabled"
        static let dismissBanners = "quiet.dismissBannersEnabled"
        static let autoCapture = "quiet.autoCaptureEnabled"
        static let hostZoom = "quiet.hostNotesDisabled.zoom"
        static let hostNotion = "quiet.hostNotesDisabled.notion"
    }

    var menuBarSymbolName: String {
        if isCapturing { return "waveform.circle.fill" }
        if isMeetingActive { return "record.circle" }
        return "waveform"
    }

    var isZoomInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "us.zoom.xos") != nil
            || FileManager.default.fileExists(atPath: "/Applications/zoom.us.app")
    }

    var isNotionInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "notion.id") != nil
            || FileManager.default.fileExists(atPath: "/Applications/Notion.app")
    }

    /// True when every installed host that can spam Take notes is marked done.
    var hostOwnsNotesComplete: Bool {
        let zoomOK = !isZoomInstalled || hostZoomNotesDisabled
        let notionOK = !isNotionInstalled || hostNotionNotesDisabled
        return zoomOK && notionOK
    }

    private init() {
        self.catalog = CompetitorCatalog.loadBundled()
        self.scanner = CompetitorScanner(catalog: catalog)
        self.processController = ProcessController(catalog: catalog)
        self.notificationWatcher = NotificationWatcher(catalog: catalog)
        self.quietBanner = QuietBannerController()
        self.meetingDetector = MeetingDetector()
        self.audioCapture = AudioCaptureSession()
        self.speechService = SpeechTranscriberService()
        self.summarizer = NotesSummarizer()
        self.notesStore = NotesStore()
        self.competitorWatchdog = CompetitorWatchdog(
            processController: processController,
            scanner: scanner
        )

        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Keys.onboarding)
        self.hijackEnabled = UserDefaults.standard.object(forKey: Keys.hijack) as? Bool ?? true
        self.quitCompetitorsEnabled = UserDefaults.standard.object(forKey: Keys.quitCompetitors) as? Bool ?? true
        self.dismissBannersEnabled = UserDefaults.standard.object(forKey: Keys.dismissBanners) as? Bool ?? true
        // Capture/Speech crashes Quiet today — guardian-only until XPC capture lands.
        self.autoCaptureEnabled = UserDefaults.standard.object(forKey: Keys.autoCapture) as? Bool ?? false
        self.hostZoomNotesDisabled = UserDefaults.standard.bool(forKey: Keys.hostZoom)
        self.hostNotionNotesDisabled = UserDefaults.standard.bool(forKey: Keys.hostNotion)

        refreshPermissions()
        installedCompetitors = scanner.scan()
        lastScanAt = Date()

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

    func markInstalledHostsNotesDone() {
        if isZoomInstalled { hostZoomNotesDisabled = true }
        if isNotionInstalled { hostNotionNotesDisabled = true }
    }

    func rescanCompetitors() {
        installedCompetitors = scanner.scan()
        lastScanAt = Date()
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        startMonitoring()
        statusMessage = "Ready — Quiet will handle meetings"
    }

    func refreshPermissions() {
        permissionSnapshot = PermissionStatus.current()
    }

    func startMonitoring() {
        detectorTask?.cancel()

        // Keep sidecars dead the whole time Quiet is armed — not only after Meet starts.
        if quitCompetitorsEnabled {
            competitorWatchdog.start { [weak self] actions in
                guard let self else { return }
                self.hijackLog.insert(contentsOf: actions, at: 0)
                let names = Array(Set(actions.map(\.competitorName))).sorted().joined(separator: ", ")
                if !self.isMeetingActive {
                    self.statusMessage = "Holding off: \(names)"
                }
            }
        } else {
            competitorWatchdog.stop()
        }

        if dismissBannersEnabled {
            notificationWatcher.start()
        } else {
            notificationWatcher.stop()
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

        if quitCompetitorsEnabled || hijackEnabled {
            let actions = processController.suspendCompetitors(from: installedCompetitors)
            session.hijackLog.append(contentsOf: actions)
            hijackLog.insert(contentsOf: actions, at: 0)
            let names = actions.map(\.competitorName).joined(separator: ", ")
            if !names.isEmpty {
                statusMessage = "Meeting detected — silenced \(names)"
            }
        }

        if dismissBannersEnabled {
            notificationWatcher.start()
        }

        // Persistent notch island for the meeting — not a 5s toast.
        quietBanner.showMeetingStatus(message: "Quiet · Meeting")
        currentSession = session

        // Guardian-only: do not start Speech/audio on meeting detect.
        // That path was SIGTRAP-crashing Quiet and undoing silencing.
        if autoCaptureEnabled {
            statusMessage = "Meeting detected — \(source) (capture experimental)"
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.beginCapturePipeline()
                    await MainActor.run {
                        self.isCapturing = true
                        self.statusMessage = "Capturing — \(source)"
                        self.quietBanner.showMeetingStatus(message: "Quiet · Capturing")
                    }
                } catch {
                    await MainActor.run {
                        self.isCapturing = false
                        self.statusMessage = "Holding competitors; capture off — \(error.localizedDescription)"
                        self.quietBanner.showMeetingStatus(message: "Quiet · Meeting")
                    }
                }
            }
        } else {
            statusMessage = "Meeting detected — \(source). Competitors held."
        }
    }

    private func beginCapturePipeline() async throws {
        speechService.onSegment = { [weak self] segment in
            Task { @MainActor in
                guard let self else { return }
                self.liveTranscript = Self.mergeTranscript(existing: self.liveTranscript, segment: segment)
                self.currentSession?.transcriptSegments.append(segment)
            }
        }
        try await speechService.prepare()
        let stream = try audioCapture.start()
        try await speechService.start(input: stream)
    }

    private func handleMeetingEnded() async {
        guard isMeetingActive else { return }
        isMeetingActive = false
        isCapturing = false
        quietBanner.hide()

        audioCapture.stop()
        await speechService.finish()

        guard var session = currentSession else { return }
        session.endedAt = Date()

        let transcript = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !transcript.isEmpty {
            do {
                let summary = try await summarizer.summarize(transcript: transcript)
                session.summary = summary
                let url = try notesStore.write(session: session, transcript: transcript, summary: summary)
                session.notesPath = url
                latestNotesURL = url
                statusMessage = "Notes ready"
                quietBanner.show(message: "Notes ready", duration: 4)
            } catch {
                statusMessage = "Summary failed: \(error.localizedDescription)"
            }
        } else {
            statusMessage = "Meeting ended"
        }

        currentSession = session
        liveTranscript = ""
    }

    private static func mergeTranscript(existing: String, segment: TranscriptSegment) -> String {
        if segment.isFinal {
            let base = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            return base.isEmpty ? segment.text : base + "\n" + segment.text
        }
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.isEmpty { return segment.text }
        var mutable = lines
        mutable[mutable.count - 1] = segment.text
        return mutable.joined(separator: "\n")
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
