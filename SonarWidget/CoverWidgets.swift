//
//  CoverWidgets.swift
//  SonarWidget
//
//  Tres widgets de portadas: Selecciones rapidas (dos, A y B, de 4 portadas cada uno) y Acceso rapido (4 portadas). Al tocar una
//  portada suena esa cancion con su radio. Los datos y las portadas los deja la app en una carpeta compartida
//  (Shared/WidgetShared.swift); si el sistema no da esa carpeta al widget, enseña el motivo en vez de las portadas.
//  En CarPlay solo sale la version pequena; en la pantalla de inicio tambien la mediana.
//
//  Cada lista es una RESERVA de unas 16 canciones; el widget enseña un grupo de 4 y pasa al siguiente cada media hora (el grupo sale
//  de la hora del reloj, no de un contador: A y B nunca enseñan el mismo grupo y no hace falta abrir la app). El boton "Actualizar" del
//  widget de botones baraja la reserva y recarga estos widgets.
//
//  Al tocar, la portada se encoge como los botones redondos del widget de botones (mismo estilo del sistema, con tinte transparente).
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

/// Cuanto dura cada grupo de portadas en pantalla.
private let coverRotationSeconds: TimeInterval = 1800

struct CoverProvider: TimelineProvider {
    func placeholder(in context: Context) -> CoverEntry {
        CoverEntry(date: Date(), state: .noData(groupId: "", appWrote: true))
    }

    func getSnapshot(in context: Context, completion: @escaping (CoverEntry) -> Void) {
        completion(CoverEntry(date: Date(), state: WidgetShared.state()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CoverEntry>) -> Void) {
        // Una entrada por cada media hora de las proximas 4 horas: cada una enseña su grupo de portadas aunque la app este cerrada. La app
        // ademas avisa cuando escribe datos nuevos.
        let state = WidgetShared.state()
        let now = Date()
        let slotStart = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / coverRotationSeconds).rounded(.down) * coverRotationSeconds)
        var entries = [CoverEntry(date: now, state: state)]
        for step in 1...8 {
            entries.append(CoverEntry(date: slotStart.addingTimeInterval(Double(step) * coverRotationSeconds), state: state))
        }
        completion(Timeline(entries: entries, policy: .after(entries.last?.date ?? now.addingTimeInterval(3600))))
    }
}

/// Que lista ensena cada widget.
enum CoverKind {
    case quickPicksA
    case quickPicksB
    case speedDial

    func tracks(in snapshot: WidgetSnapshot) -> [WidgetTrack] {
        switch self {
        case .quickPicksA, .quickPicksB: return snapshot.quickPicks
        case .speedDial: return snapshot.speedDial
        }
    }

    /// Las 4 canciones que toca ensenar a esa hora. La reserva se parte en grupos de 4; el grupo sale de la hora del reloj (cambia cada
    /// media hora). El segundo widget de Selecciones rapidas va con medio ciclo de diferencia para no repetir el grupo del primero.
    /// Si el ultimo grupo queda corto, se completa con las primeras de la lista.
    func visibleTracks(in snapshot: WidgetSnapshot, at date: Date) -> [WidgetTrack] {
        let all = tracks(in: snapshot)
        guard all.count > 4 else { return all }
        let groups = (all.count + 3) / 4
        let slot = Int((date.timeIntervalSince1970 / coverRotationSeconds).rounded(.down))
        let offset = self == .quickPicksB ? groups / 2 : 0
        let group = (((slot + offset) % groups) + groups) % groups
        return (0..<4).map { all[(group * 4 + $0) % all.count] }
    }

    var emptyMessageEs: String {
        switch self {
        case .quickPicksA, .quickPicksB: return "Abre Sonar para cargar tus Selecciones rápidas"
        case .speedDial: return "Fija canciones en tu Acceso rápido desde Sonar"
        }
    }

    var emptyMessageEn: String {
        switch self {
        case .quickPicksA, .quickPicksB: return "Open Sonar to load your Quick Picks"
        case .speedDial: return "Pin songs to your Speed Dial in Sonar"
        }
    }
}

private enum CoverCell: Identifiable {
    case track(WidgetTrack)
    case empty(Int)

    var id: String {
        switch self {
        case .track(let track): return "t-" + track.id
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
    /// Esquinas concentricas con las del widget (unos 24 pt) menos el margen.
    private static let cornerRadius: CGFloat = 14
    /// Poco hueco entre portadas y poco margen: el boton del sistema (el que da el efecto al pulsar) ya añade su propio espacio alrededor.
    private static let gap: CGFloat = 2
    private static let margin: CGFloat = 5

    // MARK: Casillas

    private func cells(for snapshot: WidgetSnapshot) -> [CoverCell] {
        var result: [CoverCell] = kind.visibleTracks(in: snapshot, at: entry.date).map { .track($0) }
        var filler = 0
        while result.count < 4 {
            result.append(.empty(filler))
            filler += 1
        }
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

    /// Franja oscura con el titulo abajo (se degrada hacia arriba para que no haya un corte seco).
    private func titleScrim(_ title: String, lines: Int, size: CGFloat) -> some View {
        Text(title)
            .font(.system(size: size, weight: .semibold, design: .rounded))
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
    /// tamaño de la casilla: asi la imagen (que llena y se sale) no agranda la capa del titulo. `contentShape` hace que TODA la casilla
    /// sea tocable: el hueco transparente de la base no lo era y a veces el toque no hacia nada segun la zona.
    private func coverTile(_ track: WidgetTrack) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { coverImage(track) }
            .overlay(alignment: .bottom) { titleScrim(track.title, lines: 2, size: 9) }
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
    }

    private func square<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(content())
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
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
        // El estilo `.bordered` con tinte transparente da el efecto de pulsar del sistema (se encoge) sin pintar ningun aro; el mismo
        // que el de los botones redondos del widget de botones.
        Button(intent: intent) {
            coverTile(track)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: Self.cornerRadius))
        .controlSize(.mini)
        .tint(.clear)
    }

    @ViewBuilder
    private func cell(_ cell: CoverCell) -> some View {
        switch cell {
        case .track(let track):
            trackCell(track)
        case .empty:
            square { placeholder() }
        }
    }

    // MARK: Diseño

    private func grid(_ cells: [CoverCell]) -> some View {
        Group {
            if family == .systemMedium {
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
            if kind.tracks(in: snapshot).isEmpty {
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
            CoverWidgetView(entry: entry, kind: .quickPicksA)
        }
        .configurationDisplayName("Sonar · Selecciones rápidas")
        .description("Portadas de tus Selecciones rápidas: toca una y suena. Cambian solas cada media hora.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

/// El segundo widget de Selecciones rapidas: otras 4 portadas distintas a las del primero.
struct SonarQuickPicksBWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SonarQuickPicksB", provider: CoverProvider()) { entry in
            CoverWidgetView(entry: entry, kind: .quickPicksB)
        }
        .configurationDisplayName("Sonar · Selecciones rápidas 2")
        .description("Otras portadas de tus Selecciones rápidas, distintas a las del primer widget.")
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
        .description("Portadas de tu Acceso rápido: toca una y suena. Cambian solas cada media hora.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}
