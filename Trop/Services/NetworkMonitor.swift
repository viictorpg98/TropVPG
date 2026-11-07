//
//  NetworkMonitor.swift
//  Trop
//

import Foundation
import Network
import Observation

/// Estado de la conexion a internet, para avisar cuando no hay y ofrecer las descargas.
@Observable
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    /// `true` mientras haya conexion. Hasta recibir la primera lectura se da por buena.
    private(set) var isOnline = true
    /// La persona ha cerrado el aviso; vuelve a salir la proxima vez que se pierda la conexion.
    var bannerDismissed = false

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var offlineTask: Task<Void, Never>?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.handle(satisfied: satisfied)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.sonar.networkMonitor"))
    }

    private func handle(satisfied: Bool) {
        offlineTask?.cancel()
        if satisfied {
            isOnline = true
            bannerDismissed = false
        } else {
            // Los cortes breves (por ejemplo al pasar de Wi-Fi a datos) no cuentan.
            offlineTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.isOnline = false
            }
        }
    }
}
