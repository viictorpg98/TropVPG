//
//  TrackStructureAnalyzer.swift
//  Trop
//
//  Adaptado a Swift del analizador de AutoMix de SimpMusic (maxrave-dev/core, GPL-3.0):
//  domain/.../mediaservice/automix/TrackStructureAnalyzer.kt y TrackStructure.kt.
//

import Foundation

/// Un cambio de seccion: el volumen de los cuatro compases siguientes frente a los cuatro anteriores.
struct SectionChange: Codable, Equatable {
    var timeMs: Int64
    /// Positivo = sube (un "drop").
    var deltaDb: Double
}

/// La forma de una cancion, medida de su propio audio. Todos los tiempos en milisegundos de la propia cancion.
struct TrackStructure: Codable, Equatable {
    /// Sube cuando cambia el analisis, para volver a medir lo guardado con una version antigua.
    static let currentVersion = 2

    var version = TrackStructure.currentVersion
    var bpm: Double
    var beatMs: Double
    /// El primer pulso de cada compas.
    var downbeatsMs: [Int64]
    var sections: [SectionChange]
    /// Primer y ultimo instante por encima de -60 dBFS.
    var firstSoundMs: Int64
    var lastSoundMs: Int64
    /// Donde acaba la ultima frase de musica (antes de colas o fundidos finales).
    var musicEndMs: Int64
    /// Donde acaba la intro, si el volumen la distingue del resto.
    var introEndMs: Int64?
    /// Donde acaba el ultimo estribillo, si le sigue una parte mas tranquila de como mucho 30 s.
    var lastChorusEndMs: Int64?
}

/// Mide tempo, compases, secciones y silencios de una cancion. Entrada: toda la cancion en mono, 16 bits,
/// a `sampleRate` Hz.
///
/// - Energia cada 10 ms, de banda completa y por debajo de 200 Hz.
/// - Envolvente de ataques: subidas de energia en log (graves con doble peso) menos su media de 0,4 s.
/// - Tempo con un "peine" de pulsos (mejor que la autocorrelacion con hi-hats de trap), plegado a 100-200 BPM.
/// - Pulsos con el seguimiento de Ellis (programacion dinamica); fase del compas por donde pegan los graves.
/// - Secciones donde la media de cuatro compases cambia mas de 3 dB.
enum TrackStructureAnalyzer {
    static let sampleRate = 8_000
    private static let hop = sampleRate / 100
    private static let fps = Double(sampleRate) / Double(hop)

    private static let silenceDb = -60.0
    private static let minSoundSeconds = 30.0
    private static let lowBandHz = 200.0
    private static let minBpm = 60.0
    private static let maxBpm = 200.0
    private static let tightness = 100.0
    private static let sectionDb = 3.0
    private static let sectionBars = 4
    private static let musicEndDb = 10.0
    private static let chorusDb = 2.0
    private static let maxIntroMs: Int64 = 45_000
    private static let maxOutroMs: Int64 = 30_000

    /// `nil` si hay menos de 30 s de sonido o muy pocos pulsos para encontrar un compas.
    static func analyze(_ pcm: [Int16]) -> TrackStructure? {
        let frames = pcm.count / hop
        guard frames > 0 else { return nil }
        var full = [Double](repeating: 0, count: frames)
        var low = [Double](repeating: 0, count: frames)
        frameEnergies(pcm, &full, &low)
        guard let first = full.firstIndex(where: { toDb($0) > silenceDb }),
              let last = full.lastIndex(where: { toDb($0) > silenceDb }),
              Double(last - first) >= minSoundSeconds * fps else { return nil }

        let onset = onsetEnvelope(full, low)
        let (bpm, period) = combTempo(onset, first: first, last: last)
        let beats = beatTrack(onset, period: period).filter { $0 >= first && $0 <= last }
        guard beats.count >= 4 * sectionBars * 2 else { return nil }
        let bars = downbeats(beats, full: full, low: low)
        guard let lastDownbeat = bars.last else { return nil }
        // Una linea de compas mas, que cierra el ultimo.
        let barLines = bars + [lastDownbeat + Int((period * 4).rounded())]
        let levels = barLevels(barLines, full: full)
        guard !levels.isEmpty else { return nil }
        let changes = sections(barLines, levels)
        let endBar = musicEndBar(levels)
        guard endBar + 1 < barLines.count else { return nil }
        let musicEndMs = toMs(barLines[endBar + 1])
        let (introEnd, lastChorusEnd) = partEdges(changes.map { $0.bar }, levels: levels, endBar: endBar)
        let introEndMs = introEnd.map { toMs(barLines[$0]) }.flatMap { $0 <= maxIntroMs ? $0 : nil }
        let lastChorusEndMs = lastChorusEnd.map { toMs(barLines[$0]) }.flatMap { musicEndMs - $0 <= maxOutroMs ? $0 : nil }
        return TrackStructure(
            bpm: (bpm * 100).rounded() / 100,
            beatMs: period / fps * 1000,
            downbeatsMs: bars.map { toMs($0) },
            sections: changes.map { $0.change },
            firstSoundMs: toMs(first),
            lastSoundMs: toMs(last),
            musicEndMs: musicEndMs,
            introEndMs: introEndMs,
            lastChorusEndMs: lastChorusEndMs
        )
    }

