//
//  MixVoice.swift
//  Trop
//

import AVFoundation
import Foundation
import ffmpegkit

/// Prepara el audio de una mezcla de AutoMix como UN solo archivo.
///
/// Se decodifican los dos tramos con FFmpeg (el mismo decodificador y la misma linea de tiempo que usa mpv, asi que
/// el punto de corte de la saliente y el de entrada de la entrante coinciden al muestreo con lo que suena en mpv), se
/// les aplican los filtros, el intercambio de graves y los volumenes, y se suman. mpv reproduce ese archivo entre la
/// saliente y la entrante sin pausa y con un unico reloj, asi que no hay doblados ni ecos.
enum MixRenderer {
    /// Duracion exacta de la mezcla (en segundos) y archivo con ella.
    struct Output {
        let url: URL
    }

    /// - Saliente: desde `outgoingStart`, durante `duration` s, un paso bajo que se cierra de 20 kHz a 200 Hz, con el
    ///   volumen bajando por coseno y los graves intactos hasta el intercambio.
    /// - Entrante: desde `incomingStart`, durante `duration` s, un paso alto que se abre de 2 kHz a 20 Hz, con el
    ///   volumen subiendo por seno, los graves entrando en el intercambio y el volumen igualado al de la saliente.
    nonisolated static func render(
        outgoingURL: URL, outgoingStart: TimeInterval,
        incomingURL: URL, incomingStart: TimeInterval,
        duration: TimeInterval
    ) -> Output? {
        // Misma frecuencia de muestreo que la saliente, para que mpv no tenga que cambiar de formato al encadenar.
        let rate: Double = {
            guard let file = try? AVAudioFile(forReading: outgoingURL) else { return 44_100 }
            return file.processingFormat.sampleRate
        }()
        let frames = Int((duration * rate).rounded())
        guard frames > 0,
              let outgoing = decode(url: outgoingURL, start: outgoingStart, seconds: duration, rate: rate, frames: frames),
              let incoming = decode(url: incomingURL, start: incomingStart, seconds: duration, rate: rate, frames: frames) else {
            return nil
        }

        // Volumen: la entrante empieza al nivel de la saliente y vuelve al suyo (sin pasarse de +-4 dB).
        let window = Int(min(duration, 8) * rate)
        let outLoudness = loudness(outgoing, count: window)
        let inLoudness = loudness(incoming, count: window)
        var match = 1.0
        if outLoudness > 0, inLoudness > 0 { match = min(max(outLoudness / inLoudness, 0.63), 1.6) }

        var mixed = [[Float]](repeating: [Float](repeating: 0, count: frames), count: 2)
        for channel in 0..<2 {
            var lowpass = Biquad()   // paso bajo que se cierra (agudos de la saliente)
            var highpass = Biquad()  // paso alto que se abre (la entrante llega sin cuerpo)
            var outSplit = Biquad()  // separa los graves de la saliente
            var inSplit = Biquad()   // separa los graves de la entrante
            outSplit.setLowPass(cutoff: bassCrossover, rate: rate)
            inSplit.setLowPass(cutoff: bassCrossover, rate: rate)
            for i in 0..<frames {
                let progress = Double(i) / Double(frames)
                if i % 64 == 0 {
                    let sweep = sweepCurve(progress)
                    lowpass.setLowPass(cutoff: exponential(20_000, 200, sweep), rate: rate)
                    highpass.setHighPass(cutoff: exponential(2_000, 20, sweep), rate: rate)
                }
                let swap = bassSwap(progress)

                // Saliente: los graves se mantienen enteros hasta el intercambio y se van de golpe; el resto baja con
                // el coseno durante toda la mezcla. Asi los graves nunca faltan ni suenan dos a la vez.
                let filteredOut = lowpass.process(Double(outgoing[channel][i]))
                let outBass = outSplit.process(filteredOut)
                let outRest = filteredOut - outBass
                let outSample = outBass * cos(swap * Double.pi / 2) + outRest * cos(progress * Double.pi / 2)

                // Entrante: los graves entran de golpe en el intercambio; el resto sube con el seno.
                let x = Double(incoming[channel][i])
                let inBass = inSplit.process(x)
                let inRest = highpass.process(x - inBass)
                let level = pow(match, 1 - progress)
                let inSample = (inBass * sin(swap * Double.pi / 2) + inRest * sin(progress * Double.pi / 2)) * level

                mixed[channel][i] = Float(max(-1, min(1, outSample + inSample)))
            }
        }
        guard let url = write(mixed, rate: rate) else { return nil }
        return Output(url: url)
    }

    // MARK: - Decodificacion con FFmpeg

    /// `seconds` s de `url` desde `start`, a `rate` Hz y en estereo, como dos canales de `frames` muestras (se rellena con
    /// silencio si el archivo acaba antes).
    nonisolated private static func decode(url: URL, start: TimeInterval, seconds: TimeInterval, rate: Double, frames: Int) -> [[Float]]? {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("automix-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let arguments = [
            "-y", "-v", "error",
            "-ss", String(format: "%.6f", max(0, start)),
            "-t", String(format: "%.6f", seconds + 0.05),
            "-i", url.path,
            "-vn", "-ac", "2", "-ar", String(Int(rate)),
            "-acodec", "pcm_f32le", "-f", "wav",
            temporary.path
        ]
        let session = FFmpegKit.execute(withArguments: arguments)
        guard ReturnCode.isSuccess(session?.getReturnCode()),
              let file = try? AVAudioFile(forReading: temporary),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            return nil
        }
        do { try file.read(into: buffer) } catch { return nil }
        guard let data = buffer.floatChannelData else { return nil }
        let available = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var result = [[Float]](repeating: [Float](repeating: 0, count: frames), count: 2)
        for channel in 0..<2 {
            let source = data[min(channel, channels - 1)]
            let count = min(frames, available)
            for i in 0..<count { result[channel][i] = source[i] }
        }
        return result
    }

    nonisolated private static func loudness(_ channels: [[Float]], count: Int) -> Double {
        let total = min(count, channels[0].count)
        guard total > 0 else { return 0 }
        var sum = 0.0
        for channel in channels {
            for i in 0..<total { sum += Double(channel[i]) * Double(channel[i]) }
        }
        return (sum / Double(total * channels.count)).squareRoot()
    }

    /// Escribe la mezcla como WAV de 32 bits en coma flotante (sin recodificar, para no alterar nada).
    nonisolated private static func write(_ channels: [[Float]], rate: Double) -> URL? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count)),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(channels[0].count)
        for channel in 0..<2 {
            for i in 0..<channels[channel].count { data[channel][i] = channels[channel][i] }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("automix-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
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

    // MARK: - Filtros (biquad RBJ) y curvas

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

    /// Frecuencia por debajo de la cual se hace el intercambio de graves.
    nonisolated private static let bassCrossover = 250.0

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
}
