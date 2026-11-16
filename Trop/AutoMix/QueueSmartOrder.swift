//
//  QueueSmartOrder.swift
//  Trop
//
//  "Ordenar por BPM y tonalidad": reordena lo que queda por sonar para que cada cancion encaje con la anterior (tempo parecido y
//  tonalidad compatible en la rueda Camelot). La que suena y las ya sonadas no se tocan. Solo se ordenan las canciones ya
//  analizadas; el resto queda al final, en su orden. Al pedirlo se manda analizar las 12 siguientes, asi que pulsarlo una segunda
//  vez, un rato despues, ordena mas.
//

import Foundation

@MainActor
enum QueueSmartOrder {
    enum Outcome {
        /// No hay nada que ordenar (cola vacia, o la que suena es la ultima).
        case nothingToOrder
        /// Hay una mezcla armada o sonando: reordenar ahora la estropearia.
        case mixInProgress
        /// `ordered`: canciones puestas en orden; `pending`: las que aun no tienen analisis y se quedaron al final.
        case done(ordered: Int, pending: Int)
    }

    private static let analyzeAhead = 12

    static func reorderUpcoming() -> Outcome {
        let np = NowPlaying.shared
        guard np.queueSongs.indices.contains(np.queueIndex), np.queueIndex + 1 < np.queueSongs.count else {
            return .nothingToOrder
        }
        guard !AutoMixEngine.shared.isActive else { return .mixInProgress }

        let store = TrackAnalysisStore.shared
        let current = np.queueSongs[np.queueIndex]
        let head = Array(np.queueSongs[...np.queueIndex])
        let upcoming = Array(np.queueSongs[(np.queueIndex + 1)...])

        for song in upcoming.prefix(analyzeAhead) { store.request(song.videoId) }

        var pool: [(song: SongItem, structure: TrackStructure)] = []
        var pending: [SongItem] = []
        for song in upcoming {
            if let structure = store.structure(for: song.videoId), structure.bpm > 0 {
                pool.append((song, structure))
            } else {
                pending.append(song)
            }
        }
        guard pool.count >= 2 else { return .done(ordered: pool.count, pending: pending.count) }

        // Se parte de la que suena (si esta analizada) y siempre se elige la siguiente que mejor encaja con la ultima.
        var last: TrackStructure? = store.structure(for: current.videoId)
        var ordered: [SongItem] = []
        while !pool.isEmpty {
            var bestIndex = 0
            var bestCost = Double.greatestFiniteMagnitude
            for (index, candidate) in pool.enumerated() {
                let value = cost(from: last, to: candidate.structure)
                if value < bestCost {
                    bestCost = value
                    bestIndex = index
                }
            }
            let chosen = pool.remove(at: bestIndex)
            ordered.append(chosen.song)
            last = chosen.structure
        }

        let newQueue = head + ordered + pending
        if newQueue.map(\.videoId) != np.queueSongs.map(\.videoId) {
            np.queueSongs = newQueue
            np.persistQueueState()
            // La mezcla que estaba planificada era con la que iba despues: se rehace con la nueva siguiente.
            AutoMixEngine.shared.replan()
        }
        PlaybackReport.record("cola: ordenada por BPM y tonalidad (\(ordered.count) ordenadas, \(pending.count) sin analizar)")
        return .done(ordered: ordered.count, pending: pending.count)
    }

    /// Cuanto cuesta que `to` suene despues de `from`: la diferencia de tempo (contando mitad y doble) y la distancia en la rueda
    /// Camelot. Menos es mejor. Sin tonalidad en alguna de las dos, un valor medio (ni premia ni castiga).
    private static func cost(from: TrackStructure?, to: TrackStructure) -> Double {
        guard let from, from.bpm > 0 else { return 0 }
        let folded = AutoMixMath.foldedRatio(outgoingBpm: from.bpm, incomingBpm: to.bpm)
        let tempoCost = abs(1 - folded) * 100 / 4
        let keyCost: Double
        if let fromKey = from.key, let toKey = to.key {
            keyCost = Double(KeyDetector.distance(fromKey, toKey))
        } else {
            keyCost = 1.5
        }
        return tempoCost + keyCost
    }
}
