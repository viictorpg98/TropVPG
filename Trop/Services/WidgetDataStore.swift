//
//  WidgetDataStore.swift
//  Trop
//
//  Deja en la carpeta compartida con el widget lo que enseñan sus portadas: tus Selecciones rapidas, tu Acceso rapido y los
//  nuevos episodios, con las portadas ya descargadas y reducidas (el widget no puede bajarlas ni leer la base de datos).
//  Se actualiza cuando cambia el inicio y al volver a la app. Nunca se guardan cookies ni datos de la cuenta, solo titulos,
//  artistas, identificadores y portadas.
//

import Foundation
import UIKit
import WidgetKit

@MainActor
final class WidgetDataStore {
    static let shared = WidgetDataStore()

    /// Lo minimo de una cancion o episodio para el widget (valores simples: se pasan fuera del hilo principal).
    struct Source: Hashable, Sendable {
        let id: String
        let title: String
        let artist: String
        let thumbnailUrl: String?
        let duration: Int
        let isEpisode: Bool
    }

    private var quickPicks: [Source] = []
    private var recentSongs: [Source] = []
    private var episodes: [Source] = []
    private var episodesFetchedAt = Date.distantPast
    private var fetchingEpisodes = false
    private var task: Task<Void, Never>?
    private var lastSignature = ""
    private var lastWrite = Date.distantPast

    private init() {}

    // MARK: - Arranque

    /// Al abrir la app: deja la marca de que se puede escribir en la carpeta compartida y apunta en el informe como esta.
    func start() {
        reportShare()
        appBecameActive()
    }

    func appBecameActive() {
        if let found = WidgetShared.resolved {
            WidgetShared.writeProbe(groupId: found.id, bundleId: Bundle.main.bundleIdentifier ?? "", in: found.url)
        }
        // El Acceso rapido sale de la base de datos: se vuelve a leer sin esperar a que cambie el inicio.
        schedule()
        fetchEpisodesIfNeeded()
    }

    private func reportShare() {
        let tried = WidgetShared.candidateGroups().joined(separator: ", ")
        let infoGroups = (Bundle.main.infoDictionary?["ALTAppGroups"] as? [String])?.joined(separator: ", ") ?? "(ninguno)"
        let resolved = WidgetShared.resolved?.id ?? "NINGUNO"
        PlaybackReport.record(
            "widget: ALTAppGroups=[\(infoGroups)] bundle=\(Bundle.main.bundleIdentifier ?? "?") probados=[\(tried)] carpeta compartida=\(resolved)"
        )
    }

    // MARK: - Cancion que suena (boton "Me gusta")

    private var lastNowPlaying: (id: String?, liked: Bool)?
    private var lastButtonsReload = Date.distantPast
    private var buttonsReloadTask: Task<Void, Never>?

    /// Lo llama el reproductor cuando cambia la cancion o su Me gusta: deja el dato en la carpeta compartida y recarga los widgets
    /// de botones. El sistema limita las recargas, asi que como mucho se pide una cada 15 s (si hay mas cambios seguidos, se juntan).
    func nowPlayingChanged(videoId: String?, liked: Bool) {
        if let last = lastNowPlaying, last.id == videoId, last.liked == liked { return }
        lastNowPlaying = (videoId, liked)
        guard let found = WidgetShared.resolved else { return }
        WidgetShared.writeNowPlaying(
            WidgetNowPlaying(videoId: videoId, liked: liked, updated: Date()), in: found.url
        )
        let sinceLast = Date().timeIntervalSince(lastButtonsReload)
        buttonsReloadTask?.cancel()
        if sinceLast >= 15 {
            reloadButtonWidgets()
        } else {
            buttonsReloadTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((15 - sinceLast) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.reloadButtonWidgets()
            }
        }
    }

