//
//  MixEditorView.swift
//  Trop
//
//  La pantalla "Mix" (como la de Spotify, con lo que el motor de AutoMix sabe hacer): la que suena y las siguientes de la cola,
//  con su tempo y tonalidad, y entre cada dos canciones una etiqueta ("Automatic ›") que abre el editor de esa transicion.
//
//  El editor deja elegir, para esa pareja, en modo manual: la duracion de la mezcla (corta, media o larga), como suena (con filtros o un
//  fundido simple), si se iguala el tempo y, si se quiere, donde deja la primera cancion y por donde entra la segunda. Enseña la forma
//  de onda de las dos (entera y ampliada) con el tramo que se mezcla marcado. Lo que se elige se guarda por pareja (`ManualMixStore`) y
//  manda sobre lo que decidiria AutoMix o el DJ. Los puntos se ajustan solos al compas mas cercano.
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
                    for entry in entries.prefix(13) { TrackAnalysisStore.shared.request(entry.song.videoId) }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    tick += 1
                }
            }
        }
    }
}

/// La barra que se mueve por una onda mientras suena la escucha de la mezcla. `songTime` pasa la posicion del archivo a segundos de la cancion
/// (`nil`: no se enseña). Lee la posicion dentro de su propio cuerpo, asi solo esta vista se repinta al moverse.
struct MixPlayheadLine: View {
    let songTime: (TimeInterval) -> Double?
    let windowStart: Double
    let windowEnd: Double

    var body: some View {
        // Se lee fuera del GeometryReader, para que esta vista se repinte cada vez que cambia la posicion.
        let player = MixPreviewPlayer.shared
        let time: Double? = player.state == .playing ? songTime(player.position) : nil
        GeometryReader { geometry in
            if windowEnd > windowStart, let time, time >= windowStart, time <= windowEnd {
                let x = geometry.size.width * CGFloat((time - windowStart) / (windowEnd - windowStart))
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: geometry.size.height)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .offset(x: x - 1)
            }
        }
        .allowsHitTesting(false)
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

/// Un tramo de una cancion entre dos cambios de volumen, con un nombre por su energia (el analisis no distingue estrofa de estribillo:
/// solo sabe donde cambia el volumen, donde acaba la intro y donde acaba la musica).
private struct MixBlock: Identifiable {
    let id: Int
    let startSeconds: Double
    let label: String
}

private enum MixBlocks {
    /// Los tramos de una cancion: "Intro" (o "Start"), "Quiet N" / "Loud N" segun el volumen, y "Outro" el ultimo. Vacio si no hay cambios
    /// de seccion que enseñar.
    static func make(_ structure: TrackStructure) -> [MixBlock] {
        let first = Double(structure.firstSoundMs) / 1000
        let end = Double(structure.musicEndMs) / 1000
        guard end - first > 20 else { return [] }
        // Se descartan los cambios a menos de 8 s del anterior o del final.
        var starts: [(time: Double, delta: Double)] = [(first, 0)]
        for change in structure.sections.sorted(by: { $0.timeMs < $1.timeMs }) {
            let time = Double(change.timeMs) / 1000
            if time - starts[starts.count - 1].time >= 8, end - time >= 8 { starts.append((time, change.deltaDb)) }
        }
        guard starts.count >= 2 else { return [] }
        var levels = [Double](repeating: 0, count: starts.count)
        for index in 1..<starts.count { levels[index] = levels[index - 1] + starts[index].delta }
        let middle = ((levels.max() ?? 0) + (levels.min() ?? 0)) / 2
        var quiet = 0
        var loud = 0
        var blocks: [MixBlock] = []
        for index in 0..<starts.count {
            let label: String
            if index == 0 {
                label = NSLocalizedString(structure.introEndMs != nil ? "Intro" : "Start", comment: "")
            } else if index == starts.count - 1, levels[index] < middle {
                label = NSLocalizedString("Outro", comment: "")
            } else if levels[index] >= middle {
                loud += 1
                label = NSLocalizedString("Loud", comment: "") + " \(loud)"
            } else {
                quiet += 1
                label = NSLocalizedString("Quiet", comment: "") + " \(quiet)"
            }
            blocks.append(MixBlock(id: index, startSeconds: starts[index].time, label: label))
        }
        return blocks
    }
}

struct MixTransitionEditor: View {
    let outgoing: SongItem
    let incoming: SongItem

