//
//  TunnelStack+Callbacks.swift
//  Anywhere
//
//  Created by NodePassProject on 3/30/26.
//

import Foundation
import Synchronization
import AnywhereIP

nonisolated private let logger = AnywhereLogger(category: "TunnelStack+Callbacks")

extension TunnelStack {
    func installIPStackCallbacks(_ stack: IPStack) {
        stack.outputHandler = { [weak self] (packet: consuming OutboundPacket) in
            guard let self else { return }
            let data = Data(
                bytesNoCopy: UnsafeMutableRawPointer(mutating: packet.bytes.baseAddress!),
                count: packet.bytes.count,
                deallocator: .none
            )
            let isIPv6 = packet.isIPv6
            let release = packet.deferRelease()
            self.assumeIsolated { $0.ipStackDidOutput(data, isIPv6: isIPv6, release: release) }
        }
        stack.synFilter = { [weak self] _, destination in
            guard let self else { return false }
            return self.assumeIsolated { !$0.isRejectMarked(destination.address) && $0.ipStackSynVerdict() }
        }
        stack.strayFilter = { [weak self] _, destination in
            guard let self else { return false }
            return self.assumeIsolated { !$0.isRejectMarked(destination.address) }
        }
        stack.acceptHandler = { [weak self] connection in
            guard let self else { return .reset }
            nonisolated(unsafe) let acceptedConnection = connection
            return self.assumeIsolated { $0.accept(acceptedConnection) }
        }
    }

    private func isRejectMarked(_ address: IPAddress) -> Bool {
        withUnsafeTemporaryAllocation(byteCount: 16, alignment: 8) { bytes in
            address.write(to: bytes.baseAddress!)
            return connectionRouter.isRejectMarkedDestination(rawIP: bytes.baseAddress!, isIPv6: address.isIPv6)
        }
    }

    func ipStackDidOutput(_ packet: Data, isIPv6: Bool, release: PacketRelease) {
        let proto: NSNumber = isIPv6 ? Self.ipv6Proto : Self.ipv4Proto
        let needsKick: Bool = outputBuffer.withLock { buffer in
            buffer.packets.append(packet)
            buffer.protocols.append(proto)
            buffer.releases.append(release)
            if buffer.drainInFlight { return false }
            buffer.drainInFlight = true
            return true
        }
        if needsKick { kickOutputDrain() }
    }

    private func ipStackSynVerdict() -> Bool {
        guard let ipStack, ipStack.activeConnectionCount >= TunnelLimits.tcpMaxConnections else { return true }
        let now = MonotonicClock.now
        guard let victim = findPressureVictim(now: now) else {
            tcpPressureLog.noteDropped(now: now, logger: logger)
            return false
        }
        victim.connection.assumeIsolated { $0.evictForConnectionPressure(idleFor: victim.idleFor) }
        tcpPressureLog.noteEvicted(now: now, logger: logger)
        return true
    }

    private func findPressureVictim(now: TimeInterval) -> (connection: TCPConnection, idleFor: TimeInterval)? {
        var establishing: (connection: TCPConnection, idleFor: TimeInterval)?
        var established: (connection: TCPConnection, idleFor: TimeInterval)?
        ipStack?.forEachConnection { connection in
            guard let delegate = connection.delegate as? TCPConnection,
                  let tier = delegate.assumeIsolated({ $0.connectionPressureCandidate(now: now) }) else { return }
            switch tier {
            case .establishing(let idleFor):
                if idleFor > (establishing?.idleFor ?? -1) { establishing = (delegate, idleFor) }
            case .established(let idleFor):
                if idleFor > (established?.idleFor ?? -1) { established = (delegate, idleFor) }
            }
        }
        return establishing ?? established
    }

    private func accept(_ connection: IPStack.Connection) -> AcceptVerdict {
        guard let defaultConfiguration = configuration else {
            logger.debug("[TunnelStack] tcp_accept: guard failed")
            return .reset
        }
        let dstIPString = connection.destination.address.description
        let dstPort = connection.destination.port
        let decision = connectionRouter.decision(forIP: dstIPString, port: dstPort, proto: "TCP")

        var connectionConfiguration = defaultConfiguration
        var routeTarget: RouteTarget = .default
        var ruleSetName: String? = nil

        switch decision.action {
        case .route(let target, let configuration, let matchedRuleSet):
            routeTarget = target
            ruleSetName = matchedRuleSet
            if let configuration {
                connectionConfiguration = configuration
            }
        case .reject(let matchedRuleSet):
            requestLog.record(
                protocol: .tcp,
                host: decision.host,
                port: dstPort,
                routeTarget: .reject,
                ruleSetName: matchedRuleSet
            )
            let reason = decision.hostIsResolvedDomain ? "fake-IP domain rule" : "IP rule"
            logger.debug("[TCP] Rejected by \(reason) (going dark): \(decision.host):\(dstPort)")
            return .drop
        case .unreachable:
            logger.debug("[TCP] Aborted (stale fake-IP): \(dstIPString):\(dstPort)")
            return .reset
        }

        let dstHost = decision.host

        var sniffSNI = !decision.hostIsResolvedDomain
        if mitmEnabled && mitmPolicy.matches(dstHost) {
            sniffSNI = true
        }
        
        nonisolated(unsafe) let nativeConnection = connection
        let delegate = TCPConnection(
            stack: self,
            connection: nativeConnection,
            dstHost: dstHost,
            dstPort: dstPort,
            configuration: connectionConfiguration,
            routeTarget: routeTarget,
            ruleSetName: ruleSetName,
            sniffSNI: sniffSNI,
            hostIsResolvedDomain: decision.hostIsResolvedDomain,
            bridge: ipBridge
        )
        connection.delegate = delegate
        delegate.assumeIsolated { $0.start() }
        return .accept
    }
}
