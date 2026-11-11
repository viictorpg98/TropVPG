//
//  SongTint.swift
//  Trop
//
//  El color de fondo del menu de una cancion: el de su carátula, oscurecido, como el reproductor y el mini.
//

import SwiftUI

@MainActor
enum SongTint {
    static func color(forThumbnail url: String?) async -> Color? {
        guard let url, let source = URL(string: url) else { return nil }
        let image: UIImage?
        if let cached = ArtworkLoader.cachedImage(for: source) {
            image = cached
        } else {
            image = try? await ArtworkLoader.image(for: source)
        }
        guard let image, let first = image.extractDominantColors().first else { return nil }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(first).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // Casi gris: un gris oscuro neutro; con color: su tono, oscuro, para que el texto blanco se lea.
        if saturation < 0.15 { return Color(white: 0.13) }
        return Color(hue: Double(hue), saturation: Double(min(saturation, 0.7)), brightness: 0.24)
    }
}
