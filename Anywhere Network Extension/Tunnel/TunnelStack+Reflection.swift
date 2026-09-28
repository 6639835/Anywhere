//
//  TunnelStack+Reflection.swift
//  Anywhere
//
//  Created by NodePassProject on 5/31/26.
//

import Foundation
import AnywhereIP

extension TunnelStack {
    nonisolated enum Reflector {
        private static let target: UInt32 = {
            var raw = in_addr()
            inet_pton(AF_INET, TunnelAddress.reflection, &raw)
            return UInt32(bigEndian: raw.s_addr)
        }()

        static func reflect(_ packet: UnsafeRawBufferPointer) -> OutboundPacket? {
            guard packet.count >= 20, packet[0] >> 4 == 4 else { return nil }
            let destination = UInt32(packet[16]) << 24 | UInt32(packet[17]) << 16 | UInt32(packet[18]) << 8 | UInt32(packet[19])
            guard destination == target else { return nil }
            return OutboundPacket(byteCount: packet.count, isIPv6: false) { reflected in
                reflected.copyMemory(from: packet)
                for i in 12..<16 { reflected.swapAt(i, i + 4) }
            }
        }
    }
}
