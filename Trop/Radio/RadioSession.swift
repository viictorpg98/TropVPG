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
    /// De que va lo que se pidio ("Reggaeton clasico"), para la pestaña Radio mientras esta en el aire.
    private(set) var currentSummary = ""

    private struct ReadyPiece {
        let kind: RadioPieceKind
        let clip: RadioClip
        let entry: RadioClip?
        let outro: RadioClip?
        let section: RadioSectionAssets?
    }

    /// `true` mientras hay un corte previsto (o en marcha): AutoMix no mezcla en ese paso (ver `MixTransition.mixingEnabled`).
    var holdsMix: Bool { holdsMixFlag }

    /// Cuanto queda la musica mientras hay voz (ajuste) y hacia donde sube en las pausas entre frases.
    private var duckLevel: Double { RadioSettings.duckLevel }
    private var pauseLevel: Double { min(1, max(duckLevel + 0.15, 0.85)) }

    @ObservationIgnored private var loop: Task<Void, Never>?
    private let player = RadioClipPlayer()
    private let bedPlayer = RadioBedPlayer()
    @ObservationIgnored private var radioKeys: Set<String> = []
    @ObservationIgnored private var recipe: RadioRecipe?
    @ObservationIgnored private var familiar: [SongItem] = []
    @ObservationIgnored private var tasteText = ""
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
    @ObservationIgnored private var holdsMixFlag = false
    @ObservationIgnored private var breakActive = false
    @ObservationIgnored private var pausedByRadio = false
    @ObservationIgnored private var breakResumesCurrent = false
    @ObservationIgnored private var breakOutId = ""
    @ObservationIgnored private var breakNextKey = ""
    @ObservationIgnored private var breakPausedId: String?
    @ObservationIgnored private var breakStartedAt = Date()
    @ObservationIgnored private var breakTask: Task<Void, Never>?
    @ObservationIgnored private var sectionCount = 0
    @ObservationIgnored private var toppingUp = false
    @ObservationIgnored private var topUps = 0

    private init() {}

    private func report(_ text: String) {
        PlaybackReport.record("radio: " + text)
    }

    // MARK: - Empezar

    /// El flujo completo del boton "Radio" (pregunta, escucha, receta, canciones, confirmacion, musica).
    func begin(request typed: String? = nil) async {
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
        // Con una peticion escrita (las pildoras de la pestaña Radio) no hay pregunta ni micrófono, y la musica sigue hasta que llega la nueva cola.
        let wasPlaying = NowPlaying.shared.isPlaying && typed == nil
        if wasPlaying { PlayerController.shared.setPaused(true) }
        var resume = wasPlaying
        defer { if resume { PlayerController.shared.setPaused(false) } }

        var heard: String?
        if let typed {
            heard = typed
            report("peticion repetida: \"\(typed)\"")
        } else {
            // 1) La pregunta de los locutores (guardada en el movil; la primera vez de todas se genera ahora).
            if let question = await RadioContent.question() {
                _ = await playClip(question)
            } else {
                report("sin pregunta (ni guardada ni se pudo generar)")
            }

            // 2) Escuchar lo que quieres oir.
            heard = await VoiceSearch.listenForRadio()
            guard heard != nil else {
                report("no se oyo nada")
                PlaybackNotice.shared.show(NSLocalizedString("I didn't catch that. Try the radio again.", comment: ""))
                return
            }
            report("oido: \"\(heard ?? "")\"")
        }
        guard let spoken = heard else { return }

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
        tasteText = taste.text
        RadioDiary.recordSession(request: spoken, summary: recipe.summary)
        RadioRecents.add(spoken)
        currentSummary = recipe.summary
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
        await player.play(clip.needsBoost ? RadioAudio.boosted(clip.wav) : clip.wav)
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
        currentSummary = ""
        cancelBreak(resume: true)
        cancelSpeech()
        setHold(false)
        restoreVolumeNow()
        ready = [:]
        plannedKind = [:]
        generating = []
        report("termina (\(reason))")
    }

    /// "Esto no, en la radio": la cancion no vuelve a salir en la radio y pasa a la siguiente si es la que suena.
    func notThisOne(_ song: SongItem) {
        RadioBlocklist.add(song)
        RadioDiary.recordNotThis()
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
        // Sin mezcla en el paso donde toca seccion. Solo se pide con AutoMix libre: si aun esta terminando la mezcla que trae esta cancion, apagarla
        // la cancelaria y recargaria la cancion en ese punto.
        if plannedKind[id] == RadioPieceKind.section, !holdsMixFlag, !breakActive, !AutoMixEngine.shared.isActive { setHold(true) }
        if breakActive {
            // Un corte en marcha: la cancion esta pausada por la radio. Si pasan 90 s o pulsas reproducir, se acaba y sigue la musica.
            if Date().timeIntervalSince(breakStartedAt) > 90 {
                report("corte: pasaron 90 s, se reanuda la musica")
                cancelBreak(resume: true)
            } else if pausedByRadio, np.isPlaying {
                report("corte: has pulsado reproducir, se salta la seccion")
                cancelBreak(resume: id == breakOutId)
            }
            return
        }
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

        // Una seccion: se prepara con la cancion sonando y se emite como un corte justo al final de esta (no se come ninguna cancion).
        if kind == .section {
            if ready[key] == nil, !generating.contains(key), !played.contains(key) {
                if np.currentTime >= 8 { generateSection(key: key) }
                return
            }
            let clock = PlayerController.shared
            let total = clock.duration > 0 ? clock.duration : np.duration
            guard let piece = ready[key], !played.contains(key), total > 0 else { return }
            let remaining = total - clock.currentTime
            if remaining <= 4.5 {
                startBreak(piece, key: key, outId: id, nextKey: RadioBlocklist.key(for: next))
            }
            return
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
        RadioDiary.recordPlay(song)
        // Un corte en marcha se acaba si cambia la cancion por tu mano (o si la radio ya la dejo pausada); solo la siguiente que llega sola, mientras la
        // saliente aun se funde, se deja a `runBreak`.
        if breakActive, pausedByRadio || RadioBlocklist.key(for: song) != breakNextKey { cancelBreak(resume: false) }
        // La voz sigue si la que suena ahora es la que esperaba (se compara por titulo y artista: el id puede cambiar a la version de audio).
        if speaking, speakingToKey != RadioBlocklist.key(for: song) { cancelSpeech() }
        ready = ready.filter { $0.key.hasPrefix(id + ">") }
        transitionCount += 1
        if transitionCount % RadioSettings.talkEvery == 0 {
            talkCount += 1
            // Ciclo de 4 comentarios: mini, mini, charla y una seccion (si estan activadas; si no, otra charla).
            let slot = talkCount % 4
            if slot == 0, RadioSettings.sectionsEnabled {
                plannedKind[id] = RadioPieceKind.section
            } else {
                plannedKind[id] = (slot == 3 || slot == 0) ? RadioPieceKind.charla : RadioPieceKind.mini
            }
        }
        // El bloqueo del paso anterior se quita aqui; el de este (si toca seccion) se pone en `tick` cuando AutoMix esta libre.
        setHold(false)
    }

    private func setHold(_ on: Bool) {
        guard holdsMixFlag != on else { return }
        holdsMixFlag = on
        if on { AutoMixEngine.shared.replan() }
    }

    // MARK: - Comentarios entre canciones

    private func generate(key: String, kind: RadioPieceKind, previous: SongItem, next: SongItem) {
        generating.insert(key)
        let started = Date()
        Task { [weak self] in
            let facts = kind == .charla ? RadioDiary.factsBlock(tasteText: self?.tasteText ?? "") : ""
            let turns = await RadioContent.piece(kind: kind, previous: previous, next: next, facts: facts)
            var clip: RadioClip?
            if !turns.isEmpty { clip = await RadioVoice.clip(turns) }
            var entry: RadioClip?
            if clip != nil, kind == .charla { entry = RadioSounds.cuna(entrance: true) }
            if entry == nil, clip != nil, kind == .charla { entry = await RadioContent.entryJingle() }
            let outro = (clip != nil && kind == .charla) ? RadioSounds.cuna(entrance: false) : nil
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
            self.ready[key] = ReadyPiece(kind: kind, clip: clip, entry: entry, outro: outro, section: nil)
            if kind == .charla, RadioSettings.memoryEnabled {
                Task {
                    let note = await RadioContent.recallNote(for: turns)
                    RadioDiary.recordNote(note)
                }
            }
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
            if !Task.isCancelled, self.speaking, let outro = piece.outro { _ = await self.playClipDucked(outro) }
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

    // MARK: - Secciones y cortes

    /// Prepara una seccion para el paso actual (noticiero, tiempo, anuncios o tendencias, rotando; si una no tiene datos, prueba la siguiente).
    private func generateSection(key: String) {
        generating.insert(key)
        let started = Date()
        let order = RadioSectionKind.allCases
        let first = sectionCount % order.count
        sectionCount += 1
        Task { [weak self] in
            var assets: RadioSectionAssets?
            for offset in 0..<order.count {
                assets = await RadioSections.make(kind: order[(first + offset) % order.count])
                if assets != nil { break }
            }
            guard let self else { return }
            self.generating.remove(key)
            guard self.isActive else { return }
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
            guard let assets else {
                self.report("seccion: sin datos o no salio (\(elapsed) s)")
                self.played.insert(key)
                self.setHold(false)
                return
            }
            guard key.hasPrefix((self.currentId ?? "") + ">") else {
                self.report("\(assets.kind.title): llego con la cancion ya cambiada")
                return
            }
            self.ready[key] = ReadyPiece(kind: .section, clip: assets.voice, entry: nil, outro: nil, section: assets)
            let text = assets.turns.map { "\($0.speaker): \($0.text)" }.joined(separator: " / ")
            self.report("\(assets.kind.title) lista en \(elapsed) s (\(String(format: "%.1f", assets.voice.seconds)) s de voz; gasto de hoy \(String(format: "%.3f", RadioSettings.spentToday)) €): " + text)
        }
    }

    private func startBreak(_ piece: ReadyPiece, key: String, outId: String, nextKey: String) {
        guard let section = piece.section else {
            played.insert(key)
            return
        }
        played.insert(key)
        cancelSpeech()
        breakActive = true
        pausedByRadio = false
        breakResumesCurrent = false
        breakOutId = outId
        breakNextKey = nextKey
        breakPausedId = nil
        breakStartedAt = Date()
        report("corte: \(section.kind.title) (\(String(format: "%.0f", section.voice.seconds)) s de voz; musiquita \(section.bed != nil ? "si" : "no"))")
        breakTask = Task { [weak self] in
            await self?.runBreak(section)
        }
    }

    /// El corte: la saliente se funde y se pausa justo antes del final, suena la sintonia con el grito de la seccion, habla la seccion con la musiquita de
    /// fondo, cuña de salida, y la siguiente empieza desde cero. Se mira la posicion cada 50 ms (con 1 s la cancion podria acabar sola antes de pausarla).
    private func runBreak(_ section: RadioSectionAssets) async {
        let np = NowPlaying.shared
        let controller = PlayerController.shared
        while !Task.isCancelled {
            guard let current = np.videoId else { break }
            if current != breakOutId {
                // La siguiente ya empezo sola: se pausa esa y, al terminar, se vuelve a empezar desde el principio. Si aun esta cargando, se espera (hasta
                // 3 s, con la musica a 0): pausar antes de que suene no hace nada y luego arrancaria sola.
                controller.volumeScale = 0
                controller.applyPlayerVolume()
                var waited = 0
                while waited < 60, !Task.isCancelled, np.loadingTrackId != nil || !np.isPlaying {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    waited += 1
                }
                guard !Task.isCancelled else { return }
                controller.setPaused(true)
                pausedByRadio = true
                breakPausedId = np.videoId
                breakResumesCurrent = true
                break
            }
            let total = controller.duration > 0 ? controller.duration : np.duration
            let remaining = total - controller.currentTime
            if remaining <= 3.0 {
                controller.volumeScale = min(1, max(0, (remaining - 0.35) / 2.65))
                controller.applyPlayerVolume()
            }
            if remaining <= 0.35 {
                controller.setPaused(true)
                pausedByRadio = true
                breakPausedId = np.videoId
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !Task.isCancelled else { return }

        // Sintonia a todo volumen con el grito de la seccion; luego queda de fondo.
        if let url = section.bed { bedPlayer.start(url: url, volume: 1.0) }
        try? await Task.sleep(nanoseconds: 500_000_000)
        if !Task.isCancelled, let shout = section.shout { _ = await playClip(shout) }
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard !Task.isCancelled else { return }
        bedPlayer.fade(to: 0.2, over: 1.0)
        try? await Task.sleep(nanoseconds: 900_000_000)

        // La seccion, con la musiquita por debajo (sube un poco en las pausas entre frases).
        if !Task.isCancelled { _ = await playClipOverBed(section.voice) }

        // Cuña de salida y fin de la sintonia.
        if !Task.isCancelled {
            bedPlayer.fade(to: 0.5, over: 0.3)
            if let outro = section.outro { _ = await playClip(outro) }
            bedPlayer.fade(to: 0, over: 1.0)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        bedPlayer.stop()
        guard !Task.isCancelled else { return }
        finishBreak()
    }

    private func playClipOverBed(_ clip: RadioClip) async -> Bool {
        let map = RadioAudio.activity(of: clip.wav)
        followerTask?.cancel()
        let follower = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let index = Int(self.player.currentTime / RadioAudio.activityWindow)
                let talking = map.indices.contains(index) ? map[index] : true
                let target: Float = talking ? 0.18 : 0.5
                let current = self.bedPlayer.volume
                self.bedPlayer.volume = current + (target - current) * 0.25
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        followerTask = follower
        let finished = await playClip(clip)
        follower.cancel()
        return finished
    }

    /// Fin normal del corte: el volumen vuelve a 1 ANTES de arrancar la siguiente (que empieza desde cero).
    private func finishBreak() {
        let resumesCurrent = breakResumesCurrent
        breakActive = false
        breakTask = nil
        pausedByRadio = false
        setHold(false)
        let controller = PlayerController.shared
        controller.volumeScale = 1
        controller.applyPlayerVolume()
        let np = NowPlaying.shared
        if resumesCurrent {
            controller.seek(to: 0)
            controller.setPaused(false)
        } else if np.hasNext {
            np.playNext()
        } else {
            controller.setPaused(false)
        }
        report("corte terminado: sigue la musica")
    }

    /// Corta un corte (otra cancion, reproducir, 90 s, fin de la radio): para la voz y la musiquita y devuelve el volumen. Con `resume`, si la radio habia
    /// pausado la musica, sigue con la siguiente cancion (o con esta, si era la que ya habia empezado).
    private func cancelBreak(resume: Bool) {
        guard breakActive else { return }
        let paused = pausedByRadio
        let resumesCurrent = breakResumesCurrent
        breakActive = false
        pausedByRadio = false
        breakTask?.cancel()
        breakTask = nil
        followerTask?.cancel()
        followerTask = nil
        player.stop()
        bedPlayer.stop()
        setHold(false)
        let controller = PlayerController.shared
        controller.volumeScale = 1
        controller.applyPlayerVolume()
        // Solo se reanuda si lo que suena (o esta pausado) sigue siendo lo que la radio dejo pausado: si pusiste otra musica, no se toca.
        if resume, paused, NowPlaying.shared.videoId == breakPausedId {
            if resumesCurrent {
                controller.seek(to: 0)
                controller.setPaused(false)
            } else if NowPlaying.shared.hasNext {
                NowPlaying.shared.playNext()
            } else {
                controller.setPaused(false)
            }
        }
        report("corte cancelado")
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
