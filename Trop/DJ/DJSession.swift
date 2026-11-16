//
//  DJSession.swift
//  Trop
//
//  El DJ automatico: una SESION que se inicia y se para (boton del reproductor, menu de la cola o tarjeta del Inicio). Mientras esta en
//  marcha:
//  - Ordena lo que queda de la cola para que cada cancion encaje con la anterior (tempo y tonalidad; `QueueSmartOrder`), y sigue
//    ordenando conforme se van analizando mas canciones. La siguiente, una vez fijada, no se mueve.
//  - Deja cada cancion en un buen punto, sin esperar a que acabe (`DJPlanner`, a traves del motor de AutoMix).
//
//  La sesion no se guarda: al abrir la app el DJ esta apagado. Todo lo que hace se apunta en el Informe con el prefijo "dj:".
//

import Foundation

@MainActor
final class DJSession {
    static let shared = DJSession()

    private var loop: Task<Void, Never>?
    /// Cuantas canciones analizadas habia la ultima vez que se ordeno (para no reordenar si no hay nada nuevo).
    private var lastAnalyzedCount = -1
    /// Canciones que habia por sonar en la ultima pasada (para notar que la cola ha cambiado por completo).
    private var knownUpcoming = Set<String>()
    /// Ya se ordeno la cola entera una vez en esta sesion: a partir de ahi la siguiente cancion no se mueve.
    private var hasSortedOnce = false

    private static let analyzeAhead = 12
    private static let passInterval: UInt64 = 4_000_000_000

    private init() {}

    var isActive: Bool { DJSettings.shared.sessionActive }

    /// Enciende o apaga la sesion; devuelve si queda encendida.
    @discardableResult
    func toggle() -> Bool {
        if isActive { stop() } else { start() }
        return isActive
    }

    func start() {
        guard !isActive else { return }
        DJSettings.shared.sessionActive = true
        lastAnalyzedCount = -1
        knownUpcoming = []
        hasSortedOnce = false
        PlaybackReport.record("dj: sesion iniciada (ordenar \(DJSettings.shared.sortQueue), cortar antes \(DJSettings.shared.cutEarly))")
        // Lo planificado hasta ahora era para el final natural de la cancion: se rehace con el DJ.
        AutoMixEngine.shared.replan()
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.pass()
                try? await Task.sleep(nanoseconds: Self.passInterval)
            }
        }
    }

    func stop() {
        guard isActive else { return }
        DJSettings.shared.sessionActive = false
        loop?.cancel()
        loop = nil
        PlaybackReport.record("dj: sesion parada")
        AutoMixEngine.shared.replan()
    }

    /// Lo llama `WaveformStore.songStarted`: una cancion empieza (tocar, saltar, relevo de AutoMix). Se aprovecha para ordenar sin esperar
    /// a la siguiente pasada.
    func songStarted(videoId: String) {
        guard isActive else { return }
        pass()
    }

    /// Una pasada: pide analizar las siguientes y, si hay algo nuevo, las ordena.
    private func pass() {
        guard isActive else { return }
        let np = NowPlaying.shared
        guard np.queueSongs.indices.contains(np.queueIndex), np.queueIndex + 1 < np.queueSongs.count else { return }
        let store = TrackAnalysisStore.shared
        let upcoming = Array(np.queueSongs[(np.queueIndex + 1)...])
        let window = upcoming.prefix(Self.analyzeAhead).filter { !store.isLong($0.videoId) }
        for song in window { store.request(song.videoId) }

        guard DJSettings.shared.sortQueue else { return }
        let ids = Set(upcoming.map(\.videoId))
        // Una cola distinta (otra lista, otra mezcla): se vuelve a ordenar desde cero, la siguiente incluida.
        if !knownUpcoming.isEmpty, ids.intersection(knownUpcoming).count * 2 < ids.count {
            hasSortedOnce = false
            lastAnalyzedCount = -1
        }
        knownUpcoming = ids
        let analyzed = window.filter { (store.structure(for: $0.videoId)?.bpm ?? 0) > 0 }.count
        guard analyzed >= 2, analyzed != lastAnalyzedCount, !AutoMixEngine.shared.isActive else { return }

        switch QueueSmartOrder.reorderUpcoming(freezeNext: hasSortedOnce) {
        case .done(let ordered, let pending):
            hasSortedOnce = true
            lastAnalyzedCount = analyzed
            knownUpcoming = Set(NowPlaying.shared.queueSongs.dropFirst(NowPlaying.shared.queueIndex + 1).map(\.videoId))
            PlaybackReport.record("dj: cola ordenada (\(ordered) ordenadas, \(pending) sin analizar aun)")
        case .nothingToOrder, .mixInProgress:
            break
        }
    }
}
