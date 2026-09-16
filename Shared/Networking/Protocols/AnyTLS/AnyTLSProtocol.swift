//
//  AnyTLSProtocol.swift
//  Anywhere
//
//  Created by NodePassProject on 5/16/26.
//

import Foundation
import CommonCrypto

nonisolated enum AnyTLSProtocol {

    // MARK: - Frame commands

    static let cmdWaste:               UInt8 = 0
    static let cmdSYN:                 UInt8 = 1
    static let cmdPSH:                 UInt8 = 2
    static let cmdFIN:                 UInt8 = 3
    static let cmdSettings:            UInt8 = 4
    static let cmdAlert:               UInt8 = 5
    static let cmdUpdatePaddingScheme: UInt8 = 6
    static let cmdSYNACK:              UInt8 = 7
    static let cmdHeartRequest:        UInt8 = 8
    static let cmdHeartResponse:       UInt8 = 9
    static let cmdServerSettings:      UInt8 = 10
    
    static let headerSize: Int = 7

    // MARK: - Client identity
    
    static let clientVersion: String = "sing-anytls/0.0.11"

    // MARK: - UoT
    
    static let uotMagicAddress: String = "sp.v2.udp-over-tcp.arpa"

    // MARK: - Password
    
    static func passwordHash(_ password: String) -> Data {
        let bytes = Array(password.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        bytes.withUnsafeBytes { pointer in
            if let base = pointer.baseAddress {
                CC_SHA256(base, CC_LONG(bytes.count), &digest)
            }
        }
        return Data(digest)
    }

    // MARK: - Address
    
    static func encodeAddrPort(host: String, port: UInt16) -> Data {
        var data = Data()
        if let ipv4 = parseIPv4(host) {
            data.append(0x01)
            data.append(contentsOf: ipv4)
        } else if let ipv6 = parseIPv6(host) {
            data.append(0x04)
            data.append(contentsOf: ipv6)
        } else {
            let domainBytes = Array(host.utf8)
            data.append(0x03)
            data.append(UInt8(min(domainBytes.count, 255)))
            data.append(contentsOf: domainBytes.prefix(255))
        }
        data.append(UInt8(port >> 8))
        data.append(UInt8(port & 0xFF))
        return data
    }

    // MARK: - Frame header
    
    static func encodeFrameHeader(cmd: UInt8, sid: UInt32, length: UInt16) -> Data {
        var data = Data(count: headerSize)
        writeFrameHeader(into: &data, at: data.startIndex, cmd: cmd, sid: sid, length: length)
        return data
    }

    private static func writeFrameHeader(into data: inout Data, at index: Data.Index,
                                         cmd: UInt8, sid: UInt32, length: UInt16) {
        data[index]     = cmd
        data[index + 1] = UInt8((sid >> 24) & 0xFF)
        data[index + 2] = UInt8((sid >> 16) & 0xFF)
        data[index + 3] = UInt8((sid >>  8) & 0xFF)
        data[index + 4] = UInt8( sid        & 0xFF)
        data[index + 5] = UInt8((length >> 8) & 0xFF)
        data[index + 6] = UInt8( length       & 0xFF)
    }

    static func decodeFrameHeader(_ bytes: Data, at offset: Int = 0) -> (cmd: UInt8, sid: UInt32, length: UInt16)? {
        guard bytes.count - offset >= headerSize else { return nil }
        let i = bytes.startIndex + offset
        let cmd = bytes[i]
        let sid = (UInt32(bytes[i + 1]) << 24)
                | (UInt32(bytes[i + 2]) << 16)
                | (UInt32(bytes[i + 3]) <<  8)
                |  UInt32(bytes[i + 4])
        let length = (UInt16(bytes[i + 5]) << 8) | UInt16(bytes[i + 6])
        return (cmd, sid, length)
    }

    static func encodeFrame(cmd: UInt8, sid: UInt32, payload: Data) -> Data {
        let length = UInt16(min(payload.count, Int(UInt16.max)))
        var frame = Data(capacity: headerSize + Int(length))
        frame.append(contentsOf: repeatElement(0, count: headerSize))
        writeFrameHeader(into: &frame, at: frame.startIndex, cmd: cmd, sid: sid, length: length)
        frame.append(payload.prefix(Int(length)))
        return frame
    }

    // MARK: - StringMap
    
    static func encodeStringMap(_ map: [String: String]) -> Data {
        let lines = map
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        return Data(lines.joined(separator: "\n").utf8)
    }
    
    static func decodeStringMap(_ data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var map: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let eq = line.firstIndex(of: "=") {
                let key = String(line[..<eq])
                let value = String(line[line.index(after: eq)...])
                map[key] = value
            }
        }
        return map
    }

    // MARK: - IP parsing

    private static func parseIPv4(_ address: String) -> [UInt8]? {
        var addr = in_addr()
        guard inet_pton(AF_INET, address, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    private static func parseIPv6(_ address: String) -> [UInt8]? {
        var clean = address
        if clean.hasPrefix("[") && clean.hasSuffix("]") {
            clean = String(clean.dropFirst().dropLast())
        }
        var addr = in6_addr()
        guard inet_pton(AF_INET6, clean, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }
}
