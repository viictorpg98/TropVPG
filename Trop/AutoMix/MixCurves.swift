//
//  MixCurves.swift
//  Trop
//
//  Las curvas de una mezcla (como el editor de Spotify): tres carriles, cada uno con una curva para la saliente y otra para la entrante.
//  El eje x es lo que lleva avanzado la mezcla (0 = empieza, 1 = acaba) y el eje y, un valor de 0 a 1:
//  - Volumen: ganancia de toda la cancion (0 = silencio, 1 = entera).
//  - Graves: ganancia de los graves (por debajo de ~250 Hz) ademas del volumen; es lo que hace el "intercambio de graves".
//  - Filtro: cuanto se filtra (0 = nada). En la saliente cierra un paso bajo (de 20 kHz a 200 Hz); en la entrante abre un paso alto (de 2 kHz a 20 Hz).
//
//  Cada carril lleva un preajuste (por su nombre) o "custom" si se han movido los puntos a mano. Las curvas son lineales a trozos.
//  Solo se usan en el modo Manual del editor; la mezcla automatica no pasa por aqui y suena exactamente como antes.
//

import Foundation

/// Un punto de una curva: `x` = avance de la mezcla (0...1) e `y` = valor (0...1).
struct MixPoint: Codable, Equatable {
    var x: Double
    var y: Double
}

enum MixLane: String, CaseIterable, Codable {
    case volume, bass, filter

    /// Los preajustes de cada carril (el primero es el de siempre).
    var presets: [String] {
        switch self {
        case .volume: return ["smooth", "overlap", "fadeInOut", "cutInFadeOut", "fadeInCutOut"]
        case .bass: return ["centre", "early", "late", "follow"]
        case .filter: return ["sweep", "none", "lowPassOut", "highPassIn"]
        }
    }

    /// El texto (en ingles, la clave de la traduccion) de un preajuste.
    func title(for preset: String) -> String {
        switch (self, preset) {
        case (.volume, "smooth"): return "Smooth Crossfade"
        case (.volume, "overlap"): return "Overlap"
        case (.volume, "fadeInOut"): return "Fade In, Fade Out"
        case (.volume, "cutInFadeOut"): return "Cut In, Fade Out"
        case (.volume, "fadeInCutOut"): return "Fade In, Cut Out"
        case (.bass, "centre"): return "Centre Bass Swap"
        case (.bass, "early"): return "Early Bass Swap"
        case (.bass, "late"): return "Late Bass Swap"
        case (.bass, "follow"): return "Follow Volume"
        case (.filter, "sweep"): return "Filter Sweep"
        case (.filter, "none"): return "No Filter"
        case (.filter, "lowPassOut"): return "Low-Pass Filter Out"
        case (.filter, "highPassIn"): return "High-Pass Filter In"
        default: return "Custom"
        }
    }
}

/// Las dos curvas (saliente y entrante) de un carril y el preajuste del que vienen.
struct MixLaneCurves: Codable, Equatable {
    var preset: String
    var outgoing: [MixPoint]
    var incoming: [MixPoint]

    /// El carril con un preajuste (si no existe, el primero del carril).
    static func make(_ lane: MixLane, _ name: String) -> MixLaneCurves {
        let chosen = lane.presets.contains(name) ? name : lane.presets[0]
        let (out, inc) = points(lane, chosen)
        return MixLaneCurves(preset: chosen, outgoing: out, incoming: inc)
    }

    private static func p(_ x: Double, _ y: Double) -> MixPoint { MixPoint(x: x, y: y) }

