import Foundation
import os.log

/// Wall-clock stamp shared between a detached relay task and the actor's watchdog.
/// Locked because the relay writes off-actor.
private final class LastBufferClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()

    func touch() {
        lock.lock()
        date = Date()
        lock.unlock()
    }

    func value() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }
}

/// Orchestrates one `TranscriptionEngine` per audio source (system + mic) and merges
/// their segments into a single stream. **Never throws to AppState** — a failed engine
/// degrades (mic dies → system-only continues), gets one automatic restart per meeting,
/// and a 15s buffer-stall watchdog treats silence from the capture side as a failure.
actor MeetingTranscriber {
    private struct Pipeline {
        /// Holds the current engine's input continuation; the relay yields through it
        /// so a restarted engine can take over mid-stream.
        let relayBox: ContinuationBox
        let lastBuffer: LastBufferClock
        var relayTask: Task<Void, Never>?
        var engine: TranscriptionEngine?
        var restartsUsed = 0
        var isDegraded = false
    }

    private struct BufferStallError: LocalizedError {
        var errorDescription: String? { "No audio buffers for 15s." }
    }

    private let logger = Logger(subsystem: "notes.quiet.app", category: "MeetingTranscriber")
    private var pipelines: [TranscriptSource: Pipeline] = [:]
    private var output: AsyncStream<TranscriptSegment>.Continuation?
    private var watchdogTask: Task<Void, Never>?
    private var isFinishing = false

    /// Starts an engine per provided capture stream and returns the merged segment
    /// stream. Engine failures never propagate — worst case the returned stream just
    /// ends while the guardian keeps running.
    func start(
        systemAudio: AsyncStream<PCMBufferBox>,
        micAudio: AsyncStream<PCMBufferBox>?
    ) async -> AsyncStream<TranscriptSegment> {
        let (stream, continuation) = AsyncStream.makeStream(of: TranscriptSegment.self)
        output = continuation

        await startPipeline(source: .system, capture: systemAudio)
        if let micAudio {
            await startPipeline(source: .mic, capture: micAudio)
        }
        startWatchdog()
        return stream
    }

    /// Graceful end-of-meeting shutdown; final segments flush into the merged stream
    /// before it finishes. Capture sessions should already be stopped.
    func finish() async {
        isFinishing = true
        watchdogTask?.cancel()
        watchdogTask = nil

        for (source, var pipeline) in pipelines {
            pipeline.relayTask?.cancel()
            pipeline.relayTask = nil
            // Ensure the engine's input ends even if the capture stream never finished.
            pipeline.relayBox.finish()
            if let engine = pipeline.engine {
                await engine.finish()
                pipeline.engine = nil
            }
            pipelines[source] = pipeline
        }

        output?.finish()
        output = nil
    }

    private func startPipeline(source: TranscriptSource, capture: AsyncStream<PCMBufferBox>) async {
        let relayBox = ContinuationBox()
        let lastBuffer = LastBufferClock()
        var pipeline = Pipeline(relayBox: relayBox, lastBuffer: lastBuffer)

        // Detached so per-buffer forwarding never hops through this actor.
        pipeline.relayTask = Task.detached {
            for await box in capture {
                lastBuffer.touch()
                relayBox.yield(box)
            }
            relayBox.finish()
        }

        pipelines[source] = pipeline
        await attachEngine(to: source)
    }

    /// Builds a fresh engine consuming a new inner stream and points the relay at it.
    /// Used for both first start and the one-per-meeting automatic restart.
    private func attachEngine(to source: TranscriptSource) async {
        guard let pipeline = pipelines[source], !pipeline.isDegraded, !isFinishing else { return }

        let engine = TranscriptionEngine(source: source)
        let (inner, innerCont) = AsyncStream.makeStream(of: PCMBufferBox.self, bufferingPolicy: .bufferingNewest(256))
        pipeline.relayBox.set(innerCont)

        let out = output
        do {
            try await engine.prepare()
            try await engine.start(
                input: inner,
                onSegment: { segment in
                    out?.yield(segment)
                },
                onFailure: { [weak self] error in
                    Task { await self?.handleEngineFailure(source: source, error: error) }
                }
            )
            // Re-read: restartsUsed/isDegraded may have changed across the awaits.
            if var current = pipelines[source], !current.isDegraded {
                current.engine = engine
                pipelines[source] = current
            } else {
                await engine.abort()
            }
        } catch {
            logger.error("Engine start failed for \(source.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            await handleEngineFailure(source: source, error: error)
        }
    }

    private func handleEngineFailure(source: TranscriptSource, error: any Error) async {
        guard var pipeline = pipelines[source], !pipeline.isDegraded, !isFinishing else { return }

        if let engine = pipeline.engine {
            pipeline.engine = nil
            pipelines[source] = pipeline
            await engine.abort()
        }

        if pipeline.restartsUsed == 0 {
            pipeline.restartsUsed = 1
            pipelines[source] = pipeline
            logger.warning("Restarting \(source.rawValue, privacy: .public) engine after: \(error.localizedDescription, privacy: .public)")
            await attachEngine(to: source)
        } else {
            pipeline.isDegraded = true
            pipeline.relayTask?.cancel()
            pipeline.relayBox.finish()
            pipelines[source] = pipeline
            logger.error("\(source.rawValue, privacy: .public) engine degraded for the rest of the meeting: \(error.localizedDescription, privacy: .public)")

            // Both sides dead → end the merged stream; guardian keeps running upstream.
            if pipelines.values.allSatisfy(\.isDegraded) {
                output?.finish()
                output = nil
            }
        }
    }

    private func startWatchdog() {
        watchdogTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, !isFinishing else { return }
                await checkForStalls()
            }
        }
    }

    /// Audio taps deliver buffers continuously even during silence, so a 15s gap
    /// means the capture or analyzer side is wedged — treat it as an engine failure.
    private func checkForStalls() async {
        for (source, pipeline) in pipelines {
            guard !pipeline.isDegraded, pipeline.engine != nil else { continue }
            let stalledFor = Date().timeIntervalSince(pipeline.lastBuffer.value())
            if stalledFor > 15 {
                logger.warning("\(source.rawValue, privacy: .public) buffers stalled for \(Int(stalledFor), privacy: .public)s")
                await handleEngineFailure(source: source, error: BufferStallError())
            }
        }
    }
}
