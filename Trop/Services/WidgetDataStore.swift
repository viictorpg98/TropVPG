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
    }

    private var quickPicks: [Source] = []
    private var episodes: [Source] = []
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
    }

    private func reportShare() {
        let tried = WidgetShared.candidateGroups().joined(separator: ", ")
        let infoGroups = (Bundle.main.infoDictionary?["ALTAppGroups"] as? [String])?.joined(separator: ", ") ?? "(ninguno)"
        let resolved = WidgetShared.resolved?.id ?? "NINGUNO"
        PlaybackReport.record(
            "widget: ALTAppGroups=[\(infoGroups)] bundle=\(Bundle.main.bundleIdentifier ?? "?") probados=[\(tried)] carpeta compartida=\(resolved)"
        )
    }

    // MARK: - Datos del inicio

    /// Lo llama el inicio cuando cambia lo que se ve (solo la portada normal, no la de un chip).
    func homeChanged(_ sections: [HomeSection]) {
        guard !sections.isEmpty else { return }
        var quick: [Source] = []
        var eps: [Source] = []
        var anySongs: [Source] = []
        var seenEpisodes = Set<String>()
        var seenSongs = Set<String>()
        for section in sections {
            if case .quickPicks(let items) = section, quick.isEmpty {
                quick = Self.sources(from: items)
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
        episodes = Array(eps.prefix(8))
        schedule()
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
                thumbnailUrl: song.thumbnailUrl
            )
        case .episode(let episode):
            return Source(
                id: episode.videoId,
                title: episode.title,
                artist: episode.artists.map(\.name).joined(separator: ", "),
                thumbnailUrl: episode.thumbnailUrl
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
        task = Task { [weak self] in
            let entries = (try? await DatabaseService.shared.fetchSpeedDial(limit: 8)) ?? []
            let dial = entries.map {
                Source(id: $0.videoId, title: $0.title, artist: $0.artist, thumbnailUrl: $0.thumbnailUrl)
            }
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
            result.append(WidgetTrack(id: source.id, title: source.title, artist: source.artist, cover: name))
        }
        return result
    }

    // MARK: - Portadas

    /// Google redimensiona la portada con "=w226-h226...": se pide de 300 px, de sobra para el widget.
    nonisolated private static func sizedURL(_ raw: String) -> URL? {
        let sized = raw.replacingOccurrences(of: "=w\\d+-h\\d+", with: "=w300-h300", options: .regularExpression)
        return URL(string: sized)
    }

    /// Descarga la portada (o reutiliza la de hace menos de una semana), la reduce y la guarda. Devuelve el nombre del archivo.
    nonisolated private static func coverFile(for source: Source, in directory: URL) async -> String? {
        guard let raw = source.thumbnailUrl, let url = sizedURL(raw) else { return nil }
        let safeId = source.id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safeId.isEmpty else { return nil }
        let name = safeId + ".jpg"
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
              let jpeg = downscaled(image, maxSide: 240).jpegData(compressionQuality: 0.8) else {
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
