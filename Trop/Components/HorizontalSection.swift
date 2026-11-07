//
//  HorizontalSection.swift
//  Trop
//
//  Created by 686udjie on 2/07/2026.
//

import SwiftUI

/// Titled horizontal-scroll section shared by the Home and Explore tabs:
/// a `NavigationTitleView` header over horizontally scrolling content with
/// standard edge padding.
struct HorizontalSection<Content: View>: View {
    let title: String
    var vSpacing: CGFloat = 0
    var contentVerticalPadding: CGFloat = 4
    /// Si es true, al deslizar se ajusta a cada columna (la rejilla debe usar `.scrollTargetLayout()`).
    var snapsToColumns: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: vSpacing) {
            NavigationTitleView(title: title)
            if snapsToColumns {
                scroller.scrollTargetBehavior(.viewAligned)
            } else {
                scroller
            }
        }
    }

    private var scroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content()
                .padding(.horizontal, DesignTokens.screenHPadding)
                .padding(.vertical, contentVerticalPadding)
        }
    }
}
