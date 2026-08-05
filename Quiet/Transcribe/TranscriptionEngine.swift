import AVFoundation
import Foundation
import Speech
import os.log

enum TranscriptionEngineError: LocalizedError {
    case assetsNotInstalled
    case noCompatibleAudioFormat
    case notPrepared

    var errorDescription: String? {
        switch self {
        case .assetsNotInstalled:
            return "Speech model not downloaded — install it from Settings."
        case .noCompatibleAudioFormat:
            return "SpeechAnalyzer offered no compatible audio format."
        case .notPrepared:
            return "Engine started before prepare() succeeded."
        }
    }
}

/// One `SpeechAnalyzer` + `SpeechTranscriber` session for a single audio source.
/// All Speech usage lives behind this actor — the old SIGTRAP came from Speech's
/// internal queues invoking MainActor-isolated closures, so nothing in here may
/// touch MainActor, and segments leave only via the `@Sendable` callbacks.
actor TranscriptionEngine {
    private let source: TranscriptSource
    private let logger = Logger(subsystem: "notes.quiet.app", category: "TranscriptionEngine")

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var analyzerInputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var conversionTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    init(source: TranscriptSource) {
        self.source = source
    }

    /// Loads the locale model up front so failures surface before audio flows.
    /// Assets must already be installed (onboarding/Settings) — never downloads here.
    func prepare() async throws {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionAssetError.transcriptionUnavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw TranscriptionAssetError.unsupportedLocale
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw TranscriptionEngineError.assetsNotInstalled
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // Never hardcode 16k mono — ask the analyzer what it actually wants.
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionEngineError.noCompatibleAudioFormat
        }
        try await analyzer.prepareToAnalyze(in: format)

        self.transcriber = transcriber
        self.analyzer = analyzer
        self.analyzerFormat = format
        logger.info("Prepared \(self.source.rawValue, privacy: .public) engine, locale \(locale.identifier, privacy: .public)")
    }

    /// Starts the results and conversion tasks, then the analyzer.
    /// `onSegment` fires for every volatile/final result; `onFailure` fires once if
    /// the results stream throws (the input side only logs and drops bad buffers).
    func start(
        input: AsyncStream<PCMBufferBox>,
        onSegment: @escaping @Sendable (TranscriptSegment) -> Void,
        onFailure: @escaping @Sendable (any Error) -> Void
    ) async throws {
        guard let transcriber, let analyzer, let analyzerFormat else {
            throw TranscriptionEngineError.notPrepared
        }

        let (analyzerStream, analyzerCont) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        analyzerInputContinuation = analyzerCont
        let source = self.source

        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    onSegment(TranscriptSegment(
                        start: result.range.start.seconds,
                        end: result.range.end.seconds,
                        text: text,
                        isFinal: result.isFinal,
                        source: source
                    ))
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.logger.error("\(source.rawValue, privacy: .public) results stream failed: \(error.localizedDescription, privacy: .public)")
                onFailure(error)
            }
        }

        conversionTask = Task {
            // Converter + accumulator are non-Sendable and stay confined to this task.
            var converter: BufferConverter?
            let accumulator = ChunkAccumulator(format: analyzerFormat)
            for await box in input {
                do {
                    let buffer = box.buffer
                    if converter?.inputFormat != buffer.format {
                        converter = try BufferConverter(from: buffer.format, to: analyzerFormat)
                    }
                    guard let converter else { continue }
                    let converted = try converter.convert(buffer)
                    for chunk in accumulator.append(converted) {
                        // No bufferStartTime — the analyzer keeps its own timeline,
                        // which sidesteps monotonicity traps across device changes.
                        analyzerCont.yield(AnalyzerInput(buffer: chunk))
                    }
                } catch {
                    // Drop the bad buffer, keep the stream alive.
                    self.logger.error("\(source.rawValue, privacy: .public) buffer conversion failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            if let tail = accumulator.flush() {
                analyzerCont.yield(AnalyzerInput(buffer: tail))
            }
            analyzerCont.finish()
        }

        try await analyzer.start(inputSequence: analyzerStream)
        logger.info("Started \(source.rawValue, privacy: .public) engine")
    }

    /// Graceful shutdown: drain remaining input, finalize through end of input with a
    /// 10s timeout, then force-cancel. Final segments flow through `onSegment` before
    /// this returns. Callers must finish the input stream before calling.
    func finish() async {
        await conversionTask?.value
        analyzerInputContinuation?.finish()

        if let analyzer {
            let finalized = await Self.runBounded(seconds: 10) {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            if !finalized {
                logger.warning("\(self.source.rawValue, privacy: .public) finalize timed out — cancelling")
                await analyzer.cancelAndFinishNow()
            }
        }

        // Results stream ends once the analyzer finishes; bound the wait anyway.
        if let resultsTask {
            _ = await Self.runBounded(seconds: 3) { await resultsTask.value }
            resultsTask.cancel()
        }
        tearDown()
        logger.info("Finished \(self.source.rawValue, privacy: .public) engine")
    }

    /// Hard stop with no finalization — used when the engine misbehaves mid-meeting.
    func abort() async {
        conversionTask?.cancel()
        resultsTask?.cancel()
        analyzerInputContinuation?.finish()
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        tearDown()
        logger.warning("Aborted \(self.source.rawValue, privacy: .public) engine")
    }

    private func tearDown() {
        conversionTask = nil
        resultsTask = nil
        analyzerInputContinuation = nil
        analyzer = nil
        transcriber = nil
        analyzerFormat = nil
    }

    /// Races `operation` against a deadline. Returns false on timeout or throw.
    private static func runBounded(seconds: Double, operation: @escaping @Sendable () async throws -> Void) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do { try await operation(); return true } catch { return false }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
