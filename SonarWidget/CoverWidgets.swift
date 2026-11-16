//
//  CoverWidgets.swift
//  SonarWidget
//
//  Tres widgets de portadas, como el de YouTube Music: tus Selecciones rapidas, tu Acceso rapido (con el dado) y tus nuevos
//  episodios. Al tocar una portada suena esa cancion con su radio. Los datos y las portadas los deja la app en una carpeta
//  compartida (Shared/WidgetShared.swift); si el sistema no da esa carpeta al widget, enseña el motivo en vez de las portadas.
//  En CarPlay solo sale la version pequena; en la pantalla de inicio tambien la mediana.
//
//  Canciones: cuadricula de portadas cuadradas con el titulo abajo. Podcasts: miniaturas anchas (se ven casi enteras: solo se
//  recorta un poco arriba y abajo) con el titulo del episodio; 2 en la pequena (una sobre otra) y 4 en la mediana (2x2).
//

import AppIntents
import Foundation
import SwiftUI
import UIKit
import WidgetKit

struct CoverEntry: TimelineEntry {
    let date: Date
    let state: WidgetShareState
}

struct CoverProvider: TimelineProvider {
    func placeholder(in context: Context) -> CoverEntry {
        CoverEntry(date: Date(), state: .noData(groupId: "", appWrote: true))
    }

    func getSnapshot(in context: Context, completion: @escaping (CoverEntry) -> Void) {
        completion(CoverEntry(date: Date(), state: WidgetShared.state()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CoverEntry>) -> Void) {
        // La app avisa al widget cuando escribe datos nuevos; ademas se relee cada media hora.
        let entry = CoverEntry(date: Date(), state: WidgetShared.state())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(1800))))
    }
}

/// Que lista ensena cada widget.
enum CoverKind {
    case quickPicks
    case speedDial
    case episodes

    func tracks(in snapshot: WidgetSnapshot) -> [WidgetTrack] {
        switch self {
        case .quickPicks: return snapshot.quickPicks
        case .speedDial: return snapshot.speedDial
        case .episodes: return snapshot.episodes
        }
    }

    /// El Acceso rapido lleva el dado en la cuarta casilla.
    var hasDice: Bool { self == .speedDial }

    /// Los episodios llevan miniaturas anchas (16:9), no portadas cuadradas.
    var isWide: Bool { self == .episodes }

    var emptyMessageEs: String {
        switch self {
        case .quickPicks: return "Abre Sonar para cargar tus Selecciones rápidas"
        case .speedDial: return "Fija canciones en tu Acceso rápido desde Sonar"
        case .episodes: return "No hay episodios nuevos en tu inicio"
        }
    }

    var emptyMessageEn: String {
        switch self {
        case .quickPicks: return "Open Sonar to load your Quick Picks"
        case .speedDial: return "Pin songs to your Speed Dial in Sonar"
        case .episodes: return "No new episodes on your home"
        }
    }
}

private enum CoverCell: Identifiable {
    case track(WidgetTrack)
    case dice
    case empty(Int)

    var id: String {
        switch self {
        case .track(let track): return "t-" + track.id
        case .dice: return "dice"
        case .empty(let index): return "e-\(index)"
        }
    }
}

struct CoverWidgetView: View {
    let entry: CoverEntry
    let kind: CoverKind

    @Environment(\.widgetFamily) private var family

    private var spanish: Bool {
        Locale.preferredLanguages.first?.hasPrefix("es") ?? false
    }

    private static let plateColor = Color(red: 0.16, green: 0.16, blue: 0.18)
    /// Esquinas concentricas con las del widget (unos 24 pt) menos el margen de 9 pt.
    private static let cornerRadius: CGFloat = 16
    private static let gap: CGFloat = 8
    private static let margin: CGFloat = 9

    // MARK: Casillas

    /// Cuantas casillas lleva cada widget: 4 (2x2 o 4 en fila), salvo episodios pequeños, que son 2 apilados.
    private var slots: Int {
        if kind.isWide && family != .systemMedium { return 2 }
        return 4
    }

    private func cells(for snapshot: WidgetSnapshot) -> [CoverCell] {
        let tracks = kind.tracks(in: snapshot)
        let realSlots = kind.hasDice ? slots - 1 : slots
        var result: [CoverCell] = tracks.prefix(realSlots).map { .track($0) }
        var filler = 0
        while result.count < realSlots {
            result.append(.empty(filler))
            filler += 1
        }
        if kind.hasDice { result.append(.dice) }
        return result
    }

