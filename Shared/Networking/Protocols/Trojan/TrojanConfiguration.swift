//
//  TrojanConfiguration.swift
//  Anywhere
//
//  Created by NodePassProject on 9/13/26.
//

import Foundation

nonisolated struct TrojanConfiguration: Hashable, Sendable {
    let password: String
    
    let securityLayer: GenericSecurityLayer

    init(password: String, securityLayer: GenericSecurityLayer) {
        self.password = password
        self.securityLayer = securityLayer
    }

    init(password: String, tls: TLSConfiguration) {
        self.init(password: password, securityLayer: .tls(tls))
    }

    var tlsConfiguration: TLSConfiguration? { securityLayer.tlsConfiguration }
}

nonisolated extension TrojanConfiguration: Codable {
    private enum CodingKeys: String, CodingKey {
        case password, security
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            password: try container.decode(String.self, forKey: .password),
            securityLayer: try container.decode(GenericSecurityLayer.self, forKey: .security)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(password, forKey: .password)
        try container.encode(securityLayer, forKey: .security)
    }
}
