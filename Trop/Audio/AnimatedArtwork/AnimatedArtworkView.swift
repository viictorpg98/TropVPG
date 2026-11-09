//
//  AnimatedArtworkView.swift
//  Trop
//
//  El video en bucle (mudo) que se pone encima de la caratula del reproductor grande cuando la cancion tiene uno.
//

import AVFoundation
import SwiftUI
import UIKit

// MARK: - Reproductores compartidos

/// Un reproductor por video, compartido entre las vistas que lo enseñan. Asi el video de la cancion que entra en una mezcla de
/// AutoMix (que ya esta sonando en la zona de la nueva) sigue sin reiniciarse cuando esa cancion pasa a ser la actual.
@MainActor
final class AnimatedVideoPool {
    static let shared = AnimatedVideoPool()

    private final class Entry {
        let player: AVQueuePlayer
        let looper: AVPlayerLooper
        var lastUsed = Date()
        var shown = false
        var attachments = 0
        init(player: AVQueuePlayer, looper: AVPlayerLooper) {
            self.player = player
            self.looper = looper
        }
    }

    private var entries: [URL: Entry] = [:]
    private let capacity = 3

    private init() {}

    func player(for url: URL) -> AVQueuePlayer {
        if let entry = entries[url] {
            entry.lastUsed = Date()
            return entry.player
        }
        let item = AVPlayerItem(url: url)
        // Un video sin sonido: no debe tocar el audio de la app ni pedir mas ancho de banda del necesario.
        item.preferredForwardBufferDuration = 4
        item.preferredPeakBitRate = 6_000_000
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.volume = 0
        queue.allowsExternalPlayback = false
        queue.preventsDisplaySleepDuringVideoPlayback = false
        queue.audiovisualBackgroundPlaybackPolicy = .pauses
        let looper = AVPlayerLooper(player: queue, templateItem: item)
        entries[url] = Entry(player: queue, looper: looper)
        evict(keeping: url)
        return queue
    }

    /// Lo deja cargando y en marcha antes de que se necesite (el video de la cancion que va a entrar).
    func warm(_ url: URL) {
        player(for: url).play()
    }

    func touch(_ url: URL) { entries[url]?.lastUsed = Date() }
    func markShown(_ url: URL) { entries[url]?.shown = true }
    func wasShown(_ url: URL) -> Bool { entries[url]?.shown ?? false }

    func attach(_ url: URL) { entries[url]?.attachments += 1 }

    /// Cuando ninguna vista lo enseña, se para (para no gastar bateria).
    func detach(_ url: URL) {
        guard let entry = entries[url] else { return }
        entry.attachments = max(0, entry.attachments - 1)
        if entry.attachments == 0 { entry.player.pause() }
    }

    private func evict(keeping keep: URL) {
        while entries.count > capacity {
            guard let oldest = entries.filter({ $0.key != keep && $0.value.attachments == 0 })
                .min(by: { $0.value.lastUsed < $1.value.lastUsed }) else { return }
            oldest.value.player.pause()
            oldest.value.looper.disableLooping()
            entries[oldest.key] = nil
        }
    }
}

// MARK: - Capa de la cancion actual

/// Se superpone a la caratula: aparece con un fundido cuando el video ya se esta dibujando y se quita sola si no hay video,
/// si esta desactivado en ajustes, en modo de bajo consumo o con "reducir movimiento". Durante una mezcla de AutoMix
/// sigue en marcha (se desenfoca y se cubre con la nueva igual que la caratula).
struct AnimatedArtworkLayer: View {
    private let np = NowPlaying.shared
    private let settings = SettingsStore.shared

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var url: URL?
    @State private var isShowing = false

