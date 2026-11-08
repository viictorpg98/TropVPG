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

    private init() {}

    /// Prepara la carátula, los colores y el titulo de la que va a entrar (se llama unos segundos antes).
    func prepare(song: SongItem) {
        guard incomingVideoId != song.videoId else { return }
        incomingVideoId = song.videoId
        incomingImage = nil
        incomingColors = []
        incomingEdgeColor = nil
        incomingTitle = song.title
        incomingArtist = artistDisplayString(from: song.artists)
        let videoId = song.videoId
        let thumbnail = song.thumbnailUrl
        Task { [weak self] in
            var image: UIImage?
            if let url = await DownloadManager.shared.localURL(for: videoId) {
                image = await Self.embeddedArtwork(url)
            }
            if image == nil, let thumbnail, let url = URL(string: ArtworkURLs.highRes(thumbnail) ?? thumbnail) {
                image = try? await ImagePipeline.shared.image(for: url)
            }
            guard let self, self.incomingVideoId == videoId, let image else { return }
            let square = image.centerCroppedSquare()
            self.incomingImage = square
            self.incomingColors = square.extractDominantColors()
            self.incomingEdgeColor = square.bottomEdgeColor()
        }
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
