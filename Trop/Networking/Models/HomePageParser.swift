//
//  HomePageParser.swift
//  Trop
//
//  Created by 686udjie on 01/07/2026.
//

import Foundation

enum HomePageParser {
    /// `chipMode`: la portada de un chip (Dormir, Relax...): ahi tambien se aceptan carruseles sin titulo y listas de
    /// canciones (el Acceso rapido del chip puede venir asi), y se apunta en el informe lo que no se sabe leer.
    static func parseHomePage(from json: [String: Any], chipMode: Bool = false) -> HomePage? {
        guard let sectionList = BrowseLens.sectionList(json) else {
            return nil
        }

        let chips = parseChips(from: sectionList)
        let sections = parseSections(from: sectionList, chipMode: chipMode)
        let continuation = extractContinuation(from: sectionList)

        return HomePage(chips: chips, sections: sections, continuation: continuation)
    }

    static func parseContinuationSections(from json: [String: Any]) -> (sections: [HomePage.Section], continuation: String?)? {
        guard let continuationContents = json["continuationContents"] as? [String: Any],
              let sectionList = continuationContents["sectionListContinuation"] as? [String: Any] else {
            return nil
        }

        let sections = parseSections(from: sectionList)
        let continuation = extractContinuation(from: sectionList)
        return (sections, continuation)
    }
}

// MARK: - Chips

extension HomePageParser {
    static func parseChips(from sectionList: [String: Any]) -> [HomePage.Chip] {
        guard let header = sectionList["header"] as? [String: Any],
              let chipCloud = header["chipCloudRenderer"] as? [String: Any],
              let chips = chipCloud["chips"] as? [[String: Any]] else {
            return []
        }
        return chips.compactMap { chipDict in
            guard let chipRenderer = chipDict["chipCloudChipRenderer"] as? [String: Any] else { return nil }
            let title = InnerTubeJSON.runsText(chipRenderer["text"] as? [String: Any]) ?? ""
            let nav = chipRenderer["navigationEndpoint"] as? [String: Any]
            let params = (nav?["browseEndpoint"] as? [String: Any])?["params"] as? String
            return HomePage.Chip(title: title, params: params)
        }
    }
}

// MARK: - Sections

extension HomePageParser {
    static func parseSections(from sectionList: [String: Any], chipMode: Bool = false) -> [HomePage.Section] {
        guard let contents = sectionList["contents"] as? [[String: Any]] else { return [] }
        return contents.compactMap { dict -> HomePage.Section? in
            if let section = parseSection(from: dict, chipMode: chipMode) { return section }
            noteUnreadSection(dict, always: chipMode)
            return nil
        }
    }

    static func parseSection(from contentDict: [String: Any], chipMode: Bool = false) -> HomePage.Section? {
        if let carousel = contentDict["musicCarouselShelfRenderer"] as? [String: Any] {
            return parseCarouselSection(from: carousel, chipMode: chipMode)
        }
        if let shelf = contentDict["musicShelfRenderer"] as? [String: Any] {
            return parseShelfSection(from: shelf, chipMode: chipMode)
        }
        return nil
    }

    /// Lista vertical (musicShelfRenderer): solo se acepta si trae episodios, como "Tus nuevos episodios" en el
    /// chip Podcasts. Las demas listas de este tipo no se enseñaban y se siguen sin enseñar.
    static func parseShelfSection(from shelf: [String: Any], chipMode: Bool = false) -> HomePage.Section? {
        let items = parseItems(from: shelf["contents"] as? [[String: Any]] ?? [])
        let hasEpisodes = items.contains(where: { if case .episode = $0 { return true } else { return false } })
        // Con un chip elegido se aceptan tambien las listas de canciones (antes solo las de episodios).
        guard hasEpisodes || (chipMode && !items.isEmpty) else { return nil }
        let title = InnerTubeJSON.runsText(shelf["title"] as? [String: Any]) ?? (chipMode && !hasEpisodes ? "" : "Episodes")
        return HomePage.Section(title: title, items: items, moreBrowseId: extractShelfMoreBrowseId(shelf))
    }

    private static let unreadLock = NSLock()
    nonisolated(unsafe) private static var unreadKinds = Set<String>()

