import Foundation
import AVFoundation
import os

final class AudioOutput {
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    // Ring buffer (single-producer / single-consumer, lock-protected positions)
    private let bufferSize = 8192  // samples per channel
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

                for frame in 0..<frames {
                    // Read positions under lock
                    os_unfair_lock_lock(&self.lock)
                    let wp = self.writePos
                    let rp = self.readPos
                    os_unfair_lock_unlock(&self.lock)

                    let available = (wp &- rp &+ self.bufferSize) % self.bufferSize

                    if available > 0 {
                        let idx = rp % self.bufferSize
                        let sL = Float(self.bufferL[idx]) / 32768.0
                        let sR = Float(self.bufferR[idx]) / 32768.0
                        self.lastSampleL = sL
                        self.lastSampleR = sR
                        dataL?[frame] = sL
                        dataR?[frame] = sR

                        os_unfair_lock_lock(&self.lock)
                        self.readPos = (rp + 1) % self.bufferSize
                        os_unfair_lock_unlock(&self.lock)
                    } else {
                        // Underrun: fade last sample toward zero to avoid clicks
                        self.lastSampleL *= self.decayFactor
                        self.lastSampleR *= self.decayFactor
                        dataL?[frame] = self.lastSampleL
                        dataR?[frame] = self.lastSampleR
                    }
                }
            } else if ablPointer.count == 1 {
                // Interleaved fallback: single buffer with alternating L/R
                let data = ablPointer[0].mData?.assumingMemoryBound(to: Float.self)
                let channels = Int(ablPointer[0].mNumberChannels)

                for frame in 0..<frames {
                    os_unfair_lock_lock(&self.lock)
                    let wp = self.writePos
                    let rp = self.readPos
                    os_unfair_lock_unlock(&self.lock)

                    let available = (wp &- rp &+ self.bufferSize) % self.bufferSize

                    if available > 0 {
                        let idx = rp % self.bufferSize
                        let sampleL = Float(self.bufferL[idx]) / 32768.0
                        let sampleR = Float(self.bufferR[idx]) / 32768.0
                        self.lastSampleL = sampleL
                        self.lastSampleR = sampleR

                        os_unfair_lock_lock(&self.lock)
                        self.readPos = (rp + 1) % self.bufferSize
                        os_unfair_lock_unlock(&self.lock)

                        if channels == 2 {
                            data?[frame * 2] = sampleL
                            data?[frame * 2 + 1] = sampleR
                        } else {
                            data?[frame] = (sampleL + sampleR) * 0.5
                        }
                    } else {
                        // Underrun: fade last sample toward zero
                        self.lastSampleL *= self.decayFactor
                        self.lastSampleR *= self.decayFactor
                        if channels == 2 {
                            data?[frame * 2] = self.lastSampleL
                            data?[frame * 2 + 1] = self.lastSampleR
                        } else {
                            data?[frame] = (self.lastSampleL + self.lastSampleR) * 0.5
                        }
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
        os_unfair_lock_unlock(&lock)
    }

    /// Called from emulator thread to enqueue a stereo sample pair
    func writeSample(left: Int16, right: Int16) {
        os_unfair_lock_lock(&lock)
        let wp = writePos
        let rp = readPos
        os_unfair_lock_unlock(&lock)

        let nextWrite = (wp + 1) % bufferSize
        // Drop sample if buffer is full (1 sample headroom)
        guard nextWrite != rp else { return }

        bufferL[wp] = left
        bufferR[wp] = right

        os_unfair_lock_lock(&lock)
        writePos = nextWrite
        os_unfair_lock_unlock(&lock)
    }

    /// Returns approximate number of samples buffered
    var bufferedSamples: Int {
        os_unfair_lock_lock(&lock)
        let result = (writePos - readPos + bufferSize) % bufferSize
        os_unfair_lock_unlock(&lock)
        return result
    }

    deinit {
        stop()
    }
}
