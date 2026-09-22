//
//  NowhereConfiguration.swift
//  Anywhere
//
//  Created by NodePassProject on 5/30/26.
//

import Foundation
import Security
import Synchronization

nonisolated enum NowhereNetwork: String, Codable, CaseIterable, Sendable {
    case udp
    case tcp
}

nonisolated enum NowhereMorphPrelude: String, Codable, CaseIterable, Sendable {
    case low7
    case full8

    var displayName: String {
        switch self {
        case .low7: String(localized: "7-bit Random")
        case .full8: String(localized: "8-bit Random")
        }
    }
}

nonisolated struct NowhereConfiguration: Hashable, Sendable {
    let key: String
    let tcpPort: UInt16?
    let udpPort: UInt16?
    let uplink: NowhereNetwork
    let downlink: NowhereNetwork
    let multiplex: Bool
    let morph: Bool
    let morphPrelude: NowhereMorphPrelude
    let serverName: String

    init(
        key: String,
        tcpPort: UInt16?,
        udpPort: UInt16?,
        uplink: NowhereNetwork,
        downlink: NowhereNetwork,
        multiplex: Bool,
        morph: Bool,
        morphPrelude: NowhereMorphPrelude = .low7,
        serverName: String
    ) {
        self.key = key
        self.tcpPort = tcpPort
        self.udpPort = udpPort
        self.uplink = uplink
        self.downlink = downlink
        self.multiplex = multiplex && (uplink == .tcp || downlink == .tcp)
        self.morph = morph
        self.morphPrelude = morphPrelude
        self.serverName = serverName
    }

    func resolvedPorts(serverPort: UInt16) -> (tcp: UInt16?, udp: UInt16?) {
        if tcpPort == nil && udpPort == nil {
            return (serverPort, serverPort)
        }
        return (tcpPort, udpPort)
    }

    var securityLayer: GenericSecurityLayer {
        .tls(TLSConfiguration(
            serverName: serverName,
            alpn: [NowhereProtocol.applicationProtocol],
            minVersion: .tls13,
            maxVersion: .tls13
        ))
    }
}

nonisolated extension NowhereConfiguration: Codable {
    private enum CodingKeys: String, CodingKey {
        case key, tcpPort, udpPort, uplink, downlink, multiplex, morph, morphPrelude, serverName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let tcpPort = try container.decodeIfPresent(UInt16.self, forKey: .tcpPort)
        let udpPort = try container.decodeIfPresent(UInt16.self, forKey: .udpPort)
        guard tcpPort != 0, udpPort != 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: tcpPort == 0 ? .tcpPort : .udpPort,
                in: container,
                debugDescription: "Nowhere carrier ports must be non-zero"
            )
        }
        let uplink = try container.decodeIfPresent(NowhereNetwork.self, forKey: .uplink) ?? .tcp
        let downlink = try container.decodeIfPresent(NowhereNetwork.self, forKey: .downlink) ?? .tcp
        if tcpPort != nil || udpPort != nil {
            guard (uplink == .tcp ? tcpPort : udpPort) != nil,
                  (downlink == .tcp ? tcpPort : udpPort) != nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .uplink,
                    in: container,
                    debugDescription: "Nowhere route uses an unavailable carrier"
                )
            }
        }

        self.init(
            key: try container.decode(String.self, forKey: .key),
            tcpPort: tcpPort,
            udpPort: udpPort,
            uplink: uplink,
            downlink: downlink,
            multiplex: try container.decodeIfPresent(Bool.self, forKey: .multiplex) ?? false,
            morph: try container.decodeIfPresent(Bool.self, forKey: .morph) ?? false,
            morphPrelude: try container.decodeIfPresent(NowhereMorphPrelude.self, forKey: .morphPrelude) ?? .low7,
            serverName: try container.decode(String.self, forKey: .serverName)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encodeIfPresent(tcpPort, forKey: .tcpPort)
        try container.encodeIfPresent(udpPort, forKey: .udpPort)
        try container.encode(uplink, forKey: .uplink)
        try container.encode(downlink, forKey: .downlink)
        try container.encode(multiplex, forKey: .multiplex)
        try container.encode(morph, forKey: .morph)
        try container.encode(morphPrelude, forKey: .morphPrelude)
        try container.encode(serverName, forKey: .serverName)
    }
}

nonisolated struct NowhereTransportIdentity: Hashable, Sendable {
    let configurationID: UUID
    let proxyHost: String
    let proxyTCPPort: UInt16?
    let proxyUDPPort: UInt16?
    let key: String
    let uplink: NowhereNetwork
    let downlink: NowhereNetwork
    let multiplex: Bool
    let morph: Bool
    let morphPrelude: NowhereMorphPrelude
    let serverName: String
}

