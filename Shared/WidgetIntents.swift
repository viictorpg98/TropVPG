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

import AppIntents

/// "Mi mezcla": la misma que "Arranca mi mezcla en Sonar".
struct WidgetMixIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "My Mix"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        _ = await SonarMix.start()
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
        _ = AutoMixEngine.shared.mixNow()
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
        _ = await SonarMix.playRandomPick()
        #endif
        return .result()
    }
}

/// Una cancion o episodio concreto, desde una portada del widget de portadas: suena y sigue su radio.
struct WidgetPlayTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Song"
    static let isDiscoverable = false

    @Parameter(title: "Video ID")
    var videoId: String

    @Parameter(title: "Song Title")
    var songTitle: String

    @Parameter(title: "Song Artist")
    var songArtist: String

    @Parameter(title: "Duration")
    var songDuration: Int

    @Parameter(title: "Is Episode")
    var isEpisode: Bool

    init() {}

    init(videoId: String, songTitle: String, songArtist: String, songDuration: Int, isEpisode: Bool) {
        self.videoId = videoId
        self.songTitle = songTitle
        self.songArtist = songArtist
        self.songDuration = songDuration
        self.isEpisode = isEpisode
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        _ = await SonarMix.playTrack(
            videoId: videoId, title: songTitle, artist: songArtist, duration: songDuration, isEpisode: isEpisode
        )
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
        let np = NowPlaying.shared
        if np.queueSongs.indices.contains(np.queueIndex) {
            let song = np.queueSongs[np.queueIndex]
            if !LikeStore.shared.isLiked(videoId: song.videoId) {
                await LikeStore.shared.toggle(song: song)
            }
        }
        #endif
        return .result()
    }
}
