//
//  MatchPlaylist.swift
//  Trop
//
//  "Lista del partido": la lista de canciones del equipo (web de Franciscans) leida de Supabase en solo lectura,
//  ordenada como una clasificacion de liga, y la forma de convertir cada fila en una cancion de YouTube Music reproducible.
//

import Foundation

/// Una cancion de la lista del equipo tal como la devuelve `playlist_state` (nunca trae quien la anadio).
struct MatchEntry: Codable, Hashable, Identifiable {
    var id: String
    var sourceId: String
    var title: String
    var artist: String
    var artworkUrl: String?
    var likes: Int
    var dislikes: Int

    var score: Int { likes - dislikes }

    enum CodingKeys: String, CodingKey {
        case id
        case sourceId = "source_id"
        case title
        case artist
        case artworkUrl = "artwork_url"
        case likes
        case dislikes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let sourceId = try c.decode(String.self, forKey: .sourceId)
        self.sourceId = sourceId
        // Si por lo que sea no hay id propio, el origen sirve (es unico en la lista).
        self.id = (try? c.decode(String.self, forKey: .id)) ?? sourceId
        self.title = (try? c.decode(String.self, forKey: .title)) ?? ""
        self.artist = (try? c.decodeIfPresent(String.self, forKey: .artist)) ?? ""
        self.artworkUrl = (try? c.decodeIfPresent(String.self, forKey: .artworkUrl)) ?? nil
        self.likes = (try? c.decodeIfPresent(Int.self, forKey: .likes)) ?? 0
        self.dislikes = (try? c.decodeIfPresent(Int.self, forKey: .dislikes)) ?? 0
    }
}

private struct MatchStateResponse: Decodable {
    let songs: [MatchEntry]?
}

/// Zona de la clasificacion, igual que en la web: banda dorada arriba (ascenso) y roja abajo (descenso).
enum MatchZone {
    case none
    case promotion
    case relegation
}

struct MatchRow: Identifiable {
    let position: Int
    let entry: MatchEntry
    let zone: MatchZone

    var id: String { entry.id }
}

enum MatchPlaylist {
    private static let endpoint = URL(string: "https://siqtakmlinlqfqhcohlg.supabase.co/rest/v1/rpc/playlist_state")!
    // Clave publica (la misma que lleva la web): solo permite lo que las funciones RPC dejan hacer a cualquiera.
    private static let apiKey = "sb_publishable_F7UMII_HrF_ml7QJ9flo6g_IBlcGCHa"
    private static let cacheKey = "matchPlaylist.cache.v1"
    private static let countKey = "matchPlaylist.count.v1"

    /// Cuantas canciones tenia la ultima lista leida (para el subtitulo de la tarjeta de Biblioteca).
    static var cachedCount: Int { UserDefaults.standard.integer(forKey: countKey) }

    /// Lee la lista (solo lectura). Con `p_device` nulo no se marca ningun voto como propio.
    static func fetch() async throws -> [MatchEntry] {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"p_device\":null}".utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(MatchStateResponse.self, from: data).songs ?? []
    }

    /// Ultima lista leida, para poder verla sin conexion.
    static func loadCache() -> [MatchEntry] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let entries = try? JSONDecoder().decode([MatchEntry].self, from: data) else { return [] }
        return entries
    }

    static func saveCache(_ entries: [MatchEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
        UserDefaults.standard.set(entries.count, forKey: countKey)
    }

    /// La clasificacion: puntos (me gusta - no me gusta) de mayor a menor, a igualdad mas me gusta y, si sigue el empate,
    /// el orden del servidor (el indice original evita depender de que el orden sea estable).
    /// Zonas por posicion, sea cual sea la puntuacion: las 2 primeras "Ascenso" y las 3 ultimas "Descenso". Con menos de 5
    /// canciones se reparte la lista (2: 1 y 1; 3: 1 y 2; 4: 2 y 2) y con una sola no hay zonas.
    static func ranked(_ entries: [MatchEntry]) -> [MatchRow] {
        let ordered = entries.enumerated().sorted { a, b in
            if a.element.score != b.element.score { return a.element.score > b.element.score }
            if a.element.likes != b.element.likes { return a.element.likes > b.element.likes }
            return a.offset < b.offset
        }.map(\.element)
        let total = ordered.count
        let promoted = total < 2 ? 0 : min(2, total / 2)
        let relegated = total < 2 ? 0 : min(3, total - promoted)
        return ordered.enumerated().map { index, entry in
            var zone = MatchZone.none
            if index < promoted {
                zone = .promotion
            } else if index >= total - relegated {
                zone = .relegation
            }
            return MatchRow(position: index + 1, entry: entry, zone: zone)
        }
    }
}

