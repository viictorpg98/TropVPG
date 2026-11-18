//
//  WidgetDataStore.swift
//  Trop
//
//  Deja en la carpeta compartida con el widget lo que enseñan sus portadas: tus Selecciones rapidas y tu Acceso rapido, con las
//  portadas ya descargadas y reducidas (el widget no puede bajarlas ni leer la base de datos). Son RESERVAS de unas 16 canciones por
//  lista: cada widget ensena un grupo de 4 y va pasando de grupo con el tiempo (ver `CoverProvider`), asi que no se ve
//  siempre lo mismo. Se actualiza cuando cambia el inicio, al volver a la app y con el boton "Actualizar" del widget de botones.
//  Tambien guarda si el DJ esta encendido (para que su boton lo enseñe). Nunca se guardan cookies ni datos de la cuenta, solo
//  titulos, artistas, identificadores y portadas.
//

import Foundation
import UIKit
import WidgetKit

@MainActor
final class WidgetDataStore {
    static let shared = WidgetDataStore()

    /// Lo minimo de una cancion para el widget (valores simples: se pasan fuera del hilo principal).
    struct Source: Hashable, Sendable {
        let id: String
        let title: String
        let artist: String
        let thumbnailUrl: String?
        let duration: Int
        let isEpisode: Bool
    }

    /// Cuantas canciones se guardan por lista: 4 grupos de 4 (el widget enseña un grupo cada vez).
    private static let poolSize = 16

