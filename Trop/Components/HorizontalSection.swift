//
//  HorizontalSection.swift
//  Trop
//
//  Created by 686udjie on 2/07/2026.
//

import SwiftUI

/// Titled horizontal-scroll section shared by the Home and Explore tabs:
/// a `NavigationTitleView` header over horizontally scrolling content with
/// standard edge padding.
struct HorizontalSection<Content: View>: View {
    let title: String
    var vSpacing: CGFloat = 0
    var contentVerticalPadding: CGFloat = 4
    /// Si es true, al deslizar se ajusta a cada columna (la rejilla debe usar `.scrollTargetLayout()`).
    var snapsToColumns: Bool = false
    @ViewBuilder let content: () -> Content

    /// Ancho real de la seccion: las columnas lo usan para dejar asomar un trozo de la siguiente.
    @State private var sectionWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: vSpacing) {
            NavigationTitleView(title: title)
            if snapsToColumns {
                scroller.scrollTargetBehavior(.viewAligned)
            } else {
                scroller
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            sectionWidth = width
        }
        .environment(\.sectionWidth, sectionWidth)
    }

    private var scroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content()
                .padding(.vertical, contentVerticalPadding)
        }
        .contentMargins(.horizontal, DesignTokens.screenHPadding, for: .scrollContent)
    }
}

// MARK: - Ancho de columna con trozo de la siguiente

private struct SectionWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var sectionWidth: CGFloat {
        get { self[SectionWidthKey.self] }
        set { self[SectionWidthKey.self] = newValue }
    }
}

private struct SongColumnWidth: ViewModifier {
    @Environment(\.sectionWidth) private var sectionWidth

    func body(content: Content) -> some View {
        // Margen izquierdo 16 + columna + 12 de separacion: asoma ~28 pt de la siguiente.
        content.frame(width: sectionWidth > 0 ? max(240, sectionWidth - 56) : 300)
    }
}

extension View {
    /// Columna de canciones casi a ancho completo, dejando ver el inicio de la siguiente.
    func songColumnWidth() -> some View {
        modifier(SongColumnWidth())
    }
}
