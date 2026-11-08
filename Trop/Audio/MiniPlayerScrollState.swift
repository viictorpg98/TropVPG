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
    /// Altura de todo lo que hay fijo encima de la barra de pestanas (mini reproductor y avisos). 0 si no hay nada.
    var insetHeight: CGFloat = 0
}

/// Flips `MiniPlayerScrollState.isInline` based on a scroll container's vertical
/// offset, matching the system's tab bar minimize behavior: collapsing when the
/// user scrolls down and restoring the moment they scroll back up.
///
/// Ademas deja al final de la lista un margen del tamano de lo que haya fijo debajo (el mini reproductor y los
/// avisos): el sistema reserva el hueco de la barra de pestanas pero NO el de esa barra, y las ultimas filas
/// quedaban tapadas al bajar del todo.
struct MiniPlayerInlineOnScrollModifier: ViewModifier {
    @Environment(MiniPlayerScrollState.self) private var scrollState

    private let compactThreshold: CGFloat = 1
    /// Aire entre la ultima fila y lo que hay debajo.
    private let air: CGFloat = 12

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
            .safeAreaPadding(.bottom, scrollState.insetHeight > 0 ? scrollState.insetHeight + air : 0)
    }
}
