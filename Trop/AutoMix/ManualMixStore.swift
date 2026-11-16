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

/// Guardar la transicion elegida para una pareja y aplicarla: si es la de la cancion que suena con la siguiente, se rehace el plan.
@MainActor
enum MixTransition {
    /// Guarda la eleccion (`nil`: que decida AutoMix) y devuelve el texto que explica cuando se aplicara.
    @discardableResult
    static func apply(_ choice: ManualMixStore.Choice?, outId: String, inId: String) -> String {
        ManualMixStore.shared.set(choice, outId: outId, inId: inId)
        let np = NowPlaying.shared
        let isNext = np.queueSongs.indices.contains(np.queueIndex) && np.queueIndex + 1 < np.queueSongs.count
            && np.queueSongs[np.queueIndex].videoId == outId && np.queueSongs[np.queueIndex + 1].videoId == inId
        guard SettingsStore.shared.autoMixEnabled else {
            return NSLocalizedString("Saved, but AutoMix is off: turn it on in Settings to use it.", comment: "")
        }
        guard isNext else {
            return NSLocalizedString("Saved for when these two songs play.", comment: "")
        }
        if AutoMixEngine.shared.isActive {
            return NSLocalizedString("Saved. This mix is already prepared; it applies the next time these two play.", comment: "")
        }
        AutoMixEngine.shared.replan()
        return NSLocalizedString("Saved for the next transition.", comment: "")
    }

    /// El nombre corto de lo elegido, para la etiqueta entre dos canciones ("Automatic" si no se ha tocado).
    static func title(for choice: ManualMixStore.Choice?) -> String {
        guard let choice else { return NSLocalizedString("Automatic", comment: "") }
        switch choice.length {
        case .short: return NSLocalizedString("Short Blend", comment: "")
        case .medium: return NSLocalizedString("Medium Blend", comment: "")
        case .long: return NSLocalizedString("Long Blend", comment: "")
        }
    }
}
