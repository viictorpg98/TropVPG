//
//  DownloadBadges.swift
//  Trop
//

import Combine
import SwiftUI

/// Marcas de "descargada" para mostrar en cualquier sitio donde salga una cancion. Cada una escucha
/// solo el estado de SU cancion, asi que no se redibuja cuando avanza cualquier otra descarga.

/// Linea de texto (artista, subtitulo...) con una marca de "descargada" delante cuando lo esta.
/// Hereda fuente y color de quien la use, para que la marca y el texto vayan a juego.
struct SubtitleWithDownloadMark: View {
    let videoId: String?
    let text: String

    @State private var isDownloaded: Bool

    init(videoId: String?, text: String) {
        self.videoId = videoId
        self.text = text
        _isDownloaded = State(initialValue: videoId.map { DownloadManager.shared.isDownloaded(videoId: $0) } ?? false)
    }

    var body: some View {
        HStack(spacing: 4) {
            if isDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .imageScale(.small)
                    .accessibilityLabel("Downloaded")
            }
            Text(text)
        }
        .task(id: videoId) {
            guard let videoId else {
                isDownloaded = false
                return
            }
            for await state in DownloadManager.shared.statePublisher(for: videoId).values {
                isDownloaded = (state == .completed)
            }
        }
    }
}

/// Marca en la esquina de una caratula (tarjetas y cuadrículas).
struct DownloadedCornerBadge: View {
    let videoId: String

    @State private var isDownloaded: Bool

    init(videoId: String) {
        self.videoId = videoId
        _isDownloaded = State(initialValue: DownloadManager.shared.isDownloaded(videoId: videoId))
    }

    var body: some View {
        ZStack {
            if isDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.55))
                    .padding(5)
                    .accessibilityLabel("Downloaded")
            }
        }
        .task(id: videoId) {
            for await state in DownloadManager.shared.statePublisher(for: videoId).values {
                isDownloaded = (state == .completed)
            }
        }
    }
}

extension View {
    /// Pone la marca de "descargada" en una esquina si la cancion lo esta (no hace nada si `videoId` es nil).
    func downloadedBadge(videoId: String?, alignment: Alignment = .bottomTrailing) -> some View {
        overlay(alignment: alignment) {
            if let videoId {
                DownloadedCornerBadge(videoId: videoId)
            }
        }
    }
}
