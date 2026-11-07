//
//  SongColumnsGrid.swift
//  Trop
//

import SwiftUI

/// Rejilla horizontal de 4 filas con las canciones en columnas anchas.
/// Se ajusta a cada columna al deslizar (como en YouTube Music).
struct SongColumnsGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyHGrid(rows: Array(repeating: GridItem(.fixed(72)), count: 4), spacing: 12) {
            content()
        }
        .scrollTargetLayout()
    }
}
