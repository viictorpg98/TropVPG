//
//  WidgetShared.swift
//  Trop
//
//  Lo que comparten la app y el widget de portadas: los datos que la app deja en un "grupo de app" (una carpeta comun) y
//  como encontrar esa carpeta. Se compila en la app y en la extension del widget, asi que solo usa Foundation.
//
//  Con SideStore y una cuenta gratuita el grupo no se llama como en el proyecto: SideStore le añade el identificador del
//  equipo y escribe los nombres reales en la clave `ALTAppGroups` del Info.plist de cada paquete (app y extension). Por eso
//  el nombre se busca en ese orden: el Info.plist propio, el de la app (si se ejecuta la extension), el perfil de
//  aprovisionamiento incrustado y, por ultimo, el nombre del proyecto. Vale el primero con el que se puede abrir la carpeta.
//

import Foundation

/// Una cancion o episodio con su portada ya descargada (el nombre de archivo dentro de `covers/`).
struct WidgetTrack: Codable, Hashable {
    var id: String
    var title: String
    var artist: String
    var cover: String?
    /// Duracion en segundos y si es un episodio de podcast: la app los necesita al reproducir (sin ellos, un episodio de 88 min se
    /// pedia como una cancion normal y YouTube rechazaba la direccion). Opcionales para leer datos escritos por versiones anteriores.
    var duration: Int?
    var episode: Bool?
}

/// Lo que ensenan los widgets de portadas: la app lo reescribe cuando cambia el inicio. Son RESERVAS de unas 16 canciones por lista: cada widget ensena un grupo de 4 y va cambiando de grupo con el paso del tiempo, sin abrir la app.
struct WidgetSnapshot: Codable {
    var updated: Date
    var quickPicks: [WidgetTrack]
    var speedDial: [WidgetTrack]
}

/// Marca de que la app llego a escribir en la carpeta compartida (sirve para saber si el reparto funciona).
struct WidgetProbe: Codable {
    var written: Date
    var groupId: String
    var bundleId: String
}

/// Como rotan las portadas: una lista (la reserva) se parte en grupos de 4 y cada widget ensena un grupo que cambia cada media hora, segun el
/// reloj. La usan el widget (para saber que ensenar) y la app (para saber que se esta viendo y poner ahi canciones nuevas al "Actualizar").
enum WidgetRotation {
    static let seconds: TimeInterval = 1800

    static func slot(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / seconds).rounded(.down))
    }

    /// Las posiciones de una lista de `count` canciones que ensena un widget en `date`. El segundo widget de Selecciones rapidas (`second`)
    /// va con medio ciclo de diferencia para no repetir el grupo del primero. Si el ultimo grupo queda corto se completa con las primeras.
    static func visibleIndices(count: Int, date: Date, second: Bool) -> [Int] {
        guard count > 4 else { return Array(0..<count) }
        let groups = (count + 3) / 4
        let offset = second ? groups / 2 : 0
        let group = (((slot(date) + offset) % groups) + groups) % groups
        return (0..<4).map { (group * 4 + $0) % count }
    }
}

/// El estado de los botones del widget: hoy, si la radio esta en el aire (el boton se ve distinto). Los campos son opcionales para leer
/// sin problema lo que dejo una version anterior.
struct WidgetButtonState: Codable {
    var radio: Bool?
    var updated: Date?
}

/// En que punto esta el reparto de datos, tal como lo ve el widget.
enum WidgetShareState {
    /// Ningun nombre de grupo abre una carpeta: el sistema no ha dado el grupo a esta extension.
    case noContainer(tried: [String])
    /// La carpeta se abre, pero aun no hay datos. `appWrote`: la app ya dejo su marca (falta cargar el inicio).
    case noData(groupId: String, appWrote: Bool)
    case ready(WidgetSnapshot)
}

enum WidgetShared {
    static let fallbackGroup = "group.com.686udjie.Trop"

    // MARK: - Buscar el grupo

