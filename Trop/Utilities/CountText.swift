//
//  CountText.swift
//  Trop
//

import Foundation

/// Recuentos localizados (singular y plural). Se usan donde la cadena se arma a mano
/// y SwiftUI no la traduce por sí sola.
enum CountText {
    static func songs(_ count: Int) -> String {
        format(count == 1 ? "%lld song" : "%lld songs", count)
    }

    static func episodes(_ count: Int) -> String {
        format(count == 1 ? "%lld episode" : "%lld episodes", count)
    }

    static func offlineTracks(_ count: Int) -> String {
        format(count == 1 ? "%lld offline track" : "%lld offline tracks", count)
    }

    private static func format(_ key: String, _ count: Int) -> String {
        String(format: NSLocalizedString(key, comment: "Count label"), count)
    }
}
