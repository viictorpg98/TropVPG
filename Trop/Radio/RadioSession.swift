//
//  RadioSession.swift
//  Trop
//
//  La radio de Sónar FM. Un toque en "Radio": los locutores preguntan que quieres oir, hablas, Gemini lo convierte en una receta, la app busca las
//  canciones, los locutores confirman y empieza la musica. Mientras suena, entre canciones hay comentarios (un "mini" casi siempre y de vez en cuando
//  una charla con cuña) que se generan por adelantado (con la cancion siguiente ya conocida) y se guardan en el movil; la musica baja mientras hablan.
//
//  Nunca se bloquea nada por esperar a Gemini: si una frase no llega a tiempo, ese hueco queda solo con musica; sin clave, sin red o con el tope de
//  gasto alcanzado, la radio sigue con musica sola. Si se pone otra musica (otra cola), la radio termina sola. El volumen siempre se devuelve a su sitio.
//

import AVFoundation
import Foundation
import Observation

@Observable
@MainActor
final class RadioSession {
    static let shared = RadioSession()

    private(set) var isActive = false
    private(set) var isStarting = false

    private struct ReadyPiece {
        let kind: RadioPieceKind
        let clip: RadioClip
        let entry: RadioClip?
    }

    /// Cuanto queda la musica mientras hay voz (ajuste) y hacia donde sube en las pausas entre frases.
    private var duckLevel: Double { RadioSettings.duckLevel }
    private var pauseLevel: Double { min(1, max(duckLevel + 0.15, 0.85)) }

    @ObservationIgnored private var loop: Task<Void, Never>?
    private let player = RadioClipPlayer()
    @ObservationIgnored private var radioKeys: Set<String> = []
    @ObservationIgnored private var recipe: RadioRecipe?
    @ObservationIgnored private var familiar: [SongItem] = []
    @ObservationIgnored private var currentId: String?
    @ObservationIgnored private var activatedAt = Date()
    @ObservationIgnored private var matchedOnce = false
    @ObservationIgnored private var transitionCount = 0
    @ObservationIgnored private var talkCount = 0
    @ObservationIgnored private var plannedKind: [String: RadioPieceKind] = [:]
    @ObservationIgnored private var ready: [String: ReadyPiece] = [:]
    @ObservationIgnored private var generating: Set<String> = []
    @ObservationIgnored private var played: Set<String> = []
    @ObservationIgnored private var speaking = false
    @ObservationIgnored private var speakingToKey: String?
    @ObservationIgnored private var radioIds: Set<String> = []
    @ObservationIgnored private var pausedTicks = 0
    @ObservationIgnored private var speechTask: Task<Void, Never>?
    @ObservationIgnored private var duckTask: Task<Void, Never>?
    @ObservationIgnored private var followerTask: Task<Void, Never>?
    @ObservationIgnored private var toppingUp = false
    @ObservationIgnored private var topUps = 0

    private init() {}

    private func report(_ text: String) {
        PlaybackReport.record("radio: " + text)
    }

    // MARK: - Empezar