    private func placeholder() -> some View {
        ZStack {
            Self.plateColor
            Image(systemName: kind.isWide ? "mic.fill" : "music.note")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.35))
        }
    }

    @ViewBuilder
    private func coverImage(_ track: WidgetTrack) -> some View {
        if let name = track.cover, let path = WidgetShared.coverPath(name), let image = UIImage(contentsOfFile: path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            placeholder()
        }
    }

    /// Franja oscura con el titulo abajo (se degrada hacia arriba para que no haya un corte seco).
    private func titleScrim(_ title: String, lines: Int) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(lines)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7)
            .padding(.top, 16)
            .padding(.bottom, 5)
            .background(
                LinearGradient(colors: [.clear, Color.black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
            )
    }

    /// Casilla de portada con su titulo. La imagen va en una capa y el titulo en otra, las dos sobre una base que ya tiene el
    /// tamaño de la casilla: asi la imagen (que llena y se sale) no agranda la capa del titulo. Antes iban juntas en un ZStack y
    /// el titulo se maquetaba tan ancho como la imagen y salia cortado por los lados, sin puntos suspensivos.
    private func coverTile(_ track: WidgetTrack, isSquare: Bool, lines: Int) -> some View {
        Group {
            if isSquare {
                Color.clear.aspectRatio(1, contentMode: .fit)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay { coverImage(track) }
        .overlay(alignment: .bottom) { titleScrim(track.title, lines: lines) }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
    }

    /// Casilla cuadrada: el contenido llena el cuadrado y se recorta con esquinas redondeadas.
    private func square<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(content())
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
    }

    /// Casilla que ocupa todo el hueco que le toque (miniaturas anchas): la imagen llena el hueco y recorta lo que sobra.
    private func flexible<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Color.clear
            .overlay(content())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
    }

    private var diceCell: some View {
        Button(intent: WidgetDiceIntent()) {
            square {
                ZStack {
                    Self.plateColor
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color(red: 1.00, green: 0.69, blue: 0.30), Color(red: 1.00, green: 0.48, blue: 0.27)],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .frame(width: 42, height: 42)
                    Image(systemName: "dice.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color(red: 0.08, green: 0.08, blue: 0.09))
                }
            }
        }
        // Estilo plano: con el del sistema cada portada quedaba metida en un circulo gris con margen.
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func trackCell(_ track: WidgetTrack) -> some View {
        let intent = WidgetPlayTrackIntent(
            videoId: track.id,
            songTitle: track.title,
            songArtist: track.artist,
            songDuration: track.duration ?? 0,
            isEpisode: track.episode ?? false
        )
        Button(intent: intent) {
            coverTile(track, isSquare: !kind.isWide, lines: kind.isWide ? 2 : 1)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func cell(_ cell: CoverCell) -> some View {
        switch cell {
        case .track(let track):
            trackCell(track)
        case .dice:
            diceCell
        case .empty:
            if kind.isWide {
                flexible { placeholder() }
            } else {
                square { placeholder() }
            }
        }
    }

    // MARK: Diseño

    private func grid(_ cells: [CoverCell]) -> some View {
        Group {
            if kind.isWide && family != .systemMedium {
                // Podcasts pequeño: dos miniaturas, una sobre otra, a todo el ancho.
                VStack(spacing: Self.gap) {
                    cell(cells[0])
                    cell(cells[1])
                }
            } else if family == .systemMedium && !kind.isWide {
                HStack(spacing: Self.gap) {
                    ForEach(cells) { self.cell($0) }
                }
            } else {
                Grid(horizontalSpacing: Self.gap, verticalSpacing: Self.gap) {
                    GridRow {
                        cell(cells[0])
                        cell(cells[1])
                    }
                    GridRow {
                        cell(cells[2])
                        cell(cells[3])
                    }
                }
            }
        }
    }

    private func message(_ es: String, _ en: String, detail: String? = nil) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color(red: 1.00, green: 0.48, blue: 0.27))
            Text(spanish ? es : en)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .minimumScaleFactor(0.6)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func abbreviated(_ ids: [String]) -> String {
        ids.map { $0.replacingOccurrences(of: "group.com.686udjie.", with: "…") }.joined(separator: "\n")
    }

    @ViewBuilder
    private var content: some View {
        switch entry.state {
        case .noContainer(let tried):
            message(
                "Sin carpeta compartida con Sonar",
                "No shared folder with Sonar",
                detail: abbreviated(tried)
            )
        case .noData(let groupId, let appWrote):
            if appWrote {
                message(kind.emptyMessageEs, kind.emptyMessageEn)
            } else {
                message(
                    "Sonar aún no ha escrito aquí",
                    "Sonar hasn't written here yet",
                    detail: abbreviated([groupId])
                )
            }
        case .ready(let snapshot):
            if kind.tracks(in: snapshot).isEmpty && !kind.hasDice {
                message(kind.emptyMessageEs, kind.emptyMessageEn)
            } else {
                grid(cells(for: snapshot))
            }
        }
    }

    var body: some View {
        content
            .padding(Self.margin)
            .containerBackground(Color(red: 0.08, green: 0.08, blue: 0.09), for: .widget)
    }
}

struct SonarQuickPicksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SonarQuickPicks", provider: CoverProvider()) { entry in
            CoverWidgetView(entry: entry, kind: .quickPicks)
        }
        .configurationDisplayName("Sonar · Selecciones rápidas")
        .description("Portadas de tus Selecciones rápidas: toca una y suena.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct SonarSpeedDialWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SonarSpeedDial", provider: CoverProvider()) { entry in
            CoverWidgetView(entry: entry, kind: .speedDial)
        }
        .configurationDisplayName("Sonar · Acceso rápido")
        .description("Portadas de tu Acceso rápido y el dado.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct SonarEpisodesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SonarEpisodes", provider: CoverProvider()) { entry in
            CoverWidgetView(entry: entry, kind: .episodes)
        }
        .configurationDisplayName("Sonar · Podcasts")
        .description("Tus nuevos episodios: toca uno y suena.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}
