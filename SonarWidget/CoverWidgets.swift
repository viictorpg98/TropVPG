//
//  CoverWidgets.swift
//  SonarWidget
//
//  Tres widgets de portadas, como el de YouTube Music: tus Selecciones rapidas, tu Acceso rapido (con el dado) y tus nuevos
//  episodios. Al tocar una portada suena esa cancion con su radio. Los datos y las portadas los deja la app en una carpeta
//  compartida (Shared/WidgetShared.swift); si el sistema no da esa carpeta al widget, enseña el motivo en vez de las portadas.
//  En CarPlay solo sale la version pequena (2x2); en la pantalla de inicio tambien la mediana (4 en fila).
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
    @Environment(\.showsWidgetContainerBackground) private var showsBackground

    private var spanish: Bool {
        Locale.preferredLanguages.first?.hasPrefix("es") ?? false
    }

    private static let plateColor = Color(red: 0.16, green: 0.16, blue: 0.18)

    // MARK: Casillas

    private func cells(for snapshot: WidgetSnapshot) -> [CoverCell] {
        let tracks = kind.tracks(in: snapshot)
        let slots = 4
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
            Image(systemName: "music.note")
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

    /// Casilla cuadrada: el contenido llena el cuadrado y se recorta con esquinas redondeadas.
    private func square<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(content())
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        .tint(.white)
    }

    @ViewBuilder
    private func cell(_ cell: CoverCell) -> some View {
        switch cell {
        case .track(let track):
            Button(intent: WidgetPlayTrackIntent(videoId: track.id, songTitle: track.title, songArtist: track.artist)) {
                square { coverImage(track) }
            }
            .tint(.white)
        case .dice:
            diceCell
        case .empty:
            square { placeholder() }
        }
    }

    // MARK: Diseño

    private func grid(_ cells: [CoverCell]) -> some View {
        Group {
            if family == .systemMedium {
                HStack(spacing: 8) {
                    ForEach(cells) { self.cell($0) }
                }
            } else {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
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
            .padding(6)
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
        .description("Portadas de tus nuevos episodios.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}