    /// El flujo completo del boton "Radio" (pregunta, escucha, receta, canciones, confirmacion, musica).
    func begin() async {
        guard !isStarting else { return }
        guard RadioSettings.isConfigured else {
            PlaybackNotice.shared.show(NSLocalizedString("Set up the radio in Settings > Radio first.", comment: ""))
            return
        }
        isStarting = true
        defer { isStarting = false }
        if isActive { stop(reason: "nueva peticion") }
        let startedAt = Date()
        report("empieza (gasto estimado de hoy \(String(format: "%.3f", RadioSettings.spentToday)) €)")

        PlayerController.shared.assertAudioSession()
        let wasPlaying = NowPlaying.shared.isPlaying
        if wasPlaying { PlayerController.shared.setPaused(true) }
        var resume = wasPlaying
        defer { if resume { PlayerController.shared.setPaused(false) } }

        // 1) La pregunta de los locutores (guardada en el movil; la primera vez de todas se genera ahora).
        if let question = await RadioContent.question() {
            _ = await playClip(question)
        } else {
            report("sin pregunta (ni guardada ni se pudo generar)")
        }

        // 2) Escuchar lo que quieres oir.
        guard let spoken = await VoiceSearch.listenForRadio() else {
            report("no se oyo nada")
            PlaybackNotice.shared.show(NSLocalizedString("I didn't catch that. Try the radio again.", comment: ""))
            return
        }
        report("oido: \"\(spoken)\"")

        // 3) La receta, mientras suena una frase de relleno guardada.
        let taste = await RadioPlanner.taste()
        let recipeStarted = Date()
        let recipeTask = Task { try? await RadioPlanner.recipe(for: spoken, taste: taste.text) }
        let fillerTask = Task { await self.playFiller() }
        let recipe = await SonarMix.withTimeout(seconds: 10) { () async -> RadioRecipe? in await recipeTask.value }
        guard let recipe else {
            report("receta: sin respuesta a tiempo; se pone Para ti")
            _ = await fillerTask.value
            resume = false
            _ = await SonarMix.start()
            return
        }
        let recipeMs = Int(Date().timeIntervalSince(recipeStarted) * 1000)
        let searches = recipe.searches.joined(separator: " | ")
        report("receta (\(recipeMs) ms): \(recipe.summary); confianza \(recipe.confidence); gustos \(recipe.usesTaste); busquedas [\(searches)]")

        // 4) La frase de confirmacion y la cola de canciones, a la vez (la confirmacion va en otra llamada para que sus reintentos no retrasen la musica).
        let confirmationTask = Task { await RadioPlanner.confirmationClip(spoken: spoken, recipe: recipe) }
        let queueTask = Task { await RadioPlanner.buildQueue(recipe: recipe, familiar: taste.familiar, exclude: []) }
        _ = await fillerTask.value
        let built = await SonarMix.withTimeout(seconds: 15) { () async -> (songs: [SongItem], requests: Int)? in await queueTask.value }
        guard let built, built.songs.count >= 5 else {
            report("cola: \(built?.songs.count ?? 0) canciones (peticiones a YouTube \(built?.requests ?? 0)); se pone Para ti")
            resume = false
            _ = await SonarMix.start()
            return
        }
        report("cola: \(built.songs.count) canciones, peticiones a YouTube \(built.requests)")

        // 5) La musica empieza ya (bajita) y la confirmacion suena por encima.
        let controller = PlayerController.shared
        controller.volumeScale = duckLevel
        controller.applyPlayerVolume()
        activate(songs: built.songs, recipe: recipe, familiar: taste.familiar)
        PlaybackQueue.play(built.songs, startIndex: 0, log: Log.nowPlaying, context: "radio")
        resume = false

        let confirmation = await SonarMix.withTimeout(seconds: 12) { () async -> RadioClip? in await confirmationTask.value }
        if let confirmation {
            report("confirmacion: \(String(format: "%.1f", confirmation.seconds)) s de voz")
            _ = await playClipDucked(confirmation)
        } else {
            report("sin confirmacion (no llego a tiempo o fallo)")
        }
        await duck(to: 1, over: 1.0)
        report("en marcha tras \(String(format: "%.1f", Date().timeIntervalSince(startedAt))) s en total")
    }

    private func playClip(_ clip: RadioClip) async -> Bool {
        await player.play(RadioAudio.boosted(clip.wav))
    }

    /// Reproduce un clip con la musica por debajo, como en una radio de verdad: baja mientras hay voz y sube en las pausas entre frases. Se sigue la
    /// posicion del audio contra un mapa de donde hay voz.
    private func playClipDucked(_ clip: RadioClip) async -> Bool {
        let map = RadioAudio.activity(of: clip.wav)
        followerTask?.cancel()
        let follower = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let index = Int(self.player.currentTime / RadioAudio.activityWindow)
                let talking = map.indices.contains(index) ? map[index] : true
                let target = talking ? self.duckLevel : self.pauseLevel
                let controller = PlayerController.shared
                controller.volumeScale += (target - controller.volumeScale) * 0.3
                controller.applyPlayerVolume()
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        followerTask = follower
        let finished = await playClip(clip)
        follower.cancel()
        return finished
    }

    private func playFiller() async {
        if let filler = RadioContent.cachedFiller() { _ = await playClip(filler) }
    }

    // MARK: - Sesion