    private func reloadButtonWidgets() {
        lastButtonsReload = Date()
        for kind in ["SonarWidget", "SonarWidgetTestA", "SonarWidgetTestB"] {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }

    // MARK: - Datos del inicio

    /// Lo llama el inicio cuando cambia lo que se ve (solo la portada normal, no la de un chip).
    func homeChanged(_ sections: [HomeSection]) {
        guard !sections.isEmpty else { return }
        var quick: [Source] = []
        var recent: [Source] = []
        var eps: [Source] = []
        var anySongs: [Source] = []
        var seenEpisodes = Set<String>()
        var seenSongs = Set<String>()
        for section in sections {
            if case .quickPicks(let items) = section, quick.isEmpty {
                quick = Self.sources(from: items)
            }
            // "Volver a escuchar" / "Acceso rapido" de YouTube Music: rellena el widget de Acceso rapido si no hay canciones fijadas.
            if case .keepListening(let items) = section, recent.isEmpty {
                recent = Self.sources(from: items)
            }
            for item in section.items {
                switch item {
                case .episode:
                    if let source = Self.source(from: item), seenEpisodes.insert(source.id).inserted { eps.append(source) }
                case .song:
                    if let source = Self.source(from: item), seenSongs.insert(source.id).inserted { anySongs.append(source) }
                default:
                    break
                }
            }
        }
        // Sin la seccion de Selecciones rapidas (puede estar desactivada), se usan las primeras canciones del inicio.
        quickPicks = Array((quick.isEmpty ? anySongs : quick).prefix(8))
        recentSongs = Array(recent.prefix(8))
        // Los episodios no suelen venir en la portada normal (estan en el chip Podcasts): solo se toman de aqui si aparecen.
        if !eps.isEmpty { episodes = Array(eps.prefix(8)) }
        schedule()
        fetchEpisodesIfNeeded()
    }

    // MARK: - Episodios (chip Podcasts)

    private func fetchEpisodesIfNeeded() {
        guard !fetchingEpisodes, Date().timeIntervalSince(episodesFetchedAt) > 1800 else { return }
        fetchingEpisodes = true
        Task { [weak self] in
            let found = await self?.fetchPodcastEpisodes() ?? []
            guard let self else { return }
            self.fetchingEpisodes = false
            // Si no salio nada (sin red, por ejemplo), se vuelve a intentar a los 5 minutos en vez de a la media hora.
            self.episodesFetchedAt = found.isEmpty ? Date().addingTimeInterval(-1500) : Date()
            if !found.isEmpty {
                self.episodes = Array(found.prefix(8))
                self.schedule()
            }
        }
    }

    /// "Tus nuevos episodios": estan en la portada del chip Podcasts del inicio de YouTube Music (se pide igual que "Pon Dormir").
    private func fetchPodcastEpisodes() async -> [Source] {
        guard NetworkMonitor.shared.hasConnection,
              let json = try? await InnerTubeClient.tropShared.browse(browseId: "FEmusic_home"),
              let page = HomePageParser.parseHomePage(from: json) else { return [] }
        let chip = page.chips.first { chip in
            chip.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased().contains("podcast")
        }
        guard let chip, let params = chip.params,
              let chipJson = try? await InnerTubeClient.tropShared.browse(
                  browseId: "FEmusic_home", params: params, locale: .deviceLanguage
              ),
              let chipPage = HomePageParser.parseHomePage(from: chipJson, chipMode: true) else { return [] }
        let newEpisodes = chipPage.sections.first {
            $0.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased().contains("episod")
        }
        let pool = newEpisodes.map { [$0] } ?? chipPage.sections
        var seen = Set<String>()
        var result: [Source] = []
        for section in pool {
            for item in section.items {
                if case .episode = item, let source = Self.source(from: item), seen.insert(source.id).inserted {
                    result.append(source)
                }
            }
        }
        PlaybackReport.record("widget: episodios del chip Podcasts: \(result.count)")
        return result
    }

    private static func sources(from items: [YTItem]) -> [Source] {
        items.compactMap { source(from: $0) }
    }

    private static func source(from item: YTItem) -> Source? {
        switch item {
        case .song(let song):
            return Source(
                id: song.videoId,
                title: song.title,
                artist: song.artists.map(\.name).joined(separator: ", "),
                thumbnailUrl: song.thumbnailUrl,
                duration: song.duration,
                isEpisode: song.musicVideoType == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"
            )
        case .episode(let episode):
            return Source(
                id: episode.videoId,
                title: episode.title,
                artist: episode.artists.map(\.name).joined(separator: ", "),
                thumbnailUrl: episode.thumbnailUrl,
                duration: episode.duration,
                isEpisode: true
            )
        default:
            return nil
        }
    }

    // MARK: - Escribir

    private func schedule() {
        task?.cancel()
        let quick = quickPicks
        let eps = episodes
        let recent = recentSongs
        task = Task { [weak self] in
            let entries = (try? await DatabaseService.shared.fetchSpeedDial(limit: 8)) ?? []
            // Primero las canciones que has fijado en el Acceso rapido; si faltan, las de "Volver a escuchar" del inicio.
            var dial = entries.map {
                Source(
                    id: $0.videoId, title: $0.title, artist: $0.artist, thumbnailUrl: $0.thumbnailUrl,
                    duration: $0.duration, isEpisode: false
                )
            }
            var seenDial = Set(dial.map(\.id))
            for source in recent where seenDial.insert(source.id).inserted { dial.append(source) }
            dial = Array(dial.prefix(8))
            guard !Task.isCancelled else { return }
            await self?.write(quick: quick, dial: dial, episodes: eps)
        }
    }

    private func write(quick: [Source], dial: [Source], episodes: [Source]) async {
        guard let found = WidgetShared.resolved else { return }
        // Lo mismo que ya se escribio hace poco: no se vuelve a descargar nada.
        let signature = [quick, dial, episodes].map { $0.map(\.id).joined(separator: ",") }.joined(separator: "|")
        if signature == lastSignature, Date().timeIntervalSince(lastWrite) < 600 { return }

        let coversDirectory = WidgetShared.coversDirectory(in: found.url)
        try? FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)

        var kept = Set<String>()
        let quickTracks = await tracks(from: quick, in: coversDirectory, kept: &kept)
        let dialTracks = await tracks(from: dial, in: coversDirectory, kept: &kept)
        let episodeTracks = await tracks(from: episodes, in: coversDirectory, kept: &kept)
        guard !Task.isCancelled else { return }

        // Se borran las portadas que ya no usa ninguna lista.
        if let files = try? FileManager.default.contentsOfDirectory(atPath: coversDirectory.path) {
            for file in files where !kept.contains(file) {
                try? FileManager.default.removeItem(at: coversDirectory.appendingPathComponent(file))
            }
        }

        let snapshot = WidgetSnapshot(
            updated: Date(),
            quickPicks: quickTracks,
            speedDial: dialTracks,
            episodes: episodeTracks
        )
        do {
            try WidgetShared.save(snapshot, in: found.url)
            lastSignature = signature
            lastWrite = Date()
            PlaybackReport.record(
                "widget: datos escritos (selecciones \(quickTracks.count), acceso rapido \(dialTracks.count), episodios \(episodeTracks.count))"
            )
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            PlaybackReport.record("widget: no se pudo escribir los datos: \(error.localizedDescription)")
        }
    }

