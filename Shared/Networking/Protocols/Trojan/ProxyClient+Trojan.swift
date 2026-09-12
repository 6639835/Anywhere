//
//  ProxyClient+Trojan.swift
//  Anywhere
//
//  Created by NodePassProject on 4/22/26.
//

import Foundation

extension ProxyClient {
    func connectWithTrojan(_ request: ProxyRequest) async throws -> ProxyConnection {
        guard case .trojan(let password, let securityLayer) = configuration.outbound, !password.isEmpty,
              let tlsConfig = securityLayer.tlsConfiguration else {
            throw AnywhereError.proxy(.trojan, .protocolViolation(detail: "Trojan password not set"))
        }

        let tlsClient = TLSClient(configuration: tlsConfig)

        let tlsConnection: TLSRecordConnection
        if let tunnel = self.tunnel {
            tlsConnection = try await tlsClient.connect(overTunnel: tunnel)
        } else {
            tlsConnection = try await tlsClient.connect(host: directDialHost, port: configuration.serverPort)
        }

        let tlsProxyConnection = TLSProxyConnection(tlsConnection: tlsConnection)
        return try await wrapTrojan(over: tlsProxyConnection, password: password, request: request)
    }
    
    private func wrapTrojan(
        over tlsConnection: ProxyConnection,
        password: String,
        request: ProxyRequest
    ) async throws -> ProxyConnection {
        switch request.network {
        case .tcp:
            let trojan = TrojanConnection(
                inner: tlsConnection,
                password: password,
                destinationHost: request.host,
                destinationPort: request.port
            )
            if let initialData = request.initialData, !initialData.isEmpty {
                try await trojan.send(initialData)
            }
            return trojan
        case .udp:
            return TrojanUDPConnection(
                inner: tlsConnection,
                password: password,
                destinationHost: request.host,
                destinationPort: request.port
            )
        }
    }
}
