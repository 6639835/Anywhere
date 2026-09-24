//
//  MITMRequestLog.swift
//  Anywhere
//
//  Created by NodePassProject on 5/14/26.
//

import Foundation
import Synchronization

nonisolated private let logger = AnywhereLogger(category: "MITMRequestLog")

nonisolated final class MITMRequestLog: Sendable {
    struct Record {
        let method: String?
        let url: String?
        let originalUrl: String?
        var synthAfter: Data = Data()
    }

    private struct State {
        var http1Queue: [Record] = []
        var http1ResponseOpen = false
        var http1OpenResponseSynthAfter = Data()
        var http2Streams: [UInt32: Record] = [:]
    }
    private let state = Mutex(State())
    
    private static let maxHTTP1Queue = 256
    private static let maxHTTP2Streams = 512
    private static let maxSynthAfterBytes: Int = 1 * 1024 * 1024

    init() {}

    // MARK: - HTTP/1

    func recordHTTP1(method: String?, url: String?, originalUrl: String?) {
        state.withLock { s in
            if s.http1Queue.count >= Self.maxHTTP1Queue {
                s.http1Queue.removeFirst()
            }
            s.http1Queue.append(Record(method: method, url: url, originalUrl: originalUrl))
        }
    }

    func popHTTP1() -> Record? {
        state.withLock { s in
            guard !s.http1Queue.isEmpty else { return nil }
            s.http1ResponseOpen = true
            return s.http1Queue.removeFirst()
        }
    }
    
    func closeHTTP1Response() -> Data {
        state.withLock { s in
            s.http1ResponseOpen = false
            let bytes = s.http1OpenResponseSynthAfter
            s.http1OpenResponseSynthAfter = Data()
            return bytes
        }
    }
    
    func peekHTTP1() -> Record? {
        state.withLock { $0.http1Queue.first }
    }
    
    var isHTTP1QueueEmpty: Bool {
        state.withLock { $0.http1Queue.isEmpty && !$0.http1ResponseOpen }
    }
    
    var http1InFlightCount: Int {
        state.withLock { $0.http1Queue.count }
    }
    
    func attachSynthAfterLastHTTP1(_ bytes: Data) {
        state.withLock { s in
            guard !s.http1Queue.isEmpty else {
                guard s.http1ResponseOpen else { return }
                let projected = s.http1OpenResponseSynthAfter.count + bytes.count
                if projected > Self.maxSynthAfterBytes {
                    logger.warning("synthAfter buffer would reach \(projected) B, over cap \(Self.maxSynthAfterBytes) B; dropping \(bytes.count) B of pipelined synth response")
                    return
                }
                s.http1OpenResponseSynthAfter.append(bytes)
                return
            }
            let index = s.http1Queue.count - 1
            let projected = s.http1Queue[index].synthAfter.count + bytes.count
            if projected > Self.maxSynthAfterBytes {
                logger.warning("synthAfter buffer would reach \(projected) B, over cap \(Self.maxSynthAfterBytes) B; dropping \(bytes.count) B of pipelined synth response")
                return
            }
            s.http1Queue[index].synthAfter.append(bytes)
        }
    }

    // MARK: - HTTP/2

    func recordHTTP2(streamID: UInt32, method: String?, url: String?, originalUrl: String?) {
        state.withLock { s in
            if s.http2Streams[streamID] == nil, s.http2Streams.count >= Self.maxHTTP2Streams,
               let oldest = s.http2Streams.keys.min() {
                s.http2Streams.removeValue(forKey: oldest)
            }
            s.http2Streams[streamID] = Record(method: method, url: url, originalUrl: originalUrl)
        }
    }

    func popHTTP2(streamID: UInt32) -> Record? {
        state.withLock { $0.http2Streams.removeValue(forKey: streamID) }
    }
    
    func peekHTTP2(streamID: UInt32) -> Record? {
        state.withLock { $0.http2Streams[streamID] }
    }
}