    @State private var isManual: Bool
    @State private var length: MixStyle.Length
    @State private var matchTempo: Bool
    @State private var sound: MixSound
    /// Las curvas del editor (volumen, graves y filtro); `nil`: la mezcla de siempre con el sonido elegido.
    @State private var curves: MixCurves?
    @State private var customPoints: Bool
    /// Donde deja la saliente y por donde entra la entrante (segundos de cada cancion), si se eligen a mano.
    @State private var outSeconds: Double
    @State private var inSeconds: Double
    @State private var message: String?
    /// Sube cuando acaba un analisis, para volver a calcular la vista previa.
    @State private var refresh = 0
    /// Para escuchar la mezcla desde el editor.
    @State private var previewPlayer = MixPreviewPlayer.shared

    init(outgoing: SongItem, incoming: SongItem) {
        self.outgoing = outgoing
        self.incoming = incoming
        let saved = ManualMixStore.shared.choice(outId: outgoing.videoId, inId: incoming.videoId)
        _isManual = State(initialValue: saved != nil)
        _length = State(initialValue: saved?.length ?? .medium)
        _matchTempo = State(initialValue: saved?.matchTempo ?? true)
        _sound = State(initialValue: saved?.sound ?? .blend)
        _curves = State(initialValue: saved?.curves)
        _customPoints = State(initialValue: saved?.outStartMs != nil || saved?.inStartMs != nil)
        _outSeconds = State(initialValue: Double(saved?.outStartMs ?? 0) / 1000)
        _inSeconds = State(initialValue: Double(saved?.inStartMs ?? 0) / 1000)
    }

    // MARK: Lo elegido

    /// Lo que hay elegido ahora (`nil`: automatico).
    private var currentChoice: ManualMixStore.Choice? {
        guard isManual else { return nil }
        return ManualMixStore.Choice(
            length: length, matchTempo: matchTempo, sound: sound,
            outStartMs: customPoints && outSeconds > 0 ? Int64(outSeconds * 1000) : nil,
            inStartMs: customPoints ? Int64(max(inSeconds, 0) * 1000) : nil,
            curves: curves
        )
    }

    private func save() {
        message = MixTransition.apply(currentChoice, outId: outgoing.videoId, inId: incoming.videoId)
    }

    private var manualBinding: Binding<Bool> {
        Binding(get: { isManual }, set: { on in
            isManual = on
            if !on { customPoints = false }
            save()
        })
    }

    private var lengthBinding: Binding<MixStyle.Length> {
        Binding(get: { length }, set: { length = $0; save() })
    }

    private var soundBinding: Binding<MixSound> {
        Binding(get: { sound }, set: { sound = $0; save() })
    }

    /// Prepara y reproduce la mezcla con lo elegido ahora (o la para si ya suena).
    private func togglePreview() {
        if previewPlayer.state != .idle {
            previewPlayer.stop()
            return
        }
        guard let plan = makePreview()?.plan else { return }
        previewPlayer.start(outgoingId: outgoing.videoId, incomingId: incoming.videoId, plan: plan)
    }

    private var curvesOnBinding: Binding<Bool> {
        Binding(get: { curves != nil }, set: { on in
            curves = on ? MixCurves.standard : nil
            save()
        })
    }

    /// Para el editor de curvas (que siempre trabaja con unas curvas).
    private var curvesEditingBinding: Binding<MixCurves> {
        Binding(get: { curves ?? MixCurves.standard }, set: { curves = $0 })
    }

    private func presetBinding(_ lane: MixLane) -> Binding<String> {
        Binding(get: { curves?.lane(lane).preset ?? lane.presets[0] }, set: { name in
            guard name != "custom" else { return }
            curves?.set(lane, MixLaneCurves.make(lane, name))
            save()
        })
    }

    private func laneTitle(_ lane: MixLane) -> String {
        switch lane {
        case .volume: return "Volume"
        case .bass: return "Bass"
        case .filter: return "Filter"
        case .effect: return "Effects"
        }
    }

    private var loopBinding: Binding<Int> {
        Binding(get: { curves?.loopBars ?? 0 }, set: { value in
            curves?.loopBars = value
            save()
        })
    }

    private var tempoBinding: Binding<Bool> {
        Binding(get: { matchTempo }, set: { matchTempo = $0; save() })
    }