    private func tracks(from sources: [Source], in directory: URL, kept: inout Set<String>) async -> [WidgetTrack] {
        var result: [WidgetTrack] = []
        for source in sources {
            let name = await Self.coverFile(for: source, in: directory)
            if let name { kept.insert(name) }
            result.append(
                WidgetTrack(
                    id: source.id, title: source.title, artist: source.artist, cover: name,
                    duration: source.duration, episode: source.isEpisode
                )
            )
        }
        return result
    }

    // MARK: - Portadas

    /// Google redimensiona la portada con "=w226-h226...": se pide de 480 px (las miniaturas de podcast son anchas y salen a ~150 pt).
    nonisolated private static func sizedURL(_ raw: String) -> URL? {
        let sized = raw.replacingOccurrences(of: "=w\\d+-h\\d+", with: "=w480-h480", options: .regularExpression)
        return URL(string: sized)
    }

    /// Descarga la portada (o reutiliza la de hace menos de una semana), la reduce y la guarda. Devuelve el nombre del archivo.
    nonisolated private static func coverFile(for source: Source, in directory: URL) async -> String? {
        guard let raw = source.thumbnailUrl, let url = sizedURL(raw) else { return nil }
        let safeId = source.id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safeId.isEmpty else { return nil }
        // "_v2": portadas de 480 px; las antiguas (240 px) se borran solas por no estar en ninguna lista.
        let name = safeId + "_v2.jpg"
        let file = directory.appendingPathComponent(name)

        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < 7 * 24 * 3600 {
            return name
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let image = UIImage(data: data),
              let jpeg = downscaled(image, maxSide: 480).jpegData(compressionQuality: 0.8) else {
            // Sin red: se conserva la portada vieja si la hay.
            return FileManager.default.fileExists(atPath: file.path) ? name : nil
        }
        do {
            try jpeg.write(to: file, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    /// WidgetKit no acepta imagenes grandes: se reducen a 240 px como maximo.
    nonisolated private static func downscaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxSide, longest > 0 else { return image }
        let factor = maxSide / longest
        let target = CGSize(width: size.width * factor, height: size.height * factor)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
