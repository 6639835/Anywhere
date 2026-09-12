//
//  VLESSConfiguration.swift
//  Anywhere
//
//  Created by NodePassProject on 9/13/26.
//

import Foundation

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

// MARK: - VLESSConfiguration

nonisolated struct VLESSConfiguration: Hashable, Sendable {

    static let visionFlow = "xtls-rprx-vision"

    let uuid: UUID
    let encryption: String
    let flow: String?
    let transport: XrayTransportLayer
    let security: XraySecurityLayer

    init(
        uuid: UUID,
        encryption: String,
        flow: String?,
        transport: XrayTransportLayer,
        security: XraySecurityLayer
    ) {
        self.uuid = uuid
        self.encryption = encryption
        self.flow = flow
        self.transport = transport
        self.security = security
    }

    // MARK: - Flow
    
    var hasVisionFlow: Bool {
        guard let flow else { return false }
        return flow.uppercased().contains("VISION")
    }
    
    var isVisionFlow: Bool { flow == Self.visionFlow }

    // MARK: - Encryption

    var hasEncryption: Bool { !encryption.isEmpty && encryption != "none" }
    
    var transportSupportsVision: Bool {
        if hasEncryption { return true }
        if case .raw = transport { return true }
        return false
    }

    // MARK: - Transport shape

    var isXHTTPOverHTTP3: Bool {
        guard case .xhttp = transport else { return false }
        guard case .tls(let tls) = security else { return false }
        let alpn = tls.alpn ?? []
        return alpn.count == 1 && alpn[0].caseInsensitiveCompare("h3") == .orderedSame
    }

    // MARK: - Display

    var displayNetworkTag: String? {
        switch transport {
        case .raw:          "TCP"
        case .ws:           "TCP"
        case .httpUpgrade:  "TCP"
        case .grpc:         "TCP"
        case .xhttp:        nil
        }
    }

    var displayTransportLayerTag: String? {
        switch transport {
        case .raw:          nil
        case .ws:           "WebSocket"
        case .httpUpgrade:  "HTTP Upgrade"
        case .grpc:         "gRPC"
        case .xhttp:        "XHTTP"
        }
    }

    var displaySecurityLayerTag: String? {
        switch security {
        case .none:         nil
        case .tls:          "TLS"
        case .reality:      "Reality"
        }
    }
}

// MARK: - Codable

nonisolated extension VLESSConfiguration: Codable {
    enum CodingKeys: String, CodingKey {
        case uuid, encryption, flow
        case transport, websocket, httpUpgrade, grpc, xhttp
        case security, tls, reality
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

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

        self.init(
            uuid: try container.decode(UUID.self, forKey: .uuid),
            encryption: try container.decode(String.self, forKey: .encryption),
            flow: try container.decodeIfPresent(String.self, forKey: .flow),
            transport: transport,
            security: security
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

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
    }
}
