//
//  CustomizeThemeView.swift
//  Anywhere
//
//  Created by NodePassProject on 6/20/26.
//

import SwiftUI
import UIKit

struct CustomizeThemeView: View {
    @Environment(VoyagerStore.self) private var voyagerStore
    @Environment(AppSettings.self) private var settings
    @State private var screenAspectRatio: CGFloat = 393 / 852

    var body: some View {
        @Bindable var settings = settings
        Form {
            if !voyagerStore.isMember {
                VoyagerNotice(description: "Custom themes are available to Anywhere Voyager members.")
            }
            
            backgroundSection(
                "Background (Light)",
                start: $settings.homeBackgroundLightStartData, startDefault: lightDefaults.start,
                end: $settings.homeBackgroundLightEndData, endDefault: lightDefaults.end
            )
            
            backgroundSection(
                "Background (Dark)",
                start: $settings.homeBackgroundDarkStartData, startDefault: darkDefaults.start,
                end: $settings.homeBackgroundDarkEndData, endDefault: darkDefaults.end
            )
            
            previewSection("Preview", light: lightColors, dark: darkColors)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            let width = proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing
            let height = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            return height > 0 ? width / height : 393 / 852
        } action: { newValue in
            screenAspectRatio = newValue
        }
        .navigationTitle("Theme")
        .toolbar {
            ToolbarItem {
                Button(role: .destructive) {
                    reset()
                } label: {
                    Label("Reset", systemImage: "arrow.clockwise")
                }
            }
        }
    }
    
    // MARK: - Sections
    
    private func backgroundSection(
        _ header: LocalizedStringKey,
        start: Binding<Data?>, startDefault: Color,
        end: Binding<Data?>, endDefault: Color
    ) -> some View {
        Section {
            ColorPicker(
                "Top",
                selection: colorBinding(start, default: startDefault),
                supportsOpacity: false
            )
            ColorPicker(
                "Bottom",
                selection: colorBinding(end, default: endDefault),
                supportsOpacity: false
            )
        } header: {
            Text(header)
        }
        .disabled(!voyagerStore.isMember)
    }
    
    private func previewSection(_ header: LocalizedStringKey, light: [Color], dark: [Color]) -> some View {
        Section {
            HStack {
                Spacer()
                swatch(title: "Light", colors: light, colorScheme: .light)
                Spacer()
                swatch(title: "Dark", colors: dark, colorScheme: .dark)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        } header: {
            Text(header)
        }
    }
    
    // MARK: - Resolved colors
    
    private var lightColors: [Color] {
        [
            resolved(settings.homeBackgroundLightStartData, default: lightDefaults.start),
            resolved(settings.homeBackgroundLightEndData, default: lightDefaults.end),
        ]
    }
    
    private var darkColors: [Color] {
        [
            resolved(settings.homeBackgroundDarkStartData, default: darkDefaults.start),
            resolved(settings.homeBackgroundDarkEndData, default: darkDefaults.end),
        ]
    }
    
    private var lightDefaults: (start: Color, end: Color) { defaults(for: .light) }
    
    private var darkDefaults: (start: Color, end: Color) { defaults(for: .dark) }
    
    private func defaults(for style: UIUserInterfaceStyle) -> (start: Color, end: Color) {
        let traits = UITraitCollection(userInterfaceStyle: style)
        return (
            Color(uiColor: UIColor(resource: .homeBackgroundStart).resolvedColor(with: traits)),
            Color(uiColor: UIColor(resource: .homeBackgroundEnd).resolvedColor(with: traits))
        )
    }
    
    // MARK: - Reset
    
    private func reset() {
        settings.homeBackgroundLightStartData = nil
        settings.homeBackgroundLightEndData = nil
        settings.homeBackgroundDarkStartData = nil
        settings.homeBackgroundDarkEndData = nil
    }
    
    // MARK: - Helpers
    
    private func colorBinding(_ data: Binding<Data?>, default fallback: Color) -> Binding<Color> {
        Binding(
            get: { resolved(data.wrappedValue, default: fallback) },
            set: { data.wrappedValue = $0.archivedData }
        )
    }
    
    private func resolved(_ data: Data?, default fallback: Color) -> Color {
        data.flatMap(Color.init(archivedData:)) ?? fallback
    }
    
    private func swatch(title: LocalizedStringKey, colors: [Color], colorScheme: ColorScheme) -> some View {
        let maxDimension: CGFloat = 170
        let size = screenAspectRatio < 1
            ? CGSize(width: maxDimension * screenAspectRatio, height: maxDimension)
            : CGSize(width: maxDimension, height: maxDimension / screenAspectRatio)
        return VStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
                )
                .frame(width: size.width, height: size.height)
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                }
                .overlay {
                    Image(systemName: "power")
                        .font(.system(size: 28, weight: .light))
                }
                .colorScheme(colorScheme)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        CustomizeThemeView()
    }
    .environment(VoyagerStore())
    .environment(AppSettings())
}
