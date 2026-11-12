//
//  MatchPlaylistView.swift
//  Trop
//
//  "Lista del partido": la clasificacion de canciones del equipo (se llena y se vota desde la web de Franciscans).
//  Aqui solo se lee y se reproduce.
//

import SwiftUI

struct MatchPlaylistView: View {
    @Environment(SettingsStore.self) private var settings

    @State private var rows: [MatchRow] = MatchPlaylist.ranked(MatchPlaylist.loadCache())
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var isPreparing = false
    /// `source_id` -> cancion de YouTube Music ya encontrada (durante esta sesion).
    @State private var resolved: [String: SongItem] = [:]

    private let gold = Color(red: 0.89, green: 0.71, blue: 0.35)
    private let rust = Color(red: 0.72, green: 0.27, blue: 0.20)

    var body: some View {
        Group {
            if rows.isEmpty {
                if isLoading {
                    LoadingStateView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyView
                }
            } else {
                listView
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Match Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .sonarRefreshable { await reload() }
        .task { await reload() }
    }

    // MARK: - Vacio / error

    private var emptyView: some View {
        ContentUnavailableView {
            if loadFailed {
                Label("Couldn't load the list", systemImage: "wifi.exclamationmark")
            } else {
                Label("No songs yet", systemImage: "music.note.list")
            }
        } description: {
            if loadFailed {
                Text("Check your connection and try again.")
            } else {
                Text("Add songs from the team's playlist page and they will show up here.")
            }
        } actions: {
            Button("Try Again") { Task { await reload() } }
                .buttonStyle(.borderedProminent)
                .tint(settings.accentColor)
        }
        .miniPlayerTracksScroll()
    }

    // MARK: - Clasificacion

    private var listView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                header
                ForEach(rows) { row in
                    Button { play(from: row) } label: { rowView(row) }
                        .buttonStyle(.plain)
                    Divider().padding(.leading, 56)
                }
                legend
            }
        }
        .miniPlayerTracksScroll()
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button { play(from: nil) } label: {
                    Group {
                        if isPreparing {
                            ProgressView()
                        } else {
                            Label("Play", systemImage: "play.fill")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .tint(settings.accentColor)

                Button { play(from: nil, shuffled: true) } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.bordered)
                .tint(settings.accentColor)
            }
            .disabled(isPreparing)

            Text(CountText.songs(rows.count))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func zoneColor(_ zone: MatchZone) -> Color {
        switch zone {
        case .promotion: return gold
        case .relegation: return rust
        case .none: return .clear
        }
    }

    private func rowView(_ row: MatchRow) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(zoneColor(row.zone))
                .frame(width: 4, height: 40)

            Text("\(row.position)")
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(row.zone == .promotion ? gold : .primary)
                .frame(width: 24)

            AsyncImageView(url: row.entry.artworkUrl)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(row.entry.title)
                    .font(.body)
                    .lineLimit(1)
                if !row.entry.artist.isEmpty {
                    Text(row.entry.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(pointsText(row.entry.score))
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(row.entry.score < 0 ? rust : .primary)
                .frame(minWidth: 28, alignment: .trailing)
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func pointsText(_ score: Int) -> String {
        score < 0 ? "\u{2212}\(-score)" : "\(score)"
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem(color: gold, text: "Favorites")
            legendItem(color: rust, text: "At Risk")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legendItem(color: Color, text: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 4, height: 12)
            Text(text)
        }
    }

    // MARK: - Carga

    private func reload() async {
        isLoading = true
        do {
            let entries = try await MatchPlaylist.fetch()
            rows = MatchPlaylist.ranked(entries)
            MatchPlaylist.saveCache(entries)
            loadFailed = false
        } catch is CancellationError {
            // Se salio de la pantalla a mitad de la carga: no es un fallo.
        } catch {
            loadFailed = true
        }
        isLoading = false
    }

    // MARK: - Reproduccion

    /// Reproduce la clasificacion entera: desde `startRow` (una cancion tocada) o desde el primer puesto; con `shuffled`,
    /// en orden aleatorio. Antes hay que encontrar cada cancion en YouTube Music (unos segundos).
    private func play(from startRow: MatchRow?, shuffled: Bool = false) {
        guard !isPreparing, !rows.isEmpty else { return }
        guard NetworkMonitor.shared.requireConnection() else { return }
        isPreparing = true
        let snapshot = rows
        let known = resolved
        Task {
            let missing = snapshot.map(\.entry).filter { known[$0.sourceId] == nil }
            var songs = known
            for (sourceId, song) in await MatchResolver.resolveAll(missing) { songs[sourceId] = song }
            resolved = songs

            // En el orden de la clasificacion, sin repetir y saltando las que no se han encontrado.
            var seen = Set<String>()
            var queue: [(row: MatchRow, song: SongItem)] = []
            for row in snapshot {
                guard let song = songs[row.entry.sourceId], seen.insert(song.videoId).inserted else { continue }
                queue.append((row, song))
            }
            isPreparing = false
            guard !queue.isEmpty else {
                PlaybackNotice.shared.show(NSLocalizedString("Couldn't find these songs on YouTube Music.", comment: ""))
                return
            }
            if shuffled {
                PlaybackQueue.playShuffled(queue.map { $0.song }, log: Log.libraryView, context: "Match playlist shuffle")
            } else {
                var start = 0
                if let tapped = startRow, let index = queue.firstIndex(where: { $0.row.position >= tapped.position }) {
                    start = index
                }
                PlaybackQueue.play(queue.map { $0.song }, startIndex: start, log: Log.libraryView, context: "Match playlist")
            }
        }
    }
}
