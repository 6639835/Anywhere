//
//  ProxyConfiguration.swift
//  Anywhere
//
//  Created by NodePassProject on 3/1/26.
//

import Foundation

nonisolated enum OutboundProtocol: String, Codable, CaseIterable {
    case nowhere
    case vless
    case hysteria
    case sudoku
    case trojan
    case anytls
    case shadowsocks
    case socks5
    case rfc

    enum InitialDataPolicy: Equatable {
        case none
        case unbounded
        case limited(Int)

        func prefixLength(for availableBytes: Int) -> Int {
            switch self {
            case .none: return 0
            case .unbounded: return availableBytes
            case .limited(let limit): return min(availableBytes, max(0, limit))
            }
        }
    }
    
    var initialDataPolicy: InitialDataPolicy {
        switch self {
        case .nowhere:
            return .limited(32 * 1024)
        case .vless, .sudoku:
            return .unbounded
        case .hysteria, .trojan, .anytls, .shadowsocks, .socks5, .rfc:
            return .none
        }
    }
    
    var supportsMux: Bool {
        self == .vless
    }
    
    func upstreamCommand(for downstreamCommand: ProxyCommand) -> ProxyCommand? {
        switch self {
        case .nowhere:
            return .udp
        case .vless, .trojan, .anytls:
            return .tcp
        case .shadowsocks:
            return downstreamCommand == .udp ? .udp : .tcp
        case .socks5:
            return .tcp
        case .hysteria:
            return .udp
        case .sudoku:
            return downstreamCommand == .tcp ? .tcp : nil
        case .rfc:
            return downstreamCommand == .tcp ? .tcp : nil
        }
    }

    var name: String {
        switch self {
        case .nowhere:
            "Nowhere"
        case .vless:
            "VLESS"
        case .hysteria:
            "Hysteria"
        case .sudoku:
            "Sudoku"
        case .trojan:
            "Trojan"
        case .anytls:
            "AnyTLS"
        case .shadowsocks:
            "Shadowsocks"
        case .socks5:
            "SOCKS5"
        case .rfc:
            "RFC"
        }
    }
}

// MARK: - Outbound Protocol Configuration

nonisolated enum Outbound: Hashable, Sendable {
    case nowhere(NowhereConfiguration)
    case vless(
        uuid: UUID,
        encryption: String,
        flow: String?,
        transport: XrayTransportLayer,
        security: XraySecurityLayer
    )
    case hysteria(
        password: String,
        congestionControl: HysteriaCongestionControl,
        uploadMbps: Int,
        downloadMbps: Int,
        obfuscation: HysteriaObfuscation?,
        sni: String
    )
    case sudoku(SudokuConfiguration)
    case trojan(password: String, securityLayer: GenericSecurityLayer)
    case anytls(
        password: String,
        idleCheckInterval: Int,
        idleTimeout: Int,
        minIdleSession: Int,
        securityLayer: GenericSecurityLayer
    )
    case shadowsocks(password: String, method: String)
    case socks5(username: String?, password: String?)
    case rfc(
        username: String?,
        password: String?,
        securityLayer: GenericSecurityLayer
    )
}

// MARK: - Xray Transport Layer Configuration

nonisolated enum XrayTransportLayer: Hashable, Sendable {
    case raw
    case ws(WebSocketConfiguration)
    case httpUpgrade(HTTPUpgradeConfiguration)
    case grpc(GRPCConfiguration)
    case xhttp(XHTTPConfiguration)
    
    var tag: String {
        switch self {
        case .raw:          "raw"
        case .ws:           "ws"
        case .httpUpgrade:  "httpupgrade"
        case .grpc:         "grpc"
        case .xhttp:        "xhttp"
        }
    }
}

// MARK: - Xray Security Layer Configuration

nonisolated enum XraySecurityLayer: Hashable, Sendable {
    case none
    case tls(TLSConfiguration)
    case reality(RealityConfiguration)
    
    var tag: String {
        switch self {
        case .none:     "none"
        case .tls:      "tls"
        case .reality:  "reality"
        }
    }
    
    func serverName(fallback: String) -> String {
        switch self {
        case .tls(let tls): return tls.serverName
        case .reality(let reality): return reality.serverName
        case .none: return fallback
        }
    }
}

// MARK: - Generic Security Layer Configuration

nonisolated enum GenericSecurityLayer: Hashable, Sendable {
    case tls(TLSConfiguration)
    case none
    
    var tag: String {
        switch self {
        case .tls:  "tls"
        case .none: "none"
        }
    }
    
    var tlsConfiguration: TLSConfiguration? {
        if case .tls(let tls) = self { return tls }
        return nil
    }
}

