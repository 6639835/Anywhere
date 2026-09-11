//
//  TunnelStack+UDP.swift
//  Anywhere
//
//  Created by NodePassProject on 5/23/26.
//

import Foundation

nonisolated private let logger = AnywhereLogger(category: "TunnelStack+UDP")

extension TunnelStack {
    static func isSTUNMessage(_ payload: Data) -> Bool {
        guard payload.count >= 20 else { return false }
        let base = payload.startIndex
        guard payload[base] & 0xC0 == 0 else { return false }
        guard payload[base + 4] == 0x21, payload[base + 5] == 0x12,
              payload[base + 6] == 0xA4, payload[base + 7] == 0x42 else { return false }
        let messageLength = Int(payload[base + 2]) << 8 | Int(payload[base + 3])
        return messageLength & 0x3 == 0 && messageLength + 20 == payload.count
    }
    
    nonisolated func sendICMPPortUnreachable(rejecting datagram: UDPPacket.Inbound) {
        guard let packet = ICMPPacket.portUnreachable(
            srcIP: datagram.srcIPData,
            srcPort: datagram.srcPort,
            dstIP: datagram.dstIPData,
            dstPort: datagram.dstPort,
            isIPv6: datagram.isIPv6,
            udpPayloadLength: datagram.payload.count
        ) else { return }
        enqueueOutbound(packet, isIPv6: datagram.isIPv6)
    }
    
    nonisolated func writeOutboundUDP(srcIP: Data, srcPort: UInt16,
                          dstIP: Data, dstPort: UInt16,
                          isIPv6: Bool, payload: Data) {
        guard let packet = UDPPacket.build(
            srcIP: srcIP, srcPort: srcPort,
            dstIP: dstIP, dstPort: dstPort,
            isIPv6: isIPv6,
            payload: payload
        ) else {
            return
        }
        enqueueOutbound(packet, isIPv6: isIPv6)
    }
}
