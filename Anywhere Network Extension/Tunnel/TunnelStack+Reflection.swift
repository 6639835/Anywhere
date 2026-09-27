//
//  TunnelStack+Reflection.swift
//  Anywhere
//
//  Created by NodePassProject on 5/31/26.
//

import Foundation

extension TunnelStack {
    nonisolated enum Reflector {
        private static let target: UInt32 = {
            var raw = in_addr()
            inet_pton(AF_INET, TunnelAddress.reflection, &raw)
            return UInt32(bigEndian: raw.s_addr)
        }()

        static func reflect(_ packet: Data) -> Data? {
            let matches = packet.withUnsafeBytes { raw -> Bool in
                guard raw.count >= 20, raw[0] >> 4 == 4 else { return false }
                let destination = UInt32(raw[16]) << 24 | UInt32(raw[17]) << 16 | UInt32(raw[18]) << 8 | UInt32(raw[19])
                return destination == target
            }
            guard matches else { return nil }

            var out = packet
            out.withUnsafeMutableBytes { raw in
                for i in 12..<16 { raw.swapAt(i, i + 4) }
            }
            return out
        }
    }
}
