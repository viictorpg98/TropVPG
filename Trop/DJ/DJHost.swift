//
//  DJHost.swift
//  Trop
//
//  El DJ: una SESION que se inicia y se para (boton del reproductor, menu de la cola o tarjeta del Inicio). Mientras la sesion
//  esta en marcha, cuando empieza una cancion (y toca hablar) escribe una presentacion corta y la dice por encima de la musica,
//  bajando el volumen mientras habla. No habla si la musica esta en pausa o si ya ha pasado un rato desde que empezo la cancion;
//  si hay una mezcla de AutoMix en marcha, espera a que acabe (hasta 20 s).
//
//  La sesion no se guarda: al abrir la app el DJ esta apagado.
//
//  Todo lo que hace se apunta en el Informe de reproduccion con el prefijo "dj:".
//

import Foundation

@MainActor
final class DJHost {
    static let shared = DJHost()

    /// Canciones desde que se inicio la sesion: la primera siempre se presenta, luego cada `everySongs`.
    private var songCounter = 0
    private var lastSong: (id: String, title: String, artist: String)?
    private var task: Task<Void, Never>?
    private var generation = 0
    /// Volumen original y volumen bajado mientras se habla (`nil` si no se ha tocado).
    private var duckOriginal: Double?
    private var duckTarget: Double?
    private static let duckFactor = 0.3
    /// Si ya han pasado tantos segundos desde que empezo la cancion, no se presenta (se estaria hablando por encima de la mitad).
    private static let maxSecondsIntoSong: TimeInterval = 45
    /// Lo que se espera como maximo a que acabe una mezcla de AutoMix antes de hablar.
    private static let maxWaitForMix: TimeInterval = 20

    private init() {}

    // MARK: - Sesion

    var isActive: Bool { DJSettings.shared.sessionActive }

    /// Enciende o apaga la sesion; devuelve si queda encendida.
    @discardableResult
    func toggle() -> Bool {
        if isActive { stop() } else { start() }
        return isActive
    }

    /// Inicia la sesion. Si ya suena algo y `introduceCurrent`, presenta la que suena ahora; si no, queda armado y habla al
    /// empezar la siguiente cancion (es lo que pasa al iniciarlo desde el Inicio, que arranca una mezcla nueva).
    func start(introduceCurrent: Bool = true) {
        guard !isActive else { return }
        reset()
        DJSettings.shared.sessionActive = true
        PlaybackReport.record("dj: sesion iniciada")
        let np = NowPlaying.shared
        if introduceCurrent, np.isPlaying, !np.videoId.isEmpty {
            songStarted(videoId: np.videoId)
        }
    }

    /// Para la sesion: corta la voz si estaba hablando y devuelve el volumen.
    func stop() {
        guard isActive else { return }
        reset()
        DJSettings.shared.sessionActive = false
        PlaybackReport.record("dj: sesion parada")
    }

    // MARK: - Una cancion empieza

