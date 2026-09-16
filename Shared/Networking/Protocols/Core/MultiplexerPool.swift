//
//  MultiplexerPool.swift
//  Anywhere
//
//  Created by NodePassProject on 4/14/26.
//

import Foundation
import Synchronization

// MARK: - MultiplexerPolicy

nonisolated struct MultiplexerPolicy {
    var idleTimeout: TimeInterval
    var idleCheckInterval: TimeInterval
    var minIdleKeep: Int
    var softCapPerKey: Int
    var hardCapPerKey: Int

    init(
        idleTimeout: TimeInterval,
        idleCheckInterval: TimeInterval,
        minIdleKeep: Int = 0,
        softCapPerKey: Int = 0,
        hardCapPerKey: Int = 0
    ) {
        self.idleTimeout = idleTimeout
        self.idleCheckInterval = idleCheckInterval
        self.minIdleKeep = minIdleKeep
        self.softCapPerKey = softCapPerKey
        self.hardCapPerKey = hardCapPerKey
    }
}

// MARK: - MultiplexerPool

nonisolated final class MultiplexerPool<S: Multiplexer & Sendable, Extra: Sendable>: Sendable {
    enum Phase: PhaseTransitionable {
        case open, closed

        static func canTransition(from old: Phase, to new: Phase) -> Bool {
            switch (old, new) {
            case (.open, .closed):
                return true
            default:
                return false
            }
        }
    }

    struct PoolState: PhaseHolding {
        var phase: Phase = .open

        var multiplexers: [String: [S]] = [:]
        
        var lastActivity: [ObjectIdentifier: TimeInterval] = [:]

        var idleTask: Task<Void, Never>?
        var policy: MultiplexerPolicy?
        
        var extra: Extra
    }

    let state: Mutex<PoolState>

    init(extra: Extra) {
        state = Mutex(PoolState(extra: extra))
    }
    
    deinit {
        state.withLock { $0.idleTask?.cancel() }
    }

    static func makeKey(host: String, port: UInt16, sni: String) -> String {
        "\(host):\(port):\(sni)"
    }

    // MARK: - Idle eviction
    
    func startIdleEviction(_ policy: MultiplexerPolicy) {
        state.withLock { state in
            state.policy = policy
            state.idleTask?.cancel()
            state.idleTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(policy.idleCheckInterval))
                    guard !Task.isCancelled, let self else { return }
                    self.runIdleEviction()
                }
            }
        }
    }

    private func runIdleEviction() {
        let now = MonotonicClock.now
        
        let toClose: [S] = state.withLock { state -> [S] in
            guard let policy = state.policy else { return [] }
            var toClose: [S] = []
            for key in Array(state.multiplexers.keys) {
                guard let multiplexers = state.multiplexers[key] else { continue }
                var idle = multiplexers.filter { $0.activeStreamCount == 0 && !$0.isClosed }
                if policy.minIdleKeep > 0 || policy.softCapPerKey > 0 {
                    idle.sort { (state.lastActivity[ObjectIdentifier($0)] ?? 0) > (state.lastActivity[ObjectIdentifier($1)] ?? 0) }
                }
                for (index, multiplexer) in idle.enumerated() {
                    if index < policy.minIdleKeep {
                        state.lastActivity[ObjectIdentifier(multiplexer)] = now
                        continue
                    }
                    let surplus = policy.softCapPerKey > 0 && index >= policy.softCapPerKey
                    let age = now - (state.lastActivity[ObjectIdentifier(multiplexer)] ?? now)
                    if surplus || age > policy.idleTimeout {
                        state.multiplexers[key]?.removeAll { $0 === multiplexer }
                        state.lastActivity.removeValue(forKey: ObjectIdentifier(multiplexer))
                        toClose.append(multiplexer)
                    }
                }
                if state.multiplexers[key]?.isEmpty == true { state.multiplexers.removeValue(forKey: key) }
            }
            return toClose
        }

        for multiplexer in toClose { multiplexer.close(error: nil) }
    }

    // MARK: - Removal / teardown

    func removeMultiplexer(_ multiplexer: S, key: String) {
        state.withLock { state in
            state.multiplexers[key]?.removeAll { $0 === multiplexer }
            if state.multiplexers[key]?.isEmpty == true {
                state.multiplexers.removeValue(forKey: key)
            }
            state.lastActivity.removeValue(forKey: ObjectIdentifier(multiplexer))
        }
    }

    private func takeAll(_ state: inout PoolState) -> [S] {
        let all = state.multiplexers.values.flatMap { $0 }
        state.multiplexers.removeAll()
        state.lastActivity.removeAll()
        return all
    }

    func drainAll() {
        let all: [S] = state.withLock { takeAll(&$0) }
        for multiplexer in all {
            multiplexer.close(error: nil)
        }
    }

    func retire() {
        let taken: (all: [S], idleTask: Task<Void, Never>?) = state.withLock { state in
            state.transition(to: .closed)
            let idleTask = state.idleTask
            state.idleTask = nil
            return (takeAll(&state), idleTask)
        }
        taken.idleTask?.cancel()
        for multiplexer in taken.all {
            multiplexer.close(error: nil)
        }
    }
}
