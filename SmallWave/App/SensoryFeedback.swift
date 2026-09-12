import Foundation
import AVFoundation
import UIKit

final class SensoryFeedback {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var lastHaptic: CFTimeInterval = 0
    private var previousEnergy: Float = 0
    private var soundFailed = false
    private var audioSessionActive = false
    private var previewing = false
    private var previewGeneration = 0
    private var statusMessage: String?
    private let impact = UIImpactFeedbackGenerator(style: .soft)
    private var soundEnabled = false
    private var hapticsEnabled = true
    private var rendererActive = true
    var onStatus: ((String?) -> Void)?

    func configure(soundEnabled: Bool, hapticsEnabled: Bool, rendererActive: Bool) {
        if self.soundEnabled != soundEnabled {
            soundFailed = false // A deliberate toggle is a retry, never a frame-by-frame retry.
            if soundEnabled { notify(nil) }
        }
        self.soundEnabled = soundEnabled
        self.hapticsEnabled = hapticsEnabled
        self.rendererActive = rendererActive
        if !rendererActive { previousEnergy = 0 }
        if !soundEnabled {
            stopPreview()
            stopAudio()
            notify(nil)
        }
        else if !rendererActive && !previewing { stopAudio() }
    }

    func update(energy: Float) {
        guard rendererActive else { return }
        if soundEnabled && !soundFailed {
            if engine == nil { prepareAudio() }
            let volume = min(0.22, max(0, energy - 0.06) * 0.13)
            if let player { player.volume += (volume - player.volume) * 0.3 }
        } else if engine != nil {
            stopAudio()
        }
        let now = CACurrentMediaTime()
        if hapticsEnabled, energy > 0.45, energy - previousEnergy > 0.10, now-lastHaptic > 0.5 {
            impact.impactOccurred(intensity: CGFloat(min(0.65, energy * 0.22)))
            lastHaptic = now
        }
        previousEnergy = energy
    }

    func stop() {
        rendererActive = false
        previewGeneration += 1
        previewing = false
        stopAudio()
        previousEnergy = 0
        notify(nil)
    }

    func preview() {
        guard soundEnabled else { return }
        previewGeneration += 1
        let generation = previewGeneration
        previewing = true
        soundFailed = false // Button press is an explicit retry after an error.
        if engine?.isRunning != true || player?.isPlaying != true {
            stopAudio()
            prepareAudio()
        }
        guard let player, !soundFailed else { previewing = false; return }
        player.volume = 0.20
        notify("물소리를 들려주는 중")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.previewGeneration == generation else { return }
            self.stopPreview()
        }
    }

    func stopPreview() {
        previewGeneration += 1
        guard previewing else { return }
        previewing = false
        stopAudio()
        notify(nil)
    }

    private func prepareAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default)
            try session.setActive(true)
            audioSessionActive = true
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200),
                  let samples = buffer.floatChannelData?[0] else {
                throw NSError(domain: "smallwave.audio", code: 1)
            }
            buffer.frameLength = buffer.frameCapacity
            var state: UInt64 = 0x534541
            var slow: Float = 0
            var previous: Float = 0
            // Synthesized, band-limited water-like noise. No microphone or downloaded audio.
            for frame in 0..<Int(buffer.frameLength) {
                state = state &* 2862933555777941757 &+ 3037000493
                let noise = Float((state >> 40) & 0xffffff) / Float(0xffffff) * 2 - 1
                previous += (noise - previous) * 0.16
                slow += (previous - slow) * 0.015
                let t = Float(frame) / Float(buffer.frameLength)
                let envelope = sin(.pi * t)
                samples[frame] = (previous-slow) * 1.8 * envelope * envelope
            }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            player.volume = 0
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            self.engine = engine
            self.player = player
        } catch {
            soundFailed = true
            stopAudio()
            notify("물소리를 재생하지 못했어. 다시 시도해줘.")
        }
    }

    private func stopAudio() {
        player?.stop()
        engine?.stop()
        player = nil
        if audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionActive = false
        }
        engine = nil
    }

    private func notify(_ message: String?) {
        // Avoid a status -> SwiftUI update -> configure -> status feedback loop.
        guard message != statusMessage else { return }
        statusMessage = message
        DispatchQueue.main.async { [weak self] in self?.onStatus?(message) }
    }
}
