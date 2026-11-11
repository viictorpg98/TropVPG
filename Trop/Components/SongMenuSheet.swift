//
//  SongMenuSheet.swift
//  Trop
//
//  Created by 686udjie on 26/08/2026.
//

import SwiftUI

struct SongMenuSheet: View {
    let song: SongItem
    var onNavigate: ((DetailRoute) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsStore) private var settings
    @ObservedObject private var downloadManager = DownloadManager.shared
    @ObservedObject private var likeStore = LikeStore.shared
    @State private var showHideDialog = false

    enum Destination: Hashable {
        case details
        case similar
        case more
    }

    @State private var pin = PinState()
    @State private var showPlaylistPicker = false
    @State private var showArtistPicker = false
    @State private var showRadioOptions = false
    @State private var showShareDialog = false
    @State private var isResolvingArtist = false
    @State private var showRemoveDownload = false
    /// El color de la carátula, oscurecido, de fondo de la hoja.
    @State private var tint: Color?

    private var isLiked: Bool {
        likeStore.isLiked(videoId: song.videoId)
    }
    private var thumbnailURL: String? {
        AudioCounterpartStore.shared.thumbnailURL(for: song)
    }

    var body: some View {
        SheetChrome(tint: tint) {
            Group {
                headerRow
                quickActions
                MenuCard {
                    MenuRow(icon: "text.insert", title: "Play Next") { playNext() }
                    Divider()
                    MenuRow(icon: "list.bullet", title: "Add to Queue") { addToQueue() }
                    Divider()
                    MenuRow(icon: "dot.radiowaves.left.and.right", title: "Start Radio") { startRadio() }
                    Divider()
                    MenuRow(icon: "music.mic", title: "View Artist", subtitle: song.artistNamesDisplay) { handleViewArtist() }
                    if let albumId = song.firstAlbumBrowseId {
                        Divider()
                        MenuRow(icon: "record.circle", title: "View Album", subtitle: song.album) {
                            navigate(.album(browseId: albumId))
                        }
                    }
                    Divider()
                    NavigationLink(value: Destination.similar) {
                        MenuRowLabel(
                            icon: "dot.radiowaves.left.and.right",
                            title: "Similar to this song",
                            subtitle: "More like “\(song.title)”"
                        )
                    }
                    .buttonStyle(.plain)
                    Divider()
                    NavigationLink(value: Destination.more) {
                        MenuRowLabel(icon: "ellipsis.circle", title: "More Options")
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationDestination(for: Destination.self) { dest in
                switch dest {
                case .details:
                    SongDetailsView(song: song)
                case .similar:
                    SimilarSongsView(
                        song: song,
                        onNavigate: onNavigate,
                        onPlaySong: { similar, songs in
                            playSimilarAndExpand(similar, in: songs)
                        }
                    )
                case .more:
                    moreOptions
                }
            }
        }
        .preferredColorScheme(.dark)
        .confirmationDialog("View Artist", isPresented: $showArtistPicker, titleVisibility: .visible) {
            ForEach(song.artists.filter { !$0.name.isEmpty }, id: \.self) { artist in
                Button(artist.name) {
                    openArtist(artist)
                }
            }
        }
        .confirmationDialog("Remove Download", isPresented: $showRemoveDownload, titleVisibility: .visible) {
            Button("Remove Download", role: .destructive) {
                Task { await downloadManager.delete(videoId: song.videoId) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showPlaylistPicker) {
            AddSongToPlaylistSheet(song: song)
        }
        .sheet(isPresented: $showRadioOptions) {
            RadioOptionsSheet(song: song)
        }
        .confirmationDialog("Share", isPresented: $showShareDialog, titleVisibility: .visible) {
            Button("Copy Link") {
                UIPasteboard.general.string = song.webUrl
                dismiss()
            }
            Button("Share with Other Apps") {
                share()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(song.title)
        }
        .task { await pin.load(videoId: song.videoId) }
        .task(id: song.videoId) { tint = await SongTint.color(forThumbnail: thumbnailURL) }
        .hideArtistDialog(for: song, isPresented: $showHideDialog)
    }

    // MARK: - Mas opciones

    private var moreOptions: some View {
        ScrollView {
            VStack(spacing: 12) {
                MenuCard {
                    MenuRow(
                        icon: pin.isPinned ? "pin.fill" : "pin",
                        title: pin.isPinned ? "Unpin from Quick Picks" : "Pin to Quick Picks"
                    ) { Task { await pin.toggle(song: song) } }
                    Divider()
                    NavigationLink(value: Destination.details) {
                        MenuRowLabel(
                            icon: "info.circle",
                            title: "Details",
                            subtitle: "Metadata & stream information"
                        )
                    }
                    .buttonStyle(.plain)
                    Divider()
                    MenuRow(
                        icon: "slider.horizontal.3",
                        title: "Customize Radio",
                        subtitle: "Style, size & explicit filter"
                    ) { showRadioOptions = true }
                    if !song.artists.isEmpty {
                        Divider()
                        MenuRow(
                            icon: "eye.slash",
                            title: "Hide Artist",
                            subtitle: song.artistNamesDisplay
                        ) { showHideDialog = true }
                    }
                }
            }
            .padding(16)
        }
        .background(tint ?? Color(.systemBackground))
        .navigationTitle("More Options")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Cabecera y acciones rapidas

    private var headerRow: some View {
        HStack(spacing: 14) {
            AsyncImageView(url: thumbnailURL)
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                MarqueeText(
                    text: song.title,
                    font: .headline,
                    frameHeight: 24,
                    textColor: .primary
                )
                Text(headerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
    }

    private var headerSubtitle: String {
        guard song.duration > 0 else { return song.artistNamesDisplay }
        let time = DurationFormat.playbackTime(TimeInterval(song.duration))
        return song.artistNamesDisplay.isEmpty ? time : "\(song.artistNamesDisplay) · \(time)"
    }

    private var quickActions: some View {
        let state = downloadManager.state(for: song.videoId)
        return HStack(spacing: 6) {
            quickAction(
                icon: isLiked ? "heart.fill" : "heart",
                label: isLiked ? "Unlike" : "Like",
                isOn: isLiked
            ) {
                Task { await likeStore.toggle(song: song) }
            }

            switch state {
            case .completed:
                quickAction(icon: "checkmark.circle.fill", label: "Downloaded", isOn: true) {
                    showRemoveDownload = true
                }
            case .downloading:
                quickAction(icon: "arrow.down.circle", label: "Downloading…") {}
            case .notStarted, .failed:
                quickAction(icon: "arrow.down.circle", label: "Download") {
                    Task { await downloadManager.download(song: song) }
                }
            }

            quickAction(icon: "music.note.list", label: "Playlist") { showPlaylistPicker = true }
            quickAction(icon: "square.and.arrow.up", label: "Share") { showShareDialog = true }
        }
        .padding(.bottom, 6)
    }

    private func quickAction(icon: String, label: String, isOn: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isOn ? settings.accentOnColor : Color.white)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(isOn ? settings.accentColor : Color.white.opacity(0.12)))
                Text(LocalizedStringKey(label))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - State

    // MARK: - Actions

    private func startRadio() {
        PlaybackQueue.startRadio(for: song)
        dismiss()
    }

    private func playNext() {
        SongActions.playNext(song)
        dismiss()
    }

    private func addToQueue() {
        SongActions.addToQueue(song)
        dismiss()
    }

    private func share() {
        shareSong(song, downloadManager: downloadManager, afterDismiss: { dismiss() })
    }

    private func navigate(_ route: DetailRoute) {
        dismiss()
        onNavigate?(route)
    }

    private func playSimilarAndExpand(_ similar: SongItem, in songs: [SongItem]) {
        dismiss()
        PlaybackQueue.play(similar, in: songs, log: Log.search, context: "SimilarTo tap")
        AppRouter.shared.expandPlayer()
    }

    private func handleViewArtist() {
        guard !isResolvingArtist else { return }
        let namedArtists = song.artists.filter { !$0.name.isEmpty }
        if namedArtists.count > 1 {
            showArtistPicker = true
            return
        }
        guard let artist = namedArtists.first else { return }
        openArtist(artist)
    }

    private func openArtist(_ artist: YTArtist) {
        if let id = artist.id {
            navigate(.artist(browseId: id))
            return
        }
        resolveArtistByName(artist.name)
    }

    private func resolveArtistByName(_ name: String) {
        guard !name.isEmpty else { return }
        isResolvingArtist = true
        Task {
            defer { isResolvingArtist = false }
            var browseId: String?
            do {
                let json = try await SearchService.shared.search(query: name)
                let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                browseId = SearchParser.parseSearchResults(from: json)
                    .flatMap(\.items)
                    .compactMap { item -> (String, String)? in
                        if case .artist(let artist) = item { return (artist.name, artist.browseId) }
                        return nil
                    }
                    .first {
                        $0.0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
                    }?.1
            } catch {
                browseId = nil
            }
            if let browseId {
                navigate(.artist(browseId: browseId))
            }
        }
    }
}
