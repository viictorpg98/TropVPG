//
//  AnimatedArtworkService.swift
//  Trop
//
//  Busca el video en bucle y la caratula de alta calidad de una cancion. La idea (y el orden de fuentes: Apple Music, luego
//  TIDAL) viene de LastWave (github.com/Clash-Projects/LastWave-Native, GPL-3.0); el codigo es propio, reescrito en Swift.
//
//  - Apple Music: "motion artwork" (`editorialVideo` del catalogo), un video HLS, y su caratula grande. Usa el token de
//    invitado de su web.
//  - TIDAL: "video cover" cuadrado de 1280x1280 y la caratula del album en su buscador publico.
//
//  Son accesos no oficiales y pueden dejar de funcionar sin aviso: si algo falla, no hay video y se ve la caratula de siempre.
//

import Foundation
import UIKit

@MainActor
final class AnimatedArtworkService {
    static let shared = AnimatedArtworkService()

    /// Lo que se ha encontrado para una cancion: el video en bucle y/o la caratula grande.
    struct Info: Codable, Sendable {
        var video: URL?
        var cover: URL?
        var source = ""
    }

    private enum Entry {
        case hit(Info)
        case miss(Date)
    }

    private var cache: [String: Entry] = [:]
    private var inflight: [String: Task<Info?, Never>] = [:]
    private let missRetry: TimeInterval = 15 * 60

    private static let storeKey = "animatedArtwork.cache.v1"

    private init() {
        // Lo ya encontrado se recuerda entre arranques: asi la carátula buena sale al instante, sin ver antes la de YouTube.
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode([String: Info].self, from: data) {
            for (videoId, info) in saved { cache[videoId] = .hit(info) }
        }
    }

    private func persistHits() {
        var hits: [String: Info] = [:]
        for (videoId, entry) in cache {
            if case .hit(let info) = entry { hits[videoId] = info }
        }
        if hits.count > 300 { hits = Dictionary(uniqueKeysWithValues: hits.prefix(300).map { ($0.key, $0.value) }) }
        if let data = try? JSONEncoder().encode(hits) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
    }

    /// Lo encontrado antes para esta cancion (sin buscar nada).
    func cachedInfo(forVideoId videoId: String) -> Info? {
        if case .hit(let info) = cache[videoId] { return info }
        return nil
    }

    /// Empieza a buscar en segundo plano (por ejemplo al pulsar una cancion, mientras carga su audio), para que la
    /// carátula buena ya este cuando suene.
    func prefetch(_ song: SongItem) {
        guard wantsLookup, cache[song.videoId] == nil else { return }
        Task { _ = await info(for: song) }
    }

    // MARK: - Cuando se puede usar

    /// Hay algo que buscar (video o caratulas de Apple Music) y la red lo permite.
    var wantsLookup: Bool {
        let settings = SettingsStore.shared
        return (settings.animatedArtworkEnabled || settings.preferAppleCovers) && networkBlockReason == nil
    }

