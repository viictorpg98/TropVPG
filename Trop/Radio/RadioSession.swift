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
    /// Para la pestaña Radio: quien habla, la seccion que esta en el aire, la frecuencia del dial y cuando toca la siguiente seccion.
    private(set) var speakingHost: String?
    /// Lo que dice ahora el que habla (subtitulos de la pestaña Radio); vacio si nadie habla.
    private(set) var speakingText = ""
    /// Lo ultimo que se dijo y quien lo dijo: la tarjeta de subtitulos lo deja (atenuado) hasta que vuelven a hablar.
    private(set) var lastText = ""
    private(set) var lastHost: String?
    private(set) var airingSection: RadioSectionKind?
    private(set) var frequency = 98.7
    private(set) var commentsUntilSection = 4
    private(set) var nextSectionKind = RadioSectionKind.noticiero

    private struct ReadyPiece {
        let kind: RadioPieceKind
        let clip: RadioClip
        let entry: RadioClip?
        let outro: RadioClip?
        let section: RadioSectionAssets?
        let turns: [RadioTurn]
        /// El golpe musical de Lyria que suena bajo el grito de entrada de una charla.
        var golpe: URL? = nil
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
    /// Cuanto puede durar el corte antes de que el vigilante lo de por colgado: 90 s, o mas si la seccion es larga (nota de voz, efectos).
    @ObservationIgnored private var breakLimit: TimeInterval = 90
    @ObservationIgnored private var breakTask: Task<Void, Never>?
    @ObservationIgnored private var handoverTask: Task<Void, Never>?
    /// Durante el relevo (la siguiente cancion ya entra bajo la voz): la musiquita se desvanece sola y el cambio de cancion que provoco el propio relevo no cancela el corte.
    @ObservationIgnored private var handingOver = false
    @ObservationIgnored private var handoverSongId: String?
    @ObservationIgnored private var sectionCount = 0
    @ObservationIgnored private var toppingUp = false
    @ObservationIgnored private var topUps = 0
    /// Ritmo irregular: tras cada comentario se sortea cuantos pasos de cancion faltan para el siguiente; y cada cuantos comentarios toca seccion.
    @ObservationIgnored private var nextTalkAt = 2
    @ObservationIgnored private var lastSectionTalk = 0
    @ObservationIgnored private var sectionInterval = 4
    @ObservationIgnored private var lastTalkWasCharla = false
    /// Cuantos comentarios seguidos (de paso en paso) llevan sorteados.
    @ObservationIgnored private var shortStreak = 0
    /// Las secciones salen en orden barajado (todas antes de repetir ninguna).
    @ObservationIgnored private var sectionQueue: [RadioSectionKind] = []

    private init() {}

    /// Cuantos pasos de cancion hasta el proximo comentario, segun el ajuste "Cada N" y la regularidad: exacta (siempre N), natural (N-1, N o N+1, casi siempre N)
    /// o imprevisible (de 1 a 2N-1). Nunca mas del doble de N, y con N de 2 o mas, nunca tres comentarios seguidos. Con "Cada cancion" solo puede saltarse alguna.
    private func randomGap() -> Int {
        let base = RadioSettings.talkEvery
        var gap = base
        switch RadioSettings.rhythm {
        case 1:
            gap = (base == 1 ? [1, 1, 1, 1, 2] : [base - 1, base, base, base + 1]).randomElement() ?? base
        case 2:
            gap = base == 1 ? ([1, 1, 2].randomElement() ?? 1) : Int.random(in: 1...(2 * base - 1))
        default:
            break
        }
        gap = min(max(gap, 1), 2 * base)
        if base >= 2, gap == 1, shortStreak >= 2 { gap = 2 }
        shortStreak = gap == 1 ? shortStreak + 1 : 0
        return gap
    }

    /// Saca la siguiente seccion del mazo barajado (si se acaba, se baraja otra vez evitando repetir la ultima).
    private func refillSections(avoiding last: RadioSectionKind? = nil) {
        guard sectionQueue.isEmpty else { return }
        var deck = RadioSettings.enabledSections.shuffled()
        if let last, deck.first == last, deck.count > 1 { deck.append(deck.removeFirst()) }
        sectionQueue = deck
    }

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
        frequency = Self.frequency(for: spoken)
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
    private func playClipDucked(_ clip: RadioClip, turns: [RadioTurn]? = nil, golpe: URL? = nil) async -> Bool {
        let map = RadioAudio.activity(of: clip.wav)
        followerTask?.cancel()
        // Con golpe musical (la entrada de una charla): suena junto al grito, baja mientras se habla y sube en las pausas, como la musica de una radio.
        if let golpe { bedPlayer.start(url: golpe, volume: 0.5) }
        let follower = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let index = Int(self.player.currentTime / RadioAudio.activityWindow)
                let talking = map.indices.contains(index) ? map[index] : true
                let target = talking ? self.duckLevel : self.pauseLevel
                let controller = PlayerController.shared
                controller.volumeScale += (target - controller.volumeScale) * 0.3
                controller.applyPlayerVolume()
                if golpe != nil {
                    let wanted: Float = talking ? 0.12 : 0.5
                    self.bedPlayer.volume += (wanted - self.bedPlayer.volume) * 0.25
                }
                if let turns { self.updateHost(turns: turns, seconds: clip.seconds) }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        followerTask = follower
        let finished = await playClip(clip)
        follower.cancel()
        if golpe != nil {
            // El golpe se apaga con un fundido corto cuando acaba el grito.
            bedPlayer.fade(to: 0, over: 0.6)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                if self?.breakActive == false { self?.bedPlayer.stop() }
            }
        }
        if turns != nil { setHost(nil) }
        return finished
    }

    /// Quien habla ahora: se reparte la duracion del audio entre los turnos segun lo que dice cada uno.
    private func updateHost(turns: [RadioTurn], seconds: Double) {
        guard seconds > 0, !turns.isEmpty else { return }
        let fraction = min(max(player.currentTime / seconds, 0), 0.999)
        let total = Double(turns.reduce(0) { $0 + max(1, $1.text.count) })
        var accumulated = 0.0
        var host: String?
        var line = ""
        for turn in turns {
            accumulated += Double(max(1, turn.text.count)) / total
            if fraction < accumulated {
                host = turn.speaker
                line = turn.text
                break
            }
        }
        if host == nil {
            host = turns.last?.speaker
            line = turns.last?.text ?? ""
        }
        // La risa va como etiqueta en el texto: en pantalla no se enseña.
        let shown = line.replacingOccurrences(of: "<laugh>", with: "").trimmingCharacters(in: .whitespaces)
        if speakingText != shown { speakingText = shown }
        if !shown.isEmpty, lastText != shown {
            lastText = shown
            lastHost = host
        }
        setHost(host)
    }

    private func setHost(_ host: String?) {
        if host == nil, !speakingText.isEmpty { speakingText = "" }
        if speakingHost != host { speakingHost = host }
    }

    /// La frecuencia del dial (88,1 a 107,9) sale de lo que pides, asi que cada peticion cae en un punto distinto.
    private static func frequency(for text: String) -> Double {
        let sum = text.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 1_000 }
        return 88.1 + Double(sum % 199) / 10.0
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
        lastText = ""
        lastHost = nil
        transitionCount = 0
        talkCount = 0
        topUps = 0
        toppingUp = false
        matchedOnce = false
        activatedAt = Date()
        lastSectionTalk = 0
        sectionInterval = Int.random(in: 3...4)
        lastTalkWasCharla = false
        shortStreak = 0
        // El primer comentario nunca tarda mas de lo que pides (el sorteo solo reparte los siguientes).
        nextTalkAt = min(randomGap(), RadioSettings.talkEvery)
        commentsUntilSection = sectionInterval
        sectionQueue = []
        refillSections()
        nextSectionKind = sectionQueue.first ?? .noticiero
        // Se calientan los datos del mundo (sin Gemini) para que el tiempo en directo ya este cuando toque un comentario.
        Task { _ = await RadioWorld.snapshot() }
        isActive = true
        WidgetDataStore.shared.radioChanged(true)
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
        WidgetDataStore.shared.radioChanged(false)
        loop?.cancel()
        loop = nil
        currentSummary = ""
        speakingHost = nil
        speakingText = ""
        lastText = ""
        lastHost = nil
        airingSection = nil
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
            if Date().timeIntervalSince(breakStartedAt) > breakLimit {
                report("corte: pasaron \(Int(breakLimit)) s, se reanuda la musica")
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
                if np.currentTime >= 8 { generateSection(key: key, next: next) }
                return
            }
            let clock = PlayerController.shared
            let total = clock.duration > 0 ? clock.duration : np.duration
            guard let piece = ready[key], !played.contains(key), total > 0 else { return }
            let remaining = total - clock.currentTime
            if remaining <= 7.5 {
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

        // La voz empieza para que la mayor parte suene sobre la INTRO de la siguiente cancion (como un locutor de verdad, que habla sobre la entrada del tema) y solo
        // el principio sobre el final de esta.
        var end = np.duration
        if let planned = AutoMixEngine.shared.plannedMixStart(for: id), planned > np.currentTime { end = planned }
        guard end > 0 else { return }
        let remaining = end - np.currentTime
        let share = voiceShareOverNext(next: next, seconds: piece.clip.seconds)
        let lead = piece.clip.seconds * (1 - share) + 0.5 + (piece.entry?.seconds ?? 0)
        if remaining <= lead {
            if remaining > lead - 4 {
                startSpeech(piece, key: key, expectingKey: RadioBlocklist.key(for: next))
            } else {
                played.insert(key)
                report("comentario descartado: llego tarde (faltaban \(Int(remaining)) s)")
            }
        }
    }

    /// Que parte de la voz suena ya sobre la siguiente cancion: si el analisis de la cancion dice cuanto dura su intro, casi toda la voz cabe encima de ella
    /// (hasta el 90 %); si no se sabe, el 60 %. Antes era un 30 %.
    private func voiceShareOverNext(next: SongItem, seconds: Double) -> Double {
        guard seconds > 0 else { return 0.6 }
        if let ms = TrackAnalysisStore.shared.structure(for: next.videoId, role: .incoming)?.introEndMs, ms >= 3_000 {
            return min(0.9, max(0.5, Double(ms) / 1_000 / seconds))
        }
        return 0.6
    }

    private func songChanged(to id: String, song: SongItem) {
        currentId = id
        RadioDiary.recordPlay(song)
        // Un corte en marcha se acaba si cambia la cancion por tu mano (o si la radio ya la dejo pausada); solo la siguiente que llega sola, mientras la
        // saliente aun se funde, se deja a `runBreak`.
        if breakActive, handingOver {
            // El primer cambio durante el relevo es el que provoca el propio relevo (aunque cambie el titulo o el id por la version de audio); otro distinto es que has saltado.
            if let own = handoverSongId, own != id { cancelBreak(resume: false) } else { handoverSongId = id }
        } else if breakActive, pausedByRadio || RadioBlocklist.key(for: song) != breakNextKey {
            cancelBreak(resume: false)
        }
        // La voz sigue si la que suena ahora es la que esperaba (se compara por titulo y artista: el id puede cambiar a la version de audio).
        if speaking, speakingToKey != RadioBlocklist.key(for: song) { cancelSpeech() }
        ready = ready.filter { $0.key.hasPrefix(id + ">") }
        transitionCount += 1
        if transitionCount >= nextTalkAt {
            talkCount += 1
            nextTalkAt = transitionCount + randomGap()
            // Una seccion cada 3 o 4 comentarios (si estan activadas); entre medias, sobre todo minis y, antes de la seccion, una charla.
            let since = talkCount - lastSectionTalk
            if since >= sectionInterval {
                lastSectionTalk = talkCount
                sectionInterval = Int.random(in: 3...4)
                if RadioSettings.sectionsEnabled, !RadioSettings.enabledSections.isEmpty {
                    plannedKind[id] = RadioPieceKind.section
                    lastTalkWasCharla = false
                } else {
                    plannedKind[id] = RadioPieceKind.charla
                    lastTalkWasCharla = true
                }
            } else {
                let wantsCharla = (since == sectionInterval - 1 || Int.random(in: 0..<4) == 0) && !lastTalkWasCharla
                plannedKind[id] = wantsCharla ? RadioPieceKind.charla : RadioPieceKind.mini
                lastTalkWasCharla = wantsCharla
            }
        }
        commentsUntilSection = plannedKind[id] == RadioPieceKind.section ? 0 : max(0, lastSectionTalk + sectionInterval - talkCount)
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
        // El comentario se escribe mientras suena la cancion anterior y se oye al final de ella: la hora que se le da es la de ENTONCES.
        let clock = PlayerController.shared
        let total = clock.duration > 0 ? clock.duration : NowPlaying.shared.duration
        let spoken = started.addingTimeInterval(max(0, total - clock.currentTime))
        Task { [weak self] in
            // La hora y el momento del dia solo se mencionan de vez en cuando (y entonces en la charla y en sus datos a la vez).
            let allowHour = RadioContent.reserveHourSlot()
            let facts = kind == .charla ? RadioDiary.factsBlock(tasteText: self?.tasteText ?? "", at: spoken, includeClock: allowHour) : ""
            // Datos reales opcionales: lo que has escuchado de la siguiente (4 de cada 10 veces) y el tiempo ya bajado (1 de cada 4).
            var extras: [String] = []
            // Lo del historial va con "La radio recuerda": con la memoria apagada no se manda ningun titulo de lo que has escuchado.
            if RadioSettings.memoryEnabled, Int.random(in: 0..<10) < 4, let line = await RadioSongFacts.line(for: next) { extras.append(line) }
            if Int.random(in: 0..<4) == 0, let weather = RadioWorld.weatherLine() { extras.append(weather) }
            // La charla vuelve con un grito NUEVO (texto y voz de cada vez) sobre un golpe musical de Lyria; se prepara a la vez que la charla.
            let identTask: Task<RadioClip?, Never>? = kind == .charla ? Task { await RadioIdent.make(.charla) } : nil
            let turns = await RadioContent.piece(kind: kind, previous: previous, next: next, facts: facts, extras: extras, spoken: spoken, allowHour: allowHour)
            var clip: RadioClip?
            if !turns.isEmpty { clip = await RadioVoice.clip(turns) }
            var entry: RadioClip?
            if clip != nil { entry = await identTask?.value }
            let golpe = entry != nil ? RadioSounds.golpe() : nil
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
            self.ready[key] = ReadyPiece(kind: kind, clip: clip, entry: entry, outro: nil, section: nil, turns: turns, golpe: golpe)
            if kind == .charla, RadioSettings.memoryEnabled {
                Task {
                    let note = await RadioContent.recallNote(for: turns)
                    RadioDiary.recordNote(note)
                }
            }
            let extraText = extras.isEmpty ? "" : "; datos: " + extras.joined(separator: " ")
            var shoutText = ""
            if kind == .charla { shoutText = entry.map { "; grito: «\($0.label)»" } ?? "; sin grito" }
            self.report("\(name) listo en \(elapsed) s (\(String(format: "%.1f", clip.seconds)) s de voz; gasto de hoy \(String(format: "%.3f", RadioSettings.spentToday)) €)\(extraText)\(shoutText)\(allowHour ? "; con hora" : ""): "
                + turns.map { turn in "\(turn.speaker)\(turn.tone.map { "[\($0)]" } ?? ""): \(turn.text)" }.joined(separator: " / "))
        }
    }

    private func startSpeech(_ piece: ReadyPiece, key: String, expectingKey: String) {
        played.insert(key)
        speaking = true
        speakingToKey = expectingKey
        report("habla (\(piece.kind == .mini ? "mini" : "charla")\(piece.entry != nil ? ", con grito" : ""))")
        speechTask = Task { [weak self] in
            guard let self else { return }
            await self.duck(to: self.duckLevel, over: 0.6)
            if !Task.isCancelled, let entry = piece.entry { _ = await self.playClipDucked(entry, golpe: piece.golpe) }
            if !Task.isCancelled, self.speaking { _ = await self.playClipDucked(piece.clip, turns: piece.turns) }
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
        // El golpe de la entrada de una charla se corta con ella (en un corte de seccion la musiquita la arranca despues).
        if !breakActive { bedPlayer.stop() }
        speaking = false
        speakingToKey = nil
        setHost(nil)
        restoreVolumeNow()
    }

    // MARK: - Secciones y cortes

    /// Prepara una seccion para el paso actual (noticiero, tiempo, anuncios o tendencias, rotando; si una no tiene datos, prueba la siguiente).
    private func generateSection(key: String, next: SongItem) {
        // Las secciones apagadas en Ajustes no salen (aunque estuvieran ya en el mazo); si no queda ninguna, este paso va sin seccion.
        let enabled = RadioSettings.enabledSections
        sectionQueue.removeAll { !enabled.contains($0) }
        refillSections()
        guard !sectionQueue.isEmpty else {
            played.insert(key)
            setHold(false)
            return
        }
        generating.insert(key)
        let started = Date()
        // El mazo barajado: la primera es la que tocaba; si no tiene datos o no sale, se prueban las demas por orden.
        let first = sectionQueue.removeFirst()
        let order = [first] + sectionQueue + enabled.filter { $0 != first && !sectionQueue.contains($0) }
        sectionCount += 1
        refillSections(avoiding: first)
        nextSectionKind = sectionQueue.first ?? first
        Task { [weak self] in
            var assets: RadioSectionAssets?
            for kind in order {
                assets = await RadioSections.make(kind: kind, next: next)
                if assets != nil { break }
            }
            if let made = assets, let self, let index = self.sectionQueue.firstIndex(of: made.kind) {
                // Salio otra distinta de la primera: ya ha salido, no vuelve a salir hasta que se baraje de nuevo.
                self.sectionQueue.remove(at: index)
                self.refillSections(avoiding: made.kind)
                self.nextSectionKind = self.sectionQueue.first ?? made.kind
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
            self.ready[key] = ReadyPiece(kind: .section, clip: assets.voice, entry: nil, outro: nil, section: assets, turns: assets.turns)
            let text = assets.turns.map { turn in "\(turn.speaker)\(turn.tone.map { "[\($0)]" } ?? ""): \(turn.text)" }.joined(separator: " / ")
            let noteText = assets.note.map { "; nota de voz de \(String(format: "%.0f", $0.seconds)) s" } ?? ""
            let noteLines = assets.noteTurns.isEmpty ? "" : " / NOTA: " + assets.noteTurns.map { "\($0.speaker): \($0.text)" }.joined(separator: " ")
            let shoutNote = assets.shout.map { "; grito: «\($0.label)»" } ?? "; sin grito"
            self.report("\(assets.kind.title) lista en \(elapsed) s (\(String(format: "%.1f", assets.voice.seconds)) s de voz\(noteText)\(shoutNote); gasto de hoy \(String(format: "%.3f", RadioSettings.spentToday)) €): " + text + noteLines)
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
        handoverTask = nil
        handingOver = false
        handoverSongId = nil
        breakStartedAt = Date()
        let contentSeconds = section.voice.seconds + (section.note?.seconds ?? 0) + (section.shout?.seconds ?? 0) + (section.outro?.seconds ?? 0)
        breakLimit = max(90, contentSeconds + 30)
        report("corte: \(section.kind.title) (\(String(format: "%.0f", section.voice.seconds)) s de voz; musiquita \(section.bed != nil ? "si" : "no"); grito \(section.shout != nil ? "si" : "no"))")
        breakTask = Task { [weak self] in
            await self?.runBreak(section)
        }
    }

    /// El corte, mezclado como lo haria AutoMix. ENTRADA: unos 7 s antes del final la cancion y la musiquita de la seccion se cruzan con curvas de potencia constante (la
    /// cancion baja y la musiquita sube desde su principio; la cancion llega a 0 justo al final, donde se pausa), y cuando la cancion ya casi no se oye entra el grito de la
    /// seccion. Despues habla la seccion con la musiquita de fondo (sube un poco en las pausas). SALIDA: unos 4 s antes de que acabe la voz, la SIGUIENTE cancion empieza
    /// bajita (entra con la misma curva) y la musiquita se desvanece por debajo, asi la ultima frase del locutor cae sobre la intro. Cuando la voz acaba, la cancion sube a su volumen.
    /// La posicion se mira cada 50 ms.
    private func runBreak(_ section: RadioSectionAssets) async {
        let np = NowPlaying.shared
        let controller = PlayerController.shared
        airingSection = section.kind
        // 1) Fundido cruzado: la musiquita entra desde su principio mientras la cancion baja hasta apagarse justo en su final.
        let total0 = controller.duration > 0 ? controller.duration : np.duration
        let cross = min(7.0, max(2.5, total0 - controller.currentTime - 0.35))
        if let url = section.bed { bedPlayer.start(url: url, volume: 0) }
        let started = Date()
        while !Task.isCancelled {
            guard let current = np.videoId else { break }
            if current != breakOutId {
                // La siguiente ya empezo sola: se pausa esa y, al terminar, se vuelve a empezar desde el principio. Si aun esta cargando, se espera (hasta
                // 3 s, con la musica a 0): pausar antes de que suene no hace nada y luego arrancaria sola.
                controller.volumeScale = 0
                controller.applyPlayerVolume()
                bedPlayer.volume = 0.8
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
            let progress = min(1, Date().timeIntervalSince(started) / cross)
            controller.volumeScale = cbrt(max(0, cos(progress * .pi / 2)))  // mpv aplica el volumen al CUBO: asi la ganancia real sigue el coseno
            controller.applyPlayerVolume()
            bedPlayer.volume = Float(sin(progress * .pi / 2)) * 0.9
            let total = controller.duration > 0 ? controller.duration : np.duration
            if progress >= 1 || total - controller.currentTime <= 0.3 {
                controller.setPaused(true)
                pausedByRadio = true
                breakPausedId = np.videoId
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // El grito (nuevo cada vez) entra cuando la cancion ya se ha apagado, con la musiquita arriba; en cuanto habla, la musiquita baja bajo la voz.
        if !Task.isCancelled, let shout = section.shout { _ = await playClipOverBed(shout) }
        guard !Task.isCancelled else { return }

        // 2) La seccion, con la musiquita por debajo (sube un poco en las pausas entre frases).
        bedPlayer.fade(to: 0.2, over: 1.0)
        try? await Task.sleep(nanoseconds: 700_000_000)
        if !Task.isCancelled {
            if section.note == nil { scheduleHandover(clipSeconds: section.voice.seconds) }
            _ = await playClipOverBed(section.voice, turns: section.turns)
        }
        if !Task.isCancelled, let note = section.note {
            // La nota de voz del oyente (otra voz, sin locutores en pantalla); la siguiente cancion entra por debajo de ella.
            scheduleHandover(clipSeconds: note.seconds)
            _ = await playClipOverBed(note, turns: section.noteTurns)
        }
        guard !Task.isCancelled else { return }

        // 3) La siguiente cancion ya viene entrando (o se arranca ahora si la voz fue muy corta); se espera a que termine su fundido y sube a su volumen.
        if handoverTask == nil { scheduleHandover(clipSeconds: 0) }
        await handoverTask?.value
        guard !Task.isCancelled else { return }
        breakActive = false
        breakTask = nil
        airingSection = nil
        handoverTask = nil
        await duck(to: 1, over: 1.5)
        report("corte terminado: sigue la musica")
        bedPlayer.fade(to: 0, over: 1.2)
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        bedPlayer.stop()
        handingOver = false
    }

    /// Programa la entrada de la siguiente cancion para unos 4 s antes de que acabe el audio que suena ahora (o ya, si dura menos).
    private func scheduleHandover(clipSeconds: Double) {
        handoverTask?.cancel()
        let lead = min(4.5, clipSeconds * 0.6)
        handoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, clipSeconds - lead) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.handOver()
        }
    }

    /// Arranca la siguiente cancion (o la vuelve a empezar si ya habia empezado sola) a volumen 0 y la sube con curva de potencia constante hasta el nivel
    /// de "hay voz" mientras la musiquita se apaga por debajo.
    private func handOver() async {
        handingOver = true
        let resumesCurrent = breakResumesCurrent
        report("relevo: la siguiente cancion entra bajo la voz\(resumesCurrent ? " (vuelve a empezar la que ya habia arrancado sola)" : "")")
        pausedByRadio = false
        setHold(false)
        let controller = PlayerController.shared
        controller.volumeScale = 0
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
        bedPlayer.fade(to: 0, over: 5.0)
        // El fundido de entrada cuenta desde que la cancion SUENA (cargar puede tardar un par de segundos).
        var waited = 0
        while waited < 100, !Task.isCancelled, np.loadingTrackId != nil || !np.isPlaying {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
        let steps = 60
        for step in 1...steps {
            if Task.isCancelled { return }
            controller.volumeScale = duckLevel * cbrt(sin(Double(step) / Double(steps) * .pi / 2))
            controller.applyPlayerVolume()
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func playClipOverBed(_ clip: RadioClip, turns: [RadioTurn]? = nil) async -> Bool {
        let map = RadioAudio.activity(of: clip.wav)
        followerTask?.cancel()
        let follower = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let index = Int(self.player.currentTime / RadioAudio.activityWindow)
                let talking = map.indices.contains(index) ? map[index] : true
                let target: Float = talking ? 0.13 : 0.45
                if !self.handingOver {
                    let current = self.bedPlayer.volume
                    self.bedPlayer.volume = current + (target - current) * 0.25
                }
                if let turns { self.updateHost(turns: turns, seconds: clip.seconds) }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        followerTask = follower
        let finished = await playClip(clip)
        follower.cancel()
        if turns != nil { setHost(nil) }
        return finished
    }

    /// Corta un corte (otra cancion, reproducir, 90 s, fin de la radio): para la voz y la musiquita y devuelve el volumen. Con `resume`, si la radio habia
    /// pausado la musica, sigue con la siguiente cancion (o con esta, si era la que ya habia empezado).
    private func cancelBreak(resume: Bool) {
        guard breakActive else { return }
        let paused = pausedByRadio
        let resumesCurrent = breakResumesCurrent
        breakActive = false
        pausedByRadio = false
        airingSection = nil
        setHost(nil)
        breakTask?.cancel()
        breakTask = nil
        handoverTask?.cancel()
        handoverTask = nil
        handingOver = false
        handoverSongId = nil
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
            let built = await RadioPlanner.buildQueue(recipe: recipe, familiar: familiar, exclude: exclude, anchors: false)
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
