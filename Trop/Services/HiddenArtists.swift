//
//  HiddenArtists.swift
//  Trop
//
//  Artistas que no quieres oir: dejan de salir en Inicio, en las radios y en la cola (siguen saliendo si los buscas, apagados
//  y marcados). Todo es local: no se manda nada a tu cuenta de YouTube.
//

import Foundation
import SwiftUI

struct HiddenArtist: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var browseId: String?
}

final class HiddenArtists: @unchecked Sendable {
    static let shared = HiddenArtists()

    private static let key = "hiddenArtists.v1"
    private let lock = NSLock()
    private var artists: [HiddenArtist]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([HiddenArtist].self, from: data) {
            artists = saved
        } else {
            artists = []
        }
    }

    var all: [HiddenArtist] {
        lock.lock()
        defer { lock.unlock() }
        return artists
    }

    static func normalize(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    func isHidden(browseId: String?, name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if artists.isEmpty { return false }
        let normalized = Self.normalize(name)
        return artists.contains { entry in
            if let id = browseId, let entryId = entry.browseId, id == entryId { return true }
            return !normalized.isEmpty && Self.normalize(entry.name) == normalized
        }
    }

    func isHidden(_ artist: YTArtist) -> Bool {
        isHidden(browseId: artist.id, name: artist.name)
    }

    /// Una cancion se oculta si cualquiera de sus artistas esta oculto (tambien las colaboraciones).
    func isHidden(_ song: SongItem) -> Bool {
        song.artists.contains { isHidden($0) }
    }

    func blocks(_ item: YTItem) -> Bool {
        switch item {
        case .song(let song): return isHidden(song)
        case .artist(let artist): return isHidden(browseId: artist.browseId, name: artist.name)
        case .album(let album): return album.artists.contains { isHidden($0) }
        case .episode(let episode): return episode.artists.contains { isHidden($0) }
        default: return false
        }
    }

    func filter(_ songs: [SongItem]) -> [SongItem] {
        songs.filter { !isHidden($0) }
    }

    func hide(_ artist: YTArtist) {
        let name = artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isHidden(artist) else { return }
        lock.lock()
        artists.append(HiddenArtist(id: artist.id ?? "name:" + Self.normalize(name), name: name, browseId: artist.id))
        let snapshot = artists
        lock.unlock()
        persist(snapshot)
    }

    func unhide(_ artist: HiddenArtist) {
        lock.lock()
        artists.removeAll { $0.id == artist.id }
        let snapshot = artists
        lock.unlock()
        persist(snapshot)
    }

    private func persist(_ snapshot: [HiddenArtist]) {
        if let data = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// Lo que pasa al ocultar un artista: se avisa, se quita de lo que viene en la cola y, si suena una suya, se pasa a la siguiente.
@MainActor
enum HiddenArtistActions {
    static func hide(_ artist: YTArtist) {
        HiddenArtists.shared.hide(artist)
        PlaybackNotice.shared.show(String(format: NSLocalizedString("%@ is hidden.", comment: ""), artist.name))
        let np = NowPlaying.shared
        guard np.queueSongs.indices.contains(np.queueIndex) else { return }
        let head = Array(np.queueSongs.prefix(np.queueIndex + 1))
        let tail = HiddenArtists.shared.filter(Array(np.queueSongs.dropFirst(np.queueIndex + 1)))
        if head.count + tail.count != np.queueSongs.count {
            np.queueSongs = head + tail
            np.persistQueueState()
        }
        if HiddenArtists.shared.isHidden(np.queueSongs[np.queueIndex]), np.hasNext {
            np.playNext()
        }
    }
}

extension View {
    /// "¿Dejar de oir a este artista?": pregunta (con un boton por cada artista de la cancion) antes de ocultarlo.
    func hideArtistDialog(for song: SongItem, isPresented: Binding<Bool>) -> some View {
        confirmationDialog("Stop hearing this artist?", isPresented: isPresented, titleVisibility: .visible) {
            ForEach(song.artists.filter { !$0.name.isEmpty }, id: \.self) { artist in
                Button(String(format: NSLocalizedString("Hide %@", comment: ""), artist.name), role: .destructive) {
                    HiddenArtistActions.hide(artist)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won't see their songs on Home or in radios. You can undo it in Settings.")
        }
    }
}
