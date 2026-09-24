//
//  PageView.swift
//  Anywhere
//
//  Created by NodePassProject on 9/21/26.
//

import SwiftUI

struct PageView<Content: View>: View {
    @Binding var selection: Int
    @ViewBuilder let content: Content

    @State private var progress: CGFloat = 0

    var body: some View {
        Group(subviews: content) { subviews in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(subviews.indices, id: \.self) { index in
                        subviews[index]
                            .containerRelativeFrame(.horizontal)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: scrolledPage)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                guard geometry.bounds.width > 0 else { return 0 }
                let lastPage = CGFloat(max(subviews.count - 1, 0))
                return min(max(geometry.bounds.minX / geometry.bounds.width, 0), lastPage)
            } action: { _, newValue in
                progress = newValue
            }
            .safeAreaInset(edge: .bottom) {
                PageIndicator(
                    items: subviews.map(\.containerValues.pageIndicator),
                    progress: progress,
                    selection: $selection
                )
                .padding(.bottom)
            }
        }
    }

    private var scrolledPage: Binding<Int?> {
        Binding {
            selection
        } set: { page in
            if let page {
                selection = page
            }
        }
    }
}

struct PageIndicatorItem {
    let symbol: String
    let label: LocalizedStringKey
}

extension ContainerValues {
    @Entry var pageIndicator: PageIndicatorItem? = nil
}

extension View {
    func pageIndicator(symbol: String, label: LocalizedStringKey) -> some View {
        containerValue(\.pageIndicator, PageIndicatorItem(symbol: symbol, label: label))
    }
}

private struct PageIndicator: View {
    private static let selectedOpacity: CGFloat = 1
    private static let unselectedOpacity: CGFloat = 0.4

    let items: [PageIndicatorItem?]
    let progress: CGFloat
    @Binding var selection: Int

    var body: some View {
        if #available(iOS 27.0, *) {
            indicators
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            indicators
        }
    }
    
    @ViewBuilder
    private var indicators: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                Button {
                    withAnimation(.snappy) {
                        selection = index
                    }
                } label: {
                    Image(systemName: items[index]?.symbol ?? "circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary.opacity(opacity(for: index)))
                        .frame(minWidth: 40, minHeight: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(items[index]?.label ?? "")
                .accessibilityAddTraits(selection == index ? .isSelected : [])
            }
        }
    }

    private func opacity(for index: Int) -> CGFloat {
        let distance = min(1, abs(progress - CGFloat(index)))
        return Self.selectedOpacity - (Self.selectedOpacity - Self.unselectedOpacity) * distance
    }
}
