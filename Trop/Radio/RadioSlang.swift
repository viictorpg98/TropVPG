//
//  RadioSlang.swift
//  Trop
//
//  Las muletillas de los locutores ("dale", "brutal", "nene", "ay bendito", "vamos con...") que, repetidas pieza tras pieza, delatan que es una IA. Se cuentan en las
//  ultimas cinco piezas: las que salieron en dos o mas se prohiben para la siguiente (se le dice a Gemini y, si se cuela alguna, se reintenta).
//

import Foundation

enum RadioSlang {
    private static let terms: [(name: String, regex: NSRegularExpression?)] = [
        ("dale", try? NSRegularExpression(pattern: "\\bdale\\b", options: [.caseInsensitive])),
        ("brutal", try? NSRegularExpression(pattern: "\\bbrutal", options: [.caseInsensitive])),
        ("nene", try? NSRegularExpression(pattern: "\\bnen[ea]s?\\b", options: [.caseInsensitive])),
        ("ay bendito", try? NSRegularExpression(pattern: "\\bbendito\\b", options: [.caseInsensitive])),
        ("chavos", try? NSRegularExpression(pattern: "\\bchavos?\\b", options: [.caseInsensitive])),
        ("janguear", try? NSRegularExpression(pattern: "\\bjangue", options: [.caseInsensitive])),
        ("mi primo / mi comadre", try? NSRegularExpression(pattern: "\\bmi (primo|prima|comadre|compadre)\\b", options: [.caseInsensitive])),
        ("atención (al empezar)", try? NSRegularExpression(pattern: "^\\W*atenci[oó]n", options: [.caseInsensitive])),
        ("vamos con / vámonos con", try? NSRegularExpression(pattern: "\\bv[aá]monos con\\b|\\bvamos con\\b|\\bsigamos con\\b", options: [.caseInsensitive])),
        ("hablando de", try? NSRegularExpression(pattern: "\\bhablando de\\b", options: [.caseInsensitive])),
        // Con humor picante, los tacos tambien se reparten: el que sale en dos de las ultimas cinco piezas descansa.
        ("carajo", try? NSRegularExpression(pattern: "\\bcarajo", options: [.caseInsensitive])),
        ("joder", try? NSRegularExpression(pattern: "\\bjod[eií]", options: [.caseInsensitive])),
        ("coño", try? NSRegularExpression(pattern: "\\bco[ñn]o\\b", options: [.caseInsensitive])),
        ("mierda", try? NSRegularExpression(pattern: "\\bmierda", options: [.caseInsensitive])),
        ("cabrón", try? NSRegularExpression(pattern: "\\bcabr[oó]n|\\bcabrona", options: [.caseInsensitive])),
        ("pendejo", try? NSRegularExpression(pattern: "\\bpendej", options: [.caseInsensitive])),
        ("hijo de puta", try? NSRegularExpression(pattern: "\\bhij[oa] ?(?:de|e) ?puta|\\bhijueputa", options: [.caseInsensitive])),
        ("cojones", try? NSRegularExpression(pattern: "\\bcojones", options: [.caseInsensitive]))
    ]

    /// Los tacos solo descansan cuando salen en tres de las ultimas cinco piezas (con dos, casi todos estarian prohibidos siempre).
    private static let swears: Set<String> = ["carajo", "joder", "coño", "mierda", "cabrón", "pendejo", "hijo de puta", "cojones"]

    private static func present(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return terms.compactMap { (term) -> String? in
            guard let regex = term.regex, regex.firstMatch(in: text, options: [], range: range) != nil else { return nil }
            return term.name
        }
    }

    /// Las que salieron en dos o mas de las ultimas cinco piezas.
    static func overused() -> [String] {
        var counts: [String: Int] = [:]
        for piece in RadioHistory.all().suffix(5) {
            let text = piece.map(\.text).joined(separator: " ")
            for name in present(in: text) { counts[name, default: 0] += 1 }
        }
        return counts.filter { $0.value >= (swears.contains($0.key) ? 3 : 2) }.map { $0.key }.sorted()
    }

    /// Las muletillas prohibidas ahora que aparecen en este texto.
    static func violations(in text: String) -> [String] {
        let banned = Set(overused())
        guard !banned.isEmpty else { return [] }
        return present(in: text).filter { banned.contains($0) }
    }

    /// La linea del prompt con las muletillas que no se pueden usar esta vez ("" si no hay ninguna).
    static func promptLine() -> String {
        let banned = overused()
        guard !banned.isEmpty else { return "" }
        return "\nMULETILLAS QUE NO PUEDES USAR ESTA VEZ (se han repetido demasiado y suena a guion): " + banned.joined(separator: ", ") + ". Di eso mismo de otra forma, o sin ellas."
    }
}
