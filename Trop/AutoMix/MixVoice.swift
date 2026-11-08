//
//  MixVoice.swift
//  Trop
//

import AVFoundation
import Foundation

/// Un reproductor de AutoMix: toca un tramo de audio ya preparado (`MixRenderer`) con `AVAudioPlayer`.
/// AutoMix usa dos: uno con el final de la saliente (paso bajo, volumen y tempo) y otro con el principio de la
/// entrante (paso alto y volumen), que arrancan sincronizados. mpv queda callado entre medias.
@MainActor
final class MixVoice {
    private let player: AVAudioPlayer
    private let fileURL: URL
    /// Segundo de la cancion en que empieza el archivo preparado.
    let startSeconds: TimeInterval

    private init(player: AVAudioPlayer, fileURL: URL, startSeconds: TimeInterval) {
        self.player = player
        self.fileURL = fileURL
        self.startSeconds = startSeconds
    }

    static func make(fileURL: URL, startSeconds: TimeInterval, enableRate: Bool) -> MixVoice? {
        guard let player = try? AVAudioPlayer(contentsOf: fileURL) else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        player.enableRate = enableRate
        player.volume = 0
        player.prepareToPlay()
        return MixVoice(player: player, fileURL: fileURL, startSeconds: startSeconds)
    }

    // MARK: - Reproduccion

    /// Empieza ya, `offset` segundos dentro del archivo.
    func play(from offset: TimeInterval) {
        player.currentTime = max(0, min(offset, player.duration - 0.05))
        player.play()
    }

    /// Empieza a la hora del dispositivo `deviceTime` (para sincronizar con otro reproductor).
    func play(from offset: TimeInterval, atDeviceTime deviceTime: TimeInterval) {
        player.currentTime = max(0, min(offset, player.duration - 0.05))
        player.play(atTime: deviceTime)
    }

    /// Hora del dispositivo de audio, comun a todos los reproductores de la app.
    var deviceTime: TimeInterval { player.deviceCurrentTime }

    /// Segundos reproducidos del archivo preparado.
    var bufferTime: TimeInterval { player.currentTime }

    /// Posicion actual en la cancion, en segundos.
    var position: TimeInterval { startSeconds + player.currentTime }

    var isPlaying: Bool { player.isPlaying }

    func pause() { player.pause() }
    func resume() { player.play() }

    func setVolume(_ volume: Float, fade: TimeInterval = 0) {
        let clamped = max(0, min(volume, 1))
        if fade > 0 {
            player.setVolume(clamped, fadeDuration: fade)
        } else {
            player.volume = clamped
        }
    }

    func setRate(_ rate: Float) { player.rate = rate }

