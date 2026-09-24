//
//  DNSSyscallConcurrencyBridge.swift
//  Anywhere
//
//  Created by NodePassProject on 7/17/26.
//

import Foundation
import Synchronization
import dnssd

nonisolated final class DNSSyscallConcurrencyBridge: Sendable {
    private static let maxConcurrentCalls = 16

    private let queue: DispatchQueue = DispatchQueue(
        label: "com.argsment.Anywhere.DNSSyscallConcurrencyBridge",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private struct Gate {
        var running = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let gate = Mutex(Gate())

    func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await acquireSlot()
        defer { releaseSlot() }
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
    
    private func acquireSlot() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let admitted: Bool = gate.withLock { gate in
                guard gate.running < Self.maxConcurrentCalls else {
                    gate.waiters.append(continuation)
                    return false
                }
                gate.running += 1
                return true
            }
            if admitted { continuation.resume() }
        }
    }

    private func releaseSlot() {
        let next: CheckedContinuation<Void, Never>? = gate.withLock { gate in
            guard !gate.waiters.isEmpty else {
                gate.running -= 1
                return nil
            }
            return gate.waiters.removeFirst()
        }
        next?.resume()
    }

    // MARK: - Record query
    
    func queryFirstRecord(
        host: String,
        rrtype: UInt16,
        timeout: TimeInterval,
        accept: @escaping @Sendable (Data) -> Data?
    ) async -> (payload: Data, ttl: UInt32)? {
        await run { Self.queryFirstRecordBlocking(host: host, rrtype: rrtype, timeout: timeout, accept: accept) }
    }
    
    private final class QueryResult {
        let rrtype: UInt16
        let accept: (Data) -> Data?
        var payload: Data?
        var ttl: UInt32 = 0
        var sawFinal = false
        var answered = false
        init(rrtype: UInt16, accept: @escaping (Data) -> Data?) {
            self.rrtype = rrtype
            self.accept = accept
        }
    }

    private static func queryFirstRecordBlocking(
        host: String,
        rrtype: UInt16,
        timeout: TimeInterval,
        accept: @escaping @Sendable (Data) -> Data?
    ) -> (payload: Data, ttl: UInt32)? {
        let result = QueryResult(rrtype: rrtype, accept: accept)
        
        let callback: DNSServiceQueryRecordReply = { _, flags, _, errorCode, _, rrtype, _, rdlen, rdata, ttl, context in
            guard let context else { return }
            let result = BridgeContext.unretained(context, as: QueryResult.self)
            if rrtype == result.rrtype || errorCode != kDNSServiceErr_NoError { result.sawFinal = true }
            if result.sawFinal, (flags & kDNSServiceFlagsMoreComing) == 0 { result.answered = true }
            guard errorCode == kDNSServiceErr_NoError,
                  rrtype == result.rrtype, let rdata, rdlen > 0
            else { return }
            guard result.payload == nil else { return }
            if let payload = result.accept(Data(bytes: rdata, count: Int(rdlen))) {
                result.payload = payload
                result.ttl = ttl
            }
        }

        var serviceRef: DNSServiceRef?
        let context = BridgeContext.passUnretained(result)
        let queryError = host.withCString { cHost in
            DNSServiceQueryRecord(
                &serviceRef,
                DNSServiceFlags(kDNSServiceFlagsReturnIntermediates),
                0,
                cHost,
                rrtype, UInt16(kDNSServiceClass_IN),
                callback,
                context
            )
        }
        guard queryError == kDNSServiceErr_NoError, let serviceRef else { return nil }
        defer { DNSServiceRefDeallocate(serviceRef) }

        let fd = DNSServiceRefSockFD(serviceRef)
        guard fd >= 0 else { return nil }

        let deadline = MonotonicClock.now + timeout
        while result.payload == nil, !result.answered {
            let remaining = deadline - MonotonicClock.now
            if remaining <= 0 { break }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(min(remaining * 1000, 60_000)))
            guard ready > 0, (pollDescriptor.revents & Int16(POLLIN)) != 0 else { break }
            if DNSServiceProcessResult(serviceRef) != kDNSServiceErr_NoError { break }
        }
        guard let payload = result.payload else { return nil }
        return (payload, result.ttl)
    }
}
