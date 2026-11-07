//
//  SongMenuOnLongPress.swift
//  Trop
//

import SwiftUI

/// Mantener pulsado sobre una cancion abre su menu de opciones (el mismo que los tres puntos).
/// Sirve para las carátulas grandes, que no tienen el boton de tres puntos.
private struct SongMenuOnLongPress: ViewModifier {
    let song: SongItem?
    let onNavigate: ((DetailRoute) -> Void)?

    @State private var showMenu = false

    func body(content: Content) -> some View {
        content
            .onLongPressGesture(minimumDuration: 0.4) {
                guard song != nil else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showMenu = true
            }
            .sheet(isPresented: $showMenu) {
                if let song {
                    SongMenuSheet(song: song, onNavigate: { onNavigate?($0) })
                }
            }
    }
}

extension View {
    func songMenuOnLongPress(_ song: SongItem?, onNavigate: ((DetailRoute) -> Void)? = nil) -> some View {
        modifier(SongMenuOnLongPress(song: song, onNavigate: onNavigate))
    }
}
