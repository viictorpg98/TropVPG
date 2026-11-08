//
//  ArtworkLoader.swift
//  Trop
//
// Created by 686udjie on 12/09/2026.
//

import Foundation
import Nuke
import UIKit

/// Shared Nuke access for imperative (non-view) artwork loads. Consolidates
/// the copy-pasted cache-check-then-fetch pairs in NowPlaying,
/// MiniPlayerBarView, DownloadManager and ArtistDetailView.
///
/// Note: `image(for:)` already consults the memory + disk caches before
/// hitting the network, so callers must not pre-check the cache themselves.
enum ArtworkLoader {
    /// Guarda en la cache de imagenes las caratulas tal y como las piden las filas y las tarjetas (mismas direcciones y
    /// mismos tamanos), para que se vean sin conexion: la cache solo sirve si la peticion coincide exactamente.
    @MainActor
    static func prefetchListVariants(thumbnailUrl: String?) async {
        guard let thumbnailUrl else { return }
        let scale = UIScreen.main.scale
        for points in [120.0, 160.0] as [CGFloat] {
            let pixels = points * scale
            let ladder = ArtworkURLs.rung(for: pixels)
            guard let url = URL(string: normalizeThumbnailURL(thumbnailUrl, pixels: ladder)) else { continue }
            let request = ImageRequest(
                url: url,
                processors: [.resize(size: CGSize(width: pixels, height: pixels), unit: .pixels, contentMode: .aspectFill)]
            )
            _ = try? await ImagePipeline.shared.image(for: request)
        }
    }

    /// Caratulas de lo que ya estaba descargado antes de existir esto: se guardan de poco en poco, una vez cada una.
    @MainActor
    static func backfillDownloads(_ tracks: [DownloadedTrackEntity]) async {
        let key = "artwork.prefetchedIds"
        var done = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        var count = 0
        for track in tracks where !done.contains(track.id) {
            guard count < 150 else { break }
            await prefetchListVariants(thumbnailUrl: track.thumbnailUrl)
            done.insert(track.id)
            count += 1
        }
        if count > 0 { UserDefaults.standard.set(Array(done), forKey: key) }
    }

    /// Cached image without hitting the network (nil on cache miss).
    static func cachedImage(for url: URL) -> UIImage? {
        ImagePipeline.shared.cache.cachedImage(for: ImageRequest(url: url), caches: .all)?.image
    }

    /// Cached image when present, otherwise fetches (and caches) it.
    static func image(for url: URL) async throws -> UIImage {
        try await ImagePipeline.shared.image(for: url)
    }

    /// Best-effort cache warm, never throws.
    static func warm(_ url: URL) {
        Task { _ = try? await ImagePipeline.shared.image(for: url) }
    }
}

/// App-side artwork helpers. CDN size rewriting lives in SwiftyTube's
/// `ArtworkURLs`; this is only what the app adds on top.
enum ArtworkURLs {
    /// i.ytimg fallback artwork for a video id.
    static func fallback(for videoId: String) -> String {
        SwiftyTube.ArtworkURLs.fallback(for: videoId)
    }

    /// Rewrites a `w<N>-h<N>` thumbnail URL to the requested square size.
    static func sized(_ url: String?, width: Int, height: Int) -> String? {
        SwiftyTube.ArtworkURLs.sized(url, width: width, height: height)
    }

    // MARK: - Size ladder

    /// Smallest ladder rung covering `pixels` (never below the row rung).
    static func rung(for pixels: CGFloat) -> Int {
        SwiftyTube.ArtworkURLs.rung(for: pixels)
    }

    // MARK: - CDN upgrade

    /// Convenience: artwork at the player rung.
    static func highRes(_ url: String?) -> String? {
        SwiftyTube.ArtworkURLs.highRes(url)
    }

    /// 1280px variant of a ytimg thumbnail URL.
    static func maxResVariant(_ url: String?) -> String? {
        SwiftyTube.ArtworkURLs.maxResVariant(url)
    }

    /// 640px variant. Exists far more often than maxres, beats hqdefault.
    static func sdVariant(_ url: String?) -> String? {
        SwiftyTube.ArtworkURLs.sdVariant(url)
    }
}
