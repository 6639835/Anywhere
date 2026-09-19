//
//  LaunchpadView.swift
//  Anywhere
//
//  Created by NodePassProject on 8/21/26.
//

import SwiftUI
import NetworkExtension

struct LaunchpadView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(Operations.self) private var operations
    @Environment(TunnelController.self) private var tunnelController
    @Environment(ProxySelection.self) private var proxySelection
    @Environment(LatencyCenter.self) private var latencyCenter
    @Environment(ConfigurationStore.self) private var configurationStore
    @Environment(ChainStore.self) private var chainStore
    @Environment(GroupStore.self) private var groupStore
    @Environment(SubscriptionStore.self) private var subscriptionStore
    @Environment(ConnectionStats.self) private var connectionStats

    @State private var connectionEffectsEnabled = false

    @State private var showingProxiesView = false
    @State private var showingAddSheet = false
    @State private var showingManualAddSheet = false

    private var isLoading: Bool { !configurationStore.isLoaded }

    private var isConnected: Bool {
        tunnelController.rawStatus == .connected
    }

    private var isTransitioning: Bool { tunnelController.rawStatus.isTransitioning }

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundGradient(isConnected: isConnected)
                    .ignoresSafeArea()
                
                TabView {
                    Tab {
                        VStack(spacing: 0) {
                            VStack(spacing: 20) {
                                PowerButton(
                                    isConnected: isConnected,
                                    isTransitioning: isTransitioning,
                                    isLoading: isLoading,
                                    isDisabled: isLoading
                                    || ((!tunnelController.isManagerReady || isTransitioning)
                                        && configurationStore.hasConfigurations),
                                    animatesChanges: connectionEffectsEnabled
                                ) {
                                    guard !isLoading else { return }
                                    if configurationStore.hasConfigurations {
                                        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                                            operations.tunnel.toggle()
                                        }
                                    } else {
                                        showingAddSheet = true
                                    }
                                }
                                
                                Text(tunnelController.status.localizedText)
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                            }
                            .layoutPriority(1)
                            
                            Rectangle()
                                .fill(.clear)
                                .frame(idealHeight: 80, maxHeight: 80)
                            
                            ConfigurationCapsule(
                                isConnected: isConnected,
                                showingProxiesPage: $showingProxiesView,
                                showingAddSheet: $showingAddSheet
                            )
                            .frame(maxWidth: 500)
                            .layoutPriority(1)
                        }
                        .padding()
                        .animation(connectionEffectsEnabled ? Animation.bouncy : nil, value: isConnected)
                    }
                    Tab {
                        MissionControlView()
                    }
                }
                .tabViewStyle(.page)
                .ignoresSafeArea(edges: [.bottom])
                .sensoryFeedback(trigger: isConnected) { _, _ in
                    guard connectionEffectsEnabled else { return nil }
                    return .impact
                }
            }
            .navigationTitle("Launchpad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if #available(iOS 27.0, *) {
                    ToolbarOverflowMenu {
                        Button {
                            Task { await connectionStats.resetStats() }
                        } label: {
                            Label("Reset Stats", systemImage: "0.circle")
                        }
                        .disabled(!isConnected)
                    }
                } else {
                    ToolbarItem {
                        Menu("More", systemImage: "ellipsis") {
                            Button {
                                Task { await connectionStats.resetStats() }
                            } label: {
                                Label("Reset Stats", systemImage: "0.circle")
                            }
                            .disabled(!isConnected)
                        }
                    }
                }
            }
            .sheet(isPresented: $showingProxiesView) {
                ProxiesView()
                    .presentationDetents([.medium, .large])
                    .environment(operations)
                    .environment(proxySelection)
                    .environment(latencyCenter)
                    .environment(configurationStore)
                    .environment(chainStore)
                    .environment(groupStore)
                    .environment(subscriptionStore)
            }
            .sheet(isPresented: $showingAddSheet) {
                DynamicSheet(animation: .snappy(duration: 0.3, extraBounce: 0)) {
                    AddProxyView(showingManualAddSheet: $showingManualAddSheet)
                        .environment(operations)
                }
            }
            .sheet(isPresented: $showingManualAddSheet) {
                ProxyEditorView { configuration in
                    operations.configurations.add(configuration); operations.selection.selectIfNone(configuration)
                }
            }
            .alert("VPN Error", isPresented: Binding(
                get: { tunnelController.startError != nil },
                set: { if !$0 { tunnelController.startError = nil } }
            )) {
                Button("OK") { tunnelController.startError = nil }
            } message: {
                Text(tunnelController.startError ?? "")
            }
            .onChange(of: tunnelController.isManagerReady, initial: true) { _, ready in
                guard ready, !connectionEffectsEnabled else { return }
                Task { @MainActor in connectionEffectsEnabled = true }
            }
        }
    }
}

