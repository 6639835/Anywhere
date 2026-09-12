//
//  ProxyClient.swift
//  Anywhere
//
//  Created by NodePassProject on 1/26/26.
//

import Foundation
import Synchronization

nonisolated final class ProxyClient: Sendable {
    fileprivate static let sharedH2BringUpTimeout: TimeInterval = 30

    let configuration: ProxyConfiguration
    let useResolvedAddressForDirectDial: Bool

    private enum Phase: PhaseTransitionable {
        case idle
        case delivered(ProxyConnection)
        case cancelled

        static func canTransition(from old: Phase, to new: Phase) -> Bool {
            switch (old, new) {
            case (.idle, .delivered),
                 (.idle, .cancelled),
                 (.delivered, .cancelled):
                return true
            default:
                return false
            }
        }
    }

    private struct State: PhaseHolding {
        var phase: Phase = .idle
        var tunnel: ProxyConnection?
    }

    private let state: Mutex<State>

    var tunnel: ProxyConnection? { state.withLock { $0.tunnel } }

    func setChainTunnel(_ tunnel: ProxyConnection?) {
        state.withLock { $0.tunnel = tunnel }
    }
    let parentChain: [ProxyConfiguration]

    let isDefaultProxy: Bool

    var directDialHost: String {
        useResolvedAddressForDirectDial ? configuration.connectAddress : configuration.serverAddress
    }

    var isCancelled: Bool {
        state.withLock { if case .cancelled = $0.phase { true } else { false } }
    }

    init(
        configuration: ProxyConfiguration,
        tunnel: ProxyConnection? = nil,
        useResolvedAddressForDirectDial: Bool = false,
        parentChain: [ProxyConfiguration] = [],
        isDefaultProxy: Bool = false
    ) {
        self.configuration = configuration
        self.state = Mutex(State(tunnel: tunnel))
        self.useResolvedAddressForDirectDial = useResolvedAddressForDirectDial
        self.parentChain = parentChain
        self.isDefaultProxy = isDefaultProxy
    }

    // MARK: - Delivery / teardown

    private func deliver(_ dial: () async throws -> ProxyConnection) async throws -> ProxyConnection {
        let connection = try await dial()
        enum Publication { case published, cancelled, alreadyDelivered }
        let publication: Publication = state.withLock { s in
            switch s.phase {
            case .idle:
                s.transition(to: .delivered(connection))
                return .published
            case .delivered:
                return .alreadyDelivered
            case .cancelled:
                return .cancelled
            }
        }
        switch publication {
        case .published:
            return connection
        case .cancelled:
            connection.cancel()
            throw AnywhereError.transport(.terminated)
        case .alreadyDelivered:
            connection.cancel()
            throw AnywhereError.transport(.connectionFailed(
                endpoint: configuration.serverAddress,
                detail: "proxy client already delivered a connection"
            ))
        }
    }

    // MARK: - Public API

    var isQUICTransport: Bool {
        (configuration.outboundProtocol == .nowhere && configuration.nowhereUplink == .udp)
            || configuration.outboundProtocol == .hysteria
            || configuration.isXHTTPOverHTTP3
    }

    private func withOutboundMetrics(
        _ dial: () async throws -> ProxyConnection
    ) async throws -> ProxyConnection {
        guard isDefaultProxy, let attempt = ConnectionMetrics.shared.beginAttempt() else {
            return try await dial()
        }
        let connection = try await ConnectionMetrics.$currentAttempt.withValue(attempt) {
            try await dial()
        }
        return MeteredProxyConnection(connection, attempt: attempt)
    }

    func connect(
        to destinationHost: String,
        port destinationPort: UInt16,
        initialData: Data? = nil
    ) async throws -> ProxyConnection {
        try await dial(.tcp(destinationHost, port: destinationPort, initialData: initialData))
    }

    func connectUDP(
        to destinationHost: String,
        port destinationPort: UInt16
    ) async throws -> ProxyConnection {
        try await dial(.udp(destinationHost, port: destinationPort))
    }
    
    func connectVLESSMultiplexerCarrier() async throws -> ProxyConnection {
        try await dial(.vlessMultiplexerCarrier)
    }

    private func dial(_ request: ProxyRequest) async throws -> ProxyConnection {
        try await withOutboundMetrics {
            try await self.deliver {
                try await self.connectThroughChainIfNeeded(request)
            }
        }
    }

    private func connectThroughChainIfNeeded(_ request: ProxyRequest) async throws -> ProxyConnection {
        guard let chain = configuration.chain, !chain.isEmpty, tunnel == nil else {
            return try await connectWithOutbound(request)
        }
        
        if configuration.outboundProtocol == .nowhere, configuration.nowhereMultiplex {
            return try await connectWithOutbound(request)
        }

        if configuration.outboundProtocol == .nowhere,
           configuration.nowhereUplink != configuration.nowhereDownlink {
            throw AnywhereError.proxy(.nowhere, .protocolViolation(detail: "Asymmetric Nowhere carriers do not support proxy chains"))
        }

        if isQUICTransport {
            return try await connectWithOutbound(request)
        }

        guard let lastDeliver = configuration.upstreamNetwork(for: request.network) else {
            throw AnywhereError.proxy(configuration.outboundProtocol.wire, .protocolViolation(
                detail: "\(configuration.outboundProtocol.name) doesn't support \(request.network)"
            ))
        }

        let hopNetworks = try Self.computeChainHopNetworks(chain: chain, lastDeliver: lastDeliver).get()

        let chainTunnel = try await buildChainTunnel(
            chain: chain, index: 0, currentTunnel: nil, hopNetworks: hopNetworks
        )
        setChainTunnel(chainTunnel)
        return try await connectWithOutbound(request)
    }

    static func computeChainHopNetworks(
        chain: [ProxyConfiguration],
        outerProtocol: OutboundProtocol,
        outerNetwork: ProxyNetwork
    ) -> Result<[ProxyNetwork], Error> {
        guard !chain.isEmpty else { return .success([]) }

        guard let lastDeliver = outerProtocol.upstreamNetwork(for: outerNetwork) else {
            return .failure(AnywhereError.proxy(outerProtocol.wire, .protocolViolation(
                detail: "\(outerProtocol.name) doesn't support \(outerNetwork)"
            )))
        }

        return computeChainHopNetworks(chain: chain, lastDeliver: lastDeliver)
    }
    
    static func computeChainHopNetworks(
        chain: [ProxyConfiguration],
        lastDeliver: ProxyNetwork
    ) -> Result<[ProxyNetwork], Error> {
        guard !chain.isEmpty else { return .success([]) }

        var networks = [ProxyNetwork](repeating: .tcp, count: chain.count)
        networks[chain.count - 1] = lastDeliver

        if chain.count > 1 {
            for i in stride(from: chain.count - 2, through: 0, by: -1) {
                let nextHop = chain[i + 1]
                let downstream = networks[i + 1]
                guard let upstream = nextHop.upstreamNetwork(for: downstream) else {
                    return .failure(AnywhereError.proxy(nextHop.outboundProtocol.wire, .protocolViolation(
                        detail: "Chain hop \(nextHop.outboundProtocol.name) doesn't support \(downstream) downstream — needed by the hop above it"
                    )))
                }
                networks[i] = upstream
            }
        }
        return .success(networks)
    }

    @discardableResult
    func buildChainTunnel(
        chain: [ProxyConfiguration],
        index: Int,
        currentTunnel: ProxyConnection?,
        hopNetworks: [ProxyNetwork],
        finalDestination: (host: String, port: UInt16)? = nil,
        track: ((ProxyClient) -> Void)? = nil
    ) async throws -> ProxyConnection {
        let resolvedDestination: (host: String, port: UInt16)
        if let finalDestination {
            resolvedDestination = finalDestination
        } else {
            guard let network = hopNetworks.last,
                  let port = configuration.endpointPort(for: network) else {
                throw AnywhereError.proxy(configuration.outboundProtocol.wire, .protocolViolation(
                    detail: "Chain command cannot reach \(configuration.outboundProtocol.name) endpoint"
                ))
            }
            resolvedDestination = (configuration.serverAddress, port)
        }
        let resolvedTrack: (ProxyClient) -> Void = track ?? { _ in }
        return try await Self.dialChain(
            chain: chain,
            index: index,
            currentTunnel: currentTunnel,
            hopNetworks: hopNetworks,
            finalDestination: resolvedDestination,
            useResolvedAddressForDirectDial: useResolvedAddressForDirectDial,
            track: resolvedTrack
        )
    }

    static func buildDetachedChainTunnel(
        chain: [ProxyConfiguration],
        hopNetworks: [ProxyNetwork],
        finalDestination: (host: String, port: UInt16),
        useResolvedAddressForDirectDial: Bool,
        track: @escaping (ProxyClient) -> Void
    ) async throws -> ProxyConnection {
        try await dialChain(
            chain: chain,
            index: 0,
            currentTunnel: nil,
            hopNetworks: hopNetworks,
            finalDestination: finalDestination,
            useResolvedAddressForDirectDial: useResolvedAddressForDirectDial,
            track: track
        )
    }

    private static func dialChain(
        chain: [ProxyConfiguration],
        index: Int,
        currentTunnel: ProxyConnection?,
        hopNetworks: [ProxyNetwork],
        finalDestination: (host: String, port: UInt16),
        useResolvedAddressForDirectDial: Bool,
        track: @escaping (ProxyClient) -> Void
    ) async throws -> ProxyConnection {
        var currentTunnel = currentTunnel
        do {
            for hopIndex in index..<chain.count {
                let isLastHop = (hopIndex + 1 == chain.count)
                let nextHost: String
                let nextPort: UInt16
                if !isLastHop {
                    let nextConfiguration = chain[hopIndex + 1]
                    nextHost = nextConfiguration.serverAddress
                    guard let port = nextConfiguration.endpointPort(for: hopNetworks[hopIndex]) else {
                        throw AnywhereError.proxy(nextConfiguration.outboundProtocol.wire, .protocolViolation(
                            detail: "Chain command cannot reach \(nextConfiguration.outboundProtocol.name) endpoint"
                        ))
                    }
                    nextPort = port
                } else {
                    nextHost = finalDestination.host
                    nextPort = finalDestination.port
                }

                let chainClient = ProxyClient(
                    configuration: chain[hopIndex],
                    tunnel: currentTunnel,
                    useResolvedAddressForDirectDial: useResolvedAddressForDirectDial,
                    parentChain: Array(chain[0..<hopIndex])
                )
                track(chainClient)

                switch hopNetworks[hopIndex] {
                case .tcp:
                    currentTunnel = try await chainClient.connect(to: nextHost, port: nextPort)
                case .udp:
                    currentTunnel = try await chainClient.connectUDP(to: nextHost, port: nextPort)
                }
            }
        } catch {
            currentTunnel?.cancel()
            throw error
        }
        guard let tunnel = currentTunnel else {
            throw AnywhereError.transport(.connectionFailed(endpoint: nil, detail: "Empty proxy chain"))
        }
        return tunnel
    }

    func cancel() {
        tearDown()
    }

    func cancel() async {
        tearDown()
    }

    private func tearDown() {
        let (delivered, tunnel) = state.withLock { s -> (ProxyConnection?, ProxyConnection?) in
            let delivered: ProxyConnection? = if case .delivered(let connection) = s.phase {
                connection
            } else {
                nil
            }
            s.transition(to: .cancelled)
            let pair = (delivered, s.tunnel)
            s.tunnel = nil
            return pair
        }
        delivered?.cancel()
        tunnel?.cancel()
    }

    // MARK: - Protocol Handshake

    private func sendProtocolHandshake(
        over connection: ProxyConnection,
        request: ProxyRequest,
        supportsVision: Bool
    ) async throws -> ProxyConnection {
        if isShadowsocks {
            return try await sendShadowsocksProtocolHandshake(over: connection, request: request)
        } else {
            return try await sendVLESSProtocolHandshake(
                over: connection, request: request, supportsVision: supportsVision
            )
        }
    }

    // MARK: - Connection Routing

    private func connectWithOutbound(_ request: ProxyRequest) async throws -> ProxyConnection {
        if request.isVLESSMultiplexerCarrier, configuration.outboundProtocol != .vless {
            throw AnywhereError.proxy(configuration.outboundProtocol.wire, .protocolViolation(
                detail: "Mux is not supported with \(configuration.outboundProtocol.name)"
            ))
        }

        switch configuration.outboundProtocol {
        case .nowhere:
            return try await connectWithNowhere(request)
        case .vless:
            switch configuration.xrayTransportLayer {
            case .ws:
                return try await connectWithWebSocket(request)
            case .httpUpgrade:
                return try await connectWithHTTPUpgrade(request)
            case .grpc:
                return try await connectWithGRPC(request)
            case .xhttp:
                return try await connectWithXHTTP(request)
            case .raw:
                switch configuration.xraySecurityLayer {
                case .tls(let tlsConfig):
                    return try await connectWithTLS(tlsConfig: tlsConfig, request: request)
                case .reality(let realityConfig):
                    return try await connectWithReality(realityConfig: realityConfig, request: request)
                case .none:
                    return try await connectDirect(request)
                }
            }
        case .hysteria:
            return try await connectWithHysteria(request)
        case .sudoku:
            return try await connectWithSudoku(request)
        case .trojan:
            return try await connectWithTrojan(request)
        case .anytls:
            return try await connectWithAnyTLS(request)
        case .socks5:
            return try await connectWithSOCKS5(request)
        case .rfc:
            return try await connectWithRFC(request)
        case .shadowsocks:
            if request.network == .udp {
                return try await connectShadowsocksRealUDP(
                    destinationHost: request.host, destinationPort: request.port
                )
            }
            return try await connectDirect(request)
        }
    }

    private func connectWithTLS(
        tlsConfig: TLSConfiguration,
        request: ProxyRequest
    ) async throws -> ProxyConnection {
        let tlsClient = TLSClient(configuration: tlsConfig)
        let tlsConnection = try await connectTLSRecord(tlsClient)
        let tlsProxyConnection = TLSProxyConnection(tlsConnection: tlsConnection)
        return try await sendProtocolHandshake(
            over: tlsProxyConnection, request: request, supportsVision: true
        )
    }

    private func connectWithReality(
        realityConfig: RealityConfiguration,
        request: ProxyRequest
    ) async throws -> ProxyConnection {
        let realityClient = RealityClient(configuration: realityConfig)
        let realityConnection = try await connectRealityRecord(realityClient)
        let realityProxyConnection = RealityProxyConnection(realityConnection: realityConnection)
        return try await sendProtocolHandshake(
            over: realityProxyConnection, request: request, supportsVision: true
        )
    }

    private func connectTLSRecord(_ tlsClient: TLSClient) async throws -> TLSRecordConnection {
        if let tunnel = self.tunnel {
            return try await tlsClient.connect(overTunnel: tunnel)
        } else {
            return try await tlsClient.connect(host: self.directDialHost, port: self.configuration.serverPort)
        }
    }

    private func connectRealityRecord(_ realityClient: RealityClient) async throws -> TLSRecordConnection {
        if let tunnel = self.tunnel {
            return try await realityClient.connect(overTunnel: tunnel)
        } else {
            return try await realityClient.connect(host: self.directDialHost, port: self.configuration.serverPort)
        }
    }

    // MARK: - WebSocket Connection

    private func connectWithWebSocket(_ request: ProxyRequest) async throws -> ProxyConnection {
        guard case .ws(let wsConfig) = configuration.xrayTransportLayer else {
            throw AnywhereError.proxy(.webSocket, .invalidConfiguration(detail: "WebSocket transport specified but no WebSocket configuration"))
        }

        let wsConnection: WebSocketConnection
        if case .tls(let baseTLSConfig) = configuration.xraySecurityLayer {
            let wsTlsConfig = TLSConfiguration(
                serverName: baseTLSConfig.serverName,
                alpn: ["http/1.1"],
                echEnabled: baseTLSConfig.echEnabled,
                echConfig: baseTLSConfig.echConfig,
                fingerprint: baseTLSConfig.fingerprint
            )
            let tlsClient = TLSClient(configuration: wsTlsConfig)
            let tlsConnection = try await connectTLSRecord(tlsClient)
            wsConnection = WebSocketConnection(tlsConnection: tlsConnection, configuration: wsConfig)
        } else if let tunnel = self.tunnel {
            wsConnection = WebSocketConnection(tunnel: tunnel, configuration: wsConfig)
        } else {
            let transport = TCPTransport(host: directDialHost, port: configuration.serverPort, resolvesViaProxyDNS: true)
            try await transport.connect()
            wsConnection = WebSocketConnection(transport: transport, configuration: wsConfig)
        }

        do {
            try await wsConnection.performUpgrade()
            let webSocketProxyConnection = WebSocketProxyConnection(wsConnection: wsConnection)
            return try await sendProtocolHandshake(
                over: webSocketProxyConnection, request: request, supportsVision: transportSupportsVision
            )
        } catch {
            wsConnection.cancel()
            throw error
        }
    }

    // MARK: - HTTP Upgrade Connection

    private func connectWithHTTPUpgrade(_ request: ProxyRequest) async throws -> ProxyConnection {
        guard case .httpUpgrade(let huConfig) = configuration.xrayTransportLayer else {
            throw AnywhereError.proxy(.httpUpgrade, .invalidConfiguration(detail: "HTTP upgrade transport specified but no configuration"))
        }

        let huConnection: HTTPUpgradeConnection
        if case .tls(let tlsConfiguration) = configuration.xraySecurityLayer {
            let tlsClient = TLSClient(configuration: tlsConfiguration)
            let tlsConnection = try await connectTLSRecord(tlsClient)
            huConnection = HTTPUpgradeConnection(tlsConnection: tlsConnection, configuration: huConfig)
        } else if let tunnel = self.tunnel {
            huConnection = HTTPUpgradeConnection(tunnel: tunnel, configuration: huConfig)
        } else {
            let transport = TCPTransport(host: directDialHost, port: configuration.serverPort, resolvesViaProxyDNS: true)
            try await transport.connect()
            huConnection = HTTPUpgradeConnection(transport: transport, configuration: huConfig)
        }

        do {
            try await huConnection.performUpgrade()
            let httpUpgradeProxyConnection = HTTPUpgradeProxyConnection(huConnection: huConnection)
            return try await sendProtocolHandshake(
                over: httpUpgradeProxyConnection, request: request, supportsVision: transportSupportsVision
            )
        } catch {
            huConnection.cancel()
            throw error
        }
    }

    private func connectWithGRPC(_ request: ProxyRequest) async throws -> ProxyConnection {
        guard case .grpc(let grpcConfig) = configuration.xrayTransportLayer else {
            throw AnywhereError.proxy(.grpc, .invalidConfiguration(detail: "gRPC transport specified but no gRPC configuration"))
        }
        
        let tlsServerName: String?
        if case .tls(let tls) = configuration.xraySecurityLayer { tlsServerName = tls.serverName } else { tlsServerName = nil }
        let realityServerName: String?
        if case .reality(let reality) = configuration.xraySecurityLayer { realityServerName = reality.serverName } else { realityServerName = nil }
        let authority = grpcConfig.resolvedAuthority(
            tlsServerName: tlsServerName,
            realityServerName: realityServerName,
            serverAddress: configuration.serverAddress
        )

        let grpcConnection: GRPCConnection
        if case .reality(let realityConfig) = configuration.xraySecurityLayer {
            let realityClient = RealityClient(configuration: realityConfig)
            let realityConnection = try await connectRealityRecord(realityClient)
            grpcConnection = GRPCConnection(tlsConnection: realityConnection, configuration: grpcConfig, authority: authority)
        } else if case .tls(let baseTLSConfig) = configuration.xraySecurityLayer {
            let grpcTLSConfig = sanitizedGRPCTLSConfiguration(from: baseTLSConfig)
            let tlsClient = TLSClient(configuration: grpcTLSConfig)
            let tlsConnection = try await connectTLSRecord(tlsClient)
            grpcConnection = GRPCConnection(tlsConnection: tlsConnection, configuration: grpcConfig, authority: authority)
        } else if let tunnel = self.tunnel {
            grpcConnection = GRPCConnection(tunnel: tunnel, configuration: grpcConfig, authority: authority)
        } else {
            let transport = TCPTransport(host: directDialHost, port: configuration.serverPort, resolvesViaProxyDNS: true)
            try await transport.connect()
            grpcConnection = GRPCConnection(transport: transport, configuration: grpcConfig, authority: authority)
        }

        do {
            try await grpcConnection.performSetup()
            let grpcProxyConnection = GRPCProxyConnection(grpcConnection: grpcConnection)
            return try await sendProtocolHandshake(
                over: grpcProxyConnection, request: request, supportsVision: transportSupportsVision
            )
        } catch {
            grpcConnection.cancel()
            throw error
        }
    }

    // MARK: - Direct Connection

    private func connectDirect(_ request: ProxyRequest) async throws -> ProxyConnection {
        let directProxyConnection: ProxyConnection
        let supportsVision = transportSupportsVision
        if let tunnel = self.tunnel {
            directProxyConnection = DirectProxyConnection(transport: TunneledTransport(tunnel: tunnel))
        } else {
            let transport = TCPTransport(host: directDialHost, port: configuration.serverPort, resolvesViaProxyDNS: true)
            try await transport.connect()
            directProxyConnection = DirectProxyConnection(transport: transport)
        }
        do {
            return try await sendProtocolHandshake(
                over: directProxyConnection, request: request, supportsVision: supportsVision
            )
        } catch {
            directProxyConnection.cancel()
            throw error
        }
    }

    // MARK: - gRPC Connection
    
    private func sanitizedGRPCTLSConfiguration(from base: TLSConfiguration) -> TLSConfiguration {
        TLSConfiguration(
            serverName: base.serverName,
            alpn: ["h2"],
            echEnabled: base.echEnabled,
            echConfig: base.echConfig,
            fingerprint: base.fingerprint
        )
    }

    // MARK: - XHTTP Connection

    private enum XHTTPHTTPVersion {
        case http11
        case http2
        case http3

        var logName: String {
            switch self {
            case .http11:
                return "http/1.1"
            case .http2:
                return "h2"
            case .http3:
                return "h3"
            }
        }
    }

    private func decideXHTTPHTTPVersion(for xraySecurityLayer: XraySecurityLayer? = nil) -> XHTTPHTTPVersion {
        let security = xraySecurityLayer ?? configuration.xraySecurityLayer
        if case .reality = security {
            return .http2
        }

        guard case .tls(let tlsConfig) = security else {
            return .http11
        }

        let alpn = tlsConfig.alpn ?? []
        guard alpn.count == 1 else {
            return .http2
        }

        switch alpn[0].lowercased() {
        case "http/1.1":
            return .http11
        case "h3":
            return .http3
        default:
            return .http2
        }
    }

    private func sanitizedXHTTPTLSConfiguration(
        from base: TLSConfiguration,
        httpVersion: XHTTPHTTPVersion
    ) -> TLSConfiguration {
        let sanitizedALPN: [String]?

        switch httpVersion {
        case .http11:
            sanitizedALPN = ["http/1.1"]
        case .http2:
            if let configuredALPN = base.alpn {
                let filtered = configuredALPN.filter {
                    $0.caseInsensitiveCompare("h2") == .orderedSame ||
                    $0.caseInsensitiveCompare("http/1.1") == .orderedSame
                }
                if filtered.isEmpty || (filtered.count == 1 && filtered[0].caseInsensitiveCompare("http/1.1") == .orderedSame) {
                    sanitizedALPN = ["h2", "http/1.1"]
                } else {
                    sanitizedALPN = filtered
                }
            } else {
                sanitizedALPN = nil
            }
        case .http3:
            sanitizedALPN = ["h3"]
        }

        return TLSConfiguration(
            serverName: base.serverName,
            alpn: sanitizedALPN,
            echEnabled: base.echEnabled,
            echConfig: base.echConfig,
            fingerprint: base.fingerprint
        )
    }

    private func connectWithXHTTP(_ request: ProxyRequest) async throws -> ProxyConnection {
        guard case .xhttp(let xhttpConfig) = configuration.xrayTransportLayer else {
            throw AnywhereError.proxy(.xhttp, .invalidConfiguration(detail: "XHTTP transport specified but no XHTTP configuration"))
        }

        let httpVersion = decideXHTTPHTTPVersion()

        var resolvedMode: XHTTPMode
        if xhttpConfig.mode == .auto {
            if case .reality = configuration.xraySecurityLayer {
                resolvedMode = .streamOne
            } else {
                resolvedMode = .packetUp
            }
        } else {
            resolvedMode = xhttpConfig.mode
        }
        
        if let downloadSettings = xhttpConfig.downloadSettings {
            if resolvedMode == .streamOne { resolvedMode = .streamUp }
            let downloadHTTPVersion = decideXHTTPHTTPVersion(for: downloadSettings.xraySecurityLayer)
            return try await connectXHTTPDetached(
                xhttpConfig: xhttpConfig, downloadSettings: downloadSettings,
                mode: resolvedMode, sessionId: xhttpConfig.generateSessionID(),
                mainHTTPVersion: httpVersion, downloadHTTPVersion: downloadHTTPVersion,
                request: request
            )
        }

        let sessionId = (resolvedMode == .packetUp || resolvedMode == .streamUp) ? xhttpConfig.generateSessionID() : ""
        return try await connectXHTTPCombined(
            xhttpConfig: xhttpConfig, mode: resolvedMode, sessionId: sessionId,
            httpVersion: httpVersion, request: request
        )
    }

    // MARK: Combined XHTTP

    private func connectXHTTPCombined(
        xhttpConfig: XHTTPConfiguration,
        mode: XHTTPMode,
        sessionId: String,
        httpVersion: XHTTPHTTPVersion,
        request: ProxyRequest
    ) async throws -> ProxyConnection {
        let route = consumeMainXHTTPRoute()
        let needsUploadFactory = httpVersion == .http11 && (mode == .packetUp || mode == .streamUp)
        let uploadFactory = needsUploadFactory
            ? makeXHTTPUploadFactory(
                security: configuration.xraySecurityLayer,
                httpVersion: httpVersion,
                mode: mode,
                xmux: xhttpConfig.effectiveXMUX
            )
            : nil
        let xhttpConnection = try await dialXHTTPLeg(
            endpoint: mainXHTTPEndpoint(),
            httpVersion: httpVersion,
            route: route,
            xhttp: xhttpConfig,
            mode: mode,
            sessionId: sessionId,
            role: .combined,
            uploadFactory: uploadFactory
        )
        do {
            return try await performXHTTPSetup(xhttpConnection: xhttpConnection, request: request)
        } catch {
            xhttpConnection.cancel()
            throw error
        }
    }

    private func performXHTTPSetup(
        xhttpConnection: XHTTPConnection,
        request: ProxyRequest
    ) async throws -> ProxyConnection {
        try await xhttpConnection.performSetup()
        let xhttpProxyConnection = XHTTPProxyConnection(xhttpConnection: xhttpConnection)
        return try await sendProtocolHandshake(
            over: xhttpProxyConnection,
            request: request,
            supportsVision: self.transportSupportsVision
        )
    }

    // MARK: XHTTP up/download detach

    private func connectXHTTPDetached(
        xhttpConfig: XHTTPConfiguration,
        downloadSettings: XHTTPDownloadSettings,
        mode: XHTTPMode,
        sessionId: String,
        mainHTTPVersion: XHTTPHTTPVersion,
        downloadHTTPVersion: XHTTPHTTPVersion,
        request: ProxyRequest
    ) async throws -> ProxyConnection {
        let uploadRoute = consumeMainXHTTPRoute()
        let uploadLeg = try await dialXHTTPLeg(
            endpoint: mainXHTTPEndpoint(),
            httpVersion: mainHTTPVersion,
            route: uploadRoute,
            xhttp: xhttpConfig,
            mode: mode,
            sessionId: sessionId,
            role: .uploadOnly,
            uploadFactory: nil
        )
        let downloadLeg: XHTTPConnection
        do {
            downloadLeg = try await dialXHTTPLeg(
                endpoint: self.downloadXHTTPEndpoint(downloadSettings),
                httpVersion: downloadHTTPVersion,
                route: .direct,
                xhttp: downloadSettings.xhttp,
                mode: mode,
                sessionId: sessionId,
                role: .downloadOnly,
                uploadFactory: nil
            )
        } catch {
            uploadLeg.cancel()
            throw error
        }
        downloadLeg.attachUploadChannel(uploadLeg)
        do {
            return try await performXHTTPSetup(xhttpConnection: downloadLeg, request: request)
        } catch {
            downloadLeg.cancel()
            throw error
        }
    }

    // MARK: XHTTP leg factory

    private struct XHTTPEndpoint {
        let directHost: String
        let chainHost: String
        let serverName: String
        let port: UInt16
        let security: XraySecurityLayer
    }

    private enum XHTTPLegRoute {
        case direct
        case overTunnel(ProxyConnection)
        case buildChain([ProxyConfiguration])
    }

    private enum XHTTPDialedTransport {
        case byteStream(any ByteTransport)
        case http3(HTTP3Multiplexer)
    }

    private func mainXHTTPEndpoint() -> XHTTPEndpoint {
        XHTTPEndpoint(
            directHost: directDialHost,
            chainHost: configuration.serverAddress,
            serverName: configuration.xraySecurityLayer.serverName(fallback: configuration.serverAddress),
            port: configuration.serverPort,
            security: configuration.xraySecurityLayer
        )
    }

    private func downloadXHTTPEndpoint(_ downloadSettings: XHTTPDownloadSettings) -> XHTTPEndpoint {
        XHTTPEndpoint(
            directHost: downloadSettings.serverAddress,
            chainHost: downloadSettings.serverAddress,
            serverName: downloadSettings.xraySecurityLayer.serverName(fallback: downloadSettings.serverAddress),
            port: downloadSettings.serverPort,
            security: downloadSettings.xraySecurityLayer
        )
    }

    private func consumeMainXHTTPRoute() -> XHTTPLegRoute {
        let takenTunnel: ProxyConnection? = state.withLock { state in
            let tunnel = state.tunnel
            state.tunnel = nil
            return tunnel
        }
        if let takenTunnel {
            return .overTunnel(takenTunnel)
        }
        if let chain = configuration.chain, !chain.isEmpty {
            return .buildChain(chain)
        }
        return .direct
    }

    private func dialXHTTPLeg(
        endpoint: XHTTPEndpoint,
        httpVersion: XHTTPHTTPVersion,
        route: XHTTPLegRoute,
        xhttp: XHTTPConfiguration,
        mode: XHTTPMode,
        sessionId: String,
        role: XHTTPChannelRole,
        uploadFactory: (@Sendable () async throws -> any ByteTransport)?
    ) async throws -> XHTTPConnection {
        if httpVersion == .http3, case .direct = route {
            return try await acquirePooledH3(
                endpoint: endpoint, xmux: xhttp.effectiveXMUX, xhttp: xhttp,
                mode: mode, sessionId: sessionId, role: role
            )
        }

        if httpVersion == .http2, case .direct = route {
            return try await acquirePooledH2(
                endpoint: endpoint, xmux: xhttp.effectiveXMUX, xhttp: xhttp,
                mode: mode, sessionId: sessionId, role: role
            )
        }

        let transport = try await dialXHTTPTransport(endpoint: endpoint, httpVersion: httpVersion, route: route)
        let connection: XHTTPConnection
        switch transport {
        case .byteStream(let closures):
            connection = XHTTPConnection(
                download: closures, configuration: xhttp, mode: mode, sessionId: sessionId,
                useHTTP2: httpVersion == .http2, uploadConnectionFactory: uploadFactory
            )
        case .http3(let session):
            connection = XHTTPConnection(
                h3Multiplexer: session, configuration: xhttp, mode: mode, sessionId: sessionId
            )
        }
        connection.configureRole(role)
        return connection
    }

    private func acquirePooledH3(
        endpoint: XHTTPEndpoint,
        xmux: XHTTPXMUXMultiplexerConfiguration,
        xhttp: XHTTPConfiguration,
        mode: XHTTPMode,
        sessionId: String,
        role: XHTTPChannelRole
    ) async throws -> XHTTPConnection {
        let host = endpoint.directHost
        let port = endpoint.port
        let serverName = endpoint.serverName
        let key = "h3|\(host)|\(port)|\(serverName)"
        let manager = XHTTPXMUXMultiplexerRegistry.shared.manager(key: key, config: xmux) {
            { () async -> XHTTPXMUXMultiplexerPoolable? in
                HTTP3Multiplexer(host: host, port: port, serverName: serverName)
            }
        }
        guard let lease = await manager.acquire(), let session = lease.connection as? HTTP3Multiplexer else {
            throw AnywhereError.transport(.connectionFailed(endpoint: "\(host):\(port)", detail: "xmux H3 session acquisition failed"))
        }
        let connection = XHTTPConnection(
            h3Multiplexer: session, configuration: xhttp, mode: mode, sessionId: sessionId
        )
        connection.configureRole(role)
        connection.configureXMUXLease(lease)
        return connection
    }

    private func acquirePooledH2(
        endpoint: XHTTPEndpoint,
        xmux: XHTTPXMUXMultiplexerConfiguration,
        xhttp: XHTTPConfiguration,
        mode: XHTTPMode,
        sessionId: String,
        role: XHTTPChannelRole
    ) async throws -> XHTTPConnection {
        let host = endpoint.directHost
        let port = endpoint.port
        let security = endpoint.security
        let serverName = endpoint.serverName
        let key = "h2|\(host)|\(port)|\(serverName)"
        let manager = XHTTPXMUXMultiplexerRegistry.shared.manager(key: key, config: xmux) {
            { () async -> XHTTPXMUXMultiplexerPoolable? in
                try? await ProxyClient.dialSharedH2(host: host, port: port, security: security)
            }
        }
        guard let lease = await manager.acquire(), let shared = lease.connection as? XHTTPH2Multiplexer else {
            throw AnywhereError.transport(.connectionFailed(endpoint: "\(host):\(port)", detail: "xmux H2 connection acquisition failed"))
        }
        let connection = XHTTPConnection(sharedH2: shared, configuration: xhttp, mode: mode, sessionId: sessionId)
        connection.configureRole(role)
        connection.configureXMUXLease(lease)
        return connection
    }

    private static func dialSharedH2(
        host: String,
        port: UInt16,
        security: XraySecurityLayer
    ) async throws -> XHTTPH2Multiplexer {
        func bringUp(_ transport: any ByteTransport, retaining object: (any Sendable)?) async throws -> XHTTPH2Multiplexer {
            let shared = XHTTPH2Multiplexer(transport: transport)
            if let object { shared.retain(object) }
            do {
                try await withDialDeadline(
                    .seconds(Self.sharedH2BringUpTimeout),
                    onExpiry: { shared.poolClose() },
                    error: {
                        AnywhereError.transport(
                            .timedOut(
                                .connect,
                                endpoint: "\(host):\(port)",
                                detail: "shared H2 settings")
                        )
                    }
                ) {
                    try await withTaskCancellationHandler {
                        try await shared.connect()
                    } onCancel: {
                        shared.poolClose()
                    }
                }
            } catch {
                shared.poolClose()
                throw error
            }
            return shared
        }
        switch security {
        case .none:
            let transport = TCPTransport(host: host, port: port, resolvesViaProxyDNS: true)
            try await transport.connect()
            return try await bringUp(transport, retaining: transport)
        case .tls(let tlsConfig):
            let h2TLS = TLSConfiguration(
                serverName: tlsConfig.serverName, alpn: ["h2", "http/1.1"],
                echEnabled: tlsConfig.echEnabled, echConfig: tlsConfig.echConfig, fingerprint: tlsConfig.fingerprint
            )
            let client = TLSClient(configuration: h2TLS)
            let connection = try await client.connect(host: host, port: port)
            return try await bringUp(TLSByteTransport(connection), retaining: client)
        case .reality(let realityConfig):
            let client = RealityClient(configuration: realityConfig)
            let connection = try await client.connect(host: host, port: port)
            return try await bringUp(TLSByteTransport(connection), retaining: client)
        }
    }

    private func dialXHTTPTransport(
        endpoint: XHTTPEndpoint,
        httpVersion: XHTTPHTTPVersion,
        route: XHTTPLegRoute
    ) async throws -> XHTTPDialedTransport {
        if httpVersion == .http3 {
            return try await dialXHTTPHTTP3Session(endpoint: endpoint, route: route)
        }
        switch route {
        case .direct:
            return try await dialXHTTPByteStream(
                host: endpoint.directHost,
                port: endpoint.port,
                security: endpoint.security,
                httpVersion: httpVersion,
                overTunnel: nil
            )
        case .overTunnel(let tunnel):
            return try await dialXHTTPByteStream(
                host: endpoint.chainHost,
                port: endpoint.port,
                security: endpoint.security,
                httpVersion: httpVersion,
                overTunnel: tunnel
            )
        case .buildChain(let chain):
            let hopNetworks = [ProxyNetwork](repeating: .tcp, count: chain.count)
            let tunnel = try await self.buildChainTunnel(chain: chain, index: 0, currentTunnel: nil, hopNetworks: hopNetworks)
            return try await dialXHTTPByteStream(
                host: endpoint.chainHost,
                port: endpoint.port,
                security: endpoint.security,
                httpVersion: httpVersion,
                overTunnel: tunnel
            )
        }
    }

    private func dialXHTTPByteStream(
        host: String,
        port: UInt16,
        security: XraySecurityLayer,
        httpVersion: XHTTPHTTPVersion,
        overTunnel: ProxyConnection?
    ) async throws -> XHTTPDialedTransport {
        switch security {
        case .none:
            if let tunnel = overTunnel {
                return .byteStream(TunneledTransport(tunnel: tunnel))
            } else {
                let transport = TCPTransport(host: host, port: port, resolvesViaProxyDNS: true)
                try await transport.connect()
                return .byteStream(transport)
            }
        case .tls(let tlsConfig):
            let client = TLSClient(configuration: sanitizedXHTTPTLSConfiguration(from: tlsConfig, httpVersion: httpVersion))
            let connection: TLSRecordConnection
            if let tunnel = overTunnel {
                connection = try await client.connect(overTunnel: tunnel)
            } else {
                connection = try await client.connect(host: host, port: port)
            }
            return .byteStream(TLSByteTransport(connection))
        case .reality(let realityConfig):
            let client = RealityClient(configuration: realityConfig)
            let connection: TLSRecordConnection
            if let tunnel = overTunnel {
                connection = try await client.connect(overTunnel: tunnel)
            } else {
                connection = try await client.connect(host: host, port: port)
            }
            return .byteStream(TLSByteTransport(connection))
        }
    }

    private func dialXHTTPHTTP3Session(
        endpoint: XHTTPEndpoint,
        route: XHTTPLegRoute
    ) async throws -> XHTTPDialedTransport {
        let makeSession: (String, QUICDatagramTransport?) -> XHTTPDialedTransport = { host, transport in
            .http3(HTTP3Multiplexer(host: host, port: endpoint.port, serverName: endpoint.serverName, transport: transport))
        }
        switch route {
        case .direct:
            return makeSession(endpoint.directHost, nil)
        case .overTunnel(let tunnel):
            return makeSession(endpoint.chainHost, ProxyConnectionDatagramTransport(connection: tunnel))
        case .buildChain(let chain):
            let hopNetworks = try Self.computeChainHopNetworks(chain: chain, lastDeliver: .udp).get()
            let tunnel = try await self.buildChainTunnel(chain: chain, index: 0, currentTunnel: nil, hopNetworks: hopNetworks)
            return makeSession(endpoint.chainHost, ProxyConnectionDatagramTransport(connection: tunnel))
        }
    }

    private func makeXHTTPUploadFactory(
        security: XraySecurityLayer,
        httpVersion: XHTTPHTTPVersion,
        mode: XHTTPMode,
        xmux: XHTTPXMUXMultiplexerConfiguration
    ) -> (@Sendable () async throws -> any ByteTransport) {
        let hasChain = (configuration.chain?.isEmpty == false)
        if mode == .packetUp, !hasChain {
            let endpoint = mainXHTTPEndpoint()
            let host = endpoint.directHost
            let port = endpoint.port
            let sec = endpoint.security
            let serverName = endpoint.serverName
            var uploadXMUX = xmux
            uploadXMUX.maxConcurrency = XHTTPXMUXMultiplexerRange(from: 1, to: 1)
            let key = "h1up|\(host)|\(port)|\(serverName)"
            let manager = XHTTPXMUXMultiplexerRegistry.shared.manager(key: key, config: uploadXMUX) {
                { () async -> XHTTPXMUXMultiplexerPoolable? in
                    await ProxyClient.dialH1UploadConnection(host: host, port: port, security: sec)
                }
            }
            return {
                try await ConnectionMetrics.$currentAttempt.withValue(nil) {
                    guard let lease = await manager.acquire(), let connection = lease.connection as? XHTTPH1Multiplexer else {
                        throw AnywhereError.transport(.connectionFailed(endpoint: "\(host):\(port)", detail: "xmux H1 upload acquisition failed"))
                    }
                    connection.adoptLease(lease)
                    return connection.sessionTransport
                }
            }
        }

        return { [weak self] in
            guard let self else {
                throw AnywhereError.transport(.terminated)
            }
            let route: XHTTPLegRoute
            if let chain = self.configuration.chain, !chain.isEmpty {
                route = .buildChain(chain)
            } else {
                route = .direct
            }
            let transport = try await ConnectionMetrics.$currentAttempt.withValue(nil) {
                try await self.dialXHTTPTransport(endpoint: self.mainXHTTPEndpoint(), httpVersion: httpVersion, route: route)
            }
            switch transport {
            case .byteStream(let closures):
                return closures
            case .http3:
                throw AnywhereError.proxy(.xhttp, .invalidConfiguration(detail: "HTTP/3 has no separate upload connection"))
            }
        }
    }

    private static func dialH1UploadConnection(
        host: String,
        port: UInt16,
        security: XraySecurityLayer
    ) async -> XHTTPH1Multiplexer? {
        func wrap(_ transport: any ByteTransport, retaining object: (any Sendable)?) -> XHTTPH1Multiplexer {
            let connection = XHTTPH1Multiplexer(transport: transport)
            if let object { connection.retain(object) }
            return connection
        }
        switch security {
        case .none:
            let transport = TCPTransport(host: host, port: port, resolvesViaProxyDNS: true)
            do {
                try await transport.connect()
            } catch {
                transport.cancel()
                return nil
            }
            return wrap(transport, retaining: transport)
        case .tls(let tlsConfig):
            let h1TLS = TLSConfiguration(
                serverName: tlsConfig.serverName, alpn: ["http/1.1"],
                echEnabled: tlsConfig.echEnabled, echConfig: tlsConfig.echConfig, fingerprint: tlsConfig.fingerprint
            )
            let client = TLSClient(configuration: h1TLS)
            guard let connection = try? await client.connect(host: host, port: port) else { return nil }
            return wrap(TLSByteTransport(connection), retaining: client)
        case .reality(let realityConfig):
            let client = RealityClient(configuration: realityConfig)
            guard let connection = try? await client.connect(host: host, port: port) else { return nil }
            return wrap(TLSByteTransport(connection), retaining: client)
        }
    }

}

// MARK: - Wire Mapping

nonisolated extension OutboundProtocol {
    fileprivate var wire: AnywhereError.Wire {
        switch self {
        case .nowhere: .nowhere
        case .vless: .vless
        case .hysteria: .hysteria
        case .sudoku: .sudoku
        case .trojan: .trojan
        case .anytls: .anyTLS
        case .shadowsocks: .shadowsocks
        case .socks5: .socks5
        case .rfc: .rfc
        }
    }
}
