//
//  MixVoice.swift
//  Trop
//

import AVFoundation
import Foundation

/// El segundo reproductor de AutoMix: toca la cancion entrante desde un punto, con un filtro paso alto
/// que se abre durante la mezcla (la entrante llega sin graves y los recupera). Usa su propio motor de audio
/// para no tocar mpv, que sigue con la saliente.
@MainActor
final class MixVoice {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 1)
    private let file: AVAudioFile
    private var startSeconds: TimeInterval = 0

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        engine.attach(node)
        engine.attach(eq)
        let format = file.processingFormat
        engine.connect(node, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        let band = eq.bands[0]
        band.filterType = .highPass
        band.frequency = 2_000
        band.bypass = false
        eq.globalGain = 0
        node.volume = 0
        engine.prepare()
    }

    /// Arranca el motor con antelacion (en silencio) para no perder tiempo cuando empiece la mezcla.
    func warmUp() -> Bool {
        if engine.isRunning { return true }
        return (try? engine.start()) != nil
    }

    /// Empieza a sonar desde `seconds` de la cancion (con volumen 0 hasta que se suba).
    func start(at seconds: TimeInterval) {
        startSeconds = max(0, seconds)
        let rate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(startSeconds * rate)
        guard startFrame < file.length else { return }
        node.stop()
        node.volume = 0
        node.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: AVAudioFrameCount(file.length - startFrame),
            at: nil,
            completionHandler: nil
        )
        if !engine.isRunning { _ = warmUp() }
        node.play()
    }

    var isPlaying: Bool { node.isPlaying }

    /// Posicion actual en la cancion, en segundos.
    var position: TimeInterval {
        guard let nodeTime = node.lastRenderTime, let time = node.playerTime(forNodeTime: nodeTime),
              time.sampleRate > 0 else { return startSeconds }
        return startSeconds + Double(time.sampleTime) / time.sampleRate
    }

    func pause() { node.pause() }
    func resume() { node.play() }

    func setVolume(_ volume: Float) { node.volume = max(0, min(volume, 1)) }

    /// Frecuencia de corte del filtro paso alto, en Hz.
    func setHighPass(_ hz: Double) {
        eq.bands[0].frequency = Float(max(20, min(hz, 20_000)))
    }

    func stop() {
        node.stop()
        engine.stop()
    }
}
