//
//  BackgroundGradient.swift
//  Anywhere
//
//  Created by NodePassProject on 8/21/26.
//

import SwiftUI

struct BackgroundGradient: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppSettings.self) private var settings

    var body: some View {
        LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    private var colors: [Color] {
        if colorScheme == .light {
            [
                color(settings.homeBackgroundLightStartData, default: .homeBackgroundStart),
                color(settings.homeBackgroundLightEndData, default: .homeBackgroundEnd),
            ]
        } else {
            [
                color(settings.homeBackgroundDarkStartData, default: .homeBackgroundStart),
                color(settings.homeBackgroundDarkEndData, default: .homeBackgroundEnd),
            ]
        }
    }

    private func color(_ data: Data?, default fallback: Color) -> Color {
        data.flatMap(Color.init(archivedData:)) ?? fallback
    }
}
