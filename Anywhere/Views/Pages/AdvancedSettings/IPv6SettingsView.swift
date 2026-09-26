//
//  IPv6SettingsView.swift
//  Anywhere
//
//  Created by NodePassProject on 9/26/26.
//

import SwiftUI

struct IPv6SettingsView: View {
    @Environment(AppSettings.self) private var settings
    
    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("IPv6 Proxies", isOn: .constant(true))
                    .disabled(true)
            } footer: {
                Text("You can connect to your proxies via IPv6 if your network supports IPv6.")
            }
            Section {
                Toggle("Local IPv6 Requests", isOn: $settings.localIPv6RequestsEnabled)
            } footer: {
                Text("May cause connection issues if your network does not support IPv6.")
            }
            Section {
                Toggle("Remote IPv6 Requests", isOn: .constant(true))
                    .disabled(true)
            } footer: {
                Text("Adjust this setting on your proxy server.")
            }
        }
        .navigationTitle("IPv6")
    }
}
