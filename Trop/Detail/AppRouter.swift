//
// AppRouter.swift
// Trop
//
// Created by 686udjie on 21/08/2026.
//

import Combine
import SwiftUI

/// Owns each tab's NavigationPath so overlays (e.g. the Big Player menu) can
/// push detail pages onto the regular tab navigation. Appending to a path is
/// plain state mutation, so it works even while views are transitioning —
/// unlike pub/sub events, which tabs can miss during player teardown.
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    @Published var homePath = NavigationPath()
    @Published var libraryPath = NavigationPath()
    @Published var explorePath = NavigationPath()
    @Published var searchPath = NavigationPath()
    @Published var selectedTabIndex = 0

    /// Pestana a la que debe cambiar ContentView (la consume y vuelve a nil).
    @Published var tabRequest: Int?
    /// Filtro de la Biblioteca que debe abrirse al entrar ("podcasts"); la Biblioteca lo consume y vuelve a nil.
    @Published var libraryFilterRequest: String?
    var previousTabIndex = 0

    /// Salir de Buscar hacia la pestana anterior (el teclado tapa la barra inferior).
    func leaveSearch() {
        tabRequest = previousTabIndex == 3 ? 0 : previousTabIndex
    }

    /// Last route opened from an overlay; ContentView listens to collapse the player.
    @Published private(set) var activeRoute: DetailRoute?

    @Published private(set) var playerExpandToken = 0

    var activePathDepth: Int {
        switch selectedTabIndex {
        case 1: libraryPath.count
        case 2: explorePath.count
        case 3: searchPath.count
        default: homePath.count
        }
    }

    func popActiveRoute() {
        guard activePathDepth > 0 else { return }
        switch selectedTabIndex {
        case 1: libraryPath.removeLast()
        case 2: explorePath.removeLast()
        case 3: searchPath.removeLast()
        default: homePath.removeLast()
        }
    }

    func expandPlayer() {
        playerExpandToken += 1
    }

    /// Lleva a la pantalla de Descargas (desde el aviso de sin conexion y desde la portada).
    func openDownloads() {
        tabRequest = 1
        selectedTabIndex = 1
        open(.downloads)
    }

    func open(_ route: DetailRoute) {
        switch selectedTabIndex {
        case 1: libraryPath.append(route)
        case 2: explorePath.append(route)
        case 3: searchPath.append(route)
        default: homePath.append(route)
        }
        activeRoute = route
    }
}
