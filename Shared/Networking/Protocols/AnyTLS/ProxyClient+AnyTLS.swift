//
//  ProxyClient+AnyTLS.swift
//  Anywhere
//
//  Created by NodePassProject on 5/16/26.
//

import Foundation

nonisolated private let logger = AnywhereLogger(category: "ProxyClient+AnyTLS")

extension ProxyClient {
    func connectWithAnyTLS(_ request: ProxyRequest) async throws -> ProxyConnection {
        guard case .anytls(let password, _, _, _, let securityLayer) = configuration.outbound, !password.isEmpty,
              let tlsConfig = securityLayer.tlsConfiguration else {
            throw AnywhereError.proxy(.anyTLS, .protocolViolation(detail: "AnyTLS password not set"))
        }

        let directHost = directDialHost
        let directPort = configuration.serverPort
        let tunnel = self.tunnel

        let dialOut: AnyTLSMultiplexerPool.DialOut = {
            let tlsClient = TLSClient(configuration: tlsConfig)
            let tlsConnection: TLSRecordConnection
            if let tunnel {
                tlsConnection = try await tlsClient.connect(overTunnel: tunnel)
            } else {
                tlsConnection = try await tlsClient.connect(host: directHost, port: directPort)
            }
            return TLSProxyConnection(tlsConnection: tlsConnection)
        }

        guard let pool = AnyTLSMultiplexerRegistry.shared.pool(for: configuration, dialOut: dialOut) else {
            throw AnywhereError.proxy(.anyTLS, .notReady)
        }

        let stream = try await pool.acquireStream()
        guard !isCancelled else {
            stream.cancel()
            throw AnywhereError.transport(.terminated)
        }

        switch request.network {
        case .tcp:
            var bootstrap = AnyTLSProtocol.encodeAddrPort(host: request.host, port: request.port)
            if let initialData = request.initialData, !initialData.isEmpty {
                bootstrap.append(initialData)
            }
            do {
                try await stream.send(bootstrap)
            } catch {
                stream.cancel()
                throw error
            }
            return stream

        case .udp:
            var bootstrap = AnyTLSProtocol.encodeAddrPort(host: AnyTLSProtocol.uotMagicAddress, port: 0)
            bootstrap.append(0x01)
            bootstrap.append(AnyTLSProtocol.encodeAddrPort(host: request.host, port: request.port))
            do {
                try await stream.send(bootstrap)
            } catch {
                stream.cancel()
                throw error
            }
            return AnyTLSUDPConnection(inner: stream)
        }
    }
}
