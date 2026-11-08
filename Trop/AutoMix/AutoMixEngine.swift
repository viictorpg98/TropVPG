//
//  AutoMixEngine.swift
//  Trop
//
//  Mezcla una cancion descargada con la siguiente como un DJ: la entrante suena en un segundo
//  reproductor (`MixVoice`, con el filtro paso alto y el volumen ya preparados) mientras la saliente (mpv) baja de
//  volumen, cierra un filtro paso bajo e iguala su tempo; al acabar, mpv toma el relevo de la entrante y
//  el segundo reproductor se apaga.
//  Diseno y formulas adaptados de AutoMix de SimpMusic (maxrave-dev/core, GPL-3.0).
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class AutoMixEngine {
    static let shared = AutoMixEngine()

    private enum Phase { case idle, arming, blending, handoff }

    /// Una mezcla en marcha.
    private struct Blend {
        let outId: String
        let inId: String
        let plan: TransitionPlan
        var elapsed: TimeInterval = 0
        var lastPosition: TimeInterval
        var lastSpeed: Double = 1
        /// Duracion del pulso de la saliente (ms) y cuantos pulsos hay por golpe del latido de la animacion.
        var beatMs: Double = 500
        var beatsPerPulse: Double = 1
    }

    // Filtro de DJ de la saliente (valores de SimpMusic): paso bajo de 20 kHz a 200 Hz con curva en S. El paso alto
    // de la entrante (2 kHz a 20 Hz) ya va aplicado al tramo que prepara `MixVoice`.
    private let lowPassStart = 20_000.0
    private let lowPassEnd = 200.0
    private let sigmoidK = 6.0
    /// Segundos extra a volumen completo tras la mezcla, para cubrir el relevo de mpv.
    private let voiceTail = 6.0

    private var phase = Phase.idle
    private var blend: Blend?
    private var timer: Timer?
    private var lastStep = Date()

    /// El segundo reproductor, preparado antes de que empiece la mezcla para no perder tiempo en el momento.
    private var armed: (inId: String, voice: MixVoice)?
    private var planCache: (outId: String, inId: String, plan: TransitionPlan?)?
    private var preparingId: String?
    /// El filtro paso bajo de mpv esta en la cadena de audio (se mete unos segundos antes de la mezcla).
    private var lowPassInstalled = false
    private var lowPassFailureLogged = false

    // Relevo
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

        let lead = Double(plan.outgoingStartMs) / 1000 - position
        if lead > 10 || lead < -2 { return }
        AutoMixVisuals.shared.prepare(song: NowPlaying.shared.queueSongs[NowPlaying.shared.queueIndex + 1])
        prepareVoice(inId: inId, plan: plan)
        installLowPass()
        if lead <= 0.7 { beginArming(outId: outId, inId: inId, plan: plan) }
    }

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

    // MARK: - Preparacion

    private func prepareVoice(inId: String, plan: TransitionPlan) {
        if let armed, armed.inId == inId { return }
        guard preparingId != inId else { return }
        armed?.voice.stop()
        armed = nil
        preparingId = inId
        let tail = voiceTail
        Task { [weak self] in
            defer { self?.preparingId = nil }
            guard let url = await DownloadManager.shared.localURL(for: inId) else { return }
            let began = Date()
            guard let voice = await MixVoice.make(
                url: url,
                startSeconds: Double(plan.incomingStartMs) / 1000,
                durationSeconds: Double(plan.durationMs) / 1000,
                tailSeconds: tail
            ) else {
                PlaybackReport.record("automix: no se pudo preparar \(inId) para mezclar")
                return
            }
            guard let self else { voice.stop(); return }
            if self.armed?.inId != inId, self.phase == .idle || self.phase == .arming {
                self.armed = (inId, voice)
                PlaybackReport.record(String(format: "automix: entrante %@ preparada en %.1f s", inId, Date().timeIntervalSince(began)))
            } else {
                voice.stop()
            }
        }
    }

    /// Mete el filtro paso bajo (abierto del todo) en la cadena de audio de mpv; despues solo se le cambia la
    /// frecuencia. Se hace unos segundos antes para que la reconfiguracion no coincida con la mezcla.
    private func installLowPass() {
        guard !lowPassInstalled else { return }
        lowPassInstalled = true
        PlayerController.shared.djFilterActive = true
        PlayerController.shared.applyPlaybackSettings()
    }

    private func removeLowPass(reapply: Bool) {
        guard lowPassInstalled else { return }
        lowPassInstalled = false
        PlayerController.shared.djFilterActive = false
        // Si va a cargarse otra cancion, `play` ya vuelve a montar la cadena sin filtro.
        if reapply { PlayerController.shared.applyPlaybackSettings() }
    }

    private func dropPreparation() {
        if let armed {
            armed.voice.stop()
            self.armed = nil
        }
        removeLowPass(reapply: true)
    }

    // MARK: - Mezcla

    /// Falta menos de un segundo: se vigila la posicion de cerca para empezar a tiempo.
    private func beginArming(outId: String, inId: String, plan: TransitionPlan) {
        phase = .arming
        blend = Blend(outId: outId, inId: inId, plan: plan, lastPosition: PlayerController.shared.currentTime)
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        lastStep = Date()
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
        guard let b = blend else { cancel("sin datos"); return }
        let np = NowPlaying.shared
        guard np.videoId == b.outId, !np.isVideoMode else { cancel("la cancion cambio antes de empezar"); return }
        guard np.isPlaying else { return }
        let position = PlayerController.shared.currentTime
        let startAt = Double(b.plan.outgoingStartMs) / 1000
        if position < startAt - 1 || position > startAt + 3 { cancel("salto de posicion antes de empezar"); return }
        guard position >= startAt else { return }

        guard let armed, armed.inId == b.inId else {
            // El segundo reproductor no estaba listo: no se arriesga, paso normal.
            PlaybackReport.record("automix: segundo reproductor no listo, sin mezcla")
            cancel("no listo", quiet: true)
            planCache = (b.outId, b.inId, nil)
            return
        }
        // Mezcla tardia: entra mas tarde y dura menos (el final no se mueve).
        guard let late = b.plan.startingAt(outgoingPositionMs: Int64(position * 1000)) else {
            cancel("demasiado tarde", quiet: true)
            planCache = (b.outId, b.inId, nil)
            return
        }
        var started = Blend(outId: b.outId, inId: b.inId, plan: late, lastPosition: position)
        if let structure = TrackAnalysisStore.shared.structure(for: b.outId) {
            started.beatMs = structure.beatMs
            // Por encima de 140 BPM el latido seria nervioso: se hace cada dos pulsos.
            started.beatsPerPulse = structure.bpm > 140 ? 2 : 1
        }
        blend = started
        AutoMixVisuals.shared.begin()
        armed.voice.setVolume(Float(SettingsStore.shared.playerVolume))
        armed.voice.start(atSongTime: Double(late.incomingStartMs) / 1000)
        phase = .blending
        lastStep = Date()
        PlaybackReport.record(String(
            format: "automix: empieza %@ -> %@ (%.1f s, tempo x%.2f, filtro %@)",
            b.outId, b.inId, Double(late.durationMs) / 1000, late.outgoingSpeedRatio,
            lowPassInstalled && PlayerController.shared.djFilterActive ? "si" : "no"
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
        let now = Date()
        let dt = min(now.timeIntervalSince(lastStep), 0.2)
        lastStep = now

        // En pausa (o interrumpido) las dos se paran y el reloj de la mezcla tambien.
        guard np.isPlaying else {
            if armed.voice.isPlaying { armed.voice.pause() }
            return
        }
        if !armed.voice.isPlaying { armed.voice.resume() }

        let position = PlayerController.shared.currentTime
        if abs(position - b.lastPosition) > 1.5 { cancel("salto de posicion"); return }
        b.lastPosition = position
        b.elapsed += dt

        let duration = Double(b.plan.durationMs) / 1000
        let progress = min(b.elapsed / duration, 1)
        let visuals = AutoMixVisuals.shared
        visuals.progress = progress
        let beatsSinceStart = (position * 1000 - Double(b.plan.outgoingStartMs)) / max(b.beatMs, 1) / b.beatsPerPulse
        visuals.beatPhase = beatsSinceStart - beatsSinceStart.rounded(.down)
        // Potencia constante: la saliente baja con el coseno (la entrante ya lleva su seno aplicado).
        let angle = progress * Double.pi / 2
        PlayerController.shared.volumeScale = mpvScale(forGain: cos(angle))
        PlayerController.shared.applyPlayerVolume()

        // Filtro de DJ con curva en S: la saliente pierde agudos.
        let sweep = 1 / (1 + exp(-sigmoidK * (progress - 0.5)))
        if lowPassInstalled, PlayerController.shared.djFilterActive {
            let result = PlayerController.shared.setDJLowpass(exponential(lowPassStart, lowPassEnd, sweep))
            if result < 0, !lowPassFailureLogged {
                lowPassFailureLogged = true
                PlaybackReport.record("automix: el filtro de mpv no responde (codigo \(result))")
            }
        }

        // La saliente iguala el tempo de la entrante, en rampa suave, y lo mantiene.
        if b.plan.outgoingSpeedRatio != 1 {
            let speed = 1 + (b.plan.outgoingSpeedRatio - 1) * AutoMixMath.rampProgress(progress)
            let quantized = (speed / 0.005).rounded() * 0.005
            if abs(quantized - b.lastSpeed) >= 0.004 {
                PlayerController.shared.setPlaybackSpeed(quantized)
                b.lastSpeed = quantized
            }
        }
        blend = b
        if progress >= 1 { startHandoff() }
    }

    private func exponential(_ start: Double, _ end: Double, _ t: Double) -> Double {
        exp(log(start) + (log(end) - log(start)) * t)
    }

    /// El volumen de mpv es perceptual (la ganancia real es su cubo): para una ganancia deseada `gain` hay que
    /// pedirle su raiz cubica. Sin esto la saliente caia mucho antes de lo previsto y quedaba un hueco.
    private func mpvScale(forGain gain: Double) -> Double {
        pow(max(gain, 0), 1.0 / 3.0)
    }

    // MARK: - Relevo: mpv toma la entrante donde va la del segundo reproductor

    private func startHandoff() {
        guard let b = blend, let armed else { cancel("sin datos"); return }
        phase = .handoff
        PlayerController.shared.volumeScale = 0
        PlayerController.shared.applyPlayerVolume()
        PlayerController.shared.setPlaybackSpeed(1)
        // La cadena de mpv se vuelve a montar al cargar la entrante, ya sin el filtro.
        removeLowPass(reapply: false)
        AutoMixVisuals.shared.progress = 1
        AutoMixVisuals.shared.pulsing = false
        // mpv carga la entrante unos instantes por detras de la del segundo reproductor; se corrige al alinear.
        handoffTarget = armed.voice.position + 0.25
        handoffStartedAt = Date()
        alignAttempts = 0
        fadeStartedAt = nil
        lastAlignAt = .distantPast
        guard NowPlaying.shared.advanceForAutoMix(startAt: handoffTarget) else {
            cancel("no se pudo avanzar la cola")
            return
        }
        blend = Blend(outId: b.outId, inId: b.inId, plan: b.plan, lastPosition: handoffTarget)
    }

    private func stepHandoff() {
        guard let b = blend, let armed else { cancel("sin datos"); return }
        let np = NowPlaying.shared
        let controller = PlayerController.shared
        guard np.videoId == b.inId else { cancel("cambio la cancion durante el relevo"); return }
        let playerVolume = SettingsStore.shared.playerVolume

        if let fadeStart = fadeStartedAt {
            let t = min(Date().timeIntervalSince(fadeStart) / handoffFade, 1)
            let angle = t * Double.pi / 2
            controller.volumeScale = mpvScale(forGain: sin(angle))
            controller.applyPlayerVolume()
            armed.voice.setVolume(Float(cos(angle) * playerVolume))
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

        // Alinear: mpv se pone justo donde va el segundo reproductor (mpv sigue en silencio). Cada intento aprende
        // cuanto tarda en saltar y lo compensa en el siguiente.
        let offset = armed.voice.position - controller.currentTime
        if abs(offset) > 0.04, alignAttempts < 3, Date().timeIntervalSince(lastAlignAt) > 0.3 {
            if alignAttempts > 0 { seekLead += offset }
            alignAttempts += 1
            lastAlignAt = Date()
            controller.seek(to: armed.voice.position + seekLead)
            return
        }
        if Date().timeIntervalSince(lastAlignAt) < 0.3 { return }
        PlaybackReport.record(String(format: "automix: relevo, desfase %.0f ms (%d ajustes)", offset * 1000, alignAttempts))
        fadeStartedAt = Date()
    }

    private func finish() {
        AutoMixVisuals.shared.end()
        PlayerController.shared.volumeScale = 1
        PlayerController.shared.applyPlayerVolume()
        PlayerController.shared.setPlaybackSpeed(1)
        armed?.voice.stop()
        armed = nil
        blend = nil
        planCache = nil
        phase = .idle
        stopTimer()
    }

    // MARK: - Cancelar

    func cancel(_ reason: String, quiet: Bool = false) {
        if !quiet { PlaybackReport.record("automix: cancelada (\(reason))") }
        let wasHandoff = phase == .handoff
        AutoMixVisuals.shared.end()
        stopTimer()
        armed?.voice.stop()
        armed = nil
        blend = nil
        phase = .idle
        PlayerController.shared.volumeScale = 1
        PlayerController.shared.applyPlayerVolume()
        PlayerController.shared.setPlaybackSpeed(1)
        removeLowPass(reapply: true)
        if wasHandoff { planCache = nil }
    }

    /// Para cuando el usuario cambia de cancion a mano o se vacia la cola.
    func songChanged() {
        // Durante el relevo el cambio de cancion lo provoca la propia mezcla.
        guard phase != .handoff else { return }
        if phase != .idle { cancel("cambio de cancion") }
        planCache = nil
        // La cadena de mpv se vuelve a montar al cargar la nueva cancion, ya sin el filtro.
        removeLowPass(reapply: false)
        if let armed {
            armed.voice.stop()
            self.armed = nil
        }
    }
}
