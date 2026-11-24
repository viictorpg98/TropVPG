//
//  RadioNotebook.swift
//  Trop
//
//  El "cuaderno" del programa: de que se ha hablado hoy (para no repetirse y poder retomarlo: "como decia antes...") y unos rasgos FIJOS de los dos locutores
//  (inventados: el primo, la comadre, el ventilador del estudio...) que dan continuidad. Todo local en el movil; no lleva datos de la persona.
//

import Foundation

enum RadioNotebook {
    private struct Entry: Codable {
        let day: String
        let topic: String
    }

    private static let key = "radio.notebook.v1"

    /// Rasgos fijos (siempre los mismos): se le dan dos al azar a cada pieza y solo se usan si vienen al caso.
    private static let bible = [
        "Pitirre tiene un primo, Junior, que presume de saber de todo y casi nunca acierta.",
        "Chuleta tiene una comadre, Nilda, que exagera todo lo que cuenta.",
        "A Pitirre le cuesta madrugar y siempre llega justo al estudio.",
        "Chuleta apunta en una libreta las tonterias de Pitirre.",
        "En el estudio hay un ventilador que hace ruido y nadie arregla.",
        "Pitirre se hace el despistado con el futbol para picar a Chuleta.",
        "Chuleta es muy puntual y se lo echa en cara a Pitirre.",
        "Pitirre pierde el movil cada dos por tres."
    ]

    private static func today() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return saved
    }

    /// Apunta de que ha ido una pieza (3 a 6 palabras); se guardan las de los ultimos dias, como mucho 30.
    static func add(_ topic: String) {
        let clean = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var saved = load()
        saved.append(Entry(day: today(), topic: String(clean.prefix(80))))
        if saved.count > 30 { saved.removeFirst(saved.count - 30) }
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func todayTopics() -> [String] {
        let day = today()
        return load().filter { $0.day == day }.map(\.topic)
    }

    /// Lo que se añade al prompt de cada pieza: lo ya tratado hoy, rasgos fijos y, a veces, algo de antes para retomar.
    static func promptBlock() -> String {
        var text = ""
        let topics = todayTopics()
        if !topics.isEmpty {
            text += "\nLO QUE YA SE HA TRATADO HOY EN EL PROGRAMA (no lo repitas; puedes retomarlo de pasada, por ejemplo \"como decia antes\"): "
                + topics.suffix(10).joined(separator: "; ") + "."
            if topics.count >= 3, Int.random(in: 0..<5) == 0, let again = topics.dropLast().randomElement() {
                text += "\nEsta vez puedes retomar de pasada esto de antes: \(again)."
            }
        }
        text += "\nCOSAS FIJAS DE LOS PERSONAJES (siempre son asi; usalas solo si vienen al caso y en menos de la mitad de las piezas): "
            + bible.shuffled().prefix(2).joined(separator: " ")
        return text
    }
}
