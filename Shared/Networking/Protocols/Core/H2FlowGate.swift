//
//  H2FlowGate.swift
//  Anywhere
//
//  Created by NodePassProject on 7/17/26.
//

import Foundation

nonisolated struct H2FlowGate {
    private var waiters: [AsyncStream<Never>.Continuation] = []
    
    mutating func enroll() -> AsyncStream<Never> {
        let (stream, continuation) = AsyncStream.makeStream(of: Never.self)
        waiters.append(continuation)
        return stream
    }
    
    mutating func wakeAll() {
        for continuation in waiters { continuation.finish() }
        waiters.removeAll()
    }
    
    static func park(_ enrollUnderLock: () -> AsyncStream<Never>?) async {
        guard !Task.isCancelled, let stream = enrollUnderLock() else { return }
        for await _ in stream {}
    }
}
