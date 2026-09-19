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

    let isConnected: Bool

    var body: some View {
        if isConnected {
            gradient(connectedColors)
                .transition(.blurReplace)
        } else {
            gradient(disconnectedColors)
                .transition(.blurReplace)
        }
    }

    private var connectedColors: [Color] {
        if colorScheme == .light {
            [
                color(settings.connectedBackgroundLightStartData, default: .connectedBackgroundLightStart),
                color(settings.connectedBackgroundLightEndData, default: .connectedBackgroundLightEnd),
            ]
        } else {
            [
                color(settings.connectedBackgroundDarkStartData, default: .connectedBackgroundDarkStart),
                color(settings.connectedBackgroundDarkEndData, default: .connectedBackgroundDarkEnd),
            ]
        }
    }

    private var disconnectedColors: [Color] {
        if colorScheme == .light {
            [
                color(settings.disconnectedBackgroundLightStartData, default: .disconnectedBackgroundLightStart),
                color(settings.disconnectedBackgroundLightEndData, default: .disconnectedBackgroundLightEnd),
            ]
        } else {
            [
                color(settings.disconnectedBackgroundDarkStartData, default: .disconnectedBackgroundDarkStart),
                color(settings.disconnectedBackgroundDarkEndData, default: .disconnectedBackgroundDarkEnd),
            ]
        }
    }

    private func gradient(_ colors: [Color]) -> some View {
        LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    private func color(_ data: Data?, default fallback: Color) -> Color {
        data.flatMap(Color.init(archivedData:)) ?? fallback
    }
}
