import Foundation
import Speech
import os.log

enum TranscriptionAssetError: LocalizedError {
    case transcriptionUnavailable
    case unsupportedLocale
    case modelNotInstalled

    var errorDescription: String? {
        switch self {
        case .transcriptionUnavailable:
            return "On-device transcription is not available on this Mac."
        case .unsupportedLocale:
            return "No on-device speech model supports your language yet."
        case .modelNotInstalled:
            return "Speech model not downloaded — install it from Settings first."
        }
    }
}

/// Preflight + download of the on-device speech model for the user's locale.
/// The download happens during onboarding (and from the Settings row) — never
/// mid-meeting. At meeting start callers only check `isInstalled()` and degrade
/// loudly if the model is missing.
enum TranscriptionAssets {
    private static let logger = Logger(subsystem: "notes.quiet.app", category: "TranscriptionAssets")

    enum State: Equatable, Sendable {
        /// SpeechTranscriber doesn't exist on this Mac at all.
        case unavailable
        /// No speech model covers the user's locale.
        case unsupportedLocale
        case notInstalled
        case downloading
        case installed
    }

    /// The transcription locale — SpeechTranscriber's closest match to the system locale.
    static func resolvedLocale() async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        return await SpeechTranscriber.supportedLocale(equivalentTo: .current)
    }

    static func state() async -> State {
        guard SpeechTranscriber.isAvailable else { return .unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            return .unsupportedLocale
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return .installed
        case .downloading:
            return .downloading
        case .supported:
            return .notInstalled
        case .unsupported:
            return .unsupportedLocale
        @unknown default:
            return .notInstalled
        }
    }

    static func isInstalled() async -> Bool {
        await state() == .installed
    }

    /// Downloads and installs the locale model, reporting progress in 0...1.
    /// Idempotent — completes immediately if the model is already installed.
    /// Also reserves the locale so the OS never evicts the assets under Quiet.
    static func ensureInstalled(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionAssetError.transcriptionUnavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw TranscriptionAssetError.unsupportedLocale
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            logger.info("Downloading speech model for \(locale.identifier, privacy: .public)")
            let downloadProgress = request.progress
            let poller = Task {
                while !Task.isCancelled {
                    progress(downloadProgress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { poller.cancel() }
            try await request.downloadAndInstall()
        }

        try await AssetInventory.reserve(locale: locale)
        progress(1)
        logger.info("Speech model installed and reserved for \(locale.identifier, privacy: .public)")
    }
}