    // MARK: - Utilidades

    private static func toMs(_ frame: Int) -> Int64 { Int64(Double(frame) * 1000 / fps) }

    private static func toDb(_ energy: Double) -> Double { 10 * log10(energy + 1e-12) }

    // MARK: - Energia por tramos de 10 ms

    private static func frameEnergies(_ pcm: [Int16], _ full: inout [Double], _ low: inout [Double]) {
        // Paso bajo RBJ, Q = 1/raiz(2), pasado dos veces (24 dB/octava).
        let w0 = 2 * Double.pi * lowBandHz / Double(sampleRate)
        let alpha = sin(w0) / 2.0.squareRoot()
        let cosW = cos(w0)
        let a0 = 1 + alpha
        let b0 = (1 - cosW) / 2 / a0
        let b1 = (1 - cosW) / a0
        let a1 = -2 * cosW / a0
        let a2 = (1 - alpha) / a0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0, z1 = 0.0, z2 = 0.0
        for f in 0..<full.count {
            var sumFull = 0.0
            var sumLow = 0.0
            for j in (f * hop)..<((f + 1) * hop) {
                let x = Double(pcm[j]) / 32768.0
                let y = b0 * x + b1 * x1 + b0 * x2 - a1 * y1 - a2 * y2
                x2 = x1
                x1 = x
                let z = b0 * y + b1 * y1 + b0 * y2 - a1 * z1 - a2 * z2
                y2 = y1
                y1 = y
                z2 = z1
                z1 = z
                sumFull += x * x
                sumLow += z * z
            }
            full[f] = sumFull / Double(hop)
            low[f] = sumLow / Double(hop)
        }
    }

    // MARK: - Ataques

    private static func onsetEnvelope(_ full: [Double], _ low: [Double]) -> [Double] {
        let n = full.count
        var rises = [Double](repeating: 0, count: n)
        if n > 1 {
            for i in 1..<n {
                rises[i] = max(0, log1p(1000 * low[i]) - log1p(1000 * low[i - 1]))
                    + 0.5 * max(0, log1p(1000 * full[i]) - log1p(1000 * full[i - 1]))
            }
        }
        // Menos la media de los ultimos 0,4 s, para que un tramo fuerte no parezca una racha de ataques.
        let window = Int(fps * 0.4)
        var onset = [Double](repeating: 0, count: n)
        var sum = 0.0
        for i in 0..<n {
            sum += rises[i]
            if i >= window { sum -= rises[i - window] }
            onset[i] = max(0, rises[i] - sum / Double(min(i + 1, window)))
        }
        var squares = 0.0
        for v in onset { squares += v * v }
        let rms = (squares / Double(n)).squareRoot()
        let scale = rms > 0 ? rms : 1.0
        for i in 0..<n { onset[i] /= scale }
        return onset
    }

    // MARK: - Tempo

