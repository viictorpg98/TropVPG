//
//  Pressable.swift
//  Trop
//

import SwiftUI

/// Vibracion de la app. Los generadores se reutilizan y se preparan al empezar a pulsar para que la
/// respuesta sea inmediata (si se crean al vuelo, la primera vibracion tarda y casi no se nota).
@MainActor
enum Haptics {
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let heavyGenerator = UIImpactFeedbackGenerator(style: .heavy)

    static func prepare() {
        lightGenerator.prepare()
        heavyGenerator.prepare()
    }

    /// Toque normal.
    static func tap() {
        lightGenerator.impactOccurred(intensity: 0.8)
    }

    /// Mantener pulsado (abre el menu de opciones).
    static func hold() {
        heavyGenerator.impactOccurred()
    }
}

/// Respuesta visual y vibracion al pulsar un boton: se hunde y se atenua mientras esta pulsado.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.tap() }
            }
    }
}

/// Lo mismo para vistas que no son un `Button` (filas y caratulas): se hunde al tocar, vibra al
/// soltar y, si hay accion, al mantener pulsado.
private struct PressableModifier: ViewModifier {
    let onTap: () -> Void
    let onLongPress: (() -> Void)?
    /// Un menu del sistema (`contextMenu`) se encarga de mantener pulsado: aqui solo se ve el hundido al tocar.
    var holdsForContextMenu = false

    @State private var isPressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? 0.97 : 1)
            .opacity(isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.12), value: isPressed)
            .contentShape(Rectangle())
            .onTapGesture {
                Haptics.tap()
                onTap()
            }
            .onLongPressGesture(
                minimumDuration: holdsForContextMenu ? 60 : 0.4,
                maximumDistance: 12,
                perform: {
                    guard let onLongPress else { return }
                    Haptics.hold()
                    onLongPress()
                },
                onPressingChanged: { pressing in
                    isPressed = pressing
                    if pressing { Haptics.prepare() }
                }
            )
    }
}

/// Acciones de una cancion que usan el menu de mantener pulsado y la hoja de opciones.
@MainActor
enum SongActions {
    static func playNext(_ song: SongItem) {
        let np = NowPlaying.shared
        let insertIndex = min(np.queueIndex + 1, np.queueSongs.count)
        np.queueSongs.insert(song, at: insertIndex)
        np.repairQueueIndex()
        np.persistQueueState()
    }

    static func addToQueue(_ song: SongItem) {
        let np = NowPlaying.shared
        np.queueSongs.append(song)
        np.persistQueueState()
    }
}

/// El menu corto que sale al mantener pulsada una cancion (el del sistema, flotante): las acciones mas usadas y "Mas..." para
/// abrir la hoja completa.
struct SongContextMenuModifier: ViewModifier {
    let song: SongItem?
    let onMore: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if let song {
            content.contextMenu {
                Button {
                    SongActions.playNext(song)
                } label: {
                    Label("Play Next", systemImage: "text.insert")
                }
                Button {
                    SongActions.addToQueue(song)
                } label: {
                    Label("Add to Queue", systemImage: "list.bullet")
                }
                let liked = LikeStore.shared.isLiked(videoId: song.videoId)
                Button {
                    Task { await LikeStore.shared.toggle(song: song) }
                } label: {
                    Label(LocalizedStringKey(liked ? "Unlike" : "Like"), systemImage: liked ? "heart.slash" : "heart")
                }
                downloadButton(for: song)
                Button(action: onMore) {
                    Label("More…", systemImage: "ellipsis")
                }
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private func downloadButton(for song: SongItem) -> some View {
        switch DownloadManager.shared.state(for: song.videoId) {
        case .completed:
            Button(role: .destructive) {
                Task { await DownloadManager.shared.delete(videoId: song.videoId) }
            } label: {
                Label("Remove Download", systemImage: "trash")
            }
        case .downloading:
            Button {} label: {
                Label("Downloading…", systemImage: "arrow.down.circle")
            }
            .disabled(true)
        case .notStarted, .failed:
            Button {
                Task { await DownloadManager.shared.download(song: song) }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
    }
}

/// Como `pressable`, y al mantener pulsado abre el menu de opciones de la cancion.
private struct PressableSongModifier: ViewModifier {
    let song: SongItem?
    let onTap: () -> Void
    let onNavigate: ((DetailRoute) -> Void)?

    @State private var showMenu = false

    func body(content: Content) -> some View {
        content
            .pressable(onTap: onTap, onLongPress: nil, holdsForContextMenu: song != nil)
            .songContextMenu(song) { showMenu = true }
            .sheet(isPresented: $showMenu) {
                if let song {
                    SongMenuSheet(song: song, onNavigate: { onNavigate?($0) })
                }
            }
    }
}

/// Como `pressable`, y al mantener pulsado abre el menu que corresponde al elemento:
/// el de cancion para canciones y episodios, y el de coleccion para album, artista, lista y podcast.
private struct PressableItemModifier: ViewModifier {
    let item: YTItem
    let onTap: () -> Void
    let onNavigate: ((DetailRoute) -> Void)?
    var onDelete: (() -> Void)?

    @State private var showMenu = false

    /// Canciones y episodios usan el menu corto (con "Mas..."); album, artista, lista y podcast, su hoja directamente.
    private var menuSong: SongItem? {
        switch item {
        case .song(let song): return song
        case .episode(let episode): return episode.toSongItem()
        default: return nil
        }
    }

    func body(content: Content) -> some View {
        content
            .pressable(
                onTap: onTap,
                onLongPress: menuSong == nil ? { showMenu = true } : nil,
                holdsForContextMenu: menuSong != nil
            )
            .songContextMenu(menuSong) { showMenu = true }
            .sheet(isPresented: $showMenu) {
                switch item {
                case .song(let song):
                    SongMenuSheet(song: song, onNavigate: { onNavigate?($0) })
                case .episode(let episode):
                    SongMenuSheet(song: episode.toSongItem(), onNavigate: { onNavigate?($0) })
                default:
                    CollectionMenuSheet(item: item, onNavigate: onNavigate, onDelete: onDelete)
                }
            }
    }
}

extension View {
    func pressableItem(
        _ item: YTItem,
        onTap: @escaping () -> Void,
        onNavigate: ((DetailRoute) -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) -> some View {
        modifier(PressableItemModifier(item: item, onTap: onTap, onNavigate: onNavigate, onDelete: onDelete))
    }

    func pressable(
        onTap: @escaping () -> Void,
        onLongPress: (() -> Void)? = nil,
        holdsForContextMenu: Bool = false
    ) -> some View {
        modifier(PressableModifier(onTap: onTap, onLongPress: onLongPress, holdsForContextMenu: holdsForContextMenu))
    }

    /// Menu corto al mantener pulsada una cancion (`nil`: no hay menu).
    func songContextMenu(_ song: SongItem?, onMore: @escaping () -> Void) -> some View {
        modifier(SongContextMenuModifier(song: song, onMore: onMore))
    }

    func pressableSong(
        _ song: SongItem?,
        onTap: @escaping () -> Void,
        onNavigate: ((DetailRoute) -> Void)? = nil
    ) -> some View {
        modifier(PressableSongModifier(song: song, onTap: onTap, onNavigate: onNavigate))
    }
}