    private var quickPicks: [Source] = []
    private var recentSongs: [Source] = []
    private var task: Task<Void, Never>?
    private var lastSignature = ""
    private var lastWrite = Date.distantPast
    private var refreshing = false

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
        // La app acaba de abrirse o de volver: si el DJ se quedo "encendido" en el dato de la ultima vez, se corrige.
        syncDJState()
        // El Acceso rapido sale de la base de datos: se vuelve a leer sin esperar a que cambie el inicio.
        schedule(force: false)
    }

    private func reportShare() {
        let tried = WidgetShared.candidateGroups().joined(separator: ", ")
        let infoGroups = (Bundle.main.infoDictionary?["ALTAppGroups"] as? [String])?.joined(separator: ", ") ?? "(ninguno)"
        let resolved = WidgetShared.resolved?.id ?? "NINGUNO"
        PlaybackReport.record(
            "widget: ALTAppGroups=[\(infoGroups)] bundle=\(Bundle.main.bundleIdentifier ?? "?") probados=[\(tried)] carpeta compartida=\(resolved)"
        )
    }

    // MARK: - Boton DJ

    private var lastDJ: Bool?
    private var lastButtonsReload = Date.distantPast
    private var buttonsReloadTask: Task<Void, Never>?

    /// Lo llama `DJSession` al encender o apagar el DJ: deja el dato en la carpeta compartida y recarga el widget de botones para que
    /// el boton se vea encendido o apagado. El sistema limita las recargas, asi que como mucho se pide una cada 5 s (si hay mas
    /// cambios seguidos, se juntan y queda el ultimo).
    func djChanged(_ on: Bool) {
        guard lastDJ != on else { return }
        lastDJ = on
        guard let found = WidgetShared.resolved else { return }
        WidgetShared.writeButtonState(WidgetButtonState(dj: on, updated: Date()), in: found.url)
        let sinceLast = Date().timeIntervalSince(lastButtonsReload)
        buttonsReloadTask?.cancel()
        if sinceLast >= 5 {
            reloadButtonWidgets()
        } else {
            buttonsReloadTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((5 - sinceLast) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.reloadButtonWidgets()
            }
        }
    }

    /// El DJ no se guarda entre aperturas: si iOS cerro la app con el DJ encendido, el dato de la carpeta compartida seguiria diciendo
    /// "encendido". Al arrancar se vuelve a escribir lo real.
    private func syncDJState() {
        let active = DJSession.shared.isActive
        if lastDJ == nil {
            lastDJ = active
            guard let found = WidgetShared.resolved else { return }
            let stored = WidgetShared.loadButtonState()?.dj
            if stored != active {
                WidgetShared.writeButtonState(WidgetButtonState(dj: active, updated: Date()), in: found.url)
                reloadButtonWidgets()
            }
        } else {
            djChanged(active)
        }
    }

    private func reloadButtonWidgets() {
        lastButtonsReload = Date()
        WidgetCenter.shared.reloadTimelines(ofKind: "SonarWidget")
    }

    // MARK: - Datos del inicio

    /// Lo llama el inicio cuando cambia lo que se ve (solo la portada normal, no la de un chip).
    func homeChanged(_ sections: [HomeSection]) {
        guard !sections.isEmpty else { return }
        var quick: [Source] = []
        var recent: [Source] = []
        var anySongs: [Source] = []
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
                if case .song = item, let source = Self.source(from: item), seenSongs.insert(source.id).inserted {
                    anySongs.append(source)
                }
            }
        }
        // Sin la seccion de Selecciones rapidas (puede estar desactivada), se usan las primeras canciones del inicio.
        setPools(quick: quick.isEmpty ? anySongs : quick, recent: recent)
        schedule(force: false)
    }

    private func setPools(quick: [Source], recent: [Source]) {
        quickPicks = Array(Self.deduplicated(quick).prefix(Self.poolSize))
        recentSongs = Array(Self.deduplicated(recent).prefix(Self.poolSize))
    }

    // MARK: - Boton "Actualizar"

    /// El boton "Actualizar" del widget de botones: vuelve a pedir el inicio de YouTube Music (una peticion, con limite de 10 s), baraja
    /// de nuevo las reservas y reescribe las portadas aunque nada haya cambiado. Sin conexion, solo las baraja.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        // Una escritura en curso (por un cambio del inicio) podria borrar portadas que esta escritura acaba de usar: se cancela.
        task?.cancel()
        var fetched = 0
        if let sections = await SonarMix.homeSectionsForWidget() {
            var quick: [Source] = []
            var recent: [Source] = []
            var anySongs: [Source] = []
            for section in sections {
                let items = Self.sources(from: section.items)
                if HomeSectionTitles.isQuickPicks(section.title), quick.isEmpty {
                    quick = items
                } else if HomeSectionTitles.isKeepListening(section.title), recent.isEmpty {
                    recent = items
                }
                anySongs.append(contentsOf: items)
            }
            fetched = quick.count + recent.count
            if fetched > 0 { setPools(quick: quick.isEmpty ? anySongs : quick, recent: recent) }
        }
        PlaybackReport.record("widget: actualizar (inicio: \(fetched) canciones, selecciones \(quickPicks.count), acceso rapido \(recentSongs.count))")
        // Con o sin datos nuevos, siempre se baraja otra vez: el boton tiene que notarse.
        quickPicks.shuffle()
        recentSongs.shuffle()
        await writeNow(force: true, reshuffle: true)
    }

    private static func deduplicated(_ sources: [Source]) -> [Source] {
        var seen = Set<String>()
        return sources.filter { seen.insert($0.id).inserted }
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

    private func schedule(force: Bool) {
        task?.cancel()
        task = Task { [weak self] in
            await self?.writeNow(force: force, reshuffle: false)
        }
    }

    /// Junta lo fijado en el Acceso rapido con "Volver a escuchar" y escribe las tres listas.
    private func writeNow(force: Bool, reshuffle: Bool) async {
        let quick = quickPicks
        let recent = recentSongs
        let entries = (try? await DatabaseService.shared.fetchSpeedDial(limit: Self.poolSize)) ?? []
        // Primero las canciones que has fijado en el Acceso rapido; si faltan, las de "Volver a escuchar" del inicio.
        var dial = entries.map {
            Source(
                id: $0.videoId, title: $0.title, artist: $0.artist, thumbnailUrl: $0.thumbnailUrl,
                duration: $0.duration, isEpisode: false
            )
        }
        var seenDial = Set(dial.map(\.id))
        for source in recent where seenDial.insert(source.id).inserted { dial.append(source) }
        // Con "Actualizar" tambien se baraja lo fijado: si no, el Acceso rapido ensenaria siempre lo mismo.
        if reshuffle { dial.shuffle() }
        dial = Array(dial.prefix(Self.poolSize))
        guard !Task.isCancelled else { return }
        await write(quick: quick, dial: dial, force: force)
    }

    private func write(quick: [Source], dial: [Source], force: Bool) async {
        guard let found = WidgetShared.resolved else { return }
        // Lo mismo que ya se escribio hace poco: no se vuelve a descargar nada (salvo si se fuerza, como con "Actualizar").
        let signature = [quick, dial].map { $0.map(\.id).joined(separator: ",") }.joined(separator: "|")
        if !force, signature == lastSignature, Date().timeIntervalSince(lastWrite) < 600 { return }
        // La app puede haber arrancado en segundo plano (al pulsar un boton) sin haber leido aun el inicio, o sin red: las listas vacias
        // NO deben borrar lo que el widget ya enseña. Con las dos vacias no hay nada que escribir.
        let existing = WidgetShared.loadSnapshot()
        if quick.isEmpty, dial.isEmpty, existing != nil { return }

        let coversDirectory = WidgetShared.coversDirectory(in: found.url)
        try? FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)

        var quickTracks: [WidgetTrack] = []
        if !quick.isEmpty { quickTracks = await tracks(from: quick, in: coversDirectory) }
        var dialTracks: [WidgetTrack] = []
        if !dial.isEmpty { dialTracks = await tracks(from: dial, in: coversDirectory) }
        guard !Task.isCancelled else { return }
        // Una lista vacia conserva la que habia en disco (con "Actualizar" y sin datos nuevos, solo se baraja).
        if quickTracks.isEmpty, let old = existing?.quickPicks, !old.isEmpty { quickTracks = force ? old.shuffled() : old }
        if dialTracks.isEmpty, let old = existing?.speedDial, !old.isEmpty { dialTracks = force ? old.shuffled() : old }

        // Se borran las portadas que ya no usa ninguna lista (las de las listas conservadas cuentan como usadas).
        var kept = Set<String>()
        for track in quickTracks + dialTracks {
            if let cover = track.cover { kept.insert(cover) }
        }
        if let files = try? FileManager.default.contentsOfDirectory(atPath: coversDirectory.path) {
            for file in files where !kept.contains(file) {
                try? FileManager.default.removeItem(at: coversDirectory.appendingPathComponent(file))
            }
        }

        let snapshot = WidgetSnapshot(updated: Date(), quickPicks: quickTracks, speedDial: dialTracks)
        do {
            try WidgetShared.save(snapshot, in: found.url)
            lastSignature = signature
            lastWrite = Date()
            PlaybackReport.record("widget: datos escritos (selecciones \(quickTracks.count), acceso rapido \(dialTracks.count))")
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            PlaybackReport.record("widget: no se pudo escribir los datos: \(error.localizedDescription)")
        }
    }

    private func tracks(from sources: [Source], in directory: URL) async -> [WidgetTrack] {
        var result: [WidgetTrack] = []
        for source in sources {
            let name = await Self.coverFile(for: source, in: directory)
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

    /// Google redimensiona la portada con "=w226-h226...": se pide de 480 px.
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

    /// WidgetKit no acepta imagenes grandes: se reducen a 480 px como maximo.
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
