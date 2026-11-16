//
//  DJHost.swift
//  Trop
//
//  El DJ: cuando empieza una cancion (y toca hablar), escribe una presentacion corta y la dice por encima de la musica, bajando
//  el volumen mientras habla. Apagado por defecto (Ajustes > Reproduccion > DJ). No habla si hay una mezcla de AutoMix
//  en marcha, si la musica esta en pausa o si ya ha pasado un rato desde que empezo la cancion.
//
//  Todo lo que hace se apunta en el Informe de reproduccion con el prefijo "dj:".
//

import Foundation

@MainActor
final class DJHost {
    static let shared = DJHost()

    /// Canciones desde que se activo: la primera siempre se presenta, luego cada `everySongs`.
    private var songCounter = 0
    private var lastSong: (id: String, title: String, artist: String)?
    private var task: Task<Void, Never>?
    private var generation = 0
    /// Volumen original mientras se esta bajando para hablar (`nil` si no se ha tocado).
    private var duckOriginal: Double?
    private static let duckFactor = 0.3
    /// Si ya ha pasado tanto desde que empezo la cancion, no se presenta (se estaria hablando por encima de la mitad).
    private static let maxSecondsIntoSong: TimeInterval = 45

    private init() {}

    // MARK: - Una cancion empieza

    /// Lo llama `WaveformStore.songStarted`, que se ejecuta en todos los cambios de cancion (tocar, saltar, relevo de AutoMix).
    func songStarted(videoId: String) {
        let settings = DJSettings.shared
        guard settings.enabled else {
            if lastSong != nil { reset() }
            return
        }
        let np = NowPlaying.shared
        guard np.queueSongs.indices.contains(np.queueIndex), np.queueSongs[np.queueIndex].videoId == videoId else { return }
        // La misma cancion avisada dos veces seguidas no cuenta dos veces.
        if lastSong?.id == videoId { return }

        let song = np.queueSongs[np.queueIndex]
        let previous = lastSong
        lastSong = (videoId, song.title, song.artists.map(\.name).joined(separator: ", "))
        songCounter += 1

        generation += 1
        let mine = generation
        task?.cancel()
        stopSpeaking()

        let every = max(1, settings.everySongs)
        guard songCounter == 1 || songCounter % every == 0 else { return }
        task = Task { [weak self] in
            await self?.introduce(song: song, previous: previous, generation: mine)
        }
    }

    private func reset() {
        generation += 1
        task?.cancel()
        stopSpeaking()
        lastSong = nil
        songCounter = 0
    }

    // MARK: - Presentar

    private func canTalk(about videoId: String, generation: Int) -> Bool {
        let np = NowPlaying.shared
        return !Task.isCancelled && generation == self.generation && DJSettings.shared.enabled
            && np.videoId == videoId && np.isPlaying && !AutoMixEngine.shared.isActive
            && np.currentTime < Self.maxSecondsIntoSong
    }

    private func introduce(song: SongItem, previous: (id: String, title: String, artist: String)?, generation: Int) async {
        // Unos instantes para que la cancion arranque antes de hablar.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard canTalk(about: song.videoId, generation: generation) else { return }

        let context = DJWriter.Context(
            title: song.title,
            artist: song.artists.map(\.name).joined(separator: ", "),
            album: song.album,
            year: song.year,
            previousTitle: previous?.title,
            previousArtist: previous?.artist
        )
        let line = await DJWriter.line(for: context, useModel: DJSettings.shared.useLanguageModel)
        PlaybackReport.record("dj: \(line.source.rawValue) (\(line.note)): \(line.text)")
        guard canTalk(about: song.videoId, generation: generation) else {
            PlaybackReport.record("dj: no se dice (la cancion o el estado cambiaron mientras se escribia)")
            return
        }
        await speakOverMusic(line.text)
    }

    /// Dice el texto bajando la musica y la devuelve a su sitio al acabar (o si se corta).
    func speakOverMusic(_ text: String) async {
        let player = PlayerController.shared
        let original = player.volumeScale
        duckOriginal = original
        let ducked = original * Self.duckFactor
        await ramp(from: original, to: ducked, steps: 5)
        // Si mientras bajaba el volumen cambio la cancion (la tarea se cancela), se devuelve el volumen y no se habla.
        if Task.isCancelled {
            restoreVolume()
            return
        }
        await DJSpeech.shared.speak(text, voiceId: DJSettings.shared.voiceId)
        restoreVolume()
    }

    private func ramp(from start: Double, to end: Double, steps: Int) async {
        let player = PlayerController.shared
        for step in 1...steps {
            if Task.isCancelled { return }
            player.volumeScale = start + (end - start) * Double(step) / Double(steps)
            player.applyPlayerVolume()
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    /// Vuelve el volumen a lo que era. Si hay una mezcla de AutoMix en marcha, el volumen es suyo y no se toca.
    private func restoreVolume() {
        guard let original = duckOriginal else { return }
        duckOriginal = nil
        guard !AutoMixEngine.shared.isActive else { return }
        let player = PlayerController.shared
        player.volumeScale = original
        player.applyPlayerVolume()
    }

    private func stopSpeaking() {
        DJSpeech.shared.stop()
        restoreVolume()
    }

    // MARK: - Pantalla de pruebas

    /// Escribe y dice la presentacion de la cancion que suena (o de una de ejemplo), y devuelve lo que ha pasado.
    func test() async -> String {
        let np = NowPlaying.shared
        var context = DJWriter.Context(title: "Bohemian Rhapsody", artist: "Queen", album: "A Night at the Opera", year: 1975)
        if np.queueSongs.indices.contains(np.queueIndex) {
            let song = np.queueSongs[np.queueIndex]
            context = DJWriter.Context(
                title: song.title,
                artist: song.artists.map(\.name).joined(separator: ", "),
                album: song.album,
                year: song.year,
                previousTitle: np.queueIndex > 0 ? np.queueSongs[np.queueIndex - 1].title : nil,
                previousArtist: np.queueIndex > 0
                    ? np.queueSongs[np.queueIndex - 1].artists.map(\.name).joined(separator: ", ") : nil
            )
        }
        let line = await DJWriter.line(for: context, useModel: DJSettings.shared.useLanguageModel)
        PlaybackReport.record("dj: prueba, \(line.source.rawValue) (\(line.note)): \(line.text)")
        if np.isPlaying {
            await speakOverMusic(line.text)
        } else {
            await DJSpeech.shared.speak(line.text, voiceId: DJSettings.shared.voiceId)
        }
        return "\(line.text)\n\n(\(line.source.rawValue): \(line.note))"
    }
}
