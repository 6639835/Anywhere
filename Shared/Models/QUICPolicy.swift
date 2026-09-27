//
//  QUICPolicy.swift
//  Anywhere
//
//  Created by NodePassProject on 5/23/26.
//

import Foundation

/// Dropping UDP/443 with ICMP port-unreachable makes HTTP/3 clients fail fast and fall
/// back to HTTP/2 over TCP, where routing and MITM can act on the connection.
nonisolated enum QUICPolicy: String, CaseIterable {
    /// A QUIC-based proxy's own transport (e.g. Hysteria) leaves on a kernel-excluded socket and is unaffected.
    case blocked
    case automatic
    case unblocked

    var title: String {
        switch self {
        case .blocked: return String(localized: "Blocked")
        case .automatic: return String(localized: "Automatic")
        case .unblocked: return String(localized: "Unblocked")
        }
    }

    /// Decided before routing resolution; only `.blocked` drops this early.
    var blocksAllQUIC: Bool { self == .blocked }

    func blocksQUIC(hostIsResolvedDomain: Bool, mitmListed: @autoclosure () -> Bool) -> Bool {
        switch self {
        case .blocked: return true
        case .automatic: return !hostIsResolvedDomain || mitmListed()
        case .unblocked: return false
        }
    }

    func blocksQUIC(isProxied: Bool) -> Bool {
        switch self {
        case .blocked: return true
        case .automatic: return isProxied
        case .unblocked: return false
        }
    }
}
