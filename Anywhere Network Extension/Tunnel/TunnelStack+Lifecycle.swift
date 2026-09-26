//
//  TunnelStack+Lifecycle.swift
//  Anywhere
//
//  Created by NodePassProject on 3/30/26.
//

import Foundation
import Synchronization
@preconcurrency import NetworkExtension
import AnywhereIP

nonisolated private let logger = AnywhereLogger(category: "TunnelStack+Lifecycle")

extension TunnelStack {

    // MARK: - Lifecycle

    func start(packetFlow: NEPacketTunnelFlow, configuration: ProxyConfiguration) async -> Bool {
        guard transition(to: .starting) else { return false }
        let epoch = claimStartEpoch()
        TransportReclaim.unsealAll()
        pendingConfigurationSwitch = nil
        pendingSuspend = false
        makeFreshDutyCycleStreams()
        purgeOutputBuffer()
        AnywhereLogger.installLogSink { [weak self] message, level in
            let logLevel: TunnelLogLevel
            switch level {
            case .debug, .info: logLevel = .info
            case .warning: logLevel = .warning
            case .error: logLevel = .error
            }
            self?.appendLog(message, level: logLevel)
        }
        self.packetFlow = packetFlow
        self.configuration = configuration

        let udpPlane = UDPPlane(stack: self)
        self.udpPlane = udpPlane

        var precompiledRouting: DomainRouter.CompiledRouting?
        if Self.effectiveProxyMode(settings: TunnelSettings.load(), network: networkContext) == .rule {
            precompiledRouting = await domainRouter.compileRoutingConfiguration()
        }

        guard phase == .starting, epoch == startEpoch else {
            logger.warning("[TunnelStack] Start aborted: phase is \(phase), epoch \(epoch)/\(startEpoch)")
            if epoch == startEpoch {
                self.packetFlow = nil
                self.configuration = nil
                self.udpPlane = nil
            }
            return false
        }
        configureRuntime(for: configuration, precompiledRouting: precompiledRouting)
        bringUpDataPlane(configuration: configuration)

        rootTask = Task { await self.run(packetFlow: packetFlow, udpPlane: udpPlane) }

        transition(to: .running)
        logger.debug("[TunnelStack] Started")

        CertificatePolicy.startObserving()
        if let pending = pendingConfigurationSwitch {
            pendingConfigurationSwitch = nil
            switchConfiguration(pending)
        }
        if pendingSuspend {
            pendingSuspend = false
            suspend()
        }
        return true
    }

    // MARK: - Task tree

    private func run(packetFlow: NEPacketTunnelFlow, udpPlane: UDPPlane) async {
        await withDiscardingTaskGroup { group in
            group.addTask { [planeCommands] in
                for await command in planeCommands {
                    await udpPlane.apply(command)
                }
            }
            group.addTask {
                await self.runDutyCycle(packetFlow: packetFlow, udpPlane: udpPlane)
                await self.finishShutdown()
            }
        }
    }

    private func runDutyCycle(packetFlow: NEPacketTunnelFlow, udpPlane: UDPPlane) async {
        await withDiscardingTaskGroup { group in
            group.addTask { [outputKick] in
                for await _ in outputKick {
                    await self.drainOutputLoop(packetFlow: packetFlow)
                }
            }
            group.addTask { await self.runReadLoop(packetFlow: packetFlow, udpPlane: udpPlane) }
            group.addTask { await self.runSettingsObserver() }
            group.addTask { await self.runUDPCleanupLoop(udpPlane: udpPlane) }
            for await job in self.nurseryJobs {
                switch job {
                case .deferredRestart(let configuration, let revalidateMode, let delay, let generation):
                    group.addTask {
                        await self.runDeferredRestart(
                            configuration: configuration,
                            revalidateMode: revalidateMode,
                            delay: delay,
                            generation: generation
                        )
                    }
                }
            }
            group.cancelAll()
        }
    }

    private func finishShutdown() {
        TransportReclaim.sealAll()
        tearDownDataPlane(tcp: .graceful)
        purgeOutputBuffer()
        OutboundConnector.setRoutingContext(nil)
        fakeIPPool.reset()
        connectionRouter.clearRejectMarks()
        ConnectionMetrics.shared.setDefaultServer(nil)
        configuration = nil
        finishPlaneCommands()
    }

