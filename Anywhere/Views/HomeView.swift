//
//  HomeView.swift
//  Anywhere
//
//  Created by NodePassProject on 3/1/26.
//

import SwiftUI
import NetworkExtension

struct HomeView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(AppSettings.self) private var appSettings

    @State private var selectedPage: Page? = .launchpad
    @State private var preferredColumn = NavigationSplitViewColumn.detail

    var body: some View {
        splitView
    }
    
    @ViewBuilder
    private var splitView: some View {
        TabView(selection: $selectedPage) {
            Tab(Page.launchpad.name, image: Page.launchpad.symbol, value: Page.launchpad) {
                LaunchpadView()
            }
            
            Tab(Page.toolbox.name, systemImage: Page.toolbox.symbol, value: Page.toolbox) {
                ToolboxView()
            }
            
            TabSection("App") {
                Tab(Page.data.name, systemImage: Page.data.symbol, value: Page.data) {
                    DataView()
                }
                
                Tab(Page.personalization.name, systemImage: Page.personalization.symbol, value: Page.personalization) {
                    PersonalizationView()
                }
            }
            .tabPlacement(.sidebarOnly)
            .hidden(horizontalSizeClass == .compact)
            
            TabSection("VPN") {
                Tab(Page.tunnel.name, systemImage: Page.tunnel.symbol, value: Page.tunnel) {
                    TunnelView()
                }
                
                Tab(Page.purify.name, systemImage: Page.purify.symbol, value: Page.purify) {
                    PurifyView()
                }
                
                Tab(Page.routing.name, systemImage: Page.routing.symbol, value: Page.routing) {
                    RoutingView()
                }
                
                Tab(Page.mitm.name, systemImage: Page.mitm.symbol, value: Page.mitm) {
                    MITMView()
                }
            }
            .tabPlacement(.sidebarOnly)
            .hidden(horizontalSizeClass == .compact)
            
            TabSection("Security") {
                Tab(Page.trustedCertificates.name, systemImage: Page.trustedCertificates.symbol, value: Page.trustedCertificates) {
                    TrustedCertificatesView()
                }
                
                Tab(Page.trustedNetwork.name, systemImage: Page.trustedNetwork.symbol, value: Page.trustedNetwork) {
                    TrustedNetworkView()
                }
            }
            .tabPlacement(.sidebarOnly)
            .hidden(horizontalSizeClass == .compact)
            
            TabSection("More") {
                Tab(Page.diagnosis.name, systemImage: Page.diagnosis.symbol, value: Page.diagnosis) {
                    DiagnosisView()
                }
                
                Tab(Page.about.name, systemImage: Page.about.symbol, value: Page.about) {
                    AboutView()
                }
            }
            .tabPlacement(.sidebarOnly)
            .hidden(horizontalSizeClass == .compact)
        }
        .tabViewStyle(.sidebarAdaptable)
    }
    
    @ViewBuilder
    private var voyagerMemberCard: some View {
        VoyagerMemberCard()
            .listRowInsets(EdgeInsets())
            .listRowBackground(
                VoyagerCardBackground()
                    .clipShape(RoundedRectangle(cornerRadius: 24))
            )
            .tag(nil as Page?)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Connected") {
    let container = AppContainer.preview()
    container.selection.select(ProxyConfiguration(
        name: "🇺🇸 Los Angeles",
        serverAddress: "203.0.113.10",
        serverPort: 443,
        outbound: .socks5(SOCKS5Configuration())
    ))
    container.tunnel.setStatusForPreview(.connected)

    return HomeView()
        .environment(AppSettings())
        .environment(Operations(container: container))
        .environment(container.tunnel)
        .environment(container.selection)
        .environment(container.latency)
        .environment(container.configurationStore)
        .environment(container.chainStore)
        .environment(container.groupStore)
        .environment(container.subscriptionStore)
        .environment(ConnectionStats.previewSeeded())
        .colorScheme(.dark)
}
#endif
