//
//  VoiceSearch.swift
//  Trop
//
//  "¿Qué quieres escuchar?": la busqueda por voz del boton del widget "Sonar · Voz" (pensada para CarPlay, sin abrir la app).
//
//  Como se hace (segun la documentacion de Apple): el boton ejecuta `WidgetVoiceIntent`, que es `AudioRecordingIntent` (lo que permite abrir el
//  microfono desde un boton, con el indicador de grabacion) y `LiveActivityIntent` (el sistema arranca la app SIN abrirla y deja iniciar la Live
//  Activity que Apple exige mientras se graba; si no hay, la grabacion se para). Es el esquema de las apps de dictado con el boton de accion.
//  Lo que NO esta comprobado es que funcione desde un widget en CarPlay: por eso es un EXPERIMENTO y cada paso apunta en el informe una linea
//  "voz: ..." (app abierta o en segundo plano, permisos, Live Activity, sesion de audio, microfono, reconocedor, texto oido, errores con dominio
//  y codigo).
//
//  PROBLEMA CONOCIDO (informe de fallo del 20-11-2026): si el proceso lo lanza el sistema en frio para este intent y la Live Activity ya esta
//  cerrada cuando el intent termina, la app SE CUELGA por una asercion dentro de AppIntents (EXC_BREAKPOINT en AppIntents.framework, 0,16 s despues
//  de acabar `perform()`). Por eso la Live Activity ("Escuchando…" y luego "Reproduciendo…") sigue viva al terminar el intent y se cierra despues.
//  Probado tambien: encadenar un segundo intent con `opensIntent` NO lo arregla (en frio el sistema ni lo ejecuta, la app se cuelga antes).
//
//  Flujo: pausa la musica si sonaba → pregunta por voz → abre el microfono y reconoce (termina cuando callas, maximo ~9 s) → busca lo oido
//  como en el buscador (`SonarMix.playSong`: primero entre las descargadas, luego YouTube Music) → suena. Si no se oye nada o falla, lo dice
//  y reanuda lo que sonaba. El microfono se cierra siempre y la sesion de audio vuelve a la de reproduccion.
//

import ActivityKit
import AVFoundation
import Foundation
import os
import Speech
import UIKit

@MainActor
enum VoiceSearch {
    private static var running = false
    private static var runStartedAt = Date.distantPast
    private static var activity: Activity<VoiceActivityAttributes>?

    /// Se toca al arrancar la app (`WidgetDataStore.start`): da la edad del proceso para saber si un intento fue en frio.
    static let launchedAt = Date()

