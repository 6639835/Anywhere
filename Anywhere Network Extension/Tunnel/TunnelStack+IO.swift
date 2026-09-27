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
        var packets: [Data] = []
        var protocols: [NSNumber] = []
        while true {
            outputBuffer.withLock { buffer in
                if buffer.packets.isEmpty {
                    buffer.drainInFlight = false
                    return
                }
                swap(&packets, &buffer.packets)
                swap(&protocols, &buffer.protocols)
            }

            if packets.isEmpty { return }
            packetFlow.writePackets(packets, withProtocols: protocols)
            packets.removeAll(keepingCapacity: true)
            protocols.removeAll(keepingCapacity: true)

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
        await consumeInbound(batches, demand: demand, udpPlane: udpPlane)
    }

    @concurrent
    private nonisolated func consumeInbound(_ batches: AsyncStream<[Data]>, demand: AsyncInbox<Void>, udpPlane: UDPPlane) async {
        datagramIntake.withLock { $0.plane = udpPlane }
        defer {
            datagramIntake.withLock { intake in
                if intake.plane === udpPlane {
                    intake.plane = nil
                    intake.pending.removeAll()
                }
            }
        }
        var datagrams: [InboundDatagram] = []
        for await packets in batches {
            demand.yield(())
            await processInboundBatch(packets, udpPlane: udpPlane, datagrams: &datagrams)
        }
    }

    private nonisolated func processInboundBatch(_ packets: [Data], udpPlane: UDPPlane, datagrams: inout [InboundDatagram]) async {
        let reflector = reflector()
        var ipBatch = packets

        if reflector.isActive {
            ipBatch = []
            for packet in packets {
                if let reflected = reflector.reflect(packet) {
                    enqueueOutbound(reflected.data, isIPv6: reflected.isIPv6)
                    continue
                }
                ipBatch.append(packet)
            }
        }

        guard !ipBatch.isEmpty, let ipStack = liveIPStack.withLock({ $0 }) else { return }
        await ipStack.inputBatch(ipBatch)
        datagramIntake.withLock { swap(&datagrams, &$0.pending) }
        guard !datagrams.isEmpty else { return }
        await udpPlane.feed(datagrams)
        datagrams.removeAll(keepingCapacity: true)
    }
    
    nonisolated func admitDatagrams(_ batch: [InboundDatagram]) {
        datagramIntake.withLock { intake in
            guard intake.plane != nil else { return }
            intake.pending.append(contentsOf: batch)
        }
    }

    // MARK: - Timers

    func startIPStackTick() {
        guard let ipStack else { return }
        ipStackTick = Task { await ipStack.runTimer() }
    }

    nonisolated func scheduleTCPIdleSweep(at deadline: TimeInterval) {
        let armed = tcpIdleSweepArmed.load(ordering: .sequentiallyConsistent)
        if armed < 0 || deadline < armed { tcpIdleSweepPoke.yield(()) }
    }

    nonisolated func runTCPIdleSweep() async {
        while !Task.isCancelled {
            tcpIdleSweepArmed.store(-1, ordering: .sequentiallyConsistent)
            let now = MonotonicClock.now
            var next = TimeInterval.infinity
            for connection in tcpConnections.withLock({ Array($0.connections.values) }) {
                guard let deadline = connection.idleDeadline else { continue }
                if deadline <= now {
                    connection.expireIdle()
                    next = min(next, now + TunnelConstants.tcpIdleSweepRecheckInterval)
                } else {
                    next = min(next, deadline)
                }
            }
            tcpIdleSweepArmed.store(next, ordering: .sequentiallyConsistent)
            if next.isFinite {
                await tcpIdleSweepSleep(until: next)
            } else if (try? await tcpIdleSweepPoke.next()) == nil {
                return
            }
        }
    }

    nonisolated private func tcpIdleSweepSleep(until deadline: TimeInterval) async {
        let delay = deadline - MonotonicClock.now
        guard delay > 0 else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await Task.sleep(
                    for: .seconds(delay),
                    tolerance: .milliseconds(TunnelConstants.tcpIdleSweepLeewayMs)
                )
            }
            group.addTask { _ = try? await self.tcpIdleSweepPoke.next() }
            defer { group.cancelAll() }
            _ = await group.next()
        }
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
