//
//  SonarClients.swift
//  Trop
//
//  La cadena de clientes de YouTube con la que Sonar pide el audio (antes salia de SwiftyTube: VISIONOS, tres ANDROID_VR, TVHTML5_SIMPLY_EMBEDDED,
//  IOS, TVHTML5, ANDROID y WEB_REMIX al final). Varios de esos clientes ya no sirven: IOS y ANDROID solo dan SABR (formatos sin direccion), el
//  cliente "embedded" responde "YouTube is no longer supported" y yt-dlp quito ANDROID_VR de sus clientes por defecto en agosto. La cadena nueva
//  sigue la de yt-dlp (VISIONOS, tv_samsung, mweb, TVHTML5_SIMPLY), añade el audio HLS de iOS como plan B (sin token, pero no todas las
//  canciones lo ofrecen) y deja WEB_REMIX el ultimo.
//

import Foundation

enum SonarClients {
    /// El mismo User-Agent con el que mpv abre las direcciones: la comprobacion previa de cada direccion usa este (si no, una direccion que
    /// las comprobaciones dan por buena puede dar 403 al reproductor).
    static let playerUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15" +
        " (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private static let cobaltUserAgent = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko)," +
        " Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)"

    /// VISIONOS con la identidad actual de yt-dlp (la de SwiftyTube, 0.1, es la antigua). Direcciones directas, sin token.
    static let visionOS102 = YouTubeClient(
        clientName: "VISIONOS",
        clientVersion: "1.02",
        clientId: 101,
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        useMusicPlayerEndpoint: true,
        skipPlayerResponseValidation: true,
        osName: "visionOS",
        osVersion: "26.5.23O471",
        deviceMake: "Apple",
        deviceModel: "RealityDevice17,1"
    )

    /// TVHTML5 de un Samsung (el cliente principal de yt-dlp desde octubre): no necesita token, la direccion viene cifrada y se descifra con
    /// el reproductor de YouTube (el modulo de cifrado de SwiftyTube).
    static let tvSamsung = YouTubeClient(
        clientName: "TVHTML5",
        clientVersion: "5.20260707",
        clientId: 7,
        userAgent: "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1",
        loginSupported: true,
        includeUserAgentInContext: true,
        useSignatureTimestamp: true,
        osName: "Tizen",
        osVersion: "2.4.0",
        deviceMake: "Samsung",
        deviceModel: "UKS9800"
    )

    /// MWEB: el que recomienda yt-dlp junto a un proveedor de token (la direccion lleva el token de BotGuard).
    static let mweb = YouTubeClient(
        clientName: "MWEB",
        clientVersion: "2.20260708.05.00",
        clientId: 2,
        userAgent: "Mozilla/5.0 (iPad; CPU OS 16_7_10 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1,gzip(gfe)",
        loginSupported: true,
        includeUserAgentInContext: true,
        useSignatureTimestamp: true,
        useWebPoTokens: true
    )

    /// TVHTML5_SIMPLY con la identidad de yt-dlp (la "embedded" de SwiftyTube ya no responde).
    static let tvSimply = YouTubeClient(
        clientName: "TVHTML5_SIMPLY",
        clientVersion: "1.0",
        clientId: 75,
        userAgent: cobaltUserAgent,
        useSignatureTimestamp: true,
        useWebPoTokens: true
    )

    /// Un paso de la cadena: un cliente de YouTube o el audio HLS.
    enum ChainEntry: Sendable {
        case client(FallbackClient)
        case hls

        var name: String {
            switch self {
            case .client(let entry): return entry.client.clientName
            case .hls: return "HLS"
            }
        }

        var isClient: Bool {
            if case .client = self { return true }
            return false
        }
    }

    /// Orden: primero los que no necesitan token ni cifrado, luego los de token, el HLS de iOS y, el ultimo, WEB_REMIX (el que da direcciones
    /// que la comprobacion da por buenas y luego el reproductor rechaza con 403).
    static var chain: [ChainEntry] {
        [
            .client(FallbackClient(client: visionOS102, skipValidation: false)),
            .client(FallbackClient(client: .visionOS, skipValidation: false)),
            .client(FallbackClient(client: tvSamsung, skipValidation: false)),
            .client(FallbackClient(client: mweb, skipValidation: false)),
            .client(FallbackClient(client: tvSimply, skipValidation: false)),
            .hls,
            .client(FallbackClient(client: .webRemix, skipValidation: false))
        ]
    }

    /// Clientes cuya direccion lleva el token (`&pot=`) de BotGuard.
    static let tokenClientNames: Set<String> = ["WEB_REMIX", "MWEB", "TVHTML5_SIMPLY"]
}

