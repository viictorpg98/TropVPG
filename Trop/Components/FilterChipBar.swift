//
//  FilterChipBar.swift
//  Trop
//
//  Created by 686udjie on 18/08/2026.
//

import SwiftUI

/// Horizontal scrollable row of capsule filter chips.
/// Replaces the duplicated chip rows in Home, Library and Search.
struct FilterChipBar<Item, ID: Hashable>: View {
    @Environment(SettingsStore.self) private var settings
    let items: [Item]
    let id: KeyPath<Item, ID>
    let title: (Item) -> String
    let isSelected: (Item) -> Bool
    let onTap: (Item) -> Void
    /// Una pildora propia al principio de la fila (la del DJ en el Inicio).
    var leading: AnyView? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let leading { leading }
                ForEach(items, id: id) { item in
                    Button {
                        onTap(item)
                    } label: {
                        Text(LocalizedStringKey(title(item)))
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(isSelected(item)
                                        ? settings.accentColor
                                        : Color(.systemGray5))
                            )
                            .foregroundColor(isSelected(item)
                                ? settings.accentOnColor
                                : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}
