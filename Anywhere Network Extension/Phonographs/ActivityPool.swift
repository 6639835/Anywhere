//
//  ActivityPool.swift
//  Anywhere
//
//  Created by NodePassProject on 9/23/26.
//

import Foundation
import Synchronization

nonisolated final class ActivityPool: Sendable {
    final class Record: Sendable {
        let id = UUID()
        let port: UInt16
        let startedAt: CFAbsoluteTime
        let defaultRouteTarget: RouteTarget

        private struct Detail {
            var host: String
            var routeTarget: RouteTarget
            var ruleSetName: String?
            var state: TunnelActivityState = .connecting
            var endedAt: CFAbsoluteTime?
        }

        private let detail: Mutex<Detail>
        private let bytesIn = Atomic<Int64>(0)
        private let bytesOut = Atomic<Int64>(0)

        fileprivate init(
            host: String,
            port: UInt16,
            routeTarget: RouteTarget,
            defaultRouteTarget: RouteTarget,
            ruleSetName: String?
        ) {
            self.port = port
            self.startedAt = CFAbsoluteTimeGetCurrent()
            self.defaultRouteTarget = defaultRouteTarget
            self.detail = Mutex(Detail(host: host, routeTarget: routeTarget, ruleSetName: ruleSetName))
        }

        fileprivate var endedAt: CFAbsoluteTime? {
            detail.withLock { $0.endedAt }
        }

        func route(host: String, routeTarget: RouteTarget, ruleSetName: String?) {
            detail.withLock { detail in
                detail.host = host
                detail.routeTarget = routeTarget
                detail.ruleSetName = ruleSetName
            }
        }

        func establish() {
            detail.withLock { detail in
                guard detail.state == .connecting else { return }
                detail.state = .established
            }
        }

        func close() {
            let now = CFAbsoluteTimeGetCurrent()
            detail.withLock { detail in
                guard detail.state != .closed else { return }
                detail.state = .closed
                detail.endedAt = now
            }
        }

        func addBytesIn(_ count: Int) {
            bytesIn.wrappingAdd(Int64(count), ordering: .relaxed)
        }

        func addBytesOut(_ count: Int) {
            bytesOut.wrappingAdd(Int64(count), ordering: .relaxed)
        }

        fileprivate var entry: TunnelActivityEntry {
            let detail = detail.withLock { $0 }
            return TunnelActivityEntry(
                id: id,
                host: detail.host,
                port: port,
                routeTarget: detail.routeTarget,
                defaultRouteTarget: defaultRouteTarget,
                ruleSetName: detail.ruleSetName,
                state: detail.state,
                startedAt: startedAt,
                endedAt: detail.endedAt,
                bytesIn: bytesIn.load(ordering: .relaxed),
                bytesOut: bytesOut.load(ordering: .relaxed)
            )
        }
    }

    private let capacity: Int
    private let records = Mutex<[Record]>([])

    init(capacity: Int) {
        self.capacity = capacity
    }

    func open(
        host: String,
        port: UInt16,
        routeTarget: RouteTarget,
        defaultRouteTarget: RouteTarget,
        ruleSetName: String?
    ) -> Record {
        let record = Record(
            host: host,
            port: port,
            routeTarget: routeTarget,
            defaultRouteTarget: defaultRouteTarget,
            ruleSetName: ruleSetName
        )
        records.withLock { records in
            if records.count >= capacity {
                records.remove(at: Self.evictionIndex(in: records))
            }
            records.append(record)
        }
        return record
    }

    func snapshot() -> [TunnelActivityEntry] {
        records.withLock { $0 }.map(\.entry)
    }
    
    private static func evictionIndex(in records: [Record]) -> Int {
        var victim = 0
        var victimEndedAt = CFAbsoluteTime.infinity
        for (index, record) in records.enumerated() {
            guard let endedAt = record.endedAt, endedAt < victimEndedAt else { continue }
            victim = index
            victimEndedAt = endedAt
        }
        return victim
    }
}
