//
//  ProxyClient+Hysteria.swift
//  Anywhere
//
//  Created by NodePassProject on 4/15/26.
//

import Foundation
import Synchronization

extension ProxyClient {
    func connectWithHysteria(_ request: ProxyRequest) async throws -> ProxyConnection {
        guard case .hysteria(let password, let congestionControl, let uploadMbps, let downloadMbps, let obfuscation, let sni) = configuration.outbound else {
            throw AnywhereError.proxy(.hysteria, .protocolViolation(detail: "Hysteria password not set"))
        }

        let hysteriaConfiguration = HysteriaConfiguration(
            proxyHost: configuration.serverAddress,
            proxyPort: configuration.serverPort,
            password: password,
            congestionControl: congestionControl,
            uploadMbps: uploadMbps,
            downloadMbps: downloadMbps,
            obfuscation: obfuscation,
            sni: sni
        )
        
        let bracketedHost = request.host.contains(":") ? "[\(request.host)]" : request.host
        let destination = "\(bracketedHost):\(request.port)"

        if let chainTunnel = tunnel {
            let transport = ProxyConnectionDatagramTransport(connection: chainTunnel)
            setChainTunnel(nil)
            let client = HysteriaClient.chained(configuration: hysteriaConfiguration, transport: transport)
            return try await dispatchHysteria(client: client, network: request.network, destination: destination)
        }

        if let chain = configuration.chain, !chain.isEmpty {
            return try await connectPooledChainedHysteria(
                hysteriaConfiguration: hysteriaConfiguration,
                chain: chain,
                network: request.network,
                destination: destination
            )
        }

        let client = HysteriaClient.shared(for: hysteriaConfiguration)
        return try await dispatchHysteria(client: client, network: request.network, destination: destination)
    }

    private func dispatchHysteria(
        client: HysteriaClient,
        network: ProxyNetwork,
        destination: String
    ) async throws -> ProxyConnection {
        switch network {
        case .tcp:
            return try await client.openTCP(destination: destination)
        case .udp:
            return try await client.openUDP(destination: destination)
        }
    }
    
    private func connectPooledChainedHysteria(
        hysteriaConfiguration: HysteriaConfiguration,
        chain: [ProxyConfiguration],
        network: ProxyNetwork,
        destination: String
    ) async throws -> ProxyConnection {
        let chainSignature = chain.map { $0.id.uuidString }.joined(separator: ":")
        
        let cascadeNetworks: [ProxyNetwork]
        switch Self.computeChainHopNetworks(
            chain: chain,
            outerProtocol: .hysteria,
            outerNetwork: network
        ) {
        case .success(let networks):
            cascadeNetworks = networks
        case .failure(let error):
            throw error
        }

        let hyServerAddress = configuration.serverAddress
        let hyServerPort = configuration.serverPort
        let useResolvedAddress = useResolvedAddressForDirectDial

        let client = try await HysteriaClient.acquireChained(
            configuration: hysteriaConfiguration,
            chainSignature: chainSignature,
            builder: {
                let holders = Mutex<[ProxyClient]>([])
                do {
                    let chainTunnel = try await ProxyClient.buildDetachedChainTunnel(
                        chain: chain,
                        hopNetworks: cascadeNetworks,
                        finalDestination: (hyServerAddress, hyServerPort),
                        useResolvedAddressForDirectDial: useResolvedAddress,
                        track: { client in
                            holders.withLock { $0.append(client) }
                        }
                    )
                    let snapshot = holders.withLock { $0 }
                    let transport = ProxyConnectionDatagramTransport(connection: chainTunnel)
                    return (transport, snapshot)
                } catch {
                    let snapshot = holders.withLock { $0 }
                    for c in snapshot { await c.cancel() }
                    throw error
                }
            }
        )
        return try await dispatchHysteria(client: client, network: network, destination: destination)
    }
}