    private static func points(_ lane: MixLane, _ preset: String) -> ([MixPoint], [MixPoint]) {
        switch (lane, preset) {
        case (.volume, "overlap"):
            return ([p(0, 1), p(0.6, 1), p(1, 0)], [p(0, 0), p(0.4, 1), p(1, 1)])
        case (.volume, "fadeInOut"):
            return ([p(0, 1), p(0.5, 0), p(1, 0)], [p(0, 0), p(0.5, 0), p(1, 1)])
        case (.volume, "cutInFadeOut"):
            return ([p(0, 1), p(1, 0)], [p(0, 0), p(0.02, 1), p(1, 1)])
        case (.volume, "fadeInCutOut"):
            return ([p(0, 1), p(0.98, 1), p(1, 0)], [p(0, 0), p(1, 1)])
        case (.volume, _):
            // Coseno y seno de siempre, en cinco puntos.
            return (
                [p(0, 1), p(0.25, 0.92), p(0.5, 0.71), p(0.75, 0.38), p(1, 0)],
                [p(0, 0), p(0.25, 0.38), p(0.5, 0.71), p(0.75, 0.92), p(1, 1)]
            )
        case (.bass, "early"):
            return ([p(0, 1), p(0.2, 1), p(0.35, 0), p(1, 0)], [p(0, 0), p(0.2, 0), p(0.35, 1), p(1, 1)])
        case (.bass, "late"):
            return ([p(0, 1), p(0.65, 1), p(0.8, 0), p(1, 0)], [p(0, 0), p(0.65, 0), p(0.8, 1), p(1, 1)])
        case (.bass, "follow"):
            return ([p(0, 1), p(1, 1)], [p(0, 1), p(1, 1)])
        case (.bass, _):
            return ([p(0, 1), p(0.42, 1), p(0.58, 0), p(1, 0)], [p(0, 0), p(0.42, 0), p(0.58, 1), p(1, 1)])
        case (.filter, "none"):
            return ([p(0, 0), p(1, 0)], [p(0, 0), p(1, 0)])
        case (.filter, "lowPassOut"):
            return (sweepOut, [p(0, 0), p(1, 0)])
        case (.filter, "highPassIn"):
            return ([p(0, 0), p(1, 0)], sweepIn)
        case (.filter, _):
            return (sweepOut, sweepIn)
        }
    }

    private static let sweepOut: [MixPoint] = [p(0, 0.05), p(0.25, 0.18), p(0.5, 0.5), p(0.75, 0.82), p(1, 0.95)]
    private static let sweepIn: [MixPoint] = [p(0, 0.95), p(0.25, 0.82), p(0.5, 0.5), p(0.75, 0.18), p(1, 0.05)]
}

/// Todas las curvas de una mezcla.
struct MixCurves: Codable, Equatable {
    var volume: MixLaneCurves
    var bass: MixLaneCurves
    var filter: MixLaneCurves

    /// Las de siempre: coseno y seno, intercambio de graves al centro y barrido de filtros.
    static var standard: MixCurves {
        MixCurves(
            volume: .make(.volume, "smooth"), bass: .make(.bass, "centre"), filter: .make(.filter, "sweep")
        )
    }

    func lane(_ lane: MixLane) -> MixLaneCurves {
        switch lane {
        case .volume: return volume
        case .bass: return bass
        case .filter: return filter
        }
    }

    mutating func set(_ lane: MixLane, _ value: MixLaneCurves) {
        switch lane {
        case .volume: volume = value
        case .bass: bass = value
        case .filter: filter = value
        }
    }

    // MARK: - Editar puntos (para el editor de curvas)

    /// Separacion minima en x entre dos puntos.
    static let minGap = 0.02

    /// Mueve un punto. El primero y el ultimo solo se mueven en y (su x es 0 y 1); los demas quedan entre sus vecinos.
    mutating func move(_ lane: MixLane, outgoing isOutgoing: Bool, index: Int, to point: MixPoint) {
        var value = self.lane(lane)
        var points = isOutgoing ? value.outgoing : value.incoming
        guard points.indices.contains(index) else { return }
        let y = min(max(point.y, 0), 1)
        if index == 0 {
            points[0].y = y
        } else if index == points.count - 1 {
            points[index].y = y
        } else {
            let low = points[index - 1].x + Self.minGap
            let high = points[index + 1].x - Self.minGap
            points[index] = MixPoint(x: min(max(point.x, low), max(high, low)), y: y)
        }
        if isOutgoing { value.outgoing = points } else { value.incoming = points }
        value.preset = "custom"
        set(lane, value)
    }

