//
//  SonarIntents.swift
//  Trop
//

import AppIntents

/// "Pon música": se puede lanzar con Siri, desde la app Atajos o con una automatizacion
/// (por ejemplo "Al conectar CarPlay"). Empieza una mezcla de lo que te gusta.
struct PlayMyMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play My Music"
    static let description = IntentDescription("Starts a mix of music you like.")

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await SonarMix.start()
        return .result()
    }
}

/// Retoma lo que sonaba; si no había nada, empieza una mezcla.
struct ResumeMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Music"
    static let description = IntentDescription("Resumes what was playing, or starts a mix if nothing was.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let np = NowPlaying.shared
        if np.isPlaying { return .result() }
        if let videoId = np.videoId, !np.queueSongs.isEmpty {
            await SonarMix.prepareSession()
            try await PlaybackManager.shared.resolveAndPlay(videoId: videoId)
        } else {
            _ = await SonarMix.start()
        }
        return .result()
    }
}

/// Pide una cancion por su nombre. Siri pregunta "¿Qué canción?" y se contesta con el titulo (y el artista si
/// ayuda). Busca primero entre las descargadas y luego en YouTube Music.
struct PlaySongIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play a Song"
    static let description = IntentDescription("Plays a song you ask for by name.")

    @Parameter(title: "Song", requestValueDialog: "Which song?")
    var song: String

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$song)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if let found = await SonarMix.playSong(named: song) {
            let artist = found.artists.map(\.name).joined(separator: ", ")
            let text = artist.isEmpty
                ? String(format: NSLocalizedString("Playing %@", comment: ""), found.title)
                : String(format: NSLocalizedString("Playing %@ by %@", comment: ""), found.title, artist)
            return .result(dialog: "\(text)")
        }
        let text = NetworkMonitor.shared.hasConnection
            ? NSLocalizedString("I couldn't find that song.", comment: "")
            : NSLocalizedString("No connection and that song isn't downloaded.", comment: "")
        return .result(dialog: "\(text)")
    }
}

/// Cuenta como fue el ultimo "Pon mi musica": cuanto tardo cada paso y que cliente de YouTube sono.
struct SonarReportIntent: AppIntent {
    static let title: LocalizedStringResource = "Sonar Report"
    static let description = IntentDescription("Shows how long the last music start took, step by step.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let report = SonarMix.lastReport
        return .result(dialog: "\(report)")
    }
}

/// Frases para Siri que funcionan sin configurar nada ("Mi mezcla en Sonar").
/// Se evita decir "pon música": Siri lo trata como una peticion de musica a una app y, como Sonar
/// no tiene soporte de SiriKit para eso, contesta que no lo permite. Las versiones en español van en `AppShortcuts.strings`.
struct SonarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayMyMusicIntent(),
            phrases: [
                "Start my mix on \(.applicationName)",
                "My mix on \(.applicationName)",
                "\(.applicationName) mix"
            ],
            shortTitle: "Play Music",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: ResumeMusicIntent(),
            phrases: [
                "Continue with \(.applicationName)"
            ],
            shortTitle: "Resume Music",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlaySongIntent(),
            phrases: [
                "Song on \(.applicationName)",
                "Find a song on \(.applicationName)"
            ],
            shortTitle: "Play a Song",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: SonarReportIntent(),
            phrases: [
                "Report of \(.applicationName)"
            ],
            shortTitle: "Sonar Report",
            systemImageName: "stopwatch"
        )
    }
}
