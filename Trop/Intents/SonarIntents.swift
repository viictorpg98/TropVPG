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

/// Pide un artista por su nombre: suenan sus canciones mas conocidas.
struct PlayArtistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play an Artist"
    static let description = IntentDescription("Plays the best-known songs of an artist you ask for.")

    @Parameter(title: "Artist", requestValueDialog: "Which artist?")
    var artist: String

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$artist)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if let name = await SonarMix.playArtist(named: artist) {
            let text = String(format: NSLocalizedString("Playing %@", comment: ""), name)
            return .result(dialog: "\(text)")
        }
        let text = NetworkMonitor.shared.hasConnection
            ? NSLocalizedString("I couldn't find that artist.", comment: "")
            : NSLocalizedString("No connection.", comment: "")
        return .result(dialog: "\(text)")
    }
}

/// Las canciones que te gustan, en mezcla. Vale sin conexion.
struct PlayLikedIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play My Likes"
    static let description = IntentDescription("Plays a mix of the songs you liked.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if await SonarMix.playLiked() {
            return .result(dialog: "\(NSLocalizedString("Playing your liked songs.", comment: ""))")
        }
        return .result(dialog: "\(NSLocalizedString("You have no liked songs saved yet.", comment: ""))")
    }
}

/// Las "Selecciones rapidas" del inicio de YouTube Music.
struct PlayQuickPicksIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Quick Picks"
    static let description = IntentDescription("Plays the Quick Picks from your home.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if await SonarMix.playQuickPicks() {
            return .result(dialog: "\(NSLocalizedString("Playing your quick picks.", comment: ""))")
        }
        let text = NetworkMonitor.shared.hasConnection
            ? NSLocalizedString("I couldn't load your quick picks.", comment: "")
            : NSLocalizedString("No connection.", comment: "")
        return .result(dialog: "\(text)")
    }
}

/// Los botones del inicio de YouTube Music (Entrenamiento, Dormir...), que traen su propia musica.
enum SonarCategory: String, AppEnum {
    case workout, energize, sleep, relax, focus, party, commute, feelGood, romance

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Category"

    static let caseDisplayRepresentations: [SonarCategory: DisplayRepresentation] = [
        .workout: "Workout",
        .energize: "Energize",
        .sleep: "Sleep",
        .relax: "Relax",
        .focus: "Focus",
        .party: "Party",
        .commute: "Commute",
        .feelGood: "Feel Good",
        .romance: "Romance"
    ]

    /// Palabras (sin acentos ni mayusculas) con las que puede llamarse el boton, en espanol o en ingles.
    var keywords: [String] {
        switch self {
        case .workout: return ["entrenamiento", "workout"]
        case .energize: return ["energizar", "energize"]
        case .sleep: return ["dormir", "sleep"]
        case .relax: return ["relaj", "relax", "calma"]
        case .focus: return ["concentr", "focus"]
        case .party: return ["fiesta", "party"]
        case .commute: return ["desplaz", "commute"]
        case .feelGood: return ["buen rollo", "feel good"]
        case .romance: return ["roman"]
        }
    }
}

struct PlayCategoryIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play a Category"
    static let description = IntentDescription("Plays the music of one of the buttons on your home, like Workout or Sleep.")

    @Parameter(title: "Category")
    var category: SonarCategory

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$category)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if let name = await SonarMix.playCategory(keywords: category.keywords) {
            let text = String(format: NSLocalizedString("Playing %@", comment: ""), name)
            return .result(dialog: "\(text)")
        }
        let text = NetworkMonitor.shared.hasConnection
            ? NSLocalizedString("I couldn't find that category on your home.", comment: "")
            : NSLocalizedString("No connection.", comment: "")
        return .result(dialog: "\(text)")
    }
}

/// "Apaga la musica en N minutos": baja el volumen poco a poco y para.
struct SleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Sleep Timer"
    static let description = IntentDescription("Fades the music out and stops it after the minutes you say. Say 0 to cancel.")

    @Parameter(title: "Minutes", requestValueDialog: "How many minutes?")
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Stop the music in \(\.$minutes) minutes")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if minutes <= 0 {
            SleepTimer.shared.cancel()
            return .result(dialog: "\(NSLocalizedString("Sleep timer cancelled.", comment: ""))")
        }
        SleepTimer.shared.start(minutes: minutes)
        let text = String(format: NSLocalizedString("The music will stop in %d minutes.", comment: ""), minutes)
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
            intent: PlayArtistIntent(),
            phrases: [
                "Artist on \(.applicationName)",
                "Play an artist on \(.applicationName)"
            ],
            shortTitle: "Play an Artist",
            systemImageName: "music.mic"
        )
        AppShortcut(
            intent: PlayLikedIntent(),
            phrases: [
                "My likes on \(.applicationName)"
            ],
            shortTitle: "Play My Likes",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: PlayQuickPicksIntent(),
            phrases: [
                "Quick picks on \(.applicationName)"
            ],
            shortTitle: "Play Quick Picks",
            systemImageName: "bolt.fill"
        )
        AppShortcut(
            intent: PlayCategoryIntent(),
            phrases: [
                "Play \(\.$category) on \(.applicationName)",
                "\(\.$category) on \(.applicationName)"
            ],
            shortTitle: "Play a Category",
            systemImageName: "square.grid.2x2.fill"
        )
        AppShortcut(
            intent: SleepTimerIntent(),
            phrases: [
                "Sleep timer on \(.applicationName)"
            ],
            shortTitle: "Sleep Timer",
            systemImageName: "moon.zzz.fill"
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
