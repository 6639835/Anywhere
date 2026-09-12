//
//  ProxyRequest.swift
//  Anywhere
//
//  Created by NodePassProject on 9/12/26.
//

import Foundation

// MARK: - ProxyNetwork

nonisolated enum ProxyNetwork: Sendable, CustomStringConvertible {
    case tcp
    case udp

    var description: String {
        switch self {
        case .tcp: "TCP"
        case .udp: "UDP"
        }
    }
}

// MARK: - ProxyRequest

nonisolated struct ProxyRequest: Sendable {
    var network: ProxyNetwork
    var host: String
    var port: UInt16
    var initialData: Data?
    var isMultiplexerCarrier: Bool

    init(
        network: ProxyNetwork,
        host: String,
        port: UInt16,
        initialData: Data? = nil,
        isMultiplexerCarrier: Bool = false
    ) {
        self.network = network
        self.host = host
        self.port = port
        self.initialData = initialData
        self.isMultiplexerCarrier = isMultiplexerCarrier
    }

    static func tcp(_ host: String, port: UInt16, initialData: Data? = nil) -> ProxyRequest {
        ProxyRequest(network: .tcp, host: host, port: port, initialData: initialData)
    }

    static func udp(_ host: String, port: UInt16) -> ProxyRequest {
        ProxyRequest(network: .udp, host: host, port: port)
    }
}
