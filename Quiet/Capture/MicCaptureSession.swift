import AVFoundation
import Foundation

enum MicCaptureError: LocalizedError {
    case invalidInputFormat
    case failedToStart(String)

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "Microphone reports an invalid audio format."
        case .failedToStart(let detail):
            return "Could not start microphone capture: \(detail)"
        }
    }
}

/// Microphone capture via an AVAudioEngine input-node tap.
/// Intentionally **not** `@MainActor` — the tap block runs on the audio render thread
/// and must never touch an actor, mirroring `AudioCaptureSession`.
final class MicCaptureSession: @unchecked Sendable {
    private let stateLock = NSLock()
    private var engine: AVAudioEngine?
    private let continuationBox = ContinuationBox()

    func start() throws -> AsyncStream<PCMBufferBox> {
        stopInternal()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicCaptureError.invalidInputFormat
        }

        let (streamOut, cont) = AsyncStream.makeStream(of: PCMBufferBox.self, bufferingPolicy: .bufferingNewest(64))
        continuationBox.set(cont)

        let box = continuationBox
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            // Runs on the audio render thread — no MainActor, no actors.
            // The tap reuses its buffer, so copy before yielding downstream.
            guard let copy = Self.copyBuffer(buffer) else { return }
            box.yield(PCMBufferBox(copy))
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuationBox.finish()
            throw MicCaptureError.failedToStart(error.localizedDescription)
        }

        stateLock.lock()
        self.engine = engine
        stateLock.unlock()

        return streamOut
    }

    func stop() {
        stopInternal()
    }

    private func stopInternal() {
        stateLock.lock()
        let engine = self.engine
        self.engine = nil
        stateLock.unlock()

        continuationBox.finish()

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        if let srcChannels = buffer.floatChannelData, let dstChannels = copy.floatChannelData {
            for ch in 0..<Int(buffer.format.channelCount) {
                dstChannels[ch].update(from: srcChannels[ch], count: Int(buffer.frameLength))
            }
        } else if let src = buffer.audioBufferList.pointee.mBuffers.mData,
                  let dst = copy.audioBufferList.pointee.mBuffers.mData {
            let bytes = Int(buffer.frameLength) * Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
            memcpy(dst, src, bytes)
        }
        return copy
    }
}
