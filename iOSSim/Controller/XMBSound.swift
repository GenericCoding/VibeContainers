import AVFoundation
import Foundation
import Observation

/// The dashboard's voice.
///
/// Every sound here is synthesised at runtime, not sampled: the PS3's own
/// audio is Sony's, and shipping it is not an option, so the *idiom* is rebuilt
/// instead. That idiom is narrow and recognisable — glassy sine partials with
/// no harmonic grit, fast attacks, long exponential tails, and a cursor blip
/// short enough to fire on every row of a fast scroll without ever stacking
/// into a drone.
///
/// The ambience is the same wave the background draws, in sound: four detuned
/// low sines beating against each other under a band of filtered noise, on an
/// eight-second loop chosen so the beats never line up with the visual wave and
/// give the whole thing an audible period.
@MainActor
@Observable
final class XMBSound {
    static let shared = XMBSound()

    enum Effect: String, CaseIterable {
        /// One row of movement. By far the most-played sound here.
        case cursor
        /// Moving between categories — a shade lower than `cursor`.
        case sweep
        /// ✕.
        case enter
        /// ○.
        case back
        /// Something refused.
        case error
        /// The swell when the dashboard opens.
        case boot
        /// A download or install finished.
        case complete
    }

    var effectsEnabled = true {
        didSet { UserDefaults.standard.set(effectsEnabled, forKey: "xmb.sfx") }
    }
    var ambienceEnabled = true {
        didSet {
            UserDefaults.standard.set(ambienceEnabled, forKey: "xmb.ambience")
            ambienceEnabled ? startAmbience() : stopAmbience()
        }
    }
    var volume: Float = 0.7 {
        didSet {
            UserDefaults.standard.set(volume, forKey: "xmb.volume")
            engine.mainMixerNode.outputVolume = volume
        }
    }

    private let engine = AVAudioEngine()
    private let ambienceNode = AVAudioPlayerNode()
    /// A small ring of voices. Effects overlap constantly — a confirm lands on
    /// top of the cursor blip that selected the row — and one node per sound
    /// would cut the tail off the previous one.
    private var voices: [AVAudioPlayerNode] = []
    private var nextVoice = 0

    private var buffers: [Effect: AVAudioPCMBuffer] = [:]
    private var ambienceBuffer: AVAudioPCMBuffer?
    private var prepared = false
    private var running = false

    private static let sampleRate: Double = 44_100
    private static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "xmb.sfx") != nil {
            effectsEnabled = defaults.bool(forKey: "xmb.sfx")
        }
        if defaults.object(forKey: "xmb.ambience") != nil {
            ambienceEnabled = defaults.bool(forKey: "xmb.ambience")
        }
        if defaults.object(forKey: "xmb.volume") != nil {
            volume = defaults.float(forKey: "xmb.volume")
        }
    }

    // MARK: - Lifecycle

    /// Builds every buffer and starts the engine. Safe to call repeatedly.
    ///
    /// Synthesis happens off the main actor: the boot swell and the ambience
    /// loop are twelve seconds of audio between them, which is a few million
    /// `sin` calls and quite visible in a debug build if it lands on the frame
    /// that is trying to animate the dashboard in.
    func prepare() {
        guard !prepared else { startEngine(); return }
        prepared = true

        Task.detached(priority: .userInitiated) {
            let effects = Synth.buildEffects()
            let ambience = Synth.buildAmbience()
            await MainActor.run {
                self.buffers = effects
                self.ambienceBuffer = ambience
                self.startEngine()
            }
        }
    }

    private func startEngine() {
        guard !running, !buffers.isEmpty else { return }

        // `.ambient` keeps whatever the user was already listening to playing
        // underneath, and honours the ringer switch — correct for UI sound.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)

        if voices.isEmpty {
            voices = (0..<6).map { _ in AVAudioPlayerNode() }
            for voice in voices {
                engine.attach(voice)
                engine.connect(voice, to: engine.mainMixerNode, format: Self.format)
            }
            engine.attach(ambienceNode)
            engine.connect(ambienceNode, to: engine.mainMixerNode, format: Self.format)
        }

        engine.mainMixerNode.outputVolume = volume
        engine.prepare()
        do {
            try engine.start()
        } catch {
            return
        }
        running = true
        voices.forEach { $0.play() }
        if ambienceEnabled { startAmbience() }
    }

    /// Called when the dashboard closes: the engine is torn down so the app is
    /// not holding an audio session open behind the iOS home screen.
    func shutdown() {
        stopAmbience()
        voices.forEach { $0.stop() }
        engine.stop()
        running = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Playing

    func play(_ effect: Effect) {
        guard effectsEnabled, running, let buffer = buffers[effect] else { return }
        let voice = voices[nextVoice % voices.count]
        nextVoice += 1
        voice.scheduleBuffer(buffer, at: nil, options: [.interrupts], completionHandler: nil)
        if !voice.isPlaying { voice.play() }
    }

    private func startAmbience() {
        guard running, ambienceEnabled, let ambienceBuffer else { return }
        ambienceNode.volume = 0.5
        ambienceNode.scheduleBuffer(ambienceBuffer, at: nil, options: [.loops], completionHandler: nil)
        ambienceNode.play()
    }

    private func stopAmbience() {
        ambienceNode.stop()
    }
}

