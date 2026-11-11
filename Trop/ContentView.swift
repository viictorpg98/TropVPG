//
//  ContentView.swift
//  Trop
//
//  Created by 686udjie on 28/06/2026.
//

import Combine
import SwiftUI

struct ContentView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var nowPlaying = NowPlaying.shared
    @State private var selectedTab = SettingsStore.shared.defaultTab
    @State private var isExpanded = false
    @State private var scrollState = MiniPlayerScrollState()

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "music.note.house.fill", value: 0) {
                withMiniPlayer(tab: 0) { HomeScreenView() }
            }

            Tab("Library", systemImage: "music.note.square.stack", value: 1) {
                withMiniPlayer(tab: 1) { LibraryView() }
            }

            Tab("Explore", systemImage: "flame", value: 2) {
                withMiniPlayer(tab: 2) { ExploreView() }
            }

            Tab("Search", systemImage: "magnifyingglass", value: 3) {
                withMiniPlayer(tab: 3) { SearchView() }
            }
        }
        .tabBarMinimizeBehavior(.never)
            .background {
                backgroundLayer
            }
            .overlay {
                if isExpanded {
                    FullPlayerView(onCollapse: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            isExpanded = false
                        }
                    })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .environment(scrollState)
        .onAppear {
            AppRouter.shared.selectedTabIndex = selectedTab
            UserActivity.shared.install()
        }
        .onChange(of: selectedTab) { oldValue, newValue in
            MixFeedbackStore.shared.dismissForActivity()
            AppRouter.shared.selectedTabIndex = newValue
            if newValue == 3 { AppRouter.shared.previousTabIndex = oldValue }
        }
        .onReceive(AppRouter.shared.$tabRequest) { request in
            guard let request else { return }
            selectedTab = request
            AppRouter.shared.tabRequest = nil
        }
        .onReceive(AppRouter.shared.$activeRoute) { route in
            // A detail page was opened from an overlay: collapse the player so
            // the pushed page is visible underneath.
            if route != nil {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    isExpanded = false
                }
            }
        }
        .onReceive(AppRouter.shared.$playerExpandToken.dropFirst()) { _ in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                isExpanded = true
            }
        }
        .simultaneousGesture(backSwipeGesture)
        // Deslizar por la app quita el aviso de valorar la mezcla del mini.
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { _ in MixFeedbackStore.shared.dismissForActivity() }
        )
    }

    /// Barra del mini reproductor: rectangular, a ancho completo y justo encima de la barra de pestanas.
    private func withMiniPlayer<Content: View>(tab: Int, @ViewBuilder _ content: () -> Content) -> some View {
        content().safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                PlaybackNoticeBar()
                OfflineBanner()
                // Solo la pestaña activa lleva el mini (antes habia uno vivo por pestaña, y los ocultos tambien se
                // redibujaban durante una mezcla).
                if nowPlaying.isBarPresented, selectedTab == tab {
                    MiniPlayerBarView(onExpand: expandPlayer)
                }
            }
            // Altura de lo que hay fijo encima de la barra de pestanas: las listas la usan como margen final. Solo la mide
            // la pestaña activa (las ocultas no deben pisar el valor).
            .background {
                GeometryReader { proxy in
                    let height = proxy.size.height
                    Color.clear
                        .onAppear { if selectedTab == tab { scrollState.insetHeight = height } }
                        .onChange(of: height) { _, newValue in
                            if selectedTab == tab { scrollState.insetHeight = newValue }
                        }
                        .onChange(of: selectedTab) { _, newTab in
                            if newTab == tab { scrollState.insetHeight = height }
                        }
                }
            }
        }
    }

    private func expandPlayer() {
        // Dismiss the keyboard before expanding the player so the reveal is visible on the first tap.
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            isExpanded = true
        }
    }

    private var backSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                let isHorizontal = abs(value.translation.width) > abs(value.translation.height)
                guard !isExpanded,
                      value.startLocation.x <= 28,
                      isHorizontal,
                      value.translation.width > 80 else { return }

                let router = AppRouter.shared
                let depth = router.activePathDepth
                guard depth > 0 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard !isExpanded, router.activePathDepth == depth else { return }
                    router.popActiveRoute()
                }
            }
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        if settings.playerBackgroundStyle == .solid {
            Color.black.ignoresSafeArea()
        } else if let accent = nowPlaying.accentColor {
            accent
                .opacity(0.06)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.8), value: nowPlaying.accentColor)
        }
    }
}

#Preview {
    ContentView()
}
