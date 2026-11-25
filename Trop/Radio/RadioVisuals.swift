//
//  RadioVisuals.swift
//  Trop
//
//  Las piezas graficas de la pestaña Radio: el dial con su aguja (barre el arco al sintonizar y oscila un poco en el aire), el disco de vinilo con la portada, el
//  ecualizador, los locutores (ilustraciones inventadas, con un anillo que late cuando hablan) y la hoja de ajustes rapidos.
//

import SwiftUI

// MARK: - Dial

struct RadioDialView: View {
    let frequency: Double
    let active: Bool
    let tuning: Bool
    /// Alguien habla: la aguja tiembla un poco. Sin esto (y sin sintonizar) el dial es una imagen fija y no gasta bateria.
    var alive = false
    var ink: Color = .primary
    var needle: Color = .red
    var height: CGFloat = 130

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !(tuning || alive))) { timeline in
            Canvas { context, size in
                draw(context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(height: height)
    }

    private func draw(_ context: GraphicsContext, size: CGSize, time: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height - 10)
        let radius = min(size.width / 2 - 14, size.height - 26)
        let dim = !(active || tuning)
        let tint = ink.opacity(dim ? 0.3 : 0.8)

        func point(_ fraction: Double, _ distance: CGFloat) -> CGPoint {
            let angle = (-150 + 120 * fraction) * Double.pi / 180
            return CGPoint(x: center.x + distance * CGFloat(cos(angle)), y: center.y + distance * CGFloat(sin(angle)))
        }

        var arc = Path()
        for step in 0...60 {
            let p = point(Double(step) / 60, radius)
            if step == 0 { arc.move(to: p) } else { arc.addLine(to: p) }
        }
        context.stroke(arc, with: .color(tint), lineWidth: 1.2)

        for tick in 0...20 {
            let fraction = Double(tick) / 20
            let long = tick % 5 == 0
            var mark = Path()
            mark.move(to: point(fraction, radius))
            mark.addLine(to: point(fraction, radius - (long ? 14 : 8)))
            context.stroke(mark, with: .color(tint), lineWidth: long ? 1.6 : 1)
            if long {
                let label = Text(verbatim: "\(88 + tick)").font(.caption2).foregroundColor(ink.opacity(0.75))
                context.draw(label, at: point(fraction, radius - 27))
            }
        }

        var position = (frequency - 88) / 20
        if tuning {
            position = 0.5 + 0.45 * sin(time * 2.4)
        } else if alive {
            position += 0.012 * sin(time * 3)
        } else if !active {
            position = 0
        }
        position = min(max(position, 0), 1)
        var needle = Path()
        needle.move(to: center)
        needle.addLine(to: point(position, radius - 8))
        let color: Color = dim ? ink.opacity(0.35) : needle
        context.stroke(needle, with: .color(color), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        context.fill(Path(ellipseIn: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)), with: .color(color))
    }
}

// MARK: - Disco

struct RadioDiscView: View {
    let cover: UIImage?
    let spinning: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !spinning)) { timeline in
            let angle = spinning ? (timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 5) / 5) * 360 : 0
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                ZStack {
                    Circle().fill(Color.black.opacity(0.9))
                    ForEach(0..<5, id: \.self) { ring in
                        Circle().stroke(Color.white.opacity(0.07), lineWidth: 1).padding(CGFloat(6 + ring * 7))
                    }
                    coverImage
                        .frame(width: side * 0.42, height: side * 0.42)
                        .clipShape(Circle())
                    Circle().fill(Color(.systemBackground)).frame(width: side * 0.06, height: side * 0.06)
                }
                .frame(width: side, height: side)
                .rotationEffect(.degrees(angle))
            }
        }
    }

    @ViewBuilder private var coverImage: some View {
        if let cover {
            Image(uiImage: cover).resizable().scaledToFill()
        } else {
            Color.orange
        }
    }
}

// MARK: - Ecualizador

struct RadioEqualizerView: View {
    var active = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !active)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<7, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.red)
                        .frame(width: 5, height: 8 + 22 * CGFloat(abs(sin(time * 3 + Double(index) * 0.9))))
                }
            }
            .frame(height: 30, alignment: .bottom)
        }
    }
}

// MARK: - Locutores

struct RadioHostView: View {
    let name: String
    let title: String
    let speaking: Bool
    var size: CGFloat = 52
    /// `true` cuando habla el otro: este se apaga un poco para que se note quien tiene la palabra.
    var dimmed = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !speaking)) { timeline in
                    let pulse = speaking ? 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * 6) : 0
                    Circle()
                        .stroke(Color.red.opacity(speaking ? 0.35 + 0.5 * pulse : 0), lineWidth: 4 + 3 * pulse)
                        .frame(width: size + 10, height: size + 10)
                }
                avatar
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            }
            .scaleEffect(speaking ? 1.04 : 1)
            Text(verbatim: title)
                .font(size > 60 ? .subheadline : .caption)
                .fontWeight(speaking ? .semibold : .regular)
        }
        .opacity(dimmed ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.25), value: speaking)
        .animation(.easeInOut(duration: 0.25), value: dimmed)
    }

    @ViewBuilder private var avatar: some View {
        if let image = RadioSounds.avatar(name) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Circle().fill(Color(.systemGray4))
        }
    }
}

