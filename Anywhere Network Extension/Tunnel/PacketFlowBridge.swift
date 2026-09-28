//
//  PacketFlowBridge.swift
//  Anywhere
//
//  Created by NodePassProject on 9/27/26.
//

import Foundation
import Synchronization
@preconcurrency import NetworkExtension
import AnywhereIP

nonisolated final class PacketFlowWriter: @unchecked Sendable {
    private typealias WritePackets = @convention(c) (NSObject, Selector, NSArray, NSArray) -> ObjCBool

    private static let selector = NSSelectorFromString("writePackets:withProtocols:")
    private static let ipv4 = NSNumber(value: AF_INET)
    private static let ipv6 = NSNumber(value: AF_INET6)

    private let flow: NEPacketTunnelFlow
    private let writePackets: WritePackets?

    init(_ flow: NEPacketTunnelFlow) {
        self.flow = flow
        writePackets = flow.responds(to: Self.selector) ? unsafeBitCast(flow.method(for: Self.selector), to: WritePackets.self) : nil
    }

    func write(_ packets: [OutboundPacket]) {
        var objects: [NSData] = []
        var protocols: [NSNumber] = []
        objects.reserveCapacity(packets.count)
        protocols.reserveCapacity(packets.count)
        for packet in packets {
            objects.append(packet.data)
            protocols.append(packet.isIPv6 ? Self.ipv6 : Self.ipv4)
        }
        if let writePackets {
            _ = writePackets(flow, Self.selector, objects as NSArray, protocols as NSArray)
        } else {
            flow.writePackets(objects.map { Data(referencing: $0) }, withProtocols: protocols)
        }
    }
}

nonisolated final class PacketReader: @unchecked Sendable {
    private typealias ReadPackets = @convention(c) (NSObject, Selector, @escaping @convention(block) (NSArray?, NSArray?) -> Void) -> Void

    private static let selector = NSSelectorFromString("readPacketsWithCompletionHandler:")

    private let flow: NEPacketTunnelFlow
    private let readPackets: ReadPackets?
    private let deliver: @Sendable ([UnsafeRawBufferPointer]) -> Void
    private let stopped = Atomic<Bool>(false)
    private let waiter = Mutex<CheckedContinuation<Void, Never>?>(nil)
    private var buffers: [UnsafeRawBufferPointer] = []

    init(flow: NEPacketTunnelFlow, deliver: @escaping @Sendable ([UnsafeRawBufferPointer]) -> Void) {
        self.flow = flow
        self.deliver = deliver
        readPackets = flow.responds(to: Self.selector) ? unsafeBitCast(flow.method(for: Self.selector), to: ReadPackets.self) : nil
    }

    func run() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.withLock { $0 = continuation }
                if stopped.load(ordering: .acquiring) {
                    stop()
                } else {
                    arm()
                }
            }
        } onCancel: {
            stop()
        }
    }

    private func stop() {
        stopped.store(true, ordering: .releasing)
        waiter.withLock { waiter in
            defer { waiter = nil }
            return waiter
        }?.resume()
    }

    private func arm() {
        if let readPackets {
            readPackets(flow, Self.selector) { [self] packets, _ in receive(packets) }
        } else {
            flow.readPackets { [self] packets, _ in receive(packets.map { $0 as NSData } as NSArray) }
        }
    }

    private func receive(_ packets: NSArray?) {
        guard !stopped.load(ordering: .acquiring) else { return }
        if let packets {
            let array = packets as CFArray
            buffers.removeAll(keepingCapacity: true)
            for index in 0..<CFArrayGetCount(array) {
                let packet = Unmanaged<CFData>.fromOpaque(CFArrayGetValueAtIndex(array, index)).takeUnretainedValue()
                buffers.append(UnsafeRawBufferPointer(start: CFDataGetBytePtr(packet), count: CFDataGetLength(packet)))
            }
            deliver(buffers)
        }
        guard !stopped.load(ordering: .acquiring) else { return }
        arm()
    }
}
