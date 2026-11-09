//
//  AudioCounterpartStore.swift
//  Trop
//
//  Muchos elementos de YouTube Music son un video (videoclip, subida de usuario) que tiene una version de audio: la cancion del
//  album ("counterpart"). La miniatura del video es un fotograma y suena el video; la version de audio tiene la caratula
//  cuadrada y es lo que se quiere escuchar. Esta clase busca esa version de audio y la da, para:
//    - las miniaturas (cualquier miniatura que sea un fotograma de video se cambia por la caratula de su audio),
//    - lo que suena (al reproducir un video que tiene audio se pone el audio, como hace YouTube Music por defecto),
//    - la cola (lo que queda por sonar).
//  Los videos que no tienen version de audio se quedan como estan.
//

import Foundation
import Observation

/// La version de audio de un video.
struct AudioVersion: Codable, Sendable, Equatable {
    var videoId: String
    var thumbnail: String
    var title: String
    var duration: Int
}

@Observable
@MainActor
final class AudioCounterpartStore {
    static let shared = AudioCounterpartStore()

    private static let foundKey = "audioCounterpart.found.v3"
    private static let noneKey = "audioCounterpart.none.v3"

    /// Identificador del video -> su version de audio.
    private(set) var found: [String: AudioVersion]
    /// Videos que se han mirado y no tienen version de audio.
    private(set) var withoutAudio: Set<String>

