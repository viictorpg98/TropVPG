//
//  MiniPlayerScrollState.swift
//  Trop
//
//  Created by 686udjie on 19/08/2026.
//

import SwiftUI

/// Shared state driving the mini player's inline (minimized) layout.
/// The system's `tabViewBottomAccessoryPlacement` environment can lag behind
/// the actual tab bar state on scroll-back, so the scroll containers set this
/// directly to keep the mini player's content in sync with its position.
@Observable
final class MiniPlayerScrollState {
    var isInline = false
    /// Borde superior (en pantalla) del mini reproductor, para que las listas sepan cuanto se les mete debajo.
    var barTop: CGFloat?
}

/// Flips `MiniPlayerScrollState.isInline` based on a scroll container's vertical
/// offset, matching the system's tab bar minimize behavior: collapsing when the
/// user scrolls down and restoring the moment they scroll back up.
///
/// Ademas reserva al final de la lista el hueco justo para que la ultima fila quede por encima del mini
/// reproductor: mide cuanto se mete el contenedor bajo la barra y cuanto margen ya reserva el sistema, y anade
/// solo lo que falte (mas un poco de aire). Asi no depende de en que pantalla este ni de si el sistema ya
/// reservo el hueco.
struct MiniPlayerInlineOnScrollModifier: ViewModifier {
    @Environment(MiniPlayerScrollState.self) private var scrollState

    private let compactThreshold: CGFloat = 1
    /// Aire que debe quedar entre la ultima fila y el mini reproductor.
    private let air: CGFloat = 20
    private let np = NowPlaying.shared

    /// Parte baja del contenedor en pantalla, margen inferior que ya reserva (incluye `extra`) y margen anadido.
    @State private var viewBottom: CGFloat = 0
    @State private var bottomInset: CGFloat = 0
    @State private var extra: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(
                for: CGFloat.self,
                of: { $0.contentOffset.y },
                action: { oldOffset, newOffset in
                    if newOffset > oldOffset, newOffset > compactThreshold {
                        guard !scrollState.isInline else { return }
                        scrollState.isInline = true
                    } else if newOffset < oldOffset {
                        guard scrollState.isInline else { return }
                        scrollState.isInline = false
                    }
                }
            )
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentInsets.bottom }) { _, newValue in
                bottomInset = newValue
                updateExtra()
            }
            // La posicion en pantalla se lee con un GeometryReader (da el valor inicial en cuanto aparece;
            // los "cambios de geometria" solo avisan cuando algo cambia despues).
            .background {
                GeometryReader { proxy in
                    let bottom = proxy.frame(in: .global).maxY
                    Color.clear
                        .onAppear {
                            viewBottom = bottom
                            updateExtra()
                        }
                        .onChange(of: bottom) { _, newValue in
                            viewBottom = newValue
                            updateExtra()
                        }
                }
            }
            .onChange(of: scrollState.barTop) { _, _ in updateExtra() }
            .onChange(of: np.isBarPresented) { _, _ in updateExtra() }
            .safeAreaPadding(.bottom, extra)
    }

    private func updateExtra() {
        guard np.isBarPresented, let barTop = scrollState.barTop else {
            if extra != 0 { extra = 0 }
            return
        }
        let overlap = max(0, viewBottom - barTop)
        let alreadyReserved = max(0, bottomInset - extra)
        let needed = min(240, max(0, overlap + air - alreadyReserved))
        if abs(needed - extra) > 1 { extra = needed }
    }
}