nonisolated struct NowhereRuntimeConfiguration: Hashable, Sendable {
    let proxyHost: String
    let proxyTCPPort: UInt16?
    let proxyUDPPort: UInt16?
    let key: String
    let uplink: NowhereNetwork
    let downlink: NowhereNetwork
    let multiplex: Bool
    let morph: Bool
    let morphPrelude: NowhereMorphPrelude
    let sessionID: Data
    let serverName: String
    let authKey: NowhereProtocol.AuthKey
    let morphKeys: NowhereMorph.Keys?

    init(
        proxyHost: String,
        proxyTCPPort: UInt16?,
        proxyUDPPort: UInt16?,
        key: String,
        uplink: NowhereNetwork,
        downlink: NowhereNetwork,
        multiplex: Bool,
        morph: Bool,
        morphPrelude: NowhereMorphPrelude = .low7,
        sessionID: Data,
        serverName: String
    ) throws {
        guard sessionID.count == 16 else {
            throw AnywhereError.proxy(.nowhere, .protocolViolation(detail: "Invalid Nowhere session ID"))
        }
        guard proxyTCPPort != nil || proxyUDPPort != nil else {
            throw AnywhereError.proxy(.nowhere, .protocolViolation(detail: "Nowhere requires a carrier port"))
        }
        guard proxyTCPPort.map({ $0 != 0 }) ?? true,
              proxyUDPPort.map({ $0 != 0 }) ?? true else {
            throw AnywhereError.proxy(.nowhere, .protocolViolation(detail: "Nowhere carrier ports must be non-zero"))
        }
        guard (uplink == .tcp ? proxyTCPPort : proxyUDPPort) != nil,
              (downlink == .tcp ? proxyTCPPort : proxyUDPPort) != nil else {
            throw AnywhereError.proxy(.nowhere, .protocolViolation(detail: "Nowhere route uses an unavailable carrier"))
        }
        self.proxyHost = proxyHost
        self.proxyTCPPort = proxyTCPPort
        self.proxyUDPPort = proxyUDPPort
        self.key = key
        self.uplink = uplink
        self.downlink = downlink
        self.multiplex = multiplex && (uplink == .tcp || downlink == .tcp)
        self.morph = morph
        self.morphPrelude = morphPrelude
        self.sessionID = sessionID
        self.serverName = serverName
        self.authKey = try NowhereProtocol.deriveAuthKey(sharedKey: key)
        self.morphKeys = morph ? try NowhereMorph.deriveKeys(sharedKey: key) : nil
    }

    var tlsConfiguration: TLSConfiguration {
        TLSConfiguration(
            serverName: serverName,
            alpn: [NowhereProtocol.applicationProtocol],
            minVersion: .tls13,
            maxVersion: .tls13,
            insecureSkipVerify: false
        )
    }

    func proxyPort(for network: NowhereNetwork) throws -> UInt16 {
        let port = network == .tcp ? proxyTCPPort : proxyUDPPort
        guard let port else {
            throw AnywhereError.proxy(.nowhere, .protocolViolation(detail: "Nowhere carrier port unavailable"))
        }
        return port
    }
}

nonisolated final class NowhereFlowIDLease: Sendable {
    let flowID: UInt32
    private let releaseImpl: @Sendable (UInt32) -> Void
    private let released = Mutex(false)

    init(flowID: UInt32, release: @escaping @Sendable (UInt32) -> Void) {
        self.flowID = flowID
        self.releaseImpl = release
    }

    func release() {
        let shouldRelease = released.withLock { released in
            guard !released else { return false }
            released = true
            return true
        }
        if shouldRelease { releaseImpl(flowID) }
    }

    deinit { release() }
}

nonisolated final class NowhereTransportIdentityRegistry: Sendable {
    static let shared = NowhereTransportIdentityRegistry()

    private struct State {
        let sessionID: Data
        var nextFlowID: UInt32
        var activeFlowIDs: Set<UInt32>
    }

    private let states = Mutex<[NowhereTransportIdentity: State]>([:])

    init() {}

    func sessionID(for transportIdentity: NowhereTransportIdentity) throws -> Data {
        try states.withLock { states in
            if let state = states[transportIdentity] { return state.sessionID }
            var bytes = Data(count: 16)
            let status = bytes.withUnsafeMutableBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return errSecAllocate }
                return SecRandomCopyBytes(kSecRandomDefault, 16, base)
            }
            guard status == errSecSuccess else {
                throw AnywhereError.proxy(.nowhere, .connectionClosed(detail: "Failed to generate session ID"))
            }
            states[transportIdentity] = State(sessionID: bytes, nextFlowID: 1, activeFlowIDs: [])
            return bytes
        }
    }

    func leaseFlowID(
        for transportIdentity: NowhereTransportIdentity,
        sessionID expectedSessionID: Data
    ) throws -> NowhereFlowIDLease {
        let flowID = try states.withLock { states -> UInt32 in
            guard var state = states[transportIdentity], state.sessionID == expectedSessionID else {
                throw AnywhereError.proxy(.nowhere, .streamClosed)
            }
            var candidate = max(state.nextFlowID, 1)
            for _ in 0...state.activeFlowIDs.count {
                if candidate <= NowhereProtocol.maximumFlowID, !state.activeFlowIDs.contains(candidate) {
                    state.activeFlowIDs.insert(candidate)
                    state.nextFlowID = candidate &+ 1
                    if state.nextFlowID > NowhereProtocol.maximumFlowID { state.nextFlowID = 1 }
                    states[transportIdentity] = state
                    return candidate
                }
                candidate &+= 1
                if candidate > NowhereProtocol.maximumFlowID { candidate = 1 }
            }
            throw AnywhereError.proxy(.nowhere, .connectionClosed(detail: "Nowhere flow ID space exhausted"))
        }
        return NowhereFlowIDLease(flowID: flowID) { [weak self] released in
            self?.releaseFlowID(released, for: transportIdentity, sessionID: expectedSessionID)
        }
    }

    private func releaseFlowID(
        _ flowID: UInt32,
        for transportIdentity: NowhereTransportIdentity,
        sessionID expectedSessionID: Data
    ) {
        states.withLock { states in
            guard var state = states[transportIdentity], state.sessionID == expectedSessionID else { return }
            state.activeFlowIDs.remove(flowID)
            states[transportIdentity] = state
        }
    }

    func reset() {
        states.withLock { $0.removeAll(keepingCapacity: false) }
    }
}
