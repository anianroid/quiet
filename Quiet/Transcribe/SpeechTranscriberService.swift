import Foundation

enum SpeechServiceError: LocalizedError {
    case disabled
    var errorDescription: String? {
        "Live transcription is temporarily disabled while we stabilize Quiet. Silencing competitors still works."
    }
}

/// Stubbed on purpose.
/// Real `SpeechAnalyzer` was crashing Quiet (SIGTRAP inside Speech.framework)
/// the moment a meeting started — which killed the guardian and let Granola win.
/// Re-enable behind a feature flag after an isolated XPC capture helper exists.
@MainActor
final class SpeechTranscriberService {
    var onSegment: ((TranscriptSegment) -> Void)?
    private(set) var isEnabled = false

    func prepare() async throws {
        guard isEnabled else { throw SpeechServiceError.disabled }
    }

    func start(input: AsyncStream<PCMBufferBox>) async throws {
        guard isEnabled else {
            // Drain input so producer doesn't hang, without touching Speech.
            Task {
                for await _ in input { }
            }
            throw SpeechServiceError.disabled
        }
    }

    func finish() async {
        // no-op
    }
}
