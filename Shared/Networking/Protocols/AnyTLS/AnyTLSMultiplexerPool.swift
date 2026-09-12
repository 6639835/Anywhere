//
//  AnyTLSMultiplexerPool.swift
//  Anywhere
//
//  Created by NodePassProject on 5/16/26.
//

import Foundation
import Synchronization

nonisolated private let logger = AnywhereLogger(category: "AnyTLSMultiplexerPool")

nonisolated final class AnyTLSMultiplexerPool: TransportPool {

    struct Extra {
        var sessionCounter: UInt64 = 0
    }

    private typealias Base = MultiplexerPool<AnyTLSMultiplexer, Extra>
    private let pool = Base(extra: Extra())

    typealias DialOut = @Sendable () async throws -> ProxyConnection
    
    private static let bucket = "anytls"

    private let dialOut: DialOut
    private let passwordHash: Data

    init(
        password: String,
        idleSessionCheckInterval: TimeInterval,
        idleSessionTimeout: TimeInterval,
        minIdleSession: Int,
        dialOut: @escaping DialOut
    ) {
        self.passwordHash = AnyTLSProtocol.passwordHash(password)
        self.dialOut = dialOut
        pool.startIdleEviction(MultiplexerPolicy(
            idleTimeout: max(30, idleSessionTimeout),
            idleCheckInterval: max(30, idleSessionCheckInterval),
            minIdleKeep: max(0, minIdleSession)
        ))
    }

    func reclaim() { pool.drainAll() }
    
    func acquireStream() async throws -> AnyTLSStream {
        let reused: AnyTLSMultiplexer? = try pool.state.withLock { state throws -> AnyTLSMultiplexer? in
            if state.phase == .closed {
                throw AnywhereError.transport(.terminated)
            }
            if let reused = state.multiplexers[Self.bucket]?.first(where: { $0.tryReserveStream() }) {
                state.lastActivity[ObjectIdentifier(reused)] = MonotonicClock.now
                return reused
            }
            return nil
        }
        if let reused {
            return try await dispatchOpenStream(on: reused)
        }

        let connection = try await dialOut()
        let adopted: AnyTLSMultiplexer? = pool.state.withLock { state -> AnyTLSMultiplexer? in
            guard state.phase == .open else { return nil }
            state.extra.sessionCounter &+= 1
            let multiplexer = AnyTLSMultiplexer(
                inner: connection,
                passwordHash: passwordHash,
                padding: AnyTLSPaddingScheme.default,
                seq: state.extra.sessionCounter,
                onClose: { [weak self] multiplexer in
                    self?.pool.removeMultiplexer(multiplexer, key: Self.bucket)
                }
            )
            _ = multiplexer.tryReserveStream()
            state.multiplexers[Self.bucket, default: []].append(multiplexer)
            state.lastActivity[ObjectIdentifier(multiplexer)] = MonotonicClock.now
            return multiplexer
        }
        guard let multiplexer = adopted else {
            connection.cancel()
            throw AnywhereError.transport(.terminated)
        }
        await multiplexer.start()
        return try await dispatchOpenStream(on: multiplexer)
    }

    func closeAll() {
        pool.retire()
    }

    // MARK: - Private

    private func dispatchOpenStream(on multiplexer: AnyTLSMultiplexer) async throws -> AnyTLSStream {
        let onEnd: @Sendable () -> Void = { [weak self, weak multiplexer] in
            guard let multiplexer else { return }
            multiplexer.releaseReservation()
            guard let self else { return }
            self.pool.state.withLock { st in
                if st.lastActivity[ObjectIdentifier(multiplexer)] != nil {
                    st.lastActivity[ObjectIdentifier(multiplexer)] = MonotonicClock.now
                }
            }
        }
        guard let stream = await multiplexer.openStream(onEnd: onEnd) else {
            throw AnywhereError.proxy(.anyTLS, .connectionClosed(detail: "Failed to open AnyTLS stream"))
        }
        return stream
    }
}