    /// Por que no se puede enseñar video ahora (nil si se puede): ajustes, accesibilidad, bateria y red.
    var blockReason: String? {
        if !SettingsStore.shared.animatedArtworkEnabled { return "ajuste apagado" }
        if UIAccessibility.isReduceMotionEnabled { return "Reducir movimiento activado" }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "modo de bajo consumo" }
        return networkBlockReason
    }

    /// Por que la red no permite buscar ahora (nil si se puede).
    var networkBlockReason: String? {
        guard NetworkMonitor.shared.hasConnection else { return "sin conexion" }
        if !(DownloadManager.shared.isOnWiFiNow || SettingsStore.shared.animatedArtworkUsesMobileData) {
            return "sin Wi-Fi y los datos moviles no estan permitidos"
        }
        return nil
    }

    private var noted: Set<String> = []

    /// Apunta en el informe (una vez por cancion y texto) lo que pasa con el video de una cancion.
    func note(_ videoId: String, _ text: String) {
        guard noted.insert("\(videoId)|\(text)").inserted else { return }
        PlaybackReport.record("caratula animada: \(videoId) \(text)")
    }

    // MARK: - Busqueda

    /// El video de la cancion, si tiene (y esta activado). Usa el mismo resultado guardado que `info`.
    func url(videoId: String, title: String, artist: String, album: String?) async -> URL? {
        guard SettingsStore.shared.animatedArtworkEnabled else { return nil }
        return await info(videoId: videoId, title: title, artist: artist, album: album)?.video
    }

    func info(for song: SongItem) async -> Info? {
        await info(videoId: song.videoId, title: song.title, artist: artistDisplayString(from: song.artists), album: song.album)
    }

    /// Video y caratula de la cancion, si tiene. Las respuestas (tambien las negativas) se guardan para no repetir la busqueda.
    func info(videoId: String, title: String, artist: String, album: String?) async -> Info? {
        if let entry = cache[videoId] {
            switch entry {
            case .hit(let info): return info
            case .miss(let date):
                if Date().timeIntervalSince(date) < missRetry {
                    note(videoId, "no se busca (ya se busco hace poco y no habia nada)")
                    return nil
                }
            }
        }
        guard wantsLookup else { return nil }
        if let running = inflight[videoId] { return await running.value }

        let task = Task<Info?, Never> { [weak self] in
            let started = Date()
            let trace = Trace()
            let found = await Self.search(title: title, artist: artist, album: album, trace: trace)
            guard let self else { return found }
            self.inflight[videoId] = nil
            if let found {
                self.cache[videoId] = .hit(found)
                self.persistHits()
            } else {
                self.cache[videoId] = .miss(Date())
            }
            if self.cache.count > 200 { self.cache = self.cache.filter { if case .hit = $0.value { return true }; return false } }
            PlaybackReport.record(String(
                format: "caratula animada: %@ -> %@ (video %@, portada %@) (%.1f s) [%@]",
                videoId, found.map { $0.source } ?? "ninguna",
                found?.video != nil ? "si" : "no", found?.cover != nil ? "si" : "no",
                Date().timeIntervalSince(started), trace.text
            ))
            return found
        }
        inflight[videoId] = task
        return await task.value
    }

    /// Lo que paso en cada paso de la busqueda, para el informe (sin esto solo se sabe que "no hay video").
    final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var parts: [String] = []
        func add(_ text: String) { lock.lock(); parts.append(text); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return parts.joined(separator: "; ") }
    }

    nonisolated private static func search(title: String, artist: String, album: String?, trace: Trace) async -> Info? {
        let wantedTitles = Matching.titleKeys(title)
        let wantedArtists = Matching.artists(artist)
        guard !wantedTitles.isEmpty, !wantedArtists.isEmpty else { return nil }
        let wanted = Wanted(titles: wantedTitles, artists: wantedArtists, album: album.map(Matching.normalize))

        var info = Info()
        let apple = await AppleMotionArtwork.search(title: title, artist: artist, album: album, wanted: wanted, trace: trace)
        info.video = apple.video
        info.cover = apple.cover
        if apple.video != nil || apple.cover != nil { info.source = "Apple Music" }
        if info.video == nil {
            let tidal = await TidalVideoCover.search(title: title, artist: artist, album: album, wanted: wanted, trace: trace)
            if let video = tidal.video { info.video = video; info.source = "TIDAL" }
            if info.cover == nil, let cover = tidal.cover {
                info.cover = cover
                if info.source.isEmpty { info.source = "TIDAL" }
            }
        }
        return (info.video == nil && info.cover == nil) ? nil : info
    }

    // MARK: - Comparacion de nombres

    struct Wanted: Sendable {
        let titles: Set<String>
        let artists: [String]
        let album: String?

        /// El titulo y los artistas coinciden (una caratula de otra cancion es peor que ninguna).
        func matches(title: String, artist: String) -> Bool {
            guard !Matching.titleKeys(title).isDisjoint(with: titles) else { return false }
            let credited = Matching.artists(artist)
            guard let first = artists.first, !credited.isEmpty else { return false }
            return credited.contains { $0 == first || $0.contains(first) || first.contains($0) }
        }
    }

    enum Matching {
        static func normalize(_ text: String) -> String {
            var t = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            t = t.replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ", options: .regularExpression)
            t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            return t.trimmingCharacters(in: .whitespaces)
        }

        /// Palabras que distinguen otra version de la cancion: si aparecen, el otro titulo tiene que llevarlas tambien (un remix
        /// no debe quedarse con la caratula del original).
        private static let editionWords = [
            "remix", "live", "en vivo", "directo", "acoustic", "acustic", "version", "mix", "edit", "sped", "slowed",
            "instrumental", "cover", "demo", "extended", "reverb", "nightcore", "8d"
        ]

        private static func hasEdition(_ text: String) -> Bool {
            let lower = text.lowercased()
            return editionWords.contains { lower.contains($0) }
        }

        /// Quita lo que cada servicio anade al titulo: parentesis y corchetes (salvo los de una edicion: remix, en vivo...),
        /// "feat. ...", "- Topic".
        private static func stripped(_ text: String) -> String {
            var t = text
            if let regex = try? NSRegularExpression(pattern: #"[\(\[][^\)\]]*[\)\]]"#) {
                let source = t as NSString
                var result = ""
                var last = 0
                for match in regex.matches(in: t, range: NSRange(location: 0, length: source.length)) {
                    result += source.substring(with: NSRange(location: last, length: match.range.location - last))
                    let piece = source.substring(with: match.range)
                    result += hasEdition(piece) ? " " + String(piece.dropFirst().dropLast()) + " " : " "
                    last = match.range.location + match.range.length
                }
                result += source.substring(from: last)
                t = result
            }
            t = t.replacingOccurrences(of: #"(?i)\b(feat|ft|featuring)\b\.?.*$"#, with: " ", options: .regularExpression)
            return t
        }

        /// Posibles formas de escribir el titulo: entera, y (si es del tipo "Artista - Titulo") cada lado.
        static func titleKeys(_ title: String) -> Set<String> {
            var keys: Set<String> = []
            let base = stripped(title)
            let whole = normalize(base)
            if !whole.isEmpty { keys.insert(whole) }
            let parts = base.components(separatedBy: " - ")
            // "Cancion - Remix" es una sola cosa; solo se separa "Artista - Cancion".
            if parts.count >= 2, !parts.contains(where: hasEdition) {
                for part in parts {
                    let value = normalize(part)
                    if value.count >= 2 { keys.insert(value) }
                }
            }
            return keys
        }

        static func artists(_ text: String) -> [String] {
            var t = text.replacingOccurrences(of: #"(?i)\s*-\s*topic\b"#, with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: #"(?i)vevo\b"#, with: "", options: .regularExpression)
            let separators = #"(?i)\s*(,|&|;|\sx\s|\sy\s|\sand\s|\sfeat\.?\s|\sft\.?\s|\sfeaturing\s)\s*"#
            let marked = t.replacingOccurrences(of: separators, with: "|", options: .regularExpression)
            return marked.components(separatedBy: "|").map(normalize).filter { !$0.isEmpty }
        }
    }

    // MARK: - HTTP

    nonisolated static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    nonisolated static func get(_ url: URL, headers: [String: String], timeout: TimeInterval = 12) async -> (Data, Int)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (data, http.statusCode)
    }

    nonisolated static var region: String {
        Locale.current.region?.identifier ?? "US"
    }
}

