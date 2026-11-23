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
    case noticiero, tiempo, anuncios, tendencias

    var name: String {
        switch self {
        case .noticiero: return "noticiero"
        case .tiempo: return "tiempo"
        case .anuncios: return "anuncios"
        case .tendencias: return "tendencias"
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
        }
    }

    var icon: String {
        switch self {
        case .noticiero: return "newspaper"
        case .tiempo: return "cloud.sun"
        case .anuncios: return "megaphone"
        case .tendencias: return "chart.line.uptrend.xyaxis"
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
        let options = ["a", "b"].compactMap { url("radio-seccion-\(kind.name)-\($0)", "mp3") }
        return options.randomElement()
    }

    /// Una cuña con efectos (de entrada, 4, o de salida, 3), al azar. Ya viene a su nivel.
    static func cuna(entrance: Bool) -> RadioClip? {
        let kind = entrance ? "entrada" : "salida"
        let count = entrance ? 4 : 3
        let numbers = Array(1...count).shuffled()
        for number in numbers {
            guard let file = url("radio-cuna-\(kind)-\(number)", "wav"), let data = try? Data(contentsOf: file) else { continue }
            let seconds = RadioAudio.duration(of: data)
            if seconds > 0 { return RadioClip(wav: data, seconds: seconds, needsBoost: false) }
        }
        return nil
    }
}
