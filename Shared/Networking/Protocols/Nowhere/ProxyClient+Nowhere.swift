//
//  ProxyClient+Nowhere.swift
//  Anywhere
//
//  Created by NodePassProject on 5/30/26.
//

import Foundation
import Synchronization

nonisolated private let nowhereRouteLogger = AnywhereLogger(category: "NowhereRoute")

nonisolated private enum NowhereLogicalFailureContext {
    case quicSession
    case tcpCarrier
    case chainBuild
}

nonisolated private struct NowhereLogicalOpenError: Error {
    let underlying: Error
    let context: NowhereLogicalFailureContext
}

nonisolated private struct NowhereLogicalPolicy: Sendable {
    let proxyHost: String
    let proxyPort: UInt16
    let key: String
    let uplink: NowhereNetwork
    let downlink: NowhereNetwork
    let multiplex: Bool
    let sessionID: Data
    let tls: TLSConfiguration

    func resolved(_ route: NowhereResolvedRoute) throws -> NowhereConfiguration {
        try NowhereConfiguration(
            proxyHost: proxyHost,
            proxyPort: proxyPort,
            key: key,
            uplink: route.uplink,
            downlink: route.downlink,
            multiplex: multiplex,
            sessionID: sessionID,
            tls: tls
        )
    }
}

nonisolated private struct NowherePreparedHalf: Sendable {
    let connection: ProxyConnection
    let commit: @Sendable () async throws -> Void

    func cancel() { connection.abort() }
}

nonisolated private struct NowherePreparedRoute: Sendable {
    let uplink: NowherePreparedHalf
    let downlink: NowherePreparedHalf?
    let kind: NowhereProtocol.FlowKind
    let mode: NowhereTCPRelayMode

    func cancel() {
        uplink.cancel()
        downlink?.cancel()
    }
}

nonisolated private struct NowherePreparedSelection: Sendable {
    let prepared: NowherePreparedRoute
    let lease: NowhereFlowIDLease
    let attempt: NowhereFlowOpenAttempt
    let route: NowhereResolvedRoute
}

nonisolated private final class NowhereLeasedConnection: ProxyConnection {
    private let inner: ProxyConnection
    private let lease: NowhereFlowIDLease

    init(inner: ProxyConnection, lease: NowhereFlowIDLease) {
        self.inner = inner
        self.lease = lease
    }

    var outerTLSVersion: TLSVersion? { inner.outerTLSVersion }
    var deliversDatagrams: Bool { inner.deliversDatagrams }
    var isConnected: Bool { inner.isConnected }

    func sendRaw(_ data: Data) async throws {
        do { try await inner.sendRaw(data) }
        catch {
            inner.abort()
            lease.release()
            throw error
        }
    }

    func receiveRaw() async throws -> Data? {
        do {
            let data = try await inner.receiveRaw()
            if data == nil { lease.release() }
            return data
        } catch {
            inner.abort()
            lease.release()
            throw error
        }
    }

    func cancel() {
        inner.cancel()
        lease.release()
    }

    func abort() {
        inner.abort()
        lease.release()
    }

    deinit { lease.release() }
}

