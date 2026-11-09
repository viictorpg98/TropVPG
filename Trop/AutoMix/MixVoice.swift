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
/// estiran en tempo si hace falta, se les aplican los filtros, el intercambio de graves y los volumenes, y se suman.
/// mpv reproduce ese archivo entre la saliente y la entrante sin pausa y con un unico reloj, asi que no hay doblados
/// ni ecos.
enum MixRenderer {
    /// Archivo de la mezcla y, de la entrante, donde acaba la parte mezclada y los segundos que se dejan despues.
    struct Output {
        let url: URL
        /// Segundo de la entrante (en su cancion) donde acaba la parte mezclada.
        let mixEndsAt: TimeInterval
        /// Segundos de la entrante tal cual que van detras de la mezcla, hasta el punto de empalme con su archivo.
        let extra: TimeInterval
    }

    /// Segundos de la entrante que se dejan en el archivo despues de la mezcla, para elegir dentro de ellos el momento
    /// mas flojo donde mpv cambia de archivo (el cambio puede dejar un hueco de unas decenas de milisegundos, que asi
    /// cae sobre algo casi silencioso).
    nonisolated static let tailSeconds = 4.0
    /// Lo mas que se guarda de la entrante detras de la mezcla (en segundos): 8 minutos.
    nonisolated static let maxRestSeconds = 480.0