    /// Apple exige una Live Activity mientras se graba (si no, la grabacion se para). Se inicia justo antes de preguntar y se cierra al terminar de
    /// escuchar. Si no se puede iniciar se apunta el motivo en el informe y se sigue (para ver que hace iOS).
    private static func startActivity() {
        let info = ActivityAuthorizationInfo()
        log("Live Activity: permitidas \(info.areActivitiesEnabled)")
        guard info.areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: VoiceActivityAttributes(startedAt: Date()),
                content: ActivityContent(state: VoiceActivityAttributes.ContentState(phase: "listening"), staleDate: nil),
                pushType: nil
            )
            log("Live Activity: iniciada")
        } catch {
            log("Live Activity: ERROR \(describe(error))")
        }
    }

    private static func updateActivity(phase: String) async {
        guard let current = activity else { return }
        await current.update(ActivityContent(state: VoiceActivityAttributes.ContentState(phase: phase), staleDate: nil))
        log("Live Activity: fase \(phase)")
    }

    /// Suelta la Live Activity y la cierra pasados `seconds` s: sigue viva cuando el intent termina (ver "PROBLEMA CONOCIDO" arriba).
    private static func releaseActivity(after seconds: Int) {
        guard let kept = activity else { return }
        activity = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            await kept.end(nil, dismissalPolicy: .immediate)
            log("Live Activity: cerrada a los \(seconds) s")
        }
    }

    /// Cierra las Live Activities que quedaron colgadas (la app se cerro con "Escuchando…" o "Reproduciendo…" en pantalla). Solo las de hace mas de
    /// un minuto: si el arranque de la app coincide con una busqueda en marcha, no se toca la suya.
    static func endOrphanedActivities() async {
        for orphan in Activity<VoiceActivityAttributes>.activities where Date().timeIntervalSince(orphan.attributes.startedAt) > 60 {
            await orphan.end(nil, dismissalPolicy: .immediate)
            log("Live Activity colgada cerrada", report: false)
        }
    }

    /// Cada linea va al informe y a un fichero que se fuerza a disco al momento (`VoiceLog`): la app puede cerrarse en mitad de la escucha.
    nonisolated static func log(_ text: String, report: Bool = true) {
        VoiceLog.add(text, report: report)
    }

    /// Memoria que le queda al proceso antes de que iOS lo mate (MB). Un proceso lanzado en segundo plano tiene un limite bajo y, con el modelo de voz,
    /// el audio y el reproductor, podria rozarlo: si el numero cae a 0 justo antes de que se corten los latidos, no es el ciclo de vida del intent.
    nonisolated private static var memoryLeft: String {
        "memoria libre \(Int(os_proc_available_memory() / 1_048_576)) MB"
    }

    nonisolated private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code) \(nsError.localizedDescription)"
    }

    private static var appState: String {
        switch UIApplication.shared.applicationState {
        case .active: return "app abierta"
        case .inactive: return "app inactiva"
        case .background: return "segundo plano"
        @unknown default: return "?"
        }
    }

    private static var spanish: Bool {
        Locale.preferredLanguages.first?.hasPrefix("es") ?? false
    }

    private static func phrase(_ es: String, _ en: String) -> String {
        spanish ? es : en
    }

    // MARK: - Permisos

    static var microphoneStatus: String {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return "concedido"
        case .denied: return "denegado"
        case .undetermined: return "sin decidir"
        @unknown default: return "?"
        }
    }

    static var speechStatus: String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return "concedido"
        case .denied: return "denegado"
        case .restricted: return "restringido"
        case .notDetermined: return "sin decidir"
        @unknown default: return "?"
        }
    }

    static var permissionsGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted && SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// Pide los dos permisos. Solo se puede con la app abierta (desde Ajustes): desde un widget en segundo plano no sale ninguna ventana.
    @discardableResult
    static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        let microphone = await AVAudioApplication.requestRecordPermission()
        log("permisos pedidos: microfono \(microphone ? "concedido" : "denegado"), voz \(speech == .authorized ? "concedido" : "no concedido (\(speechStatus))")")
        return microphone && speech == .authorized
    }

    // MARK: - Frases (con varias versiones, para que no suene siempre igual)

    private struct Variants {
        let key: String
        let es: [String]
        let en: [String]
    }

    private static let questionVariants = Variants(
        key: "question",
        es: [
            "¿Qué quieres escuchar?", "¿Qué te pongo?", "Dime, ¿qué te apetece escuchar?", "¿Qué ponemos?",
            "Te escucho. ¿Qué pongo?", "¿Qué música quieres?"
        ],
        en: [
            "What do you want to listen to?", "What can I play for you?", "Tell me, what do you feel like hearing?",
            "What shall we play?", "I'm listening. What should I play?", "What music do you want?"
        ]
    )
    private static let retryVariants = Variants(
        key: "retry",
        es: ["No te he oído. ¿Qué quieres escuchar?", "Perdona, no te he oído. ¿Qué pongo?", "¿Cómo dices? No te he oído."],
        en: ["I didn't hear you. What do you want to listen to?", "Sorry, I didn't catch that. What should I play?", "Pardon? I didn't hear you."]
    )
    private static let giveUpVariants = Variants(
        key: "giveup",
        es: ["Sigo sin oírte. Inténtalo otra vez.", "Sigue sin llegarme nada. Prueba otra vez."],
        en: ["I still can't hear you. Try again.", "I'm still not getting anything. Try again."]
    )
    private static let micFailVariants = Variants(
        key: "micfail",
        es: ["No puedo usar el micrófono desde aquí.", "El micrófono no me deja escucharte desde aquí."],
        en: ["I can't use the microphone from here.", "The microphone won't let me listen from here."]
    )
    private static let notFoundVariants = Variants(
        key: "notfound",
        es: ["No he encontrado «{q}».", "No encuentro nada de «{q}».", "Lo siento, no he encontrado «{q}»."],
        en: ["I couldn't find \"{q}\".", "I can't find anything for \"{q}\".", "Sorry, I couldn't find \"{q}\"."]
    )
    private static let songWithArtistVariants = Variants(
        key: "song-artist",
        es: [
            "Poniendo {t}, de {a}.", "Ahí va {t}, de {a}.", "Marchando {t}, de {a}.", "Te pongo {t}, de {a}.",
            "Vamos con {t}, de {a}.", "Aquí tienes {t}, de {a}."
        ],
        en: [
            "Playing {t} by {a}.", "Here goes {t} by {a}.", "Coming up, {t} by {a}.", "Putting on {t} by {a}.",
            "Let's go with {t} by {a}.", "Here you go: {t} by {a}."
        ]
    )
    private static let songOnlyVariants = Variants(
        key: "song",
        es: ["Poniendo {t}.", "Ahí va {t}.", "Marchando {t}.", "Te pongo {t}.", "Vamos con {t}."],
        en: ["Playing {t}.", "Here goes {t}.", "Coming up, {t}.", "Putting on {t}.", "Let's go with {t}."]
    )
    private static let artistVariants = Variants(
        key: "artist",
        es: ["Poniendo lo mejor de {t}.", "Te pongo a {t}.", "Ahí va {t}.", "Marchando un poco de {t}."],
        en: ["Playing the best of {t}.", "Putting on {t}.", "Here goes {t}.", "Coming up, some {t}."]
    )
    private static let albumWithArtistVariants = Variants(
        key: "album-artist",
        es: ["Poniendo el álbum {t}, de {a}.", "Ahí va el álbum {t}, de {a}.", "Marchando el álbum {t}, de {a}."],
        en: ["Playing the album {t} by {a}.", "Here goes the album {t} by {a}.", "Coming up, the album {t} by {a}."]
    )
    private static let playlistVariants = Variants(
        key: "playlist",
        es: ["Poniendo la lista {t}.", "Ahí va la lista {t}.", "Marchando la lista {t}."],
        en: ["Playing the playlist {t}.", "Here goes the playlist {t}.", "Coming up, the playlist {t}."]
    )
    private static let albumOnlyVariants = Variants(
        key: "album",
        es: ["Poniendo el álbum {t}.", "Ahí va el álbum {t}.", "Marchando el álbum {t}."],
        en: ["Playing the album {t}.", "Here goes the album {t}.", "Coming up, the album {t}."]
    )

    /// Una de las versiones, al azar y sin repetir la ultima que se dijo.
    private static func pick(_ variants: Variants) -> String {
        let options = spanish ? variants.es : variants.en
        guard options.count > 1 else { return options.first ?? "" }
        let key = "voice.variant.\(variants.key)"
        let last = UserDefaults.standard.object(forKey: key) as? Int ?? -1
        let index = options.indices.filter { $0 != last }.randomElement() ?? 0
        UserDefaults.standard.set(index, forKey: key)
        return options[index]
    }

    private static func fill(_ text: String, _ values: [String: String]) -> String {
        values.reduce(text) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }

    /// Las frases que no cambian: se dejan generadas de antemano (Ajustes > Probar la voz en la nube) para que suenen al instante.
    static var fixedPhrases: [String] {
        let all = [questionVariants, retryVariants, giveUpVariants, micFailVariants]
        return all.flatMap { spanish ? $0.es : $0.en } + [phrase("Abre Sonar y activa la voz en Ajustes.", "Open Sonar and turn on voice in Settings.")]
    }

    static var sampleSentence: String {
        phrase("Hola, soy Sonar. Poniendo Bad Bunny.", "Hi, I'm Sonar. Playing Bad Bunny.")
    }

    // MARK: - Flujo

    private enum ListenResult {
        case heard(String, [String])
        case silence
        case failed
    }

    /// Pregunta, escucha, busca lo oido y lo pone (como el buscador). `source`: nombre del intento en el registro.
    static func run(source: String) async {
        // Una busqueda "en marcha" de hace mas de 2 minutos se da por colgada (no deja las siguientes bloqueadas).
        if running, Date().timeIntervalSince(runStartedAt) < 120 {
            log("ya hay una busqueda en marcha")
            return
        }
        if running { log("la busqueda anterior llevaba mas de 2 minutos sin terminar: se descarta") }
        running = true
        runStartedAt = Date()
        defer { running = false }
        SonarMix.mirrorToVoiceLog = true
        defer { SonarMix.mirrorToVoiceLog = false }
        VoiceLog.beginAttempt(source: source)
        let runStarted = Date()
        let age = String(format: "%.0f s", Date().timeIntervalSince(launchedAt))
        log("empieza (\(source), \(appState)); proceso con \(age) de vida; microfono \(microphoneStatus), voz \(speechStatus); \(memoryLeft)")

        let speaker = Speaker()
        PlayerController.shared.assertAudioSession()
        guard permissionsGranted else {
            log("faltan permisos: no se abre el microfono")
            await speaker.speak(phrase("Abre Sonar y activa la voz en Ajustes.", "Open Sonar and turn on voice in Settings."))
            return
        }

        startActivity()
        // La Live Activity sigue viva al terminar: 40 s si suena algo (hasta que el latido confirme que el proceso aguanta), 5 s si no.
        var played = false
        defer { releaseActivity(after: played ? 40 : 5) }
        let wasPlaying = NowPlaying.shared.isPlaying
        if wasPlaying { PlayerController.shared.setPaused(true) }
        defer {
            if !played, wasPlaying { PlayerController.shared.setPaused(false) }
        }

        await speaker.speak(pick(questionVariants))
        var result = await listen()
        // Si no te oye, pregunta una vez mas antes de rendirse (con el coche en marcha no se vuelve a pulsar el boton).
        if case .silence = result {
            log("silencio: se vuelve a preguntar")
            await speaker.speak(pick(retryVariants))
            result = await listen()
        }
        // Se cierra el microfono y vuelve la sesion de reproduccion antes de buscar.
        restorePlaybackSession()
        log("tras escuchar: \(memoryLeft)")

        switch result {
        case .failed:
            await speaker.speak(pick(micFailVariants))
        case .silence:
            await speaker.speak(pick(giveUpVariants))
        case .heard(let spoken, let alternatives):
            // Todo lo que devolvio el reconocedor, para ajustar las ordenes con datos reales (con reconocimiento en el dispositivo puede traer solo una).
            let others = alternatives.filter { $0 != spoken }.prefix(4).map { "\"\($0)\"" }.joined(separator: ", ")
            log("transcripciones: \(alternatives.count) en total; mejor \"\(spoken)\"; otras [\(others)]")
            let command = VoiceCommands.detect(best: spoken, alternatives: alternatives)
            if let match = command {
                let how = match.exact ? "exacta" : "aproximada con \"\(match.source)\""
                log("orden: \(match.command), \(how)")
            } else {
                log("orden: ninguna; se busca como cancion")
            }
            // Tope de 35 s (iOS mata el intent a los ~70 s en total: informe de fallo 2026-11-21): si algo se queda esperando (la red, YouTube...), no se bloquea ni esta busqueda ni las siguientes.
            let finished = await SonarMix.withTimeout(seconds: 35) { () async -> Bool? in
                if let match = command {
                    return await handleCommand(match, spoken: spoken, wasPlaying: wasPlaying, speaker: speaker)
                }
                return await searchAndPlay(spoken, speaker: speaker)
            }
            if let finished {
                played = finished
            } else {
                log("TIEMPO AGOTADO (35 s): se abandona; lo que quedaba sigue en segundo plano")
                await speaker.speak(pick(tooSlowVariants))
            }
            if played { await updateActivity(phase: "playing") }
            log("accion: termina tras \(String(format: "%.1f", Date().timeIntervalSince(runStarted))) s; \(memoryLeft)")
            startHeartbeat()
        }
    }

    /// Buscar lo dicho como en el buscador y ponerlo. `true` si suena.
    private static func searchAndPlay(_ spoken: String, speaker: Speaker) async -> Bool {
        let query = normalized(spoken)
        log("busqueda: \"\(query)\" (oido: \"\(spoken)\")")
        guard let target = await SonarMix.resolveVoiceRequest(query) else {
            log("sin resultado")
            await speaker.speak(fill(pick(notFoundVariants), ["{q}": query]))
            return false
        }
        log("encontrado: \(target.kind) \"\(target.title)\" (\(target.songs.count) canciones, cola \(target.asQueue))")
        await speaker.speak(announcement(for: target))
        let started = await SonarMix.playVoiceTarget(target)
        log("el reproductor \(started ? "arranco" : "NO arranco")")
        return started
    }

    // MARK: - Ordenes

    private static let downloadsOKVariants = Variants(
        key: "cmd-downloads",
        es: ["Poniendo tus descargas.", "Ahí van tus descargas.", "Marchando tus descargas."],
        en: ["Playing your downloads.", "Here come your downloads.", "Coming up, your downloads."]
    )
    private static let forYouOKVariants = Variants(
        key: "cmd-foryou",
        es: ["Poniendo tu mezcla.", "Ahí va Para ti.", "Marchando tu mezcla."],
        en: ["Playing your mix.", "Here goes For You.", "Coming up, your mix."]
    )
    private static let likedOKVariants = Variants(
        key: "cmd-liked",
        es: ["Poniendo tus Me gusta.", "Ahí van tus favoritas.", "Marchando tus Me gusta."],
        en: ["Playing your liked songs.", "Here come your favourites.", "Coming up, your liked songs."]
    )
    private static let randomOKVariants = Variants(
        key: "cmd-random",
        es: ["Ahí va una sorpresa.", "Te pongo algo al azar.", "Algo al azar, marchando."],
        en: ["Here's a surprise.", "Putting on something random.", "Something random, coming up."]
    )
    private static let quickOKVariants = Variants(
        key: "cmd-quick",
        es: ["Poniendo tus selecciones rápidas.", "Ahí van tus selecciones rápidas."],
        en: ["Playing your quick picks.", "Here come your quick picks."]
    )
    private static let categoryOKVariants = Variants(
        key: "cmd-category",
        es: ["Poniendo {c}.", "Ahí va {c}.", "Marchando {c}."],
        en: ["Playing {c}.", "Here goes {c}.", "Coming up, {c}."]
    )
    private static let djOnVariants = Variants(
        key: "cmd-dj-on",
        es: ["Activando el DJ.", "DJ activado.", "Vamos con el DJ."],
        en: ["Turning the DJ on.", "DJ on.", "Let's go with the DJ."]
    )
    private static let djOffVariants = Variants(
        key: "cmd-dj-off",
        es: ["Apagando el DJ.", "DJ apagado.", "Vale, sin DJ."],
        en: ["Turning the DJ off.", "DJ off.", "Okay, no DJ."]
    )
    private static let djAlreadyOnVariants = Variants(
        key: "cmd-dj-already-on",
        es: ["El DJ ya está activado."],
        en: ["The DJ is already on."]
    )
    private static let djAlreadyOffVariants = Variants(
        key: "cmd-dj-already-off",
        es: ["El DJ ya estaba apagado."],
        en: ["The DJ was already off."]
    )
    private static let mixOKVariants = Variants(
        key: "cmd-mix",
        es: ["Mezclando.", "Mezclando ahora.", "Vamos con la mezcla."],
        en: ["Mixing.", "Mixing now.", "Let's mix."]
    )
    private static let nothingToMixVariants = Variants(
        key: "cmd-nomix",
        es: ["No hay nada que mezclar ahora."],
        en: ["There is nothing to mix right now."]
    )
    private static let nowArtistVariants = Variants(
        key: "cmd-now-artist",
        es: ["Suena {t}, de {a}.", "Esto es {t}, de {a}.", "Estás escuchando {t}, de {a}."],
        en: ["This is {t} by {a}.", "You're listening to {t} by {a}.", "Now playing {t} by {a}."]
    )
    private static let nowOnlyVariants = Variants(
        key: "cmd-now",
        es: ["Suena {t}.", "Esto es {t}.", "Estás escuchando {t}."],
        en: ["This is {t}.", "You're listening to {t}.", "Now playing {t}."]
    )
    private static let nothingPlayingVariants = Variants(
        key: "cmd-nothing",
        es: ["Ahora mismo no suena nada."],
        en: ["Nothing is playing right now."]
    )
    private static let timerSetVariants = Variants(
        key: "cmd-timer",
        es: ["Te apago la música en {d}.", "Vale, paro la música en {d}.", "Música apagada en {d}."],
        en: ["I'll stop the music in {d}.", "Okay, stopping the music in {d}.", "Music off in {d}."]
    )
    private static let timerCancelledVariants = Variants(
        key: "cmd-timer-cancel",
        es: ["Temporizador cancelado.", "Vale, sin temporizador."],
        en: ["Timer cancelled.", "Okay, no timer."]
    )
    private static let timerNoMinutesVariants = Variants(
        key: "cmd-timer-nomin",
        es: ["No he entendido cuántos minutos. Prueba, por ejemplo: apágalo en treinta minutos."],
        en: ["I didn't catch how many minutes. Try, for example: stop it in thirty minutes."]
    )
    private static let noDownloadsVariants = Variants(
        key: "cmd-nodownloads",
        es: ["No tienes canciones descargadas."],
        en: ["You have no downloaded songs."]
    )
    private static let couldNotVariants = Variants(
        key: "cmd-couldnot",
        es: ["No he podido ponerlo.", "No me ha dejado ponerlo."],
        en: ["I couldn't play it.", "I wasn't able to play it."]
    )
    private static let tooSlowVariants = Variants(
        key: "tooslow",
        es: ["Esto está tardando demasiado. Inténtalo otra vez.", "Va muy lento ahora mismo. Prueba de nuevo."],
        en: ["This is taking too long. Try again.", "It's very slow right now. Try again."]
    )
    private static let confirmNoVariants = Variants(
        key: "cmd-confirm-no",
        es: ["Vale, no hago nada.", "De acuerdo, lo dejo."],
        en: ["Okay, I won't do anything.", "Alright, never mind."]
    )
    private static let confirmUnclearVariants = Variants(
        key: "cmd-confirm-unclear",
        es: ["No te he entendido, así que no hago nada."],
        en: ["I didn't understand, so I won't do anything."]
    )

    private static let yesWords: Set<String> = [
        "si", "sii", "vale", "claro", "venga", "dale", "ok", "okay", "adelante", "correcto", "yes", "yeah", "sure", "yep"
    ]
    private static let noWords: Set<String> = ["no", "nada", "cancela", "cancelar", "nope", "stop"]

    /// Ejecuta la orden; si no salio exacta, pregunta antes. Devuelve `true` si ha quedado sonando algo.
    private static func handleCommand(_ match: VoiceCommandMatch, spoken: String, wasPlaying: Bool, speaker: Speaker) async -> Bool {
        if !match.exact, match.command.needsConfirmation {
            switch await confirm(match.command, speaker: speaker) {
            case .yes:
                break
            case .no:
                // Un "no" a "¿Pongo música de fiesta?" suele ser que querias una cancion con ese nombre: se busca como tal.
                if match.command.couldBeSongTitle { return await searchAndPlay(spoken, speaker: speaker) }
                await speaker.speak(pick(confirmNoVariants))
                return false
            case .unclear:
                await speaker.speak(pick(confirmUnclearVariants))
                return false
            }
        }
        return await execute(match.command, wasPlaying: wasPlaying, speaker: speaker)
    }

    private enum Confirmation {
        case yes, no, unclear
    }

    private static func question(for command: VoiceCommand) -> String {
        switch command {
        case .downloads: return phrase("¿Pongo tus descargas?", "Shall I play your downloads?")
        case .forYou: return phrase("¿Pongo tu mezcla Para ti?", "Shall I play your For You mix?")
        case .liked: return phrase("¿Pongo tus Me gusta?", "Shall I play your liked songs?")
        case .random: return phrase("¿Pongo algo al azar?", "Shall I play something random?")
        case .quickPicks: return phrase("¿Pongo tus selecciones rápidas?", "Shall I play your quick picks?")
        case .mix: return phrase("¿Mezclo ahora?", "Shall I mix now?")
        case .nowPlaying: return ""
        case .cancelTimer: return phrase("¿Cancelo el temporizador?", "Shall I cancel the timer?")
        case .dj(let on):
            if on == true { return phrase("¿Activo el DJ?", "Shall I turn the DJ on?") }
            if on == false { return phrase("¿Apago el DJ?", "Shall I turn the DJ off?") }
            return phrase("¿Cambio el DJ?", "Shall I toggle the DJ?")
        case .sleepTimer(let minutes):
            let duration = VoiceCommands.spokenDuration(minutes ?? 0, spanish: spanish)
            return phrase("¿Te apago la música en \(duration)?", "Shall I stop the music in \(duration)?")
        case .category(let category):
            let label = VoiceCommands.label(for: category, spanish: spanish)
            return phrase("¿Pongo \(label)?", "Shall I play \(label)?")
        }
    }

    /// Pregunta "¿Activo el DJ?" y espera un si o un no (escucha corta). Solo se usa si la orden no salio clara.
    private static func confirm(_ command: VoiceCommand, speaker: Speaker) async -> Confirmation {
        await speaker.speak(question(for: command))
        let answer = await listen(quick: true)
        restorePlaybackSession()
        guard case .heard(let said, let alternatives) = answer else {
            log("confirmacion: sin respuesta")
            return .unclear
        }
        let heard = Set(([said] + alternatives).flatMap { VoiceCommands.words($0) })
        let yes = !heard.isDisjoint(with: yesWords)
        let no = !heard.isDisjoint(with: noWords)
        let result: Confirmation = (yes && !no) ? .yes : (no ? .no : .unclear)
        log("confirmacion: \"\(said)\" -> \(result)")
        return result
    }

    /// Hace la orden. `true` si queda sonando algo nuevo; con `false`, la musica que sonaba antes se reanuda al terminar la busqueda.
    private static func execute(_ command: VoiceCommand, wasPlaying: Bool, speaker: Speaker) async -> Bool {
        func resumeMusic() {
            if wasPlaying { PlayerController.shared.setPaused(false) }
        }
        switch command {
        case .downloads:
            await speaker.speak(pick(downloadsOKVariants))
            if await SonarMix.playDownloads() { return true }
            await speaker.speak(pick(noDownloadsVariants))
            return false
        case .forYou:
            await speaker.speak(pick(forYouOKVariants))
            if await SonarMix.start() { return true }
            await speaker.speak(pick(couldNotVariants))
            return false
        case .liked:
            await speaker.speak(pick(likedOKVariants))
            if await SonarMix.playLiked() { return true }
            await speaker.speak(pick(couldNotVariants))
            return false
        case .random:
            await speaker.speak(pick(randomOKVariants))
            if await SonarMix.playRandomPick() { return true }
            await speaker.speak(pick(couldNotVariants))
            return false
        case .quickPicks:
            await speaker.speak(pick(quickOKVariants))
            if await SonarMix.playQuickPicks() { return true }
            await speaker.speak(pick(couldNotVariants))
            return false
        case .category(let category):
            let label = VoiceCommands.label(for: category, spanish: spanish)
            await speaker.speak(fill(pick(categoryOKVariants), ["{c}": label]))
            let chip = await SonarMix.withTimeout(seconds: 12) { () async -> String? in
                await SonarMix.playCategory(keywords: category.keywords)
            }
            let chipText = chip ?? "no disponible"
            log("categoria: boton del inicio: \(chipText)")
            if chip != nil { return true }
            // El inicio de YouTube Music no tiene ese boton: se busca como una cancion cualquiera, con su radio.
            if let target = await SonarMix.resolveVoiceRequest(VoiceCommands.fallbackSearch(for: category, spanish: spanish)),
               await SonarMix.playVoiceTarget(target) {
                return true
            }
            await speaker.speak(pick(couldNotVariants))
            return false
        case .dj(let on):
            let dj = DJSession.shared
            let wantOn = on ?? !dj.isActive
            if wantOn == dj.isActive {
                await speaker.speak(pick(wantOn ? djAlreadyOnVariants : djAlreadyOffVariants))
                return false
            }
            await speaker.speak(pick(wantOn ? djOnVariants : djOffVariants))
            resumeMusic()
            try? await Task.sleep(nanoseconds: 800_000_000)
            if wantOn {
                dj.start()
                let np = NowPlaying.shared
                if !(np.isPlaying && np.queueSongs.indices.contains(np.queueIndex)) {
                    if !(await SonarMix.start()) {
                        dj.stop()
                        await speaker.speak(pick(couldNotVariants))
                        return false
                    }
                }
            } else {
                dj.stop()
            }
            return true
        case .mix:
            await speaker.speak(pick(mixOKVariants))
            resumeMusic()
            try? await Task.sleep(nanoseconds: 800_000_000)
            if AutoMixEngine.shared.mixNow() { return true }
            await speaker.speak(pick(nothingToMixVariants))
            return wasPlaying
        case .nowPlaying:
            let np = NowPlaying.shared
            guard np.queueSongs.indices.contains(np.queueIndex) else {
                await speaker.speak(pick(nothingPlayingVariants))
                return false
            }
            let song = np.queueSongs[np.queueIndex]
            let title = spokenText(song.title)
            if let artist = song.artists.first?.name {
                await speaker.speak(fill(pick(nowArtistVariants), ["{t}": title, "{a}": spokenText(artist)]))
            } else {
                await speaker.speak(fill(pick(nowOnlyVariants), ["{t}": title]))
            }
            return false
        case .sleepTimer(let minutes):
            guard let minutes, minutes > 0 else {
                await speaker.speak(pick(timerNoMinutesVariants))
                return false
            }
            await speaker.speak(fill(pick(timerSetVariants), ["{d}": VoiceCommands.spokenDuration(minutes, spanish: spanish)]))
            SleepTimer.shared.start(minutes: minutes)
            resumeMusic()
            return wasPlaying
        case .cancelTimer:
            SleepTimer.shared.cancel()
            await speaker.speak(pick(timerCancelledVariants))
            return false
        }
    }

    /// Lo que se dice antes de empezar: nombre de la cancion y artista, con una de varias formas.
    private static func announcement(for target: SonarMix.VoiceTarget) -> String {
        let title = spokenText(target.title)
        let artist = target.artist.map(spokenText)
        switch target.kind {
        case .song:
            if let artist { return fill(pick(songWithArtistVariants), ["{t}": title, "{a}": artist]) }
            return fill(pick(songOnlyVariants), ["{t}": title])
        case .artist:
            return fill(pick(artistVariants), ["{t}": title])
        case .album:
            if let artist { return fill(pick(albumWithArtistVariants), ["{t}": title, "{a}": artist]) }
            return fill(pick(albumOnlyVariants), ["{t}": title])
        case .playlist:
            return fill(pick(playlistVariants), ["{t}": title])
        }
    }

    /// Lo que se lee en voz alta de un titulo: sin lo que va entre parentesis o corchetes ("(Official Video)", "[Remastered]"), sin MAYUSCULAS
    /// (la voz las deletrea) y sin pasar de ~60 caracteres.
    private static func spokenText(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // Sin simbolos ni emojis ("<3", "♥"...): la voz los lee como "menor que tres".
        text = text.replacingOccurrences(of: "<3", with: "")
            .replacingOccurrences(of: "[^\\p{L}\\p{N}\\s',.!?&:\\-]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if text.isEmpty { text = raw }
        // En MAYUSCULAS la voz lo deletrea: se pasa a minusculas, salvo las siglas cortas ("SZA", "BTS", "AG"), que se dicen letra a letra.
        if text == text.uppercased(), text.count > 3 { text = text.lowercased() }
        if text.count > 60 {
            let cut = String(text.prefix(60))
            text = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? cut
        }
        return text
    }

    /// Vuelve a la sesion de audio de reproduccion apuntando el resultado: iOS puede negar activarla desde segundo plano, y entonces la cancion
    /// "suena" para el reproductor pero no se oye.
    private static func restorePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try session.setActive(true)
            log("sesion de reproduccion: activa (\(appState))")
        } catch {
            log("sesion de reproduccion: ERROR \(describe(error)) (\(appState))")
            PlayerController.shared.assertAudioSession()
        }
    }

    /// Un latido por segundo durante 70 s tras acabar la accion (solo al fichero): la ultima linea que quede es el momento en que el proceso murio,
    /// si murio. Dice si la cancion avanza, el estado de la app y cuanto tiempo en segundo plano le queda.
    private static var heartbeatTask: Task<Void, Never>?

    private static func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor in
            for second in 1...70 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                let remaining = UIApplication.shared.backgroundTimeRemaining
                let limit = remaining > 1000 ? "sin limite" : String(format: "%.0f s", remaining)
                let session = AVAudioSession.sharedInstance()
                let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
                log("latido \(second): avanza \(PlayerController.shared.isAudioAdvancing), \(appState), segundo plano \(limit), \(memoryLeft), salida [\(outputs)]", report: false)
            }
            log("latidos: fin (el proceso siguio vivo 70 s)")
        }
    }

    /// Quita lo de "pon", "quiero escuchar", "busca"... del principio: se busca solo lo que se quiere oir.
    static func normalized(_ spoken: String) -> String {
        let fillers: Set<String> = [
            "pon", "ponme", "poner", "ponga", "pones", "reproduce", "reproducir", "busca", "buscame", "buscar", "quiero",
            "escuchar", "oir", "oír", "play", "puedes", "por", "favor", "oye", "podrias", "podrías",
            "algo", "alguno", "alguna", "algún", "algun", "unas", "unos", "una", "un", "cancion", "canción", "canciones", "tema", "temas",
            "musica", "música", "dime", "dame"
        ]
        // Solo se quitan si ya se quito algo antes (un artista puede llamarse "De La Ghetto" o "Me Gustas").
        let afterFillers: Set<String> = ["me", "de", "del"]
        var words = spoken.split(separator: " ").map(String.init)
        var removed = false
        while words.count > 1, let first = words.first?.lowercased(), fillers.contains(first) || (removed && afterFillers.contains(first)) {
            words.removeFirst()
            removed = true
        }
        // "la cancion X", "el tema de X", "la cancion que se llama X": sobran el articulo y el nombre. Con ellos la busqueda de YouTube Music se
        // desvia hacia canciones que llevan esas palabras ("la cancion luces azules" daba otra que "luces azules").
        let articles: Set<String> = ["el", "la", "los", "las", "un", "una"]
        let nouns: Set<String> = ["cancion", "canción", "canciones", "tema", "temas", "musica", "música", "disco", "album", "álbum"]
        let linkers: Set<String> = ["que", "se", "llama", "llamada", "llamado", "titulada", "titulado", "de", "del"]
        if words.count > 2, articles.contains(words[0].lowercased()), nouns.contains(words[1].lowercased()) {
            words.removeFirst(2)
            while words.count > 1, linkers.contains(words[0].lowercased()) { words.removeFirst() }
        }
        // Al final: "por favor", "gracias".
        while words.count > 1 {
            let last = words[words.count - 1].lowercased()
            if ["gracias", "porfa", "porfavor"].contains(last) {
                words.removeLast()
            } else if last == "favor", words.count > 2, words[words.count - 2].lowercased() == "por" {
                words.removeLast(2)
            } else {
                break
            }
        }
        return words.joined(separator: " ")
    }

    // MARK: - Escuchar

    /// Palabras que ayudan al reconocedor con nombres de artistas y canciones: primero los artistas (de lo que mas escuchas y de lo descargado) y
    /// luego los titulos. Apple recomienda no pasar mas de unos cientos.
    private static let commandStrings = [
        "DJ", "descargas", "mis descargas", "mezcla", "mezclar", "temporizador", "Para ti", "me gusta", "aleatorio", "selecciones rápidas",
        "qué suena", "activa el DJ", "apaga el DJ", "para dormir"
    ]

    private static func contextualStrings() async -> [String] {
        let top = (try? await DatabaseService.shared.fetchTopSongs(limit: 40)) ?? []
        let downloaded = await DownloadManager.shared.fetchAll().map { SongItem(entity: $0) }
        var artists: [String] = top.compactMap(\.artistName)
        artists += downloaded.flatMap { $0.artists.map(\.name) }
        var titles: [String] = top.map(\.title)
        titles += downloaded.map(\.title)
        var seen = Set<String>()
        var result: [String] = []
        for text in artists + titles {
            guard !text.isEmpty, seen.insert(text).inserted else { continue }
            result.append(text)
        }
        return Array(result.prefix(100))
    }

    private static func listen(quick: Bool = false) async -> ListenResult {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .defaultToSpeaker])
            try session.setActive(true)
            log("sesion de audio playAndRecord: activa")
        } catch {
            log("sesion de audio playAndRecord: ERROR \(describe(error))")
            return .failed
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Locale.preferredLanguages.first ?? "es-ES"))
            ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            log("reconocedor: no disponible")
            return .failed
        }
        log("reconocedor: \(recognizer.locale.identifier), en el dispositivo: \(recognizer.supportsOnDeviceRecognition)")

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        log("entrada de audio: \(Int(format.sampleRate)) Hz, \(format.channelCount) canales")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            log("entrada de audio invalida: no se instala el microfono")
            return .failed
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        // Respuesta corta (si/no): solo esas palabras. Si no, las ordenes, los artistas y los titulos.
        if quick {
            request.contextualStrings = ["sí", "no", "vale", "claro", "venga", "cancela", "yes", "no", "sure"]
        } else {
            let learned = await contextualStrings()
            request.contextualStrings = commandStrings + learned
        }

        let listener = Listener()
        // Estos dos cierres los llama iOS desde otros hilos (el del audio y el del reconocedor): se crean como @Sendable, sin quedar atados al hilo
        // principal de esta funcion.
        let resultHandler: @Sendable (SFSpeechRecognitionResult?, Error?) -> Void = { result, error in
            let text = result?.bestTranscription.formattedString
            let alternatives = result?.transcriptions.map(\.formattedString)
            let isFinal = result?.isFinal ?? false
            let failure = error.map { $0 as NSError }
            Task { @MainActor in listener.update(text: text, alternatives: alternatives, isFinal: isFinal, error: failure) }
        }
        let task = recognizer.recognitionTask(with: request, resultHandler: resultHandler)
        log("reconocedor: tarea creada")

        let firstBuffer = OnceFlag()
        let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            firstBuffer.once {
                VoiceLog.add("primer audio recibido: \(Int(buffer.format.sampleRate)) Hz, \(buffer.frameLength) muestras")
            }
            request.append(buffer)
        }
        // Formato `nil` = el nativo del microfono en este momento: pasar uno propio que no coincida con el del dispositivo cierra la app.
        input.installTap(onBus: 0, bufferSize: 1024, format: nil, block: tapBlock)
        log("microfono: toma instalada")
        engine.prepare()
        func stopListening() {
            input.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            request.endAudio()
            task.cancel()
        }
        do {
            try engine.start()
            log("microfono: abierto")
        } catch {
            log("microfono: ERROR \(describe(error))")
            stopListening()
            return .failed
        }

        // Termina cuando callas (1,4 s sin cambios en el texto), a los 6 s sin oir nada o a los 9 s. La respuesta corta (si/no): 1 s, 4 s y 5 s.
        let silenceGap = quick ? 1.0 : 1.4
        let noTextLimit = quick ? 4.0 : 6.0
        let maxSeconds = quick ? 5.0 : 9.0
        let started = Date()
        while true {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if listener.finished { break }
            let elapsed = Date().timeIntervalSince(started)
            let hasText = !listener.latest.isEmpty
            if hasText, Date().timeIntervalSince(listener.changedAt) > silenceGap { break }
            if !hasText, elapsed > noTextLimit { break }
            if elapsed > maxSeconds { break }
        }
        request.endAudio()
        let waitStarted = Date()
        while !listener.finished, Date().timeIntervalSince(waitStarted) < 1.5 {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        stopListening()

        if let error = listener.error {
            log("reconocimiento: error \(describe(error))")
        }
        let text = (listener.final ?? listener.latest).trimmingCharacters(in: .whitespacesAndNewlines)
        log("oido: \"\(text)\" (parcial \"\(listener.latest)\", \(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
        if text.isEmpty {
            // "No speech detected" (kAFAssistantErrorDomain 1110) es que no dijiste nada, no un fallo del microfono.
            if let error = listener.error, !(error.domain == "kAFAssistantErrorDomain" && error.code == 1110) { return .failed }
            return .silence
        }
        return .heard(text, listener.alternatives)
    }
}

