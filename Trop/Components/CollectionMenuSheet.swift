//
//  CollectionMenuSheet.swift
//  Trop
//

import SwiftUI

/// Menu de opciones de un album, artista, lista de reproduccion o podcast, al mantener pulsado
/// desde cualquier lista o caratula. Las acciones que necesitan las canciones (reproducir, cola,
/// descargar) se activan cuando termina de cargarse el contenido.
struct CollectionMenuSheet: View {
    let item: YTItem
    var onNavigate: ((DetailRoute) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsStore) private var settings

    @State private var songs: [SongItem] = []
    @State private var isLoading = true
    @State private var albumModel: AlbumDetailViewModel?
    @State private var isSaved = false
    @State private var isSubscribed = false

    private var hasSongs: Bool { !songs.isEmpty }
    private var isArtist: Bool {
        if case .artist = item { return true }
        return false
    }

    var body: some View {
        SheetChrome {
            headerCard
            quickActions
            MenuCard {
                openRow
                specificRows
                if offersQueueActions {
                    Divider()
                    songRow(icon: "text.insert", title: "Play Next", subtitle: "Add to the queue, next in line") { playNext() }
                    Divider()
                    songRow(icon: "list.bullet", title: "Add to Queue", subtitle: "Add to the end of the queue") { addToQueue() }
                    Divider()
                    songRow(icon: "arrow.down.circle", title: "Download", subtitle: "Download all songs for offline playback") { downloadAll() }
                }
            }
        }
        .task { await load() }
    }

    // MARK: - Header

