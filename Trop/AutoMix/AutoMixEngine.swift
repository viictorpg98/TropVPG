//
//  AutoMixEngine.swift
//  Trop
//
//  Mezcla una cancion con la siguiente con un crossfade limpio, como LastWave: dos reproductores mpv a la vez.
//
//  Unos segundos antes del punto de mezcla se prepara un segundo mpv (`AutoMixDeck`) que carga la entrante en su punto de
//  entrada, en pausa y sin sonido. Al llegar la saliente al punto de mezcla, el segundo mpv empieza a sonar y los dos
//  suben y bajan con una curva de potencia constante (coseno / seno) y un pequeno recorte de ganancia para que no sature.
//  Al 65 % de la mezcla el segundo mpv pasa a ser el reproductor principal (la app ya ve la entrante como la actual) y el
//  que sale se atenua hasta el final y se destruye. La entrante nunca cambia de archivo ni de reproductor: no hay empalme.
//  Los puntos (cuando empezar, cuanto dura, por donde entra la nueva, sin pisar voces) los decide `TransitionPlanner`.
//  Ideas: crossfade y cambio de reproductor de LastWave (github.com/Clash-Projects/LastWave-Native, GPL-3.0) y
//  planificacion de AutoMix de SimpMusic (maxrave-dev/core, GPL-3.0); el codigo es propio.
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class AutoMixEngine {
    static let shared = AutoMixEngine()

    private enum Phase { case idle, preparing, ready, blending }

    /// Todo lo necesario para la mezcla en curso.
    private struct Current {
        let key: String
        let outId: String
        let inId: String
        let plan: TransitionPlan
        var inLoudness: Double?
    }

    private var phase = Phase.idle
    private var current: Current?
    private var planCache: (outId: String, inId: String, plan: TransitionPlan?)?
    private var timer: Timer?
    private var prepareTask: Task<Void, Never>?

    /// El segundo mpv, que carga la entrante.
    private var deck: AutoMixDeck?
    /// El mpv que sale, cuando ya ha dejado de ser el principal.
    private var fadingDeck: AutoMixDeck?
    private var swapped = false
    private var secondaryPaused = false
    private var blendStartedAt = Date()
    /// Para comprobar que el segundo mpv suena de verdad: donde estaba al empezar y si ya se comprobo.
    private var deckStartPosition: Double?
    private var healthChecked = false

    private var beatMs: Double = 500
    private var beatsPerPulse: Double = 1

    private let fastInterval: TimeInterval = 0.03
    /// Punto de la mezcla (0...1) en que la entrante pasa a ser el reproductor principal.
    private let swapAt = 0.65

    /// Cuando se pidio la ultima cancion: el analisis en streaming espera un poco para no pedir direcciones a YouTube a la
    /// vez que la reproduccion que se acaba de pedir.
    private(set) var lastSongChange = Date.distantPast

    /// Hay una mezcla preparandose, lista o sonando.
    var isActive: Bool { phase != .idle }

    private init() {}

    // MARK: - Llamada desde el temporizador de NowPlaying (cada 0,25 s)

    func tick(position: TimeInterval) {
        guard SettingsStore.shared.autoMixEnabled else {
            if phase != .idle { cancel("desactivado") }
            return
        }
        switch phase {
        case .blending, .preparing:
            return
        case .ready:
            guard let c = current, stillValid(c) else { cancel("la cola cambio"); return }
            // El arranque exacto lo hace el temporizador rapido cuando se acerca el punto de mezcla.
            if Double(c.plan.outgoingStartMs) / 1000 - position <= 2, timer == nil { startTimer() }
            return
        case .idle:
            break
        }
        guard let (outId, inId) = currentPair() else { return }

        // Siempre se pide analizar la actual y la siguiente (si ya estan hechas no cuesta nada).
        TrackAnalysisStore.shared.request(outId)
        TrackAnalysisStore.shared.request(inId)
        // Y la letra de las dos (para saber cuando cantan y que las voces no se pisen en la mezcla).
        VocalMaskStore.shared.request(outId)
        VocalMaskStore.shared.request(inId)
        guard VocalMaskStore.shared.isSettled(outId), VocalMaskStore.shared.isSettled(inId) else { return }
        guard let plan = plan(outId: outId, inId: inId) else { return }

        let lead = Double(plan.outgoingStartMs) / 1000 - position
        if lead > 22 || lead < 0.5 { return }
        AutoMixVisuals.shared.prepare(song: NowPlaying.shared.queueSongs[NowPlaying.shared.queueIndex + 1])
        prepare(outId: outId, inId: inId, plan: plan)
    }

    private func pairKey(_ outId: String, _ inId: String) -> String { "\(outId)>\(inId)" }

    /// La cancion que suena y la siguiente, si las dos estan descargadas y se puede mezclar.
    private func currentPair() -> (String, String)? {
        let np = NowPlaying.shared
        guard np.isPlaying, !np.isVideoMode, !np.isRepeatOn, !np.isBusyResolving,
              np.queueSongs.indices.contains(np.queueIndex),
              np.queueIndex + 1 < np.queueSongs.count,
              let outId = np.videoId,
              np.queueSongs[np.queueIndex].videoId == outId else { return nil }
        let inId = np.queueSongs[np.queueIndex + 1].videoId
        // Descargadas, o con Wi-Fi tambien las de streaming (el segundo mpv las lee directamente).
        guard outId != inId, AutoMixSource.isAvailable(videoId: outId), AutoMixSource.isAvailable(videoId: inId) else {
            return nil
        }
        return (outId, inId)
    }

    /// Nada ha cambiado desde que se preparo: sigue sonando la saliente y la siguiente de la cola es la entrante.
    private func stillValid(_ c: Current) -> Bool {
        let np = NowPlaying.shared
        return np.videoId == c.outId && !np.isVideoMode
            && np.queueSongs.indices.contains(np.queueIndex) && np.queueIndex + 1 < np.queueSongs.count
            && np.queueSongs[np.queueIndex + 1].videoId == c.inId
    }

    private func plan(outId: String, inId: String) -> TransitionPlan? {
        if let cached = planCache, cached.outId == outId, cached.inId == inId { return cached.plan }
        let store = TrackAnalysisStore.shared
        guard let out = store.structure(for: outId), let inc = store.structure(for: inId) else { return nil }
        let vocals = TransitionPlanner.Vocals(
            outgoing: VocalMaskStore.shared.segments(for: outId), incoming: VocalMaskStore.shared.segments(for: inId)
        )
        let result = TransitionPlanner.plan(outgoing: out, incoming: inc, vocals: vocals)
        let plan = result?.plan
        planCache = (outId, inId, plan)
        PlaybackReport.record(result.map {
            String(
                format: "automix: plan %@ -> %@: empieza en %.1f s, dura %.0f s, entra desde %.1f s (%.0f -> %.0f BPM) %@",
                outId, inId, Double($0.plan.outgoingStartMs) / 1000, Double($0.plan.durationMs) / 1000,
                Double($0.plan.incomingStartMs) / 1000, out.bpm, inc.bpm, $0.note
            )
        } ?? "automix: \(outId) -> \(inId) sin mezcla posible (se usa el paso normal)")
        return plan
    }

    // MARK: - Preparar el segundo reproductor

    private func prepare(outId: String, inId: String, plan: TransitionPlan) {
        guard phase == .idle else { return }
        let key = pairKey(outId, inId)
        phase = .preparing
        current = Current(key: key, outId: outId, inId: inId, plan: plan, inLoudness: nil)
        prepareTask?.cancel()
        prepareTask = Task { [weak self] in await self?.runPrepare(key: key) }
    }

    private func runPrepare(key: String) async {
        guard let c = current, c.key == key else { return }
        let began = Date()
        guard let source = await AutoMixSource.source(for: c.inId) else {
            fail("no hay direccion de la entrante", key)
            return
        }
        guard phase == .preparing, current?.key == key else { return }
        current?.inLoudness = source.loudnessDb
        let chain = PlayerController.shared.audioFilterChain(loudness: source.loudnessDb)
        let start = Double(c.plan.incomingStartMs) / 1000
        guard let created = await AutoMixDeck.create(
            videoId: c.inId, url: source.url.absoluteString, isLocal: source.isLocal, start: start, filterChain: chain
        ) else {
            fail("mpv no pudo crear el segundo reproductor", key)
            return
        }
        guard phase == .preparing, current?.key == key else { created.destroy(); return }
        deck = created

        var sawLoading = false
        for _ in 0..<110 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard phase == .preparing, current?.key == key, !Task.isCancelled else { return }
            let status = await created.status()
            if !status.idle { sawLoading = true }
            if sawLoading, status.idle {
                fail("la entrante no se pudo abrir", key)
                return
            }
            // Una descargada esta lista enseguida; una de streaming, cuando tiene unos segundos por delante.
            let buffered = created.isLocal || (status.cacheAhead ?? 0) >= 3
            if status.timePos != nil, (status.duration ?? 0) > 0, buffered {
                phase = .ready
                PlaybackReport.record(String(
                    format: "automix: segundo reproductor listo con %@ en %.1f s", c.inId, Date().timeIntervalSince(began)
                ))
                return
            }
        }
        fail("la entrante tardo demasiado en cargar", key)
    }

    /// No se pudo preparar: la cancion sigue como estaba y no se vuelve a intentar con esta pareja.
    private func fail(_ reason: String, _ key: String) {
        guard let c = current, c.key == key else { return }
        PlaybackReport.record("automix: \(reason), se usa el paso normal")
        planCache = (c.outId, c.inId, nil)
        AutoMixVisuals.shared.end()
        teardown()
    }

    // MARK: - Temporizador rapido

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: fastInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.step() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func step() {
        switch phase {
        case .ready: stepReady()
        case .blending: stepBlending()
        default: stopTimer()
        }
    }

    /// Esperando el punto de mezcla: cuando la saliente llega, empieza el solape.
    private func stepReady() {
        guard let c = current, stillValid(c) else { cancel("la cola cambio"); return }
        guard PlayerController.shared.rawTimePos() >= Double(c.plan.outgoingStartMs) / 1000 else { return }
        startBlend(c)
    }

    private func startBlend(_ c: Current) {
        guard let deck else { cancel("sin segundo reproductor"); return }
        // El segundo mpv puede reajustar la sesion de audio al sonar: se vuelve a dejar como la quiere la app.
        PlayerController.shared.assertAudioSession()
        deck.setVolume(0)
        deck.setPaused(false)
        deckStartPosition = nil
        healthChecked = false
        Task { [weak self, weak deck] in
            guard let deck else { return }
            let status = await deck.status()
            self?.deckStartPosition = status.timePos
        }
        phase = .blending
        swapped = false
        secondaryPaused = false
        blendStartedAt = Date()
        if let structure = TrackAnalysisStore.shared.structure(for: c.outId) {
            beatMs = structure.beatMs
            // Por encima de 140 BPM el latido seria nervioso: se hace cada dos pulsos.
            beatsPerPulse = structure.bpm > 140 ? 2 : 1
        }
        AutoMixVisuals.shared.begin()
        PlaybackReport.record(String(
            format: "automix: empieza la mezcla %@ -> %@ (%.0f s)", c.outId, c.inId, Double(c.plan.durationMs) / 1000
        ))
    }

    // MARK: - El solape

    private func stepBlending() {
        guard let c = current else { cancel("sin datos"); return }
        let controller = PlayerController.shared
        guard swapped || stillValid(c) else { cancel("la cola cambio"); return }
        let duration = Double(c.plan.durationMs) / 1000
        // Seguridad: si el reloj no avanza (por ejemplo, un fallo del reproductor), no se queda la mezcla colgada.
        if Date().timeIntervalSince(blendStartedAt) > duration * 2 + 8 { cancel("la mezcla no avanzaba"); return }

        // El reloj de la mezcla es la posicion del reproductor principal (la saliente, y tras el cambio la entrante): si se
        // pausa, la mezcla se queda quieta.
        let reference = Double(swapped ? c.plan.incomingStartMs : c.plan.outgoingStartMs) / 1000
        let progress = min(max((controller.rawTimePos() - reference) / duration, 0), 1)

        // Potencia constante: la suma de cuadrados de las ganancias es 1 en todo el solape (sin hueco en el medio), y un
        // recorte de 1/raiz(suma) evita que dos canciones fuertes sumen por encima del maximo.
        let gainOut = cos(progress * .pi / 2)
        let gainIn = sin(progress * .pi / 2)
        let sum = gainOut + gainIn
        let trim = sum <= 1 ? 1 : 1 / sum.squareRoot()
        // La propiedad `volume` de mpv aplica su cubo: se le da la raiz cubica de la ganancia que se quiere.
        let base = SettingsStore.shared.playerVolume * 100
        if swapped {
            controller.volumeScale = cbrt(gainIn * trim)
            controller.applyPlayerVolume()
            fadingDeck?.setVolume(base * cbrt(gainOut * trim))
        } else {
            controller.volumeScale = cbrt(gainOut * trim)
            controller.applyPlayerVolume()
            deck?.setVolume(base * cbrt(gainIn * trim))
        }

        // Si se pausa la reproduccion, el otro mpv tambien.
        let paused = controller.playState.value != .playing
        if paused != secondaryPaused {
            secondaryPaused = paused
            (swapped ? fadingDeck : deck)?.setPaused(paused)
        }

        let visuals = AutoMixVisuals.shared
        visuals.progress = progress
        let beats = progress * duration * 1000 / max(beatMs, 1) / beatsPerPulse
        visuals.beatPhase = beats - beats.rounded(.down)

        // Poco despues de empezar se comprueba que el segundo mpv avanza: si no suena (por ejemplo, si el sistema no deja abrir
        // otra salida de audio), se cancela la mezcla y la cancion sigue como estaba, en vez de quedarse en silencio.
        if !swapped, !healthChecked, progress >= 0.12 {
            healthChecked = true
            let startPosition = deckStartPosition
            Task { [weak self] in
                guard let self, let deck = self.deck else { return }
                let status = await deck.status()
                guard self.phase == .blending, !self.swapped, !self.secondaryPaused,
                      let startPosition, let now = status.timePos else { return }
                if now - startPosition < 0.3 { self.cancel("el segundo reproductor no suena") }
            }
        }

        if !swapped, progress >= swapAt { swapRoles(c, progress: progress) }
        if progress >= 1 { finishBlend(c) }
    }

    /// El segundo mpv pasa a ser el principal: la app ve la entrante como la actual. El que sale sigue atenuandose.
    private func swapRoles(_ c: Current, progress: Double) {
        guard let deck, let handle = deck.releaseHandle() else { cancel("sin segundo reproductor"); return }
        let controller = PlayerController.shared
        controller.currentLoudnessDb = c.inLoudness
        guard let old = controller.adoptDeck(handle, videoId: c.inId) else {
            AutoMixDeck.discard(handle)
            cancel("no se pudo cambiar de reproductor")
            return
        }
        fadingDeck = AutoMixDeck.adopting(old, videoId: c.outId)
        self.deck = nil
        swapped = true
        secondaryPaused = false
        controller.positionOverride = nil
        controller.durationOverride = nil
        let position = Double(c.plan.incomingStartMs) / 1000 + progress * Double(c.plan.durationMs) / 1000
        let ok = NowPlaying.shared.adoptGaplessIncoming(
            videoId: c.inId, position: position, artwork: AutoMixVisuals.shared.incomingImage
        )
        PlaybackReport.record(ok
            ? String(format: "automix: la entrante %@ pasa a ser el reproductor principal (%.0f %% de la mezcla)", c.inId, progress * 100)
            : "automix: no se pudo pasar a \(c.inId)")
    }

    private func finishBlend(_ c: Current) {
        PlaybackReport.record("automix: mezcla terminada, la entrante \(c.inId) suena sola")
        AutoMixVisuals.shared.progress = 1
        AutoMixVisuals.shared.end()
        teardown()
        planCache = nil
    }

    // MARK: - Limpiar y cancelar

    /// Deja todo como si no hubiera mezcla: destruye los segundos mpv y devuelve el volumen.
    private func teardown() {
        stopTimer()
        prepareTask?.cancel()
        prepareTask = nil
        deck?.destroy()
        deck = nil
        fadingDeck?.destroy()
        fadingDeck = nil
        let controller = PlayerController.shared
        if controller.volumeScale != 1 {
            controller.volumeScale = 1
            controller.applyPlayerVolume()
        }
        phase = .idle
        current = nil
        swapped = false
        secondaryPaused = false
    }

    func cancel(_ reason: String, quiet: Bool = false) {
        guard phase != .idle else { return }
        if !quiet { PlaybackReport.record("automix: cancelada (\(reason))") }
        AutoMixVisuals.shared.end()
        teardown()
        planCache = nil
    }

    /// El usuario cambia la posicion mientras hay una mezcla: se cancela y el cambio sigue su curso normal (sobre el
    /// reproductor principal, que antes del cambio de papeles es la saliente).
    func userSeek(to time: TimeInterval) -> Bool {
        guard phase != .idle else { return false }
        cancel("cambio de posicion")
        return false
    }

    /// Para cuando el usuario cambia de cancion a mano o se vacia la cola.
    func songChanged() {
        lastSongChange = Date()
        if phase != .idle { cancel("cambio de cancion", quiet: true) }
        planCache = nil
    }

    /// Ya no se usa (era el empalme de archivos de la version anterior); se deja para no tocar otros archivos.
    func gaplessReachedIncoming() {}
}