    @ObservationIgnored private var pending: [String] = []
    @ObservationIgnored private var queued: Set<String> = []
    @ObservationIgnored private var failedAt: [String: Date] = [:]
    @ObservationIgnored private var running = 0

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.foundKey),
           let decoded = try? JSONDecoder().decode([String: AudioVersion].self, from: data) {
            found = decoded
        } else {
            found = [:]
        }
        withoutAudio = Set(UserDefaults.standard.stringArray(forKey: Self.noneKey) ?? [])
    }

    // MARK: - Que elementos son un video

    /// Videoclip oficial, subida de usuario o resultado marcado como "Video".
    nonisolated static func isVideoType(_ song: SongItem) -> Bool {
        song.isVideo == true || song.musicVideoType == "MUSIC_VIDEO_TYPE_OMV" || song.musicVideoType == "MUSIC_VIDEO_TYPE_UGC"
    }

    private var isEnabled: Bool { SettingsStore.shared.preferAppleCovers }

    /// Es un video con posible version de audio que aun no se ha mirado (y se puede mirar ahora).
    func needsLookup(_ song: SongItem) -> Bool {
        guard isEnabled, Self.isVideoType(song) else { return false }
        guard found[song.videoId] == nil, !withoutAudio.contains(song.videoId) else { return false }
        guard NetworkMonitor.shared.hasConnection, !DownloadManager.shared.isDownloaded(videoId: song.videoId) else { return false }
        return true
    }

    // MARK: - Cambiar un elemento por su version de audio

    /// El mismo elemento con su version de audio, si la tiene ya buscada. Lo descargado se queda como esta (si no, sin conexion
    /// no sonaria).
    func preferAudio(_ song: SongItem) -> SongItem {
        guard isEnabled, Self.isVideoType(song),
              let version = found[song.videoId],
              !DownloadManager.shared.isDownloaded(videoId: song.videoId) else { return song }
        var swapped = song
        swapped.videoId = version.videoId
        if !version.title.isEmpty { swapped.title = version.title }
        if version.duration > 0 { swapped.duration = version.duration }
        swapped.thumbnailUrl = version.thumbnail
        swapped.musicVideoType = "MUSIC_VIDEO_TYPE_ATV"
        swapped.isVideo = nil
        return swapped
    }

    /// Como `preferAudio`, pero si hace falta la busca antes (con un limite de espera para no retrasar el sonido).
    func resolve(_ song: SongItem) async -> SongItem {
        if needsLookup(song) { _ = await audioVersion(of: song.videoId, timeout: 1.8) }
        return preferAudio(song)
    }

    /// Pide la version de audio de los videos que quedan por sonar (en segundo plano).
    func prefetch(_ songs: [SongItem]) {
        for song in songs.prefix(20) where needsLookup(song) { request(song.videoId) }
    }

    // MARK: - Miniaturas

    /// La miniatura que debe enseñar una cancion: la caratula de su version de audio si es un video que la tiene (o la pide en
    /// segundo plano y la vista se actualiza sola cuando llega); si no, la suya.
    func thumbnailURL(for song: SongItem) -> String? {
        guard isEnabled, Self.isVideoType(song) else { return song.thumbnailUrl }
        if let version = found[song.videoId] { return version.thumbnail }
        if needsLookup(song) { request(song.videoId) }
        return song.thumbnailUrl
    }

    func thumbnailURL(for item: YTItem) -> String? {
        if case .song(let song) = item { return thumbnailURL(for: song) }
        return item.thumbnailUrl
    }

    nonisolated(unsafe) private static let frameExpression = try? NSRegularExpression(pattern: #"ytimg\.com/vi(?:_webp)?/([A-Za-z0-9_-]{11})/"#)

    /// Identificador del video de una miniatura que es un fotograma suyo (ytimg.com/vi/<id>/...).
    nonisolated static func frameVideoId(_ url: String) -> String? {
        guard let expression = frameExpression,
              let match = expression.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
              let range = Range(match.range(at: 1), in: url) else { return nil }
        return String(url[range])
    }

    /// Si la miniatura es un fotograma de un video que tiene version de audio, la caratula de esa version. Si aun no se ha
    /// mirado, lo pide (y la vista se actualiza sola cuando llegue). `nil`: se queda la que traia.
    func thumbnailOverride(forFrame url: String?) -> String? {
        guard isEnabled, let url, let id = Self.frameVideoId(url) else { return nil }
        if let version = found[id] { return version.thumbnail }
        if !withoutAudio.contains(id), NetworkMonitor.shared.hasConnection { request(id) }
        return nil
    }

    // MARK: - Busqueda en segundo plano

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
                self.apply(outcome, for: videoId)
                self.pump()
            }
        }
    }

    // MARK: - Para el reproductor

    /// La version de audio de un video (la busca si hace falta, esperando como mucho `timeout` s).
    func audioVersion(of videoId: String, timeout: TimeInterval = 4) async -> AudioVersion? {
        if let version = found[videoId] { return version }
        if withoutAudio.contains(videoId) { return nil }
        let outcome: Outcome = await withTaskGroup(of: Outcome?.self) { group in
            group.addTask { await Self.lookup(videoId) }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = (await group.next()) ?? nil
            group.cancelAll()
            return first ?? .failed
        }
        apply(outcome, for: videoId)
        return found[videoId]
    }

    /// La caratula de la version de audio de este video, si la tiene.
    func coverURL(for videoId: String) async -> URL? {
        guard let version = await audioVersion(of: videoId) else { return nil }
        return URL(string: version.thumbnail)
    }

    private func apply(_ outcome: Outcome, for videoId: String) {
        switch outcome {
        case .found(let version):
            found[videoId] = version
            if found.count > 500 { for key in found.keys.prefix(100) where key != videoId { found[key] = nil } }
            persist()
            PlaybackReport.record("version de audio: \(videoId) -> \(version.videoId)")
            // Lo que queda por sonar de la cola cambia al audio.
            NowPlaying.shared.applyAudioVersions()
        case .absent(let why):
            PlaybackReport.record("version de audio: \(videoId) -> no hay (\(why))")
            withoutAudio.insert(videoId)
            if withoutAudio.count > 800 { withoutAudio = Set(withoutAudio.suffix(400)) }
            persist()
        case .failed:
            failedAt[videoId] = Date()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(found) { UserDefaults.standard.set(data, forKey: Self.foundKey) }
        UserDefaults.standard.set(Array(withoutAudio), forKey: Self.noneKey)
    }

    // MARK: - Busqueda

    private enum Outcome {
        case found(AudioVersion)
        case absent(String)
        case failed
    }

    nonisolated private static func lookup(_ videoId: String) async -> Outcome {
        guard let json = try? await InnerTubeClient.tropShared.next(videoId: videoId, playlistId: "RDAMVM\(videoId)") else {
            return .failed
        }
        let parsed = counterpart(in: json, seed: videoId)
        if let version = parsed.version { return .found(version) }
        // Segunda via: la cancion buscada por titulo y artista entre las canciones (no videos) de YouTube Music.
        guard let seed = parsed.seed else { return .absent("next: \(parsed.shape), sin datos del video") }
        switch await searchAudio(for: seed, videoId: videoId) {
        case .found(let version): return .found(version)
        case .failed: return .failed
        case .absent(let why): return .absent("next: \(parsed.shape); busqueda: \(why)")
        }
    }

    /// Datos del video que se busca, tal como los devuelve YouTube Music.
    private struct SeedInfo {
        var title: String
        var artist: String
        var duration: Int
    }

    /// En la lista que devuelve YouTube Music para un video, el elemento trae la version de video y la de audio.
    nonisolated private static func counterpart(
        in json: [String: Any], seed: String
    ) -> (version: AudioVersion?, seed: SeedInfo?, shape: String) {
        func child(_ value: Any?, _ key: String) -> Any? { (value as? [String: Any])?[key] }

        var node: Any? = json
        for key in ["contents", "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer", "watchNextTabbedResultsRenderer"] {
            node = child(node, key)
        }
        node = ((node as? [String: Any])?["tabs"] as? [[String: Any]])?.first
        for key in ["tabRenderer", "content", "musicQueueRenderer", "content", "playlistPanelRenderer"] {
            node = child(node, key)
        }
        guard let entries = (node as? [String: Any])?["contents"] as? [[String: Any]] else { return (nil, nil, "sin lista") }

        func seedInfo(_ renderer: [String: Any]) -> SeedInfo {
            let runs = InnerTubeJSON.rawRuns(renderer["longBylineText"] as? [String: Any] ?? renderer["shortBylineText"] as? [String: Any])
            return SeedInfo(
                title: InnerTubeJSON.runsText(renderer["title"] as? [String: Any]) ?? "",
                artist: ArtistCredits.parse(runs: runs).map(\.name).joined(separator: ", "),
                duration: DurationFormat.parseRendererDuration(renderer)
            )
        }

        var seedFound: SeedInfo?
        var shape = "sin el video en la lista"
        for entry in entries.prefix(3) {
            if let renderer = entry["playlistPanelVideoRenderer"] as? [String: Any], (renderer["videoId"] as? String) == seed {
                seedFound = seedInfo(renderer)
                shape = "elemento simple (\(VideoAvailability.rowMusicVideoType(renderer) ?? "?"))"
                continue
            }
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
            guard let seedRenderer = renderers.first(where: { ($0["videoId"] as? String) == seed }) else { continue }
            seedFound = seedInfo(seedRenderer)
            shape = "con version de audio y de video"
            for renderer in renderers {
                guard let audioId = renderer["videoId"] as? String, audioId != seed,
                      VideoAvailability.rowMusicVideoType(renderer) == "MUSIC_VIDEO_TYPE_ATV",
                      let thumbnail = InnerTubeJSON.nestedThumbnailURL(renderer) else { continue }
                let version = AudioVersion(
                    videoId: audioId,
                    thumbnail: ArtworkURLs.highRes(thumbnail) ?? thumbnail,
                    title: InnerTubeJSON.runsText(renderer["title"] as? [String: Any]) ?? "",
                    duration: DurationFormat.parseRendererDuration(renderer)
                )
                return (version, seedFound, shape)
            }
            shape = "envoltorio sin audio"
        }
        return (nil, seedFound, shape)
    }

    /// Busca "artista titulo" y toma la primera cancion (no video) cuyo titulo y artista coinciden.
    nonisolated private static func searchAudio(for seed: SeedInfo, videoId: String) async -> Outcome {
        let titleKeys = AnimatedArtworkService.Matching.titleKeys(seed.title)
        let artists = AnimatedArtworkService.Matching.artists(seed.artist)
        guard let queryTitle = titleKeys.max(by: { $0.count < $1.count }), let firstArtist = artists.first else {
            return .absent("sin titulo o artista")
        }
        let wanted = AnimatedArtworkService.Wanted(titles: titleKeys, artists: artists, album: nil)
        guard let json = try? await InnerTubeClient.tropShared.search(query: "\(firstArtist) \(queryTitle)", params: nil, client: .webRemix) else {
            return .failed
        }
        var songs = 0
        for section in SearchParser.parseSearchResults(from: json) where section.title == "Songs" {
            for item in section.items {
                guard case .song(let song) = item, song.videoId != videoId, !isVideoType(song) else { continue }
                songs += 1
                guard wanted.matches(title: song.title, artist: artistDisplayString(from: song.artists)),
                      let thumbnail = song.thumbnailUrl else { continue }
                return .found(AudioVersion(
                    videoId: song.videoId,
                    thumbnail: ArtworkURLs.highRes(thumbnail) ?? thumbnail,
                    title: song.title,
                    duration: song.duration
                ))
            }
        }
        return .absent("\(songs) canciones, ninguna coincide")
    }
}

extension YTItem {
    /// Elementos que son un video o un episodio a proposito: su miniatura es el fotograma y no se cambia.
    var keepsVideoFrame: Bool {
        switch self {
        case .episode, .podcast: return true
        default: return false
        }
    }
}
