//
//  ProxyConnection.swift
//  Anywhere
//
//  Created by NodePassProject on 1/26/26.
//

import Foundation

nonisolated protocol ProxyConnection: AnyObject, Sendable {
    nonisolated var outerTLSVersion: TLSVersion? { get }
    nonisolated var deliversDatagrams: Bool { get }
    nonisolated var isConnected: Bool { get }
    
    func send(_ data: Data) async throws
    func receive() async throws -> Data?
    
    func sendRaw(_ data: Data) async throws
    func receiveRaw() async throws -> Data?
    func sendDirectRaw(_ data: Data) async throws
    func receiveDirectRaw() async throws -> Data?
    
    nonisolated func cancel()
    nonisolated func abort()
}

// MARK: - Defaults

nonisolated extension ProxyConnection {
    var outerTLSVersion: TLSVersion? { nil }

    var deliversDatagrams: Bool { false }
    
    func send(_ data: Data) async throws {
        try await sendRaw(data)
    }

    func receive() async throws -> Data? {
        try await receiveRaw()
    }

    func sendDirectRaw(_ data: Data) async throws {
        try await sendRaw(data)
    }

    func receiveDirectRaw() async throws -> Data? {
        try await receiveRaw()
    }

    func abort() {
        cancel()
    }
}