    /// Añade un punto en `x` sobre la curva (con el valor que ya tenia ahi).
    mutating func insert(_ lane: MixLane, outgoing isOutgoing: Bool, atX x: Double) {
        var value = self.lane(lane)
        var points = isOutgoing ? value.outgoing : value.incoming
        guard x > Self.minGap, x < 1 - Self.minGap, points.count < 12 else { return }
        // Sin otro punto demasiado cerca.
        if points.contains(where: { abs($0.x - x) < Self.minGap }) { return }
        let y = Self.value(of: points, at: x)
        points.append(MixPoint(x: x, y: y))
        points.sort { $0.x < $1.x }
        if isOutgoing { value.outgoing = points } else { value.incoming = points }
        value.preset = "custom"
        set(lane, value)
    }

    /// Quita un punto intermedio (el primero y el ultimo no se pueden quitar).
    mutating func remove(_ lane: MixLane, outgoing isOutgoing: Bool, index: Int) {
        var value = self.lane(lane)
        var points = isOutgoing ? value.outgoing : value.incoming
        guard index > 0, index < points.count - 1 else { return }
        points.remove(at: index)
        if isOutgoing { value.outgoing = points } else { value.incoming = points }
        value.preset = "custom"
        set(lane, value)
    }

    // MARK: - Evaluar

    /// El valor de una curva lineal a trozos en `x` (fuera del primer y ultimo punto, el de estos).
    static func value(of points: [MixPoint], at x: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        for index in 1..<points.count where x <= points[index].x {
            let a = points[index - 1]
            let b = points[index]
            let span = b.x - a.x
            return span > 0 ? a.y + (b.y - a.y) * (x - a.x) / span : b.y
        }
        return last.y
    }

    /// La curva muestreada en `count` valores (de x = 0 a x = 1), para el renderizador.
    static func table(_ points: [MixPoint], count: Int = 257) -> [Double] {
        (0..<count).map { value(of: points, at: Double($0) / Double(count - 1)) }
    }

    /// Las seis curvas muestreadas, en este orden: volumen saliente, volumen entrante, graves saliente, graves entrante, filtro saliente,
    /// filtro entrante.
    func tables() -> [[Double]] {
        [
            Self.table(volume.outgoing), Self.table(volume.incoming),
            Self.table(bass.outgoing), Self.table(bass.incoming),
            Self.table(filter.outgoing), Self.table(filter.incoming)
        ]
    }

    // MARK: - Guardar

    /// En texto (JSON), para guardarlo junto a lo demas de la eleccion.
    var encoded: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Lee lo guardado; `nil` si no es valido (curvas con menos de dos puntos, desordenadas o fuera de rango).
    init?(encoded: String) {
        guard let data = encoded.data(using: .utf8), let decoded = try? JSONDecoder().decode(MixCurves.self, from: data) else {
            return nil
        }
        for lane in MixLane.allCases {
            let value = decoded.lane(lane)
            for points in [value.outgoing, value.incoming] {
                guard points.count >= 2, points.count <= 12,
                      points.first?.x == 0, points.last?.x == 1,
                      points.allSatisfy({ $0.y >= 0 && $0.y <= 1 && $0.x >= 0 && $0.x <= 1 }),
                      zip(points, points.dropFirst()).allSatisfy({ $0.x < $1.x }) else { return nil }
            }
        }
        self = decoded
    }

    init(volume: MixLaneCurves, bass: MixLaneCurves, filter: MixLaneCurves) {
        self.volume = volume
        self.bass = bass
        self.filter = filter
    }
}
