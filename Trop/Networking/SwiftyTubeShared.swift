//
//  SwiftyTubeShared.swift
//  Trop
//
//  Created by 686udjie on 03/10/2026.
//

@_exported import SwiftyTube

/// Shared InnerTube client for the music service (replaces `InnerTube.shared`).
extension InnerTubeClient {
    static let tropShared = InnerTubeClient(config: .music)
}

extension CookieStore: AuthStateProvider {}

/// Mirrors the old behavior of reading the region from settings per request.
extension InnerTubeClient {
    func syncTropLocale() {
        let country = SettingsStore.shared.contentCountry
        updateLocale(YouTubeLocale(gl: country.isEmpty ? "US" : country, hl: "en"))
    }
}

extension YouTubeLocale {
    /// Misma region que el resto de la app pero con el idioma del dispositivo. Se usa solo en lo que
    /// ensena titulos de podcasts: pidiendolos en ingles, YouTube los devuelve traducidos al ingles
    /// aunque el podcast sea en espanol. El resto de la app sigue en ingles porque interpreta textos.
    static var deviceLanguage: YouTubeLocale {
        let country = SettingsStore.shared.contentCountry
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return YouTubeLocale(gl: country.isEmpty ? "US" : country, hl: language)
    }
}

/// Live cipher/PoToken/format-sink wiring for stream resolution.
extension StreamResolveProviders {
    static var tropLive: StreamResolveProviders {
        var providers = StreamResolveProviders.live
        providers.poTokenProvider = { videoId in
            try? await PoTokenGenerator.shared.generate(
                videoId: videoId,
                sessionId: PlaybackManager.sessionId
            )
        }
        providers.resolvedFormatHandler = { info in
            _ = try? await DatabaseService.shared.insertOrReplace(FormatEntity(
                id: info.videoId,
                itag: info.itag,
                mimeType: info.mimeType,
                codecs: info.codecs,
                bitrate: info.bitrate,
                sampleRate: 0,
                contentLength: info.contentLength,
                loudnessDb: info.loudnessDb,
                perceptualLoudnessDb: nil,
                playbackUrl: info.playbackUrl
            ))
        }
        return providers
    }
}
