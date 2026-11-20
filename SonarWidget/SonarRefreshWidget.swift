//
//  SonarRefreshWidget.swift
//  SonarWidget
//
//  Widget pequeno "Sonar · Actualizar": un solo boton grande para cambiar a mano las portadas de los demas widgets (Selecciones rapidas y Acceso
//  rapido). Es el mismo `WidgetRefreshIntent` que tenia el widget de botones (Shared/WidgetIntents.swift); lo ejecuta la app. Esta aparte para que
//  en CarPlay (que admite 5 widgets) el widget de botones pueda tener el microfono.
//

import AppIntents
import SwiftUI
import WidgetKit

struct SonarRefreshEntry: TimelineEntry {
    let date: Date
}

struct SonarRefreshProvider: TimelineProvider {
    func placeholder(in context: Context) -> SonarRefreshEntry {
        SonarRefreshEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (SonarRefreshEntry) -> Void) {
        completion(SonarRefreshEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SonarRefreshEntry>) -> Void) {
        // Se relee cada hora: con "nunca", algunos widgets interactivos dejaban de responder tras horas parados.
        completion(Timeline(entries: [SonarRefreshEntry(date: Date())], policy: .after(Date().addingTimeInterval(3600))))
    }
}

struct SonarRefreshView: View {
    @Environment(\.showsWidgetContainerBackground) private var showsBackground

    private var spanish: Bool {
        Locale.preferredLanguages.first?.hasPrefix("es") ?? false
    }

    private static let plateColor = Color(red: 0.16, green: 0.16, blue: 0.18)
    private static let iconInk = Color(red: 0.08, green: 0.08, blue: 0.09)

    var body: some View {
        VStack(spacing: 2) {
            Button(intent: WidgetRefreshIntent()) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color(red: 1.00, green: 0.69, blue: 0.30), Color(red: 1.00, green: 0.48, blue: 0.27)],
                            startPoint: .top, endPoint: .bottom
                        ))
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Self.iconInk)
                }
                .frame(width: 66, height: 66)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .tint(.clear)
            // El nombre va fuera del boton: asi no se encoge con el.
            Text(spanish ? "Actualizar" : "Refresh")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Sin fondo del widget (CarPlay): una placa oscura opaca detras para que se vea sobre cualquier tema del coche.
        .background(showsBackground ? Color.clear : Self.plateColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(4)
        .containerBackground(Color.black, for: .widget)
    }
}

struct SonarRefreshWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SonarRefresh", provider: SonarRefreshProvider()) { _ in
            SonarRefreshView()
        }
        .configurationDisplayName("Sonar · Actualizar")
        .description("Un botón grande para cambiar las portadas de los demás widgets.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}
