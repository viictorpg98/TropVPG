//
//  SpeedDialSectionView.swift
//  Trop
//

import SwiftUI

/// "Acceso rápido": cuadrícula de 3×3 que se desliza por páginas (hasta 27 elementos)
/// y un botón de dado que elige algo al azar.
struct SpeedDialSectionView: View {
    @Environment(SettingsStore.self) private var settings

    let items: [YTItem]
    let onTap: (YTItem) -> Void
    let onDice: () -> Void
    var onNavigate: ((DetailRoute) -> Void)?

    @State private var page: Int? = 0
    @State private var network = NetworkMonitor.shared
    private let np = NowPlaying.shared

    private let perPage = 9
    private let gridSpacing: CGFloat = 10

    private var pages: [[YTItem]] {
        stride(from: 0, to: items.count, by: perPage).map { start in
            Array(items[start ..< min(start + perPage, items.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 0) {
                    ForEach(pages.indices, id: \.self) { index in
                        pageGrid(pages[index])
                            .containerRelativeFrame(.horizontal)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)

            if pages.count > 1 {
                pageDots
            }
        }
        .padding(.top, 8)
    }

    private var header: some View {
        HStack {
            Text("Speed Dial")
                .font(.title3)
                .fontWeight(.bold)
                .lineLimit(1)

            Spacer()

            Button(action: onDice) {
                Image(systemName: "dice.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(settings.accentColor)
                    .frame(width: 44, height: 32)
                    .background(Capsule().fill(Color(.secondarySystemFill)))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(Text("Surprise me"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(pages.indices, id: \.self) { index in
                Circle()
                    .fill(index == (page ?? 0) ? Color.primary : Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    private func pageGrid(_ pageItems: [YTItem]) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: 3),
            alignment: .leading,
            spacing: gridSpacing
        ) {
            ForEach(pageItems.indices, id: \.self) { index in
                cell(pageItems[index])
            }
        }
        .padding(.horizontal, 16)
    }

    private func songVideoId(_ item: YTItem) -> String? {
        switch item {
        case .song(let song): return song.videoId
        case .episode(let episode): return episode.videoId
        default: return nil
        }
    }

    private func cell(_ item: YTItem) -> some View {
        tile(item)
            .accessibilityAddTraits(.isButton)
            .opacity(isUnavailableOffline(item) ? 0.4 : 1)
            .pressableItem(item, onTap: { handleTap(item) }, onNavigate: onNavigate)
    }

    /// Sin conexion, lo no descargado (y lo que no es una cancion) se ve apagado y avisa al pulsarlo.
    private func isUnavailableOffline(_ item: YTItem) -> Bool {
        guard !network.isOnline else { return false }
        guard let videoId = songVideoId(item) else { return true }
        return !DownloadManager.shared.isDownloaded(videoId: videoId)
    }

    private func handleTap(_ item: YTItem) {
        if let videoId = songVideoId(item) {
            if DownloadManager.shared.isDownloaded(videoId: videoId) {
                onTap(item)
            } else if network.requireConnection(NSLocalizedString("No connection: this song isn't downloaded.", comment: "")) {
                onTap(item)
            }
        } else if network.requireConnection() {
            onTap(item)
        }
    }

    @ViewBuilder
    private func tile(_ item: YTItem) -> some View {
        if isArtist(item) {
            artistTile(item)
        } else {
            imageTile(item)
        }
    }

    /// Artista: circulo con el nombre debajo (dentro del circulo se cortaba).
    private func artistTile(_ item: YTItem) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                VStack(spacing: 6) {
                    AsyncImageView(url: item.thumbnailUrl)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(Circle())
                        .padding(.horizontal, 18)
                    HStack(spacing: 4) {
                        Text(item.title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .padding(.horizontal, 6)
                }
            }
    }

    private func imageTile(_ item: YTItem) -> some View {
        AsyncImageView(url: item.thumbnailUrl)
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.7)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    HStack(spacing: 4) {
                        Text(item.title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        // Si no es una cancion, al pulsar se abre otra pantalla: lo avisa la flecha.
                        if opensAnotherScreen(item) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 7)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .downloadedBadge(videoId: songVideoId(item), alignment: .topTrailing)
            .overlay {
                if np.videoId != nil, np.videoId == item.id {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white, lineWidth: 3)
                }
            }
    }

    private func opensAnotherScreen(_ item: YTItem) -> Bool {
        switch item {
        case .song, .episode: return false
        default: return true
        }
    }

    private func menuSong(_ item: YTItem) -> SongItem? {
        switch item {
        case .song(let s): return s
        case .episode(let e): return e.toSongItem()
        default: return nil
        }
    }

    private func isArtist(_ item: YTItem) -> Bool {
        if case .artist = item { return true }
        return false
    }
}