    private var headerCard: some View {
        HStack(spacing: 12) {
            AsyncImageView(url: item.thumbnailUrl)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: isArtist ? 28 : 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(typeLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if isLoading && needsContent {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var typeLabel: String {
        switch item {
        case .album(let a):
            let names = a.artists.map(\.name).joined(separator: ", ")
            let kind = NSLocalizedString("Album", comment: "")
            return names.isEmpty ? kind : "\(kind) • \(names)"
        case .artist: return NSLocalizedString("Artist", comment: "")
        case .playlist(let p):
            let kind = NSLocalizedString("Playlist", comment: "")
            if let author = p.author, !author.isEmpty,
               author.localizedCaseInsensitiveCompare("playlist") != .orderedSame {
                return "\(kind) • \(author)"
            }
            return kind
        case .podcast: return NSLocalizedString("Podcast", comment: "")
        default: return ""
        }
    }

    // MARK: - Acciones rapidas

    private var quickActions: some View {
        HStack(spacing: 0) {
            if needsContent {
                actionButton(icon: "play.fill", label: "Play", enabled: hasSongs) { playAll() }
                separator
                actionButton(icon: "shuffle", label: "Shuffle", enabled: hasSongs) { shuffleAll() }
                separator
            }
            actionButton(icon: "square.and.arrow.up", label: "Share", enabled: shareURL != nil) { share() }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var separator: some View {
        Color(.separator)
            .frame(width: 0.5, height: 28)
    }

    private func actionButton(icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(settings.accentColor)
                Text(LocalizedStringKey(label))
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    // MARK: - Filas

    /// Album, artista y lista tienen canciones que se pueden reproducir; el podcast solo se abre y se comparte.
    private var needsContent: Bool {
        switch item {
        case .album, .artist, .playlist: return true
        default: return false
        }
    }

    /// Cola y descarga solo tienen sentido para album y lista (en un artista seria su "top").
    private var offersQueueActions: Bool {
        switch item {
        case .album, .playlist: return true
        default: return false
        }
    }

    @ViewBuilder
    private var openRow: some View {
        switch item {
        case .album(let a):
            MenuRow(icon: "record.circle", title: "View Album") { navigate(.album(browseId: a.browseId)) }
        case .artist(let a):
            MenuRow(icon: "music.mic", title: "View Artist") { navigate(.artist(browseId: a.browseId)) }
        case .playlist(let p):
            MenuRow(icon: "music.note.list", title: "View Playlist") { navigate(.playlist(playlistId: p.id)) }
        case .podcast(let p):
            MenuRow(icon: "mic", title: "View Podcast") { navigate(.podcast(browseId: p.browseId)) }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var specificRows: some View {
        switch item {
        case .album:
            Divider()
            MenuRow(
                icon: isSaved ? "bookmark.fill" : "bookmark",
                title: isSaved ? "Saved" : "Save to Library"
            ) { toggleSaveAlbum() }
            .disabled(albumModel?.album == nil)
            .opacity(albumModel?.album == nil ? 0.4 : 1)
        case .artist(let a):
            Divider()
            MenuRow(
                icon: isSubscribed ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus",
                title: isSubscribed ? "Unsubscribe" : "Subscribe"
            ) { toggleSubscribe(a) }
        default:
            EmptyView()
        }
    }

    private func songRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        MenuRow(icon: icon, title: title, subtitle: subtitle, action: action)
            .disabled(!hasSongs)
            .opacity(hasSongs ? 1 : 0.4)
    }

    // MARK: - Carga

    private func load() async {
        switch item {
        case .album(let a):
            let model = AlbumDetailViewModel(browseId: a.browseId)
            await model.load()
            albumModel = model
            songs = model.album?.songs ?? []
            isSaved = model.isSaved
        case .playlist(let p):
            let model = PlaylistDetailViewModel(playlistId: p.id)
            await model.load()
            songs = model.playlist?.songs ?? []
        case .artist(let a):
            let model = ArtistDetailViewModel(browseId: a.browseId)
            await model.load()
            songs = model.artist?.songs ?? []
            isSubscribed = model.artist?.isSubscribed ?? a.isSubscribed
        default:
            break
        }
        isLoading = false
    }

    // MARK: - Acciones

    private func navigate(_ route: DetailRoute) {
        dismiss()
        onNavigate?(route)
    }

    private func playAll() {
        PlaybackQueue.play(songs, log: Log.homeScreenView, context: "Collection menu play")
        dismiss()
    }

    private func shuffleAll() {
        PlaybackQueue.playShuffled(songs, log: Log.homeScreenView, context: "Collection menu shuffle")
        dismiss()
    }

    private func playNext() {
        let np = NowPlaying.shared
        let insertIndex = min(np.queueIndex + 1, np.queueSongs.count)
        np.queueSongs.insert(contentsOf: songs, at: insertIndex)
        np.repairQueueIndex()
        np.persistQueueState()
        dismiss()
    }

    private func addToQueue() {
        let np = NowPlaying.shared
        np.queueSongs.append(contentsOf: songs)
        np.persistQueueState()
        dismiss()
    }

    private func downloadAll() {
        for song in songs {
            Task { await DownloadManager.shared.download(song: song) }
        }
        dismiss()
    }

    private func toggleSaveAlbum() {
        guard let albumModel else { return }
        Task {
            await albumModel.toggleSave()
            isSaved = albumModel.isSaved
        }
    }

    private func toggleSubscribe(_ artist: ArtistItem) {
        let wasSubscribed = isSubscribed
        isSubscribed = !wasSubscribed
        loggedTask(Log.artistDetail, "Subscribe failed") {
            let entity = ArtistEntity(
                id: artist.browseId,
                name: artist.name,
                thumbnailUrl: artist.thumbnailUrl,
                bookmarkedAt: wasSubscribed ? nil : Date(),
                isPodcastChannel: false,
                channelId: artist.browseId
            )
            try await DatabaseService.shared.insertOrReplace(entity)
            if wasSubscribed {
                try await SyncBridge.mutations.unsubscribeArtist(channelId: artist.browseId, artistId: artist.browseId)
            } else {
                try await SyncBridge.mutations.subscribeArtist(channelId: artist.browseId, artistId: artist.browseId)
            }
        }
    }

    private var shareURL: URL? {
        switch item {
        case .album(let a):
            return URL(string: "https://music.youtube.com/browse/\(a.browseId)")
        case .artist(let a):
            return URL(string: "https://music.youtube.com/channel/\(a.browseId)")
        case .playlist(let p):
            let id = p.id.hasPrefix("VL") ? String(p.id.dropFirst(2)) : p.id
            return URL(string: "https://music.youtube.com/playlist?list=\(id)")
        case .podcast(let p):
            return URL(string: "https://music.youtube.com/browse/\(p.browseId)")
        default:
            return nil
        }
    }

    private func share() {
        guard let url = shareURL else { return }
        presentShareSheet(items: [url])
        dismiss()
    }
}
