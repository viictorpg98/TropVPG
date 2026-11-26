//
//  RadioLocal.swift
//  Trop
//
//  La emisora es LOCAL: los locutores "hacen radio" desde la ciudad que elijas en Ajustes (la misma del tiempo), hablan de la zona como vecinos y los oyentes
//  inventados son de los pueblos de alrededor. Solo se les deja aludir a lo que es seguro de cada ciudad (lugares que existen) o a lo que venga en los datos
//  (titulares locales, el tiempo): nada de inventar calles, locales ni noticias.
//

import Foundation

enum RadioLocal {
    struct Info {
        /// Donde esta, en una frase ("en el Valles Occidental, a unos 20 km de Barcelona").
        let area: String
        /// Pueblos y ciudades de alrededor (de donde son los oyentes inventados).
        let towns: [String]
        /// Cosas que existen seguro y de las que pueden hablar.
        let places: [String]
        /// Un RSS de noticias locales (si no hay, se busca la ciudad en Google Noticias).
        let feed: String?
    }

    private static let all: [String: Info] = [
        "Sabadell": Info(
            area: "en el Vallès Occidental, a unos 20 km de Barcelona",
            towns: ["Terrassa", "Barberà del Vallès", "Sant Quirze del Vallès", "Cerdanyola del Vallès", "Castellar del Vallès", "Sentmenat", "Polinyà"],
            places: ["el Parc Catalunya", "la Plaça Sant Roc", "la Plaça Major", "los Jardinets", "los trenes de FGC y de Rodalies a Barcelona",
                     "el CE Sabadell (los arlequinats)", "el pasado textil de la ciudad"],
            feed: "https://www.diaridesabadell.com/feed/"
        ),
        "Barcelona": Info(
            area: "en la costa catalana",
            towns: ["l'Hospitalet de Llobregat", "Badalona", "Sant Adrià de Besòs", "Cornellà de Llobregat", "Santa Coloma de Gramenet"],
            places: ["el metro y las Rodalies", "la Barceloneta", "Montjuïc", "el Camp Nou"], feed: nil
        ),
        "Madrid": Info(
            area: "en el centro de España",
            towns: ["Alcalá de Henares", "Getafe", "Móstoles", "Alcobendas", "Leganés"],
            places: ["el metro", "el Retiro", "la Gran Vía", "el río Manzanares"], feed: nil
        ),
        "Valencia": Info(
            area: "en la costa mediterránea",
            towns: ["Torrent", "Paterna", "Sagunto", "Mislata", "Burjassot"],
            places: ["el antiguo cauce del Turia", "el Mercat Central", "la Malvarrosa"], feed: nil
        ),
        "Sevilla": Info(
            area: "en el valle del Guadalquivir",
            towns: ["Dos Hermanas", "Alcalá de Guadaíra", "Mairena del Aljarafe", "Camas"],
            places: ["la Giralda", "Triana", "el Guadalquivir"], feed: nil
        ),
        "Bilbao": Info(
            area: "en la ría del Nervión",
            towns: ["Barakaldo", "Getxo", "Portugalete", "Sestao"],
            places: ["la ría", "el Guggenheim", "San Mamés", "el Casco Viejo"], feed: nil
        ),
        "Zaragoza": Info(
            area: "en el valle del Ebro",
            towns: ["Utebo", "Cuarte de Huerva", "Zuera"],
            places: ["el Ebro", "la basílica del Pilar", "el tranvía"], feed: nil
        ),
        "Málaga": Info(
            area: "en la Costa del Sol",
            towns: ["Torremolinos", "Benalmádena", "Fuengirola", "Vélez-Málaga"],
            places: ["la Malagueta", "la Alcazaba", "el Paseo del Parque"], feed: nil
        ),
        "Palma": Info(
            area: "en la isla de Mallorca",
            towns: ["Marratxí", "Llucmajor", "Calvià", "Inca"],
            places: ["la Seu", "el Paseo Marítimo", "la bahía"], feed: nil
        )
    ]

    static var cityName: String { RadioSettings.city.name }

    private static var info: Info? { all[cityName] }

    static var feedURL: String? { info?.feed }

    /// Los pueblos de alrededor como lista (para crear las voces de los oyentes).
    static var townList: [String] { info?.towns ?? [] }

    /// Los pueblos de alrededor, para los oyentes inventados.
    static var townsText: String {
        guard let towns = info?.towns, !towns.isEmpty else { return "pueblos y barrios de la zona" }
        return towns.joined(separator: ", ")
    }

    /// El bloque que se pega a la ficha de la emisora en todos los prompts.
    static var block: String {
        let city = cityName
        var text = "LUGAR: Sónar efe eme es una emisora LOCAL de \(city)"
        if let info { text += " (\(info.area))" }
        text += ". Los locutores viven y hacen radio ahi; los oyentes son vecinos de \(city) y de la zona (\(townsText)). "
        text += "De vez en cuando (no en cada pieza) hablan de la ciudad y de los alrededores como vecinos. "
        if let info, !info.places.isEmpty {
            text += "Sobre \(city) SOLO puedes aludir a lo que sabes seguro (\(info.places.joined(separator: "; "))) o a lo que venga en los DATOS (titulares locales, el tiempo). "
        } else {
            text += "Sobre \(city) SOLO puedes aludir a lo que venga en los DATOS (titulares locales, el tiempo). "
        }
        text += "No inventes nada de la ciudad: ni calles, ni locales, ni eventos, ni noticias locales. "
        if city != "Madrid" { text += "No hables de Madrid ni de otras ciudades como si vivieran alli, salvo que un dato lo pida. " }
        text += "Las noticias, anuncios y bromas INVENTADOS llevan nombres inventados: nunca atribuyas cosas falsas a lugares, clubes, empresas o personas reales de la ciudad. "
        text += "No hables del tiempo (calor, frio, lluvia, sol) salvo que se te de el dato del tiempo en esta pieza. "
        text += "No saludes con \"buenos dias\", \"buenas tardes\" o \"buenas noches\" ni digas la hora o el momento del dia salvo que se te de la hora en esta pieza."
        return text
    }
}
