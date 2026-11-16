//
//  ManualMixStore.swift
//  Trop
//
//  El estilo de mezcla que has elegido TU para una pareja de canciones (la que suena y la siguiente): su duracion y si se
//  iguala el tempo. Manda sobre lo que elegiria AutoMix (y sobre su aprendizaje). Se guarda por pareja, en el movil.
//

import Foundation

@MainActor
final class ManualMixStore {
    static let shared = ManualMixStore()

    /// Lo que se puede elegir a mano.
    struct Choice: Equatable {
        var length: MixStyle.Length
        var matchTempo: Bool

        var stored: String { "\(length.rawValue)|\(matchTempo ? "tempo" : "libre")" }

        init(length: MixStyle.Length, matchTempo: Bool) {
            self.length = length
            self.matchTempo = matchTempo
        }

        init?(stored: String) {
            let parts = stored.split(separator: "|").map(String.init)
            guard parts.count == 2, let length = MixStyle.Length(rawValue: parts[0]) else { return nil }
            self.init(length: length, matchTempo: parts[1] == "tempo")
        }
    }

    private static let defaultsKey = "automix.manualStyles.v1"
    private static let maxPairs = 200
    private var styles: [String: String]

    private init() {
        styles = (UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String]) ?? [:]
    }

    private func pairKey(_ outId: String, _ inId: String) -> String { "\(outId)>\(inId)" }

    func choice(outId: String, inId: String) -> Choice? {
        styles[pairKey(outId, inId)].flatMap { Choice(stored: $0) }
    }

    /// `nil` quita lo elegido (AutoMix vuelve a decidir).
    func set(_ choice: Choice?, outId: String, inId: String) {
        let key = pairKey(outId, inId)
        if let choice {
            styles[key] = choice.stored
            if styles.count > Self.maxPairs {
                // El diccionario no guarda el orden: se recorta al azar lo que sobra, sin tocar esta pareja.
                for other in styles.keys.filter({ $0 != key }).prefix(styles.count - Self.maxPairs) { styles[other] = nil }
            }
        } else {
            styles[key] = nil
        }
        UserDefaults.standard.set(styles, forKey: Self.defaultsKey)
    }
}
