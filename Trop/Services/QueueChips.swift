//
//  QueueChips.swift
//  Trop
//
//  Los botones de la cola de YouTube Music (Familiar, Populares, Descubrir, generos...): cada uno pide otra radio de la
//  misma cancion, con otro caracter. Llegan en la respuesta de la radio y al tocar uno se cambia lo que viene despues.
//

import Foundation
import Observation

struct QueueChip: Hashable, Sendable {
    let title: String
    /// La radio de ese boton (nil en "Todas": la radio normal).
    let playlistId: String?
    let params: String?

    /// El titulo en espanol (YouTube lo manda en ingles; los generos que no se conocen se dejan tal cual).
    var displayTitle: String {
        let names = [
            "All": "Todas", "Familiar": "Conocida", "Popular": "Populares", "Discover": "Por descubrir",
            "Deep cuts": "De culto", "Party": "Fiesta", "Chill": "Relax", "Workout": "Entrenamiento",
            "Romance": "Romántica", "Pump-up": "Motivación", "Reggaeton": "Reguetón", "Electronic": "Electrónica",
            "Latin pop": "Pop latino", "Focus": "Concentración", "Sleep": "Dormir", "Commute": "Desplazamientos"
        ]
        return names[title] ?? title
    }
}

@MainActor
@Observable
final class QueueChipsStore {
    static let shared = QueueChipsStore()

    private(set) var chips: [QueueChip] = []
    private(set) var selected: String?
    private(set) var isLoading = false

    @ObservationIgnored private var loadTask: Task<Void, Never>?

    private init() {}

    /// Los botones de una radio recien pedida; el primero ("Todas") queda elegido.
    func set(_ chips: [QueueChip]) {
        loadTask?.cancel()
        self.chips = chips
        selected = chips.first?.title
        isLoading = false
    }

    /// La cola es otra (un album, una lista...): no hay botones.
    func clear() {
        loadTask?.cancel()
        chips = []
        selected = nil
        isLoading = false
    }

    /// Pide la radio del boton y cambia lo que queda por sonar; lo que ya sono y la que suena se quedan.
    func select(_ chip: QueueChip) {
        guard !isLoading, chip.title != selected else { return }
        loadTask?.cancel()
        selected = chip.title
        isLoading = true
        loadTask = Task { await load(chip) }
    }

    private func load(_ chip: QueueChip) async {
        defer { isLoading = false }
        let np = NowPlaying.shared
        guard let videoId = np.videoId, np.queueSongs.indices.contains(np.queueIndex) else { return }
        do {
            let radio = try await PersonalizationService.shared.fetchRadio(
                videoId: videoId, options: .default, playlistId: chip.playlistId
            )
            guard !Task.isCancelled, np.videoId == videoId else { return }
            let head = Array(np.queueSongs.prefix(np.queueIndex + 1))
            let headIds = Set(head.map(\.videoId))
            let tail = radio.songs.filter { !headIds.contains($0.videoId) }
            guard !tail.isEmpty else {
                PlaybackReport.record("cola: el boton \(chip.title) no trajo canciones nuevas")
                return
            }
            np.queueSongs = head + tail
            np.applyAudioVersions()
            np.persistQueueState()
            PlaybackReport.record("cola: boton \(chip.title): \(tail.count) canciones")
        } catch {
            PlaybackReport.record("cola: el boton \(chip.title) fallo (\(error.localizedDescription))")
        }
    }
}
