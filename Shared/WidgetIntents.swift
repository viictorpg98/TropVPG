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

/// "Voz": pregunta por voz "¿Qué quieres escuchar?", reconoce lo que dices y lo busca como en el buscador. EXPERIMENTO pensado para CarPlay:
/// iOS puede negarse a abrir el microfono sin la app abierta; el informe ("voz: ...") dice que paso en cada paso (ver `VoiceSearch`).
/// Segun la documentacion de Apple, `AudioRecordingIntent` es lo que permite grabar audio desde un boton (con el indicador de grabacion) y exige
/// una Live Activity mientras se graba; `LiveActivityIntent` hace que el sistema arranque la app SIN abrirla y deje iniciar esa Live Activity
/// (el mismo esquema que usan las apps de dictado con el boton de accion y el Centro de control). Tambien es `AudioPlaybackIntent`: con solo
/// las otras dos, el sistema no dejaba arrancar la musica desde segundo plano al terminar de escuchar (se oia la pregunta y se reconocia la voz,
/// pero la cancion no sonaba y la app se cerraba).
struct WidgetVoiceIntent: AudioRecordingIntent, LiveActivityIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Voice Search"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await VoiceSearch.run(source: "widget")
        #endif
        return .result()
    }
}
