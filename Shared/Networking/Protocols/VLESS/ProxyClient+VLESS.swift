//
//  ProxyClient+VLESS.swift
//  Anywhere
//
//  Created by NodePassProject on 5/13/26.
//

import Foundation

nonisolated extension ProxyRequest {
    static let vlessMultiplexerCarrier = ProxyRequest(
        network: .tcp,
        host: VLESSProtocol.muxCoolHost,
        port: VLESSProtocol.muxCoolPort,
        isMultiplexerCarrier: true
    )
}

nonisolated extension ProxyClient {

    // MARK: - Mux carrier
    
    func connectVLESSMultiplexerCarrier() async throws -> ProxyConnection {
        guard configuration.outboundProtocol == .vless else {
            throw AnywhereError.proxy(configuration.outboundProtocol.wire, .protocolViolation(
                detail: "Mux is not supported with \(configuration.outboundProtocol.name)"
            ))
        }
        return try await dial(.vlessMultiplexerCarrier)
    }

    // MARK: - Vision flow

    var isVisionFlow: Bool { configuration.vless?.isVisionFlow ?? false }

    var hasVLESSEncryption: Bool { configuration.vless?.hasEncryption ?? false }

    var transportSupportsVision: Bool { configuration.vless?.transportSupportsVision ?? false }

    // MARK: - VLESS protocol handshake
    
    func sendVLESSProtocolHandshake(
        over connection: ProxyConnection,
        request: ProxyRequest,
        supportsVision: Bool
    ) async throws -> ProxyConnection {
        let vlessEncryption = configuration.vless?.encryption ?? "none"
        let encryptionConfig: VLESSEncryptionConfig?
        do {
            encryptionConfig = try VLESSEncryptionConfig.parse(vlessEncryption)
        } catch {
            throw AnywhereError.proxy(.vless, .protocolViolation(
                detail: "Invalid VLESS encryption: \(error.localizedDescription)"
            ))
        }
        if let encryptionConfig {
            guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) else {
                throw AnywhereError.proxy(.vless, .protocolViolation(
                    detail: "VLESS encryption requires iOS 26 / macOS 26 / tvOS 26 or later"
                ))
            }
            let client = try VLESSEncryptionClient(
                config: encryptionConfig,
                host: configuration.serverAddress,
                port: configuration.serverPort
            )
            let encryptedConnection = try await client.handshake(over: connection)
            return try await continueVLESSHandshake(
                over: encryptedConnection,
                request: request,
                supportsVision: supportsVision
            )
        }

        return try await continueVLESSHandshake(
            over: connection,
            request: request,
            supportsVision: supportsVision
        )
    }

    fileprivate func continueVLESSHandshake(
        over connection: ProxyConnection,
        request: ProxyRequest,
        supportsVision: Bool
    ) async throws -> ProxyConnection {
        let vlessUUID = configuration.vless?.uuid ?? configuration.id
        let command = VLESSCommand(request.network, isMultiplexerCarrier: request.isMultiplexerCarrier)
        let isVision = supportsVision && isVisionFlow && command != .udp

        let requestHeader = VLESSProtocol.encodeRequestHeader(
            uuid: vlessUUID,
            command: command,
            destinationAddress: request.host,
            destinationPort: request.port,
            flow: isVision ? VLESSConfiguration.visionFlow : nil
        )

        let vlessConnection = VLESSConnection(inner: connection)
        
        let handshakeInitialData = isVision ? nil : request.initialData
        do {
            try await vlessConnection.sendHandshake(requestHeader: requestHeader, initialData: handshakeInitialData)
        } catch {
            throw AnywhereError.capture(error, context: "VLESS handshake")
        }

        let proxyConnection: ProxyConnection = (command == .udp)
            ? VLESSUDPConnection(inner: vlessConnection)
            : vlessConnection

        if isVision {
            if let tlsError = validateOuterTLSForVision(proxyConnection) {
                throw tlsError
            }
            let vision = wrapWithVision(proxyConnection)
            do {
                if let initialData = request.initialData {
                    try await vision.sendRaw(initialData)
                } else {
                    try await vision.sendEmptyPadding()
                }
                return vision
            } catch {
                throw AnywhereError.capture(error, context: "VLESS Vision intro")
            }
        } else {
            return proxyConnection
        }
    }

    // MARK: - Vision
    
    fileprivate func validateOuterTLSForVision(_ connection: ProxyConnection) -> Error? {
        if hasVLESSEncryption {
            return nil
        }
        guard let version = connection.outerTLSVersion else {
            return AnywhereError.proxy(.vless, .protocolViolation(detail: "Vision requires outer TLS or REALITY transport"))
        }
        if version != .tls13 {
            return AnywhereError.proxy(.vless, .protocolViolation(detail: "Vision requires outer TLS 1.3, found \(version)"))
        }
        return nil
    }

    fileprivate func wrapWithVision(_ connection: ProxyConnection) -> VLESSVisionConnection {
        let vlessUUID = configuration.vless?.uuid ?? configuration.id
        let uuidBytes = vlessUUID.uuid
        let uuidData = Data([
            uuidBytes.0, uuidBytes.1, uuidBytes.2, uuidBytes.3,
            uuidBytes.4, uuidBytes.5, uuidBytes.6, uuidBytes.7,
            uuidBytes.8, uuidBytes.9, uuidBytes.10, uuidBytes.11,
            uuidBytes.12, uuidBytes.13, uuidBytes.14, uuidBytes.15
        ])
        return VLESSVisionConnection(connection: connection, userUUID: uuidData)
    }
}