// MARK: - Apple Music

private enum AppleMotionArtwork {
    private static let catalog = "https://amp-api.music.apple.com/v1/catalog"
    private static let webPlayer = "https://music.apple.com/us/new"
    private static let tokenKey = "animatedArtwork.appleToken"
    private static let tokenExpiryKey = "animatedArtwork.appleTokenExpiry"
    private static let state = TokenState()

    /// Guarda el token entre busquedas (y entre arranques) para no bajar los scripts de la web cada vez.
    private final class TokenState: @unchecked Sendable {
        private let lock = NSLock()
        private var retryAfter = Date.distantPast
        private var rejected: Set<String> = []

        func canRetry() -> Bool { lock.lock(); defer { lock.unlock() }; return Date() >= retryAfter }
        func backOff() { lock.lock(); defer { lock.unlock() }; retryAfter = Date().addingTimeInterval(30 * 60) }
        func reject(_ token: String) { lock.lock(); defer { lock.unlock() }; rejected.insert(token) }
        func isRejected(_ token: String) -> Bool { lock.lock(); defer { lock.unlock() }; return rejected.contains(token) }
    }

    static func search(
        title: String, artist: String, album: String?, wanted: AnimatedArtworkService.Wanted,
        trace: AnimatedArtworkService.Trace
    ) async -> (video: URL?, cover: URL?) {
        guard let token = await bearer() else { trace.add("apple: sin token"); return (nil, nil) }
        let songs = await searchSongs(title: title, artist: artist, album: album, wanted: wanted, token: token, trace: trace)
        if let video = songs.video { return (video, songs.cover) }
        // El album que da Apple para la cancion (la cola no siempre trae el album de YouTube Music).
        let albumName = (album?.isEmpty == false ? album : nil) ?? songs.albumName
        guard let albumName, !albumName.isEmpty else {
            trace.add("apple: sin album para buscar por album")
            return (nil, songs.cover)
        }
        let video = await searchAlbums(artist: artist, album: albumName, wanted: wanted, token: token, trace: trace)
        return (video, songs.cover)
    }