// MARK: - Ventanas de estudio

/// Un locutor en su ventana de estudio (arco arriba): el que habla se enciende con aro ambar y medidor; el otro se atenua. La placa lleva su nombre.
struct RadioStudioWindow: View {
    let name: String
    let title: String
    let speaking: Bool
    let dimmed: Bool
    let animated: Bool

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 56, bottomLeadingRadius: 10, bottomTrailingRadius: 10, topTrailingRadius: 56, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 8) {
            window
            Text(verbatim: title)
                .font(.system(.caption2, design: .rounded).weight(.heavy))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(RadioPalette.ink)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(RadioPalette.cream))
        }
        .opacity(dimmed ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.25), value: speaking)
        .animation(.easeInOut(duration: 0.25), value: dimmed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: speaking ? title + ", " + NSLocalizedString("speaking", comment: "") : title))
    }

    private var window: some View {
        ZStack(alignment: .bottomTrailing) {
            avatar
                .frame(width: 112, height: 134)
                .clipShape(shape)
            shape
                .strokeBorder(speaking ? RadioPalette.amber : RadioPalette.line, lineWidth: 3)
                .frame(width: 112, height: 134)
            if speaking {
                RadioVUBars(animated: animated)
                    .padding(8)
            }
        }
        .frame(width: 112, height: 134)
        .shadow(color: speaking ? RadioPalette.amber.opacity(0.4) : .clear, radius: 14, y: 4)
    }

    @ViewBuilder private var avatar: some View {
        if let image = RadioSounds.avatar(name) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Rectangle().fill(RadioPalette.line)
        }
    }
}

/// El medidor de nivel de quien habla (4 barras); solo se dibuja mientras habla.
struct RadioVUBars: View {
    let animated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: !animated)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(RadioPalette.amber)
                        .frame(width: 3, height: animated ? 5 + 10 * CGFloat(abs(sin(time * 7 + Double(index) * 1.1))) : 9)
                }
            }
            .frame(height: 15, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Secciones una a una

/// Un interruptor por seccion (en los ajustes de Radio): las apagadas no salen.
struct RadioSectionToggles: View {
    @AppStorage(RadioSettings.sectionsOffKey) private var off = ""

    var body: some View {
        ForEach(RadioSectionKind.allCases, id: \.self) { kind in
            Toggle(isOn: Binding(
                get: { !RadioSettings.disabledSections(from: off).contains(kind.name) },
                set: { isOn in
                    var names = RadioSettings.disabledSections(from: off)
                    if isOn { names.remove(kind.name) } else { names.insert(kind.name) }
                    off = names.sorted().joined(separator: ",")
                }
            )) {
                Label(LocalizedStringKey(kind.displayKey), systemImage: kind.icon)
            }
            .padding(.leading, 12)
        }
    }
}

// MARK: - Ajustes rapidos

struct RadioQuickSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(RadioSettings.sectionsKey) private var sections = true
    @AppStorage(RadioSettings.memoryKey) private var memory = true
    @AppStorage(RadioSettings.talkEveryKey) private var talkEvery = 2
    @AppStorage(RadioSettings.rhythmKey) private var rhythm = 0
    @AppStorage(RadioSettings.humorKey) private var humor = 1
    @AppStorage(RadioSettings.cityKey) private var city = "Sabadell"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Sections", isOn: $sections)
                    Picker("Talk", selection: $talkEvery) {
                        ForEach(1...5, id: \.self) { count in
                            Text(count == 1
                                 ? NSLocalizedString("Every song", comment: "")
                                 : String(format: NSLocalizedString("Every %d songs", comment: ""), count))
                                .tag(count)
                        }
                    }
                    Picker("Regularity", selection: $rhythm) {
                        Text("Exact").tag(0)
                        Text("Natural").tag(1)
                        Text("Unpredictable").tag(2)
                    }
                    Picker("Humor", selection: $humor) {
                        Text("Mild").tag(0)
                        Text("Spicy").tag(1)
                        Text("Dark Humor").tag(2)
                    }
                    Toggle("Radio Remembers", isOn: $memory)
                    Picker("City for the Weather", selection: $city) {
                        ForEach(RadioSettings.cities, id: \.name) { place in
                            Text(verbatim: place.name).tag(place.name)
                        }
                    }
                } header: {
                    Text("Quick Settings")
                }

                Section {
                    Text(String(format: NSLocalizedString("Voice requests today: %d", comment: ""), RadioSettings.voiceRequestsToday))
                        .foregroundStyle(.secondary)
                    Text(spendText)
                        .foregroundStyle(.secondary)
                    SettingsNavigationRow("All Radio Settings", icon: "dot.radiowaves.left.and.right") {
                        RadioSettingsView()
                    }
                }
            }
            .sonarSettingsList()
            .navigationTitle("Radio Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var spendText: String {
        let cap = RadioSettings.dailyCap
        let spent = String(format: "%.3f €", RadioSettings.spentToday)
        let limit = cap > 0 ? String(format: "%.2f €", cap) : NSLocalizedString("No limit", comment: "")
        return String(format: NSLocalizedString("Estimated spend today: %@", comment: ""), spent + " / " + limit)
    }
}
