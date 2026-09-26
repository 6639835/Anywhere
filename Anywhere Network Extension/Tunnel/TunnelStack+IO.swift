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
            
            if Task.isCancelled { return }
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

        for packet in packets {
            if reflector.isActive, let reflected = reflector.reflect(packet) {
                enqueueOutbound(reflected.data, isIPv6: reflected.isIPv6)
                continue
            }
            ipBatch.append(packet)
        }

        guard dataPlaneUp, let ipStack, !ipBatch.isEmpty else { return }
        let (datagrams, sink) = AsyncStream.makeStream(of: [InboundDatagram].self)
        datagramSink.withLock { $0 = sink }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [ipBatch] in
                await ipStack.inputBatch(ipBatch)
                sink.finish()
            }
            group.addTask {
                for await batch in datagrams { await udpPlane.feed(batch) }
            }
        }
    }

    // MARK: - Timers

    func startIPStackTick() {
        guard let ipStack else { return }
        ipStackTick = Task { await ipStack.runTimer() }
    }

    nonisolated func runUDPCleanupLoop(udpPlane: UDPPlane) async {
        let coalescing = TimeInterval(TunnelConstants.udpCleanupCoalescingSec)
        while !Task.isCancelled {
            if publishedPhase.load(ordering: .relaxed) == .running,
               let deadline = await udpPlane.cleanup() {
                await udpCleanupSleep(until: deadline + coalescing)
            } else {
                guard (try? await udpCleanupResume.next()) != nil else { return }
            }
        }
    }

    nonisolated private func udpCleanupSleep(until deadline: TimeInterval) async {
        let delay = deadline - MonotonicClock.now
        guard delay > 0 else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await Task.sleep(
                    for: .seconds(delay),
                    tolerance: .milliseconds(TunnelConstants.udpCleanupLeewayMs)
                )
            }
            group.addTask { _ = try? await self.udpCleanupResume.next() }
            defer { group.cancelAll() }
            _ = await group.next()
        }
    }
}
