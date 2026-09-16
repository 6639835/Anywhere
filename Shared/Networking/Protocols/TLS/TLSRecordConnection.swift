//
//  TLSRecordConnection.swift
//  Anywhere
//
//  Created by NodePassProject on 1/26/26.
//

import Foundation
import CryptoKit
import CommonCrypto
import Synchronization

nonisolated private let logger = AnywhereLogger(category: "TLSRecordConnection")

nonisolated final class TLSRecordConnection: Sendable {

    // MARK: Properties

    private enum Phase: PhaseTransitionable {
        case unattached
        case attached(any ByteTransport)
        case cancelled

        static func canTransition(from old: Phase, to new: Phase) -> Bool {
            switch (old, new) {
            case (.unattached, .attached):
                return true
            case (_, .cancelled):
                return !old.isCancelled
            default:
                return false
            }
        }

        var isCancelled: Bool { if case .cancelled = self { true } else { false } }
    }
    private let phase = Mutex<Phase>(.unattached)

    var connection: (any ByteTransport)? {
        phase.withLock { if case .attached(let transport) = $0 { transport } else { nil } }
    }
    
    func adoptTransport(_ transport: (any ByteTransport)?) {
        guard let transport else { return }
        let adopted: Bool = phase.withLock { Phase.transition(&$0, to: .attached(transport)) }
        if !adopted {
            transport.cancel()
        }
    }
    
    private let sendChain = SerialSender()
    func chainedSend(_ body: @escaping @Sendable () async throws -> Void) async throws {
        try await sendChain.run(body)
    }

    let tlsVersion: UInt16
    
    private let negotiatedALPNBox = Mutex<String>("")
    var negotiatedALPN: String { negotiatedALPNBox.withLock { $0 } }
    func publishNegotiatedALPN(_ alpn: String) {
        negotiatedALPNBox.withLock { $0 = alpn }
    }

    let cipherSuite: UInt16
    
    private let exporterMasterSecret: Data?

    // MARK: - Per-direction Record State
    
    struct DirectionState {
        var key: Data
        var iv: Data
        var symmetricKey: SymmetricKey
        var appSecret: Data? = nil
        var seqNum: UInt64 = 0
    }
    
    private let egressState: Mutex<DirectionState>
    private let ingressState: Mutex<DirectionState>
    
    let egressMACKey: Data
    let ingressMACKey: Data
    
    func nextEgressState() -> DirectionState {
        egressState.withLock { state in
            defer { state.seqNum += 1 }
            return state
        }
    }
    
    func nextIngressState() -> DirectionState {
        ingressState.withLock { state in
            defer { state.seqNum += 1 }
            return state
        }
    }
    
    func mutateEgressState(_ mutate: (inout DirectionState) -> Void) {
        egressState.withLock { mutate(&$0) }
    }
    
    func mutateIngressState(_ mutate: (inout DirectionState) -> Void) {
        ingressState.withLock { mutate(&$0) }
    }

    private static let maxRecordPlaintext = 16384

    // MARK: - Receive State
    
    struct ReceiveState {
        var buffer: Data
        var keyUpdateResponsePending = false
        var receivedCloseNotify = false
    }

    private let receiveState = Mutex<ReceiveState>(ReceiveState(buffer: Data()))

    // MARK: Initialization

    enum Direction {
        case client
        case server
    }

    let direction: Direction

    init(clientKey: Data, clientIV: Data, serverKey: Data, serverIV: Data,
         cipherSuite: UInt16 = TLSCipherSuite.TLS_AES_128_GCM_SHA256,
         clientAppSecret: Data? = nil, serverAppSecret: Data? = nil,
         exporterMasterSecret: Data? = nil,
         direction: Direction = .client) {
        self.tlsVersion = 0x0304
        self.cipherSuite = cipherSuite
        self.direction = direction
        self.exporterMasterSecret = exporterMasterSecret
        let client = DirectionState(
            key: clientKey, iv: clientIV,
            symmetricKey: SymmetricKey(data: clientKey),
            appSecret: clientAppSecret
        )
        let server = DirectionState(
            key: serverKey, iv: serverIV,
            symmetricKey: SymmetricKey(data: serverKey),
            appSecret: serverAppSecret
        )
        self.egressState = Mutex(direction == .server ? server : client)
        self.ingressState = Mutex(direction == .server ? client : server)
        self.egressMACKey = Data()
        self.ingressMACKey = Data()
    }

    init(
        tls12ClientKey clientKey: Data,
        clientIV: Data,
        serverKey: Data,
        serverIV: Data,
        clientMACKey: Data,
        serverMACKey: Data,
        cipherSuite: UInt16,
        protocolVersion: UInt16 = 0x0303,
        initialClientSeqNum: UInt64 = 0,
        initialServerSeqNum: UInt64 = 0,
        direction: Direction = .client
    ) {
        self.tlsVersion = protocolVersion
        self.cipherSuite = cipherSuite
        self.direction = direction
        self.exporterMasterSecret = nil
        let client = DirectionState(
            key: clientKey, iv: clientIV,
            symmetricKey: SymmetricKey(data: clientKey),
            seqNum: initialClientSeqNum
        )
        let server = DirectionState(
            key: serverKey, iv: serverIV,
            symmetricKey: SymmetricKey(data: serverKey),
            seqNum: initialServerSeqNum
        )
        self.egressState = Mutex(direction == .server ? server : client)
        self.ingressState = Mutex(direction == .server ? client : server)
        self.egressMACKey = direction == .server ? serverMACKey : clientMACKey
        self.ingressMACKey = direction == .server ? clientMACKey : serverMACKey
    }
    
    func exportKeyingMaterial(label: String, context: Data, length: Int) throws -> Data {
        guard tlsVersion == 0x0304, let exporterMasterSecret, length > 0 else {
            throw AnywhereError.tls(.handshakeFailed(detail: "TLS exporter unavailable"))
        }
        return TLS13KeyDerivation(cipherSuite: cipherSuite).exportKeyingMaterial(
            exporterMasterSecret: exporterMasterSecret,
            label: label,
            context: context,
            length: length
        )
    }
    
    func prependToReceiveBuffer(_ data: Data) {
        receiveState.withLock { $0.buffer.append(data) }
    }

    // MARK: - Send / Receive (Raw, Unencrypted)
    
    func sendRaw(_ data: Data) async throws {
        try await chainedSend { [self] in
            guard let connection else { throw AnywhereError.tls(.record(.connectionUnavailable)) }
            try await connection.send(data)
        }
    }
    
    func receiveRaw() async throws -> Data? {
        let buffered: Data? = receiveState.withLock { state in
            guard !state.buffer.isEmpty else { return nil }
            let data = state.buffer
            state.buffer.removeAll()
            return data
        }
        if let buffered { return buffered }

        guard let connection else { throw AnywhereError.tls(.record(.connectionUnavailable)) }
        switch try await connection.receive() {
        case .bytes(let data): return data
        case .end: return nil
        }
    }

    // MARK: - Async Surface
    
    func send(_ data: Data) async throws {
        try await chainedSend { [self] in
            guard let connection else { throw AnywhereError.tls(.record(.connectionUnavailable)) }
            let record = try buildTLSRecords(for: data)
            try await connection.send(record)
        }
    }
    
    func receive() async throws -> Data? {
        while true {
            let (processed, needsKeyUpdateResponse) = receiveState.withLock { state -> (BufferResult?, Bool) in
                let processed = processBuffer(&state)
                let needsKeyUpdateResponse = state.keyUpdateResponsePending
                state.keyUpdateResponsePending = false
                return (processed, needsKeyUpdateResponse)
            }

            if needsKeyUpdateResponse {
                await sendKeyUpdateResponseAndRekeyEgress()
            }

            if let result = processed {
                switch result {
                case .data(let data):
                    return data
                case .error(let error):
                    throw error
                case .needMore:
                    break
                case .skip:
                    continue
                case .closed:
                    return nil
                }
            }

            guard let connection else {
                throw AnywhereError.tls(.record(.connectionUnavailable))
            }
            switch try await connection.receive() {
            case .bytes(let data):
                receiveState.withLock { $0.buffer.append(data) }
                continue
            case .end:
                return nil
            }
        }
    }

    // MARK: - Cancel

    func cancel() {
        let transport = phase.withLock { phase -> (any ByteTransport)? in
            let attached: (any ByteTransport)? = if case .attached(let transport) = phase { transport } else { nil }
            Phase.transition(&phase, to: .cancelled)
            return attached
        }

        sendChain.cancel()

        receiveState.withLock { $0.buffer.removeAll() }

        transport?.cancel()
    }

    // MARK: - Internal Buffer Processing

    private enum BufferResult {
        case data(Data)
        case error(Error)
        case needMore
        case skip
        case closed
    }
    
    private func processBuffer(_ state: inout ReceiveState) -> BufferResult? {
        if state.receivedCloseNotify {
            return .closed
        }

        if state.buffer.count == 0 {
            return nil
        }

        var batchedData = Data()
        var batchedRecords = 0
        var hasError: Error? = nil
        var recordsProcessed = 0
        var bytesPendingReplay: Data? = nil

        var consumed = 0

        while state.buffer.count - consumed >= 5 {
            var contentType: UInt8 = 0
            var recordLen: UInt16 = 0

            state.buffer.withUnsafeBytes { pointer in
                let p = pointer.bindMemory(to: UInt8.self)
                contentType = p[consumed]
                recordLen = UInt16(p[consumed + 3]) << 8 | UInt16(p[consumed + 4])
            }

            let maxCiphertext = tlsVersion >= 0x0304 ? 16384 + 256 : 16384 + 2048
            guard Int(recordLen) <= maxCiphertext else {
                state.buffer.removeAll()
                return .error(AnywhereError.tls(.record(.malformed(detail: "record overflow (\(recordLen) bytes)"))))
            }

            let totalLen = 5 + Int(recordLen)
            guard state.buffer.count - consumed >= totalLen else { break }

            let base = state.buffer.startIndex
            let headerStart = base + consumed
            let headerEnd = headerStart + 5
            let bodyEnd = headerStart + totalLen

            let header = state.buffer[headerStart..<headerEnd]
            let body = state.buffer[headerEnd..<bodyEnd]

            recordsProcessed += 1

            if contentType == TLSContentType.applicationData {
                let ingress = nextIngressState()

                do {
                    let decrypted = try decryptTLSRecord(ciphertext: body, header: header, ingress: ingress, receive: &state)
                    consumed += totalLen
                    if !decrypted.isEmpty {
                        if batchedRecords == 0 {
                            batchedData = decrypted.startIndex == 0 ? decrypted : Data(decrypted)
                        } else {
                            batchedData.append(decrypted)
                        }
                        batchedRecords += 1
                    }
                    if state.receivedCloseNotify { break }
                } catch {
                    if case AnywhereError.tls(.alert) = error {
                        state.buffer.removeAll()
                        consumed = 0
                        hasError = error
                        break
                    }
                    let pending = Data(state.buffer[(base + consumed)...])
                    state.buffer.removeAll()
                    consumed = 0
                    bytesPendingReplay = pending
                    hasError = error
                    break
                }
            } else if contentType == TLSContentType.alert {
                if tlsVersion < 0x0304 {
                    let ingress = nextIngressState()

                    consumed += totalLen
                    if let alert = try? decryptTLSRecord(ciphertext: body, header: header, ingress: ingress, receive: &state),
                       alert.count >= 2 {
                        if alert[alert.startIndex + 1] == TLSAlertDescription.closeNotify {
                            state.receivedCloseNotify = true
                        } else {
                            hasError = AnywhereError.tls(.alert(level: alert[alert.startIndex],
                                                                code: alert[alert.startIndex + 1]))
                        }
                    } else {
                        hasError = AnywhereError.tls(.unexpectedAlert)
                    }
                } else {
                    consumed += totalLen
                    hasError = AnywhereError.tls(.unexpectedAlert)
                }
                break
            } else {
                consumed += totalLen
            }
        }

        if consumed > 0 {
            if consumed >= state.buffer.count {
                state.buffer = Data()
            } else {
                state.buffer = Data(state.buffer.suffix(from: state.buffer.startIndex + consumed))
            }
        }

        if let error = hasError {
            if !batchedData.isEmpty {
                if let pending = bytesPendingReplay {
                    state.buffer = pending
                }
                return .data(batchedData)
            }
            return .error(error)
        }

        if state.receivedCloseNotify {
            if !batchedData.isEmpty {
                return .data(batchedData)
            }
            return .closed
        }

        if !batchedData.isEmpty {
            return .data(batchedData)
        }

        if recordsProcessed > 0 {
            return .skip
        }

        return nil
    }

    // MARK: - TLS Record Crypto

    private func buildTLSRecords(for data: Data) throws -> Data {
        if data.count <= Self.maxRecordPlaintext {
            return try encryptSingleRecord(plaintext: data, contentType: TLSContentType.applicationData)
        }

        let chunkCount = (data.count + Self.maxRecordPlaintext - 1) / Self.maxRecordPlaintext
        var records = Data(capacity: data.count + chunkCount * 64)
        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.maxRecordPlaintext, data.count)
            records.append(try encryptSingleRecord(plaintext: Data(data[offset..<end]), contentType: TLSContentType.applicationData))
            offset = end
        }
        return records
    }

    private func encryptSingleRecord(plaintext: Data, contentType: UInt8) throws -> Data {
        if tlsVersion >= 0x0304 {
            return try encryptTLS13Record(plaintext: plaintext, contentType: contentType)
        } else {
            return try encryptTLS12Record(plaintext: plaintext, contentType: contentType)
        }
    }

    private func decryptTLSRecord(ciphertext: Data, header: Data, ingress: DirectionState, receive state: inout ReceiveState) throws -> Data {
        if tlsVersion >= 0x0304 {
            return try decryptTLS13Record(ciphertext: ciphertext, header: header, ingress: ingress, receive: &state)
        } else {
            return try decryptTLS12Record(ciphertext: ciphertext, header: header, ingress: ingress)
        }
    }

    // MARK: - AEAD Helpers

    func sealAEAD(plaintext: Data, nonce: Data, aad: Data, key: SymmetricKey) throws -> (ciphertext: Data, tag: Data) {
        if TLSCipherSuite.isChaCha20(cipherSuite) {
            let nonceObj = try ChaChaPoly.Nonce(data: nonce)
            let sealedBox = try ChaChaPoly.seal(plaintext, using: key, nonce: nonceObj, authenticating: aad)
            return (Data(sealedBox.ciphertext), Data(sealedBox.tag))
        } else {
            let nonceObj = try AES.GCM.Nonce(data: nonce)
            let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonceObj, authenticating: aad)
            return (Data(sealedBox.ciphertext), Data(sealedBox.tag))
        }
    }

    func openAEAD(ciphertext: Data, tag: Data, nonce: Data, aad: Data, key: SymmetricKey) throws -> Data {
        do {
            if TLSCipherSuite.isChaCha20(cipherSuite) {
                let nonceObj = try ChaChaPoly.Nonce(data: nonce)
                let sealedBox = try ChaChaPoly.SealedBox(nonce: nonceObj, ciphertext: ciphertext, tag: tag)
                return Data(try ChaChaPoly.open(sealedBox, using: key, authenticating: aad))
            } else {
                let nonceObj = try AES.GCM.Nonce(data: nonce)
                let sealedBox = try AES.GCM.SealedBox(nonce: nonceObj, ciphertext: ciphertext, tag: tag)
                return Data(try AES.GCM.open(sealedBox, using: key, authenticating: aad))
            }
        } catch CryptoKitError.authenticationFailure {
            throw AnywhereError.tls(.record(.authenticationFailed))
        }
    }

    @inline(__always)
    func xorSeqIntoNonce(_ nonce: inout Data, seqNum: UInt64) {
        nonce.withUnsafeMutableBytes { pointer in
            let p = pointer.bindMemory(to: UInt8.self)
            let base = p.count - 8
            for i in 0..<8 {
                p[base + i] ^= UInt8((seqNum >> ((7 - i) * 8)) & 0xFF)
            }
        }
    }
}