    /// La caratula grande de un elemento del catalogo (la direccion trae {w}x{h} para elegir el tamano).
    private static func artworkURL(_ value: Any?) -> URL? {
        guard let artwork = value as? [String: Any], var template = artwork["url"] as? String else { return nil }
        template = template.replacingOccurrences(of: "{w}", with: "1500").replacingOccurrences(of: "{h}", with: "1500")
            .replacingOccurrences(of: "{c}", with: "bb").replacingOccurrences(of: "{f}", with: "jpg")
        return URL(string: template)
    }

    /// El numero de album que lleva la direccion de la cancion en Apple Music (".../album/nombre/1234567890?i=...").
    private static func albumId(fromURL string: String?) -> String? {
        guard let string, let range = string.range(of: "/album/") else { return nil }
        let tail = string[range.upperBound...].split(separator: "?").first.map(String.init) ?? ""
        let last = tail.split(separator: "/").last.map(String.init) ?? ""
        return !last.isEmpty && last.allSatisfy(\.isNumber) ? last : nil
    }

    private static func searchSongs(
        title: String, artist: String, album: String?, wanted: AnimatedArtworkService.Wanted, token: String,
        trace: AnimatedArtworkService.Trace
    ) async -> (video: URL?, cover: URL?, albumName: String?) {
        let first = AnimatedArtworkService.Matching.artists(artist).first ?? artist
        var term = title.localizedCaseInsensitiveContains(first) ? title : "\(first) \(title)"
        if let album, !album.isEmpty, !title.localizedCaseInsensitiveContains(album) { term += " \(album)" }

        var components = URLComponents(string: "\(catalog)/\(storefront)/search")
        components?.queryItems = [
            .init(name: "term", value: term),
            .init(name: "types", value: "songs"),
            .init(name: "limit", value: "10"),
            .init(name: "extend", value: "editorialVideo"),
            .init(name: "include", value: "albums")
        ]
        guard let url = components?.url, let json = await request(url, token: token, trace: trace) else { return (nil, nil, nil) }
        guard let songs = ((json["results"] as? [String: Any])?["songs"] as? [String: Any])?["data"] as? [[String: Any]] else {
            trace.add("apple canciones: 0 resultados")
            return (nil, nil, nil)
        }

        var matched = 0
        var albumsTried = 0
        var triedIds: Set<String> = []
        var matchedAlbumName: String?
        var matchedCover: URL?
        for song in songs {
            guard let attributes = song["attributes"] as? [String: Any],
                  let name = attributes["name"] as? String,
                  let credited = attributes["artistName"] as? String,
                  wanted.matches(title: name, artist: credited) else { continue }
            let albumName = (attributes["albumName"] as? String) ?? ""
            if isCompilation(name) || isCompilation(albumName) { continue }
            matched += 1
            if matchedAlbumName == nil, !albumName.isEmpty { matchedAlbumName = albumName }
            if matchedCover == nil { matchedCover = artworkURL(attributes["artwork"]) }
            if let video = attributes["editorialVideo"] as? [String: Any], let motion = motionURL(video) {
                return (motion, matchedCover, albumName)
            }

            // El album: de la relacion si viene, y si no del numero que lleva la direccion de la cancion.
            let relationships = song["relationships"] as? [String: Any]
            let related = (((relationships?["albums"] as? [String: Any])?["data"] as? [[String: Any]])?.first?["id"]) as? String
            let albumId = related ?? albumId(fromURL: attributes["url"] as? String)
            if let albumId, !albumId.hasPrefix("pl."), triedIds.insert(albumId).inserted {
                albumsTried += 1
                if let motion = await albumMotion(id: albumId, token: token, trace: trace) { return (motion, matchedCover, albumName) }
            }
        }
        trace.add("apple canciones: \(songs.count) resultados, \(matched) coinciden, \(albumsTried) albumes mirados, sin video")
        return (nil, matchedCover, matchedAlbumName)
    }

