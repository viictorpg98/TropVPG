//
//  AutoMixEngine.swift
//  Trop
//
//  Mezcla una cancion descargada con la siguiente como un DJ, dentro de un unico reproductor (mpv).
//
//  Unos segundos antes del punto de mezcla se prepara UN archivo con la transicion ya hecha (`MixRenderer`: el final de
//  la saliente con su paso bajo, el intercambio de graves y los volumenes, sumado al principio de la entrante). Se le
//  dice a mpv que corte la saliente en ese punto y que a continuacion reproduzca ese archivo y despues la entrante, a
//  partir de donde la deja la mezcla. mpv encadena los tres sin pausa y con un solo reloj: al no haber dos
//  reproductores que sincronizar, no puede haber doblados ni ecos.
//  Diseno y formulas adaptados de AutoMix de SimpMusic (maxrave-dev/core, GPL-3.0).
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class AutoMixEngine {
    static let shared = AutoMixEngine()

    private enum Phase { case idle, armed, mixing }

    /// Todo lo necesario para una mezcla ya preparada.
    private struct Prepared {
        let key: String
        let outId: String
        let inId: String
        let plan: TransitionPlan
        let mixURL: URL
        let outgoingURL: URL
        let incomingURL: URL
        /// Segundo de la saliente donde mpv la corta y empieza el archivo de la mezcla.
        let cutAt: Double
        /// Segundo de la entrante por donde sigue mpv cuando acaba el archivo de la mezcla (despues de la cola).
        let resumeAt: Double
        /// Segundo de la entrante donde acaba la mezcla propiamente dicha (a partir de ahi suena tal cual).
        let mixEndsAt: Double
    }

    private var phase = Phase.idle
    private var prepared: Prepared?
    private var preparingKey: String?
    private var planCache: (outId: String, inId: String, plan: TransitionPlan?)?
    private var timer: Timer?

    // Estado mientras suena la mezcla
    private var outgoingDuration: TimeInterval = 0
    private var beatMs: Double = 500
    private var beatsPerPulse: Double = 1
    /// La app ya ve la entrante como cancion actual (el relevo se hace al acabar la revelacion de la carátula).
    private var handedOver = false
    /// Lo que tardo en prepararse la ultima mezcla (para saber con cuanta antelacion pedir una mezcla a mano).
    private var lastRenderSeconds: Double = 0
    private var manualMix = false
    private var manualRetries = 0
    /// Duracion de la cancion que entra (para la barra de progreso durante la mezcla).
    private var incomingSongDuration: TimeInterval = 0
    /// A que punto de la mezcla (0...1) la app pasa a ver la entrante como actual: justo despues de la revelacion.
    private let handoverAt = 0.66

    private let fastInterval: TimeInterval = 0.03

    /// El archivo de mezcla que suena ahora como si fuera la cancion (se borra cuando deja de hacerlo).
    private var playingMix: URL?

    private init() {
        removeStaleMixFiles()
    }

    private func releasePlayingMix() {
        if let url = playingMix {
            try? FileManager.default.removeItem(at: url)
            playingMix = nil
        }
    }

    /// Restos de mezclas de otra vez (la app se cerro sonando una): al arrancar no hay ninguna en uso.
    private func removeStaleMixFiles() {
        let directory = FileManager.default.temporaryDirectory
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix("automix-") && url.pathExtension == "wav" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Llamada desde el temporizador de NowPlaying (cada 0,25 s)

    func tick(position: TimeInterval) {
        guard SettingsStore.shared.autoMixEnabled else {
            if phase != .idle { cancel("desactivado") }
            dropPrepared()
            return
        }
        guard phase == .idle else { return }
        guard let (outId, inId) = currentPair() else { dropPrepared(); return }

        // Siempre se pide analizar la actual y la siguiente (si ya estan hechas no cuesta nada).
        TrackAnalysisStore.shared.request(outId)
        TrackAnalysisStore.shared.request(inId)
        // Y la letra de las dos (para saber cuando cantan y que las voces no se pisen en la mezcla).
        VocalMaskStore.shared.request(outId)
        VocalMaskStore.shared.request(inId)
        guard VocalMaskStore.shared.isSettled(outId), VocalMaskStore.shared.isSettled(inId) else { return }
        guard let plan = plan(outId: outId, inId: inId) else { return }

        let lead = Double(plan.outgoingStartMs) / 1000 - position
        // La mezcla lleva ahora el resto entero de la entrante: preparar el archivo puede llevar unos segundos mas.
        if lead > 30 || lead < 0.8 { return }
        AutoMixVisuals.shared.prepare(song: NowPlaying.shared.queueSongs[NowPlaying.shared.queueIndex + 1])
        prepare(outId: outId, inId: inId, plan: plan)
        // Se deja detras de la cancion con tiempo de sobra antes del corte.
        if lead <= 7, prepared?.key == pairKey(outId, inId) { arm() }
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
        // Descargadas, o con Wi-Fi tambien las de streaming (FFmpeg las lee directamente).
        guard outId != inId, AutoMixSource.isAvailable(videoId: outId), AutoMixSource.isAvailable(videoId: inId) else {
            return nil
        }
        return (outId, inId)
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
                format: "automix: plan %@ -> %@: corte en %.1f s, dura %.0f s, entra desde %.1f s (%.0f -> %.0f BPM, tempo %.3f/%.3f) %@",
                outId, inId, Double($0.plan.outgoingStartMs) / 1000, Double($0.plan.durationMs) / 1000,
                Double($0.plan.incomingStartMs) / 1000, out.bpm, inc.bpm, $0.plan.outgoingSpeedRatio, $0.plan.incomingSpeedRatio,
                $0.note
            )
        } ?? "automix: \(outId) -> \(inId) sin mezcla posible (se usa el paso normal)")
        return plan
    }

    // MARK: - Preparacion del archivo de la mezcla

    private func prepare(outId: String, inId: String, plan: TransitionPlan) {
        let key = pairKey(outId, inId)
        if prepared?.key == key { return }
        guard preparingKey != key else { return }
        dropPrepared()
        preparingKey = key
        Task { [weak self] in
            defer { self?.preparingKey = nil }
            guard let outSource = await AutoMixSource.source(for: outId),
                  let inSource = await AutoMixSource.source(for: inId) else { return }
            let outURL = outSource.url
            let inURL = inSource.url
            let began = Date()
            let cutAt = Double(plan.outgoingStartMs) / 1000
            let inStart = Double(plan.incomingStartMs) / 1000
            let duration = Double(plan.durationMs) / 1000
            let outgoingRatio = plan.outgoingSpeedRatio
            let incomingRatio = plan.incomingSpeedRatio
            let rendered = await Task.detached(priority: .userInitiated) {
                MixRenderer.render(
                    outgoingURL: outURL, outgoingStart: cutAt,
                    incomingURL: inURL, incomingStart: inStart,
                    duration: duration, outgoingRatio: outgoingRatio, incomingRatio: incomingRatio
                )
            }.value
            guard let rendered else {
                PlaybackReport.record("automix: no se pudo preparar la mezcla \(outId) -> \(inId)")
                self?.planCache = (outId, inId, nil)
                return
            }
            guard let self else { try? FileManager.default.removeItem(at: rendered.url); return }
            let spent = Date().timeIntervalSince(began)
            self.lastRenderSeconds = spent
            if self.manualMix, PlayerController.shared.currentTime > cutAt - 1.0 {
                // Una mezcla pedida a mano que ya no llega a su punto de corte: se pide de nuevo con mas margen (una vez).
                try? FileManager.default.removeItem(at: rendered.url)
                self.planCache = nil
                PlaybackReport.record(String(format: "automix: la mezcla pedida a mano llego tarde (%.1f s), se repite con mas margen", spent))
                if self.manualRetries < 1 {
                    self.manualRetries += 1
                    Task {
                        // Un momento, para que se libere la preparacion actual.
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        await self.runManualMix(outId: outId, inId: inId, extraLead: spent + 3)
                    }
                } else {
                    self.abortManual("Can't mix right now.")
                }
                return
            }
            if self.prepared?.key != key, self.phase == .idle {
                self.prepared = Prepared(
                    key: key, outId: outId, inId: inId, plan: plan, mixURL: rendered.url,
                    outgoingURL: outURL, incomingURL: inURL, cutAt: cutAt,
                    resumeAt: rendered.mixEndsAt + rendered.extra, mixEndsAt: rendered.mixEndsAt
                )
                PlaybackReport.record(String(
                    format: "automix: mezcla %@ -> %@ preparada en %.1f s", outId, inId, Date().timeIntervalSince(began)
                ))
            } else {
                try? FileManager.default.removeItem(at: rendered.url)
            }
        }
    }

    private func dropPrepared() {
        guard phase == .idle else { return }
        if let prepared {
            try? FileManager.default.removeItem(at: prepared.mixURL)
            self.prepared = nil
        }
    }

    // MARK: - Dejar la mezcla detras de la cancion

    private func arm() {
        guard let p = prepared, phase == .idle else { return }
        let controller = PlayerController.shared
        guard controller.armGaplessMix(
            mixURL: p.mixURL, incomingURL: nil, incomingStart: p.resumeAt, endAt: p.cutAt, incomingId: p.inId
        ) else {
            PlaybackReport.record("automix: mpv no acepto la mezcla encadenada, se usa el paso normal")
            planCache = (p.outId, p.inId, nil)
            dropPrepared()
            return
        }
        outgoingDuration = controller.duration
        handedOver = false
        let next = NowPlaying.shared.queueIndex + 1
        incomingSongDuration = NowPlaying.shared.queueSongs.indices.contains(next)
            ? TimeInterval(NowPlaying.shared.queueSongs[next].duration) : 0
        if let structure = TrackAnalysisStore.shared.structure(for: p.outId) {
            beatMs = structure.beatMs
            // Por encima de 140 BPM el latido seria nervioso: se hace cada dos pulsos.
            beatsPerPulse = structure.bpm > 140 ? 2 : 1
        }
        phase = .armed
        startTimer()
        PlaybackReport.record(String(format: "automix: mezcla encadenada lista, corte en %.1f s", p.cutAt))
    }

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
        case .idle: stopTimer()
        case .armed: stepArmed()
        case .mixing: stepMixing()
        }
    }

    /// Esperando el corte: se comprueba que nada ha cambiado y que mpv encadena de verdad.
    private func stepArmed() {
        guard let p = prepared else { cancel("sin datos"); return }
        let np = NowPlaying.shared
        guard np.videoId == p.outId, !np.isVideoMode,
              np.queueSongs.indices.contains(np.queueIndex), np.queueIndex + 1 < np.queueSongs.count,
              np.queueSongs[np.queueIndex + 1].videoId == p.inId else {
            cancel("la cola cambio")
            return
        }
        let controller = PlayerController.shared
        if controller.gaplessStage == 2 {
            // mpv ya paso al archivo de la mezcla (el de la mezcla anterior, si lo habia, ya no se usa).
            phase = .mixing
            controller.clearTimeline()
            releasePlayingMix()
            controller.durationOverride = outgoingDuration
            AutoMixVisuals.shared.begin()
            PlaybackReport.record("automix: empieza la mezcla \(p.outId) -> \(p.inId)")
        } else if controller.gaplessStage == 1, controller.currentTime > p.cutAt + 0.8 {
            // Deberia haber cortado ya: si mpv no lo hace, se deja la cancion como estaba.
            PlaybackReport.record("automix: mpv no corto la saliente en su sitio, se cancela la mezcla")
            planCache = (p.outId, p.inId, nil)
            cancel("sin corte")
        }
    }

    /// Suena el archivo de la mezcla: la barra de progreso sigue a la saliente y las animaciones, a la mezcla.
    private func stepMixing() {
        guard let p = prepared else { cancel("sin datos"); return }
        let controller = PlayerController.shared
        guard controller.gaplessStage == 2 else { return }
        let mixPosition = controller.rawTimePos()
        let duration = Double(p.plan.durationMs) / 1000
        let visuals = AutoMixVisuals.shared
        if mixPosition < duration {
            let progress = min(max(mixPosition / duration, 0), 1)
            visuals.progress = progress
            let beats = (mixPosition * 1000) / max(beatMs, 1) / beatsPerPulse
            visuals.beatPhase = beats - beats.rounded(.down)
            // Donde va la entrante en su cancion (con sus cambios de velocidad): su barra de progreso entra con la carátula.
            let incomingPosition = Double(p.plan.incomingStartMs) / 1000
                + AutoMixMath.incomingAdvance(startRatio: p.plan.incomingSpeedRatio, duration: duration, seconds: mixPosition)
            visuals.incomingElapsed = incomingPosition
            visuals.incomingDuration = incomingSongDuration
            visuals.incomingProgress = incomingSongDuration > 0 ? min(incomingPosition / incomingSongDuration, 1) : 0
            if !handedOver, progress >= handoverAt { handOver(p, position: incomingPosition) }
            if handedOver {
                controller.positionOverride = incomingPosition
            } else {
                // La saliente avanza mas (o menos) que la mezcla porque cambia de velocidad.
                let advanced = AutoMixMath.outgoingAdvance(ratio: p.plan.outgoingSpeedRatio, duration: duration, seconds: mixPosition)
                controller.positionOverride = min(p.cutAt + advanced, max(outgoingDuration, p.cutAt))
            }
        } else {
            // La mezcla acabo: la entrante ya suena sola, desde el mismo archivo (lleva el resto de la cancion).
            if !handedOver { handOver(p, position: p.mixEndsAt) }
            completeMix(p)
        }
    }

    // MARK: - Fin de la mezcla: mpv ya suena la entrante

    /// Relevo: justo despues de revelarse la carátula, la app pasa a ver la entrante como la actual (cola, letra, mini
    /// reproductor, pantalla de bloqueo, barra...), aunque el audio aun sea la mezcla.
    private func handOver(_ p: Prepared, position: Double) {
        handedOver = true
        let controller = PlayerController.shared
        let ok = NowPlaying.shared.adoptGaplessIncoming(
            videoId: p.inId, position: position, artwork: AutoMixVisuals.shared.incomingImage
        )
        controller.currentVideoId = p.inId
        controller.pendingVideoId = nil
        controller.durationOverride = incomingSongDuration > 0 ? incomingSongDuration : nil
        // La pantalla de bloqueo no recibe "archivo cargado" de la entrante (suena desde el archivo de la mezcla): se le dice aqui.
        controller.setNowPlayingMetadata()
        controller.updateNowPlayingArtwork()
        PlaybackReport.record(ok
            ? String(format: "automix: relevo, la app pasa a ver %@ como actual (en %.0f s de su cancion)", p.inId, position)
            : "automix: no se pudo pasar a \(p.inId)")
    }

    /// La mezcla acabo: el archivo de la mezcla lleva ya el resto de la entrante y suena como si fuera su cancion. La posicion y
    /// la duracion que se ven son las de la cancion (las del archivo mas este desplazamiento).
    private func completeMix(_ p: Prepared) {
        let controller = PlayerController.shared
        let duration = Double(p.plan.durationMs) / 1000
        controller.positionOverride = nil
        controller.durationOverride = nil
        controller.timeline = (shift: p.mixEndsAt - duration, mixEnd: duration)
        playingMix = p.mixURL
        PlaybackReport.record("automix: mezcla terminada, la entrante \(p.inId) suena sola")
        AutoMixVisuals.shared.progress = 1
        AutoMixVisuals.shared.end()
        MixFeedbackStore.shared.mixFinished(outId: p.outId, inId: p.inId, plan: p.plan)
        finish(keepingMix: true)
    }

    /// Ya no se usa (era el empalme de archivos de una version anterior); se deja para no tocar otros archivos.
    func gaplessReachedIncoming() {}

    private func finish(keepingMix: Bool = false) {
        stopTimer()
        if !keepingMix, let prepared { try? FileManager.default.removeItem(at: prepared.mixURL) }
        prepared = nil
        planCache = nil
        handedOver = false
        manualMix = false
        phase = .idle
    }

    // MARK: - Cancelar

    func cancel(_ reason: String, quiet: Bool = false) {
        if !quiet { PlaybackReport.record("automix: cancelada (\(reason))") }
        let controller = PlayerController.shared
        let stage = controller.gaplessStage
        controller.disarmGaplessMix()
        // Si ya sonaba el archivo de la mezcla y la cancion sigue siendo la saliente, se vuelve a ella donde iba; si ya habia
        // relevo (la app ve la entrante como actual), se carga la entrante normal en su punto.
        if stage == 2, let p = prepared {
            if handedOver {
                let position = AutoMixVisuals.shared.incomingElapsed
                Task { _ = try? await PlaybackManager.shared.resolveAndPlay(videoId: p.inId, startAt: position) }
            } else if NowPlaying.shared.videoId == p.outId {
                let position = min(p.cutAt + controller.rawTimePos(), max(outgoingDuration, p.cutAt))
                Task { _ = try? await PlaybackManager.shared.resolveAndPlay(videoId: p.outId, startAt: position) }
            }
        }
        controller.positionOverride = nil
        controller.durationOverride = nil
        AutoMixVisuals.shared.end()
        finish()
    }

    /// El usuario cambia la posicion mientras hay una mezcla preparada o sonando. Devuelve `true` si ya se ha encargado
    /// de todo (la saliente se vuelve a cargar en esa posicion); `false` si hay que seguir con el cambio normal.
    func userSeek(to time: TimeInterval) -> Bool {
        let controller = PlayerController.shared
        guard let p = prepared else { return false }
        if controller.gaplessStage == 2, handedOver {
            // Ya se veia la entrante como actual: el cambio de posicion es en su cancion.
            PlaybackReport.record("automix: cancelada (cambio de posicion tras el relevo)")
            controller.disarmGaplessMix()
            controller.positionOverride = nil
            controller.durationOverride = nil
            AutoMixVisuals.shared.end()
            finish()
            Task { _ = try? await PlaybackManager.shared.resolveAndPlay(videoId: p.inId, startAt: time) }
            return true
        }
        if controller.gaplessStage == 2, NowPlaying.shared.videoId == p.outId {
            PlaybackReport.record("automix: cancelada (cambio de posicion durante la mezcla)")
            controller.disarmGaplessMix()
            controller.positionOverride = nil
            controller.durationOverride = nil
            AutoMixVisuals.shared.end()
            finish()
            Task { _ = try? await PlaybackManager.shared.resolveAndPlay(videoId: p.outId, startAt: time) }
            return true
        }
        // Antes del corte: se deshace lo preparado y el cambio de posicion sigue su curso normal.
        PlaybackReport.record("automix: cancelada (cambio de posicion)")
        controller.disarmGaplessMix()
        AutoMixVisuals.shared.end()
        finish()
        return false
    }

    /// El usuario pide mezclar ya: el aviso animado sale al instante y la mezcla empieza en cuanto este preparada (unos
    /// segundos: lo que tardo la ultima vez, con un margen).
    @discardableResult
    func mixNow() -> Bool {
        guard SettingsStore.shared.autoMixEnabled else { return false }
        guard phase == .idle, prepared == nil, preparingKey == nil, !AutoMixVisuals.shared.preparingManual else { return false }
        guard let (outId, inId) = currentPair() else {
            PlaybackNotice.shared.show(NSLocalizedString("Can't mix right now.", comment: ""))
            return false
        }
        AutoMixVisuals.shared.preparingManual = true
        manualRetries = 0
        Task { await runManualMix(outId: outId, inId: inId, extraLead: 0) }
        return true
    }

    private func abortManual(_ message: String? = nil) {
        AutoMixVisuals.shared.preparingManual = false
        manualMix = false
        if let message { PlaybackNotice.shared.show(NSLocalizedString(message, comment: "")) }
    }

    private func stillCurrent(_ outId: String, _ inId: String) -> Bool {
        let np = NowPlaying.shared
        return np.videoId == outId && np.queueSongs.indices.contains(np.queueIndex)
            && np.queueIndex + 1 < np.queueSongs.count && np.queueSongs[np.queueIndex + 1].videoId == inId
    }

    private func runManualMix(outId: String, inId: String, extraLead: Double) async {
        let store = TrackAnalysisStore.shared
        store.request(outId)
        store.request(inId)
        VocalMaskStore.shared.request(outId)
        VocalMaskStore.shared.request(inId)
        // Hasta unos segundos para que esten analizadas (casi siempre ya lo estan).
        var waited = 0.0
        while waited < 12 {
            if store.structure(for: outId) != nil, store.structure(for: inId) != nil,
               VocalMaskStore.shared.isSettled(outId), VocalMaskStore.shared.isSettled(inId) { break }
            try? await Task.sleep(nanoseconds: 400_000_000)
            waited += 0.4
            guard AutoMixVisuals.shared.preparingManual, stillCurrent(outId, inId) else { abortManual(); return }
        }
        guard AutoMixVisuals.shared.preparingManual, stillCurrent(outId, inId),
              phase == .idle, prepared == nil, preparingKey == nil else { abortManual(); return }
        guard let out = store.structure(for: outId), let inc = store.structure(for: inId) else {
            abortManual("Can't mix right now.")
            return
        }
        let vocals = TransitionPlanner.Vocals(
            outgoing: VocalMaskStore.shared.segments(for: outId), incoming: VocalMaskStore.shared.segments(for: inId)
        )
        // Cuanto falta para empezar: lo que tardo en prepararse la ultima vez, con margen (entre 6 y 18 s).
        let lead = min(max(lastRenderSeconds * 1.4 + 2.5, 6), 18) + extraLead
        let startMs = Int64((PlayerController.shared.currentTime + lead) * 1000)
        guard let result = TransitionPlanner.plan(outgoing: out, incoming: inc, vocals: vocals, forcedStartMs: startMs) else {
            abortManual("Not enough of the song is left to mix.")
            return
        }
        planCache = (outId, inId, result.plan)
        PlaybackReport.record(String(
            format: "automix: mezcla pedida a mano %@ -> %@: empieza en %.1f s (en %.0f s), dura %.0f s, entra desde %.1f s",
            outId, inId, Double(result.plan.outgoingStartMs) / 1000, lead, Double(result.plan.durationMs) / 1000,
            Double(result.plan.incomingStartMs) / 1000
        ))
        let next = NowPlaying.shared.queueIndex + 1
        if NowPlaying.shared.queueSongs.indices.contains(next) {
            AutoMixVisuals.shared.prepare(song: NowPlaying.shared.queueSongs[next])
        }
        manualMix = true
        prepare(outId: outId, inId: inId, plan: result.plan)
    }

    /// Para cuando el usuario cambia de cancion a mano o se vacia la cola.
    /// Cuando se pidio la ultima cancion: el analisis en streaming espera un poco para no pedir direcciones a YouTube a la vez que
    /// la reproduccion que se acaba de pedir.
    private(set) var lastSongChange = Date.distantPast

    /// Hay una mezcla preparandose, preparada o sonando.
    var isActive: Bool { phase != .idle }

    /// Segundo de `outId` donde empezara la mezcla con la siguiente, si ya esta planificada (para la marca de la barra).
    func plannedMixStart(for outId: String) -> TimeInterval? {
        guard SettingsStore.shared.autoMixEnabled, let cached = planCache, cached.outId == outId, let plan = cached.plan else { return nil }
        return Double(plan.outgoingStartMs) / 1000
    }

    func songChanged() {
        lastSongChange = Date()
        releasePlayingMix()
        AutoMixVisuals.shared.preparingManual = false
        manualMix = false
        if phase != .idle {
            let controller = PlayerController.shared
            controller.disarmGaplessMix()
            controller.positionOverride = nil
            controller.durationOverride = nil
            AutoMixVisuals.shared.end()
            finish()
        }
        planCache = nil
        dropPrepared()
    }
}
