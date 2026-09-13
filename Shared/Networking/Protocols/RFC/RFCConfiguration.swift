//
//  RFCConfiguration.swift
//  Anywhere
//
//  Created by NodePassProject on 9/13/26.
//

import Foundation

nonisolated struct RFCConfiguration: Hashable, Sendable {
    let username: String?
    let password: String?
    
    let securityLayer: GenericSecurityLayer

    init(username: String? = nil, password: String? = nil, securityLayer: GenericSecurityLayer) {
        self.username = username
        self.password = password
        self.securityLayer = securityLayer
    }

    var tlsConfiguration: TLSConfiguration? { securityLayer.tlsConfiguration }

    var basicCredentials: String? {
        RFCProtocol.basicCredentials(username: username, password: password)
    }
}

nonisolated extension RFCConfiguration: Codable {
    private enum CodingKeys: String, CodingKey {
        case username, password, security
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            username: try container.decodeIfPresent(String.self, forKey: .username),
            password: try container.decodeIfPresent(String.self, forKey: .password),
            securityLayer: try container.decode(GenericSecurityLayer.self, forKey: .security)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encodeIfPresent(password, forKey: .password)
        try container.encode(securityLayer, forKey: .security)
    }
}