/// Quien genera los tokens de BotGuard. Tras un 403 de una direccion con token se crea un generador nuevo (como hace Metrolist con la
/// atestacion), como mucho una vez cada 5 minutos.
actor PoTokenSource {
    static let shared = PoTokenSource()

    private var generator = PoTokenGenerator.shared
    private var lastReset = Date.distantPast

    func generate(videoId: String, sessionId: String?) async throws -> PoTokenResult {
        try await generator.generate(videoId: videoId, sessionId: sessionId)
    }

    /// `true` si se ha creado un generador nuevo (no si se hizo hace menos de 5 minutos).
    func invalidate() -> Bool {
        guard Date().timeIntervalSince(lastReset) > 300 else { return false }
        lastReset = Date()
        generator = PoTokenGenerator()
        return true
    }
}

/// Audio de la lista HLS del cliente iOS (y de VISIONOS): pistas de solo audio (AAC) que se bajan sin token. No todas las canciones tienen
/// lista HLS (en las pruebas, solo un video normal; ninguna de las canciones del informe), asi que es un plan B parcial.
enum SonarHLS {
    struct Outcome: Sendable {
        let result: PlaybackResult?
        let hadManifest: Bool
        let requests: Int
    }

    private struct Info: Sendable {
        let manifest: String
        let title: String?
        let author: String?
        let duration: Int?
        let musicVideoType: String?
        let expiresInSeconds: Int
    }

    static func resolve(videoId: String) async -> Outcome {
        var requests = 0
        var hadManifest = false
        for client in [YouTubeClient.iOS, SonarClients.visionOS102] {
            requests += 1
            guard let json = try? await InnerTubeClient.tropShared.player(videoId: videoId, client: client),
                  let info = Self.info(from: json) else { continue }
            hadManifest = true
            guard let audio = await audioPlaylist(manifest: info.manifest) else { continue }
            let result = PlaybackResult(
                streamUrl: audio.url,
                itag: audio.itag,
                mimeType: "application/x-mpegURL",
                bitrate: audio.itag == 234 ? 128_000 : 48_000,
                audioQuality: audio.itag == 234 ? "AUDIO_QUALITY_MEDIUM" : "AUDIO_QUALITY_LOW",
                videoId: videoId,
                title: info.title,
                author: info.author,
                duration: info.duration,
                expiresInSeconds: info.expiresInSeconds,
                clientName: "HLS",
                musicVideoType: info.musicVideoType,
                hasVideoContent: false,
                muxedStreamUrl: nil,
                loudnessDb: nil
            )
            return Outcome(result: result, hadManifest: true, requests: requests)
        }
        return Outcome(result: nil, hadManifest: hadManifest, requests: requests)
    }

    private static func info(from json: [String: Any]) -> Info? {
        let status = (json["playabilityStatus"] as? [String: Any])?["status"] as? String
        guard status == "OK",
              let streaming = json["streamingData"] as? [String: Any],
              let manifest = streaming["hlsManifestUrl"] as? String, !manifest.isEmpty else { return nil }
        let details = json["videoDetails"] as? [String: Any]
        return Info(
            manifest: manifest,
            title: details?["title"] as? String,
            author: details?["author"] as? String,
            duration: (details?["lengthSeconds"] as? String).flatMap { Int($0) },
            musicVideoType: details?["musicVideoType"] as? String,
            expiresInSeconds: (streaming["expiresInSeconds"] as? String).flatMap { Int($0) } ?? 0
        )
    }

    /// La pista de solo audio de mejor calidad de la lista maestra (itag 234, AAC ~128 kbps; si no, la 233, HE-AAC ~48 kbps).
    private static func audioPlaylist(manifest: String) async -> (url: String, itag: Int)? {
        guard let url = URL(string: manifest) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue(SonarClients.playerUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return nil }
        var best: (url: String, itag: Int)?
        for line in text.components(separatedBy: "\n") where line.hasPrefix("#EXT-X-MEDIA:") && line.contains("TYPE=AUDIO") {
            guard let uri = attribute("URI", in: line), let itag = itag(in: uri) else { continue }
            if best == nil || rank(itag) > rank(best?.itag ?? 0) { best = (uri, itag) }
        }
        return best
    }

    private static func rank(_ itag: Int) -> Int {
        switch itag {
        case 234: return 2
        case 233: return 1
        default: return 0
        }
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        guard let start = line.range(of: "\(name)=\"") else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private static func itag(in uri: String) -> Int? {
        guard let start = uri.range(of: "/itag/") else { return nil }
        let digits = uri[start.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }
}
