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

    nonisolated func claimOutputDrain() -> Bool {
        outputBuffer.withLock { $0.claimDrain() }
    }

    nonisolated func drainOutput() {
        var packets: [OutboundPacket] = []
        while let writer = outputBuffer.withLock({ $0.take(&packets) }) {
            writer.write(packets)
            packets.removeAll(keepingCapacity: true)
        }
    }

    nonisolated func flushOutputBuffer() {
        if claimOutputDrain() { drainOutput() }
    }

    nonisolated func enqueueOutbound(_ packet: OutboundPacket) {
        let drains = outputBuffer.withLock { buffer in
            guard buffer.writer != nil else { return false }
            buffer.packets.append(packet)
            return buffer.claimDrain()
        }
        if drains { drainOutput() }
    }

    nonisolated func enqueueTCPOutput(_ packets: [OutboundPacket], generation: UInt64) {
        let drains = outputBuffer.withLock { buffer in
            guard buffer.generation == generation, buffer.writer != nil, !packets.isEmpty else { return false }
            buffer.packets.append(contentsOf: packets)
            return buffer.claimDrain()
        }
        if drains { drainOutput() }
    }

    // MARK: - Packet Reading

    nonisolated func runReadLoop(packetFlow: NEPacketTunnelFlow, udpPlane: UDPPlane) async {
        let intake = AsyncInbox<[InboundDatagram]>(capacity: TunnelConstants.udpIntakeBacklog)
        datagramIntake.withLock { $0 = intake }
        let reader = PacketReader(flow: packetFlow) { [weak self] packets in
            self?.processInbound(packets)
        }
        await withDiscardingTaskGroup { group in
            group.addTask {
                while let batches = try? await intake.nextBatch() {
                    await udpPlane.feed(batches.count == 1 ? batches[0] : Array(batches.joined()))
                }
            }
            await reader.run()
            datagramIntake.withLock { if $0 === intake { $0 = nil } }
            intake.finish()
        }
    }

    private nonisolated func processInbound(_ packets: [UnsafeRawBufferPointer]) {
        let drains = claimOutputDrain()
        var batch = packets
        if reflectionEnabled {
            batch = []
            batch.reserveCapacity(packets.count)
            for packet in packets {
                if let reflected = Reflector.reflect(packet) {
                    enqueueOutbound(reflected)
                    continue
                }
                batch.append(packet)
            }
        }
        if !batch.isEmpty, let ipStack = liveIPStack.withLock({ $0 }) {
            ipStack.input(batch)
        }
        if drains { drainOutput() }
    }
    
    nonisolated func admitDatagrams(_ batch: [InboundDatagram]) {
        datagramIntake.withLock { $0 }?.yield(batch)
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