    private static func groups(in info: [String: Any]?) -> [String] {
        (info?["ALTAppGroups"] as? [String]) ?? []
    }

    /// Los grupos que concede el perfil incrustado (si SideStore lo deja en el paquete).
    private static func provisionedGroups() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)),
              start.lowerBound < end.upperBound else { return [] }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = (try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil)) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return [] }
        return (entitlements["com.apple.security.application-groups"] as? [String]) ?? []
    }

    /// Todos los nombres posibles del grupo, sin repetir y en orden de preferencia.
    static func candidateGroups() -> [String] {
        var found: [String] = []
        func add(_ ids: [String]) {
            for id in ids where !id.isEmpty && !found.contains(id) { found.append(id) }
        }
        add(groups(in: Bundle.main.infoDictionary))
        // La extension vive en Trop.app/PlugIns/X.appex: el Info.plist de la app esta dos niveles mas arriba.
        if Bundle.main.bundleURL.pathExtension == "appex" {
            let hostInfo = Bundle.main.bundleURL
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Info.plist")
            add(groups(in: NSDictionary(contentsOf: hostInfo) as? [String: Any]))
        }
        add(provisionedGroups())
        add([fallbackGroup])
        return found
    }

    /// El primer grupo con el que se puede abrir la carpeta compartida (`nil` si ninguno).
    static var resolved: (id: String, url: URL)? {
        for id in candidateGroups() {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
                return (id, url)
            }
        }
        return nil
    }

    // MARK: - Archivos

    private static let snapshotName = "widget-snapshot.json"
    private static let probeName = "widget-probe.json"

    static func coversDirectory(in base: URL) -> URL {
        base.appendingPathComponent("covers", isDirectory: true)
    }

    /// Ruta de una portada ya descargada, o `nil` si no hay carpeta compartida.
    static func coverPath(_ name: String) -> String? {
        guard let base = resolved?.url else { return nil }
        return coversDirectory(in: base).appendingPathComponent(name).path
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func save(_ snapshot: WidgetSnapshot, in base: URL) throws {
        let data = try encoder().encode(snapshot)
        try data.write(to: base.appendingPathComponent(snapshotName), options: .atomic)
    }

    static func loadSnapshot() -> WidgetSnapshot? {
        guard let base = resolved?.url,
              let data = try? Data(contentsOf: base.appendingPathComponent(snapshotName)) else { return nil }
        return try? decoder().decode(WidgetSnapshot.self, from: data)
    }

    static func writeProbe(groupId: String, bundleId: String, in base: URL) {
        let probe = WidgetProbe(written: Date(), groupId: groupId, bundleId: bundleId)
        if let data = try? encoder().encode(probe) {
            try? data.write(to: base.appendingPathComponent(probeName), options: .atomic)
        }
    }

    static func loadProbe() -> WidgetProbe? {
        guard let base = resolved?.url,
              let data = try? Data(contentsOf: base.appendingPathComponent(probeName)) else { return nil }
        return try? decoder().decode(WidgetProbe.self, from: data)
    }

    private static let buttonStateName = "widget-state.json"

    static func writeButtonState(_ value: WidgetButtonState, in base: URL) {
        if let data = try? encoder().encode(value) {
            try? data.write(to: base.appendingPathComponent(buttonStateName), options: .atomic)
        }
    }

    static func loadButtonState() -> WidgetButtonState? {
        guard let base = resolved?.url,
              let data = try? Data(contentsOf: base.appendingPathComponent(buttonStateName)) else { return nil }
        return try? decoder().decode(WidgetButtonState.self, from: data)
    }

    /// El estado completo, para que el widget enseñe datos o diga que falla.
    static func state() -> WidgetShareState {
        guard let found = resolved else { return .noContainer(tried: candidateGroups()) }
        if let snapshot = loadSnapshot() { return .ready(snapshot) }
        return .noData(groupId: found.id, appWrote: loadProbe() != nil)
    }
}
