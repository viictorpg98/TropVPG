//
//  VocalMaskStore.swift
//  Trop
//
//  Idea de la "regla de proteccion vocal" de AutoMix de LastWave (github.com/Clash-Projects/LastWave-Native, GPL-3.0):
//  dos voces cantando a la vez durante una mezcla suenan fatal, asi que se mide cuando canta cada cancion y la mezcla
//  se coloca (o se acorta) para que no se pisen. Aqui se saca de la letra sincronizada que ya tiene la app.
//

import Foundation

/// Cuando se canta en cada cancion (en segundos), sacado de las lineas de su letra sincronizada.
@MainActor
final class VocalMaskStore {
    static let shared = VocalMaskStore()

    typealias Segment = (start: Double, end: Double)

    private var masks: [String: [Segment]] = [:]
    private var finished: Set<String> = []
    private var startedAt: [String: Date] = [:]

    private init() {}

    /// Pide la letra de la cancion (una sola vez) y construye su mascara.
    func request(_ videoId: String) {
        guard startedAt[videoId] == nil else { return }
        startedAt[videoId] = Date()
        Task { [weak self] in
            let lines = try? await LyricsService.shared.fetchLyrics(videoId: videoId)
            guard let self else { return }
            if let lines, let segments = Self.segments(from: lines, offset: SettingsStore.shared.lyricsOffsetSeconds) {
                self.masks[videoId] = segments
            }
            self.finished.insert(videoId)
        }
    }

    /// Ya se sabe si hay mascara o no (o se ha esperado demasiado): se puede planificar la mezcla.
    func isSettled(_ videoId: String) -> Bool {
        if finished.contains(videoId) || masks[videoId] != nil { return true }
        guard let started = startedAt[videoId] else { return false }
        return Date().timeIntervalSince(started) > 8
    }

    /// `nil` si no hay letra sincronizada (no se sabe cuando canta).
    func segments(for videoId: String) -> [Segment]? { masks[videoId] }

    /// Lineas de letra -> tramos cantados. Cada linea dura lo que la cantan: segun su largo, entre 1,5 y 6 s, sin pasar de
    /// la siguiente; los huecos cortos entre lineas se unen.
    nonisolated static func segments(from lines: [LyricLine], offset: Double) -> [Segment]? {
        let synced = lines
            .filter { $0.startTime != nil && !isInstrumental($0.text) }
            .sorted { ($0.startTime ?? 0) < ($1.startTime ?? 0) }
        guard synced.count >= 3 else { return nil }
        var raw: [Segment] = []
        for (index, line) in synced.enumerated() {
            guard let startTime = line.startTime else { continue }
            let start = startTime - offset
            let next = index + 1 < synced.count ? (synced[index + 1].startTime ?? start + 4) - offset : start + 4
            let estimated = min(max(Double(line.text.count) * 0.07, 1.5), 6)
            raw.append((start, max(min(next, start + estimated), start + 0.5)))
        }
        var merged: [Segment] = []
        for segment in raw {
            if let last = merged.last, segment.start - last.end < 0.4 {
                merged[merged.count - 1] = (last.start, max(last.end, segment.end))
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    nonisolated private static func isInstrumental(_ text: String) -> Bool {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "♪*· ")).isEmpty
    }

    /// Milisegundos en que cantan las dos a la vez durante una mezcla.
    nonisolated static func overlapMs(
        outgoing: [Segment], incoming: [Segment],
        outgoingStart: Double, incomingStart: Double, duration: Double
    ) -> Int {
        func active(_ segments: [Segment], _ time: Double) -> Bool {
            segments.contains { time >= $0.start && time <= $0.end }
        }
        var total = 0
        var t = 0.0
        while t < duration {
            if active(outgoing, outgoingStart + t), active(incoming, incomingStart + t) { total += 50 }
            t += 0.05
        }
        return total
    }
}