// MARK: - Synthesis

/// Pure sample generation. Nothing in here touches AVAudioEngine state, so it
/// can run anywhere.
private enum Synth {
    static let sampleRate: Double = 44_100

    static func buildEffects() -> [XMBSound.Effect: AVAudioPCMBuffer] {
        var built: [XMBSound.Effect: AVAudioPCMBuffer] = [:]
        built[.cursor] = cursor()
        built[.sweep] = sweep()
        built[.enter] = enter()
        built[.back] = back()
        built[.error] = error()
        built[.boot] = boot()
        built[.complete] = complete()
        return built
    }

    // MARK: Voices

    /// The blip. Two octaves of the same note, gone in sixty milliseconds.
    private static func cursor() -> AVAudioPCMBuffer? {
        render(seconds: 0.14) { t, _ in
            let env = envelope(t, attack: 0.001, decay: 0.055)
            return env * 0.30 * (sin(2 * .pi * 1_180 * t)
                                 + 0.45 * sin(2 * .pi * 2_360 * t)
                                 + 0.20 * sin(2 * .pi * 590 * t))
        }
    }

    /// Category change: the same shape a fifth down, with a hair more body so
    /// a horizontal move feels weightier than a vertical one.
    private static func sweep() -> AVAudioPCMBuffer? {
        render(seconds: 0.22) { t, _ in
            let env = envelope(t, attack: 0.002, decay: 0.085)
            return env * 0.30 * (sin(2 * .pi * 780 * t)
                                 + 0.5 * sin(2 * .pi * 1_560 * t)
                                 + 0.28 * sin(2 * .pi * 392 * t))
        }
    }

    /// ✕ — a short upward glide with a shimmer over it.
    private static func enter() -> AVAudioPCMBuffer? {
        render(seconds: 0.5) { t, _ in
            let glide = 660 + 330 * min(1, t / 0.12)
            let env = envelope(t, attack: 0.003, decay: 0.20)
            let shimmer = envelope(t, attack: 0.006, decay: 0.11) * 0.22 * sin(2 * .pi * 1_980 * t)
            return env * 0.34 * (sin(2 * .pi * glide * t) + 0.4 * sin(2 * .pi * glide * 2 * t)) + shimmer
        }
    }

    /// ○ — the same idea inverted.
    private static func back() -> AVAudioPCMBuffer? {
        render(seconds: 0.44) { t, _ in
            let glide = 880 - 386 * min(1, t / 0.14)
            let env = envelope(t, attack: 0.002, decay: 0.16)
            return env * 0.30 * (sin(2 * .pi * glide * t) + 0.32 * sin(2 * .pi * glide * 2 * t))
        }
    }

    /// Refused. Two low bursts, detuned against each other so they beat.
    private static func error() -> AVAudioPCMBuffer? {
        render(seconds: 0.46) { t, _ in
            let burst = t < 0.18 ? t : (t >= 0.22 ? t - 0.22 : -1)
            guard burst >= 0 else { return 0 }
            let env = envelope(burst, attack: 0.004, decay: 0.06)
            return env * 0.30 * (sin(2 * .pi * 158 * t) + sin(2 * .pi * 167 * t))
        }
    }