/// Convierte las filas de la lista en canciones de YouTube Music: la web guarda "yt:<id>" (o un id de iTunes / un texto
/// si se anadio a mano), asi que se busca "artista titulo" para tener la cancion completa (con su duracion, que Sonar
/// necesita para tratar bien las canciones largas) o, en las que no traen id de YouTube, para encontrarla.
enum MatchResolver {
    static func youtubeId(_ sourceId: String) -> String? {
        guard sourceId.hasPrefix("yt:") else { return nil }
        let id = String(sourceId.dropFirst(3))
        return id.count == 11 ? id : nil
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\(.*?\\)|\\[.*?\\]", with: " ", options: .regularExpression)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func firstArtist(_ artist: String) -> String {
        var name = artist
        for separator in [", ", " & ", " y ", " feat. ", " feat ", " ft. ", " con "] {
            if let range = name.range(of: separator, options: .caseInsensitive) {
                name = String(name[name.startIndex..<range.lowerBound])
            }
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// La cancion lista para sonar, o `nil` si no se encuentra (esa fila se salta, no se cancela todo).
    static func resolve(_ entry: MatchEntry) async -> SongItem? {
        let wantedId = youtubeId(entry.sourceId)
        let query = [firstArtist(entry.artist), entry.title].filter { !$0.isEmpty }.joined(separator: " ")
        if !query.isEmpty,
           let json = try? await InnerTubeClient.tropShared.search(query: query, params: nil, client: .webRemix) {
            var candidates: [SongItem] = []
            for section in SearchParser.parseSearchResults(from: json) {
                for item in section.items {
                    if case .song(let song) = item { candidates.append(song) }
                }
            }
            if let wantedId, let exact = candidates.first(where: { $0.videoId == wantedId }) {
                return exact
            }
            if wantedId == nil {
                let wanted = normalize(entry.title)
                if !wanted.isEmpty,
                   let match = candidates.first(where: {
                       let got = normalize($0.title)
                       return !got.isEmpty && (got == wanted || got.contains(wanted) || wanted.contains(got))
                   }) {
                    return match
                }
            }
        }
        // Con id de YouTube siempre se puede intentar, aunque la busqueda no lo devuelva (duracion desconocida).
        if let wantedId {
            return SongItem(
                matchVideoId: wantedId,
                title: entry.title,
                artist: entry.artist,
                thumbnailUrl: entry.artworkUrl
            )
        }
        return nil
    }

    /// Resuelve varias a la vez (hasta `maxConcurrent` busquedas simultaneas). Devuelve `source_id` -> cancion.
    static func resolveAll(_ entries: [MatchEntry], maxConcurrent: Int = 6) async -> [String: SongItem] {
        var found: [String: SongItem] = [:]
        await withTaskGroup(of: (String, SongItem?).self) { group in
            var next = 0
            while next < min(maxConcurrent, entries.count) {
                let entry = entries[next]
                next += 1
                group.addTask { (entry.sourceId, await MatchResolver.resolve(entry)) }
            }
            while let result = await group.next() {
                if let song = result.1 { found[result.0] = song }
                if next < entries.count {
                    let entry = entries[next]
                    next += 1
                    group.addTask { (entry.sourceId, await MatchResolver.resolve(entry)) }
                }
            }
        }
        return found
    }
}

extension SongItem {
    /// Cancion minima a partir del id de YouTube y los datos de la lista (duracion desconocida: 0).
    init(matchVideoId: String, title: String, artist: String, thumbnailUrl: String?) {
        self.videoId = matchVideoId
        self.title = title.isEmpty ? "Unknown" : title
        self.artists = artist.isEmpty ? [] : [YTArtist(name: artist)]
        self.album = nil
        self.albumId = nil
        self.duration = 0
        self.thumbnailUrl = thumbnailUrl
        self.isExplicit = false
        self.playlistId = nil
        self.likeStatus = nil
    }
}
