//
//  MainControlView.swift
//  Anywhere
//
//  Created by NodePassProject on 9/22/26.
//

import SwiftUI
import NetworkExtension

struct MainControlView: View {
    @Environment(Operations.self) private var operations
    @Environment(TunnelController.self) private var tunnelController
    @Environment(ProxySelection.self) private var proxySelection
    @Environment(LatencyCenter.self) private var latencyCenter
    @Environment(ConnectionStats.self) private var connectionStats
    @Environment(ConfigurationStore.self) private var configurationStore
    @Environment(ChainStore.self) private var chainStore
    @Environment(GroupStore.self) private var groupStore
    @Environment(SubscriptionStore.self) private var subscriptionStore

    let connectionEffectsEnabled: Bool

    @State private var showingProxiesView = false
    @State private var showingAddSheet = false
    @State private var showingManualAddSheet = false

    private var isLoading: Bool { !configurationStore.isLoaded }

    private var isConnected: Bool {
        tunnelController.rawStatus == .connected
    }

    private var isTransitioning: Bool { tunnelController.rawStatus.isTransitioning }

    private var isPowerButtonDisabled: Bool {
        if configurationStore.hasConfigurations {
            if !isTransitioning {
                if tunnelController.isManagerReady {
                    return false
                }
            }
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                PowerButton(
                    isConnected: isConnected,
                    isTransitioning: isTransitioning,
                    isLoading: isLoading,
                    isDisabled: isPowerButtonDisabled,
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

                let status = tunnelController.status
                HStack {
                    if [.connecting, .disconnecting, .reasserting].contains(status) {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(status.localizedText)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            .layoutPriority(1)

            Rectangle()
                .fill(.clear)
                .frame(idealHeight: 100, maxHeight: 100)

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

    private var indicatorColor: Color {
        if isConnected { return .green }
        if isTransitioning { return .orange }
        return .gray.opacity(0.8)
    }

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
                ZStack {
                    Image(systemName: "power")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 40)
                    Image(systemName: "circle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 5)
                        .foregroundStyle(indicatorColor)
                        .offset(y: 45)
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

    return MainControlView(connectionEffectsEnabled: true)
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
