//
//  AutoMixVisuals.swift
//  Trop
//

import AVFoundation
import Nuke
import Observation
import SwiftUI
import UIKit

/// Lo que el reproductor grande necesita para dibujar una mezcla de AutoMix: en que punto va, la carátula,
/// los colores y el titulo de la cancion que entra, y la fase del pulso para el latido.
@Observable
@MainActor
final class AutoMixVisuals {
    static let shared = AutoMixVisuals()

    /// Hay una mezcla en marcha (incluye el relevo final).
    var isMixing = false
    /// 0...1: lo avanzada que va la mezcla.
    var progress = 0.0
    /// 0...1: fase del pulso (0 = justo en el pulso).
    var beatPhase = 0.0
    /// El pulso solo se anima mientras las dos suenan a la vez.
    var pulsing = false

    var outgoingImage: UIImage?
    var outgoingColors: [Color] = []
    var outgoingEdgeColor: Color?
    var incomingEdgeColor: Color?
    var incomingImage: UIImage?
    var incomingColors: [Color] = []
    var incomingTitle = ""
    var incomingArtist = ""
    var incomingVideoId: String?
    /// El video en bucle de la cancion que entra (si tiene), ya cargandose para que este listo cuando se revele.
    var incomingVideoURL: URL?
    private var incomingCoverIsApple = false

    private init() {}

    /// Prepara la carátula, los colores y el titulo de la que va a entrar (se llama unos segundos antes).
    func prepare(song: SongItem) {
        guard incomingVideoId != song.videoId else { return }
        incomingVideoId = song.videoId
        incomingImage = nil
        incomingColors = []
        incomingEdgeColor = nil
        incomingVideoURL = nil
        incomingCoverIsApple = false
        incomingTitle = song.title
        incomingArtist = artistDisplayString(from: song.artists)
        let videoId = song.videoId
        let thumbnail = song.thumbnailUrl
        // Video y caratula de alta calidad (Apple Music / TIDAL), si los hay.
        Task { [weak self] in
            let service = AnimatedArtworkService.shared
            let wantsVideo = service.blockReason == nil
            let wantsCover = SettingsStore.shared.preferAppleCovers
            guard wantsVideo || wantsCover, let info = await service.info(for: song) else { return }
            guard let self, self.incomingVideoId == videoId else { return }
            if wantsVideo, let video = info.video {
                self.incomingVideoURL = video
                AnimatedVideoPool.shared.warm(video)
            }
            if wantsCover, let cover = info.cover, let image = try? await ArtworkLoader.image(for: cover),
               self.incomingVideoId == videoId {
                self.apply(image, apple: true)
            }
        }
        Task { [weak self] in
            // 1) La incrustada en el archivo descargado, para tener algo enseguida.
            var best: UIImage?
            if let url = await DownloadManager.shared.localURL(for: videoId) {
                best = await Self.embeddedArtwork(url)
                if let best, let self, self.incomingVideoId == videoId { self.apply(best) }
            }
            // 2) Si es pequena (o no hay), la mejor de internet, como hace el reproductor: la de la propia cancion a
            //    maxima resolucion, luego variantes menores y, por ultimo, la miniatura de YouTube.
            if best == nil || Self.pixelSide(best) < 900 {
                for url in Self.candidates(videoId: videoId, thumbnail: thumbnail) {
                    guard let self, self.incomingVideoId == videoId else { return }
                    let found: UIImage?
                    if let cached = ArtworkLoader.cachedImage(for: url) {
                        found = cached
                    } else {
                        found = try? await ArtworkLoader.image(for: url)
                    }
                    if let found {
                        if Self.pixelSide(found) > Self.pixelSide(best) { self.apply(found) }
                        break
                    }
                }
            }
        }
    }

    private func apply(_ image: UIImage, apple: Bool = false) {
        // La de Apple Music manda: las demas (incrustada, internet) no la pisan.
        if incomingCoverIsApple, !apple { return }
        if apple { incomingCoverIsApple = true }
        let square = image.centerCroppedSquare()
        incomingImage = square
        incomingColors = square.extractDominantColors()
        incomingEdgeColor = square.bottomEdgeColor()
    }

    nonisolated private static func pixelSide(_ image: UIImage?) -> CGFloat {
        guard let image else { return 0 }
        return min(image.size.width, image.size.height) * image.scale
    }

    /// Las mismas direcciones que usa el reproductor para la carátula, de mejor a peor.
    private static func candidates(videoId: String, thumbnail: String?) -> [URL] {
        var urls: [String] = []
        if let upgraded = ArtworkURLs.highRes(thumbnail) {
            if let maxRes = ArtworkURLs.maxResVariant(upgraded) { urls.append(maxRes) }
            if let standard = ArtworkURLs.sdVariant(upgraded) { urls.append(standard) }
            urls.append(upgraded)
        }
        let fallback = NowPlaying.artworkURL(for: videoId)
        if !urls.contains(fallback) { urls.append(fallback) }
        return urls.compactMap(URL.init(string:))
    }

    func begin() {
        outgoingImage = NowPlaying.shared.thumbnailUIImage
        outgoingColors = NowPlaying.shared.dominantColors
        outgoingEdgeColor = NowPlaying.shared.artworkEdgeColor
        progress = 0
        beatPhase = 0
        pulsing = true
        isMixing = true
    }

    func end() {
        // El progreso se queda como esta: el resplandor se apaga con un fundido y conserva los colores de la entrante.
        isMixing = false
        pulsing = false
    }

    /// La caratula incrustada en el archivo descargado.
    nonisolated private static func embeddedArtwork(_ url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.metadata) else { return nil }
        for item in metadata {
            if let data = try? await item.load(.dataValue), let image = UIImage(data: data) { return image }
        }
        return nil
    }
}