    /// Segunda via: buscar el album directamente (algunos albumes tienen video aunque la cancion no lo traiga).
    private static func searchAlbums(
        artist: String, album: String, wanted: AnimatedArtworkService.Wanted, token: String,
        trace: AnimatedArtworkService.Trace
    ) async -> URL? {
        let first = AnimatedArtworkService.Matching.artists(artist).first ?? artist
        var components = URLComponents(string: "\(catalog)/\(storefront)/search")
        components?.queryItems = [
            .init(name: "term", value: "\(first) \(album)"),
            .init(name: "types", value: "albums"),
            .init(name: "limit", value: "10"),
            .init(name: "extend", value: "editorialVideo")
        ]
        guard let url = components?.url, let json = await request(url, token: token, trace: trace) else { return nil }
        guard let albums = ((json["results"] as? [String: Any])?["albums"] as? [String: Any])?["data"] as? [[String: Any]] else {
            trace.add("apple albumes: 0 resultados")
            return nil
        }
        let wantedAlbum = AnimatedArtworkService.Matching.normalize(album)
        var matched = 0
        for record in albums {
            guard let attributes = record["attributes"] as? [String: Any],
                  let name = attributes["name"] as? String, !isCompilation(name),
                  let credited = attributes["artistName"] as? String else { continue }
            let hitAlbum = AnimatedArtworkService.Matching.normalize(name)
            guard hitAlbum == wantedAlbum else { continue }
            let firstWanted = wanted.artists.first ?? ""
            let creditedArtists = AnimatedArtworkService.Matching.artists(credited)
            guard creditedArtists.contains(where: { $0 == firstWanted || $0.contains(firstWanted) || firstWanted.contains($0) }) else { continue }
            matched += 1
            if let video = attributes["editorialVideo"] as? [String: Any], let motion = motionURL(video) { return motion }
        }
        trace.add("apple albumes: \(albums.count) resultados, \(matched) coinciden, sin video")
        return nil
    }

    private static func albumMotion(id: String, token: String, trace: AnimatedArtworkService.Trace) async -> URL? {
        var components = URLComponents(string: "\(catalog)/\(storefront)/albums/\(id)")
        components?.queryItems = [.init(name: "extend", value: "editorialVideo")]
        guard let url = components?.url, let json = await request(url, token: token, trace: trace),
              let album = (json["data"] as? [[String: Any]])?.first,
              let attributes = album["attributes"] as? [String: Any],
              let name = attributes["name"] as? String, !isCompilation(name) else { return nil }
        guard let video = attributes["editorialVideo"] as? [String: Any] else {
            trace.add("apple album \"\(name)\": sin editorialVideo")
            return nil
        }
        let motion = motionURL(video)
        if motion == nil { trace.add("apple album \"\(name)\": editorialVideo sin enlace (\(video.keys.sorted().joined(separator: ",")))") }
        return motion
    }

    /// Prefiere el cuadrado (la caratula es cuadrada); si no, el mas parecido.
    private static func motionURL(_ video: [String: Any]) -> URL? {
        func link(_ key: String) -> String? {
            guard let asset = video[key] as? [String: Any] else { return nil }
            for field in ["video", "videoUrl", "hlsUrl", "url"] {
                if let value = asset[field] as? String, !value.isEmpty { return value }
            }
            return nil
        }
        let ordered = ["motionDetailSquare", "motionSquareVideo1x1", "motionDetailRaw", "motionDetailTall", "motionTallVideo3x4"]
        let chosen = ordered.lazy.compactMap(link).first
            ?? ["motionWideVideo", "motionWideVideo16x9", "motionDetailWide"].lazy.compactMap(link).first
        return chosen.flatMap(URL.init(string:))
    }