    /// Apunta (una vez por tipo y por arranque) las secciones que no se saben leer, para poder ver que llega
    /// en el Informe de reproduccion si falta algo en la portada.
    private static func noteUnreadSection(_ dict: [String: Any], always: Bool = false) {
        let kinds = dict.keys.filter { $0 != "continuationItemRenderer" }.sorted().joined(separator: ",")
        guard !kinds.isEmpty else { return }
        if always {
            // En la portada de un chip se apunta cada vez (para ver que llega).
            PlaybackReport.record("chip: seccion sin leer (\(kinds))")
            return
        }
        unreadLock.lock()
        let isNew = unreadKinds.insert(kinds).inserted
        unreadLock.unlock()
        if isNew { PlaybackReport.record("portada: seccion sin leer (\(kinds))") }
    }

    static func parseCarouselSection(from carousel: [String: Any], chipMode: Bool = false) -> HomePage.Section? {
        let basicHeader = (carousel["header"] as? [String: Any])?["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any]
        let title = InnerTubeJSON.runsText(basicHeader?["title"] as? [String: Any])
        // Sin titulo solo se acepta con un chip elegido (en la portada normal siguen sin enseñarse).
        guard title != nil || chipMode else { return nil }

        let items = parseItems(from: carousel["contents"] as? [[String: Any]] ?? [])

        guard !items.isEmpty else { return nil }

        return HomePage.Section(
            title: title ?? "",
            items: items,
            moreBrowseId: basicHeader.flatMap { extractMoreBrowseId(in: $0) }
        )
    }

    /// Destino del boton "mas" (la flecha del titulo) de una seccion en forma de carrusel.
    static func extractMoreBrowseId(in header: [String: Any]) -> String? {
        let button = (header["moreContentButton"] as? [String: Any])?["buttonRenderer"] as? [String: Any]
        let endpoint = button?["navigationEndpoint"] as? [String: Any]
        return (endpoint?["browseEndpoint"] as? [String: Any])?["browseId"] as? String
    }

    /// Lo mismo para una lista vertical: el enlace del titulo o el de abajo ("ver todo").
    static func extractShelfMoreBrowseId(_ shelf: [String: Any]) -> String? {
        if let bottom = (shelf["bottomEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any],
           let id = bottom["browseId"] as? String {
            return id
        }
        let runs = (shelf["title"] as? [String: Any])?["runs"] as? [[String: Any]]
        let endpoint = runs?.first?["navigationEndpoint"] as? [String: Any]
        return (endpoint?["browseEndpoint"] as? [String: Any])?["browseId"] as? String
    }

    static func parseItems(from contents: [[String: Any]]) -> [YTItem] {
        contents.compactMap { itemDict in
            if let twoRow = itemDict["musicTwoRowItemRenderer"] as? [String: Any] {
                return parseTwoRowItem(twoRow)
            }
            if let responsiveList = itemDict["musicResponsiveListItemRenderer"] as? [String: Any] {
                return SongItem.from(responsiveList).map { YTItem.song($0) }
            }
            if let multiRow = itemDict["musicMultiRowListItemRenderer"] as? [String: Any] {
                return parseMultiRowEpisode(multiRow).map { YTItem.episode($0) }
            }
            return nil
        }
    }

    /// Episodio de una lista (musicMultiRowListItemRenderer), como los de "Tus nuevos episodios".
    static func parseMultiRowEpisode(_ renderer: [String: Any]) -> EpisodeItem? {
        guard let onTap = renderer["onTap"] as? [String: Any],
              let watch = onTap["watchEndpoint"] as? [String: Any],
              let videoId = watch["videoId"] as? String else { return nil }
        let title = InnerTubeJSON.runsText(renderer["title"] as? [String: Any]) ?? "Unknown"

        var thumbnailUrl: String?
        if let thumb = (renderer["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any],
           let inner = thumb["thumbnail"] as? [String: Any],
           let list = inner["thumbnails"] as? [[String: Any]] {
            thumbnailUrl = list.last?["url"] as? String
        }

        var duration = 0
        if let progress = (renderer["playbackProgress"] as? [String: Any])?["musicPlaybackProgressRenderer"] as? [String: Any],
           let text = InnerTubeJSON.runsText(progress["durationText"] as? [String: Any]), !text.isEmpty {
            duration = DurationFormat.parseClock(text) ?? DurationFormat.parseSpoken(text) ?? 0
        }

        // Subtitulo tipo "17k visualizaciones • hace 4 h • 1 h 23 min": se conserva la fecha.
        var publishDate: String?
        let runs = ((renderer["subtitle"] as? [String: Any])?["runs"] as? [[String: Any]]) ?? []
        for run in runs {
            let text = ((run["text"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text == "•" || text.contains(":") { continue }
            let lower = text.lowercased()
            if ServerText.isViewsText(lower) { continue }
            if !ServerText.isRelativeDate(lower), DurationFormat.parseSpoken(text) != nil { continue }
            if publishDate == nil { publishDate = text }
        }

        return EpisodeItem(
            videoId: videoId,
            title: title,
            artists: [],
            duration: duration,
            thumbnailUrl: thumbnailUrl,
            publishDate: publishDate,
            descriptionText: InnerTubeJSON.runsText(renderer["description"] as? [String: Any]),
            viewsText: nil
        )
    }

    static func parseTwoRowItem(_ renderer: [String: Any]) -> YTItem? {
        let pageType = extractPageType(renderer)
        let hasWatchEndpoint = hasWatchEndpoint(renderer)

        if hasWatchEndpoint && pageType == nil {
            return SongItem.from(renderer).map { YTItem.song($0) }
        }
        switch pageType {
        case "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_AUDIOBOOK":
            return AlbumItem.from(renderer).map { YTItem.album($0) }
        case "MUSIC_PAGE_TYPE_ARTIST":
            return ArtistItem.from(renderer).map { YTItem.artist($0) }
        case "MUSIC_PAGE_TYPE_PLAYLIST":
            return PlaylistItem.from(renderer).map { YTItem.playlist($0) }
        case "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE":
            return PodcastItem.from(renderer).map { YTItem.podcast($0) }
        case "MUSIC_PAGE_TYPE_NON_MUSIC_AUDIO_TRACK_PAGE":
            return EpisodeItem.from(renderer).map { YTItem.episode($0) }
        default:
            return nil
        }
    }
}

// MARK: - Explore

extension HomePageParser {
    static let exploreBrowseId = "FEmusic_explore"
    static let moodsCategoryBrowseId = "FEmusic_moods_and_genres_category"

    /// Parses `FEmusic_explore` into categorized sections. Logs the raw
    /// structure at every level so the mapping can be tailored from logs:
    /// renderer keys per section, header browseIds, item counts and the
    /// first item's renderer keys.
    static func parseExploreSections(from json: [String: Any]) -> [ExploreSection] {
        guard let contents = json["contents"] as? [String: Any] else {
            Log.explore.error("Explore parse failed: missing contents, top keys=\(json.keys.sorted())")
            return []
        }
        guard let sections = BrowseLens.browseSections(json) else {
            Log.explore.error("Explore parse failed: bad section path, contents keys=\(contents.keys.sorted())")
            return []
        }
        Log.explore.debug("Explore raw: \(sections.count) sections")
        var output: [ExploreSection] = []
        for (index, sectionDict) in sections.enumerated() {
            let keys = sectionDict.keys.sorted()
            Log.explore.debug("Explore section[\(index)] keys=\(keys)")
            if let parsed = parseExploreSection(sectionDict, index: index) {
                output.append(parsed)
            }
        }
        Log.explore.debug(
            "Explore parsed: " + output.map { "\($0.title):\($0.items.count)+\($0.moods.count)moods" }.joined(separator: ", ")
        )
        return output
    }

    private static func parseExploreSection(
        _ sectionDict: [String: Any],
        index: Int
    ) -> ExploreSection? {
        if let carousel = sectionDict["musicCarouselShelfRenderer"] as? [String: Any] {
            return parseExploreCarousel(carousel, index: index)
        }
        if let shelf = sectionDict["musicShelfRenderer"] as? [String: Any] {
            let title = shelfTitle(shelf) ?? "Songs"
            let items = parseItems(from: shelf["contents"] as? [[String: Any]] ?? [])
            Log.explore.debug("Explore section[\(index)] shelf title='\(title)' items=\(items.count)")
            guard !items.isEmpty else { return nil }
            return ExploreSection(title: title, kind: .rows, items: items, moods: [])
        }
        if let immersive = sectionDict["musicImmersiveCarouselShelfRenderer"] as? [String: Any] {
            let contents = immersive["contents"] as? [[String: Any]] ?? []
            let items = parseItems(from: contents)
            Log.explore.debug(
                "Explore section[\(index)] immersive keys=\((immersive.keys.sorted())) items=\(items.count)"
            )
            guard !items.isEmpty else { return nil }
            return ExploreSection(title: "Featured", kind: .cards, items: items, moods: [])
        }
        if let grid = sectionDict["gridRenderer"] as? [String: Any] {
            let rawItems = grid["items"] as? [[String: Any]] ?? []
            let navButtons = rawItems.filter { $0["musicNavigationButtonRenderer"] != nil }
            if !navButtons.isEmpty {
                let buttons = navButtons.compactMap(parseExploreButton)
                if buttons.count == navButtons.count {
                    return ExploreSection(title: "", kind: .buttons, items: [], moods: [], buttons: buttons)
                }
                let gridMoods = navButtons
                    .compactMap { parseMood(from: $0, sectionIndex: index) }
                    .filter { $0.params != nil }
                if !gridMoods.isEmpty {
                    return ExploreSection(title: gridTitle(grid) ?? "Moods & genres", kind: .moods, items: [], moods: gridMoods)
                }
            }
            let items = parseItems(from: rawItems)
            Log.explore.debug(
                "Explore section[\(index)] grid keys=\(grid.keys.sorted()) items=\(items.count) " +
                "first=\(rawItems.first?.keys.sorted() ?? [])"
            )
            guard !items.isEmpty else { return nil }
            return ExploreSection(title: "More", kind: .cards, items: items, moods: [])
        }
        return nil
    }

    /// Boton de navegacion de la parte alta de Explorar (Novedades, Listas de exitos...).
    private static func parseExploreButton(_ item: [String: Any]) -> ExploreButton? {
        guard let button = item["musicNavigationButtonRenderer"] as? [String: Any],
              let title = InnerTubeJSON.runsText(button["buttonText"] as? [String: Any]),
              let command = button["clickCommand"] as? [String: Any],
              let browse = command["browseEndpoint"] as? [String: Any],
              let browseId = browse["browseId"] as? String,
              browseId != moodsCategoryBrowseId else { return nil }
        return ExploreButton(title: title, browseId: browseId, params: browse["params"] as? String)
    }

    private static func gridTitle(_ grid: [String: Any]) -> String? {
        guard let header = grid["header"] as? [String: Any],
              let gridHeader = header["gridHeaderRenderer"] as? [String: Any] else { return nil }
        return InnerTubeJSON.runsText(gridHeader["title"] as? [String: Any])
    }

    private static func parseExploreCarousel(
        _ carousel: [String: Any],
        index: Int
    ) -> ExploreSection? {
        guard let header = carousel["header"] as? [String: Any],
              let basicHeader = header["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any],
              let title = InnerTubeJSON.runsText(basicHeader["title"] as? [String: Any]) else {
            Log.explore.debug("Explore section[\(index)] carousel skipped: no basic header")
            return nil
        }
        let headerBrowseId = exploreHeaderBrowseId(basicHeader)
        let rawItems = carousel["contents"] as? [[String: Any]] ?? []
        Log.explore.debug(
            "Explore section[\(index)] carousel title='\(title)' browseId=\(headerBrowseId ?? "none") rawItems=\(rawItems.count)"
        )

        // Moods & genres: title + params shortcuts, no playable items.
        if headerBrowseId == "FEmusic_moods_and_genres" {
            let moods = rawItems.compactMap { parseMood(from: $0, sectionIndex: index) }
            Log.explore.debug("Explore section[\(index)] moods parsed=\(moods.count)")
            guard !moods.isEmpty else { return nil }
            return ExploreSection(title: title, kind: .moods, items: [], moods: moods)
        }

        let items = parseItems(from: rawItems)
        if let first = rawItems.first {
            Log.explore.debug("Explore section[\(index)] first item keys=\(first.keys.sorted()) parsed=\(items.count)")
        }
        if items.isEmpty, !rawItems.isEmpty {
            // Shelf dropped: log why the first item didn't parse so the
            // shape can be mapped (pageType / browse prefix / endpoints).
            Log.explore.debug("Explore section[\(index)] dropped: " + describeUnparsed(rawItems.first ?? [:]))
        }
        guard !items.isEmpty else { return nil }

        // Videos and chart shelves have machine-readable header browseIds;
        // anything song-only renders as rows, mixed content as cards.
        let kind: ExploreSection.Kind
        if headerBrowseId == "FEmusic_new_releases_videos"
            || headerBrowseId?.hasPrefix("VLPL") == true
            || headerBrowseId?.hasPrefix("VLOLA") == true
            || items.allSatisfy({ if case .song = $0 { true } else { false } }) {
            kind = .rows
        } else {
            kind = .cards
        }
        return ExploreSection(title: title, kind: kind, items: items, moods: [])
    }

    /// Header identity per ytmusic-rs: the title runs' navigation endpoint,
    /// falling back to the more-content button.
    private static func exploreHeaderBrowseId(_ basicHeader: [String: Any]) -> String? {
        if let title = basicHeader["title"] as? [String: Any],
           let runs = title["runs"] as? [[String: Any]],
           let first = runs.first,
           let nav = first["navigationEndpoint"] as? [String: Any],
           let browse = nav["browseEndpoint"] as? [String: Any],
           let bid = browse["browseId"] as? String {
            return bid
        }
        return extractBrowseEndpoint(basicHeader)?.browseId
    }

    private static func shelfTitle(_ shelf: [String: Any]) -> String? {
        guard let header = shelf["header"] as? [String: Any],
              let basicHeader = header["musicShelfHeaderRenderer"] as? [String: Any] else { return nil }
        return InnerTubeJSON.runsText(basicHeader["title"] as? [String: Any])
    }

    /// Best-effort mood shortcut parsing (title + category params).
    /// Raw item keys are logged so unknown shapes can be mapped later.
    private static func parseMood(from item: [String: Any], sectionIndex: Int) -> MoodItem? {
        if let twoRow = item["musicTwoRowItemRenderer"] as? [String: Any] {
            let title = InnerTubeJSON.runsText(twoRow["title"] as? [String: Any])
            let params = moodParams(from: twoRow["navigationEndpoint"] as? [String: Any])
            if let title {
                return MoodItem(title: title, params: params)
            }
        }
        if let button = item["musicNavigationButtonRenderer"] as? [String: Any] {
            let title = InnerTubeJSON.runsText(button["buttonText"] as? [String: Any])
            let params = moodParams(from: button["clickCommand"] as? [String: Any])
            if let title {
                return MoodItem(title: title, params: params)
            }
        }
        Log.explore.debug("Explore section[\(sectionIndex)] unparsed mood keys=\(item.keys.sorted())")
        return nil
    }

    private static func moodParams(from endpoint: [String: Any]?) -> String? {
        guard let browse = endpoint?["browseEndpoint"] as? [String: Any],
              (browse["browseId"] as? String) == moodsCategoryBrowseId else { return nil }
        return browse["params"] as? String
    }

    /// One-line fingerprint of an unparseable item for log mapping.
    private static func describeUnparsed(_ item: [String: Any]) -> String {
        let inner: [String: Any]
        if let twoRow = item["musicTwoRowItemRenderer"] as? [String: Any] {
            inner = twoRow
        } else if let responsive = item["musicResponsiveListItemRenderer"] as? [String: Any] {
            inner = responsive
        } else {
            return "keys=\(item.keys.sorted())"
        }
        let pageType = extractPageType(inner) ?? "none"
        let nav = inner["navigationEndpoint"] as? [String: Any]
        let watch = nav?["watchEndpoint"] as? [String: Any]
        let browse = nav?["browseEndpoint"] as? [String: Any]
        return "renderer=\(item.keys.sorted()) pageType=\(pageType) " +
            "watch=\(watch?["videoId"] as? String ?? "none") " +
            "browse=\(browse?["browseId"] as? String ?? "none")"
    }
}

// MARK: - Extract Helpers

extension HomePageParser {
    static func extractPageType(_ renderer: [String: Any]) -> String? {
        guard let nav = renderer["navigationEndpoint"] as? [String: Any],
              let browse = nav["browseEndpoint"] as? [String: Any],
              let configs = browse["browseEndpointContextSupportedConfigs"] as? [String: Any],
              let musicConfig = configs["browseEndpointContextMusicConfig"] as? [String: Any],
              let pageType = musicConfig["pageType"] as? String else { return nil }
        return pageType
    }

    static func hasWatchEndpoint(_ renderer: [String: Any]) -> Bool {
        guard let nav = renderer["navigationEndpoint"] as? [String: Any] else { return false }
        return nav["watchEndpoint"] != nil
    }

    static func extractBrowseEndpoint(_ header: [String: Any]) -> (browseId: String, params: String?)? {
        guard let moreContent = header["moreContentButton"] as? [String: Any],
              let button = moreContent["buttonRenderer"] as? [String: Any],
              let nav = button["navigationEndpoint"] as? [String: Any],
              let browse = nav["browseEndpoint"] as? [String: Any],
              let browseId = browse["browseId"] as? String else { return nil }
        return (browseId, browse["params"] as? String)
    }

    static func extractContinuation(from sectionList: [String: Any]) -> String? {
        guard let continuations = sectionList["continuations"] as? [[String: Any]],
              let first = continuations.first,
              let nextContinuation = first["nextContinuationData"] as? [String: Any],
              let token = nextContinuation["continuation"] as? String else { return nil }
        return token
    }
}
