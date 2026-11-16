//
//  MixEditorView.swift
//  Trop
//
//  La pantalla "Mix" (como la de Spotify, con lo que el motor de AutoMix sabe hacer): la que suena y las siguientes de la cola,
//  con su tempo y tonalidad, y entre cada dos canciones una etiqueta ("Automatic ›") que abre el editor de esa transicion.
//
//  El editor deja elegir, para esa pareja, la duracion de la mezcla (corta, media o larga) y si se iguala el tempo. Enseña la forma
//  de onda de las dos canciones con el tramo que se mezclaria marcado. Lo que se elige se guarda por pareja (`ManualMixStore`) y
//  manda sobre lo que decidiria AutoMix. El motor no cambia: los puntos de corte y de entrada los sigue calculando el, a compases.
//

import SwiftUI

// MARK: - Lista de la cola con las transiciones

struct MixEditorView: View {
    @Environment(\.dismiss) private var dismiss
    private let np = NowPlaying.shared
    @State private var notice = PlaybackNotice.shared
    @State private var tick = 0
    @State private var isSorting = false

    private struct Entry: Identifiable {
        let index: Int
        let song: SongItem
        var id: Int { index }
    }

    /// La que suena y hasta 30 siguientes.
    private var entries: [Entry] {
        guard np.queueSongs.indices.contains(np.queueIndex) else { return [] }
        let end = min(np.queueSongs.count, np.queueIndex + 31)
        return (np.queueIndex..<end).map { Entry(index: $0, song: np.queueSongs[$0]) }
    }

