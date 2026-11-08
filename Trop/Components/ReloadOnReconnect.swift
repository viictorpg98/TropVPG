//
//  ReloadOnReconnect.swift
//  Trop
//

import SwiftUI

extension View {
    /// Si la pantalla se quedo con un error y vuelve la conexion, la recarga sola (sin tirar para refrescar).
    func reloadWhenBackOnline(hasError: Bool, _ reload: @escaping () async -> Void) -> some View {
        modifier(ReloadWhenBackOnline(hasError: hasError, reload: reload))
    }
}

private struct ReloadWhenBackOnline: ViewModifier {
    let hasError: Bool
    let reload: () async -> Void

    @State private var network = NetworkMonitor.shared

    func body(content: Content) -> some View {
        content.onChange(of: network.isOnline) { _, online in
            if online, hasError {
                Task { await reload() }
            }
        }
    }
}