    private func activate(songs: [SongItem], recipe: RadioRecipe, familiar: [SongItem]) {
        self.recipe = recipe
        self.familiar = familiar
        radioKeys = Set(songs.map { RadioBlocklist.key(for: $0) })
        radioIds = Set(songs.map(\.videoId))
        pausedTicks = 0
        ready = [:]
        generating = []
        played = []
        plannedKind = [:]
        currentId = nil
        transitionCount = 0
        talkCount = 0
        topUps = 0
        toppingUp = false
        matchedOnce = false
        activatedAt = Date()
        isActive = true
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop(reason: String = "parada") {
        guard isActive else { return }
        isActive = false
        loop?.cancel()
        loop = nil
        cancelSpeech()
        restoreVolumeNow()
        ready = [:]
        plannedKind = [:]
        generating = []
        report("termina (\(reason))")
    }

    /// "Esto no, en la radio": la cancion no vuelve a salir en la radio y pasa a la siguiente si es la que suena.
    func notThisOne(_ song: SongItem) {
        RadioBlocklist.add(song)
        report("esto no: \(song.title)")
        PlaybackNotice.shared.show(NSLocalizedString("Got it. That one won't play on the radio again.", comment: ""))
        let np = NowPlaying.shared
        guard np.queueSongs.indices.contains(np.queueIndex) else { return }
        let head = Array(np.queueSongs.prefix(np.queueIndex + 1))
        let tail = np.queueSongs.dropFirst(np.queueIndex + 1).filter { !RadioBlocklist.contains($0) }
        if head.count + tail.count != np.queueSongs.count {
            np.queueSongs = head + tail
            np.persistQueueState()
        }
        if RadioBlocklist.contains(np.queueSongs[np.queueIndex]), np.hasNext {
            np.playNext()
        }
    }

    // MARK: - Cada segundo

    private func tick() {
        guard isActive else { return }
        let np = NowPlaying.shared
        guard let id = np.videoId, np.queueSongs.indices.contains(np.queueIndex) else { return }
        let song = np.queueSongs[np.queueIndex]
        if radioKeys.contains(RadioBlocklist.key(for: song)) || radioIds.contains(id) {
            matchedOnce = true
            // Las versiones de audio cambian el titulo y el id de las canciones que vienen: se apuntan todas las de la cola para no confundirlas
            // con otra musica.
            for queued in np.queueSongs {
                radioIds.insert(queued.videoId)
                radioKeys.insert(RadioBlocklist.key(for: queued))
            }
        } else if matchedOnce || Date().timeIntervalSince(activatedAt) > 45 {
            // Suena otra cosa (otra cola): la radio termina.
            stop(reason: "has puesto otra musica")
            return
        } else {
            return
        }
        if id != currentId { songChanged(to: id, song: song) }
        // En pausa no hay voz. Al cambiar de cancion el reproductor puede pasar un instante por "no suena" mientras carga la siguiente: eso no es una
        // pausa (si lo fuera, se cortaria la voz justo en el cambio). Solo cuenta si no esta cargando y sigue asi 2 segundos seguidos.
        guard np.isPlaying || np.loadingTrackId != nil else {
            pausedTicks += 1
            if pausedTicks >= 2, speaking { cancelSpeech() }
            return
        }
        pausedTicks = 0
        topUpIfNeeded()
        guard np.queueIndex + 1 < np.queueSongs.count, let kind = plannedKind[id] else { return }
        let next = np.queueSongs[np.queueIndex + 1]
        let key = id + ">" + next.videoId

        // Si el DJ reordeno y la siguiente ya no es la que tenia el comentario, ese comentario ya no vale.
        if let stale = ready.keys.first(where: { $0.hasPrefix(id + ">") && $0 != key }) {
            ready[stale] = nil
            report("comentario descartado: cambio la cancion siguiente")
        }

        // Se pide el comentario cuando la cancion lleva un rato sonando (si la saltas enseguida, no se gasta).
        if ready[key] == nil, !generating.contains(key), !played.contains(key) {
            if np.currentTime >= 8 { generate(key: key, kind: kind, previous: song, next: next) }
            return
        }
        guard let piece = ready[key], !played.contains(key), !speaking else { return }

        // La voz empieza para que cerca del 70 % suene sobre el final de esta cancion y solo el resto sobre el principio de la siguiente.
        var end = np.duration
        if let planned = AutoMixEngine.shared.plannedMixStart(for: id), planned > np.currentTime { end = planned }
        guard end > 0 else { return }
        let remaining = end - np.currentTime
        let lead = piece.clip.seconds * 0.7 + 0.5 + (piece.entry?.seconds ?? 0)
        if remaining <= lead {
            if remaining > lead - 4 {
                startSpeech(piece, key: key, expectingKey: RadioBlocklist.key(for: next))
            } else {
                played.insert(key)
                report("comentario descartado: llego tarde (faltaban \(Int(remaining)) s)")
            }
        }
    }

    private func songChanged(to id: String, song: SongItem) {
        currentId = id
        // La voz sigue si la que suena ahora es la que esperaba (se compara por titulo y artista: el id puede cambiar a la version de audio).
        if speaking, speakingToKey != RadioBlocklist.key(for: song) { cancelSpeech() }
        ready = ready.filter { $0.key.hasPrefix(id + ">") }
        transitionCount += 1
        if transitionCount % RadioSettings.talkEvery == 0 {
            talkCount += 1
            plannedKind[id] = talkCount % 3 == 0 ? RadioPieceKind.charla : RadioPieceKind.mini
        }
    }

    // MARK: - Comentarios entre canciones

    private func generate(key: String, kind: RadioPieceKind, previous: SongItem, next: SongItem) {
        generating.insert(key)
        let started = Date()
        Task { [weak self] in
            let turns = await RadioContent.piece(kind: kind, previous: previous, next: next)
            var clip: RadioClip?
            if !turns.isEmpty { clip = await RadioVoice.clip(turns) }
            var entry: RadioClip?
            if clip != nil, kind == .charla { entry = await RadioContent.entryJingle() }
            guard let self else { return }
            self.generating.remove(key)
            guard self.isActive else { return }
            let name = kind == .mini ? "mini" : "charla"
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
            guard let clip else {
                self.report("\(name): no salio (\(elapsed) s)")
                self.played.insert(key)
                return
            }
            // Si ya se cambio de cancion, ese comentario ya no vale.
            guard key.hasPrefix((self.currentId ?? "") + ">") else {
                self.report("\(name): llego con la cancion ya cambiada")
                return
            }
            self.ready[key] = ReadyPiece(kind: kind, clip: clip, entry: entry)
            self.report("\(name) listo en \(elapsed) s (\(String(format: "%.1f", clip.seconds)) s de voz; gasto de hoy \(String(format: "%.3f", RadioSettings.spentToday)) €): " + turns.map { "\($0.speaker): \($0.text)" }.joined(separator: " / "))
        }
    }

    private func startSpeech(_ piece: ReadyPiece, key: String, expectingKey: String) {
        played.insert(key)
        speaking = true
        speakingToKey = expectingKey
        report("habla (\(piece.kind == .mini ? "mini" : "charla"))")
        speechTask = Task { [weak self] in
            guard let self else { return }
            await self.duck(to: self.duckLevel, over: 0.6)
            if !Task.isCancelled, let entry = piece.entry { _ = await self.playClipDucked(entry) }
            if !Task.isCancelled, self.speaking { _ = await self.playClipDucked(piece.clip) }
            guard !Task.isCancelled, self.speaking else { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
            await self.duck(to: 1, over: 1.0)
            self.speaking = false
            self.speakingToKey = nil
        }
    }

    /// Corta la voz que suena (otra cancion, pausa, fin de la radio) y devuelve el volumen.
    private func cancelSpeech() {
        speechTask?.cancel()
        speechTask = nil
        player.stop()
        speaking = false
        speakingToKey = nil
        restoreVolumeNow()
    }

    // MARK: - Volumen

    /// Baja o sube la musica poco a poco (con el mismo volumen interno que usa el temporizador de sueño).
    private func duck(to target: Double, over seconds: Double) async {
        duckTask?.cancel()
        let task = Task { @MainActor in
            let controller = PlayerController.shared
            let start = controller.volumeScale
            let steps = max(1, Int(seconds / 0.05))
            for index in 1...steps {
                if Task.isCancelled { return }
                controller.volumeScale = start + (target - start) * Double(index) / Double(steps)
                controller.applyPlayerVolume()
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        duckTask = task
        await task.value
    }

    private func restoreVolumeNow() {
        followerTask?.cancel()
        followerTask = nil
        duckTask?.cancel()
        duckTask = nil
        let controller = PlayerController.shared
        if controller.volumeScale != 1 {
            controller.volumeScale = 1
            controller.applyPlayerVolume()
        }
    }

    // MARK: - Mas canciones

    /// Con menos de 6 canciones por delante, se añaden mas (como mucho 3 veces por sesion).
    private func topUpIfNeeded() {
        let np = NowPlaying.shared
        guard !toppingUp, topUps < 3, let recipe else { return }
        guard np.queueSongs.count - np.queueIndex - 1 < 6 else { return }
        toppingUp = true
        topUps += 1
        let exclude = Set(np.queueSongs.map(\.videoId))
        let familiar = self.familiar
        Task { [weak self] in
            let built = await RadioPlanner.buildQueue(recipe: recipe, familiar: familiar, exclude: exclude)
            guard let self, self.isActive else { return }
            self.toppingUp = false
            guard !built.songs.isEmpty else {
                self.report("cola: no se pudieron añadir mas canciones")
                return
            }
            np.queueSongs.append(contentsOf: built.songs)
            np.persistQueueState()
            self.radioKeys.formUnion(built.songs.map { RadioBlocklist.key(for: $0) })
            self.report("cola ampliada: +\(built.songs.count) canciones (peticiones a YouTube \(built.requests))")
        }
    }
}
