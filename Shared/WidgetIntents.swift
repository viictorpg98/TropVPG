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

/// "Para ti": la misma mezcla que "Arranca mi mezcla en Sonar".
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

/// "DJ": enciende o apaga la sesion de DJ (la misma tarjeta del Inicio). Al encenderla, si no suena nada, arranca tu mezcla; si algo ya
/// suena, el DJ se une a lo que haya en la cola. El boton del widget se recarga solo (`WidgetDataStore.djChanged`).
struct WidgetDJIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "DJ"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let dj = DJSession.shared
        if dj.isActive {
            dj.stop()
            return .result()
        }
        dj.start()
        let np = NowPlaying.shared
        if !(np.isPlaying && np.queueSongs.indices.contains(np.queueIndex)) {
            let started = await SonarMix.start()
            if !started { dj.stop() }
        }
        #endif
        return .result()
    }
}

/// "Actualizar": vuelve a pedir el inicio y cambia las portadas de los demas widgets (Selecciones rapidas y Acceso rapido).
struct WidgetRefreshIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Refresh"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await WidgetDataStore.shared.refresh()
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


// MARK: - Voz

// "Voz": pregunta por voz "¿Qué quieres escuchar?", reconoce lo que dices y lo busca como en el buscador. Pensado para CarPlay (ver `VoiceSearch`).
// Son DOS intents encadenados, porque asi sobrevive el proceso (probado en el movil el 20-11-2026):
//   1. `WidgetVoiceListenIntent`: `AudioRecordingIntent` (permite abrir el microfono desde un boton, con el indicador de grabacion, y exige una Live
//      Activity mientras se graba) + `LiveActivityIntent` (el sistema arranca la app SIN abrirla y deja iniciar esa Live Activity). Solo escucha.
//   2. `WidgetPlayQueryIntent`: solo `AudioPlaybackIntent` (el tipo de los botones de Para ti). El primero lo devuelve con `opensIntent` y el sistema lo
//      ejecuta en la app, sin abrirla: pone la cancion. Si una misma intent grababa y reproducia, el proceso moria a los 2-3 s de sonar la cancion.

/// Primera mitad: solo escucha (con Live Activity) y devuelve el intent que pone la cancion.
struct WidgetVoiceListenIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Voice Search"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        var query = ""
        #if !WIDGET_EXTENSION
        query = await VoiceSearch.run(source: "widget") ?? ""
        #endif
        return .result(opensIntent: WidgetPlayQueryIntent(query: query.isEmpty ? nil : query))
    }
}

/// Segunda mitad: pone lo que se busco (sin texto = no hace nada, para cuando no se oyo nada o fallo).
struct WidgetPlayQueryIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Song"
    static let isDiscoverable = false

    @Parameter(title: "Query")
    var query: String?

    init() {}

    init(query: String?) {
        self.query = query
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await VoiceSearch.playChained(query ?? "")
        #endif
        return .result()
    }
}
