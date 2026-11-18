//
//  HomeSectionTitles.swift
//  Trop
//
//  Como se reconocen por su titulo las secciones del inicio de YouTube Music que importan a la app: "Selecciones rapidas" y "Volver a
//  escuchar" (Acceso rapido). Lo usan el inicio (`HomeViewModel.mapServerSection`) y los widgets de portadas (`WidgetDataStore`), para
//  que los dos hablen de lo mismo. Sin mayusculas ni acentos, y en español o en ingles (con un chip YouTube manda los titulos en el
//  idioma del movil).
//

import Foundation

enum HomeSectionTitles {
    private static func plain(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func isQuickPicks(_ title: String) -> Bool {
        let value = plain(title)
        return value.contains("quick pick") || value.contains("selecciones rapidas")
    }

    /// "Long listens" (canciones muy largas): los widgets no las usan para completar Selecciones rapidas. La traduccion al español es una
    /// suposicion (no se ha visto el titulo en español).
    static func isLongListens(_ title: String) -> Bool {
        let value = plain(title)
        return value.contains("long listen") || value.contains("escuchas largas")
    }

    static func isKeepListening(_ title: String) -> Bool {
        let value = plain(title)
        return value.contains("listen again") || value.contains("keep listening") || value.contains("volver a escuchar")
            || value.contains("vuelve a escuchar")
            || value.contains("acceso rapido") || value.contains("speed dial") || value.contains("quick access")
    }
}
