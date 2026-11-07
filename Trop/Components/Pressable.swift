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
                minimumDuration: 0.4,
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

/// Como `pressable`, y al mantener pulsado abre el menu de opciones de la cancion.
private struct PressableSongModifier: ViewModifier {
    let song: SongItem?
    let onTap: () -> Void
    let onNavigate: ((DetailRoute) -> Void)?

    @State private var showMenu = false

    func body(content: Content) -> some View {
        content
            .pressable(onTap: onTap, onLongPress: song == nil ? nil : { showMenu = true })
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

    @State private var showMenu = false

    func body(content: Content) -> some View {
        content
            .pressable(onTap: onTap, onLongPress: { showMenu = true })
            .sheet(isPresented: $showMenu) {
                switch item {
                case .song(let song):
                    SongMenuSheet(song: song, onNavigate: { onNavigate?($0) })
                case .episode(let episode):
                    SongMenuSheet(song: episode.toSongItem(), onNavigate: { onNavigate?($0) })
                default:
                    CollectionMenuSheet(item: item, onNavigate: onNavigate)
                }
            }
    }
}

extension View {
    func pressableItem(
        _ item: YTItem,
        onTap: @escaping () -> Void,
        onNavigate: ((DetailRoute) -> Void)? = nil
    ) -> some View {
        modifier(PressableItemModifier(item: item, onTap: onTap, onNavigate: onNavigate))
    }

    func pressable(onTap: @escaping () -> Void, onLongPress: (() -> Void)? = nil) -> some View {
        modifier(PressableModifier(onTap: onTap, onLongPress: onLongPress))
    }

    func pressableSong(
        _ song: SongItem?,
        onTap: @escaping () -> Void,
        onNavigate: ((DetailRoute) -> Void)? = nil
    ) -> some View {
        modifier(PressableSongModifier(song: song, onTap: onTap, onNavigate: onNavigate))
    }
}