    func stop() async {
        switch phase {
        case .idle, .stopped:
            return
        case .stopping:
            await withCheckedContinuation { stopWaiters.append($0) }
            return
        case .starting, .running, .suspended:
            break
        }
        transition(to: .stopping)
        nurseryJobContinuation.finish()
        await rootTask?.value
        rootTask = nil
        AnywhereLogger.installLogSink(nil)
        transition(to: .stopped)
        let waiters = stopWaiters
        stopWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func switchConfiguration(_ newConfiguration: ProxyConfiguration) {
        if phase == .starting {
            logger.info("[VPN] Configuration switch deferred until start completes")
            pendingConfigurationSwitch = newConfiguration
            return
        }
        guard phase.isActive else {
            logger.warning("[VPN] Configuration switch ignored: phase is \(phase)")
            return
        }
        logger.info("[VPN] Configuration switched")
        restartStack(configuration: newConfiguration)
    }

    // MARK: - Sleep / Wake
    
    func suspend() {
        switch phase {
        case .running:
            logger.info("[VPN] Device sleep")
            transition(to: .suspended)
            tearDownDataPlane(tcp: .abortive)
            flushOutputBuffer()
        case .starting:
            logger.info("[VPN] Device sleep during start")
            pendingSuspend = true
        case .suspended, .idle, .stopping, .stopped:
            return
        }
    }
    
    func wake() {
        pendingSuspend = false
        guard phase == .suspended, let configuration else { return }
        logger.info("[VPN] Device wake")
        transition(to: .running)
        bringUpDataPlane(configuration: configuration)
        udpCleanupResume.yield(())
    }

    func updateNetworkContext(_ context: NetworkContext) {
        publishNetworkSupportsIPv6(context.supportsIPv6)
        guard phase.isActive, let configuration else { return }

        guard context != networkContext else { return }
        networkContext = context

        let newEffective = computeEffectiveProxyMode()
        guard newEffective != proxyMode else { return }
        restartStack(configuration: configuration, revalidateMode: true)
    }

    // MARK: - Data plane

    private enum TCPTeardown {
        case graceful
        case abortive
    }
    
    private func bringUpDataPlane(configuration: ProxyConfiguration) {
        guard !dataPlaneUp else {
            logger.error("[TunnelStack] Data plane already up; bring-up ignored")
            return
        }
        dataPlaneUp = true
        let ipStack = makeIPStack()
        self.ipStack = ipStack
        startIPStackTick()
        submitPlaneCommand(.setMultiplexerPool(configuration.makeUDPMultiplexerPool()))
        logger.debug("[TunnelStack] Data plane up")
    }
    
    private func tearDownDataPlane(tcp: TCPTeardown) {
        guard dataPlaneUp else { return }
        dataPlaneUp = false

        ipStackTick?.cancel()
        ipStackTick = nil

        purgeOutputBuffer()

        ipStackAbortContext.store(.teardown, ordering: .relaxed)
        switch tcp {
        case .graceful: closeAllActiveTCP()
        case .abortive: abortAllActiveTCP()
        }
        dataPlaneGeneration.wrappingAdd(1, ordering: .acquiringAndReleasing)

        reclaimAllOutboundPools()
        submitPlaneCommand(.reclaim)

        ipStack?.shutdown()
        ipStack = nil
        tcpConnections.withLock { $0.removeAll() }
        ipStackAbortContext.store(.none, ordering: .relaxed)
        logger.debug("[TunnelStack] Data plane down")
    }

    private func closeAllActiveTCP() {
        for connection in ipStack?.connections() ?? [] { connection.close() }
    }

    private func abortAllActiveTCP() {
        ipStack?.abortAllConnections()
    }

    private func reclaimAllOutboundPools() {
        TransportReclaim.reclaimAll()
        MITMScriptHTTP2Pool.shared.reclaim()
    }

    // MARK: - Restart

    private func restartStack(configuration: ProxyConfiguration, revalidateMode: Bool = false) {
        if revalidateMode, deferredRestartScheduled { return }

        let now = MonotonicClock.now
        let elapsed = now - lastRestartTime

        if elapsed < TunnelConstants.restartThrottleInterval {
            let delay = TunnelConstants.restartThrottleInterval - elapsed
            deferredRestartGeneration += 1
            deferredRestartScheduled = true
            nurseryJobContinuation.yield(.deferredRestart(
                configuration: configuration, revalidateMode: revalidateMode,
                delay: delay, generation: deferredRestartGeneration
            ))
            logger.debug("[TunnelStack] Restart throttled, deferred by \(String(format: "%.0f", delay * 1000))ms")
            return
        }

        restartStackNow(configuration: configuration)
    }

    private func runDeferredRestart(
        configuration: ProxyConfiguration,
        revalidateMode: Bool,
        delay: TimeInterval,
        generation: Int
    ) async {
        try? await Task.sleep(for: .seconds(delay))
        guard generation == deferredRestartGeneration else { return }
        deferredRestartScheduled = false
        guard !Task.isCancelled, phase.isActive else { return }
        if revalidateMode, computeEffectiveProxyMode() == proxyMode { return }
        restartStackNow(configuration: configuration)
    }

    private func restartStackNow(configuration: ProxyConfiguration) {
        guard phase.isActive else {
            logger.warning("[TunnelStack] Restart ignored: phase is \(phase)")
            return
        }
        deferredRestartGeneration += 1
        deferredRestartScheduled = false
        lastRestartTime = MonotonicClock.now

        tearDownDataPlane(tcp: .graceful)

        connectionRouter.clearRejectMarks()

        self.configuration = configuration
        configureRuntime(for: configuration)
        guard phase == .running else {
            logger.debug("[TunnelStack] Reconfigured while suspended; data plane returns on wake")
            return
        }
        bringUpDataPlane(configuration: configuration)
        logger.debug("[TunnelStack] Restarted")
    }

    // MARK: - Settings Observation

    private func runSettingsObserver() async {
        let settings = AWNotificationCenter.Notification.tunnelSettingsChanged as String
        let routing = AWNotificationCenter.Notification.routingChanged as String
        let mitm = AWNotificationCenter.Notification.mitmChanged as String
        for await name in DarwinNotificationConcurrencyBridge.names([
            AWNotificationCenter.Notification.tunnelSettingsChanged,
            AWNotificationCenter.Notification.routingChanged,
            AWNotificationCenter.Notification.mitmChanged
        ]) {
            switch name {
            case settings: handleSettingsChanged()
            case routing: await handleRoutingChanged()
            case mitm: handleMITMChanged()
            default: break
            }
        }
    }

    private func handleSettingsChanged() {
        guard phase.isActive, let configuration else { return }

        let old = settings
        let new = TunnelSettings.load()
        guard new != old else { return }
        settings = new

        if new.quicPolicy != old.quicPolicy {
            logger.info("[VPN] QUIC policy changed: \(old.quicPolicy.rawValue) -> \(new.quicPolicy.rawValue)")
        }
        if new.blockUDP != old.blockUDP {
            logger.info("[VPN] Block UDP changed: \(old.blockUDP) -> \(new.blockUDP)")
        }
        if new.blockWebRTC != old.blockWebRTC {
            logger.info("[VPN] Block WebRTC changed: \(old.blockWebRTC) -> \(new.blockWebRTC)")
        }
        if new.preventDNSLeak != old.preventDNSLeak {
            logger.info("[VPN] Prevent DNS Leak changed: \(old.preventDNSLeak) -> \(new.preventDNSLeak)")
            connectionRouter.preventDNSLeak.store(new.preventDNSLeak, ordering: .relaxed)
        }
        if new.reflectionEnabled != old.reflectionEnabled || new.reflectionAddresses != old.reflectionAddresses {
            logger.info("[VPN] Reflection changed: enabled=\(new.reflectionEnabled), addresses=\(new.reflectionAddresses)")
            publishReflector()
        }
        if new.ipRuleDNSUpstream != old.ipRuleDNSUpstream {
            logger.info("[VPN] IP-rule DNS changed")
            RuleResolver.shared.setUpstream(new.ipRuleDNSUpstream)
        }
        if new.interceptExemptDNSServers != old.interceptExemptDNSServers {
            logger.info("[VPN] DNS interception exemptions changed: \(new.interceptExemptDNSServers.sorted())")
        }
        publishUDPConfig()

        if new.tunnelIncludedRoutes != old.tunnelIncludedRoutes || new.tunnelExcludedRoutes != old.tunnelExcludedRoutes {
            logger.info("[VPN] Custom routes changed: included=\(new.tunnelIncludedRoutes), excluded=\(new.tunnelExcludedRoutes)")
            requestReapplyTunnelSettings()
        }

        let proxyModeChanged = computeEffectiveProxyMode() != proxyMode
        let hideVPNIconChanged = new.hideVPNIcon != old.hideVPNIcon

        guard proxyModeChanged || hideVPNIconChanged else {
            return
        }

        logger.info("[VPN] Settings changed")

        if hideVPNIconChanged {
            requestReapplyTunnelSettings()
        }

        restartStack(configuration: configuration)
    }

    private func handleRoutingChanged() async {
        guard phase.isActive else { return }
        guard proxyMode == .rule else { return }
        logger.info("[VPN] Routing changed")
        let compiled = await domainRouter.compileRoutingConfiguration()
        guard phase.isActive, proxyMode == .rule else { return }
        domainRouter.install(compiled)
        connectionRouter.clearRejectMarks()
    }

    private func handleMITMChanged() {
        guard phase.isActive else { return }
        logger.info("[VPN] MITM settings changed")
        loadMITMSetting()
        publishUDPConfig()
    }
}
