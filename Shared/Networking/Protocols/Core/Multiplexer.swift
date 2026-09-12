//
//  Multiplexer.swift
//  Anywhere
//
//  Created by NodePassProject on 6/15/26.
//

import Foundation

// MARK: - Multiplexer

nonisolated protocol Multiplexer: AnyObject {
    var isClosed: Bool { get }
    var activeStreamCount: Int { get }
    func close(error: Error?)
}

// MARK: - MultiplexerStreamSink

protocol MultiplexerStreamSink: AnyObject {
    nonisolated func deliverData(_ data: Data)
    nonisolated func deliverClose(error: Error?)
}

// MARK: - UDP Multiplexer

nonisolated protocol UDPMultiplexerPool: Sendable {
    func acquireUDPStream(host: String, port: UInt16, sourceAddress: String) async throws -> any UDPMultiplexerStream
    func closeAll()
}

nonisolated protocol UDPMultiplexerStream: Sendable {
    nonisolated var closed: Bool { get }
    func send(data: Data) async throws
    func receive() async throws -> Data?
    nonisolated func close()
}