    /// Por que no se busca ni se enseña el video (nil si se puede). Se apunta en el informe.
    private var blockReason: String? {
        if !settings.animatedArtworkEnabled { return "ajuste apagado" }
        if reduceMotion { return "Reducir movimiento activado" }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "modo de bajo consumo" }
        if np.isVideoMode { return "modo video" }
        return nil
    }

    private var allowed: Bool { blockReason == nil }

    var body: some View {
        ZStack {
            if let url, allowed {
                LoopingVideoView(url: url, isPlaying: scenePhase == .active) { ready in
                    let quick = ready && AnimatedVideoPool.shared.wasShown(url)
                    withAnimation(.easeInOut(duration: quick ? 0.12 : 0.6)) { isShowing = ready }
                }
                .opacity(isShowing ? 1 : 0)
                .id(url)
            }
        }
        .allowsHitTesting(false)
        .task(id: "\(np.videoId ?? "")|\(allowed)|\(settings.animatedArtworkUsesMobileData)") {
            isShowing = false
            url = nil
            guard let videoId = np.videoId else { return }
            AnimatedArtworkService.shared.note(videoId, "el reproductor grande la pide")
            if let reason = blockReason ?? AnimatedArtworkService.shared.networkBlockReason {
                AnimatedArtworkService.shared.note(videoId, "no se busca (\(reason))")
                return
            }
            let title = np.title
            let artist = np.displayArtist
            let album = np.albumTitle.isEmpty ? nil : np.albumTitle
            guard !title.isEmpty, !artist.isEmpty else {
                AnimatedArtworkService.shared.note(videoId, "no se busca (sin titulo o artista todavia)")
                return
            }
            let found = await AnimatedArtworkService.shared.url(videoId: videoId, title: title, artist: artist, album: album)
            // La cancion puede haber cambiado mientras se buscaba.
            guard !Task.isCancelled, np.videoId == videoId else { return }
            if let found {
                // Si ya se estaba enseñando (venia de una mezcla), no se vuelve a hacer aparecer.
                isShowing = AnimatedVideoPool.shared.wasShown(found)
            }
            url = found
        }
    }
}

// MARK: - Capa de la cancion que entra (durante una mezcla)

/// El video de la cancion que va a entrar, dentro de la zona que se va revelando en la mezcla.
struct IncomingArtworkVideo: View {
    let url: URL
    @State private var ready = false

    var body: some View {
        LoopingVideoView(url: url, isPlaying: true) { isReady in
            withAnimation(.easeInOut(duration: 0.3)) { ready = isReady }
        }
        .opacity(ready ? 1 : 0)
        .allowsHitTesting(false)
    }
}

// MARK: - Reproductor en bucle

struct LoopingVideoView: UIViewRepresentable {
    let url: URL
    let isPlaying: Bool
    let onReady: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.isUserInteractionEnabled = false
        view.playerLayer.videoGravity = .resizeAspectFill
        context.coordinator.attach(url: url, to: view, playing: isPlaying, onReady: onReady)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        context.coordinator.setPlaying(isPlaying)
        AnimatedVideoPool.shared.touch(url)
    }

    static func dismantleUIView(_ view: PlayerLayerView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    @MainActor
    final class Coordinator {
        private var url: URL?
        private weak var view: PlayerLayerView?
        private var readyObservation: NSKeyValueObservation?
        private var wantsPlaying = true

        func attach(url: URL, to view: PlayerLayerView, playing: Bool, onReady: @escaping (Bool) -> Void) {
            self.url = url
            self.view = view
            wantsPlaying = playing
            let pool = AnimatedVideoPool.shared
            let player = pool.player(for: url)
            pool.attach(url)
            view.playerLayer.player = player

            readyObservation = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
                let ready = layer.isReadyForDisplay
                Task { @MainActor in
                    if ready { AnimatedVideoPool.shared.markShown(url) }
                    onReady(ready)
                }
            }
            if playing { player.play() }
        }

        func setPlaying(_ playing: Bool) {
            wantsPlaying = playing
            guard let url else { return }
            let player = AnimatedVideoPool.shared.player(for: url)
            if playing { player.play() } else { player.pause() }
        }

        func detach() {
            readyObservation = nil
            view?.playerLayer.player = nil
            if let url { AnimatedVideoPool.shared.detach(url) }
            url = nil
        }
    }
}