    /// The dashboard opening: a slow swell on a low fundamental with its first
    /// four partials fading in behind it, and a noise sweep rising through.
    private static func boot() -> AVAudioPCMBuffer? {
        var noise = NoiseFilter(cutoffStart: 0.02, cutoffEnd: 0.35)
        return render(seconds: 3.4) { t, index in
            let swell = min(1, t / 1.5) * exp(-max(0, t - 1.9) / 0.75)
            var value: Double = 0
            for (partial, gain) in [(1.0, 1.0), (2.0, 0.55), (3.0, 0.30), (4.0, 0.18), (5.0, 0.10)] {
                // Partials arrive one after another, not all at once.
                let entry = min(1, max(0, (t - partial * 0.16) / 0.5))
                value += gain * entry * sin(2 * .pi * 110 * partial * t)
            }
            let air = noise.next(progress: min(1, t / 2.2), index: index) * 0.16 * min(1, t / 1.1)
            return swell * 0.16 * value + swell * air
        }
    }

    /// An install landed: a rising triad.
    private static func complete() -> AVAudioPCMBuffer? {
        let notes: [(Double, Double)] = [(784, 0), (1_046.5, 0.09), (1_318.5, 0.18)]
        return render(seconds: 0.85) { t, _ in
            var value: Double = 0
            for (frequency, start) in notes where t >= start {
                let local = t - start
                value += envelope(local, attack: 0.003, decay: 0.19)
                    * (sin(2 * .pi * frequency * local) + 0.3 * sin(2 * .pi * frequency * 2 * local))
            }
            return value * 0.20
        }
    }

    /// The bed under the dashboard: the wave, as sound.
    static func buildAmbience() -> AVAudioPCMBuffer? {
        var sea = NoiseFilter(cutoffStart: 0.06, cutoffEnd: 0.06)
        let length: Double = 8
        return render(seconds: length) { t, index in
            // Detuned pairs beating slowly against each other.
            var value: Double = 0
            for (frequency, detune, gain) in [(55.0, 0.17, 1.0), (82.4, 0.23, 0.6),
                                              (110.0, 0.31, 0.45), (164.8, 0.19, 0.22)] {
                value += gain * (sin(2 * .pi * frequency * t) + sin(2 * .pi * (frequency + detune) * t))
            }
            // A slow tide over the whole loop, plus the surf.
            let tide = 0.55 + 0.45 * sin(2 * .pi * t / length)
            let surf = sea.next(progress: 0, index: index) * (0.06 + 0.05 * sin(2 * .pi * t / 5.3))
            // Both ends are faded so the loop point is inaudible.
            let seam = min(1, t / 0.4) * min(1, (length - t) / 0.4)
            return seam * (tide * 0.045 * value + surf)
        }
    }

    // MARK: Primitives

    /// Fast attack, exponential tail — the shape almost everything here uses.
    private static func envelope(_ t: Double, attack: Double, decay: Double) -> Double {
        guard t >= 0 else { return 0 }
        let rise = attack > 0 ? min(1, t / attack) : 1
        return rise * exp(-t / decay)
    }

    /// A one-pole lowpass over a deterministic pseudo-random source. Seeded by
    /// sample index rather than `random()` so a buffer is identical every run —
    /// the ambience loop must not have a discontinuity at its seam.
    private struct NoiseFilter {
        let cutoffStart: Double
        let cutoffEnd: Double
        private var state: Double = 0
        private var seed: UInt64 = 0x9E3779B97F4A7C15

        init(cutoffStart: Double, cutoffEnd: Double) {
            self.cutoffStart = cutoffStart
            self.cutoffEnd = cutoffEnd
        }

        mutating func next(progress: Double, index: Int) -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ UInt64(index) &+ 1_442_695_040_888_963_407
            let raw = Double(Int64(bitPattern: seed >> 11)) / Double(1 << 52) - 1
            let cutoff = cutoffStart + (cutoffEnd - cutoffStart) * progress
            state += cutoff * (raw - state)
            return state
        }
    }

    /// Renders a mono buffer, clamped so a stack of partials can never clip.
    private static func render(seconds: Double,
                               _ body: (_ t: Double, _ index: Int) -> Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return nil
        }
        let frames = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames

        for index in 0..<Int(frames) {
            let value = body(Double(index) / sampleRate, index)
            channel[index] = Float(max(-1, min(1, value)))
        }
        return buffer
    }
}
