//
//  AnyTLSConfiguration.swift
//  Anywhere
//
//  Created by NodePassProject on 9/13/26.
//

import Foundation

nonisolated struct AnyTLSConfiguration: Hashable, Sendable {
    static let defaultIdleCheckInterval = 30
    static let defaultIdleTimeout = 30
    static let defaultMinIdleSession = 0

    let password: String
    
    let idleCheckInterval: Int
    let idleTimeout: Int
    let minIdleSession: Int
    
    let securityLayer: GenericSecurityLayer

    init(
        password: String,
        idleCheckInterval: Int = Self.defaultIdleCheckInterval,
        idleTimeout: Int = Self.defaultIdleTimeout,
        minIdleSession: Int = Self.defaultMinIdleSession,
        securityLayer: GenericSecurityLayer
    ) {
        self.password = password
        self.idleCheckInterval = idleCheckInterval
        self.idleTimeout = idleTimeout
        self.minIdleSession = minIdleSession
        self.securityLayer = securityLayer
    }
    
    init(
        password: String,
        securityLayer: GenericSecurityLayer,
        inheritingTuningFrom base: AnyTLSConfiguration?
    ) {
        self.init(
            password: password,
            idleCheckInterval: base?.idleCheckInterval ?? Self.defaultIdleCheckInterval,
            idleTimeout: base?.idleTimeout ?? Self.defaultIdleTimeout,
            minIdleSession: base?.minIdleSession ?? Self.defaultMinIdleSession,
            securityLayer: securityLayer
        )
    }

    var tlsConfiguration: TLSConfiguration? { securityLayer.tlsConfiguration }
}

nonisolated extension AnyTLSConfiguration: Codable {
    private enum CodingKeys: String, CodingKey {
        case password, idleCheckInterval, idleTimeout, minIdleSession, security
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            password: try container.decode(String.self, forKey: .password),
            idleCheckInterval: try container.decodeIfPresent(Int.self, forKey: .idleCheckInterval) ?? Self.defaultIdleCheckInterval,
            idleTimeout: try container.decodeIfPresent(Int.self, forKey: .idleTimeout) ?? Self.defaultIdleTimeout,
            minIdleSession: try container.decodeIfPresent(Int.self, forKey: .minIdleSession) ?? Self.defaultMinIdleSession,
            securityLayer: try container.decode(GenericSecurityLayer.self, forKey: .security)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(password, forKey: .password)
        try container.encode(idleCheckInterval, forKey: .idleCheckInterval)
        try container.encode(idleTimeout, forKey: .idleTimeout)
        try container.encode(minIdleSession, forKey: .minIdleSession)
        try container.encode(securityLayer, forKey: .security)
    }
}
