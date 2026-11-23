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
    var height: CGFloat = 130

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !(active || tuning))) { timeline in
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
        let ink = Color.primary.opacity(dim ? 0.25 : 0.55)

        func point(_ fraction: Double, _ distance: CGFloat) -> CGPoint {
            let angle = (-150 + 120 * fraction) * Double.pi / 180
            return CGPoint(x: center.x + distance * CGFloat(cos(angle)), y: center.y + distance * CGFloat(sin(angle)))
        }

        var arc = Path()
        for step in 0...60 {
            let p = point(Double(step) / 60, radius)
            if step == 0 { arc.move(to: p) } else { arc.addLine(to: p) }
        }
        context.stroke(arc, with: .color(ink), lineWidth: 1.2)

        for tick in 0...20 {
            let fraction = Double(tick) / 20
            let long = tick % 5 == 0
            var mark = Path()
            mark.move(to: point(fraction, radius))
            mark.addLine(to: point(fraction, radius - (long ? 14 : 8)))
            context.stroke(mark, with: .color(ink), lineWidth: long ? 1.6 : 1)
            if long {
                let label = Text(verbatim: "\(88 + tick)").font(.caption2).foregroundColor(.secondary)
                context.draw(label, at: point(fraction, radius - 27))
            }
        }

        var position = (frequency - 88) / 20
        if tuning {
            position = 0.5 + 0.45 * sin(time * 2.4)
        } else if active {
            position += 0.012 * sin(time * 3)
        } else {
            position = 0
        }
        position = min(max(position, 0), 1)
        var needle = Path()
        needle.move(to: center)
        needle.addLine(to: point(position, radius - 8))
        let color: Color = dim ? .gray : .red
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

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !speaking)) { timeline in
                    let pulse = speaking ? 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * 6) : 0
                    Circle()
                        .stroke(Color.red.opacity(speaking ? 0.35 + 0.5 * pulse : 0), lineWidth: 4 + 3 * pulse)
                        .frame(width: 62, height: 62)
                }
                avatar
                    .frame(width: 52, height: 52)
                    .clipShape(Circle())
            }
            Text(verbatim: title)
                .font(.caption)
                .fontWeight(speaking ? .semibold : .regular)
        }
    }

    @ViewBuilder private var avatar: some View {
        if let image = RadioSounds.avatar(name) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Circle().fill(Color(.systemGray4))
        }
    }
}

// MARK: - Ajustes rapidos

struct RadioQuickSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(RadioSettings.sectionsKey) private var sections = true
    @AppStorage(RadioSettings.memoryKey) private var memory = true
    @AppStorage(RadioSettings.talkEveryKey) private var talkEvery = 2
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