    var body: some View {
        NavigationStack {
            let items = entries
            List {
                if items.count < 2 {
                    Text("Add more songs to the queue to edit the mixes between them.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(items.enumerated()), id: \.element.id) { position, entry in
                        MixSongRow(song: entry.song, isCurrent: position == 0, tick: tick)
                        if position + 1 < items.count {
                            let next = items[position + 1]
                            NavigationLink {
                                MixTransitionEditor(outgoing: entry.song, incoming: next.song)
                            } label: {
                                MixChip(outgoing: entry.song, incoming: next.song, tick: tick)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Mix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        guard !isSorting else { return }
                        isSorting = true
                        Task {
                            await QueueSmartOrder.sortAndAnnounce()
                            isSorting = false
                            tick += 1
                        }
                    } label: {
                        if isSorting {
                            ProgressView()
                        } else {
                            Label("Sort by BPM & Key", systemImage: "arrow.up.arrow.down")
                        }
                    }
                    .disabled(items.count < 3)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                // El aviso normal queda tapado por esta hoja: aqui se enseña dentro.
                if let message = notice.message {
                    Text(message)
                        .font(.footnote.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: notice.message)
            .onAppear { tick += 1 }
            .task {
                // Se piden analizar las siguientes y se refresca de vez en cuando para que vayan saliendo sus etiquetas.
                while !Task.isCancelled {
                    for entry in entries.prefix(26) { TrackAnalysisStore.shared.request(entry.song.videoId) }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    tick += 1
                }
            }
        }
    }
}

/// Una cancion de la lista: portada, titulo, artista y duracion; a la derecha, tempo y tonalidad.
private struct MixSongRow: View {
    let song: SongItem
    let isCurrent: Bool
    /// Solo sirve para que la fila se vuelva a pintar cuando acaba un analisis.
    let tick: Int

    var body: some View {
        HStack(spacing: 12) {
            AsyncImageView(url: AudioCounterpartStore.shared.thumbnailURL(for: song))
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if isCurrent {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.45))
                            Image(systemName: "waveform")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.subheadline.weight(isCurrent ? .semibold : .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let badge = MusicBadge.make(for: song.videoId) {
                badge.fixedSize()
            }
        }
    }

    private var subtitle: String {
        let artists = song.artists.map(\.name).joined(separator: ", ")
        guard song.duration > 0 else { return artists }
        return (artists.isEmpty ? "" : artists + " · ") + DurationFormat.playbackTime(TimeInterval(song.duration))
    }
}

/// La etiqueta entre dos canciones: lo elegido para esa mezcla ("Automatic" si no se ha tocado) y una flecha.
private struct MixChip: View {
    let outgoing: SongItem
    let incoming: SongItem
    let tick: Int

    var body: some View {
        let choice = ManualMixStore.shared.choice(outId: outgoing.videoId, inId: incoming.videoId)
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 13, weight: .semibold))
            Text(MixTransition.title(for: choice))
                .font(.footnote.weight(.semibold))
            if let choice, !choice.matchTempo {
                Text("Keep Both Tempos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(choice == nil ? Color.secondary : Color.accentColor)
        .padding(.leading, 56)
    }
}

// MARK: - Editor de una transicion

struct MixTransitionEditor: View {
    let outgoing: SongItem
    let incoming: SongItem

    @State private var length: MixStyle.Length?
    @State private var matchTempo: Bool
    @State private var message: String?
    /// Sube cuando acaba un analisis, para volver a calcular la vista previa.
    @State private var refresh = 0

    init(outgoing: SongItem, incoming: SongItem) {
        self.outgoing = outgoing
        self.incoming = incoming
        let saved = ManualMixStore.shared.choice(outId: outgoing.videoId, inId: incoming.videoId)
        _length = State(initialValue: saved?.length)
        _matchTempo = State(initialValue: saved?.matchTempo ?? true)
    }

    private var lengthBinding: Binding<MixStyle.Length?> {
        Binding(get: { length }, set: { length = $0; save() })
    }

    private var tempoBinding: Binding<Bool> {
        Binding(get: { matchTempo }, set: { matchTempo = $0; save() })
    }

    private func save() {
        let choice = length.map { ManualMixStore.Choice(length: $0, matchTempo: matchTempo) }
        message = MixTransition.apply(choice, outId: outgoing.videoId, inId: incoming.videoId)
    }

    // MARK: Vista previa

    private struct Preview {
        let plan: TransitionPlan?
        let outgoingWave: [Float]?
        let incomingWave: [Float]?
        let outgoingSeconds: Double
        let incomingSeconds: Double
        let outgoingBpm: Double
        let incomingBpm: Double
        /// Tempos parecidos: solo entonces tiene sentido elegir si se iguala el tempo.
        let tempoMatters: Bool
    }

    /// Lo que haria el motor con esta pareja y lo elegido ahora (misma funcion que usa AutoMix; no toca su plan guardado).
    /// `nil` si alguna de las dos aun no esta analizada.
    private func makePreview() -> Preview? {
        _ = refresh
        let store = TrackAnalysisStore.shared
        guard let out = store.structure(for: outgoing.videoId, role: .outgoing),
              let inc = store.structure(for: incoming.videoId, role: .incoming) else { return nil }
        let context = MixLearning.context(outgoingBpm: out.bpm, incomingBpm: inc.bpm)
        let style: MixStyle
        if let length {
            style = MixStyle(length: length, matchTempo: context == "near" ? matchTempo : true, context: context)
        } else {
            style = MixLearning.shared.style(
                outId: outgoing.videoId, inId: incoming.videoId, outBpm: out.bpm, inBpm: inc.bpm
            )
        }
        let vocals = TransitionPlanner.Vocals(
            outgoing: VocalMaskStore.shared.segments(for: outgoing.videoId),
            incoming: VocalMaskStore.shared.segments(for: incoming.videoId)
        )
        let result = TransitionPlanner.plan(
            outgoing: out, incoming: inc, vocals: vocals, style: style,
            maxEarlyMs: SettingsStore.shared.autoMixTiming.maxEarlyMs
        )
        // La forma de onda es la de la cancion entera (las canciones largas no la tienen aqui).
        let outWhole = store.structure(for: outgoing.videoId)
        let incWhole = store.structure(for: incoming.videoId)
        return Preview(
            plan: result?.plan,
            outgoingWave: outWhole?.waveform,
            incomingWave: incWhole?.waveform,
            outgoingSeconds: store.knownDuration(outgoing.videoId) ?? Double(out.lastSoundMs) / 1000,
            incomingSeconds: store.knownDuration(incoming.videoId) ?? Double(inc.lastSoundMs) / 1000,
            outgoingBpm: out.bpm,
            incomingBpm: inc.bpm,
            tempoMatters: context == "near"
        )
    }

    var body: some View {
        let preview = makePreview()
        List {
            Section {
                MixPairHeader(song: outgoing, role: "From")
                MixPairHeader(song: incoming, role: "To")
            }

            if let preview {
                previewSection(preview)
            } else {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("These songs are still being analyzed. The preview appears when they are ready.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Picker("Transition", selection: lengthBinding) {
                    Text("Automatic").tag(MixStyle.Length?.none)
                    Text("Short Blend").tag(MixStyle.Length?.some(.short))
                    Text("Medium Blend").tag(MixStyle.Length?.some(.medium))
                    Text("Long Blend").tag(MixStyle.Length?.some(.long))
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Transition")
            } footer: {
                Text("Automatic lets AutoMix decide. The mix always starts and ends on the beat; the length changes how long the two songs overlap.")
            }

            Section {
                Toggle("Match Tempo", isOn: tempoBinding)
                    .disabled(length == nil || !(preview?.tempoMatters ?? true))
            } footer: {
                Text("Off keeps each song at its own tempo. It only applies when both songs have a similar tempo.")
            }

            if let message {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Transition")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Si alguna aun no esta analizada, se pide y se vuelve a mirar hasta que este.
            while !Task.isCancelled {
                TrackAnalysisStore.shared.request(outgoing.videoId, role: .outgoing)
                TrackAnalysisStore.shared.request(incoming.videoId, role: .incoming)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                refresh += 1
                if TrackAnalysisStore.shared.structure(for: outgoing.videoId, role: .outgoing) != nil,
                   TrackAnalysisStore.shared.structure(for: incoming.videoId, role: .incoming) != nil { break }
            }
        }
    }

    @ViewBuilder
    private func previewSection(_ preview: Preview) -> some View {
        Section {
            if let plan = preview.plan {
                let mixEnd = Double(plan.outgoingEndMs) / 1000
                let inEnd = Double(plan.incomingStartMs
                    + AutoMixMath.incomingAdvanceMs(durationMs: plan.durationMs, startRatio: plan.incomingSpeedRatio)) / 1000
                VStack(alignment: .leading, spacing: 10) {
                    if let wave = preview.outgoingWave {
                        MixWaveformStrip(
                            wave: wave, totalSeconds: preview.outgoingSeconds,
                            startSeconds: Double(plan.outgoingStartMs) / 1000, endSeconds: mixEnd, tint: .orange
                        )
                    }
                    if let wave = preview.incomingWave {
                        MixWaveformStrip(
                            wave: wave, totalSeconds: preview.incomingSeconds,
                            startSeconds: Double(plan.incomingStartMs) / 1000, endSeconds: inEnd, tint: .blue
                        )
                    }
                }
                .padding(.vertical, 4)

                LabeledContent("Mix starts at") {
                    Text(DurationFormat.playbackTime(Double(plan.outgoingStartMs) / 1000))
                }
                LabeledContent("Overlap") {
                    Text(String(format: NSLocalizedString("%d s", comment: ""), Int((Double(plan.durationMs) / 1000).rounded())))
                }
                LabeledContent("Next song enters at") {
                    Text(DurationFormat.playbackTime(Double(plan.incomingStartMs) / 1000))
                }
                LabeledContent("Tempo") {
                    Text("\(Int(preview.outgoingBpm.rounded())) → \(Int(preview.incomingBpm.rounded())) BPM")
                }
            } else {
                Text("No mix is possible between these two songs, so the normal transition will be used.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Preview")
        }
    }
}

/// "De / A" con la canción, su portada y su etiqueta de tempo y tonalidad.
private struct MixPairHeader: View {
    let song: SongItem
    let role: String

    var body: some View {
        HStack(spacing: 12) {
            AsyncImageView(url: AudioCounterpartStore.shared.thumbnailURL(for: song))
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(role))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(song.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(song.artists.map(\.name).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let badge = MusicBadge.make(for: song.videoId) {
                badge.fixedSize()
            }
        }
    }
}

/// La forma de onda de una cancion con el tramo de la mezcla resaltado.
private struct MixWaveformStrip: View {
    let wave: [Float]
    let totalSeconds: Double
    let startSeconds: Double
    let endSeconds: Double
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let count = wave.count
            guard count > 0, totalSeconds > 0 else { return }
            let barWidth = size.width / CGFloat(count)
            let from = size.width * CGFloat(min(max(startSeconds / totalSeconds, 0), 1))
            let to = size.width * CGFloat(min(max(endSeconds / totalSeconds, 0), 1))
            let region = CGRect(x: from, y: 0, width: max(to - from, 3), height: size.height)
            context.fill(Path(roundedRect: region, cornerRadius: 4), with: .color(tint.opacity(0.2)))
            for index in 0..<count {
                let height = max(3, CGFloat(min(max(wave[index], 0), 1)) * size.height)
                let x = CGFloat(index) * barWidth
                let rect = CGRect(x: x + barWidth * 0.15, y: (size.height - height) / 2, width: barWidth * 0.7, height: height)
                let middle = x + barWidth / 2
                let inside = middle >= from && middle <= to
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth * 0.35),
                    with: .color(inside ? tint : Color.secondary.opacity(0.45))
                )
            }
        }
        .frame(height: 48)
        .accessibilityHidden(true)
    }
}