    private func customPointsBinding(seed plan: TransitionPlan?) -> Binding<Bool> {
        Binding(get: { customPoints }, set: { on in
            customPoints = on
            if on, let plan {
                // Se parte de lo que haria el automatico, para que nada salte.
                outSeconds = Double(plan.outgoingStartMs) / 1000
                inSeconds = Double(plan.incomingStartMs) / 1000
            }
            save()
        })
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
        /// Entre que segundos se pueden poner a mano la salida y la entrada (`nil`: no hay margen).
        let outRange: ClosedRange<Double>?
        let inRange: ClosedRange<Double>?
        /// Los tramos de cada cancion (por sus cambios de volumen).
        let outBlocks: [MixBlock]
        let inBlocks: [MixBlock]
    }

    /// Lo que haria el motor con esta pareja y lo elegido ahora: la misma funcion que usa AutoMix (`MixTransition.planInputs`), asi lo que
    /// se ve es lo que suena. No toca su plan guardado. `nil` si alguna de las dos aun no esta analizada.
    private func makePreview() -> Preview? {
        _ = refresh
        let store = TrackAnalysisStore.shared
        guard let out = store.structure(for: outgoing.videoId, role: .outgoing),
              let inc = store.structure(for: incoming.videoId, role: .incoming) else { return nil }
        let np = NowPlaying.shared
        let isNext = np.queueSongs.indices.contains(np.queueIndex) && np.queueIndex + 1 < np.queueSongs.count
            && np.queueSongs[np.queueIndex].videoId == outgoing.videoId && np.queueSongs[np.queueIndex + 1].videoId == incoming.videoId
        let inputs = MixTransition.planInputs(
            outId: outgoing.videoId, inId: incoming.videoId, outgoing: out, incoming: inc,
            currentTime: isNext ? np.currentTime : 0, choice: currentChoice
        )
        let vocals = TransitionPlanner.Vocals(
            outgoing: VocalMaskStore.shared.segments(for: outgoing.videoId),
            incoming: VocalMaskStore.shared.segments(for: incoming.videoId)
        )
        let maxEarly = SettingsStore.shared.autoMixTiming.maxEarlyMs
        var result = TransitionPlanner.plan(
            outgoing: out, incoming: inc, vocals: vocals, forcedStartMs: inputs.forcedStartMs, style: inputs.style,
            maxEarlyMs: maxEarly, forcedIncomingMs: inputs.forcedIncomingMs
        )
        if result == nil, inputs.forcedStartMs != nil {
            result = TransitionPlanner.plan(
                outgoing: out, incoming: inc, vocals: vocals, style: inputs.style, maxEarlyMs: maxEarly,
                forcedIncomingMs: inputs.forcedIncomingMs
            )
        }
        // La forma de onda es la de la cancion entera (las canciones largas no la tienen aqui).
        let outWhole = store.structure(for: outgoing.videoId)
        let incWhole = store.structure(for: incoming.videoId)
        // Si ya se leyo la onda con detalle (unas 1.500 barras), se usa esa; si no, la de 160 barras.
        let outDetailed = DetailedWaveformStore.shared.entry(for: outgoing.videoId)
        let incDetailed = DetailedWaveformStore.shared.entry(for: incoming.videoId)

        let outLow = max(Double(out.firstSoundMs) / 1000 + 15, 20)
        let outHigh = Double(out.musicEndMs) / 1000 - 8
        let inHigh = min(max(Double(inc.musicEndMs) / 1000 - 30, 0), 150)
        return Preview(
            plan: result?.plan,
            outgoingWave: outDetailed?.wave ?? outWhole?.waveform,
            incomingWave: incDetailed?.wave ?? incWhole?.waveform,
            outgoingSeconds: outDetailed?.seconds ?? store.knownDuration(outgoing.videoId) ?? Double(out.lastSoundMs) / 1000,
            incomingSeconds: incDetailed?.seconds ?? store.knownDuration(incoming.videoId) ?? Double(inc.lastSoundMs) / 1000,
            outgoingBpm: out.bpm,
            incomingBpm: inc.bpm,
            tempoMatters: inputs.style.context == "near",
            outRange: outHigh > outLow ? outLow...outHigh : nil,
            inRange: inHigh > 1 ? 0...inHigh : nil,
            outBlocks: MixBlocks.make(out),
            inBlocks: MixBlocks.make(inc)
        )
    }