nonisolated extension ProxyClient {
    func connectWithNowhere(
        command: ProxyCommand,
        destinationHost: String,
        destinationPort: UInt16,
        initialData: Data?
    ) async throws -> ProxyConnection {
        guard case .nowhere(let key, let uplink, let downlink, let multiplex, let securityLayer) = configuration.outbound else {
            throw AnywhereError.proxy(.nowhere, .protocolViolation(detail: "Invalid Nowhere configuration"))
        }
        guard let tls = securityLayer.tlsConfiguration else {
            throw AnywhereError.proxy(.nowhere, .protocolViolation(detail: "Nowhere TLS configuration not set"))
        }
        let effectiveMultiplex = multiplex && (uplink.canUseTCP || downlink.canUseTCP)
        let identityKey = NowhereTransportIdentityKey(
            configurationID: configuration.id,
            proxyHost: configuration.serverAddress,
            proxyPort: configuration.serverPort,
            key: key,
            uplink: uplink,
            downlink: downlink,
            multiplex: effectiveMultiplex,
            tls: tls
        )
        let sessionID = try NowhereTransportIdentityRegistry.shared.identity(for: identityKey)
        let policy = NowhereLogicalPolicy(
            proxyHost: configuration.serverAddress,
            proxyPort: configuration.serverPort,
            key: key,
            uplink: uplink,
            downlink: downlink,
            multiplex: effectiveMultiplex,
            sessionID: sessionID,
            tls: tls
        )

        let destination = try NowhereProtocol.Target(host: destinationHost, port: destinationPort)
        let retries = tunnel == nil || configuration.chain?.isEmpty == false || !parentChain.isEmpty ? 1 : 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))

        return try await connectLogicalNowhere(
            policy: policy,
            command: command,
            destination: destination,
            initialData: command == .tcp ? initialData : nil,
            identityKey: identityKey,
            deadline: deadline,
            retriesLeft: retries
        )
    }

    private func connectLogicalNowhere(
        policy: NowhereLogicalPolicy,
        command: ProxyCommand,
        destination: NowhereProtocol.Target,
        initialData: Data?,
        identityKey: NowhereTransportIdentityKey,
        deadline: ContinuousClock.Instant,
        retriesLeft: Int
    ) async throws -> ProxyConnection {
        var retriesLeft = retriesLeft
        let initialLease = try NowhereTransportIdentityRegistry.shared.leaseFlowID(
            for: identityKey,
            sessionID: policy.sessionID
        )
        let plan = NowhereRoutePlanner.plan(
            uplink: policy.uplink,
            downlink: policy.downlink,
            seed: NowhereRoutePlanner.seed(from: policy.sessionID),
            flowID: initialLease.flowID
        )
        var nextLease: NowhereFlowIDLease? = initialLease
        var lockedRoute: NowhereResolvedRoute?
        var inheritedTunnel = takeChainTunnel()

        while true {
            let selection: NowherePreparedSelection
            var activeSelection: NowherePreparedSelection?
            let inheritedForAttempt = inheritedTunnel
            inheritedTunnel = nil
            do {
                if let lockedRoute {
                    let lease: NowhereFlowIDLease
                    if let pending = nextLease {
                        lease = pending
                    } else {
                        lease = try NowhereTransportIdentityRegistry.shared.leaseFlowID(
                            for: identityKey,
                            sessionID: policy.sessionID
                        )
                    }
                    nextLease = nil
                    selection = try await prepareNowhereSelection(
                        policy: policy,
                        route: lockedRoute,
                        lease: lease,
                        command: command,
                        destination: destination,
                        initialData: initialData,
                        inheritedTunnel: inheritedForAttempt,
                        deadline: deadline,
                        preparationLimit: nil
                    )
                } else {
                    guard let lease = nextLease else {
                        throw AnywhereError.proxy(.nowhere, .streamClosed)
                    }
                    nextLease = nil
                    selection = try await prepareInitialNowhereSelection(
                        policy: policy,
                        plan: plan,
                        lease: lease,
                        identityKey: identityKey,
                        command: command,
                        destination: destination,
                        initialData: initialData,
                        inheritedTunnel: inheritedForAttempt,
                        deadline: deadline
                    )
                    lockedRoute = selection.route
                }
                activeSelection = selection

                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else { throw AnywhereError.proxy(.nowhere, .openTimeout) }
                let connection = try await withDialDeadline(
                    remaining,
                    onExpiry: { selection.attempt.cancel() },
                    error: { AnywhereError.proxy(.nowhere, .openTimeout) },
                    discardingLateResult: { $0.cancel() }
                ) {
                    try await Self.commitPreparedNowhereRoute(selection.prepared)
                }
                return NowhereLeasedConnection(inner: connection, lease: selection.lease)
            } catch {
                activeSelection?.attempt.cancel()
                activeSelection?.lease.release()
                let explicitReplacement: Bool = {
                    guard case AnywhereError.proxy(.nowhere, .flowRejected(let code)) = Self.underlyingLogicalNowhereFailure(error),
                          code == NowhereProtocol.FlowRejectCode.sessionReplaced.rawValue else { return false }
                    return true
                }()
                let replaySafe = explicitReplacement || activeSelection?.attempt.hasCommitted != true
                if retriesLeft > 0, replaySafe, Self.isRetryableLogicalNowhereFailure(error) {
                    let route = lockedRoute ?? plan.primary
                    let nwConfig = try policy.resolved(route)
                    if explicitReplacement, nwConfig.multiplex {
                        NowhereMultiplexerRegistry.shared.invalidate(
                            configurationID: configuration.id
                        )
                    }
                    if Self.shouldInvalidateAsymmetricQUICSession(
                        error: error,
                        uplink: nwConfig.uplink,
                        downlink: nwConfig.downlink
                    ) {
                        NowhereClient.invalidateSharedSession(for: nwConfig)
                    }
                    retriesLeft -= 1
                    nextLease = nil
                    continue
                }
                throw Self.underlyingLogicalNowhereFailure(error)
            }
        }
    }

    private func prepareInitialNowhereSelection(
        policy: NowhereLogicalPolicy,
        plan: NowhereRoutePlan,
        lease: NowhereFlowIDLease,
        identityKey: NowhereTransportIdentityKey,
        command: ProxyCommand,
        destination: NowhereProtocol.Target,
        initialData: Data?,
        inheritedTunnel: ProxyConnection?,
        deadline: ContinuousClock.Instant
    ) async throws -> NowherePreparedSelection {
        do {
            return try await prepareNowhereSelection(
                policy: policy,
                route: plan.primary,
                lease: lease,
                command: command,
                destination: destination,
                initialData: initialData,
                inheritedTunnel: inheritedTunnel,
                deadline: deadline,
                preparationLimit: plan.fallback == nil
                    ? nil
                    : NowhereRoutePlanner.primaryPreparationTimeout
            )
        } catch {
            guard let fallback = plan.fallback else { throw error }
            nowhereRouteLogger.warning(
                "[Nowhere] event=carrier_fallback primary=\(plan.primary.label) "
                    + "fallback=\(fallback.label) reason=\(String(describing: error))"
            )
            let fallbackLease = try NowhereTransportIdentityRegistry.shared.leaseFlowID(
                for: identityKey,
                sessionID: policy.sessionID
            )
            do {
                return try await prepareNowhereSelection(
                    policy: policy,
                    route: fallback,
                    lease: fallbackLease,
                    command: command,
                    destination: destination,
                    initialData: initialData,
                    inheritedTunnel: nil,
                    deadline: deadline,
                    preparationLimit: nil
                )
            } catch let fallbackError {
                throw AnywhereError.proxy(.nowhere, .connectionClosed(
                    detail: "Route \(plan.primary.label) failed before commit: \(error); "
                        + "fallback \(fallback.label) failed before commit: \(fallbackError)"
                ))
            }
        }
    }

    private func prepareNowhereSelection(
        policy: NowhereLogicalPolicy,
        route: NowhereResolvedRoute,
        lease: NowhereFlowIDLease,
        command: ProxyCommand,
        destination: NowhereProtocol.Target,
        initialData: Data?,
        inheritedTunnel: ProxyConnection?,
        deadline: ContinuousClock.Instant,
        preparationLimit: Duration?
    ) async throws -> NowherePreparedSelection {
        let attempt = NowhereFlowOpenAttempt()
        let nwConfig = try policy.resolved(route)
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else {
            lease.release()
            inheritedTunnel?.cancel()
            throw AnywhereError.proxy(.nowhere, .openTimeout)
        }
        let budget = preparationLimit.map { min($0, remaining) } ?? remaining
        do {
            let prepared = try await withDialDeadline(
                budget,
                onExpiry: {
                    attempt.cancel()
                    inheritedTunnel?.cancel()
                },
                error: { AnywhereError.proxy(.nowhere, .openTimeout) },
                discardingLateResult: { $0.cancel() }
            ) { [weak self] in
                guard let self else { throw AnywhereError.transport(.terminated) }
                return try await self.prepareNowhereRoute(
                    nwConfig: nwConfig,
                    command: command,
                    destination: destination,
                    initialData: initialData,
                    flowID: lease.flowID,
                    attempt: attempt,
                    inheritedTunnel: inheritedTunnel
                )
            }
            return NowherePreparedSelection(
                prepared: prepared,
                lease: lease,
                attempt: attempt,
                route: route
            )
        } catch {
            attempt.cancel()
            inheritedTunnel?.cancel()
            lease.release()
            throw error
        }
    }

    private static func commitPreparedNowhereRoute(
        _ prepared: NowherePreparedRoute
    ) async throws -> ProxyConnection {
        do {
            if let downlink = prepared.downlink {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await prepared.uplink.commit() }
                    group.addTask { try await downlink.commit() }
                    try await group.waitForAll()
                }
                if let udp = prepared.uplink.connection as? NowhereUDPConnection {
                    udp.activatePairedFlow()
                }
                return NowhereDirectionalConnection(
                    uplink: logicalNowhereConnection(prepared.uplink.connection, mode: prepared.mode),
                    downlink: logicalNowhereConnection(downlink.connection, mode: prepared.mode),
                    kind: prepared.kind
                )
            }
            try await prepared.uplink.commit()
            let logical = logicalNowhereConnection(prepared.uplink.connection, mode: prepared.mode)
            return NowhereDirectionalConnection(uplink: logical, downlink: logical, kind: prepared.kind)
        } catch {
            prepared.cancel()
            throw error
        }
    }

    private static func logicalNowhereConnection(
        _ connection: ProxyConnection,
        mode: NowhereTCPRelayMode
    ) -> ProxyConnection {
        switch mode {
        case .tcp: connection
        case .udp: NowhereTCPUDPConnection(inner: connection)
        }
    }

    private static func isRetryableLogicalNowhereFailure(_ error: Error) -> Bool {
        let tagged = error as? NowhereLogicalOpenError
        guard case AnywhereError.proxy(.nowhere, let failure) = (tagged?.underlying ?? error) else {
            return false
        }
        switch failure {
        case .flowRejected(let code) where code == NowhereProtocol.FlowRejectCode.sessionReplaced.rawValue:
            return true
        case .notReady, .streamClosed:
            return tagged?.context == .quicSession
        default:
            return false
        }
    }

    private static func logicalNowhereFailure(
        _ error: Error,
        context: NowhereLogicalFailureContext
    ) -> Error {
        NowhereLogicalOpenError(underlying: error, context: context)
    }

    private static func underlyingLogicalNowhereFailure(_ error: Error) -> Error {
        (error as? NowhereLogicalOpenError)?.underlying ?? error
    }

    static func shouldInvalidateAsymmetricQUICSession(
        error: Error,
        uplink: NowhereCarrier,
        downlink: NowhereCarrier
    ) -> Bool {
        guard uplink != downlink,
              (uplink == .udp || downlink == .udp),
              case AnywhereError.proxy(.nowhere, .flowRejected(let code)) = underlyingLogicalNowhereFailure(error),
              code == NowhereProtocol.FlowRejectCode.sessionReplaced.rawValue else {
            return false
        }
        return true
    }

    private static func flowKindAndMode(
        _ command: ProxyCommand
    ) -> (NowhereProtocol.FlowKind, NowhereTCPRelayMode)? {
        switch command {
        case .tcp, .mux: return (.tcp, .tcp)
        case .udp: return (.udp, .udp)
        }
    }

    private func prepareNowhereRoute(
        nwConfig: NowhereConfiguration,
        command: ProxyCommand,
        destination: NowhereProtocol.Target,
        initialData: Data?,
        flowID: UInt32,
        attempt: NowhereFlowOpenAttempt,
        inheritedTunnel: ProxyConnection?
    ) async throws -> NowherePreparedRoute {
        guard let (kind, mode) = Self.flowKindAndMode(command) else {
            throw AnywhereError.routing(.dropped)
        }

        let rebuildChain: [ProxyConfiguration]? = parentChain.isEmpty
            ? configuredNowhereChain
            : parentChain
        let inheritedMatchesUplink = inheritedTunnel.map {
            let carrierMatches = nwConfig.uplink == .udp
                ? $0.deliversDatagrams
                : !$0.deliversDatagrams
            let canReuse = nwConfig.uplink != .udp || parentChain.isEmpty
            return carrierMatches && canReuse
        } ?? false
        let providedUplink = inheritedMatchesUplink ? inheritedTunnel : nil
        if inheritedTunnel != nil, !inheritedMatchesUplink {
            inheritedTunnel?.cancel()
        }

        if inheritedTunnel != nil, rebuildChain == nil {
            guard providedUplink != nil, nwConfig.uplink == nwConfig.downlink else {
                throw AnywhereError.proxy(
                    .nowhere,
                    .protocolViolation(detail: "Selected MIX carrier needs a rebuildable parent chain")
                )
            }
        }

        if nwConfig.uplink == nwConfig.downlink {
            let header = NowhereProtocol.FlowHeader(
                role: .duplex,
                flowID: flowID,
                kind: kind,
                uplink: nwConfig.uplink,
                downlink: nwConfig.downlink
            )
            let prepared = try await prepareNowhereHalf(
                nwConfig: nwConfig,
                destination: destination,
                header: header,
                carrier: nwConfig.uplink,
                attempt: attempt,
                initialData: initialData,
                providedTunnel: providedUplink,
                chain: providedUplink == nil ? rebuildChain : nil
            )
            return NowherePreparedRoute(uplink: prepared, downlink: nil, kind: kind, mode: mode)
        }

        let open = NowhereProtocol.FlowHeader(
            role: .open,
            flowID: flowID,
            kind: kind,
            uplink: nwConfig.uplink,
            downlink: nwConfig.downlink
        )
        let attach = NowhereProtocol.FlowHeader(
            role: .attach,
            flowID: flowID,
            kind: kind,
            uplink: nwConfig.uplink,
            downlink: nwConfig.downlink
        )

        return try await withThrowingTaskGroup(of: (Bool, NowherePreparedHalf).self) { group in
            group.addTask {
                let half = try await self.prepareNowhereHalf(
                    nwConfig: nwConfig,
                    destination: destination,
                    header: open,
                    carrier: nwConfig.uplink,
                    attempt: attempt,
                    initialData: initialData,
                    providedTunnel: providedUplink,
                    chain: providedUplink == nil ? rebuildChain : nil
                )
                return (true, half)
            }
            group.addTask {
                let half = try await self.prepareNowhereHalf(
                    nwConfig: nwConfig,
                    destination: destination,
                    header: attach,
                    carrier: nwConfig.downlink,
                    attempt: attempt,
                    initialData: nil,
                    providedTunnel: nil,
                    chain: rebuildChain
                )
                return (false, half)
            }

            var uplink: NowherePreparedHalf?
            var downlink: NowherePreparedHalf?
            do {
                for try await (isUplink, half) in group {
                    if isUplink { uplink = half } else { downlink = half }
                }
            } catch {
                attempt.cancel()
                group.cancelAll()
                throw error
            }
            guard let uplink, let downlink else {
                attempt.cancel()
                throw AnywhereError.proxy(.nowhere, .streamClosed)
            }
            return NowherePreparedRoute(
                uplink: uplink,
                downlink: downlink,
                kind: kind,
                mode: mode
            )
        }
    }

    private func prepareNowhereHalf(
        nwConfig: NowhereConfiguration,
        destination: NowhereProtocol.Target,
        header: NowhereProtocol.FlowHeader,
        carrier: NowhereCarrier,
        attempt: NowhereFlowOpenAttempt,
        initialData: Data?,
        providedTunnel: ProxyConnection?,
        chain: [ProxyConfiguration]?
    ) async throws -> NowherePreparedHalf {
        do {
            if carrier == .tcp {
                if nwConfig.multiplex {
                    let connection = try await prepareNowhereMultiplexerHalf(
                        nwConfig: nwConfig,
                        flowHeader: header,
                        attempt: attempt,
                        providedTunnel: providedTunnel,
                        chain: chain
                    )
                    return NowherePreparedHalf(connection: connection) {
                        try await connection.open(
                            destination: destination,
                            flowHeader: header,
                            initialData: initialData,
                            attempt: attempt
                        )
                    }
                }

                let carrierTunnel: ProxyConnection?
                if let providedTunnel {
                    carrierTunnel = providedTunnel
                } else if let chain, !chain.isEmpty {
                    carrierTunnel = try await buildNowhereCarrierTunnel(chain: chain, deliver: .tcp)
                } else {
                    carrierTunnel = nil
                }
                let connection = NowhereTCPConnection(
                    configuration: nwConfig,
                    connectHost: directDialHost,
                    tunnel: carrierTunnel
                )
                guard !isCancelled, attempt.bind(connection) else {
                    connection.cancel()
                    throw AnywhereError.proxy(.nowhere, .streamClosed)
                }
                try await connection.prepareFresh(flowHeader: header)
                return NowherePreparedHalf(connection: connection) {
                    try await connection.commitFresh(
                        destination: destination,
                        flowHeader: header,
                        initialData: initialData,
                        attempt: attempt
                    )
                }
            }

            let client: NowhereClient
            if let providedTunnel {
                client = NowhereClient.chained(
                    configuration: nwConfig,
                    transport: ProxyConnectionDatagramTransport(connection: providedTunnel)
                )
            } else if let chain, !chain.isEmpty {
                client = try await acquireChainedNowhereClient(
                    nwConfig: nwConfig,
                    chain: chain,
                    lastDeliver: .udp
                )
            } else {
                client = try NowhereClient.shared(for: nwConfig)
            }

            switch header.kind {
            case .tcp:
                let connection = try await client.prepareTCPHalf(
                    destination: destination,
                    header: header,
                    initialData: initialData,
                    attempt: attempt
                )
                return NowherePreparedHalf(connection: connection) {
                    try await connection.commit()
                }
            case .udp:
                let connection = try await client.prepareUDP(
                    destination: destination,
                    header: header,
                    attempt: attempt
                )
                return NowherePreparedHalf(connection: connection) {
                    try await connection.commit(attempt: attempt)
                }
            }
        } catch {
            throw Self.logicalNowhereFailure(
                error,
                context: carrier == .udp ? .quicSession : (chain == nil ? .tcpCarrier : .chainBuild)
            )
        }
    }

    private func buildNowhereCarrierTunnel(
        chain: [ProxyConfiguration],
        deliver: ProxyCommand
    ) async throws -> ProxyConnection {
        let commands = try Self.computeChainHopCommands(chain: chain, lastDeliver: deliver).get()
        return try await Self.buildDetachedChainTunnel(
            chain: chain,
            hopCommands: commands,
            finalDestination: (configuration.serverAddress, configuration.serverPort),
            useResolvedAddressForDirectDial: useResolvedAddressForDirectDial,
            track: { _ in }
        )
    }

    private func prepareNowhereMultiplexerHalf(
        nwConfig: NowhereConfiguration,
        flowHeader: NowhereProtocol.FlowHeader,
        attempt: NowhereFlowOpenAttempt,
        providedTunnel: ProxyConnection?,
        chain: [ProxyConfiguration]?
    ) async throws -> NowhereMultiplexerConnection {
        let stream: NowhereMultiplexerStream
        let ownedMultiplexer: NowhereMultiplexer?

        if let providedTunnel {
            let multiplexer = try await Self.makeNowhereMultiplexer(
                configuration: nwConfig,
                connectHost: directDialHost,
                tunnel: providedTunnel
            )
            do {
                stream = try await multiplexer.openStream(flowID: flowHeader.flowID)
                ownedMultiplexer = multiplexer
            } catch {
                multiplexer.abort()
                throw error
            }
        } else {
            let multiplexerChain: [ProxyConfiguration]
            let multiplexerBuilder: @Sendable () async throws -> NowhereMultiplexer
            let connectHost = directDialHost

            if let chain, !chain.isEmpty {
                let cascadeCommands = try Self.computeChainHopCommands(
                    chain: chain,
                    lastDeliver: .tcp
                ).get()
                multiplexerChain = chain
                let proxyHost = configuration.serverAddress
                let proxyPort = configuration.serverPort
                let useResolvedAddress = useResolvedAddressForDirectDial
                multiplexerBuilder = {
                    let holders = Mutex<[ProxyClient]>([])
                    do {
                        let tunnel = try await ProxyClient.buildDetachedChainTunnel(
                            chain: chain,
                            hopCommands: cascadeCommands,
                            finalDestination: (proxyHost, proxyPort),
                            useResolvedAddressForDirectDial: useResolvedAddress,
                            track: { client in holders.withLock { $0.append(client) } }
                        )
                        let snapshot = holders.withLock { $0 }
                        return try await Self.makeNowhereMultiplexer(
                            configuration: nwConfig,
                            connectHost: connectHost,
                            tunnel: tunnel,
                            chainHolders: snapshot
                        )
                    } catch {
                        let snapshot = holders.withLock { $0 }
                        for client in snapshot { await client.cancel() }
                        throw error
                    }
                }
            } else {
                multiplexerChain = []
                multiplexerBuilder = {
                    try await Self.makeNowhereMultiplexer(
                        configuration: nwConfig,
                        connectHost: connectHost,
                        tunnel: nil
                    )
                }
            }

            stream = try await NowhereMultiplexerRegistry.shared.acquire(
                configurationID: configuration.id,
                configuration: nwConfig,
                connectHost: connectHost,
                chain: multiplexerChain,
                flowID: flowHeader.flowID,
                builder: multiplexerBuilder
            )
            ownedMultiplexer = nil
        }

        let connection = NowhereMultiplexerConnection(
            stream: stream,
            ownedMultiplexer: ownedMultiplexer
        )
        guard !isCancelled, attempt.bind(connection) else {
            connection.abort()
            throw AnywhereError.proxy(.nowhere, .streamClosed)
        }
        return connection
    }

    private static func makeNowhereMultiplexer(
        configuration: NowhereConfiguration,
        connectHost: String,
        tunnel: ProxyConnection?,
        chainHolders: [ProxyClient] = []
    ) async throws -> NowhereMultiplexer {
        let client = TLSClient(configuration: configuration.tcpTLSConfiguration)
        let record: TLSRecordConnection
        if let tunnel {
            record = try await client.connect(overTunnel: tunnel)
        } else {
            record = try await client.connect(
                host: connectHost,
                port: configuration.proxyPort
            )
        }

        do {
            guard configuration.acceptsNegotiatedALPN(record.negotiatedALPN) else {
                throw AnywhereError.tls(.handshakeFailed(
                    detail: "Portal did not negotiate the configured ALPN"
                ))
            }
            let exporter = try record.exportKeyingMaterial(
                label: "EXPORTER-Nowhere-Auth",
                context: Data(),
                length: 32
            )
            let auth = try NowhereProtocol.makeAuthFrame(
                authKey: configuration.authKey,
                transport: .tlsTCP,
                exporter: exporter,
                sessionID: configuration.sessionID
            )
            let transport = TLSByteTransport(record)
            var bootstrap = auth
            bootstrap.append(NowhereMultiplexerConstants.marker)
            do {
                try await transport.send(bootstrap)
            } catch {
                transport.cancel()
                throw error
            }
            return NowhereMultiplexer(
                transport: transport,
                tlsVersion: TLSVersion(rawValue: record.tlsVersion),
                chainHolders: chainHolders
            )
        } catch {
            record.cancel()
            throw error
        }
    }

    private var configuredNowhereChain: [ProxyConfiguration]? {
        if let chain = configuration.chain, !chain.isEmpty { return chain }
        return nil
    }

    private func acquireChainedNowhereClient(
        nwConfig: NowhereConfiguration,
        chain: [ProxyConfiguration],
        lastDeliver: ProxyCommand
    ) async throws -> NowhereClient {
        let cascadeCommands = try Self.computeChainHopCommands(
            chain: chain,
            lastDeliver: lastDeliver
        ).get()
        let nwServerAddress = configuration.serverAddress
        let nwServerPort = configuration.serverPort
        let useResolvedAddress = useResolvedAddressForDirectDial

        return try await NowhereClient.acquireChained(
            configuration: nwConfig,
            chain: chain,
            builder: {
                let holders = Mutex<[ProxyClient]>([])
                do {
                    let chainTunnel = try await ProxyClient.buildDetachedChainTunnel(
                        chain: chain,
                        hopCommands: cascadeCommands,
                        finalDestination: (nwServerAddress, nwServerPort),
                        useResolvedAddressForDirectDial: useResolvedAddress,
                        track: { client in holders.withLock { $0.append(client) } }
                    )
                    let snapshot = holders.withLock { $0 }
                    return (
                        ProxyConnectionDatagramTransport(connection: chainTunnel),
                        snapshot
                    )
                } catch {
                    let snapshot = holders.withLock { $0 }
                    for client in snapshot { await client.cancel() }
                    throw error
                }
            }
        )
    }
}
