//
//  MixVoice.swift
//  Trop
//

import AVFoundation
import Foundation

/// El segundo reproductor de AutoMix: toca la cancion entrante mientras mpv sigue con la saliente.
///
/// El tramo de la entrante se prepara antes (en segundo plano) con el filtro paso alto que se abre y la curva de
/// volumen ya aplicados, y se guarda en un archivo temporal que se reproduce con `AVAudioPlayer`. Un motor de
/// audio propio (AVAudioEngine) no sonaba junto a mpv, y asi solo hay un reproductor extra, el mismo que ya se oia.
@MainActor
final class MixVoice {
    private let player: AVAudioPlayer
    private let fileURL: URL
    /// Segundo de la cancion en que empieza el archivo preparado.
    private let startSeconds: TimeInterval

    private init(player: AVAudioPlayer, fileURL: URL, startSeconds: TimeInterval) {
        self.player = player
        self.fileURL = fileURL
        self.startSeconds = startSeconds
    }

    /// Prepara la entrante: desde `startSeconds`, `durationSeconds` de mezcla (filtro y volumen incluidos) y
    /// `tailSeconds` mas a volumen completo y sin filtro, para cubrir el relevo. `nil` si no se puede.
    static func make(url: URL, startSeconds: TimeInterval, durationSeconds: TimeInterval, tailSeconds: TimeInterval) async -> MixVoice? {
        let rendered = await Task.detached(priority: .userInitiated) {
            render(url: url, start: startSeconds, duration: durationSeconds, tail: tailSeconds)
        }.value
        guard let rendered else { return nil }
        guard let player = try? AVAudioPlayer(contentsOf: rendered) else {
            try? FileManager.default.removeItem(at: rendered)
            return nil
        }
        player.volume = 0
        player.prepareToPlay()
        return MixVoice(player: player, fileURL: rendered, startSeconds: startSeconds)
    }

    // MARK: - Reproduccion

    /// Empieza a sonar desde el segundo `songTime` de la cancion.
    func start(atSongTime songTime: TimeInterval) {
        player.currentTime = max(0, min(songTime - startSeconds, player.duration - 0.05))
        player.play()
    }

    var isPlaying: Bool { player.isPlaying }

    /// Posicion actual en la cancion, en segundos.
    var position: TimeInterval { startSeconds + player.currentTime }

    func pause() { player.pause() }
    func resume() { player.play() }

    func setVolume(_ volume: Float) { player.volume = max(0, min(volume, 1)) }

    func stop() {
        player.stop()
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Preparacion del tramo (fuera del hilo principal)

    nonisolated private static func render(url: URL, start: TimeInterval, duration: TimeInterval, tail: TimeInterval) -> URL? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let rate = format.sampleRate
        let startFrame = AVAudioFramePosition(max(0, start) * rate)
        guard startFrame < file.length else { return nil }
        let wanted = (duration + tail) * rate
        let total = AVAudioFrameCount(min(Double(file.length - startFrame), wanted))
        guard total > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else { return nil }
        file.framePosition = startFrame
        do { try file.read(into: buffer, frameCount: total) } catch { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return nil }

        let mixFrames = max(duration * rate, 1)
        let q = 0.7071
        for channel in 0..<Int(format.channelCount) {
            let samples = channels[channel]
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
            for i in 0..<frames {
                let progress = Double(i) / mixFrames
                let inMix = progress < 1
                if i % 64 == 0, inMix {
                    // Paso alto de 2 kHz a 20 Hz con curva en S (valores de SimpMusic), coeficientes RBJ.
                    let sweep = 1 / (1 + exp(-6 * (progress - 0.5)))
                    let cutoff = exp(log(2_000.0) + (log(20.0) - log(2_000.0)) * sweep)
                    let w0 = 2 * Double.pi * cutoff / rate
                    let alpha = sin(w0) / (2 * q)
                    let c = cos(w0)
                    let a0 = 1 + alpha
                    b0 = (1 + c) / 2 / a0
                    b1 = -(1 + c) / a0
                    b2 = (1 + c) / 2 / a0
                    a1 = -2 * c / a0
                    a2 = (1 - alpha) / a0
                }
                let x = Double(samples[i])
                var filtered = x
                var out = x
                if inMix {
                    filtered = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                    // Potencia constante: la entrante sube con el seno.
                    out = filtered * sin(progress * Double.pi / 2)
                }
                x2 = x1
                x1 = x
                y2 = y1
                y1 = filtered
                samples[i] = Float(max(-1, min(1, out)))
            }
        }

        let output = FileManager.default.temporaryDirectory.appendingPathComponent("automix-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        do {
            let out = try AVAudioFile(forWriting: output, settings: settings)
            try out.write(from: buffer)
        } catch {
            try? FileManager.default.removeItem(at: output)
            return nil
        }
        return output
    }
}
