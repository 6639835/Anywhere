//
//  UDPPacket.swift
//  Anywhere
//
//  Created by NodePassProject on 5/23/26.
//

import Foundation

nonisolated enum UDPPacket {
    static let ipProtocolUDP: UInt8 = 17
    
    struct Inbound {
        let isIPv6: Bool
        let srcIP: SIMD16<UInt8>
        let srcPort: UInt16
        let dstIP: SIMD16<UInt8>
        let dstPort: UInt16
        let payload: Data

        var addrLen: Int { isIPv6 ? 16 : 4 }
        var srcIPData: Data { UDPPacket.ipData(srcIP, count: addrLen) }
        var dstIPData: Data { UDPPacket.ipData(dstIP, count: addrLen) }
    }
    
    static func ipProtocol(of packet: Data) -> (isIPv6: Bool, proto: UInt8)? {
        packet.withUnsafeBytes { raw -> (Bool, UInt8)? in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let length = raw.count
            guard length >= 1 else { return nil }
            switch (p[0] >> 4) & 0x0F {
            case 4: return length >= 20 ? (false, p[9]) : nil
            case 6: return length >= 40 ? (true, p[6]) : nil
            default: return nil
            }
        }
    }
    
    static func parse(_ packet: Data) -> Inbound? {
        packet.withUnsafeBytes { raw -> Inbound? in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let length = raw.count
            guard length >= 1 else { return nil }

            switch (p[0] >> 4) & 0x0F {
            case 4:
                guard length >= 20 else { return nil }
                let ihl = Int(p[0] & 0x0F) * 4
                guard ihl >= 20, length >= ihl + 8, p[9] == ipProtocolUDP else { return nil }
                let fragWord = (UInt16(p[6]) << 8) | UInt16(p[7])
                guard fragWord & 0x3FFF == 0 else { return nil }
                return finish(p, len: length, headerLen: ihl, isIPv6: false, srcOffset: 12, dstOffset: 16, addrLen: 4)
            case 6:
                guard length >= 48, p[6] == ipProtocolUDP else { return nil }
                return finish(p, len: length, headerLen: 40, isIPv6: true, srcOffset: 8, dstOffset: 24, addrLen: 16)
            default:
                return nil
            }
        }
    }

    private static func finish(
        _ packetBytes: UnsafePointer<UInt8>,
        len: Int,
        headerLen: Int,
        isIPv6: Bool,
        srcOffset: Int,
        dstOffset: Int,
        addrLen: Int
    ) -> Inbound? {
        let udpHeader = packetBytes + headerLen
        let srcPort = (UInt16(udpHeader[0]) << 8) | UInt16(udpHeader[1])
        let dstPort = (UInt16(udpHeader[2]) << 8) | UInt16(udpHeader[3])
        let udpLen = Int((UInt16(udpHeader[4]) << 8) | UInt16(udpHeader[5]))
        guard udpLen >= 8 else { return nil }
        let payloadLen = min(udpLen, len - headerLen) - 8
        return Inbound(
            isIPv6: isIPv6,
            srcIP: loadIP(packetBytes + srcOffset, addrLen),
            srcPort: srcPort,
            dstIP: loadIP(packetBytes + dstOffset, addrLen),
            dstPort: dstPort,
            payload: Data(bytes: udpHeader + 8, count: payloadLen)
        )
    }

    // MARK: - Inline address storage
    
    private static func loadIP(_ p: UnsafePointer<UInt8>, _ len: Int) -> SIMD16<UInt8> {
        var v = SIMD16<UInt8>()
        withUnsafeMutableBytes(of: &v) { $0.baseAddress!.copyMemory(from: p, byteCount: len) }
        return v
    }
    
    static func loadIP(_ data: Data) -> SIMD16<UInt8> {
        var v = SIMD16<UInt8>()
        let n = min(data.count, 16)
        guard n > 0 else { return v }
        withUnsafeMutableBytes(of: &v) { destination in
            data.withUnsafeBytes { source in destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: n) }
        }
        return v
    }
    
    static func ipData(_ v: SIMD16<UInt8>, count: Int) -> Data {
        withUnsafeBytes(of: v) { Data(bytes: $0.baseAddress!, count: count) }
    }
    
    static func build(
        srcIP: Data,
        srcPort: UInt16,
        dstIP: Data,
        dstPort: UInt16,
        isIPv6: Bool,
        payload: Data
    ) -> Data? {
        let addrLen = isIPv6 ? 16 : 4
        guard srcIP.count == addrLen, dstIP.count == addrLen else { return nil }
        let udpLen = 8 + payload.count
        guard udpLen <= 0xFFFF else { return nil }

        return isIPv6
            ? buildV6(srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, payload: payload, udpLen: udpLen)
            : buildV4(srcIP: srcIP, srcPort: srcPort, dstIP: dstIP, dstPort: dstPort, payload: payload, udpLen: udpLen)
    }

    private static func buildV4(
        srcIP: Data,
        srcPort: UInt16,
        dstIP: Data,
        dstPort: UInt16,
        payload: Data,
        udpLen: Int
    ) -> Data {
        let total = 20 + udpLen
        var packet = Data(count: total)
        packet.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self).baseAddress!

            // --- IPv4 header ---
            p[0] = 0x45                                  // Version 4, IHL 5
            p[1] = 0x00                                  // DSCP/ECN
            p[2] = UInt8(total >> 8); p[3] = UInt8(total & 0xFF)
            p[4] = 0; p[5] = 0                           // Identification
            p[6] = 0; p[7] = 0                           // Flags + fragment offset
            p[8] = 64                                    // TTL
            p[9] = ipProtocolUDP                         // Protocol: UDP
            p[10] = 0; p[11] = 0                         // Header checksum (below)
            srcIP.copyBytes(to: p + 12, count: 4)
            dstIP.copyBytes(to: p + 16, count: 4)

            writeUDP(p, udpStart: 20, srcPort: srcPort, dstPort: dstPort, udpLen: udpLen, payload: payload)

            // IPv4 header checksum (0 is a valid result; no all-ones rule here)
            let ipck = fold(sum(p, 0, 20))
            p[10] = UInt8(ipck >> 8); p[11] = UInt8(ipck & 0xFF)

            // UDP checksum: pseudo-header (src+dst+proto+len) + UDP header + payload
            let psum = sum(p, 12, 20) + UInt32(ipProtocolUDP) + UInt32(udpLen) + sum(p, 20, total)
            var udpck = fold(psum)
            if udpck == 0 { udpck = 0xFFFF }             // 0 means "no checksum"; send all-ones
            p[26] = UInt8(udpck >> 8); p[27] = UInt8(udpck & 0xFF)
        }
        return packet
    }

    private static func buildV6(
        srcIP: Data,
        srcPort: UInt16,
        dstIP: Data,
        dstPort: UInt16,
        payload: Data,
        udpLen: Int
    ) -> Data {
        let total = 40 + udpLen
        var packet = Data(count: total)
        packet.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self).baseAddress!

            // --- IPv6 header (no header checksum in IPv6) ---
            p[0] = 0x60; p[1] = 0; p[2] = 0; p[3] = 0    // Version 6, TC/flow 0
            p[4] = UInt8(udpLen >> 8); p[5] = UInt8(udpLen & 0xFF)  // Payload length
            p[6] = ipProtocolUDP                          // Next header: UDP
            p[7] = 64                                     // Hop limit
            srcIP.copyBytes(to: p + 8, count: 16)
            dstIP.copyBytes(to: p + 24, count: 16)

            writeUDP(p, udpStart: 40, srcPort: srcPort, dstPort: dstPort, udpLen: udpLen, payload: payload)

            // UDP checksum is mandatory over IPv6; pseudo-header per RFC 8200 §8.1.
            let psum = sum(p, 8, 40) + UInt32(udpLen) + UInt32(ipProtocolUDP) + sum(p, 40, total)
            var udpck = fold(psum)
            if udpck == 0 { udpck = 0xFFFF }
            p[46] = UInt8(udpck >> 8); p[47] = UInt8(udpck & 0xFF)
        }
        return packet
    }
    
    private static func writeUDP(
        _ p: UnsafeMutablePointer<UInt8>,
        udpStart: Int,
        srcPort: UInt16,
        dstPort: UInt16,
        udpLen: Int,
        payload: Data
    ) {
        p[udpStart + 0] = UInt8(srcPort >> 8); p[udpStart + 1] = UInt8(srcPort & 0xFF)
        p[udpStart + 2] = UInt8(dstPort >> 8); p[udpStart + 3] = UInt8(dstPort & 0xFF)
        p[udpStart + 4] = UInt8(udpLen >> 8);  p[udpStart + 5] = UInt8(udpLen & 0xFF)
        p[udpStart + 6] = 0; p[udpStart + 7] = 0   // checksum placeholder
        if !payload.isEmpty {
            payload.copyBytes(to: p + udpStart + 8, count: payload.count)
        }
    }
    
    private static func sum(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int) -> UInt32 {
        var acc: UInt32 = 0
        var i = start
        while i + 1 < end { acc += (UInt32(p[i]) << 8) | UInt32(p[i + 1]); i += 2 }
        if i < end { acc += UInt32(p[i]) << 8 }
        return acc
    }
    
    private static func fold(_ acc: UInt32) -> UInt16 {
        var s = acc
        while s > 0xFFFF { s = (s & 0xFFFF) + (s >> 16) }
        return ~UInt16(s & 0xFFFF)
    }
}
