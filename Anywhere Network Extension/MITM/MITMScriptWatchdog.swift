//
//  MITMScriptWatchdog.swift
//  Anywhere
//
//  Created by NodePassProject on 6/3/26.
//

import Foundation
import Synchronization

nonisolated enum MITMScriptWatchdog {
    static let hardCapSeconds = 30
    
    private static let checkIntervalSeconds = 5

    private struct Span {
        var start: TimeInterval?
        var label = ""
    }
    private static let span = Mutex(Span())
    
    private static var uptimeSeconds: TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
    
    private static let sampler: Task<Void, Never> = {
        Task.detached(priority: .high) {
            while true {
                try? await Task.sleep(for: .seconds(checkIntervalSeconds))
                checkInFlightSpan()
            }
        }
    }()
    
    static func begin(_ label: String) {
        _ = sampler
        span.withLock { span in
            span.start = Self.uptimeSeconds
            span.label = label
        }
    }

    static func end() {
        span.withLock { span in
            span.start = nil
            span.label = ""
        }
    }

    private static func checkInFlightSpan() {
        let (start, label) = span.withLock { ($0.start, $0.label) }
        guard let start else { return }
        let elapsed = uptimeSeconds - start
        guard elapsed >= Double(hardCapSeconds) else { return }
        let seconds = Int(elapsed)
        let shown = label.count > 200 ? String(label.prefix(200)) + "…" : label
        fatalError("A JavaScript script span ran \(seconds)s without returning. Offending script: \(shown)")
    }
}
