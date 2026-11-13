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
    /// Estado inmediato (sin el margen de 2 s de `isOnline`): para decidir al momento si hay red.
    private(set) var hasConnection = true

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var offlineTask: Task<Void, Never>?
    /// Por que red salia el telefono en la ultima lectura ("wifi", "datos", "cable"...): para notar el paso de una a otra.
    @ObservationIgnored private var lastInterface: String?
    @ObservationIgnored private var lastInterfaceChange = Date.distantPast
    /// El telefono cambio de Wi-Fi a datos (o al reves) hace menos de un minuto. Las direcciones de googlevideo llevan la IP
    /// publica de quien las pidio: tras el cambio dejan de valer y las canciones fallan al abrirse, aunque haya red.
    var changedInterfaceRecently: Bool { Date().timeIntervalSince(lastInterfaceChange) < 60 }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let interface = Self.interfaceName(path)
            Task { @MainActor [weak self] in
                self?.handle(satisfied: satisfied, interface: interface)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.sonar.networkMonitor"))
    }

    /// Si no hay conexion enseña el aviso y devuelve `false`; con conexion no hace nada y devuelve `true`.
    func requireConnection(
        _ message: String = NSLocalizedString("No connection: this needs internet.", comment: "")
    ) -> Bool {
        if hasConnection { return true }
        PlaybackNotice.shared.show(message)
        return false
    }

    nonisolated private static func interfaceName(_ path: NWPath) -> String {
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.cellular) { return "datos" }
        if path.usesInterfaceType(.wiredEthernet) { return "cable" }
        return "otra"
    }

    private func handle(satisfied: Bool, interface: String) {
        let wasOffline = !hasConnection
        hasConnection = satisfied
        if satisfied {
            if let last = lastInterface, last != interface {
                lastInterfaceChange = Date()
                NowPlaying.shared.networkInterfaceChanged(from: last, to: interface)
            }
            lastInterface = interface
        }
        offlineTask?.cancel()
        if satisfied {
            if wasOffline { NowPlaying.shared.connectionRestored() }
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
