//
//  IPStackConcurrencyBridge.swift
//  Anywhere
//
//  Created by NodePassProject on 7/15/26.
//

import Foundation

nonisolated final class IPStackConcurrencyBridge: @unchecked Sendable {
    let executor: BridgeExecutor

    // All access is confined to executor.queue, including synchronous IPStack callbacks.
    private var inputPacket: Data?
    private var inputBytes: UnsafeRawBufferPointer?

    func withInputPacket(_ packet: Data, _ body: (UnsafeRawBufferPointer) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        precondition(inputPacket == nil, "IPStack input must not be nested")
        inputPacket = packet
        defer { inputPacket = nil }
        packet.withUnsafeBytes { bytes in
            inputBytes = bytes
            defer { inputBytes = nil }
            body(bytes)
        }
    }

    func receivedData(_ bytes: UnsafeRawBufferPointer) -> Data {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let packet = inputPacket, let input = inputBytes,
              let base = input.baseAddress, let start = bytes.baseAddress else {
            preconditionFailure("TCP receive must run synchronously inside feed")
        }
        let offset = base.distance(to: start)
        precondition(offset >= 0 && offset <= input.count && bytes.count <= input.count - offset)
        // Keep Foundation's slice ownership and copy-on-write semantics. Consumers
        // must use startIndex; Data(slice) would copy just to rebase the indices.
        let lower = packet.startIndex + offset
        return packet[lower..<(lower + bytes.count)]
    }

    init(label: String) {
        self.executor = BridgeExecutor(label: label)
    }

    private var queue: DispatchQueue { executor.queue }

    func enqueue(_ work: @escaping @convention(block) @Sendable () -> Void) {
        queue.async(execute: work)
    }

    // MARK: - Async hop

    private struct QueueHopBody<Body>: @unchecked Sendable { let body: Body }

    func run<T>(_ body: @escaping () -> T) async -> T {
        let hop = QueueHopBody(body: body)
        return await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: hop.body()) }
        }
    }

    func runParked<T>(_ body: @escaping (CheckedContinuation<T, Never>) -> Void) async -> T {
        let hop = QueueHopBody(body: body)
        return await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { hop.body(continuation) }
        }
    }

    // MARK: - Timers

    func makeTick(
        intervalMs: Int,
        leewayMs: Int,
        handler: @escaping @Sendable () -> Void
    ) -> BridgeTimer {
        executor.makeRepeatingTimer(intervalMs: intervalMs, leewayMs: leewayMs, handler: handler)
    }
}
