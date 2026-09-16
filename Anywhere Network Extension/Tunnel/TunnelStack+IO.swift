//
//  TunnelStack+IO.swift
//  Anywhere
//
//  Created by NodePassProject on 3/30/26.
//

import Foundation
import NetworkExtension
import Synchronization

nonisolated private let logger = AnywhereLogger(category: "TunnelStack+IO")

extension TunnelStack {

    // MARK: - Output Batching

    nonisolated func drainOutputLoop(packetFlow: NEPacketTunnelFlow) async {
        while true {
            var packets: [Data] = []
            var protocols: [NSNumber] = []
            var releases: [LWIPReleaseAction] = []

            outputBuffer.withLock { buffer in
                let pending = buffer.packets.count
                if pending == 0 {
                    buffer.drainInFlight = false
                    return
                }
                packets = buffer.packets
                protocols = buffer.protocols
                releases = buffer.releases
                buffer.packets = []
                buffer.protocols = []
                buffer.releases = []
            }

            if packets.isEmpty { return }
            packetFlow.writePackets(packets, withProtocols: protocols)

            if !releases.isEmpty {
                let toRelease = releases
                lwipBridge.enqueue {
                    for release in toRelease {
                        release.run()
                    }
                }
            }

            await Task.yield()
        }
    }
    
    func flushOutputBuffer() {
        guard let packetFlow else { return }
        let (packets, protocols, releases) = outputBuffer.withLock { buffer in
            defer {
                buffer.packets.removeAll(keepingCapacity: true)
                buffer.protocols.removeAll(keepingCapacity: true)
                buffer.releases.removeAll(keepingCapacity: true)
            }
            return (buffer.packets, buffer.protocols, buffer.releases)
        }
        guard !packets.isEmpty else { return }
        packetFlow.writePackets(packets, withProtocols: protocols)
        for release in releases {
            release.run()
        }
    }

    nonisolated func enqueueOutbound(_ packet: Data, isIPv6: Bool) {
        let proto: NSNumber = isIPv6 ? Self.ipv6Proto : Self.ipv4Proto
        let needsKick: Bool = outputBuffer.withLock { buffer in
            buffer.packets.append(packet)
            buffer.protocols.append(proto)
            buffer.releases.append(.noop)
            if buffer.drainInFlight { return false }
            buffer.drainInFlight = true
            return true
        }
        if needsKick {
            kickOutputDrain()
        }
    }

    // MARK: - Packet Reading

    func runReadLoop(packetFlow: NEPacketTunnelFlow, udpPlane: UDPPlane) async {
        let demand = AsyncInbox<Void>(capacity: 1)
        demand.yield(())
        let batches = AsyncStream<[Data]> { continuation in
            let producer = Task {
                while (try? await demand.next()) != nil {
                    let (packets, _) = await packetFlow.readPackets()
                    continuation.yield(packets)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
        for await packets in batches {
            demand.yield(())
            await processInboundBatch(packets, udpPlane: udpPlane)
        }
    }

    private func processInboundBatch(_ packets: [Data], udpPlane: UDPPlane) async {
        let reflector = reflector()
        var lwipBatch: [Data] = []
        var udpBatch: [Data] = []

        for packet in packets {
            if reflector.isActive, let reflected = reflector.reflect(packet) {
                enqueueOutbound(reflected.data, isIPv6: reflected.isIPv6)
                continue
            }
            if UDPPacket.ipProtocol(of: packet)?.proto == UDPPacket.ipProtocolUDP {
                udpBatch.append(packet)
            } else {
                lwipBatch.append(packet)
            }
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [lwipBatch] in await self.feedLwipBatch(lwipBatch) }
            group.addTask { [udpBatch] in await udpPlane.feed(udpBatch) }
        }
    }

    func feedLwipBatch(_ packets: [Data]) {
        guard dataPlaneUp, !packets.isEmpty else { return }
        lwip_bridge_input_batch_begin()
        for packet in packets {
            packet.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                lwip_bridge_input(baseAddress, Int32(buffer.count))
            }
        }
        lwip_bridge_input_batch_end()
        FlowGauge.publishTCPTable(Int(lwip_bridge_active_tcp_count()))
        if lwip_bridge_tcp_idle() == 0 {
            lwipTick?.resume()
        }
    }

    // MARK: - Timers
    
    func startLwipTick() {
        let tick = lwipBridge.makeTick(
            intervalMs: TunnelConstants.lwipTickIntervalMs,
            leewayMs: TunnelConstants.lwipTickLeewayMs
        ) { [weak self] in
            guard let self, self.publishedPhase.load(ordering: .relaxed).isActive else { return }
            lwip_bridge_tick()
            FlowGauge.publishTCPTable(Int(lwip_bridge_active_tcp_count()))
            if lwip_bridge_tcp_idle() != 0 {
                self.assumeIsolated { $0.lwipTick?.suspend() }
            }
        }
        tick.suspend()
        lwipTick = tick
    }

    nonisolated func runUDPCleanupLoop(udpPlane: UDPPlane) async {
        let interval = TimeInterval(TunnelConstants.udpCleanupIntervalSec)
        var lastRun = MonotonicClock.now
        while !Task.isCancelled {
            guard publishedPhase.load(ordering: .relaxed) == .running else {
                guard (try? await udpCleanupResume.next()) != nil else { return }
                lastRun = MonotonicClock.now
                continue
            }
            let remaining = interval - (MonotonicClock.now - lastRun)
            if remaining > 0 {
                try? await Task.sleep(
                    for: .seconds(remaining),
                    tolerance: .milliseconds(TunnelConstants.udpCleanupLeewayMs)
                )
                continue
            }
            await udpPlane.cleanup()
            lastRun = MonotonicClock.now
        }
    }
}
