//
//  TunnelStack+IO.swift
//  Anywhere
//
//  Created by NodePassProject on 3/30/26.
//

import Foundation
import Synchronization
@preconcurrency import NetworkExtension
import AnywhereIP

nonisolated private let logger = AnywhereLogger(category: "TunnelStack+IO")

extension TunnelStack {

    // MARK: - Output Batching

    nonisolated func drainOutputLoop(packetFlow: NEPacketTunnelFlow) async {
        while true {
            var packets: [Data] = []
            var protocols: [NSNumber] = []

            outputBuffer.withLock { buffer in
                let pending = buffer.packets.count
                if pending == 0 {
                    buffer.drainInFlight = false
                    return
                }
                packets = buffer.packets
                protocols = buffer.protocols
                buffer.packets = []
                buffer.protocols = []
            }

            if packets.isEmpty { return }
            packetFlow.writePackets(packets, withProtocols: protocols)

            await Task.yield()
        }
    }
    
    func flushOutputBuffer() {
        guard let packetFlow else { return }
        let (packets, protocols) = outputBuffer.withLock { buffer in
            defer {
                buffer.packets.removeAll(keepingCapacity: true)
                buffer.protocols.removeAll(keepingCapacity: true)
            }
            return (buffer.packets, buffer.protocols)
        }
        guard !packets.isEmpty else { return }
        packetFlow.writePackets(packets, withProtocols: protocols)
    }

    nonisolated func enqueueOutbound(_ packet: Data, isIPv6: Bool) {
        let proto: NSNumber = isIPv6 ? Self.ipv6Proto : Self.ipv4Proto
        let needsKick: Bool = outputBuffer.withLock { buffer in
            buffer.packets.append(packet)
            buffer.protocols.append(proto)
            if buffer.drainInFlight { return false }
            buffer.drainInFlight = true
            return true
        }
        if needsKick {
            kickOutputDrain()
        }
    }

    nonisolated func enqueueTCPOutput(_ packets: [OutboundPacket], generation: UInt64) {
        let needsKick = outputBuffer.withLock { buffer in
            guard buffer.generation == generation, !packets.isEmpty else { return false }
            for packet in packets {
                buffer.packets.append(packet.data)
                buffer.protocols.append(packet.isIPv6 ? Self.ipv6Proto : Self.ipv4Proto)
            }
            guard !buffer.drainInFlight else { return false }
            buffer.drainInFlight = true
            return true
        }
        if needsKick { kickOutputDrain() }
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
        var ipBatch: [Data] = []
        var udpBatch: [Data] = []

        for packet in packets {
            if reflector.isActive, let reflected = reflector.reflect(packet) {
                enqueueOutbound(reflected.data, isIPv6: reflected.isIPv6)
                continue
            }
            if UDPPacket.ipProtocol(of: packet)?.proto == UDPPacket.ipProtocolUDP {
                udpBatch.append(packet)
            } else {
                ipBatch.append(packet)
            }
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [ipBatch] in await self.feedIPStackBatch(ipBatch) }
            group.addTask { [udpBatch] in await udpPlane.feed(udpBatch) }
        }
    }

    func feedIPStackBatch(_ packets: [Data]) async {
        guard dataPlaneUp, let ipStack, !packets.isEmpty else { return }
        await ipStack.inputBatch(packets)
    }

    // MARK: - Timers

    func startIPStackTick() {
        guard let ipStack else { return }
        let generation = dataPlaneGeneration.load(ordering: .acquiring)
        ipStackTick = Task { [weak self] in
            await ipStack.runTimer { [weak self] count in
                guard let self, self.dataPlaneGeneration.load(ordering: .acquiring) == generation else { return }
                FlowGauge.publishTCPTable(count)
            }
        }
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
