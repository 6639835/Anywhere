//
//  ProxyClient+VLESSTransport.swift
//  Anywhere
//
//  Created by NodePassProject on 9/13/26.
//

import Foundation

nonisolated extension ProxyClient {

    // MARK: - Entry point

    func connectWithVLESS(_ request: ProxyRequest) async throws -> ProxyConnection {
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
                return try await connectVLESSDirect(request)
            }
        }
    }

    // MARK: - Raw transport


    private func connectWithTLS(
        tlsConfig: TLSConfiguration,
        request: ProxyRequest
    ) async throws -> ProxyConnection {
        let tlsClient = TLSClient(configuration: tlsConfig)
        let tlsConnection = try await connectTLSRecord(tlsClient)
        let tlsProxyConnection = TLSProxyConnection(tlsConnection: tlsConnection)
        return try await sendVLESSProtocolHandshake(
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
        return try await sendVLESSProtocolHandshake(
            over: realityProxyConnection, request: request, supportsVision: true
        )
    }

    private func connectRealityRecord(_ realityClient: RealityClient) async throws -> TLSRecordConnection {
        if let tunnel = self.tunnel {
            return try await realityClient.connect(overTunnel: tunnel)
        } else {
            return try await realityClient.connect(host: self.directDialHost, port: self.configuration.serverPort)
        }
    }

    /// Raw TCP with no security layer: VLESS speaks straight over the byte stream.
    private func connectVLESSDirect(_ request: ProxyRequest) async throws -> ProxyConnection {
        let directProxyConnection = try await dialDirectProxyConnection()
        do {
            return try await sendVLESSProtocolHandshake(
                over: directProxyConnection, request: request, supportsVision: transportSupportsVision
            )
        } catch {
            directProxyConnection.cancel()
            throw error
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
            wsConnection = WebSocketConnection(transport: try await dialServerTransport(), configuration: wsConfig)
        }

        do {
            try await wsConnection.performUpgrade()
            let webSocketProxyConnection = WebSocketProxyConnection(wsConnection: wsConnection)
            return try await sendVLESSProtocolHandshake(
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
            huConnection = HTTPUpgradeConnection(transport: try await dialServerTransport(), configuration: huConfig)
        }

        do {
            try await huConnection.performUpgrade()
            let httpUpgradeProxyConnection = HTTPUpgradeProxyConnection(huConnection: huConnection)
            return try await sendVLESSProtocolHandshake(
                over: httpUpgradeProxyConnection, request: request, supportsVision: transportSupportsVision
            )
        } catch {
            huConnection.cancel()
            throw error
        }
    }

    // MARK: - gRPC Connection

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
            grpcConnection = GRPCConnection(
                transport: try await dialServerTransport(), configuration: grpcConfig, authority: authority
            )
        }

        do {
            try await grpcConnection.performSetup()
            let grpcProxyConnection = GRPCProxyConnection(grpcConnection: grpcConnection)
            return try await sendVLESSProtocolHandshake(
                over: grpcProxyConnection, request: request, supportsVision: transportSupportsVision
            )
        } catch {
            grpcConnection.cancel()
            throw error
        }
    }

    // MARK: - gRPC TLS

    private func sanitizedGRPCTLSConfiguration(from base: TLSConfiguration) -> TLSConfiguration {
        TLSConfiguration(
            serverName: base.serverName,
            alpn: ["h2"],
            echEnabled: base.echEnabled,
            echConfig: base.echConfig,
            fingerprint: base.fingerprint
        )
    }
}