    func stop() {
        player.stop()
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - Preparacion de los tramos (fuera del hilo principal)

enum MixRenderer {
    struct Output {
        let outgoing: URL
        let incoming: URL
    }

    /// Prepara los dos tramos de una mezcla.
    /// - Saliente: `lead` segundos tal cual (para el relevo desde mpv) y despues, durante `duration` segundos de
    ///   mezcla, un filtro paso bajo de 20 kHz a 200 Hz y el volumen bajando con el coseno. El tempo se cambia al
    ///   reproducirla (`rate`), asi que las curvas se calculan sobre el tiempo de la mezcla, no el de la cancion.
    /// - Entrante: durante `duration`, un paso alto de 2 kHz a 20 Hz y el volumen subiendo con el seno; despues
    ///   `tail` segundos tal cual, para cubrir el relevo a mpv.
    nonisolated static func render(
        outgoingURL: URL, outgoingStart: TimeInterval, lead: TimeInterval,
        incomingURL: URL, incomingStart: TimeInterval,
        duration: TimeInterval, ratio: Double, tail: TimeInterval
    ) -> Output? {
        // Tabla: segundos de cancion que recorre la saliente al cabo de cada instante de la mezcla.
        let step = 0.005
        let count = max(Int(duration / step), 1)
        var consumed = [Double](repeating: 0, count: count + 1)
        for k in 1...count {
            let u = (Double(k) - 0.5) * step
            let rate = 1 + (ratio - 1) * AutoMixMath.rampProgress(u / duration)
            consumed[k] = consumed[k - 1] + rate * step
        }
        let advance = consumed[count]

        guard let outBuffer = read(url: outgoingURL, start: outgoingStart, seconds: lead + advance + 1.5),
              let inBuffer = read(url: incomingURL, start: incomingStart, seconds: duration + tail) else { return nil }

        // Igualar el volumen: la entrante empieza al nivel de la saliente y va volviendo al suyo (sin pasarse de +-4 dB).
        let outRate = outBuffer.format.sampleRate
        let outLoudness = loudness(outBuffer, from: Int(lead * outRate), seconds: min(advance, 8))
        let inLoudness = loudness(inBuffer, from: 0, seconds: min(duration, 8))
        var match = 1.0
        if outLoudness > 0, inLoudness > 0 { match = min(max(outLoudness / inLoudness, 0.63), 1.6) }

        processOutgoing(outBuffer, lead: lead, duration: duration, step: step, consumed: consumed)
        processIncoming(inBuffer, duration: duration, match: match)

        guard let outURL = write(outBuffer), let inURL = write(inBuffer) else { return nil }
        return Output(outgoing: outURL, incoming: inURL)
    }

    /// Volumen eficaz (RMS) de un tramo del buffer, promediando los canales.
    nonisolated private static func loudness(_ buffer: AVAudioPCMBuffer, from frame: Int, seconds: TimeInterval) -> Double {
        guard let channels = buffer.floatChannelData else { return 0 }
        let rate = buffer.format.sampleRate
        let total = Int(buffer.frameLength)
        let start = min(max(frame, 0), total)
        let end = min(start + Int(seconds * rate), total)
        guard end > start else { return 0 }
        var sum = 0.0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            for i in start..<end { sum += Double(samples[i]) * Double(samples[i]) }
        }
        return (sum / Double((end - start) * Int(buffer.format.channelCount))).squareRoot()
    }

    nonisolated private static func read(url: URL, start: TimeInterval, seconds: TimeInterval) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let rate = format.sampleRate
        let startFrame = AVAudioFramePosition(max(0, start) * rate)
        guard startFrame < file.length else { return nil }
        let frames = AVAudioFrameCount(min(Double(file.length - startFrame), seconds * rate))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        file.framePosition = startFrame
        do { try file.read(into: buffer, frameCount: frames) } catch { return nil }
        return buffer.frameLength > 0 ? buffer : nil
    }

