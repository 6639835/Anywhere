//
//  NowhereMorph.swift
//  Anywhere
//
//  Created by NodePassProject on 9/11/26.
//

import CryptoKit
import Foundation
import Security
import Synchronization

nonisolated enum NowhereMorph {
    static let nonceSize = 12
    static let byteLimit: UInt64 = (1 << 38) - 64

    struct Keys: Hashable, Sendable {
        let tcpClientToServer: Data
        let tcpServerToClient: Data
        let udp: Data
    }

    static func deriveKeys(sharedKey: String) throws -> Keys {
        let input = Data(sharedKey.utf8)
        guard !input.isEmpty, input.count <= UInt8.max else {
            throw AnywhereError.proxy(.nowhere, .protocolViolation(detail: "Invalid Morph shared key"))
        }
        func derive(_ label: String) -> Data {
            let key = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: input),
                salt: Data("nowhere/morph".utf8),
                info: Data(label.utf8),
                outputByteCount: 32
            )
            return key.withUnsafeBytes { Data($0) }
        }
        return Keys(
            tcpClientToServer: derive("tcp c2s"),
            tcpServerToClient: derive("tcp s2c"),
            udp: derive("udp")
        )
    }

    static func apply(_ input: Data, key: Data, nonce: Data, offset: UInt64) throws -> Data {
        guard key.count == 32, nonce.count == nonceSize,
              offset <= byteLimit, UInt64(input.count) <= byteLimit - offset else {
            throw AnywhereError.proxy(.nowhere, .connectionClosed(detail: "Morph stream limit exceeded"))
        }
        if input.isEmpty { return Data() }
        var output = Data(count: input.count)
        let status = output.withUnsafeMutableBytes { destination in
            input.withUnsafeBytes { source in
                key.withUnsafeBytes { keyBytes in
                    nonce.withUnsafeBytes { nonceBytes in
                        nowhere_chacha20_xor(
                            destination.bindMemory(to: UInt8.self).baseAddress,
                            source.bindMemory(to: UInt8.self).baseAddress,
                            input.count,
                            keyBytes.bindMemory(to: UInt8.self).baseAddress,
                            nonceBytes.bindMemory(to: UInt8.self).baseAddress,
                            offset
                        )
                    }
                }
            }
        }
        guard status == 0 else {
            throw AnywhereError.proxy(.nowhere, .connectionClosed(detail: "Morph stream limit exceeded"))
        }
        return output
    }
}

nonisolated final class NowhereMorphNonceGenerator: Sendable {
    typealias RandomBytes = @Sendable (Int) throws -> Data

    private struct State {
        var key: Data
        var nonce: Data
        var offset: UInt64
    }

    private let state: Mutex<State>
    private let randomBytes: RandomBytes
    private let reseedByteLimit: UInt64

    init(
        randomBytes: @escaping RandomBytes = NowhereMorphNonceGenerator.secureRandomBytes,
        reseedByteLimit: UInt64 = NowhereMorph.byteLimit
    ) throws {
        guard reseedByteLimit >= UInt64(NowhereMorph.nonceSize) else {
            throw AnywhereError.proxy(.nowhere, .connectionClosed(detail: "Invalid Morph nonce limit"))
        }
        self.randomBytes = randomBytes
        self.reseedByteLimit = reseedByteLimit
        state = Mutex(try Self.makeState(randomBytes: randomBytes))
    }

    func next() throws -> Data {
        try state.withLock { state in
            if state.offset > reseedByteLimit - UInt64(NowhereMorph.nonceSize) {
                state = try Self.makeState(randomBytes: randomBytes)
            }
            let output = try NowhereMorph.apply(
                Data(repeating: 0, count: NowhereMorph.nonceSize),
                key: state.key,
                nonce: state.nonce,
                offset: state.offset
            )
            state.offset += UInt64(NowhereMorph.nonceSize)
            return output
        }
    }

    private static func makeState(randomBytes: RandomBytes) throws -> State {
        let seed = try randomBytes(44)
        guard seed.count == 44 else {
            throw AnywhereError.proxy(.nowhere, .connectionClosed(detail: "Failed to seed Morph nonce generator"))
        }
        return State(key: Data(seed.prefix(32)), nonce: Data(seed.suffix(12)), offset: 0)
    }

    static func secureRandomBytes(count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw AnywhereError.proxy(.nowhere, .connectionClosed(detail: "Failed to seed Morph nonce generator"))
        }
        return bytes
    }
}

