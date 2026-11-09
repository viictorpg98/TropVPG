//
//  SearchSuggestions.swift
//  Trop
//
//  Sugerencias mientras se escribe en Buscar: las de YouTube Music y, ademas, la mejor cancion para lo escrito.
//

import Foundation
import Observation

enum SearchSuggestionService {
    private static let endpoint =
        "https://music.youtube.com/youtubei/v1/music/get_search_suggestions?prettyPrint=false&key=AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"

    /// Frases que YouTube Music sugiere para lo escrito (vacio si no hay red o falla).
    static func suggestions(for query: String) async -> [String] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, let url = URL(string: endpoint) else { return [] }
        let client = YouTubeClient.webRemix
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let country = Locale.current.region?.identifier ?? "US"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "context": ["client": [
                "clientName": client.clientName, "clientVersion": client.clientVersion, "hl": language, "gl": country
            ]],
            "input": text
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return [] }
        request.httpBody = payload
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let contents = json["contents"] as? [[String: Any]] else { return [] }

        var found: [String] = []
        for section in contents {
            let items = (section["searchSuggestionsSectionRenderer"] as? [String: Any])?["contents"] as? [[String: Any]] ?? []
            for item in items {
                guard let renderer = item["searchSuggestionRenderer"] as? [String: Any],
                      let query = ((renderer["navigationEndpoint"] as? [String: Any])?["searchEndpoint"] as? [String: Any])?["query"] as? String,
                      !found.contains(query) else { continue }
                found.append(query)
            }
        }
        return Array(found.prefix(8))
    }

    /// La primera cancion (no video) que YouTube Music devuelve para lo escrito.
    static func topSong(for query: String) async -> SongItem? {
        guard let json = try? await InnerTubeClient.tropShared.search(query: query, params: nil, client: .webRemix) else { return nil }
        for section in SearchParser.parseSearchResults(from: json) where section.title == "Songs" {
            for item in section.items {
                if case .song(let song) = item { return song }
            }
        }
        return nil
    }
}

@MainActor
@Observable
final class SearchSuggestionsModel {
    private(set) var items: [String] = []
    private(set) var topSong: SongItem?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Se llama cada vez que cambia el texto: espera un momento por si se sigue escribiendo.
    func update(for text: String) {
        task?.cancel()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, NetworkMonitor.shared.hasConnection else {
            items = []
            topSong = nil
            return
        }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            let list = await SearchSuggestionService.suggestions(for: query)
            guard !Task.isCancelled else { return }
            self?.items = list
            // El mejor resultado cuesta mas: se pide un poco despues, sin retrasar las sugerencias.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let song = await SearchSuggestionService.topSong(for: query)
            guard !Task.isCancelled else { return }
            self?.topSong = song
        }
    }
}
