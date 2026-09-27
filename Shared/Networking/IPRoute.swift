//
//  IPRoute.swift
//  Anywhere
//
//  Created by NodePassProject on 9/26/26.
//

import Foundation

nonisolated enum IPRoute: Equatable, Sendable {
    case ipv4(network: UInt32, prefixLength: Int)
    case ipv6(network: SIMD16<UInt8>, prefixLength: Int)
    
    init?(_ string: String) {
        let parts = string.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let address = String(parts[0])
        let prefix = parts.count == 2 ? parts[1] : nil

        if address.contains(":") {
            var raw = in6_addr()
            guard inet_pton(AF_INET6, address, &raw) == 1,
                  let prefixLength = Self.prefixLength(prefix, maximum: 128) else { return nil }
            var network = SIMD16<UInt8>()
            withUnsafeBytes(of: &raw) { bytes in
                for i in 0..<16 { network[i] = bytes[i] }
            }
            self = .ipv6(network: network & Self.ipv6Mask(prefixLength: prefixLength), prefixLength: prefixLength)
        } else {
            var raw = in_addr()
            guard inet_pton(AF_INET, address, &raw) == 1,
                  let prefixLength = Self.prefixLength(prefix, maximum: 32) else { return nil }
            self = .ipv4(network: UInt32(bigEndian: raw.s_addr) & Self.ipv4Mask(prefixLength: prefixLength), prefixLength: prefixLength)
        }
    }

    init?(reflection string: String) {
        guard let route = IPRoute(string) else { return nil }
        switch route {
        case .ipv4(_, let prefixLength) where prefixLength < 24: return nil
        case .ipv6(_, let prefixLength) where prefixLength < 120: return nil
        default: break
        }
        guard !Self.tunnelHosts.contains(where: { route.contains($0) }) else { return nil }
        self = route
    }

    private static let tunnelHosts = [TunnelAddress.ipv4, TunnelAddress.ipv6].compactMap { IPRoute($0) }

    func contains(_ other: IPRoute) -> Bool {
        switch (self, other) {
        case let (.ipv4(network, prefixLength), .ipv4(otherNetwork, otherPrefixLength)):
            return otherPrefixLength >= prefixLength && (otherNetwork & Self.ipv4Mask(prefixLength: prefixLength)) == network
        case let (.ipv6(network, prefixLength), .ipv6(otherNetwork, otherPrefixLength)):
            return otherPrefixLength >= prefixLength && (otherNetwork & Self.ipv6Mask(prefixLength: prefixLength)) == network
        default:
            return false
        }
    }

    static func ipv4Mask(prefixLength: Int) -> UInt32 {
        ~UInt32(0) << (32 - prefixLength)
    }

    static func ipv6Mask(prefixLength: Int) -> SIMD16<UInt8> {
        var mask = SIMD16<UInt8>()
        for i in 0..<16 {
            mask[i] = ~UInt8(0) << (8 - min(max(prefixLength - i * 8, 0), 8))
        }
        return mask
    }

    private static func prefixLength(_ string: Substring?, maximum: Int) -> Int? {
        guard let string else { return maximum }
        guard let value = Int(string), (0...maximum).contains(value) else { return nil }
        return value
    }
}