/// Lo que va llegando del reconocedor (sus avisos salen en otro hilo).
@MainActor
private final class Listener {
    var latest = ""
    var final: String?
    var error: NSError?
    var finished = false
    var changedAt = Date()

    var alternatives: [String] = []

    func update(text: String?, alternatives: [String]?, isFinal: Bool, error: NSError?) {
        if let alternatives, !alternatives.isEmpty { self.alternatives = alternatives }
        if let text, text != latest {
            if latest.isEmpty { VoiceLog.add("primer texto parcial: \"\(text)\"") }
            latest = text
            changedAt = Date()
        }
        if isFinal, let text {
            final = text
            VoiceLog.add("texto final: \"\(text)\"")
        }
        if let error {
            self.error = error
            finished = true
            VoiceLog.add("aviso del reconocedor: \(error.domain) \(error.code)")
        }
        if isFinal { finished = true }
    }
}

/// Deja pasar solo la primera llamada (el aviso "primer audio recibido" se da desde el hilo del audio).
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func once(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

/// Lee una frase en voz alta (con la voz del idioma del movil) y espera a que acabe.
private final class Speaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?
    private var loggedVoice = false
    private let clip = ClipPlayer()
    private var cloudFailed = false

    /// La voz mas natural que haya instalada para el idioma del movil: Premium > Mejorada > Normal, y a igualdad la de la misma region (es-ES). Se
    /// descartan las voces de novedad. Se pueden bajar mejores en Ajustes de iOS > Accesibilidad > Contenido hablado > Voces.
    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let language = Locale.preferredLanguages.first ?? "es-ES"
        let prefix = String(language.prefix(2))
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix(prefix) && ($0.identifier.hasPrefix("com.apple.voice.") || $0.identifier.hasPrefix("com.apple.ttsbundle."))
        }
        func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
            voice.quality.rawValue * 10 + (voice.language == language ? 1 : 0)
        }
        return candidates.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: language)
    }

    func speak(_ text: String) async {
        // La voz de la nube (si esta puesta); si falla, tarda o no hay red, la del sistema.
        // Si una frase falla, en el resto de esta busqueda ya no se prueba (con mala cobertura cada intento haria esperar).
        if !cloudFailed, CloudVoice.isConfigured {
            let started = Date()
            if let audio = await CloudVoice.audio(for: text), await clip.play(audio) {
                VoiceLog.add("dicho con la voz de la nube (\(Int(Date().timeIntervalSince(started) * 1000)) ms hasta terminar)")
                return
            }
            cloudFailed = true
            VoiceLog.add("la voz de la nube no pudo: se usa la del sistema el resto de la busqueda")
        }
        let utterance = AVSpeechUtterance(string: text)
        let voice = Self.bestVoice()
        utterance.voice = voice
        if !loggedVoice {
            loggedVoice = true
            VoiceLog.add("voz de lectura: \(voice?.name ?? "la del sistema") (calidad \(voice?.quality.rawValue ?? 0))")
        }
        synthesizer.delegate = self
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
            synthesizer.speak(utterance)
            // Si no hay salida de audio y la frase nunca termina, no se queda esperando.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.finish() }
        }
    }

    private func finish() {
        continuation?.resume()
        continuation = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish()
    }
}
