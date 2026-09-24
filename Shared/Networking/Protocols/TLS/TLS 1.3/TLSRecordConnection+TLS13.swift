//
//  TLSRecordConnection+TLS13.swift
//  Anywhere
//
//  Created by NodePassProject on 6/19/26.
//

import Foundation
import CryptoKit
import CommonCrypto
import Synchronization

nonisolated extension TLSRecordConnection {

    // MARK: - TLS 1.3 Record Crypto

    func encryptTLS13Record(plaintext: Data, contentType: UInt8 = TLSContentType.applicationData) throws -> Data {
        let egress = nextEgressState()

        let innerLen = plaintext.count + 1
        let encryptedLen = innerLen + 16

        var nonce = egress.iv
        xorSeqIntoNonce(&nonce, seqNum: egress.seqNum)

        var innerPlaintext = Data(count: innerLen)
        innerPlaintext.withUnsafeMutableBytes { buffer in
            plaintext.copyBytes(to: buffer)
            buffer[plaintext.count] = contentType
        }

        let aad = Data([TLSContentType.applicationData, 0x03, 0x03, UInt8(encryptedLen >> 8), UInt8(encryptedLen & 0xFF)])

        let (sealedCt, sealedTag) = try sealAEAD(plaintext: innerPlaintext, nonce: nonce, aad: aad, key: egress.symmetricKey)

        var record = Data(capacity: 5 + encryptedLen)
        record.append(aad)
        record.append(sealedCt)
        record.append(sealedTag)
        return record
    }
    
    func decryptTLS13Record(ciphertext: Data, header: Data, ingress: DirectionState, receive state: inout ReceiveState) throws -> Data {
        guard ciphertext.count >= 16 else {
            throw AnywhereError.tls(.record(.ciphertextTooShort))
        }

        var nonce = ingress.iv
        xorSeqIntoNonce(&nonce, seqNum: ingress.seqNum)

        let ct = ciphertext.prefix(ciphertext.count - 16)
        let tag = ciphertext.suffix(16)

        let decrypted = try openAEAD(ciphertext: ct, tag: tag, nonce: nonce, aad: header, key: ingress.symmetricKey)

        guard !decrypted.isEmpty else {
            throw AnywhereError.tls(.record(.emptyPlaintext))
        }

        var innerContentType: UInt8 = 0
        let contentLen: ssize_t = decrypted.withUnsafeBytes { pointer -> ssize_t in
            let decryptedBytes = pointer.bindMemory(to: UInt8.self)
            var i = decryptedBytes.count - 1
            while i >= 0 && decryptedBytes[i] == 0 { i -= 1 }
            guard i >= 0 else { return -1 }
            innerContentType = decryptedBytes[i]
            return ssize_t(i)
        }

        guard contentLen >= 0 else {
            throw AnywhereError.tls(.record(.missingContentType))
        }
        
        if innerContentType == TLSContentType.handshake {
            try handlePostHandshakeTLS13(decrypted.prefix(Int(contentLen)), receive: &state)
            return Data()
        }

        if innerContentType == TLSContentType.alert {
            let body = decrypted.prefix(Int(contentLen))
            let level = body.first ?? 0
            let description = body.count >= 2 ? body[body.startIndex + 1] : 0
            if description == TLSAlertDescription.closeNotify {
                state.receivedCloseNotify = true
                return Data()
            }
            throw AnywhereError.tls(.alert(level: level, code: description))
        }

        return decrypted.prefix(Int(contentLen))
    }

    // MARK: - TLS 1.3 KeyUpdate
    
    private func handlePostHandshakeTLS13(_ fragment: Data, receive state: inout ReceiveState) throws {
        state.pendingPostHandshake.append(fragment)
        let messages = state.pendingPostHandshake
        var i = messages.startIndex
        let end = messages.endIndex
        while i + 4 <= end {
            let type = messages[i]
            let length = Int(messages[i + 1]) << 16 | Int(messages[i + 2]) << 8 | Int(messages[i + 3])
            let bodyStart = i + 4
            let bodyEnd = bodyStart + length
            guard bodyEnd <= end else {
                guard length <= 1 << 17 else {
                    throw AnywhereError.tls(.record(.malformed(detail: "post-handshake message too large (\(length) bytes)")))
                }
                break
            }

            if type == TLSHandshakeType.keyUpdate {
                rekeyIngress()
                let requestUpdate = length >= 1 ? messages[bodyStart] : 0
                if requestUpdate == 1 {
                    state.keyUpdateResponsePending = true
                }
            }
            i = bodyEnd
        }
        state.pendingPostHandshake = i < end ? Data(messages[i..<end]) : Data()
    }
    
    private func rekeyIngress() {
        let keyDerivation = TLS13KeyDerivation(cipherSuite: cipherSuite)
        mutateIngressState { state in
            guard let current = state.appSecret else { return }
            let next = keyDerivation.nextApplicationGeneration(trafficSecret: current)
            state.appSecret = next.secret
            state.key = next.key
            state.iv = next.iv
            state.symmetricKey = SymmetricKey(data: next.key)
            state.seqNum = 0
        }
    }
    
    func enqueueKeyUpdateResponseAndRekeyEgress() {
        enqueueChainedSend { [self] in
            let record: Data
            do {
                let keyUpdate = Data([TLSHandshakeType.keyUpdate, 0x00, 0x00, 0x01, 0x00])
                record = try encryptTLS13Record(plaintext: keyUpdate, contentType: TLSContentType.handshake)
            } catch {
                return
            }

            if let connection {
                try? await connection.send(record)
            }

            let kd = TLS13KeyDerivation(cipherSuite: cipherSuite)
            mutateEgressState { state in
                guard let current = state.appSecret else { return }
                let next = kd.nextApplicationGeneration(trafficSecret: current)
                state.appSecret = next.secret
                state.key = next.key
                state.iv = next.iv
                state.symmetricKey = SymmetricKey(data: next.key)
                state.seqNum = 0
            }
        }
    }
}