    /// La mejor fuerza media de ataques sobre una rejilla de pulsos de `bpm`, en cualquier fase.
    private static func combScore(_ onset: [Double], bpm: Double, start: Int, end: Int) -> Double {
        let period = 60 * fps / bpm
        var best = 0.0
        for phase in 0..<Int(period) {
            var sum = 0.0
            var count = 0
            var t = Double(start + phase)
            while t < Double(end - 2) {
                let i = Int(t.rounded())
                sum += max(onset[i - 1], max(onset[i], onset[i + 1]))
                count += 1
                t += period
            }
            if count > 0 { best = max(best, sum / Double(count)) }
        }
        return best
    }

    /// Tempo en BPM y periodo del pulso en tramos: barrido de 0,5 BPM y luego afinado de 0,05.
    private static func combTempo(_ onset: [Double], first: Int, last: Int) -> (Double, Double) {
        let start = max(first, 1)
        var top = minBpm
        var topScore = -1.0
        let steps = Int((maxBpm - minBpm) * 2)
        for step in 0...steps {
            let bpm = minBpm + Double(step) * 0.5
            let score = combScore(onset, bpm: bpm, start: start, end: last)
            if score > topScore {
                topScore = score
                top = bpm
            }
        }
        var bpm = top
        var bestScore = -1.0
        for step in -12...12 {
            let candidate = top + Double(step) * 0.05
            let score = combScore(onset, bpm: candidate, start: start, end: last)
            if score > bestScore {
                bestScore = score
                bpm = candidate
            }
        }
        while bpm < 100 { bpm *= 2 }
        return (bpm, 60 * fps / bpm)
    }

    // MARK: - Pulsos

    /// Ellis (2007): el mejor camino de pulsos separados un `period`, recorrido hacia atras desde el final.
    private static func beatTrack(_ onset: [Double], period: Double) -> [Int] {
        let n = onset.count
        let shortest = Int((period / 2).rounded())
        let longest = Int((period * 2).rounded())
        var penalty = [Double](repeating: 0, count: longest + 1)
        for gap in 1...longest {
            let ratio = log(Double(gap) / period)
            penalty[gap] = tightness * ratio * ratio
        }
        var score = [Double](repeating: 0, count: n)
        var back = [Int](repeating: -1, count: n)
        for t in 0..<n {
            var best = 0.0
            var arg = -1
            let lo = max(0, t - longest)
            let hi = t - shortest
            if hi >= lo {
                for p in lo...hi {
                    let value = score[p] - penalty[t - p]
                    if arg < 0 || value > best {
                        best = value
                        arg = p
                    }
                }
            }
            score[t] = onset[t] + (arg >= 0 ? best : 0)
            back[t] = arg
        }
        let from = max(0, n - Int(period))
        guard from < n else { return [] }
        var t = from
        for i in from..<n where score[i] > score[t] { t = i }
        var beats: [Int] = []
        while t >= 0 {
            beats.append(t)
            t = back[t]
        }
        beats.reverse()
        return beats
    }

    /// El pulso con que empieza cada compas: de las cuatro fases, donde pegan mas los graves,
    /// con medio voto para donde cambia el volumen entre compases.
    private static func downbeats(_ beats: [Int], full: [Double], low: [Double]) -> [Int] {
        let n = full.count
        var bassHits = [Double](repeating: 0, count: n)
        if n > 1 {
            for i in 1..<n { bassHits[i] = max(0, log1p(1000 * low[i]) - log1p(1000 * low[i - 1])) }
        }

        func strength(_ beat: Int) -> Double {
            var strongest = 0.0
            for i in max(0, beat - 3)...min(n - 1, beat + 3) { strongest = max(strongest, bassHits[i]) }
            return strongest
        }

        func barDb(_ startBeat: Int) -> Double {
            let a = beats[startBeat]
            let b = beats[min(startBeat + 4, beats.count - 1)]
            if b <= a { return -90 }
            var sum = 0.0
            for i in a..<b { sum += full[i] }
            return toDb(sum / Double(b - a))
        }

        var hitScores = [Double](repeating: 0, count: 4)
        var jumpScores = [Double](repeating: 0, count: 4)
        for phase in 0..<4 {
            var sum = 0.0
            var k = phase
            while k < beats.count {
                sum += strength(beats[k])
                k += 4
            }
            hitScores[phase] = sum

            var jumps = 0.0
            var previous: Double?
            k = phase
            while k < beats.count - 4 {
                let level = barDb(k)
                if let previous { jumps += abs(level - previous) }
                previous = level
                k += 4
            }
            jumpScores[phase] = jumps
        }
        let maxHits = (hitScores.max() ?? 0) > 0 ? hitScores.max()! : 1.0
        let maxJumps = (jumpScores.max() ?? 0) > 0 ? jumpScores.max()! : 1.0
        var chosen = 0
        var bestValue = -Double.infinity
        for candidate in 0..<4 {
            let value = hitScores[candidate] / maxHits + 0.5 * jumpScores[candidate] / maxJumps
            if value > bestValue {
                bestValue = value
                chosen = candidate
            }
        }
        let count = (beats.count - chosen + 3) / 4
        return (0..<count).map { beats[chosen + $0 * 4] }
    }