// MARK: - ProxyConfiguration

nonisolated struct ProxyConfiguration: Identifiable, Hashable, Codable, Sendable, SoftDeletable {
    let id: UUID
    let name: String
    let serverAddress: String
    let serverPort: UInt16
    let resolvedIP: String?
    let subscriptionId: UUID?
    let outbound: Outbound
    let chain: [ProxyConfiguration]?
    var updatedAt: Date
    var deletedAt: Date? = nil

    var connectAddress: String { resolvedIP ?? serverAddress }

    var outboundProtocol: OutboundProtocol {
        switch outbound {
        case .nowhere:      .nowhere
        case .vless:        .vless
        case .hysteria:     .hysteria
        case .sudoku:       .sudoku
        case .trojan:       .trojan
        case .anytls:       .anytls
        case .shadowsocks:  .shadowsocks
        case .socks5:       .socks5
        case .rfc:          .rfc
        }
    }
    
    var genericSecurityLayer: GenericSecurityLayer {
        switch outbound {
        case .nowhere(let configuration):        .tls(TLSConfiguration(serverName: configuration.serverName, alpn: [NowhereProtocol.defaultALPN], minVersion: .tls13, maxVersion: .tls13))
        case .trojan(_, let security):           security
        case .anytls(_, _, _, _, let security):  security
        case .rfc(_, _, let security):           security
        default:                                 .none
        }
    }
    
    var displayNetworkTag: String? {
        let tag: String?
        switch outboundProtocol {
        case .nowhere:
            switch (nowhereUplink, nowhereDownlink) {
            case (.tcp, .tcp):  tag = "TCP"
            case (.udp, .udp):  tag = "UDP"
            case (.tcp, .udp):  tag = "↑ TCP ↓ UDP"
            case (.udp, .tcp):  tag = "↑ UDP ↓ TCP"
            }
        case .vless:
            switch xrayTransportLayer {
            case .raw:          tag = "TCP"
            case .ws:           tag = "TCP"
            case .httpUpgrade:  tag = "TCP"
            case .grpc:         tag = "TCP"
            case .xhttp:        tag = nil
            }
        case .hysteria:         tag = "UDP"
        case .sudoku:           tag = "TCP"
        case .trojan:           tag = "TCP"
        case .anytls:           tag = "TCP"
        case .shadowsocks:      tag = nil
        case .socks5:           tag = nil
        case .rfc:              tag = "TCP"
        }
        return tag
    }

    var displayTransportLayerTag: String? {
        let tag: String?
        switch outboundProtocol {
        case .vless:
            switch xrayTransportLayer {
            case .raw:          tag = nil
            case .ws:           tag = "WebSocket"
            case .httpUpgrade:  tag = "HTTP Upgrade"
            case .grpc:         tag = "gRPC"
            case .xhttp:        tag = "XHTTP"
            }
        default:                tag = nil
        }
        return tag
    }

    var displaySecurityLayerTag: String? {
        let tag: String?
        switch outboundProtocol {
        case .nowhere:
            tag = "TLS"
        case .vless:
            switch xraySecurityLayer {
            case .none:         tag = nil
            case .tls:          tag = "TLS"
            case .reality:      tag = "Reality"
            }
        case .hysteria:         tag = "TLS"
        case .trojan, .anytls, .rfc:
            switch genericSecurityLayer {
            case .none:         tag = nil
            case .tls:          tag = "TLS"
            }
        default:                tag = nil
        }
        return tag
    }
    
    var nowhereUplink: NowhereNetwork {
        if case .nowhere(let configuration) = outbound { return configuration.uplink }
        return .udp
    }

    var nowhereDownlink: NowhereNetwork {
        if case .nowhere(let configuration) = outbound { return configuration.downlink }
        return .udp
    }

    var nowhereMultiplex: Bool {
        if case .nowhere(let configuration) = outbound {
            return configuration.multiplex
        }
        return false
    }

    var nowhereMorph: Bool {
        if case .nowhere(let configuration) = outbound { return configuration.morph }
        return false
    }

    var hasVisionFlow: Bool {
        if case .vless(_, _, let flow?, _, _) = outbound {
            return flow.uppercased().contains("VISION")
        }
        return false
    }

    var xrayTransportLayer: XrayTransportLayer {
        if case .vless(_, _, _, let t, _) = outbound { return t }
        return .raw
    }
    
    var xraySecurityLayer: XraySecurityLayer {
        if case .vless(_, _, _, _, let s) = outbound { return s }
        return .none
    }
    
    var isXHTTPOverHTTP3: Bool {
        guard case .xhttp = xrayTransportLayer else { return false }
        guard case .tls(let tls) = xraySecurityLayer else { return false }
        let alpn = tls.alpn ?? []
        return alpn.count == 1 && alpn[0].caseInsensitiveCompare("h3") == .orderedSame
    }
    
    func upstreamCommand(for downstreamCommand: ProxyCommand) -> ProxyCommand? {
        if isXHTTPOverHTTP3 { return .udp }
        if outboundProtocol == .nowhere {
            switch nowhereUplink {
            case .udp:
                return .udp
            case .tcp:
                if downstreamCommand == .tcp { return .tcp }
                if downstreamCommand == .udp { return .tcp }
                return nil
            }
        }
        return outboundProtocol.upstreamCommand(for: downstreamCommand)
    }

    init(
        id: UUID = UUID(),
        name: String,
        serverAddress: String,
        serverPort: UInt16,
        resolvedIP: String? = nil,
        subscriptionId: UUID? = nil,
        outbound: Outbound,
        chain: [ProxyConfiguration]? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.serverAddress = serverAddress
        self.serverPort = serverPort
        self.resolvedIP = resolvedIP
        self.subscriptionId = subscriptionId
        self.outbound = outbound
        self.chain = chain
        self.updatedAt = updatedAt
    }

    func withChain(_ chain: [ProxyConfiguration]?) -> ProxyConfiguration {
        ProxyConfiguration(
            id: id, name: name, serverAddress: serverAddress, serverPort: serverPort,
            resolvedIP: resolvedIP, subscriptionId: subscriptionId,
            outbound: outbound, chain: chain, updatedAt: updatedAt
        )
    }

    func withResolvedIP(_ resolvedIP: String?) -> ProxyConfiguration {
        ProxyConfiguration(
            id: id, name: name, serverAddress: serverAddress, serverPort: serverPort,
            resolvedIP: resolvedIP, subscriptionId: subscriptionId,
            outbound: outbound, chain: chain, updatedAt: updatedAt
        )
    }
    
    func contentEquals(_ other: ProxyConfiguration) -> Bool {
        name == other.name &&
        serverAddress == other.serverAddress &&
        serverPort == other.serverPort &&
        outbound == other.outbound &&
        chain == other.chain
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, serverAddress, serverPort, resolvedIP, subscriptionId
        case nowhereKey, nowhereSNI, nowhereALPN, nowhereTCPPort, nowhereUDPPort, up, down, mux, morph
        case outboundProtocol, uuid, encryption, flow
        case transport, websocket, httpUpgrade, grpc, xhttp
        case security, tls, reality
        case hysteriaPassword, hysteriaCongestionControl, hysteriaUploadMbps, hysteriaDownloadMbps
        case hysteriaObfs, hysteriaObfsPassword, hysteriaObfsMinPacketSize, hysteriaObfsMaxPacketSize
        case hysteriaSNI
        case sudoku
        case trojanPassword, trojanTLS
        case anytlsPassword, anytlsIdleCheckInterval, anytlsIdleTimeout, anytlsMinIdleSession, anytlsTLS
        case ssPassword, ssMethod
        case socks5Username, socks5Password
        case rfcUsername, rfcPassword, rfcSecurity, rfcTLS
        case chain
        case updatedAt
        case deletedAt
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        serverAddress = try container.decode(String.self, forKey: .serverAddress)
        let decodedServerPort = try container.decode(UInt16.self, forKey: .serverPort)
        resolvedIP = try container.decodeIfPresent(String.self, forKey: .resolvedIP)
        subscriptionId = try container.decodeIfPresent(UUID.self, forKey: .subscriptionId)

        let `protocol` = try container.decodeIfPresent(OutboundProtocol.self, forKey: .outboundProtocol) ?? .vless

        switch `protocol` {
        case .nowhere:
            let explicitSNI = try container.decodeIfPresent(String.self, forKey: .nowhereSNI)
            _ = try container.decodeIfPresent(String.self, forKey: .nowhereALPN)
            let hasCarrierPorts = container.contains(.nowhereTCPPort) || container.contains(.nowhereUDPPort)
            let storedTCPPort = try container.decodeIfPresent(UInt16.self, forKey: .nowhereTCPPort)
            let storedUDPPort = try container.decodeIfPresent(UInt16.self, forKey: .nowhereUDPPort)
            let usesSeparatePorts = hasCarrierPorts && storedTCPPort != storedUDPPort
            let tcpPort = usesSeparatePorts ? storedTCPPort : decodedServerPort
            let udpPort = usesSeparatePorts ? storedUDPPort : decodedServerPort
            if decodedServerPort == 0 {
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
            func decodeCarrier(_ value: String?, forKey key: CodingKeys) throws -> NowhereNetwork {
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
            let decodedMultiplex: Bool
            if !container.contains(.mux) {
                decodedMultiplex = false
            } else if try container.decodeNil(forKey: .mux) {
                decodedMultiplex = false
            } else if let value = try? container.decode(Bool.self, forKey: .mux) {
                decodedMultiplex = value
            } else if let value = try? container.decode(Int.self, forKey: .mux), value == 0 || value == 1 {
                decodedMultiplex = value == 1
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .mux,
                    in: container,
                    debugDescription: "Invalid Nowhere mux value"
                )
            }
            let decodedMorph: Bool
            let morphMissing = !container.contains(.morph)
            let morphNull = morphMissing ? false : try container.decodeNil(forKey: .morph)
            if morphMissing || morphNull {
                decodedMorph = false
            } else if let value = try? container.decode(Bool.self, forKey: .morph) {
                decodedMorph = value
            } else if let value = try? container.decode(Int.self, forKey: .morph), value == 0 || value == 1 {
                decodedMorph = value == 1
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .morph,
                    in: container,
                    debugDescription: "Invalid Nowhere morph value"
                )
            }
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
            outbound = .nowhere(NowhereConfiguration(
                key: try container.decodeIfPresent(String.self, forKey: .nowhereKey) ?? "",
                tcpPort: usesSeparatePorts ? storedTCPPort : nil,
                udpPort: usesSeparatePorts ? storedUDPPort : nil,
                uplink: uplink,
                downlink: downlink,
                multiplex: (uplink == .tcp || downlink == .tcp) && decodedMultiplex,
                morph: decodedMorph,
                serverName: (explicitSNI?.isEmpty == false && explicitSNI != "none" ? explicitSNI : nil) ?? serverAddress
            ))

        case .vless:
            let transportLayerString = try container.decodeIfPresent(String.self, forKey: .transport) ?? "tcp"
            let transport: XrayTransportLayer
            switch transportLayerString {
            case "ws":
                transport = (try container.decodeIfPresent(WebSocketConfiguration.self, forKey: .websocket)).map { .ws($0) } ?? .raw
            case "httpupgrade":
                transport = (try container.decodeIfPresent(HTTPUpgradeConfiguration.self, forKey: .httpUpgrade)).map { .httpUpgrade($0) } ?? .raw
            case "grpc":
                transport = (try container.decodeIfPresent(GRPCConfiguration.self, forKey: .grpc)).map { .grpc($0) } ?? .raw
            case "xhttp":
                transport = (try container.decodeIfPresent(XHTTPConfiguration.self, forKey: .xhttp)).map { .xhttp($0) } ?? .raw
            default:
                transport = .raw
            }
            let securityLayerString = try container.decodeIfPresent(String.self, forKey: .security) ?? "none"
            let security: XraySecurityLayer
            switch securityLayerString {
            case "tls":
                security = (try container.decodeIfPresent(TLSConfiguration.self, forKey: .tls)).map { .tls($0) } ?? .none
            case "reality":
                security = (try container.decodeIfPresent(RealityConfiguration.self, forKey: .reality)).map { .reality($0) } ?? .none
            default:
                security = .none
            }
            outbound = .vless(
                uuid: try container.decode(UUID.self, forKey: .uuid),
                encryption: try container.decode(String.self, forKey: .encryption),
                flow: try container.decodeIfPresent(String.self, forKey: .flow),
                transport: transport,
                security: security
            )

        case .hysteria:
            let congestionControl = try container.decodeIfPresent(HysteriaCongestionControl.self, forKey: .hysteriaCongestionControl) ?? .brutal
            let rawUp = try container.decodeIfPresent(Int.self, forKey: .hysteriaUploadMbps)
                ?? HysteriaCongestionControl.uploadMbpsDefault
            let rawDown = try container.decodeIfPresent(Int.self, forKey: .hysteriaDownloadMbps)
                ?? HysteriaCongestionControl.downloadMbpsDefault
            let obfsType = try container.decodeIfPresent(String.self, forKey: .hysteriaObfs)
            let obfsPassword = try container.decodeIfPresent(String.self, forKey: .hysteriaObfsPassword)
            let obfsMin = try container.decodeIfPresent(Int.self, forKey: .hysteriaObfsMinPacketSize)
            let obfsMax = try container.decodeIfPresent(Int.self, forKey: .hysteriaObfsMaxPacketSize)
            let explicitSNI = try container.decodeIfPresent(String.self, forKey: .hysteriaSNI)
            outbound = .hysteria(
                password: try container.decodeIfPresent(String.self, forKey: .hysteriaPassword) ?? "",
                congestionControl: congestionControl,
                uploadMbps: HysteriaCongestionControl.clampUploadMbps(rawUp),
                downloadMbps: HysteriaCongestionControl.clampDownloadMbps(rawDown),
                obfuscation: HysteriaObfuscation.make(
                    type: obfsType,
                    password: obfsPassword,
                    geckoMinPacketSize: obfsMin,
                    geckoMaxPacketSize: obfsMax
                ),
                sni: (explicitSNI?.isEmpty == false ? explicitSNI! : serverAddress)
            )
            
        case .sudoku:
            outbound = .sudoku(try container.decode(SudokuConfiguration.self, forKey: .sudoku))
            
        case .trojan:
            let password = try container.decodeIfPresent(String.self, forKey: .trojanPassword) ?? ""
            // TLS is mandatory; fall back to SNI=serverAddress so partial configs decode cleanly.
            let tlsConfiguration = try container.decodeIfPresent(TLSConfiguration.self, forKey: .trojanTLS)
                ?? TLSConfiguration(serverName: serverAddress)
            outbound = .trojan(password: password, securityLayer: .tls(tlsConfiguration))

        case .anytls:
            let password = try container.decodeIfPresent(String.self, forKey: .anytlsPassword) ?? ""
            // Stored unclamped so the JSON round-trips exactly; AnyTLSMultiplexerPool clamps at use time.
            let idleCheckInterval = try container.decodeIfPresent(Int.self, forKey: .anytlsIdleCheckInterval) ?? 30
            let idleTimeout  = try container.decodeIfPresent(Int.self, forKey: .anytlsIdleTimeout) ?? 30
            let minIdleSession = try container.decodeIfPresent(Int.self, forKey: .anytlsMinIdleSession) ?? 0
            let tlsConfiguration = try container.decodeIfPresent(TLSConfiguration.self, forKey: .anytlsTLS)
                ?? TLSConfiguration(serverName: serverAddress)
            outbound = .anytls(
                password: password,
                idleCheckInterval: idleCheckInterval,
                idleTimeout: idleTimeout,
                minIdleSession: minIdleSession,
                securityLayer: .tls(tlsConfiguration)
            )

        case .shadowsocks:
            outbound = .shadowsocks(
                password: try container.decodeIfPresent(String.self, forKey: .ssPassword) ?? "",
                method: try container.decodeIfPresent(String.self, forKey: .ssMethod) ?? ""
            )
            
        case .socks5:
            outbound = .socks5(
                username: try container.decodeIfPresent(String.self, forKey: .socks5Username),
                password: try container.decodeIfPresent(String.self, forKey: .socks5Password)
            )

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
            outbound = .rfc(
                username: try container.decodeIfPresent(String.self, forKey: .rfcUsername),
                password: try container.decodeIfPresent(String.self, forKey: .rfcPassword),
                securityLayer: securityLayer
            )
        }

        serverPort = decodedServerPort

        chain = try container.decodeIfPresent([ProxyConfiguration].self, forKey: .chain)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? deletedAt ?? .distantPast
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(serverAddress, forKey: .serverAddress)
        try container.encode(serverPort, forKey: .serverPort)
        try container.encodeIfPresent(resolvedIP, forKey: .resolvedIP)
        try container.encodeIfPresent(subscriptionId, forKey: .subscriptionId)

        try container.encode(outboundProtocol, forKey: .outboundProtocol)
        
        switch outbound {
        case .nowhere(let configuration):
            try container.encode(id, forKey: .uuid)
            try container.encode("none", forKey: .encryption)
            try container.encode(configuration.key, forKey: .nowhereKey)
            try container.encodeIfPresent(configuration.tcpPort, forKey: .nowhereTCPPort)
            try container.encodeIfPresent(configuration.udpPort, forKey: .nowhereUDPPort)
            try container.encode(configuration.uplink.rawValue, forKey: .up)
            try container.encode(configuration.downlink.rawValue, forKey: .down)
            try container.encode(configuration.multiplex, forKey: .mux)
            try container.encode(configuration.morph, forKey: .morph)
            try container.encode(configuration.serverName, forKey: .nowhereSNI)
        case .vless(let uuid, let encryption, let flow, let transport, let security):
            try container.encode(uuid, forKey: .uuid)
            try container.encode(encryption, forKey: .encryption)
            try container.encodeIfPresent(flow, forKey: .flow)

            try container.encode(transport.tag, forKey: .transport)
            switch transport {
            case .raw: break
            case .ws(let config): try container.encode(config, forKey: .websocket)
            case .httpUpgrade(let config): try container.encode(config, forKey: .httpUpgrade)
            case .grpc(let config): try container.encode(config, forKey: .grpc)
            case .xhttp(let config): try container.encode(config, forKey: .xhttp)
            }

            try container.encode(security.tag, forKey: .security)
            switch security {
            case .none: break
            case .tls(let config): try container.encode(config, forKey: .tls)
            case .reality(let config): try container.encode(config, forKey: .reality)
            }
        case .hysteria(let password, let congestionControl, let uploadMbps, let downloadMbps, let obfuscation, let sni):
            try container.encode(id, forKey: .uuid)
            try container.encode("none", forKey: .encryption)
            try container.encode(password, forKey: .hysteriaPassword)
            try container.encode(congestionControl, forKey: .hysteriaCongestionControl)
            try container.encode(uploadMbps, forKey: .hysteriaUploadMbps)
            try container.encode(downloadMbps, forKey: .hysteriaDownloadMbps)
            if let obfuscation {
                try container.encode(obfuscation.typeTag, forKey: .hysteriaObfs)
                try container.encode(obfuscation.password, forKey: .hysteriaObfsPassword)
                if case .gecko(_, let minPacketSize, let maxPacketSize) = obfuscation {
                    try container.encode(minPacketSize, forKey: .hysteriaObfsMinPacketSize)
                    try container.encode(maxPacketSize, forKey: .hysteriaObfsMaxPacketSize)
                }
            }
            try container.encode(sni, forKey: .hysteriaSNI)
        case .sudoku(let configuration):
            try container.encode(id, forKey: .uuid)
            try container.encode("none", forKey: .encryption)
            try container.encode(configuration, forKey: .sudoku)
        case .trojan(let password, let securityLayer):
            let tls = securityLayer.tlsConfiguration ?? TLSConfiguration(serverName: serverAddress)
            try container.encode(id, forKey: .uuid)
            try container.encode("none", forKey: .encryption)
            try container.encode(password, forKey: .trojanPassword)
            try container.encode(tls, forKey: .trojanTLS)
        case .anytls(let password, let idleCheckInterval, let idleTimeout, let minIdleSession, let securityLayer):
            let tls = securityLayer.tlsConfiguration ?? TLSConfiguration(serverName: serverAddress)
            try container.encode(id, forKey: .uuid)
            try container.encode("none", forKey: .encryption)
            try container.encode(password, forKey: .anytlsPassword)
            try container.encode(idleCheckInterval, forKey: .anytlsIdleCheckInterval)
            try container.encode(idleTimeout, forKey: .anytlsIdleTimeout)
            try container.encode(minIdleSession, forKey: .anytlsMinIdleSession)
            try container.encode(tls, forKey: .anytlsTLS)
        case .shadowsocks(let password, let method):
            try container.encode(id, forKey: .uuid)
            try container.encode("none", forKey: .encryption)
            try container.encode(password, forKey: .ssPassword)
            try container.encode(method, forKey: .ssMethod)
        case .socks5(let username, let password):
            try container.encode(id, forKey: .uuid)
            try container.encode("none", forKey: .encryption)
            try container.encodeIfPresent(username, forKey: .socks5Username)
            try container.encodeIfPresent(password, forKey: .socks5Password)
        case .rfc(let username, let password, let securityLayer):
            try container.encode(id, forKey: .uuid)
            try container.encode("none", forKey: .encryption)
            try container.encodeIfPresent(username, forKey: .rfcUsername)
            try container.encodeIfPresent(password, forKey: .rfcPassword)
            try container.encode(securityLayer.tag, forKey: .rfcSecurity)
            if let tls = securityLayer.tlsConfiguration {
                try container.encode(tls, forKey: .rfcTLS)
            }
        }

        try container.encodeIfPresent(chain, forKey: .chain)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }
}
