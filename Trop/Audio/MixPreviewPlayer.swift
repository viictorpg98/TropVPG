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

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var resumeMusic = false

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
        state = .preparing
        task = Task { [weak self] in
            await self?.run(outgoingId: outgoingId, incomingId: incomingId, plan: plan)
        }
    }

    /// Para la escucha (o la preparacion) y devuelve la musica si sonaba. Se puede llamar siempre.
    func stop() {
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
        state = .idle
    }

    private func fail() {
        statusText = NSLocalizedString("Can't preview right now.", comment: "")
        PlaybackReport.record("mezcla: vista previa no disponible")
        stop()
    }

    private func run(outgoingId: String, incomingId: String, plan: TransitionPlan) async {
        guard let outSource = await AutoMixSource.source(for: outgoingId),
              let inSource = await AutoMixSource.source(for: incomingId), !Task.isCancelled else {
            fail()
            return
        }
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
        guard let rendered else {
            fail()
            return
        }
        fileURL = rendered
        guard !Task.isCancelled, AutoMixEngine.shared.isActive == false else {
            stop()
            return
        }
        // La musica se pausa mientras suena la escucha; al acabar vuelve si sonaba.
        resumeMusic = NowPlaying.shared.isPlaying
        if resumeMusic { PlayerController.shared.setPaused(true) }
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let audioPlayer = try? AVAudioPlayer(contentsOf: rendered) else {
            fail()
            return
        }
        player = audioPlayer
        audioPlayer.prepareToPlay()
        guard audioPlayer.play() else {
            fail()
            return
        }
        state = .playing
        // Hasta que acabe el archivo o se pase lo previsto (saliente + mezcla + un poco de la entrante).
        let limit = min(lead, cutAt) + duration + Self.tailSeconds
        while !Task.isCancelled, audioPlayer.isPlaying, audioPlayer.currentTime < limit {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        stop()
    }
}