// MARK: - Power Button

private struct PowerButton: View {
    private static let circleDiameter: CGFloat = 140

    let isConnected: Bool
    let isTransitioning: Bool
    let isLoading: Bool
    let isDisabled: Bool
    let animatesChanges: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if #available(iOS 27.0, *) {
                    Circle()
                        .fill(.clear)
                        .frame(width: Self.circleDiameter)
                        .glassEffect(.regular, in: .circle)
                } else if #available(iOS 26.0, *) {
                    Circle()
                        .fill(.clear)
                        .frame(width: Self.circleDiameter)
                        .glassEffect(.clear, in: .circle)
                } else {
                    Circle()
                        .fill(.white.opacity(0.2))
                        .frame(width: Self.circleDiameter)
                        .shadow(color: isConnected ? .cyan.opacity(0.4) : .black.opacity(0.08), radius: isConnected ? 24 : 8)
                }
                if isTransitioning || isLoading {
                    ProgressView()
                        .controlSize(.large)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 40, weight: .light))
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .animation(animatesChanges ? Animation.easeInOut(duration: 0.6) : nil, value: isConnected)
    }
}

// MARK: - Configuration Capsule

private struct ConfigurationCapsule: View {
    @Environment(ProxySelection.self) private var selection
    @Environment(ConfigurationStore.self) private var configurationStore

    let isConnected: Bool
    @Binding var showingProxiesPage: Bool
    @Binding var showingAddSheet: Bool

    var body: some View {
        if let configuration = selection.selectedConfiguration {
            selectedCapsule(configuration)
        } else if configurationStore.isLoaded {
            emptyCapsule
        } else {
            loadingCapsule
        }
    }

    private func selectedCapsule(_ configuration: ProxyConfiguration) -> some View {
        Button {
            showingProxiesPage = true
        } label: {
            ProminentCapsule {
                HStack {
                    HStack {
                        Image("anywhere")
                            .font(.body.weight(.medium))
                        Text(configuration.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary.opacity(0.7))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var emptyCapsule: some View {
        Button {
            showingAddSheet = true
        } label: {
            ProminentCapsule {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    Text("Add a Configuration")
                        .font(.body.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var loadingCapsule: some View {
        ProminentCapsule {
            HStack(spacing: 12) {
                ProgressView()
                Text("Loading…")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

private struct ProminentCapsule<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(iOS 27.0, *) {
            content
                .padding(16)
                .contentShape(Capsule())
                .glassEffect(.regular.interactive(), in: .capsule)
        } else if #available(iOS 26.0, *) {
            content
                .padding(16)
                .contentShape(Capsule())
                .glassEffect(.clear.interactive(), in: .capsule)
        } else {
            content
                .padding(16)
                .contentShape(Capsule())
                .background(
                    Capsule()
                        .fill(.white.opacity(0.2))
                )
        }
    }
}

private struct ProminentCircle<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(iOS 27.0, *) {
            content
                .padding(16)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
        } else if #available(iOS 26.0, *) {
            content
                .padding(16)
                .contentShape(Circle())
                .glassEffect(.clear.interactive(), in: .circle)
        } else {
            content
                .padding(16)
                .contentShape(Circle())
                .background(
                    Circle()
                        .fill(.white.opacity(0.2))
                )
        }
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

    return LaunchpadView()
        .environment(AppSettings())
        .environment(Operations(container: container))
        .environment(container.tunnel)
        .environment(container.selection)
        .environment(container.latency)
        .environment(container.configurationStore)
        .environment(container.chainStore)
        .environment(container.subscriptionStore)
        .environment(ConnectionStats.previewSeeded())
        .colorScheme(.dark)
}
#endif