    private static func isCompilation(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["playlist", "set list", "essentials", "dj mix", "apple music", "today's hits", "session"].contains { lower.contains($0) }
    }

    private static var storefront: String { AnimatedArtworkService.region.lowercased() }

    private static func request(_ url: URL, token: String, trace: AnimatedArtworkService.Trace) async -> [String: Any]? {
        let headers = [
            "Authorization": "Bearer \(token)",
            "Origin": "https://music.apple.com",
            "Referer": "https://music.apple.com/"
        ]
        guard let (data, status) = await AnimatedArtworkService.get(url, headers: headers) else {
            trace.add("apple: sin respuesta")
            return nil
        }
        if status != 200 { trace.add("apple: HTTP \(status)") }
        if status == 401 {
            // El token ya no vale: se olvida y se vuelve a sacar de la web la proxima vez.
            state.reject(token)
            UserDefaults.standard.removeObject(forKey: tokenKey)
            UserDefaults.standard.removeObject(forKey: tokenExpiryKey)
            return nil
        }
        guard status == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Token de invitado de la web de Apple Music

    private static func bearer() async -> String? {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: tokenKey), !state.isRejected(saved),
           defaults.double(forKey: tokenExpiryKey) > Date().timeIntervalSince1970 + 60 {
            return saved
        }
        guard state.canRetry() else { return nil }
        if let (token, expiry) = await scrapeToken() {
            defaults.set(token, forKey: tokenKey)
            defaults.set(expiry, forKey: tokenExpiryKey)
            return token
        }
        state.backOff()
        return nil
    }

