import AVFoundation
import Foundation

enum BufferConversionError: LocalizedError {
    case failedToCreateConverter
    case failedToAllocateBuffer
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .failedToCreateConverter:
            return "Could not create an audio converter for the capture format."
        case .failedToAllocateBuffer:
            return "Could not allocate a conversion buffer."
        case .conversionFailed(let detail):
            return "Audio conversion failed: \(detail)"
        }
    }
}

/// Converts capture-format PCM buffers to the analyzer's `bestAvailableAudioFormat`.
/// `AVAudioConverter` is not Sendable — each instance must stay confined to the single
/// conversion task that created it (enforced by convention in `TranscriptionEngine`).
final class BufferConverter {
    let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw BufferConversionError.failedToCreateConverter
        }
        // No priming zeroes — priming shifts the analyzer's timeline and breaks streaming.
        converter.primeMethod = .none
        self.inputFormat = inputFormat
        self.converter = converter
    }

    /// Confines the input buffer and consumed flag inside the `@Sendable` input block.
    /// Safe: `AVAudioConverter.convert` invokes the block synchronously on the calling
    /// thread, so there is no actual concurrent access.
    private final class InputState: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var consumed = false
        init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: max(capacity, 1)) else {
            throw BufferConversionError.failedToAllocateBuffer
        }

        let state = InputState(buffer: buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if state.consumed {
                // .noDataNow keeps the stream open — .endOfStream would finalize the converter.
                outStatus.pointee = .noDataNow
                return nil
            }
            state.consumed = true
            outStatus.pointee = .haveData
            return state.buffer
        }
        guard status != .error else {
            throw BufferConversionError.conversionFailed(conversionError?.localizedDescription ?? "status \(status.rawValue)")
        }
        return output
    }
}

/// Batches small converted buffers into ~8192-frame chunks — SpeechAnalyzer streaming
/// misbehaves when fed the tiny buffers audio taps produce. Not Sendable on purpose;
/// lives inside the same conversion task as `BufferConverter`.
final class ChunkAccumulator {
    private let format: AVAudioFormat
    private let chunkFrames: AVAudioFrameCount
    private var pending: AVAudioPCMBuffer?

    init(format: AVAudioFormat, chunkFrames: AVAudioFrameCount = 8192) {
        self.format = format
        self.chunkFrames = chunkFrames
    }

    /// Appends a converted buffer; returns any chunks that reached full size.
    func append(_ buffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        var chunks: [AVAudioPCMBuffer] = []
        var offset: AVAudioFrameCount = 0
        while offset < buffer.frameLength {
            let chunk: AVAudioPCMBuffer
            if let pending {
                chunk = pending
            } else if let fresh = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) {
                chunk = fresh
            } else {
                return chunks
            }

            let take = min(chunkFrames - chunk.frameLength, buffer.frameLength - offset)
            Self.copyFrames(from: buffer, srcOffset: offset, to: chunk, dstOffset: chunk.frameLength, frames: take)
            chunk.frameLength += take
            offset += take

            if chunk.frameLength >= chunkFrames {
                chunks.append(chunk)
                pending = nil
            } else {
                pending = chunk
            }
        }
        return chunks
    }

    /// Returns the partial tail chunk, if any. Call once at end of input.
    func flush() -> AVAudioPCMBuffer? {
        defer { pending = nil }
        guard let pending, pending.frameLength > 0 else { return nil }
        return pending
    }

    private static func copyFrames(
        from src: AVAudioPCMBuffer,
        srcOffset: AVAudioFrameCount,
        to dst: AVAudioPCMBuffer,
        dstOffset: AVAudioFrameCount,
        frames: AVAudioFrameCount
    ) {
        // mBytesPerFrame is per-channel for deinterleaved layouts, per-frame for
        // interleaved — either way it matches each AudioBuffer's stride.
        let bytesPerFrame = Int(src.format.streamDescription.pointee.mBytesPerFrame)
        let srcList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: src.audioBufferList))
        let dstList = UnsafeMutableAudioBufferListPointer(dst.mutableAudioBufferList)
        for (s, d) in zip(srcList, dstList) {
            guard let sData = s.mData, let dData = d.mData else { continue }
            memcpy(
                dData + Int(dstOffset) * bytesPerFrame,
                sData + Int(srcOffset) * bytesPerFrame,
                Int(frames) * bytesPerFrame
            )
        }
    }
}
