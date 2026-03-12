import Foundation
import AVFoundation
import os

final class AudioOutput {
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    // Ring buffer (single-producer / single-consumer, lock-protected positions)
    private let bufferSize = 32768  // samples per channel
    private let prebufferSamples = 1536
    private var bufferL: [Int16]
    private var bufferR: [Int16]
    private var writePos = 0  // only written by emulator thread
    private var readPos = 0   // only written by audio thread

    // Lock protecting writePos and readPos
    private var lock = os_unfair_lock()

    // Underrun fade-out state (audio thread only, no lock needed)
    private var lastSampleL: Float = 0
    private var lastSampleR: Float = 0
    private let decayFactor: Float = 0.95
    private var primed = false
    private var underrunCount: UInt64 = 0
    private var overrunCount: UInt64 = 0

    private let sampleRate: Double = 32000.0
    private var isRunning = false

    init() {
        bufferL = [Int16](repeating: 0, count: bufferSize)
        bufferR = [Int16](repeating: 0, count: bufferSize)
    }

    func start() {
        guard !isRunning else { return }

        let engine = AVAudioEngine()
        self.engine = engine

        // Non-interleaved stereo: 2 separate buffers, one per channel
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        )!

        let sourceNode = AVAudioSourceNode(format: format) {
            [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }

            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)

            // Non-interleaved: expect 2 buffers (L and R)
            if ablPointer.count >= 2 {
                let dataL = ablPointer[0].mData?.assumingMemoryBound(to: Float.self)
                let dataR = ablPointer[1].mData?.assumingMemoryBound(to: Float.self)
                let produced = self.dequeueSamples(frameCount: frames) { frame, left, right in
                    dataL?[frame] = left
                    dataR?[frame] = right
                }
                self.fillRemainingOutput(startFrame: produced, frameCount: frames) { frame, left, right in
                    dataL?[frame] = left
                    dataR?[frame] = right
                }
            } else if ablPointer.count == 1 {
                // Interleaved fallback: single buffer with alternating L/R
                let data = ablPointer[0].mData?.assumingMemoryBound(to: Float.self)
                let channels = Int(ablPointer[0].mNumberChannels)
                let produced = self.dequeueSamples(frameCount: frames) { frame, left, right in
                    if channels == 2 {
                        data?[frame * 2] = left
                        data?[frame * 2 + 1] = right
                    } else {
                        data?[frame] = (left + right) * 0.5
                    }
                }
                self.fillRemainingOutput(startFrame: produced, frameCount: frames) { frame, left, right in
                    if channels == 2 {
                        data?[frame * 2] = left
                        data?[frame * 2 + 1] = right
                    } else {
                        data?[frame] = (left + right) * 0.5
                    }
                }
            }
            return noErr
        }
        self.sourceNode = sourceNode

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
            isRunning = true
        } catch {
            print("Audio engine failed to start: \(error)")
        }
    }

    func stop() {
        engine?.stop()
        isRunning = false
        os_unfair_lock_lock(&lock)
        writePos = 0
        readPos = 0
        primed = false
        underrunCount = 0
        overrunCount = 0
        os_unfair_lock_unlock(&lock)
        lastSampleL = 0
        lastSampleR = 0
    }

    /// Called from emulator thread to enqueue a stereo sample pair
    func writeSample(left: Int16, right: Int16) {
        os_unfair_lock_lock(&lock)
        let wp = writePos
        let rp = readPos
        let nextWrite = (wp + 1) % bufferSize
        if nextWrite == rp {
            // Preserve continuity by dropping incoming samples when the producer gets ahead.
            overrunCount &+= 1
            os_unfair_lock_unlock(&lock)
            return
        }

        bufferL[wp] = left
        bufferR[wp] = right
        writePos = nextWrite
        os_unfair_lock_unlock(&lock)
    }

    /// Called from emulator thread to enqueue a stereo sample batch with one lock acquisition.
    func writeSamples(left: [Int16], right: [Int16]) {
        guard !left.isEmpty, left.count == right.count else { return }

        os_unfair_lock_lock(&lock)
        var wp = writePos
        let rp = readPos

        for i in left.indices {
            let nextWrite = (wp + 1) % bufferSize
            if nextWrite == rp {
                // Preserve continuity by dropping the rest of this batch when full.
                overrunCount &+= UInt64(left.count - i)
                break
            }

            bufferL[wp] = left[i]
            bufferR[wp] = right[i]
            wp = nextWrite
        }

        writePos = wp
        readPos = rp
        os_unfair_lock_unlock(&lock)
    }

    /// Returns approximate number of samples buffered
    var bufferedSamples: Int {
        os_unfair_lock_lock(&lock)
        let result = (writePos - readPos + bufferSize) % bufferSize
        os_unfair_lock_unlock(&lock)
        return result
    }

    var underrunEvents: UInt64 {
        os_unfair_lock_lock(&lock)
        let result = underrunCount
        os_unfair_lock_unlock(&lock)
        return result
    }

    var pacingTargetBufferedSamples: Int {
        prebufferSamples + (prebufferSamples / 2)
    }

    var overrunEvents: UInt64 {
        os_unfair_lock_lock(&lock)
        let result = overrunCount
        os_unfair_lock_unlock(&lock)
        return result
    }

    private func dequeueSamples(frameCount: Int, write: (_ frame: Int, _ left: Float, _ right: Float) -> Void) -> Int {
        os_unfair_lock_lock(&lock)
        let wp = writePos
        let rp = readPos
        let available = (wp &- rp &+ bufferSize) % bufferSize

        if !primed {
            if available < prebufferSamples {
                os_unfair_lock_unlock(&lock)
                lastSampleL = 0
                lastSampleR = 0
                return 0
            }
            primed = true
        }

        let toRead = min(frameCount, available)
        for frame in 0..<toRead {
            let idx = (rp + frame) % bufferSize
            let sL = Float(bufferL[idx]) / 32768.0
            let sR = Float(bufferR[idx]) / 32768.0
            lastSampleL = sL
            lastSampleR = sR
            write(frame, sL, sR)
        }
        readPos = (rp + toRead) % bufferSize
        if toRead < frameCount {
            primed = false
            underrunCount &+= 1
        }
        os_unfair_lock_unlock(&lock)
        return toRead
    }

    private func fillRemainingOutput(startFrame: Int, frameCount: Int, write: (_ frame: Int, _ left: Float, _ right: Float) -> Void) {
        guard startFrame < frameCount else { return }

        if startFrame == 0 {
            for frame in 0..<frameCount {
                write(frame, 0, 0)
            }
            return
        }

        for frame in startFrame..<frameCount {
            lastSampleL *= decayFactor
            lastSampleR *= decayFactor
            write(frame, lastSampleL, lastSampleR)
        }
    }

    deinit {
        stop()
    }
}
