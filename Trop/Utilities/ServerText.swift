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

    static func localize(_ text: String) -> String {
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
