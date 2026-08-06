import AVFoundation
import CoreAudio
import Foundation

enum AudioCaptureError: LocalizedError {
    case tapFailed(String)
    case noOutputDevice
    case failedToStart(String)

    var errorDescription: String? {
        switch self {
        case .tapFailed(let detail):
            return "System audio tap failed: \(detail)"
        case .noOutputDevice:
            return "No default output device found."
        case .failedToStart(let detail):
            return "Could not start audio capture: \(detail)"
        }
    }
}

final class PCMBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// Holds the AsyncStream continuation for cross-thread yields from audio callback threads
/// (the HAL IO thread here, the AVAudioEngine render thread in `MicCaptureSession`).
/// Must NOT touch MainActor — audio callbacks trap if they land on an actor's queue.
final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<PCMBufferBox>.Continuation?

    func set(_ continuation: AsyncStream<PCMBufferBox>.Continuation) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func yield(_ box: PCMBufferBox) {
        lock.lock()
        let cont = continuation
        lock.unlock()
        cont?.yield(box)
    }

    func finish() {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.finish()
    }
}

/// System-audio capture via Core Audio process taps.
/// Intentionally **not** `@MainActor` — the HAL IO callback must stay off the main actor
/// or Swift 6 traps with `dispatch_assert_queue_fail` and kills Quiet.
final class AudioCaptureSession: @unchecked Sendable {
    private let stateLock = NSLock()
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var deviceProcID: AudioDeviceIOProcID?
    private let continuationBox = ContinuationBox()
    private let ioQueue = DispatchQueue(label: "notes.quiet.systemaudio")

    func start() throws -> AsyncStream<PCMBufferBox> {
        stopInternal()

        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard tapStatus == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            throw AudioCaptureError.tapFailed("AudioHardwareCreateProcessTap status \(tapStatus)")
        }

        let outputUID = try Self.defaultOutputDeviceUID()
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Kamui System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw AudioCaptureError.tapFailed("AudioHardwareCreateAggregateDevice status \(aggStatus)")
        }

        var asbd = try Self.readTapStreamDescription(tapID: tapID)
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw AudioCaptureError.failedToStart("Invalid tap audio format")
        }

        let (streamOut, cont) = AsyncStream.makeStream(of: PCMBufferBox.self, bufferingPolicy: .bufferingNewest(64))
        continuationBox.set(cont)

        let box = continuationBox
        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, inInputData, _, _, _ in
            // Runs on HAL IO thread — no MainActor, no Task { @MainActor }.
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil),
                  let copy = Self.copyBuffer(buffer) else { return }
            box.yield(PCMBufferBox(copy))
        }
        guard createStatus == noErr, let procID else {
            continuationBox.finish()
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw AudioCaptureError.failedToStart("AudioDeviceCreateIOProcIDWithBlock status \(createStatus)")
        }

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            continuationBox.finish()
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw AudioCaptureError.failedToStart(
                "AudioDeviceStart status \(startStatus). Allow system audio for Kamui if prompted, then retry."
            )
        }

        stateLock.lock()
        self.tapID = tapID
        self.aggregateDeviceID = aggregateID
        self.deviceProcID = procID
        stateLock.unlock()

        return streamOut
    }

    func stop() {
        stopInternal()
    }

    private func stopInternal() {
        stateLock.lock()
        let aggregate = aggregateDeviceID
        let proc = deviceProcID
        let tap = tapID
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        deviceProcID = nil
        tapID = AudioObjectID(kAudioObjectUnknown)
        stateLock.unlock()

        continuationBox.finish()

        if aggregate != AudioObjectID(kAudioObjectUnknown) {
            if let proc {
                AudioDeviceStop(aggregate, proc)
                AudioDeviceDestroyIOProcID(aggregate, proc)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tap)
        }
    }

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let bytes = Int(buffer.frameLength) * Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        if let src = buffer.audioBufferList.pointee.mBuffers.mData,
           let dst = copy.audioBufferList.pointee.mBuffers.mData {
            memcpy(dst, src, bytes)
        } else if let srcChannels = buffer.floatChannelData, let dstChannels = copy.floatChannelData {
            for ch in 0..<Int(buffer.format.channelCount) {
                dstChannels[ch].update(from: srcChannels[ch], count: Int(buffer.frameLength))
            }
        }
        return copy
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr else { throw AudioCaptureError.noOutputDevice }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var cfUID: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let st = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &cfUID)
        guard st == noErr, let cfUID else { throw AudioCaptureError.noOutputDevice }
        return cfUID.takeUnretainedValue() as String
    }

    private static func readTapStreamDescription(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            throw AudioCaptureError.tapFailed("kAudioTapPropertyFormat status \(status)")
        }
        return asbd
    }
}