nonisolated final class NowhereMorphPacketObfuscator: QUICPacketObfuscator {
    private struct FailureState {
        var failed = false
        var handler: (@Sendable (Error) -> Void)?
    }

    private let key: Data
    private let nonceGenerator: NowhereMorphNonceGenerator
    private let failureState = Mutex(FailureState())

    init(key: Data) throws {
        self.key = key
        nonceGenerator = try NowhereMorphNonceGenerator()
    }

    init(key: Data, nonceGenerator: NowhereMorphNonceGenerator) {
        self.key = key
        self.nonceGenerator = nonceGenerator
    }

    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) {
        let error: Error? = failureState.withLock { state in
            state.handler = handler
            return state.failed
                ? AnywhereError.proxy(.nowhere, .connectionClosed(detail: "Morph nonce generation failed"))
                : nil
        }
        if let error { handler(error) }
    }

    func seal(_ packet: UnsafeRawBufferPointer) -> [Data] {
        do {
            let nonce = try nonceGenerator.next()
            let ciphertext = try NowhereMorph.apply(Data(packet), key: key, nonce: nonce, offset: 0)
            var output = Data(capacity: NowhereMorph.nonceSize + ciphertext.count)
            output.append(nonce)
            output.append(ciphertext)
            return [output]
        } catch {
            let handler: (@Sendable (Error) -> Void)? = failureState.withLock { state in
                guard !state.failed else { return nil }
                state.failed = true
                return state.handler
            }
            handler?(error)
            return []
        }
    }

    func open(_ datagram: Data) -> Data? {
        guard datagram.count > NowhereMorph.nonceSize else { return nil }
        let nonce = Data(datagram.prefix(NowhereMorph.nonceSize))
        let ciphertext = Data(datagram.dropFirst(NowhereMorph.nonceSize))
        return try? NowhereMorph.apply(ciphertext, key: key, nonce: nonce, offset: 0)
    }
}

nonisolated final class NowhereMorphTCPTransport: ByteTransport, Sendable {
    private struct State {
        let nonce: Data
        var sendOffset: UInt64 = 0
        var receiveOffset: UInt64 = 0
        var nonceSent = false
    }

    private let inner: any ByteTransport
    private let clientToServerKey: Data
    private let serverToClientKey: Data
    private let state: Mutex<State>

    convenience init(inner: any ByteTransport, keys: NowhereMorph.Keys) throws {
        try self.init(inner: inner, keys: keys, nonce: NowhereMorphNonceGenerator().next())
    }

    init(inner: any ByteTransport, keys: NowhereMorph.Keys, nonce: Data) throws {
        guard nonce.count == NowhereMorph.nonceSize else {
            throw AnywhereError.proxy(.nowhere, .protocolViolation(detail: "Invalid Morph nonce"))
        }
        self.inner = inner
        clientToServerKey = keys.tcpClientToServer
        serverToClientKey = keys.tcpServerToClient
        state = Mutex(State(nonce: nonce))
    }

    var isReady: Bool { inner.isReady }

    func send(_ data: Data) async throws {
        do {
            let wire = try state.withLock { state -> Data in
                let ciphertext = try NowhereMorph.apply(
                    data,
                    key: clientToServerKey,
                    nonce: state.nonce,
                    offset: state.sendOffset
                )
                state.sendOffset += UInt64(data.count)
                if state.nonceSent { return ciphertext }
                state.nonceSent = true
                var output = Data(capacity: NowhereMorph.nonceSize + ciphertext.count)
                output.append(state.nonce)
                output.append(ciphertext)
                return output
            }
            try await inner.send(wire)
        } catch {
            inner.cancel()
            throw error
        }
    }

    func receive() async throws -> TransportChunk {
        do {
            switch try await inner.receive() {
            case .end:
                return .end
            case .bytes(let data):
                return try state.withLock { state in
                    let plaintext = try NowhereMorph.apply(
                        data,
                        key: serverToClientKey,
                        nonce: state.nonce,
                        offset: state.receiveOffset
                    )
                    state.receiveOffset += UInt64(data.count)
                    return .bytes(plaintext)
                }
            }
        } catch {
            inner.cancel()
            throw error
        }
    }

    func cancel() {
        inner.cancel()
    }
}
