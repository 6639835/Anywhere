//
//  TunnelStack+Reflection.swift
//  Anywhere
//
//  Created by NodePassProject on 5/31/26.
//

import Foundation

extension TunnelStack {
    struct Reflector {
        let ipv4Routes: [(network: UInt32, mask: UInt32)]
        let ipv6Routes: [(network: SIMD16<UInt8>, mask: SIMD16<UInt8>)]

        var isActive: Bool { !ipv4Routes.isEmpty || !ipv6Routes.isEmpty }

        static let inactive = Reflector(routes: [])
        
        init(routes: [String]) {
            var v4: [(network: UInt32, mask: UInt32)] = []
            var v6: [(network: SIMD16<UInt8>, mask: SIMD16<UInt8>)] = []
            for route in routes.compactMap({ IPRoute(reflection: $0) }) {
                switch route {
                case .ipv4(let network, let prefixLength):
                    v4.append((network, IPRoute.ipv4Mask(prefixLength: prefixLength)))
                case .ipv6(let network, let prefixLength):
                    v6.append((network, IPRoute.ipv6Mask(prefixLength: prefixLength)))
                }
            }
            self.ipv4Routes = v4
            self.ipv6Routes = v6
        }
        
        func reflect(_ packet: Data) -> (data: Data, isIPv6: Bool)? {
            let match: Bool? = packet.withUnsafeBytes { raw -> Bool? in
                guard let p = raw.bindMemory(to: UInt8.self).baseAddress, raw.count >= 1 else { return nil }
                switch (p[0] >> 4) & 0x0F {
                case 4:
                    guard raw.count >= 20 else { return nil }
                    let destination = UInt32(p[16]) << 24 | UInt32(p[17]) << 16 | UInt32(p[18]) << 8 | UInt32(p[19])
                    return ipv4Routes.contains { (destination & $0.mask) == $0.network } ? false : nil
                case 6:
                    guard raw.count >= 40 else { return nil }
                    var destination = SIMD16<UInt8>()
                    for i in 0..<16 { destination[i] = p[24 + i] }
                    return ipv6Routes.contains { (destination & $0.mask) == $0.network } ? true : nil
                default:
                    return nil
                }
            }
            guard let isIPv6 = match else { return nil }
            
            var out = packet
            out.withUnsafeMutableBytes { raw in
                guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                if isIPv6 {
                    for i in 0..<16 { swap(&p[8 + i], &p[24 + i]) }
                } else {
                    for i in 0..<4 { swap(&p[12 + i], &p[16 + i]) }
                }
            }
            return (out, isIPv6)
        }
    }
}