    /// - Saliente: desde `outgoingStart`, durante `duration` s, un paso bajo que se cierra de 20 kHz a 200 Hz, con el
    ///   volumen bajando por coseno y los graves intactos hasta el intercambio. Si hace falta, estirada hasta
    ///   `outgoingRatio` veces su velocidad.
    /// - Entrante: desde `incomingStart`, durante `duration` s, un paso alto que se abre de 2 kHz a 20 Hz, con el
    ///   volumen subiendo por seno, los graves entrando en el intercambio y el volumen igualado al de la saliente.
    ///   Si hace falta, empieza a `incomingRatio` veces su velocidad y vuelve a la normal al final.
    nonisolated static func render(
        outgoingURL: URL, outgoingStart: TimeInterval,
        incomingURL: URL, incomingStart: TimeInterval,
        duration: TimeInterval, outgoingRatio: Double, incomingRatio: Double
    ) -> Output? {
        // Misma frecuencia de muestreo que la saliente, para que mpv no tenga que cambiar de formato al encadenar.
        let rate = sampleRate(of: outgoingURL)
        let frames = Int((duration * rate).rounded())
        guard frames > 0 else { return nil }

        let stretchOut = abs(outgoingRatio - 1) > 0.003
        let stretchIn = abs(incomingRatio - 1) > 0.003

        // Segundos de cada cancion que recorre la mezcla (con los cambios de velocidad).
        let advanceOut = AutoMixMath.outgoingAdvance(ratio: outgoingRatio, duration: duration)
        let advanceIn = AutoMixMath.incomingAdvance(startRatio: incomingRatio, duration: duration)

        // Un colchon antes y despues de cada tramo para que el estirado pueda tomar muestras de alrededor.
        let paddingFrames = TimeStretch.grain + TimeStretch.tolerance
        let outPad = min(paddingFrames, Int(max(outgoingStart, 0) * rate))
        let inPad = min(paddingFrames, Int(max(incomingStart, 0) * rate))
        let margin = Double(TimeStretch.grain + 2 * TimeStretch.tolerance) / rate

        guard let outputSource = decode(
            url: outgoingURL, start: outgoingStart - Double(outPad) / rate,
            seconds: Double(outPad) / rate + advanceOut + margin, rate: rate
        ), let incomingSource = decode(
            url: incomingURL, start: incomingStart - Double(inPad) / rate,
            seconds: Double(inPad) / rate + advanceIn + margin + 0.2, rate: rate
        ) else { return nil }

        // Saliente en el tiempo de la mezcla.
        let outgoing: [[Float]]
        if stretchOut {
            outgoing = TimeStretch.render(input: outputSource, start: outPad, frames: frames) {
                AutoMixMath.outgoingRate(ratio: outgoingRatio, progress: $0)
            }.output
        } else {
            outgoing = slice(outputSource, from: outPad, count: frames)
        }

        // Entrante en el tiempo de la mezcla, y donde de su cancion acaba la parte mezclada.
        let incoming: [[Float]]
        var tailStart: Int
        var mixEndsAt: TimeInterval
        if stretchIn {
            let stretched = TimeStretch.render(input: incomingSource, start: inPad, frames: frames) {
                AutoMixMath.incomingRate(startRatio: incomingRatio, progress: $0)
            }
            incoming = stretched.output
            tailStart = Int(stretched.endPosition.rounded())
            mixEndsAt = incomingStart + (stretched.endPosition - Double(inPad)) / rate
        } else {
            incoming = slice(incomingSource, from: inPad, count: frames)
            tailStart = inPad + frames
            mixEndsAt = incomingStart + Double(frames) / rate
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

        // Empalme suave entre lo mezclado y lo que sigue (la mezcla ya acaba casi igual que la cancion).
        guard tailStart <= incomingSource[0].count else { return nil }
        let blend = min(Int(0.003 * rate), frames, tailStart)
        if blend > 0 {
            for channel in 0..<2 {
                for i in 0..<blend {
                    let t = Float(i) / Float(blend)
                    let raw = incomingSource[channel][tailStart - blend + i]
                    let index = frames - blend + i
                    mixed[channel][index] = mixed[channel][index] * (1 - t) + raw * t
                }
            }
        }
        // Detras de la mezcla va el resto de la entrante tal cual, hasta el final de su cancion, en el MISMO archivo: asi mpv no
        // tiene que cambiar de archivo al acabar la mezcla (ese cambio era lo que dejaba el microcorte). Si la cancion es
        // demasiado larga para guardarla entera, no se mezcla.
        guard let restURL = decodeToFile(url: incomingURL, start: mixEndsAt, seconds: maxRestSeconds, rate: rate) else { return nil }
        defer { try? FileManager.default.removeItem(at: restURL) }
        guard let url = write(mixed, followedBy: restURL, rate: rate) else { return nil }
        return Output(url: url, mixEndsAt: mixEndsAt, extra: 0)
    }

    // MARK: - Decodificacion con FFmpeg

    /// Frecuencia de muestreo de la cancion: la de su archivo, o la habitual de su formato si es una direccion de internet.
    nonisolated private static func sampleRate(of url: URL) -> Double {
        if url.isFileURL, let file = try? AVAudioFile(forReading: url) { return file.processingFormat.sampleRate }
        let text = url.absoluteString.lowercased()
        return (text.contains("webm") || text.contains("opus")) ? 48_000 : 44_100
    }

    /// `seconds` s de `url` desde `start`, a `rate` Hz y en estereo.
    nonisolated private static func decode(url: URL, start: TimeInterval, seconds: TimeInterval, rate: Double) -> [[Float]]? {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("automix-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let input = url.isFileURL ? url.path : url.absoluteString
        let arguments = ["-y", "-v", "error"] + AutoMixSource.inputOptions(for: url) + [
            "-ss", String(format: "%.6f", max(0, start)),
            "-t", String(format: "%.6f", seconds),
            "-i", input,
            "-vn", "-ac", "2", "-ar", String(Int(rate)),
            "-acodec", "pcm_f32le", "-f", "wav",
            temporary.path
        ]
        let session = FFmpegKit.execute(withArguments: arguments)
        guard ReturnCode.isSuccess(session?.getReturnCode()),
              let file = try? AVAudioFile(forReading: temporary),
              file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            return nil
        }
        do { try file.read(into: buffer) } catch { return nil }
        guard let data = buffer.floatChannelData else { return nil }
        let available = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var result = [[Float]](repeating: [Float](repeating: 0, count: available), count: 2)
        for channel in 0..<2 {
            let source = data[min(channel, channels - 1)]
            for i in 0..<available { result[channel][i] = source[i] }
        }
        return result
    }

    /// `count` muestras desde `from` (rellenando con silencio lo que falte).
    nonisolated private static func slice(_ channels: [[Float]], from: Int, count: Int) -> [[Float]] {
        var result = [[Float]](repeating: [Float](repeating: 0, count: count), count: 2)
        for channel in 0..<2 {
            let source = channels[channel]
            let available = max(min(count, source.count - from), 0)
            if available > 0 {
                for i in 0..<available { result[channel][i] = source[from + i] }
            }
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

    /// Decodifica `url` desde `start` hasta el final (como mucho `seconds`) a un archivo WAV temporal. `nil` si no se puede o si la
    /// cancion es mas larga que el limite (el archivo quedaria corto).
    nonisolated private static func decodeToFile(url: URL, start: TimeInterval, seconds: TimeInterval, rate: Double) -> URL? {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("automix-\(UUID().uuidString).wav")
        let input = url.isFileURL ? url.path : url.absoluteString
        let arguments = ["-y", "-v", "error"] + AutoMixSource.inputOptions(for: url) + [
            "-ss", String(format: "%.6f", max(0, start)),
            "-t", String(format: "%.6f", seconds),
            "-i", input,
            "-vn", "-ac", "2", "-ar", String(Int(rate)),
            "-acodec", "pcm_f32le", "-f", "wav",
            temporary.path
        ]
        let session = FFmpegKit.execute(withArguments: arguments)
        guard ReturnCode.isSuccess(session?.getReturnCode()),
              let file = try? AVAudioFile(forReading: temporary), file.length > 0,
              Double(file.length) / rate < seconds - 1 else {
            try? FileManager.default.removeItem(at: temporary)
            return nil
        }
        return temporary
    }

    /// Escribe la mezcla como WAV de 32 bits en coma flotante (sin recodificar, para no alterar nada) y, detras, el contenido de
    /// `restURL` (copiado por trozos para no llenar la memoria).
    nonisolated private static func write(_ channels: [[Float]], followedBy restURL: URL, rate: Double) -> URL? {
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
            let rest = try AVAudioFile(forReading: restURL)
            let chunkFrames: AVAudioFrameCount = 65_536
            guard let chunk = AVAudioPCMBuffer(pcmFormat: rest.processingFormat, frameCapacity: chunkFrames) else {
                throw CocoaError(.fileWriteUnknown)
            }
            while rest.framePosition < rest.length {
                try rest.read(into: chunk, frameCount: chunkFrames)
                if chunk.frameLength == 0 { break }
                try file.write(from: chunk)
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Fotograma, dentro de `from..<to`, donde la entrante suena mas floja (ventana de 30 ms), ajustado al paso por cero
    /// mas cercano.
    nonisolated private static func quietestFrame(_ channels: [[Float]], from: Int, to: Int, rate: Double) -> Int {
        let total = channels[0].count
        let start = min(max(from, 0), total - 1)
        let end = min(max(to, start + 1), total)
        let hop = max(Int(0.005 * rate), 1)
        let window = 6
        // Energia por tramos de 5 ms (mono).
        var energy: [Double] = []
        var i = start
        while i + hop <= end {
            var sum = 0.0
            for frame in i..<(i + hop) {
                let v = Double(channels[0][frame] + channels[1][frame]) * 0.5
                sum += v * v
            }
            energy.append(sum)
            i += hop
        }
        guard energy.count > window else { return min(start + Int(0.5 * rate), end) }
        var best = 0
        var bestValue = Double.infinity
        for k in 0...(energy.count - window) {
            let value = energy[k..<(k + window)].reduce(0, +)
            if value < bestValue {
                bestValue = value
                best = k
            }
        }
        var center = start + (best + window / 2) * hop
        // Paso por cero: dentro de +-3 ms, el fotograma con menos amplitud.
        let span = Int(0.003 * rate)
        var lowest = Float.infinity
        for frame in max(center - span, start)...min(center + span, end - 1) {
            let level = abs(channels[0][frame]) + abs(channels[1][frame])
            if level < lowest {
                lowest = level
                center = frame
            }
        }
        return min(max(center, start), end)
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

// MARK: - Estirado de tempo (WSOLA)

/// Cambia la velocidad del audio sin cambiar el tono: se toman trozos ("granos") de la entrada a la velocidad pedida y se
/// vuelven a pegar a ritmo normal, eligiendo para cada uno el punto cercano que mejor continua al anterior (WSOLA).
/// A velocidad 1 el resultado es igual a la entrada, muestra a muestra.
enum TimeStretch {
    nonisolated static let grain = 2048
    nonisolated static let hop = 512
    /// Cuanto se mira a cada lado del punto previsto para encontrar el que mejor encaja.
    nonisolated static let tolerance = 192
    nonisolated private static let compare = 512

    /// - Parameters:
    ///   - input: la cancion (estereo) con un colchon por delante y por detras.
    ///   - start: indice de `input` que corresponde al primer fotograma de la salida.
    ///   - frames: fotogramas de salida.
    ///   - rate: velocidad en cada punto (0...1 del avance) de la salida: 1 = normal.
    /// - Returns: la salida y el indice (fraccionario) de `input` que corresponde a su ultimo fotograma, ya con el
    ///   desajuste que haya dejado la busqueda.
    nonisolated static func render(
        input: [[Float]], start: Int, frames: Int, rate: (Double) -> Double
    ) -> (output: [[Float]], endPosition: Double) {
        let count = input[0].count
        var mono = [Float](repeating: 0, count: count)
        for i in 0..<count { mono[i] = (input[0][i] + input[1][i]) * 0.5 }

        let window: [Float] = (0..<grain).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(grain))) }
        let lead = grain
        var accumulated = [[Float]](repeating: [Float](repeating: 0, count: frames + 2 * grain), count: 2)

        // Granos que empiezan antes del fotograma 0 (a velocidad 1) para que el solape este completo desde el principio.
        let firstGrain = -(grain / hop - 1)
        var nominal = Double(start) + Double(firstGrain * hop)
        var previous: Int?
        var m = firstGrain
        mono.withUnsafeBufferPointer { monoBuffer in
            while m * hop < frames {
                let outputStart = m * hop
                var chosen = Int(nominal.rounded())
                if let previous {
                    chosen = bestStart(monoBuffer, nominal: chosen, natural: previous + hop)
                }
                for channel in 0..<2 {
                    input[channel].withUnsafeBufferPointer { source in
                        let base = outputStart + lead
                        for i in 0..<grain {
                            let index = chosen + i
                            if index >= 0, index < count { accumulated[channel][base + i] += window[i] * source[index] }
                        }
                    }
                }
                previous = chosen
                // Velocidad en el medio de este paso de salida (antes del 0: normal).
                let progress = min(max(Double(outputStart + hop / 2) / Double(frames), 0), 1)
                nominal += (outputStart < 0 ? 1 : rate(progress)) * Double(hop)
                m += 1
            }
        }

        // La suma de ventanas de Hann con un cuarto de paso vale 2.
        var output = [[Float]](repeating: [Float](repeating: 0, count: frames), count: 2)
        for channel in 0..<2 {
            for i in 0..<frames { output[channel][i] = accumulated[channel][lead + i] * 0.5 }
        }

        // Donde de la entrada esta el final: la posicion prevista, corregida con el desajuste que haya dejado la busqueda.
        let finalRate = rate(1)
        let nominalEnd = nominal - Double(m * hop - frames) * finalRate
        let probe = min(1024, frames)
        var endPosition = nominalEnd
        mono.withUnsafeBufferPointer { monoBuffer in
            var reference = [Float](repeating: 0, count: probe)
            for i in 0..<probe { reference[i] = (output[0][frames - probe + i] + output[1][frames - probe + i]) * 0.5 }
            let expected = Int((nominalEnd - Double(probe)).rounded())
            var best = expected
            var bestScore = -Double.infinity
            for k in -tolerance...tolerance {
                let candidate = expected + k
                guard candidate >= 0, candidate + probe <= count else { continue }
                var dot = 0.0
                for i in 0..<probe { dot += Double(reference[i]) * Double(monoBuffer[candidate + i]) }
                dot -= Double(abs(k)) * 1e-6
                if dot > bestScore {
                    bestScore = dot
                    best = candidate
                }
            }
            endPosition = nominalEnd + Double(best - expected)
        }
        return (output, endPosition)
    }

    /// El punto de arranque del siguiente grano: cerca del previsto (`nominal`), el que mejor continua lo que sigue al
    /// grano anterior (`natural`). Correlacion normalizada, primero cada dos muestras y luego afinando.
    nonisolated private static func bestStart(_ x: UnsafeBufferPointer<Float>, nominal: Int, natural: Int) -> Int {
        let count = x.count
        guard natural >= 0, natural + compare <= count else { return nominal }
        func score(_ candidate: Int, step: Int) -> Double {
            guard candidate >= 0, candidate + compare <= count else { return -.infinity }
            var dot: Float = 0
            var energy: Float = 0
            var naturalEnergy: Float = 0
            var j = 0
            while j < compare {
                let value = x[candidate + j]
                let reference = x[natural + j]
                dot += value * reference
                energy += value * value
                naturalEnergy += reference * reference
                j += step
            }
            return Double(dot) / Double((energy * naturalEnergy + 1e-9).squareRoot())
        }
        var best = nominal
        var bestScore = -Double.infinity
        var k = -tolerance
        while k <= tolerance {
            let s = score(nominal + k, step: 2) - Double(abs(k)) * 1e-6
            if s > bestScore {
                bestScore = s
                best = nominal + k
            }
            k += 2
        }
        // Afinado a resolucion completa alrededor del mejor.
        for k in -1...1 {
            let candidate = best + k
            let s = score(candidate, step: 1) - Double(abs(candidate - nominal)) * 1e-6
            if s > bestScore {
                bestScore = s
                best = candidate
            }
        }
        return best
    }
}