    /// Lo llama `WaveformStore.songStarted`, que se ejecuta en todos los cambios de cancion (tocar, saltar, relevo de AutoMix).
    func songStarted(videoId: String) {
        let settings = DJSettings.shared
        guard settings.sessionActive else { return }
        let np = NowPlaying.shared
        guard np.queueSongs.indices.contains(np.queueIndex), np.queueSongs[np.queueIndex].videoId == videoId else { return }
        // La misma cancion avisada dos veces seguidas no cuenta dos veces.
        if lastSong?.id == videoId { return }

        let song = np.queueSongs[np.queueIndex]
        let previous = lastSong
        lastSong = (videoId, song.title, song.artists.map(\.name).joined(separator: ", "))
        songCounter += 1
        // Tras un relevo de AutoMix la entrante ya lleva sonando un rato (la parte mezclada): el limite de los 45 s se cuenta
        // desde donde estaba la cancion al avisarse, no desde el segundo 0.
        let startPosition = np.currentTime

        generation += 1
        let mine = generation
        task?.cancel()
        stopSpeaking()

        let every = max(1, settings.everySongs)
        guard songCounter == 1 || songCounter % every == 0 else { return }
        task = Task { [weak self] in
            await self?.introduce(song: song, previous: previous, generation: mine, startPosition: startPosition)
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

    private func isCurrent(_ videoId: String, generation: Int) -> Bool {
        !Task.isCancelled && generation == self.generation && DJSettings.shared.sessionActive
            && NowPlaying.shared.videoId == videoId
    }

    private func canTalk(about videoId: String, generation: Int, startPosition: TimeInterval) -> Bool {
        let np = NowPlaying.shared
        return isCurrent(videoId, generation: generation) && np.isPlaying && !AutoMixEngine.shared.isActive
            && np.currentTime - startPosition < Self.maxSecondsIntoSong
    }

    private func introduce(
        song: SongItem, previous: (id: String, title: String, artist: String)?, generation: Int, startPosition: TimeInterval
    ) async {
        // Unos instantes para que la cancion arranque antes de hablar.
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // Si hay una mezcla de AutoMix en marcha (el relevo la deja activa unos segundos mas), se espera a que acabe.
        var waited: TimeInterval = 0
        while AutoMixEngine.shared.isActive, waited < Self.maxWaitForMix {
            guard isCurrent(song.videoId, generation: generation) else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            waited += 0.5
        }
        if waited > 0 {
            PlaybackReport.record(String(format: "dj: espere %.1f s a que acabara la mezcla de AutoMix", waited))
        }
        guard canTalk(about: song.videoId, generation: generation, startPosition: startPosition) else {
            PlaybackReport.record("dj: no se presenta \(song.title) (pausa, cambio de cancion o mezcla aun en marcha)")
            return
        }

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
        guard canTalk(about: song.videoId, generation: generation, startPosition: startPosition) else {
            PlaybackReport.record("dj: no se dice (la cancion o el estado cambiaron mientras se escribia)")
            return
        }
        await speakOverMusic(line.text)
    }

    /// Dice el texto bajando la musica y la devuelve a su sitio al acabar (o si se corta).
    func speakOverMusic(_ text: String) async {
        let player = PlayerController.shared
        // Si ya se estaba bajando (otra presentacion en curso), el volumen "de verdad" es el que se guardo entonces.
        let original = duckOriginal ?? player.volumeScale
        let ducked = original * Self.duckFactor
        duckOriginal = original
        duckTarget = ducked
        DJSettings.shared.speaking = true
        defer { DJSettings.shared.speaking = false }
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

    /// Vuelve el volumen a lo que era. Si otra cosa lo ha cambiado mientras tanto (el temporizador de sueno lo va bajando), no se
    /// toca: AutoMix no usa este volumen, asi que una mezcla en marcha no impide devolverlo.
    private func restoreVolume() {
        guard let original = duckOriginal, let target = duckTarget else { return }
        duckOriginal = nil
        duckTarget = nil
        let player = PlayerController.shared
        // Cerca del volumen bajado (o de camino a el, si se corto a medias): es nuestro. Si no, es de otro y se respeta.
        let low = min(target, original) - 0.05
        let high = max(target, original) + 0.05
        guard player.volumeScale >= low, player.volumeScale <= high else { return }
        player.volumeScale = original
        player.applyPlayerVolume()
    }

    private func stopSpeaking() {
        DJSpeech.shared.stop()
        restoreVolume()
        DJSettings.shared.speaking = false
    }

    // MARK: - Pantalla de pruebas

    /// Escribe y dice la presentacion de la cancion que suena (o de una de ejemplo), y devuelve lo que ha pasado.
    func test() async -> String {
        let np = NowPlaying.shared
        var context = DJWriter.Context(title: "Bohemian Rhapsody", artist: "Queen", album: "A Night at the Opera", year: 1975)
        var isExample = true
        if np.queueSongs.indices.contains(np.queueIndex) {
            isExample = false
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
        let origin = isExample
            ? "Ejemplo con datos inventados de prueba (no suena ninguna canción): lo que dice el modelo aquí no es real."
            : "Sobre la canción que suena ahora."
        return "\(line.text)\n\n(\(line.source.rawValue): \(line.note))\n\(origin)"
    }
}
