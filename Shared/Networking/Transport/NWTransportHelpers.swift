//
//  NWTransportHelpers.swift
//  Anywhere
//
//  Created by NodePassProject on 7/6/26.
//

import Foundation
import Network
import Synchronization

// MARK: - Legacy engine stall

nonisolated final class NWStallLatch: Sendable {
    private let stallError = Mutex<NWError?>(nil)

    func watch(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak connection, self] state in
            switch state {
            case .waiting(let error), .failed(let error):
                if self.record(error) { connection?.cancel() }
            default:
                break
            }
        }
    }

    func failure(for error: NWError, operation: AnywhereError.Transport.Operation) -> any Error {
        (stallError.withLock { $0 } ?? error).legacyEngineError(operation: operation)
    }

    private func record(_ error: NWError) -> Bool {
        stallError.withLock { stored in
            guard stored == nil else { return false }
            stored = error
            return true
        }
    }
}

// MARK: - Modern engine stall

@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
nonisolated final class NetworkConnectionStallLatch: Sendable {
    private enum Outcome {
        case pending
        case ready
        case stalled(NWError)
        case cancelled

        func failure(operation: AnywhereError.Transport.Operation) -> (any Error)? {
            switch self {
            case .pending, .ready:
                return nil
            case .stalled(let error):
                return error.legacyEngineError(operation: operation)
            case .cancelled:
                return CancellationError()
            }
        }
    }

    private enum Gate: UInt8, AtomicRepresentable {
        case pending
        case ready
        case settled
    }

    private struct State {
        var outcome: Outcome = .pending
        var initiated = false
        var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
        var nextWaiterID: UInt64 = 0
    }

    private let gate = Atomic<Gate>(.pending)
    private let state = Mutex(State())

    func watch<P: NetworkProtocolOptions>(_ connection: NetworkConnection<P>) {
        connection.onStateUpdate { [self] _, update in
            switch update {
            case .ready:
                settle(.ready)
            case .waiting(let error), .failed(let error):
                settle(.stalled(error))
            case .cancelled:
                settle(.cancelled)
            default:
                break
            }
        }
    }

    func cancel() {
        settle(.cancelled)
    }

    func perform<T: Sendable>(
        _ operation: AnywhereError.Transport.Operation,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        switch gate.load(ordering: .acquiring) {
        case .ready:
            return try await run(operation, body)
        case .settled:
            throw failure(for: CancellationError(), operation: operation)
        case .pending:
            if claimInitiation() {
                return try await initiate(operation, body)
            }
            try await awaitReady(operation)
            return try await run(operation, body)
        }
    }

    private func run<T: Sendable>(
        _ operation: AnywhereError.Transport.Operation,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await body()
        } catch {
            throw failure(for: error, operation: operation)
        }
    }

    private func claimInitiation() -> Bool {
        state.withLock { state in
            guard case .pending = state.outcome, !state.initiated else { return false }
            state.initiated = true
            return true
        }
    }

    private func initiate<T: Sendable>(
        _ operation: AnywhereError.Transport.Operation,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask {
                do {
                    try Task.checkCancellation()
                    return try await body()
                } catch {
                    self.abandon(error)
                    throw self.failure(for: error, operation: operation)
                }
            }
            group.addTask {
                try await self.awaitReady(operation)
                return nil
            }
            defer { group.cancelAll() }
            while let result = try await group.next() {
                if let value = result { return value }
            }
            throw CancellationError()
        }
    }

    private func abandon(_ error: any Error) {
        if let nwError = error as? NWError, nwError != .posix(.ECANCELED) {
            settle(.stalled(nwError), onlyIfPending: true)
        } else {
            settle(.cancelled, onlyIfPending: true)
        }
    }

    private func settle(_ outcome: Outcome, onlyIfPending: Bool = false) {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { state in
            switch (state.outcome, outcome) {
            case (.pending, _):
                break
            case (.ready, .stalled), (.ready, .cancelled):
                guard !onlyIfPending else { return [] }
            default:
                return []
            }
            state.outcome = outcome
            if case .ready = outcome {
                gate.store(.ready, ordering: .releasing)
            } else {
                gate.store(.settled, ordering: .releasing)
            }
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    private func failure(for error: any Error, operation: AnywhereError.Transport.Operation) -> any Error {
        if let failure = state.withLock({ $0.outcome }).failure(operation: operation) { return failure }
        if let nwError = error as? NWError { return nwError.legacyEngineError(operation: operation) }
        return error
    }

    private func awaitReady(_ operation: AnywhereError.Transport.Operation) async throws {
        let id: UInt64 = state.withLock { state in
            defer { state.nextWaiterID &+= 1 }
            return state.nextWaiterID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let registered: Bool = state.withLock { state in
                    guard case .pending = state.outcome, !Task.isCancelled else { return false }
                    state.waiters[id] = continuation
                    return true
                }
                if !registered { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume()
        }
        let outcome = state.withLock { $0.outcome }
        switch outcome {
        case .ready:
            return
        case .pending:
            throw CancellationError()
        case .stalled, .cancelled:
            throw outcome.failure(operation: operation) ?? CancellationError()
        }
    }
}

// MARK: - NWError

extension NWError {
    nonisolated func anywhereError(operation: AnywhereError.Transport.Operation) -> AnywhereError {
        switch self {
        case .posix(let code):
            return .transport(.posix(operation, errno: code.rawValue))
        case .dns:
            return .dns(.resolutionFailed(host: nil, detail: localizedDescription))
        default:
            return .transport(.connectionFailed(endpoint: nil, detail: localizedDescription))
        }
    }
    
    nonisolated func legacyEngineError(operation: AnywhereError.Transport.Operation) -> any Error {
        if case .posix(.ECANCELED) = self { return CancellationError() }
        return anywhereError(operation: operation)
    }
    
    nonisolated var connectWaitingDescription: String {
        switch self {
        case .posix(let code):
            return "waiting(errno \(code.rawValue): \(String(cString: strerror(code.rawValue))))"
        case .dns(let code):
            return "waiting(dns \(code))"
        default:
            return "waiting(\(localizedDescription))"
        }
    }

}

// MARK: - AnywhereError

extension AnywhereError {
    nonisolated static func networkFailure(_ error: Error, operation: Transport.Operation) -> AnywhereError {
        if error is CancellationError { return .transport(.terminated) }
        if let nwError = error as? NWError { return nwError.anywhereError(operation: operation) }
        if let anywhereError = error as? AnywhereError { return anywhereError }
        return .transport(.connectionFailed(endpoint: nil, detail: error.localizedDescription))
    }
    
    nonisolated static func errnoCode(from error: Error) -> Int32 {
        if error is CancellationError { return ECANCELED }
        if let nwError = error as? NWError, case .posix(let posix) = nwError { return posix.rawValue }
        return -1
    }
}

// MARK: - NWEndpoint.Host

extension NWEndpoint.Host {
    nonisolated init?(ipLiteral ip: String) {
        if ip.contains(":") {
            guard let address = IPv6Address(ip) else { return nil }
            self = .ipv6(address)
        } else {
            guard let address = IPv4Address(ip) else { return nil }
            self = .ipv4(address)
        }
    }
    
    nonisolated static func dialHost(for host: String, viaProxyDNS: Bool) async -> NWEndpoint.Host {
        if let literal = NWEndpoint.Host(ipLiteral: host) { return literal }
        guard viaProxyDNS,
              let resolved = await DNSResolver.shared.resolveDialAddress(for: host),
              let literal = NWEndpoint.Host(ipLiteral: resolved)
        else { return .name(host, nil) }
        return literal
    }
}
