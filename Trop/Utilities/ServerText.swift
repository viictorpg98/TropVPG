//
//  ServerText.swift
//  Trop
//

import Foundation

/// Traduce nombres de listas que YouTube genera en inglés con un patrón fijo
/// (por ejemplo "Trending 20 Spain"). Solo actúa si el texto empieza por uno de
/// los patrones conocidos, así que nunca toca títulos de canciones.
enum ServerText {
    private static let regionCodesByEnglishName: [String: String] = {
        let english = Locale(identifier: "en_US")
        var map: [String: String] = [:]
        for region in Locale.Region.isoRegions {
            if let name = english.localizedString(forRegionCode: region.identifier) {
                map[name] = region.identifier
            }
        }
        return map
    }()

    private static let patterns: [(prefix: String, key: String)] = [
        ("Trending 20 ", "Trending 20 %@"),
        ("Daily Top Music Videos - ", "Daily Top Music Videos - %@"),
        ("Top 100 Music Videos ", "Top 100 Music Videos %@")
    ]

    /// "3.3K views", "3,3 K visualizaciones", "12 listening", "2 mil descargas"...
    /// Los textos de recuento llegan en el idioma en que se pidieron (ingles o el del dispositivo).
    static func isViewsText(_ lowercased: String) -> Bool {
        ["view", "listening", "download", "visualiz", "reproducc", "escucha", "oyente", "descarga", "vistas"]
            .contains { lowercased.contains($0) }
    }

    /// "4 hr ago", "1d ago", "hace 1 d". Importa que no se tome por una duracion ("hace 4 h" no son 4 horas).
    static func isRelativeDate(_ lowercased: String) -> Bool {
        lowercased.contains("ago") || lowercased.hasPrefix("hace ") || lowercased.hasPrefix("hace\u{a0}")
    }

    /// Nombres que YouTube Music da en ingles a sus listas propias (no son titulos de canciones).
    private static let systemNames: Set<String> = [
        "Liked Music", "New Episodes", "Episodes for later", "My Supermix", "Discover Mix", "New Release Mix"
    ]

    /// "Rels B, La Pantera, Mabreezee and Milo j" -> "Rels B, La Pantera, Mabreezee y Milo j" (en espanol).
    static func localizeArtistList(_ text: String) -> String {
        guard Locale.current.language.languageCode?.identifier == "es",
              let range = text.range(of: " and ", options: .backwards) else { return text }
        return text.replacingCharacters(in: range, with: " y ")
    }

    static func localize(_ text: String) -> String {
        if systemNames.contains(text) {
            return NSLocalizedString(text, comment: "Nombre de una lista del sistema de YouTube Music")
        }
        if text.hasPrefix("My Mix "), let number = text.split(separator: " ").last, Int(number) != nil {
            return String(format: NSLocalizedString("My Mix %@", comment: ""), String(number))
        }
        for pattern in patterns where text.hasPrefix(pattern.prefix) {
            let country = String(text.dropFirst(pattern.prefix.count))
            guard let code = regionCodesByEnglishName[country],
                  let localName = Locale.current.localizedString(forRegionCode: code) else {
                return text
            }
            return String(format: NSLocalizedString(pattern.key, comment: "YouTube chart name"), localName)
        }
        return text
    }
}