    nonisolated private static func write(_ buffer: AVAudioPCMBuffer) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("automix-\(UUID().uuidString).wav")
        let format = buffer.format
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buffer)
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    // MARK: Filtros (biquad RBJ)

    private struct Biquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        mutating func setLowPass(cutoff: Double, rate: Double) {
            let w0 = 2 * Double.pi * min(cutoff, rate * 0.45) / rate
            let alpha = sin(w0) / (2 * 0.7071)
            let c = cos(w0)
            let a0 = 1 + alpha
            b0 = (1 - c) / 2 / a0
            b1 = (1 - c) / a0
            b2 = (1 - c) / 2 / a0
            a1 = -2 * c / a0
            a2 = (1 - alpha) / a0
        }

        mutating func setHighPass(cutoff: Double, rate: Double) {
            let w0 = 2 * Double.pi * cutoff / rate
            let alpha = sin(w0) / (2 * 0.7071)
            let c = cos(w0)
            let a0 = 1 + alpha
            b0 = (1 + c) / 2 / a0
            b1 = -(1 + c) / a0
            b2 = (1 + c) / 2 / a0
            a1 = -2 * c / a0
            a2 = (1 - alpha) / a0
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            return y
        }
    }

    /// Intercambio de graves: de 0 a 1 en un tramo corto hacia la mitad de la mezcla (de 42 % a 58 %).
    nonisolated private static func bassSwap(_ progress: Double) -> Double {
        let x = min(max((progress - 0.42) / 0.16, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// Curva en S (valores de SimpMusic): lenta al principio y al final, rapida en el medio.
    nonisolated private static func sweepCurve(_ progress: Double) -> Double {
        1 / (1 + exp(-6 * (progress - 0.5)))
    }

    nonisolated private static func exponential(_ start: Double, _ end: Double, _ t: Double) -> Double {
        exp(log(start) + (log(end) - log(start)) * t)
    }

    /// Frecuencia por debajo de la cual se hace el intercambio de graves.
    nonisolated private static let bassCrossover = 250.0

    nonisolated private static func processOutgoing(
        _ buffer: AVAudioPCMBuffer, lead: TimeInterval, duration: TimeInterval, step: Double, consumed: [Double]
    ) {
        guard let channels = buffer.floatChannelData else { return }
        let rate = buffer.format.sampleRate
        let frames = Int(buffer.frameLength)
        let last = consumed.count - 1
        let advance = consumed[last]
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            var sweep = Biquad()          // paso bajo que se cierra (agudos)
            var split = Biquad()          // separa los graves del resto
            split.setLowPass(cutoff: bassCrossover, rate: rate)
            var k = 0
            for i in 0..<frames {
                let time = Double(i) / rate
                if time < lead { continue } // tal cual: relevo desde mpv
                let inBlend = time - lead
                if inBlend >= advance {
                    samples[i] = 0
                    continue
                }
                while k < last - 1, consumed[k + 1] <= inBlend { k += 1 }
                let span = max(consumed[k + 1] - consumed[k], 1e-9)
                let progress = min(max((Double(k) + (inBlend - consumed[k]) / span) * step / duration, 0), 1)
                if i % 64 == 0 {
                    sweep.setLowPass(cutoff: exponential(20_000, 200, Self.sweepCurve(progress)), rate: rate)
                }
                let filtered = sweep.process(Double(samples[i]))
                let bass = split.process(filtered)
                let rest = filtered - bass
                // Los graves de la saliente se mantienen enteros hasta el intercambio y se van de golpe; el resto baja
                // con el coseno durante toda la mezcla. Asi los graves nunca faltan ni suenan dos a la vez.
                let swap = bassSwap(progress)
                let out = bass * cos(swap * Double.pi / 2) + rest * cos(progress * Double.pi / 2)
                samples[i] = Float(max(-1, min(1, out)))
            }
        }
    }

    nonisolated private static func processIncoming(_ buffer: AVAudioPCMBuffer, duration: TimeInterval, match: Double) {
        guard let channels = buffer.floatChannelData else { return }
        let rate = buffer.format.sampleRate
        let frames = Int(buffer.frameLength)
        let mixFrames = max(duration * rate, 1)
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            var sweep = Biquad()          // paso alto que se abre (la entrante llega sin cuerpo)
            var split = Biquad()
            split.setLowPass(cutoff: bassCrossover, rate: rate)
            for i in 0..<frames {
                let progress = Double(i) / mixFrames
                if progress >= 1 { break }
                if i % 64 == 0 {
                    sweep.setHighPass(cutoff: exponential(2_000, 20, Self.sweepCurve(progress)), rate: rate)
                }
                let x = Double(samples[i])
                let bass = split.process(x)
                let rest = sweep.process(x - bass)
                // Los graves de la entrante entran de golpe en el intercambio; el resto sube con el seno. El volumen
                // parte igualado al de la saliente y vuelve al suyo.
                let swap = bassSwap(progress)
                let level = pow(match, 1 - progress)
                let out = (bass * sin(swap * Double.pi / 2) + rest * sin(progress * Double.pi / 2)) * level
                samples[i] = Float(max(-1, min(1, out)))
            }
        }
    }
}
