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
        /// Segundo de la entrante por donde sigue mpv cuando acaba el archivo de la mezcla.
        let resumeAt: Double
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

    private let fastInterval: TimeInterval = 0.03

    private init() {}

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
        guard let plan = plan(outId: outId, inId: inId) else { return }

        let lead = Double(plan.outgoingStartMs) / 1000 - position
        if lead > 14 || lead < 0.8 { return }
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
        let downloads = DownloadManager.shared
        guard outId != inId, downloads.isDownloaded(videoId: outId), downloads.isDownloaded(videoId: inId) else {
            return nil
        }
        return (outId, inId)
    }

    private func plan(outId: String, inId: String) -> TransitionPlan? {
        if let cached = planCache, cached.outId == outId, cached.inId == inId { return cached.plan }
        let store = TrackAnalysisStore.shared
        guard let out = store.structure(for: outId), let inc = store.structure(for: inId) else { return nil }
        let plan = TransitionPlanner.plan(outgoing: out, incoming: inc)
        planCache = (outId, inId, plan)
        PlaybackReport.record(plan.map {
            String(
                format: "automix: plan %@ -> %@: corte en %.1f s, dura %.0f s, entra desde %.1f s (%.0f -> %.0f BPM)",
                outId, inId, Double($0.outgoingStartMs) / 1000, Double($0.durationMs) / 1000,
                Double($0.incomingStartMs) / 1000, out.bpm, inc.bpm
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
            let downloads = DownloadManager.shared
            guard let outURL = await downloads.localURL(for: outId),
                  let inURL = await downloads.localURL(for: inId) else { return }
            let began = Date()
            let cutAt = Double(plan.outgoingStartMs) / 1000
            let inStart = Double(plan.incomingStartMs) / 1000
            let duration = Double(plan.durationMs) / 1000
            let rendered = await Task.detached(priority: .userInitiated) {
                MixRenderer.render(
                    outgoingURL: outURL, outgoingStart: cutAt,
                    incomingURL: inURL, incomingStart: inStart,
                    duration: duration
                )
            }.value
            guard let rendered else {
                PlaybackReport.record("automix: no se pudo preparar la mezcla \(outId) -> \(inId)")
                self?.planCache = (outId, inId, nil)
                return
            }
            guard let self else { try? FileManager.default.removeItem(at: rendered.url); return }
            if self.prepared?.key != key, self.phase == .idle {
                self.prepared = Prepared(
                    key: key, outId: outId, inId: inId, plan: plan, mixURL: rendered.url,
                    outgoingURL: outURL, incomingURL: inURL, cutAt: cutAt, resumeAt: inStart + duration
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
            mixURL: p.mixURL, incomingURL: p.incomingURL, incomingStart: p.resumeAt, endAt: p.cutAt, incomingId: p.inId
        ) else {
            PlaybackReport.record("automix: mpv no acepto la mezcla encadenada, se usa el paso normal")
            planCache = (p.outId, p.inId, nil)
            dropPrepared()
            return
        }
        outgoingDuration = controller.duration
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
            // mpv ya paso al archivo de la mezcla.
            phase = .mixing
            controller.durationOverride = outgoingDuration
            AutoMixVisuals.shared.begin()
            PlaybackReport.record("automix: empieza la mezcla \(p.outId) -> \(p.inId)")
        } else if controller.gaplessStage == 1, controller.rawTimePos() > p.cutAt + 0.8 {
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
        controller.positionOverride = min(p.cutAt + mixPosition, max(outgoingDuration, p.cutAt))
        let duration = Double(p.plan.durationMs) / 1000
        let visuals = AutoMixVisuals.shared
        visuals.progress = min(max(mixPosition / duration, 0), 1)
        let beats = (mixPosition * 1000) / max(beatMs, 1) / beatsPerPulse
        visuals.beatPhase = beats - beats.rounded(.down)
    }

    // MARK: - Fin de la mezcla: mpv ya suena la entrante

    /// mpv acabo el archivo de la mezcla y pasa a la entrante: la app pasa a verla como cancion actual.
    func gaplessReachedIncoming() {
        guard phase != .idle, let p = prepared else { return }
        let controller = PlayerController.shared
        controller.positionOverride = nil
        controller.durationOverride = nil
        let ok = NowPlaying.shared.adoptGaplessIncoming(videoId: p.inId)
        PlaybackReport.record(ok ? "automix: mezcla terminada, suena \(p.inId)" : "automix: no se pudo pasar a \(p.inId)")
        AutoMixVisuals.shared.progress = 1
        AutoMixVisuals.shared.end()
        finish()
    }

    private func finish() {
        stopTimer()
        if let prepared { try? FileManager.default.removeItem(at: prepared.mixURL) }
        prepared = nil
        planCache = nil
        phase = .idle
    }

    // MARK: - Cancelar

    func cancel(_ reason: String, quiet: Bool = false) {
        if !quiet { PlaybackReport.record("automix: cancelada (\(reason))") }
        let controller = PlayerController.shared
        let stage = controller.gaplessStage
        controller.disarmGaplessMix()
        // Si ya sonaba el archivo de la mezcla y la cancion sigue siendo la saliente, se vuelve a ella donde iba.
        if stage == 2, let p = prepared, NowPlaying.shared.videoId == p.outId {
            let position = min(p.cutAt + controller.rawTimePos(), max(outgoingDuration, p.cutAt))
            Task { _ = try? await PlaybackManager.shared.resolveAndPlay(videoId: p.outId, startAt: position) }
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

    /// Para cuando el usuario cambia de cancion a mano o se vacia la cola.
    func songChanged() {
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
