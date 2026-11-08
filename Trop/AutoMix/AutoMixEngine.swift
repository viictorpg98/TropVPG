//
//  AutoMixEngine.swift
//  Trop
//
//  Mezcla una cancion descargada con la siguiente como un DJ: la entrante suena en un segundo
//  reproductor (AVAudioPlayer) mientras la saliente (mpv) baja de volumen e iguala su tempo; al
//  acabar, mpv toma el relevo de la entrante y el segundo reproductor se apaga.
//  Diseno y formulas adaptados de AutoMix de SimpMusic (maxrave-dev/core, GPL-3.0).
//

import AVFoundation
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
    }

    private var phase = Phase.idle
    private var blend: Blend?
    private var timer: Timer?
    private var lastStep = Date()

    /// El segundo reproductor, preparado antes de que empiece la mezcla para no perder tiempo en el momento.
    private var armed: (inId: String, player: AVAudioPlayer, startSeconds: TimeInterval)?
    private var planCache: (outId: String, inId: String, plan: TransitionPlan?)?
    private var preparingId: String?

    // Relevo
    private var handoffStartedAt = Date()
    private var handoffTarget: TimeInterval = 0
    private var alignAttempts = 0
    private var fadeStartedAt: Date?
    private var lastAlignAt = Date.distantPast

    private let fastInterval: TimeInterval = 0.03
    private let handoffFade: TimeInterval = 0.4

    private init() {}

    // MARK: - Llamada desde el temporizador de NowPlaying (cada 0,25 s)

    func tick(position: TimeInterval) {
        guard SettingsStore.shared.autoMixEnabled else {
            if phase != .idle { cancel("desactivado") }
            armed = nil
            return
        }
        guard phase == .idle else { return }
        guard let (outId, inId) = currentPair() else { armed = nil; return }

        // Siempre se pide analizar la actual y la siguiente (si ya estan hechas no cuesta nada).
        TrackAnalysisStore.shared.request(outId)
        TrackAnalysisStore.shared.request(inId)
        guard let plan = plan(outId: outId, inId: inId) else { return }

        let lead = Double(plan.outgoingStartMs) / 1000 - position
        if lead > 10 || lead < -2 { return }
        prepareVoice(inId: inId, plan: plan)
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
                format: "automix: plan %@ -> %@: empieza en %.1f s, dura %.0f s, entra desde %.1f s, tempo x%.2f",
                outId, inId, Double($0.outgoingStartMs) / 1000, Double($0.durationMs) / 1000,
                Double($0.incomingStartMs) / 1000, $0.outgoingSpeedRatio
            )
        } ?? "automix: \(outId) -> \(inId) sin mezcla posible (se usa el paso normal)")
        return plan
    }

    // MARK: - Segundo reproductor

    private func prepareVoice(inId: String, plan: TransitionPlan) {
        if let armed, armed.inId == inId { return }
        guard preparingId != inId else { return }
        armed = nil
        preparingId = inId
        Task { [weak self] in
            defer { self?.preparingId = nil }
            guard let url = await DownloadManager.shared.localURL(for: inId) else { return }
            guard let self else { return }
            guard let player = try? AVAudioPlayer(contentsOf: url) else {
                PlaybackReport.record("automix: no se pudo abrir \(inId) para mezclar")
                return
            }
            player.volume = 0
            player.prepareToPlay()
            let start = Double(plan.incomingStartMs) / 1000
            player.currentTime = start
            if self.armed?.inId != inId, self.phase == .idle || self.phase == .arming {
                self.armed = (inId, player, start)
            }
        }
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
        blend = Blend(outId: b.outId, inId: b.inId, plan: late, lastPosition: position)
        armed.player.currentTime = Double(late.incomingStartMs) / 1000
        armed.player.volume = 0
        armed.player.play()
        phase = .blending
        lastStep = Date()
        PlaybackReport.record(String(
            format: "automix: empieza %@ -> %@ (%.1f s, tempo x%.2f)",
            b.outId, b.inId, Double(late.durationMs) / 1000, late.outgoingSpeedRatio
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
            if armed.player.isPlaying { armed.player.pause() }
            return
        }
        if !armed.player.isPlaying { armed.player.play() }

        let position = PlayerController.shared.currentTime
        if abs(position - b.lastPosition) > 1.5 { cancel("salto de posicion"); return }
        b.lastPosition = position
        b.elapsed += dt

        let duration = Double(b.plan.durationMs) / 1000
        let progress = min(b.elapsed / duration, 1)
        // Potencia constante: la saliente baja con el coseno y la entrante sube con el seno.
        let angle = progress * Double.pi / 2
        let playerVolume = SettingsStore.shared.playerVolume
        PlayerController.shared.volumeScale = cos(angle)
        PlayerController.shared.applyPlayerVolume()
        armed.player.volume = Float(sin(angle) * playerVolume)

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

    // MARK: - Relevo: mpv toma la entrante donde va la del segundo reproductor

    private func startHandoff() {
        guard let b = blend, let armed else { cancel("sin datos"); return }
        phase = .handoff
        PlayerController.shared.volumeScale = 0
        PlayerController.shared.applyPlayerVolume()
        PlayerController.shared.setPlaybackSpeed(1)
        // mpv carga la entrante unos instantes por detras de la del segundo reproductor; se corrige al alinear.
        handoffTarget = armed.player.currentTime + 0.25
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
            controller.volumeScale = sin(angle)
            controller.applyPlayerVolume()
            armed.player.volume = Float(cos(angle) * playerVolume)
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
                armed.player.stop()
                self.armed = nil
                controller.volumeScale = 1
                controller.applyPlayerVolume()
                finish()
            }
            return
        }

        // Alinear: mpv se pone justo donde va el segundo reproductor (con las dos en silencio una de ellas).
        let offset = armed.player.currentTime - controller.currentTime
        if abs(offset) > 0.03, alignAttempts < 2, Date().timeIntervalSince(lastAlignAt) > 0.25 {
            alignAttempts += 1
            lastAlignAt = Date()
            controller.seek(to: armed.player.currentTime + 0.06)
            return
        }
        if Date().timeIntervalSince(lastAlignAt) < 0.2 { return }
        PlaybackReport.record(String(format: "automix: relevo, desfase %.0f ms (%d ajustes)", offset * 1000, alignAttempts))
        fadeStartedAt = Date()
    }

    private func finish() {
        PlayerController.shared.volumeScale = 1
        PlayerController.shared.applyPlayerVolume()
        PlayerController.shared.setPlaybackSpeed(1)
        armed?.player.stop()
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
        stopTimer()
        armed?.player.stop()
        armed = nil
        blend = nil
        phase = .idle
        PlayerController.shared.volumeScale = 1
        PlayerController.shared.applyPlayerVolume()
        PlayerController.shared.setPlaybackSpeed(1)
        if wasHandoff { planCache = nil }
    }

    /// Para cuando el usuario cambia de cancion a mano o se vacia la cola.
    func songChanged() {
        // Durante el relevo el cambio de cancion lo provoca la propia mezcla.
        guard phase != .handoff else { return }
        if phase != .idle { cancel("cambio de cancion") }
        planCache = nil
    }
}
