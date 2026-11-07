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
            try await PlaybackManager.shared.resolveAndPlay(videoId: videoId)
        } else {
            _ = await SonarMix.start()
        }
        return .result()
    }
}

/// Frases para Siri que funcionan sin configurar nada ("Pon música en Sonar").
/// Las versiones en español van en `AppShortcuts.strings`.
struct SonarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayMyMusicIntent(),
            phrases: [
                "Play music on \(.applicationName)",
                "Play my music on \(.applicationName)"
            ],
            shortTitle: "Play Music",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: ResumeMusicIntent(),
            phrases: [
                "Resume music on \(.applicationName)"
            ],
            shortTitle: "Resume Music",
            systemImageName: "play.fill"
        )
    }
}
