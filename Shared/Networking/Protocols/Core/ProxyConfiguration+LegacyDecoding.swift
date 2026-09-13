//
//  ProxyConfiguration+LegacyDecoding.swift
//  Anywhere
//
//  Created by NodePassProject on 9/13/26.
//

import Foundation

// MARK: Remove in future build

nonisolated extension Outbound {
    private enum LegacyCodingKeys: String, CodingKey {
        case serverPort
        case outboundProtocol
        case nowhereKey, nowhereSNI, nowhereALPN, nowhereTCPPort, nowhereUDPPort, up, down, mux, morph
        case hysteriaPassword, hysteriaCongestionControl, hysteriaUploadMbps, hysteriaDownloadMbps
        case hysteriaObfs, hysteriaObfsPassword, hysteriaObfsMinPacketSize, hysteriaObfsMaxPacketSize
        case hysteriaSNI
        case sudoku
        case trojanPassword, trojanTLS
        case anytlsPassword, anytlsIdleCheckInterval, anytlsIdleTimeout, anytlsMinIdleSession, anytlsTLS
        case ssPassword, ssMethod
        case socks5Username, socks5Password
        case rfcUsername, rfcPassword, rfcSecurity, rfcTLS
    }

    init(legacyFrom decoder: Decoder, serverAddress: String, serverPort: UInt16) throws {
        let container = try decoder.container(keyedBy: LegacyCodingKeys.self)
        
        let `protocol` = try container.decodeIfPresent(OutboundProtocol.self, forKey: .outboundProtocol) ?? .vless

        switch `protocol` {
        case .nowhere:
            let explicitSNI = try container.decodeIfPresent(String.self, forKey: .nowhereSNI)
            _ = try container.decodeIfPresent(String.self, forKey: .nowhereALPN)
            let hasCarrierPorts = container.contains(.nowhereTCPPort) || container.contains(.nowhereUDPPort)
            let storedTCPPort = try container.decodeIfPresent(UInt16.self, forKey: .nowhereTCPPort)
            let storedUDPPort = try container.decodeIfPresent(UInt16.self, forKey: .nowhereUDPPort)
            let usesSeparatePorts = hasCarrierPorts && storedTCPPort != storedUDPPort
            let tcpPort = usesSeparatePorts ? storedTCPPort : serverPort
            let udpPort = usesSeparatePorts ? storedUDPPort : serverPort
            if serverPort == 0 {
                throw DecodingError.dataCorruptedError(
                    forKey: .serverPort,
                    in: container,
                    debugDescription: "Invalid zero Nowhere port"
                )
            }
            if storedTCPPort == 0 {
                throw DecodingError.dataCorruptedError(
                    forKey: .nowhereTCPPort,
                    in: container,
                    debugDescription: "Invalid zero Nowhere TCP port"
                )
            }
            if storedUDPPort == 0 {
                throw DecodingError.dataCorruptedError(
                    forKey: .nowhereUDPPort,
                    in: container,
                    debugDescription: "Invalid zero Nowhere UDP port"
                )
            }
            let rawUp = try container.decodeIfPresent(String.self, forKey: .up)
            let rawDown = try container.decodeIfPresent(String.self, forKey: .down)
            func decodeCarrier(_ value: String?, forKey key: LegacyCodingKeys) throws -> NowhereNetwork {
                guard let value else { return .tcp }
                guard let network = NowhereNetwork(rawValue: value) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: key,
                        in: container,
                        debugDescription: "Invalid Nowhere \(key.stringValue) value"
                    )
                }
                return network
            }
            let uplink = try decodeCarrier(rawUp, forKey: .up)
            let downlink = try decodeCarrier(rawDown, forKey: .down)
            let decodedMultiplex = try Self.decodeLegacyFlag(in: container, forKey: .mux, label: "mux")
            let decodedMorph = try Self.decodeLegacyFlag(in: container, forKey: .morph, label: "morph")
            guard tcpPort != nil || udpPort != nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .serverPort,
                    in: container,
                    debugDescription: "Nowhere requires at least one carrier port"
                )
            }
            guard (uplink == .tcp ? tcpPort : udpPort) != nil,
                  (downlink == .tcp ? tcpPort : udpPort) != nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .up,
                    in: container,
                    debugDescription: "Nowhere route uses an unavailable carrier"
                )
            }
            self = .nowhere(NowhereConfiguration(
                key: try container.decodeIfPresent(String.self, forKey: .nowhereKey) ?? "",
                tcpPort: usesSeparatePorts ? storedTCPPort : nil,
                udpPort: usesSeparatePorts ? storedUDPPort : nil,
                uplink: uplink,
                downlink: downlink,
                multiplex: decodedMultiplex,
                morph: decodedMorph,
                serverName: (explicitSNI?.isEmpty == false && explicitSNI != "none" ? explicitSNI : nil) ?? serverAddress
            ))

        case .vless:
            self = .vless(try VLESSConfiguration(from: decoder))

        case .hysteria:
            let explicitSNI = try container.decodeIfPresent(String.self, forKey: .hysteriaSNI)
            self = .hysteria(HysteriaConfiguration(
                password: try container.decodeIfPresent(String.self, forKey: .hysteriaPassword) ?? "",
                congestionControl: try container.decodeIfPresent(HysteriaCongestionControl.self, forKey: .hysteriaCongestionControl) ?? .brutal,
                uploadMbps: try container.decodeIfPresent(Int.self, forKey: .hysteriaUploadMbps)
                    ?? HysteriaCongestionControl.uploadMbpsDefault,
                downloadMbps: try container.decodeIfPresent(Int.self, forKey: .hysteriaDownloadMbps)
                    ?? HysteriaCongestionControl.downloadMbpsDefault,
                obfuscation: HysteriaObfuscation.make(
                    type: try container.decodeIfPresent(String.self, forKey: .hysteriaObfs),
                    password: try container.decodeIfPresent(String.self, forKey: .hysteriaObfsPassword),
                    geckoMinPacketSize: try container.decodeIfPresent(Int.self, forKey: .hysteriaObfsMinPacketSize),
                    geckoMaxPacketSize: try container.decodeIfPresent(Int.self, forKey: .hysteriaObfsMaxPacketSize)
                ),
                serverName: (explicitSNI?.isEmpty == false ? explicitSNI! : serverAddress)
            ))

        case .sudoku:
            self = .sudoku(try container.decode(SudokuConfiguration.self, forKey: .sudoku))

        case .trojan:
            self = .trojan(TrojanConfiguration(
                password: try container.decodeIfPresent(String.self, forKey: .trojanPassword) ?? "",
                tls: try container.decodeIfPresent(TLSConfiguration.self, forKey: .trojanTLS)
                    ?? TLSConfiguration(serverName: serverAddress)
            ))

        case .anytls:
            let tlsConfiguration = try container.decodeIfPresent(TLSConfiguration.self, forKey: .anytlsTLS)
                ?? TLSConfiguration(serverName: serverAddress)
            self = .anytls(AnyTLSConfiguration(
                password: try container.decodeIfPresent(String.self, forKey: .anytlsPassword) ?? "",
                idleCheckInterval: try container.decodeIfPresent(Int.self, forKey: .anytlsIdleCheckInterval)
                    ?? AnyTLSConfiguration.defaultIdleCheckInterval,
                idleTimeout: try container.decodeIfPresent(Int.self, forKey: .anytlsIdleTimeout)
                    ?? AnyTLSConfiguration.defaultIdleTimeout,
                minIdleSession: try container.decodeIfPresent(Int.self, forKey: .anytlsMinIdleSession)
                    ?? AnyTLSConfiguration.defaultMinIdleSession,
                securityLayer: .tls(tlsConfiguration)
            ))

        case .shadowsocks:
            self = .shadowsocks(ShadowsocksConfiguration(
                password: try container.decodeIfPresent(String.self, forKey: .ssPassword) ?? "",
                method: try container.decodeIfPresent(String.self, forKey: .ssMethod) ?? ""
            ))

        case .socks5:
            self = .socks5(SOCKS5Configuration(
                username: try container.decodeIfPresent(String.self, forKey: .socks5Username),
                password: try container.decodeIfPresent(String.self, forKey: .socks5Password)
            ))

        case .rfc:
            let securityTag = try container.decodeIfPresent(String.self, forKey: .rfcSecurity) ?? "tls"
            let securityLayer: GenericSecurityLayer
            if securityTag == "none" {
                securityLayer = .none
            } else {
                securityLayer = .tls(
                    try container.decodeIfPresent(TLSConfiguration.self, forKey: .rfcTLS)
                        ?? TLSConfiguration(serverName: serverAddress, alpn: RFCProtocol.defaultALPN)
                )
            }
            self = .rfc(RFCConfiguration(
                username: try container.decodeIfPresent(String.self, forKey: .rfcUsername),
                password: try container.decodeIfPresent(String.self, forKey: .rfcPassword),
                securityLayer: securityLayer
            ))
        }
    }
    
    private static func decodeLegacyFlag(
        in container: KeyedDecodingContainer<LegacyCodingKeys>,
        forKey key: LegacyCodingKeys,
        label: String
    ) throws -> Bool {
        guard container.contains(key), try !container.decodeNil(forKey: key) else { return false }
        if let value = try? container.decode(Bool.self, forKey: key) { return value }
        if let value = try? container.decode(Int.self, forKey: key), value == 0 || value == 1 {
            return value == 1
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "Invalid Nowhere \(label) value"
        )
    }
}

nonisolated extension ProxyConfiguration {
    static func legacyPayloadIDs(in payloads: [Data]) -> Set<UUID> {
        var ids: Set<UUID> = []
        for payload in payloads {
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  object["outbound"] == nil,
                  let id = (object["id"] as? String).flatMap(UUID.init(uuidString:))
            else { continue }
            ids.insert(id)
        }
        return ids
    }
}
