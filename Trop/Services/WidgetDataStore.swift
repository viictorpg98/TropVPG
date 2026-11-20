//
//  WidgetDataStore.swift
//  Trop
//
//  Deja en la carpeta compartida con el widget lo que enseñan sus portadas: tus Selecciones rapidas y tu Acceso rapido, con las
//  portadas ya descargadas y reducidas (el widget no puede bajarlas ni leer la base de datos). Son RESERVAS de unas 20 canciones por
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

    /// Cuantas canciones se guardan por lista (el widget enseña un grupo de 4 cada vez): Selecciones rapidas 20 (5 grupos, que se reparten
    /// entre los dos widgets) y Acceso rapido 24 (6 grupos).
    private static let quickPoolSize = 20
    private static let dialPoolSize = 24
    /// Reserva de canciones de relleno de YouTube (se eligen 20 como maximo; con "Actualizar", otras al azar de las 40).
    private static let fillPoolSize = 40
    private static let lastShownKey = "widget.lastShown"
    private static let baseSignatureKey = "widget.baseSignature"

    /// Lo que ensena el inicio de la app (Selecciones rapidas puede ser la local de 20 canciones al azar de tus Me gusta, o la de YouTube).
    private var quickPicks: [Source] = []
    private var recentSongs: [Source] = []
    /// Las listas que el propio widget pide a YouTube (el inicio de la app puede ensenar menos): Selecciones rapidas suele traer ~20.
    private var fetchedQuick: [Source] = []
    private var fetchedRecent: [Source] = []
    /// Canciones de las demas secciones del inicio de YouTube (repartidas una a una entre ellas), para completar Selecciones rapidas
    /// cuando YouTube no la manda o trae menos de 20.
    private var fetchedFill: [Source] = []
    private var lastServerFetch = Date.distantPast
    private var lastServerSuccess = Date.distantPast
    /// La peticion del inicio de YouTube en marcha (una sola a la vez: la comparten la apertura de la app y "Actualizar").
    private var serverTask: Task<Int, Never>?
    private var fetchingServer: Bool { serverTask != nil }
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
        Task { await VoiceSearch.endOrphanedActivities() }
    }

    func appBecameActive() {
        if let found = WidgetShared.resolved {
            WidgetShared.writeProbe(groupId: found.id, bundleId: Bundle.main.bundleIdentifier ?? "", in: found.url)
        }
        // La app acaba de abrirse o de volver: si el DJ se quedo "encendido" en el dato de la ultima vez, se corrige.
        syncDJState()
        // El Acceso rapido sale de la base de datos: se vuelve a leer sin esperar a que cambie el inicio.
        schedule(force: false)
        fetchServerListsIfNeeded()
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
        quickPicks = Array(Self.deduplicated(quick).prefix(Self.quickPoolSize))
        recentSongs = Array(Self.deduplicated(recent).prefix(Self.dialPoolSize))
    }

    // MARK: - Boton "Actualizar"

    /// El boton "Actualizar" del widget de botones: vuelve a pedir el inicio de YouTube Music (las paginas que hagan falta para dar con Selecciones rapidas, 20 s como maximo), y reescribe
    /// las portadas aunque nada haya cambiado, poniendo en lo que los widgets enseñan ahora las canciones que llevan mas tiempo sin salir
    /// (`arranged`). Sin conexion, hace lo mismo con las reservas que ya hay.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        // Una escritura en curso (por un cambio del inicio) podria borrar portadas que esta escritura acaba de usar: se cancela.
        task?.cancel()
        // Pulsarlo varias veces seguidas no vuelve a pedir 5 paginas del inicio cada vez: si hay una lista de YouTube de hace menos de 10
        // minutos se reutiliza (la variedad la dan los Me gusta al azar y `arranged`).
        let age = Date().timeIntervalSince(lastServerSuccess)
        let origin: String
        if age > 600 {
            let count = await startServerFetch().value
            origin = "de YouTube: \(count) canciones"
        } else {
            origin = "lista reutilizada, de hace \(Int(age / 60)) min"
        }
        PlaybackReport.record(
            "widget: actualizar (\(origin); selecciones: YouTube \(fetchedQuick.count) + relleno \(fetchedFill.count), acceso rapido \(fetchedRecent.isEmpty ? recentSongs.count : fetchedRecent.count))"
        )
        await writeNow(force: true)
    }

    // MARK: - Listas pedidas a YouTube por el widget

    /// Al abrir la app, como mucho cada 30 minutos (cada peticion son varias paginas del inicio).
    private func fetchServerListsIfNeeded() {
        guard !fetchingServer, Date().timeIntervalSince(lastServerFetch) > 1800 else { return }
        // La peticion se crea AQUI, sin esperar: si la app avisa dos veces seguidas de que esta activa, la segunda ya la encuentra en marcha.
        let request = startServerFetch()
        Task { [weak self] in
            _ = await request.value
            // Con o sin datos nuevos: hasta ahora las escrituras esperaban a esto (ver `writeNow`).
            self?.schedule(force: false)
        }
    }

    /// Lanza la peticion del inicio de YouTube, o devuelve la que ya esta en marcha (asi no salen dos a la vez, ni al abrir la app ni al
    /// pulsar "Actualizar" justo despues de que un toque en el widget arranque la app).
    private func startServerFetch() -> Task<Int, Never> {
        if let running = serverTask { return running }
        let request = Task { [weak self] () -> Int in
            await self?.fetchServerLists() ?? 0
        }
        serverTask = request
        return request
    }

    /// Pide el inicio de YouTube (con las paginas que haga falta para dar con Selecciones rapidas) y se queda con sus dos listas de
    /// canciones, sin las que has marcado como "no me gusta", de artistas ocultos o explicitas si las ocultas. Devuelve cuantas canciones
    /// salieron. Sin conexion o con fallo no toca lo que ya habia y vuelve a intentarlo a los 5 minutos.
    private func fetchServerLists() async -> Int {
        defer { serverTask = nil }
        guard let sections = await SonarMix.homeSectionsForWidget() else {
            lastServerFetch = Date().addingTimeInterval(-1500)
            return 0
        }
        lastServerFetch = Date()
        lastServerSuccess = Date()
        var quick: [Source] = []
        var recent: [Source] = []
        // Canciones de las demas secciones (una lista por seccion), para completar Selecciones rapidas. Se dejan fuera "Volver a escuchar"
        // (es del Acceso rapido) y "Escuchas largas" (por su titulo; no se recorta nada por duracion).
        var otherSections: [[Source]] = []
        for section in sections {
            let items = section.items.filter { Self.allowed($0) }
            if HomeSectionTitles.isQuickPicks(section.title) {
                if quick.isEmpty { quick = Self.sources(from: items) }
            } else if HomeSectionTitles.isKeepListening(section.title) {
                if recent.isEmpty { recent = Self.sources(from: items) }
            } else if !HomeSectionTitles.isLongListens(section.title) {
                let songs = Self.songSources(from: items)
                if !songs.isEmpty { otherSections.append(songs) }
            }
        }
        // Reparto una a una entre las secciones (la primera de cada una, luego la segunda...), sin las que ya estan en Selecciones o en
        // Acceso rapido: asi el relleno mezcla lo que YouTube te propone en vez de ser una sola seccion.
        var fill: [Source] = []
        var used = Set(quick.map(\.id)).union(recent.map(\.id))
        var position = 0
        while fill.count < Self.fillPoolSize, otherSections.contains(where: { position < $0.count }) {
            for list in otherSections where position < list.count && fill.count < Self.fillPoolSize {
                if used.insert(list[position].id).inserted { fill.append(list[position]) }
            }
            position += 1
        }
        PlaybackReport.record(
            "widget: inicio de YouTube pedido: selecciones rapidas \(quick.count), acceso rapido \(recent.count), relleno \(fill.count) de \(otherSections.count) secciones (de \(sections.count) secciones)"
        )
        if !quick.isEmpty { fetchedQuick = Array(Self.deduplicated(quick).prefix(Self.quickPoolSize)) }
        if !recent.isEmpty { fetchedRecent = Array(Self.deduplicated(recent).prefix(Self.dialPoolSize)) }
        if !fill.isEmpty { fetchedFill = fill }
        return quick.count + recent.count + fill.count
    }

    /// Los mismos filtros que el inicio: "no me gusta", artistas ocultos y explicitas si estan ocultas.
    private static func allowed(_ item: YTItem) -> Bool {
        if case .song(let song) = item {
            if LikeStore.shared.disliked.contains(song.videoId) { return false }
            if SettingsStore.shared.hideExplicit && song.isExplicit { return false }
        }
        return !HiddenArtists.shared.blocks(item)
    }

    private static func deduplicated(_ sources: [Source]) -> [Source] {
        var seen = Set<String>()
        return sources.filter { seen.insert($0.id).inserted }
    }

    private static func sources(from items: [YTItem]) -> [Source] {
        items.compactMap { source(from: $0) }
    }

    /// Solo canciones (ni episodios, ni albumes, ni listas) y con portada, como el relleno con tus Me gusta.
    private static func songSources(from items: [YTItem]) -> [Source] {
        items.compactMap { item in
            guard case .song = item, let found = source(from: item), !found.isEpisode, found.thumbnailUrl != nil else { return nil }
            return found
        }
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
            await self?.writeNow(force: force)
        }
    }

    /// Junta lo fijado en el Acceso rapido, "Volver a escuchar" y tu historial local, y escribe las dos listas.
    private func writeNow(force: Bool) async {
        // Selecciones rapidas: la de YouTube que ha pedido el widget; si trae menos de 20 (o no la manda), se completa con canciones de las
        // demas secciones del inicio de YouTube (con "Actualizar", otras al azar de la reserva) y luego, abajo, con tus Me gusta. Sin nada de
        // YouTube (sin conexion) se usa la lista del inicio de la app.
        var quickBase = fetchedQuick
        if quickBase.count < Self.quickPoolSize {
            let have = Set(quickBase.map(\.id))
            var extra = fetchedFill.filter { !have.contains($0.id) }
            if force { extra.shuffle() }
            quickBase += extra.prefix(Self.quickPoolSize - quickBase.count)
        }
        let noYouTubeLists = fetchedQuick.isEmpty && fetchedFill.isEmpty
        if noYouTubeLists { quickBase = quickPicks }
        let recent = fetchedRecent.isEmpty ? recentSongs : fetchedRecent
        let entries = (try? await DatabaseService.shared.fetchSpeedDial(limit: Self.dialPoolSize)) ?? []
        // Primero las canciones que has fijado en el Acceso rapido; luego las de "Volver a escuchar" y, para que haya variedad aunque no
        // fijes nada, canciones de tu historial local (recientes y mas escuchadas, alternadas).
        var dial = entries.map {
            Source(
                id: $0.videoId, title: $0.title, artist: $0.artist, thumbnailUrl: $0.thumbnailUrl,
                duration: $0.duration, isEpisode: false
            )
        }
        // Si lo que viene de YouTube y lo fijado es lo mismo que la ultima vez, no se hace nada (ni base de datos ni descargas): asi lo que
        // dejo "Actualizar" no se desordena al abrir la app. Con "Actualizar" siempre se sigue adelante.
        // La firma usa TODA la reserva de relleno (no los 20 elegidos, que con "Actualizar" son al azar): si no, al abrir la app se reescribiria
        // lo que dejo "Actualizar".
        let signatureQuick = noYouTubeLists ? quickPicks : fetchedQuick + fetchedFill
        let baseSignature = [signatureQuick, recent, dial].map { $0.map(\.id).sorted().joined(separator: ",") }.joined(separator: "|")
        if !force, baseSignature == UserDefaults.standard.string(forKey: Self.baseSignatureKey), WidgetShared.loadSnapshot() != nil { return }
        // Al abrir la app, hasta que no se sepa que trae YouTube (la peticion esta en marcha o no ha empezado) no se escribe nada si ya hay datos:
        // si no, se escribian Me gusta al azar encima de la lista de YouTube y luego otra vez al llegar. Al terminar la peticion se escribe.
        if !force, noYouTubeLists, fetchingServer || lastServerFetch == .distantPast, WidgetShared.loadSnapshot() != nil { return }

        // Si Selecciones rapidas trae menos de 20, se completa con tus Me gusta (con "Actualizar", otros al azar).
        var quick = quickBase
        if quick.count < Self.quickPoolSize {
            let have = Set(quick.map(\.id))
            quick += await likedFill(excluding: have, count: Self.quickPoolSize - quick.count, shuffled: force)
        }
        guard !Task.isCancelled else { return }
        var seenDial = Set(dial.map(\.id))
        for source in recent where seenDial.insert(source.id).inserted { dial.append(source) }
        for source in await localHistory() where seenDial.insert(source.id).inserted { dial.append(source) }
        // Las canciones de Selecciones rapidas no se repiten en Acceso rapido (siempre que a este le queden suficientes).
        let quickIds = Set(quick.map(\.id))
        let withoutQuick = dial.filter { !quickIds.contains($0.id) }
        if withoutQuick.count >= 4 { dial = withoutQuick }
        dial = Array(dial.prefix(Self.dialPoolSize))
        guard !Task.isCancelled else { return }
        await write(quick: quick, dial: dial, force: force, baseSignature: baseSignature)
    }

    /// Canciones de tus Me gusta (con portada, sin episodios, "no me gusta" ni artistas ocultos) para completar Selecciones rapidas.
    private func likedFill(excluding ids: Set<String>, count: Int, shuffled: Bool) async -> [Source] {
        guard count > 0, let liked = try? await DatabaseService.shared.fetchLikedSongs() else { return [] }
        var pool = liked.filter { !$0.isEpisode && $0.thumbnailUrl != nil && !ids.contains($0.id) }
        if shuffled { pool.shuffle() }
        var result: [Source] = []
        for entity in pool where result.count < count {
            let song = SongItem(entity: entity)
            guard Self.allowed(.song(song)) else { continue }
            if let source = Self.source(from: .song(song)) { result.append(source) }
        }
        return result
    }

    /// Canciones de tu historial local (las de los ultimos 60 dias y las mas escuchadas) con portada, sin episodios ni artistas ocultos.
    private func localHistory() async -> [Source] {
        let recent = (try? await DatabaseService.shared.fetchRecentSongs(days: 60, limit: 30)) ?? []
        let top = (try? await DatabaseService.shared.fetchTopSongs(limit: 30)) ?? []
        // Sin barajar (se llamaria en cada apertura y la lista cambiaria sola): recientes y mas escuchadas alternadas. La variedad la da `arranged`.
        var mixed: [SongEntity] = []
        for index in 0..<max(recent.count, top.count) {
            if index < recent.count { mixed.append(recent[index]) }
            if index < top.count { mixed.append(top[index]) }
        }
        var seen = Set<String>()
        var result: [Source] = []
        for entity in mixed where !entity.isEpisode && entity.thumbnailUrl != nil && seen.insert(entity.id).inserted {
            let song = SongItem(entity: entity)
            if HiddenArtists.shared.isHidden(song) { continue }
            if let source = Self.source(from: .song(song)) { result.append(source) }
        }
        return result
    }

    // MARK: - Que canciones salen con "Actualizar"

    private func lastShownTimes() -> [String: Double] {
        let all = (UserDefaults.standard.dictionary(forKey: Self.lastShownKey) as? [String: Double]) ?? [:]
        let cutoff = Date().timeIntervalSince1970 - 14 * 86_400
        return all.filter { $0.value > cutoff }
    }

    /// Reordena una lista para que en las posiciones que los widgets ensenan AHORA (`visible`) queden las canciones que mas tiempo llevan
    /// sin salir (las que nunca han salido, primero, al azar), y apunta cuando sale cada una. Asi pulsar "Actualizar" no repite lo que acabas
    /// de ver y, antes de repetir una, pasan todas las demas. El resto de posiciones se llena en el mismo orden (de mas antiguas a mas
    /// recientes), y por eso las siguientes rotaciones por reloj tambien traen canciones que llevan tiempo sin salir.
    private func arranged(_ tracks: [WidgetTrack], visible: [Int], times: inout [String: Double], at date: Date) -> [WidgetTrack] {
        guard tracks.count > 4 else { return tracks }
        let snapshot = times
        let ranked = tracks.shuffled().sorted { (snapshot[$0.id] ?? 0) < (snapshot[$1.id] ?? 0) }
        var order: [Int] = []
        var taken = Set<Int>()
        for position in visible where position < tracks.count && taken.insert(position).inserted { order.append(position) }
        for position in 0..<tracks.count where !taken.contains(position) { order.append(position) }
        var result = tracks
        for (rank, position) in order.enumerated() { result[position] = ranked[rank] }
        let stamp = date.timeIntervalSince1970
        for position in visible where position < result.count { times[result[position].id] = stamp }
        return result
    }

    private func write(quick: [Source], dial: [Source], force: Bool, baseSignature: String) async {
        guard let found = WidgetShared.resolved else { return }
        // Lo mismo que ya se escribio hace poco: no se vuelve a descargar nada (salvo si se fuerza, como con "Actualizar").
        let signature = [quick, dial].map { $0.map(\.id).sorted().joined(separator: ",") }.joined(separator: "|")
        if !force, signature == lastSignature, Date().timeIntervalSince(lastWrite) < 600 { return }
        // La app puede haber arrancado en segundo plano (al pulsar un boton) sin haber leido aun el inicio, o sin red: las listas vacias
        // NO deben borrar lo que el widget ya enseña. Con las dos vacias no hay nada que escribir.
        let existing = WidgetShared.loadSnapshot()
        if !force, quick.isEmpty, dial.isEmpty, existing != nil { return }
        // Mismas canciones que las ya escritas (aunque en otro orden): no se toca nada, asi lo que dejo "Actualizar" se conserva al abrir la app.
        if !force, let existing,
           quick.isEmpty || Set(existing.quickPicks.map(\.id)) == Set(quick.map(\.id)),
           dial.isEmpty || Set(existing.speedDial.map(\.id)) == Set(dial.map(\.id)) {
            return
        }

        let coversDirectory = WidgetShared.coversDirectory(in: found.url)
        try? FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)

        var quickTracks: [WidgetTrack] = []
        if !quick.isEmpty { quickTracks = await tracks(from: quick, in: coversDirectory) }
        var dialTracks: [WidgetTrack] = []
        if !dial.isEmpty { dialTracks = await tracks(from: dial, in: coversDirectory) }
        guard !Task.isCancelled else { return }
        // Una lista vacia conserva la que habia en disco.
        if quickTracks.isEmpty, let old = existing?.quickPicks, !old.isEmpty { quickTracks = old }
        if dialTracks.isEmpty, let old = existing?.speedDial, !old.isEmpty { dialTracks = old }
        // "Actualizar": en lo que los widgets enseñan ahora se ponen canciones que llevan tiempo sin salir.
        if force {
            let now = Date()
            var times = lastShownTimes()
            let visibleA = WidgetRotation.visibleIndices(count: quickTracks.count, date: now, second: false)
            let visibleB = WidgetRotation.visibleIndices(count: quickTracks.count, date: now, second: true)
            quickTracks = arranged(quickTracks, visible: visibleA + visibleB, times: &times, at: now)
            dialTracks = arranged(
                dialTracks,
                visible: WidgetRotation.visibleIndices(count: dialTracks.count, date: now, second: false),
                times: &times, at: now
            )
            UserDefaults.standard.set(times, forKey: Self.lastShownKey)
        }

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
            UserDefaults.standard.set(baseSignature, forKey: Self.baseSignatureKey)
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
