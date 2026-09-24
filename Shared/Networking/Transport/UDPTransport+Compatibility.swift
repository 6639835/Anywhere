//
//  UDPTransport+Compatibility.swift
//  Anywhere
//
//  Created by NodePassProject on 7/27/26.
//

import Foundation
import Network

nonisolated final class LegacyUDPEngine: UDPTransportEngine, Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.argsment.Anywhere.UDPTransport", qos: .userInitiated)
    private let stall = NWStallLatch()

    init(endpoint: NWEndpoint) {
        connection = NWConnection(to: endpoint, using: .udp)
        stall.watch(connection)
        connection.start(queue: queue)
    }

    deinit {
        connection.cancel()
    }

    func cancel() {
        connection.cancel()
    }

    func send(_ datagram: Data) async throws {
        let connection = connection
        let stall = stall
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: datagram, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: stall.failure(for: error, operation: .send))
                    } else {
                        continuation.resume()
                    }
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func receive() async throws -> Data {
        let connection = connection
        let stall = stall
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                connection.receiveMessage { content, _, _, error in
                    if let error {
                        continuation.resume(throwing: stall.failure(for: error, operation: .receive))
                    } else {
                        continuation.resume(returning: content ?? Data())
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}
