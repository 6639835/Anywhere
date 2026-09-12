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
        isVLESSMultiplexerCarrier: true
    )
}

nonisolated extension ProxyClient {

    // MARK: - Vision flow
    
    fileprivate static let visionFlow = "xtls-rprx-vision"

    var isVisionFlow: Bool {
        guard case .vless(_, _, let flow, _, _) = configuration.outbound else { return false }
        return flow == Self.visionFlow
    }

    var hasVLESSEncryption: Bool {
        guard case .vless(_, let encryption, _, _, _) = configuration.outbound else { return false }
        return !encryption.isEmpty && encryption != "none"
    }
    
    var transportSupportsVision: Bool {
        if hasVLESSEncryption { return true }
        if case .raw = configuration.xrayTransportLayer { return true }
        return false
    }

    // MARK: - VLESS protocol handshake
    
    func sendVLESSProtocolHandshake(
        over connection: ProxyConnection,
        request: ProxyRequest,
        supportsVision: Bool
    ) async throws -> ProxyConnection {
        let vlessEncryption: String
        if case .vless(_, let encryption, _, _, _) = configuration.outbound {
            vlessEncryption = encryption
        } else {
            vlessEncryption = "none"
        }
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
        let vlessUUID: UUID
        if case .vless(let uuid, _, _, _, _) = configuration.outbound {
            vlessUUID = uuid
        } else {
            vlessUUID = configuration.id
        }
        let command = VLESSCommand(request.network, isVLESSMultiplexerCarrier: request.isVLESSMultiplexerCarrier)
        let isVision = supportsVision && isVisionFlow && command != .udp

        let requestHeader = VLESSProtocol.encodeRequestHeader(
            uuid: vlessUUID,
            command: command,
            destinationAddress: request.host,
            destinationPort: request.port,
            flow: isVision ? Self.visionFlow : nil
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
        let vlessUUID: UUID
        if case .vless(let uuid, _, _, _, _) = configuration.outbound {
            vlessUUID = uuid
        } else {
            vlessUUID = configuration.id
        }
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
