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

    // MARK: - Flujo

    private enum ListenResult {
        case heard(String)
        case silence
        case failed
    }

    /// Pregunta, escucha, busca lo oido y lo pone (como el buscador). `source`: nombre del intento en el registro.
    static func run(source: String) async {
        guard !running else {
            log("ya hay una busqueda en marcha")
            return
        }
        running = true
        defer { running = false }
        VoiceLog.beginAttempt(source: source)
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

        await speaker.speak(phrase("¿Qué quieres escuchar?", "What do you want to listen to?"))
        var result = await listen()
        // Si no te oye, pregunta una vez mas antes de rendirse (con el coche en marcha no se vuelve a pulsar el boton).
        if case .silence = result {
            log("silencio: se vuelve a preguntar")
            await speaker.speak(phrase("No te he oído. ¿Qué quieres escuchar?", "I didn't hear you. What do you want to listen to?"))
            result = await listen()
        }
        // Se cierra el microfono y vuelve la sesion de reproduccion antes de buscar.
        restorePlaybackSession()
        log("tras escuchar: \(memoryLeft)")

        switch result {
        case .failed:
            await speaker.speak(phrase("No puedo usar el micrófono desde aquí.", "I can't use the microphone from here."))
        case .silence:
            await speaker.speak(phrase("Sigo sin oírte. Inténtalo otra vez.", "I still can't hear you. Try again."))
        case .heard(let spoken):
            let query = normalized(spoken)
            log("busqueda: \"\(query)\" (oido: \"\(spoken)\")")
            guard let target = await SonarMix.resolveVoiceRequest(query) else {
                log("sin resultado")
                await speaker.speak(phrase("No he encontrado «\(query)».", "I couldn't find \"\(query)\"."))
                break
            }
            log("encontrado: \(target.kind) \"\(target.title)\" (\(target.songs.count) canciones, cola \(target.asQueue))")
            await speaker.speak(announcement(for: target))
            let started = await SonarMix.playVoiceTarget(target)
            log("el reproductor \(started ? "arranco" : "NO arranco")")
            played = started
            if started { await updateActivity(phase: "playing") }
            log("accion: termina; \(memoryLeft)")
            startHeartbeat()
        }
    }

    /// Lo que se dice antes de empezar. Los titulos en MAYUSCULAS se pasan a minusculas: si no, la voz los deletrea.
    private static func announcement(for target: SonarMix.VoiceTarget) -> String {
        func readable(_ text: String) -> String {
            text == text.uppercased() ? text.lowercased() : text
        }
        let title = readable(target.title)
        switch target.kind {
        case .song:
            if let artist = target.artist {
                return phrase("Poniendo \(title), de \(readable(artist)).", "Playing \(title) by \(readable(artist)).")
            }
            return phrase("Poniendo \(title).", "Playing \(title).")
        case .artist:
            return phrase("Poniendo \(title).", "Playing \(title).")
        case .album:
            return phrase("Poniendo el álbum \(title).", "Playing the album \(title).")
        }
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
    private static func startHeartbeat() {
        Task { @MainActor in
            for second in 1...70 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
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
            "escuchar", "oir", "oír", "play", "puedes", "por", "favor", "oye", "podrias", "podrías"
        ]
        var words = spoken.split(separator: " ").map(String.init)
        var removed = false
        while words.count > 1, let first = words.first?.lowercased(), fillers.contains(first) || (removed && first == "me") {
            words.removeFirst()
            removed = true
        }
        return words.joined(separator: " ")
    }

    // MARK: - Escuchar

    /// Palabras que ayudan al reconocedor con nombres de artistas y canciones: primero los artistas (de lo que mas escuchas y de lo descargado) y
    /// luego los titulos. Apple recomienda no pasar mas de unos cientos.
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

    private static func listen() async -> ListenResult {
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
        request.contextualStrings = await contextualStrings()

        let listener = Listener()
        // Estos dos cierres los llama iOS desde otros hilos (el del audio y el del reconocedor): se crean como @Sendable, sin quedar atados al hilo
        // principal de esta funcion.
        let resultHandler: @Sendable (SFSpeechRecognitionResult?, Error?) -> Void = { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error.map { $0 as NSError }
            Task { @MainActor in listener.update(text: text, isFinal: isFinal, error: failure) }
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

        // Termina cuando callas (1,4 s sin cambios en el texto), a los 6 s sin oir nada o a los 9 s.
        let started = Date()
        while true {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if listener.finished { break }
            let elapsed = Date().timeIntervalSince(started)
            let hasText = !listener.latest.isEmpty
            if hasText, Date().timeIntervalSince(listener.changedAt) > 1.4 { break }
            if !hasText, elapsed > 6 { break }
            if elapsed > 9 { break }
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
        return .heard(text)
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

    func update(text: String?, isFinal: Bool, error: NSError?) {
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
