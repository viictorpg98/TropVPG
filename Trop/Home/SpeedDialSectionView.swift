//
//  SpeedDialSectionView.swift
//  Trop
//

import SwiftUI

/// "Acceso rápido": cuadrícula de 3×3 que se desliza por páginas (hasta 27 elementos)
/// y un botón de dado que elige algo al azar.
struct SpeedDialSectionView: View {
    @Environment(SettingsStore.self) private var settings

    let items: [YTItem]
    let onTap: (YTItem) -> Void
    let onDice: () -> Void

    @State private var page: Int? = 0

    private let perPage = 9
    private let gridSpacing: CGFloat = 10

    private var pages: [[YTItem]] {
        stride(from: 0, to: items.count, by: perPage).map { start in
            Array(items[start ..< min(start + perPage, items.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 0) {
                    ForEach(pages.indices, id: \.self) { index in
                        pageGrid(pages[index])
                            .containerRelativeFrame(.horizontal)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)

            if pages.count > 1 {
                pageDots
            }
        }
        .padding(.top, 8)
    }

    private var header: some View {
        HStack {
            Text("Speed Dial")
                .font(.title3)
                .fontWeight(.bold)
                .lineLimit(1)

            Spacer()

            Button(action: onDice) {
                Image(systemName: "dice.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(settings.accentColor)
                    .frame(width: 44, height: 32)
                    .background(Capsule().fill(Color(.secondarySystemFill)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Surprise me"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(pages.indices, id: \.self) { index in
                Circle()
                    .fill(index == (page ?? 0) ? Color.primary : Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    private func pageGrid(_ pageItems: [YTItem]) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: 3),
            alignment: .leading,
            spacing: gridSpacing
        ) {
            ForEach(pageItems.indices, id: \.self) { index in
                cell(pageItems[index])
            }
        }
        .padding(.horizontal, 16)
    }

    private func cell(_ item: YTItem) -> some View {
        Button {
            onTap(item)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                AsyncImageView(url: item.thumbnailUrl)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: isArtist(item) ? 200 : 8))

                Text(item.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private func isArtist(_ item: YTItem) -> Bool {
        if case .artist = item { return true }
        return false
    }
}
