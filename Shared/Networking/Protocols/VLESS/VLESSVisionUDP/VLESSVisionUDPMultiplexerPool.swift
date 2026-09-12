//
//  VLESSVisionUDPMultiplexerPool.swift
//  Anywhere
//
//  Created by NodePassProject on 3/1/26.
//

import Foundation
import Synchronization

nonisolated final class VLESSVisionUDPMultiplexerPool: Sendable {
    let configuration: ProxyConfiguration
    private let multiplexers = Mutex<[VLESSVisionUDPMultiplexer]>([])

    init(configuration: ProxyConfiguration) {
        self.configuration = configuration
    }
    
    func acquireStream(
        network: VLESSVisionUDPNetwork,
        host: String,
        port: UInt16,
        globalID: Data?
    ) async throws -> VLESSVisionUDPStream {
        let multiplexer: VLESSVisionUDPMultiplexer = multiplexers.withLock { multiplexers in
            multiplexers.removeAll { $0.isClosed }

            if let reusable = multiplexers.first(where: { !$0.isFull }) {
                return reusable
            }
            
            let created = VLESSVisionUDPMultiplexer(
                configuration: configuration,
                onClose: { [weak self] multiplexer in
                    self?.multiplexers.withLock { $0.removeAll { $0 === multiplexer } }
                }
            )
            multiplexers.append(created)
            return created
        }

        return try await multiplexer.openStream(network: network, host: host, port: port, globalID: globalID)
    }

    func closeAll() {
        let all = multiplexers.withLock { multiplexers -> [VLESSVisionUDPMultiplexer] in
            let snapshot = multiplexers
            multiplexers.removeAll()
            return snapshot
        }
        for multiplexer in all {
            multiplexer.close()
        }
    }
}

// MARK: - UDPMultiplexerPool

nonisolated extension VLESSVisionUDPMultiplexerPool: UDPMultiplexerPool {
    func acquireUDPStream(
        host: String,
        port: UInt16,
        sourceAddress: String
    ) async throws -> any UDPMultiplexerStream {
        try await acquireStream(
            network: .udp,
            host: host,
            port: port,
            globalID: VLESSVisionUDPGlobalID.generateGlobalID(sourceAddress: sourceAddress)
        )
    }
}

// MARK: - Configuration hook

nonisolated extension ProxyConfiguration {
    func makeUDPMultiplexerPool() -> (any UDPMultiplexerPool)? {
        guard case .vless = outbound else { return nil }
        return VLESSVisionUDPMultiplexerPool(configuration: self)
    }
}
