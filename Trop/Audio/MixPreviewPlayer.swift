//
//  MixPreviewPlayer.swift
//  Trop
//
//  Escuchar una mezcla desde el editor: se prepara la mezcla de las dos canciones (con lo que haya elegido en ese momento) como un archivo
//  corto (unos segundos de la saliente, la mezcla y unos segundos de la entrante), se pausa la musica y se reproduce. Al acabar, o al
//  parar o salir del editor, se borra el archivo y la musica sigue si sonaba.
//
//  No se puede escuchar mientras hay una mezcla de AutoMix preparada o sonando (pausar en medio no esta probado).
//

import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class MixPreviewPlayer {
    static let shared = MixPreviewPlayer()

    enum State { case idle, preparing, playing }

    private(set) var state = State.idle
    /// Un mensaje corto cuando algo no ha ido bien (se enseña junto al boton).
    private(set) var statusText: String?
    /// Por donde va la escucha (segundos del archivo preparado), para la barra que se mueve por las ondas. 0 si no suena.
    private(set) var position: TimeInterval = 0
    /// Los segundos de la saliente que se oyen antes de la mezcla en este archivo, y lo que dura la mezcla (para colocar la barra).
    private(set) var leadActual: TimeInterval = 0
    private(set) var mixDuration: TimeInterval = 0

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var resumeMusic = false
    /// Cada escucha lleva su numero; parar o empezar otra lo cambia, y una preparacion que vuelve tarde (de una escucha ya cancelada) se
    /// descarta sin tocar la nueva.
    @ObservationIgnored private var generation = 0

    /// Segundos de la saliente que se oyen antes de que empiece la mezcla.
    private static let leadSeconds: TimeInterval = 6
    /// Segundos que se dejan oir despues de la mezcla.
    private static let tailSeconds: TimeInterval = 6

    private init() {}

    func start(outgoingId: String, incomingId: String, plan: TransitionPlan) {
        guard state == .idle else { return }
        statusText = nil
        guard !AutoMixEngine.shared.isActive else {
            statusText = NSLocalizedString("Preview not available during a mix.", comment: "")
            return
        }
        generation += 1
        let mine = generation
        state = .preparing
        task = Task { [weak self] in
            await self?.run(outgoingId: outgoingId, incomingId: incomingId, plan: plan, generation: mine)
        }
    }

    /// Para la escucha (o la preparacion) y devuelve la musica si sonaba. Se puede llamar siempre.
    func stop() {
        generation += 1
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
            fileURL = nil
        }
        if resumeMusic {
            resumeMusic = false
            PlayerController.shared.setPaused(false)
        }
        position = 0
        state = .idle
    }

    /// El segundo de la saliente que suena en la posicion `t` del archivo; `nil` cuando la saliente ya no suena (acabo la mezcla).
    func outgoingSongTime(_ t: TimeInterval, cutAt: Double) -> Double? {
        let mixEnd = leadActual + mixDuration
        return t <= mixEnd + 0.1 ? cutAt - leadActual + min(t, mixEnd) : nil
    }

    /// El segundo de la entrante que suena en la posicion `t` del archivo; `nil` antes de que empiece la mezcla.
    func incomingSongTime(_ t: TimeInterval, inStart: Double) -> Double? {
        t >= leadActual ? inStart + (t - leadActual) : nil
    }

    /// Cuanto va la mezcla en la posicion `t` (0 = empieza, 1 = acaba; negativo antes y mayor que 1 despues).
    func mixProgress(_ t: TimeInterval) -> Double {
        mixDuration > 0 ? (t - leadActual) / mixDuration : 0
    }

    private func fail(generation mine: Int) {
        guard mine == generation else { return }
        statusText = NSLocalizedString("Can't preview right now.", comment: "")
        PlaybackReport.record("mezcla: vista previa no disponible")
        stop()
    }

    private func run(outgoingId: String, incomingId: String, plan: TransitionPlan, generation mine: Int) async {
        guard let outSource = await AutoMixSource.source(for: outgoingId),
              let inSource = await AutoMixSource.source(for: incomingId) else {
            fail(generation: mine)
            return
        }
        guard mine == generation else { return }
        let outURL = outSource.url
        let inURL = inSource.url
        let cutAt = Double(plan.outgoingStartMs) / 1000
        let inStart = Double(plan.incomingStartMs) / 1000
        let duration = Double(plan.durationMs) / 1000
        let outgoingRatio = plan.outgoingSpeedRatio
        let incomingRatio = plan.incomingSpeedRatio
        let plainFade = plan.sound == .fade
        let curveTables: [[Double]]? = plan.curves?.tables()
        let effectKind = plan.curves?.effectKind ?? 0
        let loopBars = plan.curves?.loopBars ?? 0
        let beatSeconds = (TrackAnalysisStore.shared.structure(for: outgoingId, role: .outgoing)?.beatMs ?? 500) / 1000
        let lead = Self.leadSeconds
        let rendered = await Task.detached(priority: .userInitiated) {
            MixRenderer.renderPreview(
                outgoingURL: outURL, outgoingStart: cutAt, incomingURL: inURL, incomingStart: inStart,
                duration: duration, outgoingRatio: outgoingRatio, incomingRatio: incomingRatio, plainFade: plainFade,
                curveTables: curveTables, effectKind: effectKind, loopBars: loopBars, beatSeconds: beatSeconds, leadSeconds: lead
            )
        }.value
        // Si mientras se preparaba se paro o se empezo otra escucha, lo preparado se tira sin tocar la nueva.
        guard mine == generation else {
            if let rendered { try? FileManager.default.removeItem(at: rendered) }
            return
        }
        guard let rendered else {
            fail(generation: mine)
            return
        }
        fileURL = rendered
        guard AutoMixEngine.shared.isActive == false else {
            stop()
            return
        }
        // La musica se pausa mientras suena la escucha; al acabar vuelve si sonaba.
        resumeMusic = NowPlaying.shared.isPlaying
        if resumeMusic { PlayerController.shared.setPaused(true) }
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let audioPlayer = try? AVAudioPlayer(contentsOf: rendered) else {
            fail(generation: mine)
            return
        }
        player = audioPlayer
        audioPlayer.prepareToPlay()
        guard audioPlayer.play() else {
            fail(generation: mine)
            return
        }
        leadActual = min(lead, cutAt)
        mixDuration = duration
        position = 0
        state = .playing
        // Hasta que acabe el archivo o se pase lo previsto (saliente + mezcla + un poco de la entrante). La posicion se actualiza ~20 veces por
        // segundo para la barra que se mueve; solo la leen las vistas de esa barra.
        let limit = leadActual + duration + Self.tailSeconds
        while mine == generation, audioPlayer.isPlaying, audioPlayer.currentTime < limit {
            position = audioPlayer.currentTime
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if mine == generation { stop() }
    }
}
