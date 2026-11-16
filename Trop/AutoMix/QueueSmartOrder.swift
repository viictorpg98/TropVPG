//
//  QueueSmartOrder.swift
//  Trop
//
//  "Ordenar por BPM y tonalidad": reordena lo que queda por sonar para que cada cancion encaje con la anterior (tempo parecido y
//  tonalidad compatible en la rueda Camelot). La que suena y las ya sonadas no se tocan. Solo se ordenan las canciones ya
//  analizadas; el resto queda al final, en su orden. `sortAndAnnounce` pide analizar las 12 siguientes y espera hasta ~30 s a que
//  se vayan haciendo (con avisos de progreso) antes de ordenar; lo ya analizado queda guardado, asi que pulsarlo otra vez un
//  rato despues ordena mas.
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
    /// Cuantas canciones siguientes se mandan analizar antes de ordenar, y lo mas que se espera a que se hagan.
    private static let waitAhead = 12
    private static let maxWaitSeconds = 30
    private static var isSorting = false

    /// Pide analizar las canciones siguientes, espera a que se vayan haciendo (con avisos) y ordena. Todo lo que pasa se avisa con
    /// un mensaje; si ya hay una ordenacion en curso, no hace nada.
    static func sortAndAnnounce() async {
        guard !isSorting else { return }
        isSorting = true
        defer { isSorting = false }
        let notice = PlaybackNotice.shared
        let np = NowPlaying.shared
        let store = TrackAnalysisStore.shared

        guard np.queueSongs.indices.contains(np.queueIndex), np.queueIndex + 1 < np.queueSongs.count else {
            notice.show(NSLocalizedString("Nothing left in the queue to sort.", comment: ""))
            return
        }
        // Las canciones largas (mezclas de horas) no se analizan enteras: no se espera por ellas.
        let ids = np.queueSongs[(np.queueIndex + 1)...].prefix(waitAhead).map(\.videoId).filter { !store.isLong($0) }

        // Si ninguna de las que faltan por analizar se puede leer ahora (sin Wi-Fi y sin descargar), esperar no sirve de nada.
        func missing() -> [String] { ids.filter { !store.isSettled($0) } }
        let readable = missing().filter { AutoMixSource.isAvailable(videoId: $0) }
        if !missing().isEmpty, readable.isEmpty {
            PlaybackReport.record("cola: ordenar sin esperar (las canciones sin analizar no se pueden leer ahora: sin Wi-Fi ni descarga)")
        } else if !missing().isEmpty {
            notice.show(String(
                format: NSLocalizedString("Analyzing the next songs to sort them… %d of %d ready.", comment: ""),
                ids.count - missing().count, ids.count
            ), duration: 8)
            var seconds = 0
            while seconds < maxWaitSeconds, !missing().isEmpty {
                for id in missing() { store.request(id) }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                seconds += 1
                if seconds % 5 == 0, !missing().isEmpty {
                    notice.show(String(
                        format: NSLocalizedString("Analyzing the next songs to sort them… %d of %d ready.", comment: ""),
                        ids.count - missing().count, ids.count
                    ), duration: 8)
                }
            }
            PlaybackReport.record("cola: espera de analisis acabada tras \(seconds) s (\(ids.count - missing().count) de \(ids.count) listas)")
        }

        let message: String
        switch reorderUpcoming() {
        case .nothingToOrder:
            message = NSLocalizedString("Nothing left in the queue to sort.", comment: "")
        case .mixInProgress:
            message = NSLocalizedString("A mix is in progress. Try again in a moment.", comment: "")
        case .done(let ordered, let pending):
            if ordered < 2 {
                message = NSLocalizedString("Not enough analyzed songs yet. Try again in a minute.", comment: "")
            } else if pending > 0 {
                message = String(format: NSLocalizedString("%d songs sorted; %d still being analyzed.", comment: ""), ordered, pending)
            } else {
                message = String(format: NSLocalizedString("%d songs sorted.", comment: ""), ordered)
            }
        }
        notice.show(message)
    }

    /// `freezeNext`: la cancion que va a continuacion no se mueve (su mezcla ya puede estar planificada o preparada); se ordena el resto
    /// a partir de ella.
    static func reorderUpcoming(freezeNext: Bool = false) -> Outcome {
        let np = NowPlaying.shared
        guard np.queueSongs.indices.contains(np.queueIndex), np.queueIndex + 1 < np.queueSongs.count else {
            return .nothingToOrder
        }
        guard !AutoMixEngine.shared.isActive else { return .mixInProgress }

        let store = TrackAnalysisStore.shared
        let current = np.queueSongs[np.queueIndex]
        var head = Array(np.queueSongs[...np.queueIndex])
        var upcoming = Array(np.queueSongs[(np.queueIndex + 1)...])
        // Con la siguiente fija, esta pasa a ser parte de lo que ya esta colocado y el orden sigue desde ella.
        let frozen: SongItem? = freezeNext && upcoming.count >= 2 ? upcoming.removeFirst() : nil
        if let frozen { head.append(frozen) }

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
        var last: TrackStructure? = store.structure(for: (frozen ?? current).videoId)
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
            // La mezcla que estaba planificada era con la que iba despues: se rehace con la nueva siguiente (si la siguiente no se
            // ha movido, lo planificado sigue valiendo).
            if frozen == nil { AutoMixEngine.shared.replan() }
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
