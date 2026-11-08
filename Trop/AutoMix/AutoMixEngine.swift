//
//  AutoMixEngine.swift
//  Trop
//
//  Mezcla una cancion descargada con la siguiente como un DJ. Unos segundos antes se preparan dos tramos de
//  audio (`MixRenderer`): el final de la saliente, con un paso bajo que se cierra, el volumen bajando y el
//  tempo ajustandose al de la entrante, y el principio de la entrante, con un paso alto que se abre y el volumen
//  subiendo. Los dos suenan sincronizados con `AVAudioPlayer` mientras mpv queda callado; al acabar, mpv toma el
//  relevo de la entrante donde va y los dos tramos se apagan.
//  Diseno y formulas adaptados de AutoMix de SimpMusic (maxrave-dev/core, GPL-3.0).
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class AutoMixEngine {
    static let shared = AutoMixEngine()

    private enum Phase { case idle, arming, blending, handoff }

    /// Los dos tramos ya preparados para una pareja de canciones.
    private struct Armed {
        let key: String
        let outId: String
        let inId: String
        let plan: TransitionPlan
        /// Segundo de la saliente en que empieza su tramo (un poco antes de la mezcla, para el relevo desde mpv).
        let outgoingStart: Double
        let outgoing: MixVoice
        let incoming: MixVoice
    }

    /// Una mezcla en marcha.
    private struct Blend {
        let outId: String
        let inId: String
        let plan: TransitionPlan
        let outgoingStart: Double
        let swappedAt: Date
        var beatMs: Double = 500
        var beatsPerPulse: Double = 1
        var lastRate: Double = 1
        /// mpv ya esta callado y en pausa (la saliente suena por su tramo).
        var mpvSilenced = false
        var playersPaused = false
    }

    /// Segundos de la saliente que se reproducen tal cual desde su tramo antes de empezar la mezcla: en ellos
    /// mpv le pasa el testigo (un fundido corto) sin que se note el cambio de reproductor.
    private let swapLead = 0.8
    /// Duracion del fundido del relevo de mpv al tramo de la saliente (mas largo = menos se nota un pequeno desfase).
    private let swapFade = 0.3
    /// Segundos extra de la entrante a volumen completo tras la mezcla, para cubrir el relevo de mpv.
    private let voiceTail = 6.0

    private var phase = Phase.idle
    private var armed: Armed?
    private var blend: Blend?
    private var planCache: (outId: String, inId: String, plan: TransitionPlan?)?
    private var preparingKey: String?
    private var timer: Timer?

    // Relevo final a mpv
    private var handoffStartedAt = Date()
    private var handoffTarget: TimeInterval = 0
    private var alignAttempts = 0
    private var seekLead = 0.15
    private var fadeStartedAt: Date?
    private var lastAlignAt = Date.distantPast

    private let fastInterval: TimeInterval = 0.03
    private let handoffFade: TimeInterval = 0.4

    private init() {}

    // MARK: - Llamada desde el temporizador de NowPlaying (cada 0,25 s)

    func tick(position: TimeInterval) {
        guard SettingsStore.shared.autoMixEnabled else {
            if phase != .idle { cancel("desactivado") }
            dropPreparation()
            return
        }
        guard phase == .idle else { return }
        guard let (outId, inId) = currentPair() else { dropPreparation(); return }

        // Siempre se pide analizar la actual y la siguiente (si ya estan hechas no cuesta nada).
        TrackAnalysisStore.shared.request(outId)
        TrackAnalysisStore.shared.request(inId)
        guard let plan = plan(outId: outId, inId: inId) else { return }

        let swapAt = Double(plan.outgoingStartMs) / 1000 - swapLead
        let lead = swapAt - position
        if lead > 10 || lead < -1 { return }
        AutoMixVisuals.shared.prepare(song: NowPlaying.shared.queueSongs[NowPlaying.shared.queueIndex + 1])
        prepare(outId: outId, inId: inId, plan: plan)
        if lead <= 0.7, armed?.key == pairKey(outId, inId) { beginArming() }
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
                format: "automix: plan %@ -> %@: empieza en %.1f s, dura %.0f s, entra desde %.1f s, tempo x%.2f (%.0f -> %.0f BPM)",
                outId, inId, Double($0.outgoingStartMs) / 1000, Double($0.durationMs) / 1000,
                Double($0.incomingStartMs) / 1000, $0.outgoingSpeedRatio, out.bpm, inc.bpm
            )
        } ?? "automix: \(outId) -> \(inId) sin mezcla posible (se usa el paso normal)")
        return plan
    }

    // MARK: - Preparacion de los tramos

    private func prepare(outId: String, inId: String, plan: TransitionPlan) {
        let key = pairKey(outId, inId)
        if armed?.key == key { return }
        guard preparingKey != key else { return }
        dropArmed()
        preparingKey = key
        let lead = swapLead
        let tail = voiceTail
        Task { [weak self] in
            defer { self?.preparingKey = nil }
            let downloads = DownloadManager.shared
            guard let outURL = await downloads.localURL(for: outId),
                  let inURL = await downloads.localURL(for: inId) else { return }
            let began = Date()
            let outgoingStart = Double(plan.outgoingStartMs) / 1000 - lead
            let incomingStart = Double(plan.incomingStartMs) / 1000
            let duration = Double(plan.durationMs) / 1000
            let ratio = plan.outgoingSpeedRatio
            let rendered = await Task.detached(priority: .userInitiated) {
                MixRenderer.render(
                    outgoingURL: outURL, outgoingStart: outgoingStart, lead: lead,
                    incomingURL: inURL, incomingStart: incomingStart,
                    duration: duration, ratio: ratio, tail: tail
                )
            }.value
            guard let rendered,
                  let outgoing = MixVoice.make(fileURL: rendered.outgoing, startSeconds: outgoingStart, enableRate: true),
                  let incoming = MixVoice.make(fileURL: rendered.incoming, startSeconds: incomingStart, enableRate: false) else {
                PlaybackReport.record("automix: no se pudo preparar la mezcla \(outId) -> \(inId)")
                return
            }
            guard let self else { outgoing.stop(); incoming.stop(); return }
            if self.armed?.key != key, self.phase == .idle || self.phase == .arming {
                self.armed = Armed(
                    key: key, outId: outId, inId: inId, plan: plan, outgoingStart: outgoingStart,
                    outgoing: outgoing, incoming: incoming
                )
                PlaybackReport.record(String(format: "automix: mezcla %@ -> %@ preparada en %.1f s", outId, inId, Date().timeIntervalSince(began)))
            } else {
                outgoing.stop()
                incoming.stop()
            }
        }
    }

    private func dropArmed() {
        if let armed {
            armed.outgoing.stop()
            armed.incoming.stop()
            self.armed = nil
        }
    }

    private func dropPreparation() {
        dropArmed()
    }

    // MARK: - Mezcla

    /// Falta menos de un segundo para el relevo: se vigila la posicion de mpv de cerca para entrar a tiempo.
    private func beginArming() {
        guard let armed else { return }
        phase = .arming
        blend = Blend(
            outId: armed.outId, inId: armed.inId, plan: armed.plan, outgoingStart: armed.outgoingStart, swappedAt: Date()
        )
        startTimer()
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
        case .arming: stepArming()
        case .blending: stepBlending()
        case .handoff: stepHandoff()
        }
    }

    private func stepArming() {
        guard let b = blend, let armed, armed.outId == b.outId, armed.inId == b.inId else { cancel("sin datos"); return }
        let np = NowPlaying.shared
        guard np.videoId == b.outId, !np.isVideoMode else { cancel("la cancion cambio antes de empezar"); return }
        guard np.isPlaying else { return }
        let controller = PlayerController.shared
        let position = controller.currentTime
        if position < b.outgoingStart - 1 || position > b.outgoingStart + swapLead { cancel("salto de posicion antes de empezar"); return }
        guard position >= b.outgoingStart else { return }

        // Donde del tramo de la saliente hay que entrar para seguir justo donde va mpv (con un pequeno adelanto
        // por lo que tarda en arrancar). Si ya se paso casi todo el relevo, no se mezcla.
        let offset = position - b.outgoingStart + 0.03
        guard offset < swapLead - 0.2 else {
            cancel("demasiado tarde", quiet: true)
            planCache = (b.outId, b.inId, nil)
            return
        }
        let volume = Float(SettingsStore.shared.playerVolume)
        armed.outgoing.setVolume(0)
        armed.outgoing.play(from: offset)
        armed.outgoing.setVolume(volume, fade: swapFade)
        // La entrante arranca exactamente cuando la saliente llega al inicio de la mezcla (misma hora del dispositivo).
        armed.incoming.setVolume(volume)
        armed.incoming.play(from: 0, atDeviceTime: armed.outgoing.deviceTime + max(swapLead - offset, 0.01))

        var started = Blend(
            outId: b.outId, inId: b.inId, plan: b.plan, outgoingStart: b.outgoingStart, swappedAt: Date()
        )
        if let structure = TrackAnalysisStore.shared.structure(for: b.outId) {
            started.beatMs = structure.beatMs
            // Por encima de 140 BPM el latido seria nervioso: se hace cada dos pulsos.
            started.beatsPerPulse = structure.bpm > 140 ? 2 : 1
        }
        blend = started
        AutoMixVisuals.shared.begin()
        phase = .blending
        PlaybackReport.record(String(
            format: "automix: empieza %@ -> %@ (%.1f s, tempo x%.2f)",
            b.outId, b.inId, Double(b.plan.durationMs) / 1000, b.plan.outgoingSpeedRatio
        ))
    }

    private func stepBlending() {
        guard var b = blend, let armed, armed.inId == b.inId else { cancel("sin datos"); return }
        let np = NowPlaying.shared
        guard np.videoId == b.outId, !np.isVideoMode,
              np.queueSongs.indices.contains(np.queueIndex), np.queueIndex + 1 < np.queueSongs.count,
              np.queueSongs[np.queueIndex + 1].videoId == b.inId else {
            cancel("la cola cambio")
            return
        }
        let controller = PlayerController.shared

        // En pausa (o interrumpido) las dos se paran; como todo se mide con el tiempo de los propios tramos,
        // al reanudar la mezcla sigue donde estaba.
        guard np.isPlaying else {
            if !b.playersPaused {
                armed.outgoing.pause()
                armed.incoming.pause()
                b.playersPaused = true
                blend = b
            }
            return
        }
        if b.playersPaused {
            armed.outgoing.resume()
            armed.incoming.resume()
            b.playersPaused = false
        }

        // Relevo de mpv al tramo de la saliente: mpv baja con un fundido corto y luego se calla y se pausa.
        let sinceSwap = Date().timeIntervalSince(b.swappedAt)
        if !b.mpvSilenced {
            if sinceSwap < swapFade + 0.1 {
                let gain = 1 - min(max((sinceSwap - 0.05) / swapFade, 0), 1)
                controller.volumeScale = mpvScale(forGain: gain)
                controller.applyPlayerVolume()
            } else {
                controller.volumeScale = 0
                controller.applyPlayerVolume()
                controller.setRawPause(true)
                b.mpvSilenced = true
            }
        }

        // Todo el reproductor (barra de progreso, pantalla de bloqueo) sigue la posicion de la saliente.
        let outgoingPosition = armed.outgoing.position
        controller.positionOverride = outgoingPosition

        // Avance de la mezcla: lo que lleva sonando la entrante, de 0 a 1.
        let duration = Double(b.plan.durationMs) / 1000
        let progress = min(max(armed.incoming.bufferTime / duration, 0), 1)
        let visuals = AutoMixVisuals.shared
        visuals.progress = progress
        let beats = (outgoingPosition * 1000 - Double(b.plan.outgoingStartMs)) / max(b.beatMs, 1) / b.beatsPerPulse
        visuals.beatPhase = beats - beats.rounded(.down)

        // La saliente iguala el tempo de la entrante, en rampa suave, y lo mantiene.
        if b.plan.outgoingSpeedRatio != 1 {
            let rate = 1 + (b.plan.outgoingSpeedRatio - 1) * AutoMixMath.rampProgress(progress)
            let quantized = (rate / 0.005).rounded() * 0.005
            if abs(quantized - b.lastRate) >= 0.004 {
                armed.outgoing.setRate(Float(quantized))
                b.lastRate = quantized
            }
        }
        blend = b
        if progress >= 1 { startHandoff() }
    }

    /// El volumen de mpv es perceptual (la ganancia real es su cubo): para una ganancia deseada `gain` hay que
    /// pedirle su raiz cubica.
    private func mpvScale(forGain gain: Double) -> Double {
        pow(max(gain, 0), 1.0 / 3.0)
    }

    // MARK: - Relevo final: mpv toma la entrante donde va su tramo

    private func startHandoff() {
        guard let b = blend, let armed else { cancel("sin datos"); return }
        phase = .handoff
        let controller = PlayerController.shared
        controller.positionOverride = nil
        controller.volumeScale = 0
        controller.applyPlayerVolume()
        armed.outgoing.stop()
        AutoMixVisuals.shared.progress = 1
        AutoMixVisuals.shared.pulsing = false
        // mpv carga la entrante unos instantes por detras de su tramo; se corrige al alinear.
        handoffTarget = armed.incoming.position + 0.25
        handoffStartedAt = Date()
        alignAttempts = 0
        fadeStartedAt = nil
        lastAlignAt = .distantPast
        guard NowPlaying.shared.advanceForAutoMix(startAt: handoffTarget) else {
            cancel("no se pudo avanzar la cola")
            return
        }
        blend = Blend(
            outId: b.outId, inId: b.inId, plan: b.plan, outgoingStart: b.outgoingStart, swappedAt: b.swappedAt
        )
    }

    private func stepHandoff() {
        guard let b = blend, let armed else { cancel("sin datos"); return }
        let np = NowPlaying.shared
        let controller = PlayerController.shared
        guard np.videoId == b.inId else { cancel("cambio la cancion durante el relevo"); return }
        let playerVolume = SettingsStore.shared.playerVolume

        if let fadeStart = fadeStartedAt {
            // Las dos suenan la misma cancion en el mismo punto: el fundido es lineal (sumar amplitudes), no de potencia.
            let t = min(Date().timeIntervalSince(fadeStart) / handoffFade, 1)
            controller.volumeScale = mpvScale(forGain: t)
            controller.applyPlayerVolume()
            armed.incoming.setVolume(Float((1 - t) * playerVolume))
            if t >= 1 { finish() }
            return
        }

        // Esperando a que mpv suene con la entrante.
        let mainReady = controller.currentVideoId == b.inId
            && controller.playState.value == .playing
            && controller.currentTime >= handoffTarget - 0.3
        if !mainReady {
            if Date().timeIntervalSince(handoffStartedAt) > 4 {
                PlaybackReport.record("automix: mpv no cargo la entrante a tiempo")
                // Se deja sonar mpv solo, sin el segundo reproductor.
                controller.volumeScale = 1
                controller.applyPlayerVolume()
                finish()
            }
            return
        }

        // Alinear: mpv se pone justo donde va el tramo de la entrante (mpv sigue en silencio). Cada intento aprende
        // cuanto tarda en saltar y lo compensa en el siguiente.
        let offset = armed.incoming.position - controller.currentTime
        if abs(offset) > 0.04, alignAttempts < 3, Date().timeIntervalSince(lastAlignAt) > 0.3 {
            if alignAttempts > 0 { seekLead += offset }
            alignAttempts += 1
            lastAlignAt = Date()
            controller.seek(to: armed.incoming.position + seekLead)
            return
        }
        if Date().timeIntervalSince(lastAlignAt) < 0.3 { return }
        PlaybackReport.record(String(format: "automix: relevo, desfase %.0f ms (%d ajustes)", offset * 1000, alignAttempts))
        fadeStartedAt = Date()
    }

    private func finish() {
        let controller = PlayerController.shared
        controller.positionOverride = nil
        controller.volumeScale = 1
        controller.applyPlayerVolume()
        AutoMixVisuals.shared.end()
        dropArmed()
        blend = nil
        planCache = nil
        phase = .idle
        stopTimer()
    }

    // MARK: - Cancelar

    func cancel(_ reason: String, quiet: Bool = false) {
        if !quiet { PlaybackReport.record("automix: cancelada (\(reason))") }
        let controller = PlayerController.shared
        let np = NowPlaying.shared
        let wasBlending = phase == .blending
        let b = blend
        let outgoingPosition = armed?.outgoing.position
        let wasHandoff = phase == .handoff
        stopTimer()
        AutoMixVisuals.shared.end()
        dropArmed()
        blend = nil
        phase = .idle
        controller.positionOverride = nil
        controller.volumeScale = 1
        // Si mpv se habia callado y pausado y la cancion sigue siendo la misma, se le devuelve donde iba el tramo.
        if wasBlending, let b, b.mpvSilenced, np.videoId == b.outId {
            if let outgoingPosition { controller.seek(to: outgoingPosition) }
            if np.isPlaying { controller.setRawPause(false) }
        }
        controller.applyPlayerVolume()
        if wasHandoff { planCache = nil }
    }

    /// Para cuando el usuario cambia de cancion a mano o se vacia la cola.
    func songChanged() {
        // Durante el relevo el cambio de cancion lo provoca la propia mezcla.
        guard phase != .handoff else { return }
        if phase != .idle { cancel("cambio de cancion") }
        planCache = nil
        dropArmed()
    }
}
