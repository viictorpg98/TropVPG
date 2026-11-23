//
//  RadioSounds.swift
//  Trop
//
//  Los audios fijos de la radio, hechos antes en el PC y metidos en la app (Trop/Radio/Sounds): las cuñas con efectos (WAV, ya a su nivel: no se les sube el
//  volumen) y las musiquitas de las secciones (MP3 de unos 30 s, de un modelo de musica de Google). Si falta alguno, la radio sigue sin el.
//

import Foundation
import UIKit

enum RadioSectionKind: CaseIterable {
    case noticiero, tiempo, anuncios, tendencias, top5, hoy, whatsapp, deportes

    var name: String {
        switch self {
        case .noticiero: return "noticiero"
        case .tiempo: return "tiempo"
        case .anuncios: return "anuncios"
        case .tendencias: return "tendencias"
        case .top5: return "top5"
        case .hoy: return "hoy"
        case .whatsapp: return "whatsapp"
        case .deportes: return "deportes"
        }
    }

    /// Para el informe.
    var title: String { "seccion \(name)" }

    /// Nombre de la seccion en la pestaña Radio (clave de traduccion).
    var displayKey: String {
        switch self {
        case .noticiero: return "Newscast"
        case .tiempo: return "Weather Report"
        case .anuncios: return "Ad Break"
        case .tendencias: return "Most Searched"
        case .top5: return "My Top 5 of the Week"
        case .hoy: return "On This Day"
        case .whatsapp: return "Listener Messages"
        case .deportes: return "Sports Corner"
        }
    }

    var icon: String {
        switch self {
        case .noticiero: return "newspaper"
        case .tiempo: return "cloud.sun"
        case .anuncios: return "megaphone"
        case .tendencias: return "chart.line.uptrend.xyaxis"
        case .top5: return "list.number"
        case .hoy: return "calendar"
        case .whatsapp: return "message"
        case .deportes: return "sportscourt"
        }
    }

    /// La musiquita (hay 2 por cada una de las 4 de siempre; las nuevas secciones usan la de otra mientras no tengan la suya).
    var bedName: String {
        switch self {
        case .top5: return "tendencias"
        case .deportes: return "tendencias"
        case .hoy: return "tiempo"
        case .whatsapp: return "anuncios"
        default: return name
        }
    }
}

enum RadioSounds {
    /// El archivo en el paquete de la app: primero en la raiz y luego en las carpetas por si se conservan.
    static func url(_ name: String, _ ext: String) -> URL? {
        if let found = Bundle.main.url(forResource: name, withExtension: ext) { return found }
        for folder in ["Sounds", "Radio/Sounds", "Radio"] {
            if let found = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: folder) { return found }
        }
        return nil
    }

    /// La ilustracion (inventada) de un locutor: "Pitirre" o "Chuleta".
    static func avatar(_ host: String) -> UIImage? {
        let name = host == "Chuleta" ? "radio-avatar-chuleta" : "radio-avatar-pitirre"
        guard let file = url(name, "jpg") else { return nil }
        return UIImage(contentsOfFile: file.path)
    }

    /// La musiquita de una seccion (al azar entre las dos que hay), como archivo (se reproduce con `AVAudioPlayer`; NO pasa por `RadioAudio`).
    static func bed(for kind: RadioSectionKind) -> URL? {
        let options = ["a", "b"].compactMap { url("radio-seccion-\(kind.bedName)-\($0)", "mp3") }
        return options.randomElement()
    }

    /// Un golpe musical corto de Lyria (8, de 4,5 s, ya a nivel bajo) para las entradas de las charlas, al azar; la voz va por encima y el golpe baja mientras habla.
    static func golpe() -> URL? {
        (1...8).shuffled().lazy.compactMap { url("radio-golpe-\($0)", "mp3") }.first
    }
}
