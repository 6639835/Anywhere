//
//  AnyTLSStream.swift
//  Anywhere
//
//  Created by NodePassProject on 5/16/26.
//

import Foundation
import Synchronization

nonisolated private let logger = AnywhereLogger(category: "AnyTLSStream")

actor AnyTLSStream {
    nonisolated let sid: UInt32
    private weak var multiplexer: AnyTLSMultiplexer?
    
    private nonisolated let cachedTLSVersion: TLSVersion?
    
    private let inbox = AsyncInbox<Data>()

    private enum Phase: PhaseTransitionable {
        case open
        case localCancelled
        case ended

        static func canTransition(from old: Phase, to new: Phase) -> Bool {
            switch (old, new) {
            case (.open, .localCancelled),
                 (.open, .ended),
                 (.localCancelled, .ended):
                return true
            default:
                return false
            }
        }
    }
    private struct StreamState: PhaseHolding {
        var phase: Phase = .open
        var onEnd: (@Sendable () -> Void)?
    }
    private nonisolated let state: Mutex<StreamState>

    init(sid: UInt32, multiplexer: AnyTLSMultiplexer, outerTLSVersion: TLSVersion?,
         onEnd: (@Sendable () -> Void)? = nil) {
        self.sid = sid
        self.multiplexer = multiplexer
        self.cachedTLSVersion = outerTLSVersion
        self.state = Mutex(StreamState(onEnd: onEnd))
    }

    nonisolated var isConnected: Bool {
        state.withLock { if case .open = $0.phase { true } else { false } }
    }
    nonisolated var outerTLSVersion: TLSVersion? { cachedTLSVersion }

    // MARK: - Send

    func sendRaw(_ data: Data) async throws {
        guard isConnected, let multiplexer else {
            throw AnywhereError.proxy(.anyTLS, .connectionClosed(detail: "AnyTLS stream closed"))
        }
        try await multiplexer.writeData(sid: sid, data: data)
    }

    // MARK: - Receive

    func receiveRaw() async throws -> Data? {
        try await inbox.next()
    }

    // MARK: - Cancel

    nonisolated func cancel() {
        let outcome: (proceed: Bool, hook: (@Sendable () -> Void)?) = state.withLock { state in
            guard state.transition(to: .localCancelled) else { return (false, nil) }
            let hook = state.onEnd
            state.onEnd = nil
            return (true, hook)
        }
        guard outcome.proceed else { return }
        inbox.finish()
        outcome.hook?()
        Task { await self.removeFromMultiplexer() }
    }

    private func removeFromMultiplexer() {
        multiplexer?.removeStream(sid: sid)
    }
    
    nonisolated func deliverData(_ data: Data) {
        inbox.yield(data)
    }
    
    nonisolated func deliverClose(error: Error?) {
        let outcome: (proceed: Bool, hook: (@Sendable () -> Void)?) = state.withLock { state in
            guard state.transition(to: .ended) else { return (false, nil) }
            let hook = state.onEnd
            state.onEnd = nil
            return (true, hook)
        }
        guard outcome.proceed else { return }
        if let error { inbox.finish(throwing: error) } else { inbox.finish() }
        outcome.hook?()
    }
}

extension AnyTLSStream: ProxyConnection, MultiplexerStreamSink {}
