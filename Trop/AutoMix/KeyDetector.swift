//
//  KeyDetector.swift
//  Trop
//
//  Detecta la tonalidad de una cancion (mayor o menor) con el audio que ya se lee para analizarla (mono, 16 bits, 8 kHz).
//  Metodo clasico: se mide cuanta energia hay en cada nota (Goertzel sobre trozos de ~0,5 s repartidos por la cancion), se juntan
//  las octavas en 12 notas y se compara con los perfiles de tonalidad de Krumhansl y Kessler. Con audio tan reducido y sin separar
//  instrumentos, se equivoca en algunas canciones (sobre todo con la relativa mayor/menor): es una ayuda, no una medida exacta.
//
//  La tonalidad se guarda como un numero de 0 a 23: 0-11 = mayor (0 = do, 1 = do#...), 12-23 = menor (12 = do menor...).
//

import Foundation

enum KeyDetector {
    private static let frameLength = 4096
    private static let maxFrames = 80
    /// Notas MIDI que se miran: de mi2 (82 Hz) a si6 (1976 Hz), por debajo del limite de 4 kHz de este audio.
    private static let midiRange = 40...95

    private static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// `nil` si el audio es demasiado corto o no tiene tonos claros.
    static func detect(_ pcm: [Int16], sampleRate: Int, fromSample: Int, toSample: Int) -> Int? {
        let start = max(0, fromSample)
        let end = min(pcm.count, toSample)
        guard end - start > frameLength * 4 else { return nil }

        let window = (0..<frameLength).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(frameLength - 1)) }
        let coefficients = midiRange.map { midi -> Double in
            let frequency = 440 * pow(2, Double(midi - 69) / 12)
            return 2 * cos(2 * Double.pi * frequency / Double(sampleRate))
        }

        let span = end - start - frameLength
        let count = min(maxFrames, span / (frameLength / 2))
        guard count >= 4 else { return nil }
        let step = max(1, span / count)

        var chroma = [Double](repeating: 0, count: 12)
        var frame = [Double](repeating: 0, count: frameLength)
        var used = 0
        for index in 0..<count {
            let origin = start + index * step
            var energy = 0.0
            for position in 0..<frameLength {
                let value = Double(pcm[origin + position]) / 32768 * window[position]
                frame[position] = value
                energy += value * value
            }
            // Los trozos casi en silencio no dicen nada.
            guard energy / Double(frameLength) > 1e-6 else { continue }

            var frameChroma = [Double](repeating: 0, count: 12)
            var total = 0.0
            for (offset, coefficient) in coefficients.enumerated() {
                var previous = 0.0
                var beforePrevious = 0.0
                for sample in frame {
                    let current = sample + coefficient * previous - beforePrevious
                    beforePrevious = previous
                    previous = current
                }
                let power = previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
                let magnitude = max(0, power).squareRoot()
                let pitchClass = (midiRange.lowerBound + offset) % 12
                frameChroma[pitchClass] += magnitude
                total += magnitude
            }
            guard total > 0 else { continue }
            // Cada trozo pesa igual, suene fuerte o flojo.
            for pitchClass in 0..<12 { chroma[pitchClass] += frameChroma[pitchClass] / total }
            used += 1
        }
        guard used >= 4 else { return nil }

        var winner: (key: Int, score: Double)?
        for tonic in 0..<12 {
            for (minor, profile) in [(false, majorProfile), (true, minorProfile)] {
                // El perfil se gira para que su primera nota sea la tonica probada.
                let rotated = (0..<12).map { profile[($0 - tonic + 12) % 12] }
                let score = correlation(chroma, rotated)
                if winner == nil || score > winner!.score { winner = (minor ? 12 + tonic : tonic, score) }
            }
        }
        // Una correlacion tan baja es ruido (percusion sola, por ejemplo).
        guard let found = winner, found.score > 0.2 else { return nil }
        return found.key
    }

    private static func correlation(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let meanLeft = lhs.reduce(0, +) / Double(lhs.count)
        let meanRight = rhs.reduce(0, +) / Double(rhs.count)
        var numerator = 0.0
        var leftSquares = 0.0
        var rightSquares = 0.0
        for index in 0..<lhs.count {
            let left = lhs[index] - meanLeft
            let right = rhs[index] - meanRight
            numerator += left * right
            leftSquares += left * left
            rightSquares += right * right
        }
        let denominator = (leftSquares * rightSquares).squareRoot()
        return denominator > 0 ? numerator / denominator : 0
    }

    // MARK: - Nombres

    /// Numeracion Camelot ("8A" = la menor, "8B" = do mayor), la que usan los DJ para mezclar por tonalidad.
    /// Indice = nota (0 = do ... 11 = si). Mayores y menores: do mayor = 8B, la menor = 8A, sol mayor = 9B, mi menor = 9A...
    private static let camelotMajor = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]
    private static let camelotMinor = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10]

    /// "8B", "5A"... o `nil` si la tonalidad no es valida.
    static func camelot(_ key: Int) -> String? {
        guard (0..<24).contains(key) else { return nil }
        return key < 12 ? "\(camelotMajor[key])B" : "\(camelotMinor[key - 12])A"
    }

    /// Numero (1-12) y letra de la tonalidad en la rueda Camelot.
    static func wheelPosition(_ key: Int) -> (number: Int, isMinor: Bool)? {
        guard (0..<24).contains(key) else { return nil }
        return key < 12 ? (camelotMajor[key], false) : (camelotMinor[key - 12], true)
    }

    /// Lo bien que suenan dos tonalidades seguidas, de 0 (iguales) a 3 (chocan): misma posicion o su relativa (misma
    /// numeracion, otra letra) = 0, una posicion a cada lado de la rueda = 1, dos = 2, el resto = 3.
    static func distance(_ lhs: Int, _ rhs: Int) -> Int {
        guard let left = wheelPosition(lhs), let right = wheelPosition(rhs) else { return 3 }
        let raw = abs(left.number - right.number)
        let around = min(raw, 12 - raw)
        if around == 0 { return 0 }
        // Un paso en la rueda con la misma letra se mezcla bien; con otra letra y un paso, ya no tanto.
        if left.isMinor == right.isMinor {
            return around == 1 ? 1 : (around == 2 ? 2 : 3)
        }
        return around == 1 ? 2 : 3
    }
}
