//
//  AnimatedArtworkView.swift
//  Trop
//
//  El video en bucle (mudo) que se pone encima de la caratula del reproductor grande cuando la cancion tiene uno.
//

import AVFoundation
import SwiftUI
import UIKit

/// Se superpone a la caratula: aparece con un fundido cuando el video ya se esta dibujando y se quita sola si no hay video,
/// si esta desactivado en ajustes, en modo de bajo consumo, con "reducir movimiento" o durante una mezcla de AutoMix.
struct AnimatedArtworkLayer: View {
    private let np = NowPlaying.shared
    private let settings = SettingsStore.shared
    private let visuals = AutoMixVisuals.shared

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var url: URL?
    @State private var isShowing = false

    private var allowed: Bool {
        settings.animatedArtworkEnabled && !reduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled
            && !np.isVideoMode
    }

    var body: some View {
        ZStack {
            if let url, allowed {
                LoopingVideoView(url: url, isPlaying: scenePhase == .active && !visuals.isMixing) { ready in
                    withAnimation(.easeInOut(duration: 0.6)) { isShowing = ready }
                }
                .opacity(isShowing && !visuals.isMixing ? 1 : 0)
                .animation(.easeInOut(duration: 0.5), value: visuals.isMixing)
                .id(url)
            }
        }
        .allowsHitTesting(false)
        .task(id: "\(np.videoId ?? "")|\(allowed)|\(settings.animatedArtworkUsesMobileData)") {
            isShowing = false
            url = nil
            guard allowed, let videoId = np.videoId else { return }
            let title = np.title
            let artist = np.displayArtist
            let album = np.albumTitle.isEmpty ? nil : np.albumTitle
            guard !title.isEmpty, !artist.isEmpty else { return }
            let found = await AnimatedArtworkService.shared.url(videoId: videoId, title: title, artist: artist, album: album)
            // La cancion puede haber cambiado mientras se buscaba.
            if !Task.isCancelled, np.videoId == videoId { url = found }
        }
    }
}

// MARK: - Reproductor en bucle

private struct LoopingVideoView: UIViewRepresentable {
    let url: URL
    let isPlaying: Bool
    let onReady: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.isUserInteractionEnabled = false
        view.playerLayer.videoGravity = .resizeAspectFill
        context.coordinator.start(url: url, in: view, onReady: onReady)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        context.coordinator.setPlaying(isPlaying)
    }

    static func dismantleUIView(_ view: PlayerLayerView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    final class Coordinator {
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var readyObservation: NSKeyValueObservation?
        private var wantsPlaying = true

        func start(url: URL, in view: PlayerLayerView, onReady: @escaping (Bool) -> Void) {
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
            looper = AVPlayerLooper(player: queue, templateItem: item)
            player = queue
            view.playerLayer.player = queue

            readyObservation = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
                let ready = layer.isReadyForDisplay
                DispatchQueue.main.async { onReady(ready) }
            }
            if wantsPlaying { queue.play() }
        }

        func setPlaying(_ playing: Bool) {
            wantsPlaying = playing
            if playing { player?.play() } else { player?.pause() }
        }

        func stop() {
            readyObservation = nil
            player?.pause()
            looper?.disableLooping()
            looper = nil
            player = nil
        }
    }
}
