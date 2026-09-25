//
//  UDPTransport.swift
//  Anywhere
//
//  Created by NodePassProject on 7/14/26.
//

import Foundation
import Network
import Synchronization

nonisolated protocol UDPTransportEngine: AnyObject, Sendable {
    func send(_ datagram: Data) async throws
    func receive() async throws -> Data
    func cancel()
}

nonisolated final class UDPTransport: DatagramTransport, Sendable {

    // MARK: State

    enum Phase: PhaseTransitionable {
        case idle
        case connecting
        case ready
        case cancelled

        static func canTransition(from old: Phase, to new: Phase) -> Bool {
            switch (old, new) {
            case (.idle, .connecting),
                 (.connecting, .ready):
                return true
            case (_, .cancelled):
                return old != .cancelled
            default:
                return false
            }
        }
    }

    private struct State: PhaseHolding {
        var phase: Phase = .idle

        var engine: (any UDPTransportEngine)?
        var flowSlot: FlowSlot?
        var failure: AnywhereError?
    }

    private let state = Mutex(State())

    private let host: String
    private let port: UInt16
    private let resolvesViaProxyDNS: Bool
    let endpointDescription: String

    init(host: String, port: UInt16, resolvesViaProxyDNS: Bool = false) {
        self.host = host
        self.port = port
        self.resolvesViaProxyDNS = resolvesViaProxyDNS
        self.endpointDescription = "\(host):\(port)"
    }

    deinit {
        cancel()
    }

    var isReady: Bool {
        state.withLock { $0.phase == .ready }
    }

    // MARK: - Connect

    func connect() async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw AnywhereError.transport(.connectionFailed(endpoint: nil, detail: "invalid port \(port)"))
        }
        let endpointHost = await NWEndpoint.Host.dialHost(for: host, viaProxyDNS: resolvesViaProxyDNS)
        let endpoint = NWEndpoint.hostPort(host: endpointHost, port: nwPort)
        let slot = FlowSlot(context: "[UDP] \(endpointDescription)")

        let engine: any UDPTransportEngine
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
            engine = ModernUDPEngine(endpoint: endpoint)
        } else {
            engine = LegacyUDPEngine(endpoint: endpoint)
        }

        let live: Bool = state.withLock { state in
            guard state.transition(to: .connecting) else { return false }
            state.flowSlot = slot
            state.engine = engine
            return true
        }
        guard live else {
            slot.release()
            throw AnywhereError.transport(.terminated)
        }
        let published: Bool = state.withLock { $0.transition(to: .ready) }
        guard published else { throw AnywhereError.transport(.terminated) }
    }

    // MARK: - DatagramTransport

    func send(_ datagram: Data) async throws {
        let engine = try activeEngine()
        do {
            try await engine.send(datagram)
        } catch {
            throw latchedFailure() ?? AnywhereError.networkFailure(error, operation: .send)
        }
    }

    func receive() async throws -> Data {
        while true {
            let engine = try activeEngine()
            let content: Data
            do {
                content = try await engine.receive()
            } catch {
                throw latchedFailure() ?? AnywhereError.networkFailure(error, operation: .receive)
            }
            if !content.isEmpty { return content }
        }
    }

    func cancel() {
        let (engine, slot): ((any UDPTransportEngine)?, FlowSlot?) = state.withLock { state in
            if state.failure == nil { state.failure = .transport(.terminated) }
            state.transition(to: .cancelled)
            let pair = (state.engine, state.flowSlot)
            state.engine = nil
            state.flowSlot = nil
            return pair
        }
        engine?.cancel()
        slot?.release()
    }

    // MARK: - Helpers

    private func activeEngine() throws -> any UDPTransportEngine {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            if state.phase == .cancelled { throw AnywhereError.transport(.terminated) }
            guard let engine = state.engine else { throw AnywhereError.transport(.notConnected) }
            return engine
        }
    }

    private func latchedFailure() -> AnywhereError? {
        state.withLock { $0.failure }
    }
}

// MARK: - Modern engine

@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
nonisolated final class ModernUDPEngine: UDPTransportEngine, Sendable {
    private let connection: NetworkConnection<UDP>
    private let stall = NetworkConnectionStallLatch()

    init(endpoint: NWEndpoint) {
        connection = NetworkConnection(to: endpoint) { UDP() }
        stall.watch(connection)
    }

    func cancel() {
        stall.cancel()
    }

    func send(_ datagram: Data) async throws {
        let connection = connection
        try await stall.perform(.send) {
            try await connection.send(datagram)
        }
    }

    func receive() async throws -> Data {
        let connection = connection
        return try await stall.perform(.receive) {
            try await connection.receive().content
        }
    }
}
