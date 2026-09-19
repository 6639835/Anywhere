//
//  CustomizeThemeView.swift
//  Anywhere
//
//  Created by NodePassProject on 6/20/26.
//

import SwiftUI

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
                "Background (Connected, Light)",
                start: $settings.connectedBackgroundLightStartData, startDefault: .connectedBackgroundLightStart,
                end: $settings.connectedBackgroundLightEndData, endDefault: .connectedBackgroundLightEnd
            )
            
            backgroundSection(
                "Background (Connected, Dark)",
                start: $settings.connectedBackgroundDarkStartData, startDefault: .connectedBackgroundDarkStart,
                end: $settings.connectedBackgroundDarkEndData, endDefault: .connectedBackgroundDarkEnd
            )
            
            backgroundSection(
                "Background (Disconnected, Light)",
                start: $settings.disconnectedBackgroundLightStartData, startDefault: .disconnectedBackgroundLightStart,
                end: $settings.disconnectedBackgroundLightEndData, endDefault: .disconnectedBackgroundLightEnd
            )
            
            backgroundSection(
                "Background (Disconnected, Dark)",
                start: $settings.disconnectedBackgroundDarkStartData, startDefault: .disconnectedBackgroundDarkStart,
                end: $settings.disconnectedBackgroundDarkEndData, endDefault: .disconnectedBackgroundDarkEnd
            )
            
            previewSection("Preview (Connected)", light: connectedLightColors, dark: connectedDarkColors)
            
            previewSection("Preview (Disconnected)", light: disconnectedLightColors, dark: disconnectedDarkColors)
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
    
    private var connectedLightColors: [Color] {
        [
            resolved(settings.connectedBackgroundLightStartData, default: .connectedBackgroundLightStart),
            resolved(settings.connectedBackgroundLightEndData, default: .connectedBackgroundLightEnd),
        ]
    }
    
    private var connectedDarkColors: [Color] {
        [
            resolved(settings.connectedBackgroundDarkStartData, default: .connectedBackgroundDarkStart),
            resolved(settings.connectedBackgroundDarkEndData, default: .connectedBackgroundDarkEnd),
        ]
    }
    
    private var disconnectedLightColors: [Color] {
        [
            resolved(settings.disconnectedBackgroundLightStartData, default: .disconnectedBackgroundLightStart),
            resolved(settings.disconnectedBackgroundLightEndData, default: .disconnectedBackgroundLightEnd),
        ]
    }
    
    private var disconnectedDarkColors: [Color] {
        [
            resolved(settings.disconnectedBackgroundDarkStartData, default: .disconnectedBackgroundDarkStart),
            resolved(settings.disconnectedBackgroundDarkEndData, default: .disconnectedBackgroundDarkEnd),
        ]
    }
    
    // MARK: - Customization state
    
    private var isCustomized: Bool {
        settings.connectedBackgroundLightStartData != nil
        || settings.connectedBackgroundLightEndData != nil
        || settings.connectedBackgroundDarkStartData != nil
        || settings.connectedBackgroundDarkEndData != nil
        || settings.disconnectedBackgroundLightStartData != nil
        || settings.disconnectedBackgroundLightEndData != nil
        || settings.disconnectedBackgroundDarkStartData != nil
        || settings.disconnectedBackgroundDarkEndData != nil
    }
    
    private func reset() {
        settings.connectedBackgroundLightStartData = nil
        settings.connectedBackgroundLightEndData = nil
        settings.connectedBackgroundDarkStartData = nil
        settings.connectedBackgroundDarkEndData = nil
        settings.disconnectedBackgroundLightStartData = nil
        settings.disconnectedBackgroundLightEndData = nil
        settings.disconnectedBackgroundDarkStartData = nil
        settings.disconnectedBackgroundDarkEndData = nil
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
