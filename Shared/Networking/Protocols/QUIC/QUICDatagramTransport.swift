//
//  QUICDatagramTransport.swift
//  Anywhere
//
//  Created by NodePassProject on 5/19/26.
//

import Foundation

nonisolated protocol QUICDatagramTransport: AnyObject, Sendable {
    func sendDatagram(_ data: Data)
    func receiveDatagram() async throws -> Data?
    func cancel()
}

nonisolated final class ProxyConnectionDatagramTransport: QUICDatagramTransport, Sendable {
    private let connection: ProxyConnection
    
    private let outbound: AsyncStream<Data>.Continuation

    private static let maxQueuedDatagrams = 512

    init(connection: ProxyConnection) {
        self.connection = connection
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingOldest(Self.maxQueuedDatagrams)
        )
        self.outbound = continuation
        Task { [connection] in
            for await data in stream {
                do {
                    try await connection.send(data)
                } catch {
                    if Self.isTransientDatagramError(error) { continue }
                    connection.cancel()
                    break
                }
            }
        }
    }

    func sendDatagram(_ data: Data) {
        outbound.yield(data)
    }

    func receiveDatagram() async throws -> Data? {
        try await connection.receive()
    }

    func cancel() {
        outbound.finish()
        connection.cancel()
    }
    
    private static func isTransientDatagramError(_ error: Error) -> Bool {
        if case AnywhereError.quic(let quicError) = error {
            switch quicError {
            case .handshakeFailed, .streamReset, .streamClosedWithError, .closed:
                return false
            case .datagramTooLarge, .datagramQueueFull, .connectionFailed, .streamFailed, .timedOut:
                return true
            }
        }
        if case AnywhereError.proxy(.hysteria, let failure) = error {
            switch failure {
            case .authenticationRejected, .unsupported, .datagramTooLarge, .streamClosed:
                return false
            case .notReady, .connectionClosed, .tunnelRejected:
                return true
            default:
                return false
            }
        }
        if case AnywhereError.proxy(.nowhere, let failure) = error {
            if case .notReady = failure { return true }
            if case .connectionClosed = failure { return true }
            return false
        }
        return false
    }
}