    // MARK: - Compases y secciones

    /// Volumen de cada compas en dB: un valor por cada par de lineas de compas vecinas.
    private static func barLevels(_ barLines: [Int], full: [Double]) -> [Double] {
        guard barLines.count > 1 else { return [] }
        return (0..<(barLines.count - 1)).map { i in
            let a = barLines[i]
            let b = min(barLines[i + 1], full.count)
            if b <= a { return -90.0 }
            var sum = 0.0
            for j in a..<b { sum += full[j] }
            return toDb(sum / Double(b - a))
        }
    }

    /// El ultimo compas tocado a menos de 10 dB de la mediana.
    private static func musicEndBar(_ levels: [Double]) -> Int {
        let median = levels.sorted()[levels.count / 2]
        let index = levels.lastIndex(where: { $0 >= median - musicEndDb }) ?? 0
        return max(index, 0)
    }

    /// El final de la intro y del ultimo estribillo, como numeros de compas, segun el volumen de las partes.
    private static func partEdges(_ changeBars: [Int], levels: [Double], endBar: Int) -> (Int?, Int?) {
        let inside = changeBars.filter { $0 >= 1 && $0 <= endBar }
        var edges: [Int] = []
        for value in [0] + inside + [endBar + 1] where !edges.contains(value) {
            edges.append(value)
        }
        guard edges.count >= 3 else { return (nil, nil) }
        let partLevels: [Double] = (0..<(edges.count - 1)).map { i in
            let slice = levels[edges[i]..<edges[i + 1]]
            return slice.reduce(0, +) / Double(slice.count)
        }
        let loudest = partLevels.max() ?? 0
        let isChorus = partLevels.map { $0 >= loudest - chorusDb }
        let nextTwo = partLevels.dropFirst().prefix(2)
        var introEnd: Int?
        if !isChorus[0], let quietest = nextTwo.min(), partLevels[0] <= quietest - sectionDb {
            introEnd = edges[1]
        }
        var lastChorusEnd: Int?
        if let lastChorus = isChorus.lastIndex(of: true), lastChorus < partLevels.count - 1 {
            lastChorusEnd = edges[lastChorus + 1]
        }
        return (introEnd, lastChorusEnd)
    }

    /// Cambios de seccion con el compas en que empieza cada uno.
    private static func sections(_ barLines: [Int], _ levels: [Double]) -> [(bar: Int, change: SectionChange)] {
        var found: [(bar: Int, change: SectionChange)] = []
        guard levels.count >= 2 * sectionBars else { return found }
        for bar in sectionBars...(levels.count - sectionBars) {
            var before = 0.0
            var after = 0.0
            for j in (bar - sectionBars)..<bar { before += levels[j] }
            for j in bar..<(bar + sectionBars) { after += levels[j] }
            let delta = (after - before) / Double(sectionBars)
            if abs(delta) <= sectionDb { continue }
            let change = SectionChange(timeMs: toMs(barLines[bar]), deltaDb: (delta * 10).rounded() / 10)
            if let previous = found.last, bar - previous.bar < sectionBars {
                if abs(delta) > abs(previous.change.deltaDb) { found[found.count - 1] = (bar, change) }
            } else {
                found.append((bar, change))
            }
        }
        return found
    }
}
