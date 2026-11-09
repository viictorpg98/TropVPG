//
//  AudioCounterpartStore.swift
//  Trop
//
//  Videoclips y subidas de usuario traen como miniatura un fotograma del video. Muchos tienen una version de audio (la cancion
//  del album, "counterpart" en YouTube Music) con su caratula cuadrada: esta clase la busca y la da en lugar del fotograma.
//

import Foundation
import Observation

@Observable
@MainActor
final class AudioCounterpartStore {
    static let shared = AudioCounterpartStore()

    private static let defaultsKey = "audioCounterpart.covers"

    /// Identificador del video -> direccion de la caratula de su version de audio ("" = no tiene).
    private(set) var covers: [String: String]

    @ObservationIgnored private var pending: [String] = []
    @ObservationIgnored private var queued: Set<String> = []
    @ObservationIgnored private var failedAt: [String: Date] = [:]
    @ObservationIgnored private var running = 0

    private init() {
        covers = (UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String]) ?? [:]
    }

    // MARK: - Que canciones son un video

    /// Videoclip oficial o subida de usuario.
    nonisolated static func isVideoType(_ song: SongItem) -> Bool {
        song.musicVideoType == "MUSIC_VIDEO_TYPE_OMV" || song.musicVideoType == "MUSIC_VIDEO_TYPE_UGC"
    }

    // MARK: - Para las listas

    /// La miniatura que debe enseñar una fila: la caratula de la version de audio si la cancion es un video y la tiene; si no, la
    /// suya. Los resultados marcados como "Video" (los que se buscan a proposito) conservan su fotograma.
    func thumbnailURL(for song: SongItem) -> String? {
        guard SettingsStore.shared.preferAppleCovers, Self.isVideoType(song), song.isVideo != true else {
            return song.thumbnailUrl
        }
        if let known = covers[song.videoId] { return known.isEmpty ? song.thumbnailUrl : known }
        request(song.videoId)
        return song.thumbnailUrl
    }

    private func request(_ videoId: String) {
        if let failed = failedAt[videoId], Date().timeIntervalSince(failed) < 120 { return }
        guard queued.insert(videoId).inserted else { return }
        pending.append(videoId)
        // Se arranca fuera de la actualizacion de la vista que lo pidio.
        Task { @MainActor in self.pump() }
    }

    private func pump() {
        while running < 2, !pending.isEmpty {
            let videoId = pending.removeFirst()
            running += 1
            Task { @MainActor in
                let outcome = await Self.lookup(videoId)
                self.running -= 1
                self.queued.remove(videoId)
                switch outcome {
                case .found(let url): self.store(videoId, url)
                case .none: self.store(videoId, "")
                case .failed: self.failedAt[videoId] = Date()
                }
                self.pump()
            }
        }
    }

    // MARK: - Para el reproductor

    /// La caratula de la version de audio de este video, si la tiene.
    func coverURL(for videoId: String) async -> URL? {
        if let known = covers[videoId] { return known.isEmpty ? nil : URL(string: known) }
        switch await Self.lookup(videoId) {
        case .found(let url):
            store(videoId, url)
            return URL(string: url)
        case .none:
            store(videoId, "")
            return nil
        case .failed:
            return nil
        }
    }

    private func store(_ videoId: String, _ value: String) {
        covers[videoId] = value
        if covers.count > 600 {
            for key in covers.keys.prefix(100) where key != videoId { covers[key] = nil }
        }
        UserDefaults.standard.set(covers, forKey: Self.defaultsKey)
        PlaybackReport.record("caratula del audio: \(videoId) -> \(value.isEmpty ? "sin version de audio" : "encontrada")")
    }

    // MARK: - Busqueda

    private enum Outcome {
        case found(String)
        case none
        case failed
    }

    nonisolated private static func lookup(_ videoId: String) async -> Outcome {
        guard let json = try? await InnerTubeClient.tropShared.next(videoId: videoId, playlistId: "RDAMVM\(videoId)") else {
            return .failed
        }
        if let url = counterpartCover(in: json, seed: videoId) { return .found(url) }
        return .none
    }

    /// En la lista que devuelve YouTube Music para un video, el elemento trae la version de video y la de audio; la caratula
    /// de la de audio es la del album.
    nonisolated private static func counterpartCover(in json: [String: Any], seed: String) -> String? {
        func child(_ value: Any?, _ key: String) -> Any? { (value as? [String: Any])?[key] }

        var node: Any? = json
        for key in ["contents", "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer", "watchNextTabbedResultsRenderer"] {
            node = child(node, key)
        }
        node = ((node as? [String: Any])?["tabs"] as? [[String: Any]])?.first
        for key in ["tabRenderer", "content", "musicQueueRenderer", "content", "playlistPanelRenderer"] {
            node = child(node, key)
        }
        guard let entries = (node as? [String: Any])?["contents"] as? [[String: Any]] else { return nil }

        for entry in entries.prefix(3) {
            guard let wrapper = entry["playlistPanelVideoWrapperRenderer"] as? [String: Any] else { continue }
            var renderers: [[String: Any]] = []
            if let primary = child(child(wrapper, "primaryRenderer"), "playlistPanelVideoRenderer") as? [String: Any] {
                renderers.append(primary)
            }
            for counterpart in (wrapper["counterpart"] as? [[String: Any]]) ?? [] {
                if let renderer = child(child(counterpart, "counterpartRenderer"), "playlistPanelVideoRenderer") as? [String: Any] {
                    renderers.append(renderer)
                }
            }
            guard renderers.contains(where: { ($0["videoId"] as? String) == seed }) else { continue }
            for renderer in renderers where (renderer["videoId"] as? String) != seed
                && VideoAvailability.rowMusicVideoType(renderer) == "MUSIC_VIDEO_TYPE_ATV" {
                if let thumbnail = InnerTubeJSON.nestedThumbnailURL(renderer) { return ArtworkURLs.highRes(thumbnail) ?? thumbnail }
            }
        }
        return nil
    }
}