    private static func scrapeToken() async -> (String, TimeInterval)? {
        guard let page = URL(string: webPlayer),
              let (html, status) = await AnimatedArtworkService.get(page, headers: [:]), status == 200 else { return nil }
        let text = String(decoding: html, as: UTF8.self)
        let scripts = matches(#"/assets/(?:index|app)(?:-legacy)?[~-][A-Za-z0-9_-]+\.js"#, in: text)
        for path in Array(NSOrderedSet(array: scripts)).compactMap({ $0 as? String }).prefix(4) {
            guard let url = URL(string: "https://music.apple.com\(path)"),
                  let (data, code) = await AnimatedArtworkService.get(url, headers: [:], timeout: 25), code == 200 else { continue }
            let script = String(decoding: data, as: UTF8.self)
            let now = Date().timeIntervalSince1970
            let candidates = Array(NSOrderedSet(array: matches(#"ey[A-Za-z0-9_-]+\.ey[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#, in: script)))
                .compactMap { $0 as? String }
                .compactMap { jwt -> (String, TimeInterval, Bool)? in
                    guard let info = inspect(jwt), info.expiry > now + 60, !state.isRejected(jwt) else { return nil }
                    return (jwt, info.expiry, info.isWebPlayer)
                }
            if let best = candidates.first(where: { $0.2 }) ?? candidates.first { return (best.0, best.1) }
        }
        return nil
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func inspect(_ jwt: String) -> (expiry: TimeInterval, isWebPlayer: Bool)? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3, let header = decode(String(parts[0])), let payload = decode(String(parts[1])),
              let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
              let exp = object["exp"] as? Double else { return nil }
        return (exp, header.contains("WebPlayKid") || payload.contains("AMPWebPlay"))
    }

    private static func decode(_ part: String) -> String? {
        var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
    }
}

// MARK: - TIDAL

private enum TidalVideoCover {
    private static let search = "https://api.tidal.com/v1/search"
    /// El token publico de su reproductor embebido (no hace falta cuenta).
    private static let token = "vNVdglQOjFJJGG2U"

    static func search(
        title: String, artist: String, album: String?, wanted: AnimatedArtworkService.Wanted,
        trace: AnimatedArtworkService.Trace
    ) async -> (video: URL?, cover: URL?) {
        let first = AnimatedArtworkService.Matching.artists(artist).first ?? artist
        var query = "\(first) \(title)"
        if let album, !album.isEmpty { query = "\(album) \(query)" }
        var components = URLComponents(string: search)
        components?.queryItems = [
            .init(name: "query", value: query),
            .init(name: "limit", value: "10"),
            .init(name: "types", value: "TRACKS"),
            .init(name: "countryCode", value: AnimatedArtworkService.region.uppercased())
        ]
        guard let url = components?.url, let json = await requestJSON(url, trace: trace),
              let items = (json["tracks"] as? [String: Any])?["items"] as? [[String: Any]] else { return (nil, nil) }

        var matched = 0
        var albumTitle: String?
        var matchedCover: URL?
        for item in items {
            guard let name = item["title"] as? String else { continue }
            let credited = ((item["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
            guard wanted.matches(title: name, artist: credited) else { continue }
            matched += 1
            let albumObject = item["album"] as? [String: Any]
            if albumTitle == nil { albumTitle = albumObject?["title"] as? String }
            if matchedCover == nil, let image = albumObject?["cover"] as? String { matchedCover = imageURL(image) }
            if let cover = albumObject?["videoCover"] as? String, let video = coverURL(cover) { return (video, matchedCover) }
        }
        trace.add("tidal canciones: \(items.count) resultados, \(matched) coinciden, sin videoCover en su album")
        // Segunda via: en la busqueda de albumes si aparece el video aunque la cancion no lo traiga.
        guard let albumName = albumTitle ?? album else { return (nil, matchedCover) }
        return (await searchAlbums(artist: first, album: albumName, wanted: wanted, trace: trace), matchedCover)
    }

    /// La caratula del album en el servidor de imagenes de TIDAL.
    private static func imageURL(_ id: String) -> URL? {
        let parts = id.split(separator: "-")
        guard parts.count == 5 else { return nil }
        return URL(string: "https://resources.tidal.com/images/\(parts.joined(separator: "/"))/1280x1280.jpg")
    }

    private static func searchAlbums(
        artist: String, album: String, wanted: AnimatedArtworkService.Wanted, trace: AnimatedArtworkService.Trace
    ) async -> URL? {
        var components = URLComponents(string: search)
        components?.queryItems = [
            .init(name: "query", value: "\(album) \(artist)"),
            .init(name: "limit", value: "10"),
            .init(name: "types", value: "ALBUMS"),
            .init(name: "countryCode", value: AnimatedArtworkService.region.uppercased())
        ]
        guard let url = components?.url, let json = await requestJSON(url, trace: trace),
              let items = (json["albums"] as? [String: Any])?["items"] as? [[String: Any]] else { return nil }
        let wantedAlbum = AnimatedArtworkService.Matching.normalize(album)
        var matched = 0
        for item in items {
            guard let name = item["title"] as? String,
                  AnimatedArtworkService.Matching.normalize(name) == wantedAlbum else { continue }
            let credited = ((item["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
                .map(AnimatedArtworkService.Matching.normalize)
            let firstWanted = wanted.artists.first ?? ""
            guard credited.contains(where: { $0 == firstWanted || $0.contains(firstWanted) || firstWanted.contains($0) }) else { continue }
            matched += 1
            if let cover = item["videoCover"] as? String, let video = coverURL(cover) { return video }
        }
        trace.add("tidal albumes: \(items.count) resultados, \(matched) coinciden, sin videoCover")
        return nil
    }

    private static func requestJSON(_ url: URL, trace: AnimatedArtworkService.Trace) async -> [String: Any]? {
        guard let (data, status) = await AnimatedArtworkService.get(url, headers: ["X-Tidal-Token": token]) else {
            trace.add("tidal: sin respuesta")
            return nil
        }
        guard status == 200 else {
            trace.add("tidal: HTTP \(status)")
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func coverURL(_ id: String) -> URL? {
        let parts = id.split(separator: "-")
        guard parts.count == 5 else { return nil }
        return URL(string: "https://resources.tidal.com/videos/\(parts.joined(separator: "/"))/1280x1280.mp4")
    }
}
