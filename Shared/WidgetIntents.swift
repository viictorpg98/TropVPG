//
//  WidgetIntents.swift
//  Trop
//
//  Las acciones de los botones del widget de Sonar (CarPlay y pantalla de inicio).
//
//  Este archivo se compila en DOS sitios: en la app, con el codigo de verdad, y en la extension del widget
//  (SonarWidget), donde solo hace falta que el tipo exista para poder poner el boton (la condicion WIDGET_EXTENSION
//  esta en los ajustes de esa extension y deja vacio el cuerpo). Al ser AudioPlaybackIntent, el sistema las ejecuta en
//  la app y no en el widget. No salen en Atajos (isDiscoverable = false); las de Siri son las de `Intents/`.
//
//  Confirmacion del toque: mientras una accion no termina, el widget deja el boton "en curso" (atenuado, por
//  `.invalidatableContent()`). Las acciones que terminan casi al instante (Mezclar, Me gusta) esperan un minimo de
//  tiempo para que ese estado se llegue a ver, y todas dan un golpecito haptico si la app esta activa.
//

import AppIntents

#if !WIDGET_EXTENSION
import UIKit

/// Cuanto dura como minimo una accion del widget, para que se vea el boton "en curso".
private let widgetMinimumDuration: TimeInterval = 1.2

@MainActor
private func tapFeedback() {
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
}

/// Espera lo que falte hasta `widgetMinimumDuration` desde que empezo la accion.
private func holdUntilMinimum(since start: Date) async {
    let remaining = widgetMinimumDuration - Date().timeIntervalSince(start)
    if remaining > 0 {
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }
}
#endif

/// "Mi mezcla": la misma que "Arranca mi mezcla en Sonar".
struct WidgetMixIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "My Mix"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let start = Date()
        tapFeedback()
        _ = await SonarMix.start()
        await holdUntilMinimum(since: start)
        #endif
        return .result()
    }
}

/// "Mezclar ahora": como el boton "Mezclar" del reproductor grande (salta a la siguiente con AutoMix).
struct WidgetMixNowIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Mix Now"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let start = Date()
        tapFeedback()
        _ = AutoMixEngine.shared.mixNow()
        await holdUntilMinimum(since: start)
        #endif
        return .result()
    }
}

/// "El dado": una cancion al azar del inicio y del Acceso rapido, con su radio (como el dado del inicio).
struct WidgetDiceIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Surprise Me"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let start = Date()
        tapFeedback()
        _ = await SonarMix.playRandomPick()
        await holdUntilMinimum(since: start)
        #endif
        return .result()
    }
}

/// "Me gusta" a la cancion que suena. Solo marca: si ya te gustaba, no la quita (un toque de mas en el coche no la desmarca).
struct WidgetLikeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Like This Song"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let start = Date()
        tapFeedback()
        let np = NowPlaying.shared
        if np.queueSongs.indices.contains(np.queueIndex) {
            let song = np.queueSongs[np.queueIndex]
            if !LikeStore.shared.isLiked(videoId: song.videoId) {
                await LikeStore.shared.toggle(song: song)
            }
        }
        await holdUntilMinimum(since: start)
        #endif
        return .result()
    }
}
