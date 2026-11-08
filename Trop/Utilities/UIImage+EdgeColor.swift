//
//  UIImage+EdgeColor.swift
//  Trop
//

import SwiftUI
import UIKit

extension UIImage {
    /// Color medio de la franja inferior de la imagen: el que hay que usar de fondo para que la carátula se funda con
    /// el reproductor sin que se note el corte.
    func bottomEdgeColor(fraction: CGFloat = 0.14) -> Color? {
        guard let cg = cgImage else { return nil }
        let height = cg.height
        let strip = max(1, Int(CGFloat(height) * fraction))
        guard let cropped = cg.cropping(to: CGRect(x: 0, y: height - strip, width: cg.width, height: strip)) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return Color(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
    }
}
