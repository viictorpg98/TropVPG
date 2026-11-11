//
//  SleepTimer.swift
//  Trop
//
//  "Apaga la musica en N minutos" (por voz): pasado el tiempo baja el volumen poco a poco y pausa.
//

import Foundation

@MainActor
final class SleepTimer {
    static let shared = SleepTimer()

    private var task: Task<Void, Never>?
    private(set) var endDate: Date?

    private init() {}

    func start(minutes: Int) {
        cancel()
        guard minutes > 0 else { return }
        endDate = Date().addingTimeInterval(Double(minutes) * 60)
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.fadeOutAndPause()
        }
        PlaybackReport.record("temporizador: la musica se parara en \(minutes) min")
    }

    func cancel() {
        task?.cancel()
        task = nil
        endDate = nil
    }

    /// Unos 8 segundos de fundido y pausa; el volumen vuelve a su sitio para la proxima vez.
    private func fadeOutAndPause() async {
        let player = PlayerController.shared
        let steps = 20
        for step in 1...steps {
            player.volumeScale = 1 - Double(step) / Double(steps)
            player.applyPlayerVolume()
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled {
                player.volumeScale = 1
                player.applyPlayerVolume()
                return
            }
        }
        player.setPaused(true)
        player.volumeScale = 1
        player.applyPlayerVolume()
        endDate = nil
        task = nil
        PlaybackReport.record("temporizador: musica parada")
    }
}