    var body: some View {
        let preview = makePreview()
        VStack(spacing: 0) {
            // La vista previa siempre a la vista, mientras se tocan los ajustes de debajo.
            pinnedPreview(preview)
            Divider()
            List {
                Section {
                    MixPairHeader(song: outgoing, role: "From")
                    MixPairHeader(song: incoming, role: "To")
                }

                Section {
                    Picker("Mode", selection: manualBinding) {
                        Text("Automatic").tag(false)
                        Text("Manual").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } header: {
                    Text("Transition")
                } footer: {
                    Text("Automatic lets AutoMix (or the DJ) decide. In Manual, what you choose here is used every time these two songs play one after the other.")
                }

                if isManual {
                    manualControls(preview)
                }

                if let preview, let plan = preview.plan {
                    detailsSection(preview, plan: plan)
                }

                if let message {
                    Section {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Transition")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { previewPlayer.stop() }
        .task {
            // La onda con detalle de las dos (una lectura por cancion; despues sale de la memoria).
            await DetailedWaveformStore.shared.load(outgoing.videoId)
            await DetailedWaveformStore.shared.load(incoming.videoId)
            refresh += 1
        }
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

    // MARK: Controles manuales

    @ViewBuilder
    private func manualControls(_ preview: Preview?) -> some View {
        Section {
            Picker("Length", selection: lengthBinding) {
                Text("Short").tag(MixStyle.Length.short)
                Text("Medium").tag(MixStyle.Length.medium)
                Text("Long").tag(MixStyle.Length.long)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Length")
        } footer: {
            Text("How long the two songs overlap. The mix always starts and ends on the beat.")
        }

        if curves == nil {
            Section {
                Picker("Sound", selection: soundBinding) {
                    Text("Blend").tag(MixSound.blend)
                    Text("Fade").tag(MixSound.fade)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Sound")
            } footer: {
                Text("Blend closes and opens filters and swaps the bass between the songs. Fade is a plain cross-fade.")
            }
        }

        Section {
            Toggle("Custom Curves", isOn: curvesOnBinding)
                .disabled(preview == nil)
            if curves != nil {
                ForEach(MixLane.allCases, id: \.self) { lane in
                    Picker(LocalizedStringKey(laneTitle(lane)), selection: presetBinding(lane)) {
                        ForEach(lane.presets, id: \.self) { name in
                            Text(LocalizedStringKey(lane.title(for: name))).tag(name)
                        }
                        if curves?.lane(lane).preset == "custom" {
                            Text("Custom").tag("custom")
                        }
                    }
                }
                Picker("Looping", selection: loopBinding) {
                    Text("None").tag(0)
                    Text("1 Bar").tag(1)
                    Text("2 Bars").tag(2)
                    Text("4 Bars").tag(4)
                }
                if let preview, let plan = preview.plan {
                    NavigationLink {
                        MixCurveEditorView(
                            curves: curvesEditingBinding,
                            outgoingWave: preview.outgoingWave, outgoingSeconds: preview.outgoingSeconds,
                            outgoingStart: Double(plan.outgoingStartMs) / 1000, outgoingEnd: Double(plan.outgoingEndMs) / 1000,
                            incomingWave: preview.incomingWave, incomingSeconds: preview.incomingSeconds,
                            incomingStart: Double(plan.incomingStartMs) / 1000,
                            incomingEnd: Double(plan.incomingStartMs
                                + AutoMixMath.incomingAdvanceMs(durationMs: plan.durationMs, startRatio: plan.incomingSpeedRatio)) / 1000,
                            onCommit: { save() },
                            onPreview: { togglePreview() }
                        )
                    } label: {
                        Text("Edit Curves")
                    }
                }
            }
        } header: {
            Text("Curves")
        } footer: {
            Text("Shape the volume, the bass and the filter of each song during the mix. The presets are starting points; move the points to make your own. With custom curves, the Sound choice is not used. Looping repeats the start of the song that is leaving and is ignored when the tempo match stretches it. Effects only act during the mix and fade out before it ends.")
        }

        Section {
            Toggle("Match Tempo", isOn: tempoBinding)
                .disabled(!(preview?.tempoMatters ?? true))
        } footer: {
            Text("Off keeps each song at its own tempo. It only applies when both songs have a similar tempo.")
        }

        Section {
            Toggle("Choose the Points", isOn: customPointsBinding(seed: preview?.plan))
                .disabled(preview == nil)
            if customPoints, let preview, let plan = preview.plan {
                if let range = preview.outRange {
                    pointSlider(
                        title: "Leaves the first song at", shown: Double(plan.outgoingStartMs) / 1000,
                        value: $outSeconds, range: range
                    )
                    blockChips(preview.outBlocks.filter { $0.startSeconds >= range.lowerBound && $0.startSeconds <= range.upperBound }) {
                        outSeconds = $0
                        save()
                    }
                }
                if let range = preview.inRange {
                    pointSlider(
                        title: "Next song enters at", shown: Double(plan.incomingStartMs) / 1000,
                        value: $inSeconds, range: range
                    )
                    blockChips(preview.inBlocks.filter { $0.startSeconds <= range.upperBound }) {
                        inSeconds = $0
                        save()
                    }
                }
            }
        } footer: {
            Text("Move the points, or tap a part of the song, to choose where the first song is left and where the next one comes in. They snap to the nearest beat. Parts are named by their volume: the analysis cannot tell a verse from a chorus.")
        }
    }

    private func pointSlider(title: String, shown: Double, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(LocalizedStringKey(title))
                Spacer()
                Text(DurationFormat.playbackTime(shown))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // Se guarda al soltar (cada cambio rehace la mezcla preparada).
            Slider(value: value, in: range, onEditingChanged: { editing in
                if !editing { save() }
            })
        }
    }

    /// Los tramos de una cancion como botones: tocar uno lleva el punto a su principio.
    @ViewBuilder
    private func blockChips(_ blocks: [MixBlock], pick: @escaping (Double) -> Void) -> some View {
        if blocks.count >= 2 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(blocks) { block in
                        Button {
                            pick(block.startSeconds)
                        } label: {
                            Text("\(block.label) \(DurationFormat.playbackTime(block.startSeconds))")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: Forma de onda y datos

    /// Las ondas de las dos canciones (enteras y ampliadas) con la mezcla marcada, siempre arriba, y una linea con lo que pasa.
    @ViewBuilder
    private func pinnedPreview(_ preview: Preview?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let preview, let plan = preview.plan {
                let outStart = Double(plan.outgoingStartMs) / 1000
                let outEnd = Double(plan.outgoingEndMs) / 1000
                let inStart = Double(plan.incomingStartMs) / 1000
                let inEnd = Double(plan.incomingStartMs
                    + AutoMixMath.incomingAdvanceMs(durationMs: plan.durationMs, startRatio: plan.incomingSpeedRatio)) / 1000
                if let wave = preview.outgoingWave {
                    MixWaveformStrip(
                        wave: wave, totalSeconds: preview.outgoingSeconds, windowStart: 0, windowEnd: preview.outgoingSeconds,
                        startSeconds: outStart, endSeconds: outEnd, tint: .orange, height: 20,
                        markers: preview.outBlocks.map(\.startSeconds)
                    )
                    .overlay {
                        MixPlayheadLine(
                            songTime: { MixPreviewPlayer.shared.outgoingSongTime($0, cutAt: outStart) },
                            windowStart: 0, windowEnd: preview.outgoingSeconds
                        )
                    }
                    MixWaveformStrip(
                        wave: wave, totalSeconds: preview.outgoingSeconds,
                        windowStart: max(outStart - 20, 0), windowEnd: min(outEnd + 8, preview.outgoingSeconds),
                        startSeconds: outStart, endSeconds: outEnd, tint: .orange, height: 46
                    )
                    .overlay {
                        MixPlayheadLine(
                            songTime: { MixPreviewPlayer.shared.outgoingSongTime($0, cutAt: outStart) },
                            windowStart: max(outStart - 20, 0), windowEnd: min(outEnd + 8, preview.outgoingSeconds)
                        )
                    }
                }
                if let wave = preview.incomingWave {
                    MixWaveformStrip(
                        wave: wave, totalSeconds: preview.incomingSeconds, windowStart: 0, windowEnd: preview.incomingSeconds,
                        startSeconds: inStart, endSeconds: inEnd, tint: .blue, height: 20,
                        markers: preview.inBlocks.map(\.startSeconds)
                    )
                    .overlay {
                        MixPlayheadLine(
                            songTime: { MixPreviewPlayer.shared.incomingSongTime($0, inStart: inStart) },
                            windowStart: 0, windowEnd: preview.incomingSeconds
                        )
                    }
                    MixWaveformStrip(
                        wave: wave, totalSeconds: preview.incomingSeconds,
                        windowStart: max(inStart - 3, 0), windowEnd: min(inEnd + 22, preview.incomingSeconds),
                        startSeconds: inStart, endSeconds: inEnd, tint: .blue, height: 46
                    )
                    .overlay {
                        MixPlayheadLine(
                            songTime: { MixPreviewPlayer.shared.incomingSongTime($0, inStart: inStart) },
                            windowStart: max(inStart - 3, 0), windowEnd: min(inEnd + 22, preview.incomingSeconds)
                        )
                    }
                }
                HStack(spacing: 8) {
                    Text(String(
                        format: NSLocalizedString("Leaves at %@ · %d s overlap · enters at %@", comment: ""),
                        DurationFormat.playbackTime(outStart), Int((Double(plan.durationMs) / 1000).rounded()),
                        DurationFormat.playbackTime(inStart)
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button {
                        togglePreview()
                    } label: {
                        HStack(spacing: 5) {
                            if previewPlayer.state == .preparing {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: previewPlayer.state == .playing ? "stop.fill" : "play.fill")
                            }
                            Text(LocalizedStringKey(
                                previewPlayer.state == .playing ? "Stop Preview"
                                    : (previewPlayer.state == .preparing ? "Preparing the preview…" : "Preview Mix")
                            ))
                        }
                        .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(previewPlayer.state == .preparing)
                }
                if let status = previewPlayer.statusText {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if preview != nil {
                Text("No mix is possible between these two songs, so the normal transition will be used.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("These songs are still being analyzed. The preview appears when they are ready.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func detailsSection(_ preview: Preview, plan: TransitionPlan) -> some View {
        Section {
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

/// La forma de onda de una cancion con el tramo de la mezcla resaltado. Dibuja solo la ventana pedida (entera, o ampliada alrededor de
/// la mezcla). `markers`: segundos donde empieza cada tramo de la cancion (lineas finas).
struct MixWaveformStrip: View {
    let wave: [Float]
    let totalSeconds: Double
    let windowStart: Double
    let windowEnd: Double
    let startSeconds: Double
    let endSeconds: Double
    let tint: Color
    let height: CGFloat
    var markers: [Double] = []

    var body: some View {
        Canvas { context, size in
            let count = wave.count
            let span = windowEnd - windowStart
            guard count > 1, totalSeconds > 0, span > 0 else { return }
            func x(_ seconds: Double) -> CGFloat {
                size.width * CGFloat(min(max((seconds - windowStart) / span, 0), 1))
            }
            let from = x(startSeconds)
            let to = x(endSeconds)
            context.fill(
                Path(roundedRect: CGRect(x: from, y: 0, width: max(to - from, 3), height: size.height), cornerRadius: 4),
                with: .color(tint.opacity(0.2))
            )
            // Cada barra de la forma de onda cubre `totalSeconds / count` segundos de la cancion.
            let barSeconds = totalSeconds / Double(count)
            let first = max(Int((windowStart / barSeconds).rounded(.down)), 0)
            let last = min(Int((windowEnd / barSeconds).rounded(.up)), count - 1)
            guard first <= last else { return }
            let rawWidth = size.width * CGFloat(barSeconds / span)
            // Si caben varias barras en un pixel (la onda con detalle vista entera), se dibuja una por grupo, con el valor mas alto del grupo.
            let step = max(1, Int((1 / max(rawWidth, 0.0001)).rounded(.up)))
            let barWidth = max(rawWidth * CGFloat(step), 1)
            for index in stride(from: first, through: last, by: step) {
                let middleSeconds = (Double(index) + Double(step) / 2) * barSeconds
                let centerX = x(middleSeconds)
                var peak: Float = 0
                for k in index..<min(index + step, last + 1) { peak = max(peak, wave[k]) }
                let barHeight = max(3, CGFloat(min(max(peak, 0), 1)) * size.height)
                let rect = CGRect(
                    x: centerX - barWidth * 0.35, y: (size.height - barHeight) / 2, width: barWidth * 0.7, height: barHeight
                )
                let inside = middleSeconds >= startSeconds && middleSeconds <= endSeconds
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth * 0.3),
                    with: .color(inside ? tint : Color.secondary.opacity(0.45))
                )
            }
            for marker in markers where marker > windowStart && marker < windowEnd {
                let markerX = x(marker)
                context.fill(Path(CGRect(x: markerX - 0.5, y: 0, width: 1, height: size.height)), with: .color(Color.primary.opacity(0.35)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
