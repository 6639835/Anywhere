//
//  ActivityModel.swift
//  Anywhere
//
//  Created by NodePassProject on 9/23/26.
//

import Foundation
import Observation

@MainActor
@Observable
class ActivityModel {
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let host: String
        let port: UInt16
        let routeTarget: RouteTarget
        let defaultRouteTarget: RouteTarget
        let ruleSetName: String?
        let state: TunnelActivityState
        let startedAt: Date
        let endedAt: Date?
        let bytesIn: Int64
        let bytesOut: Int64
    }
    
    private(set) var active: [Entry] = []
    private(set) var closed: [Entry] = []
    private(set) var isLoaded = false

    func poll(_ proto: TunnelActivityProtocol, using tunnel: TunnelController) async {
        guard let response = await tunnel.send(.fetchActivity(proto)),
              !Task.isCancelled,
              let payload = try? JSONDecoder().decode(ActivityResponse.self, from: response) else { return }
        apply(payload.entries)
    }

    private func apply(_ entries: [TunnelActivityEntry]) {
        var active: [Entry] = []
        var closed: [Entry] = []
        for entry in entries {
            let model = Entry(
                id: entry.id,
                host: entry.host,
                port: entry.port,
                routeTarget: entry.routeTarget,
                defaultRouteTarget: entry.defaultRouteTarget,
                ruleSetName: entry.ruleSetName,
                state: entry.state,
                startedAt: Date(timeIntervalSinceReferenceDate: entry.startedAt),
                endedAt: entry.endedAt.map(Date.init(timeIntervalSinceReferenceDate:)),
                bytesIn: entry.bytesIn,
                bytesOut: entry.bytesOut
            )
            if entry.state == .closed {
                closed.append(model)
            } else {
                active.append(model)
            }
        }
        self.active = active.sorted { $0.startedAt > $1.startedAt }
        self.closed = closed.sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
        isLoaded = true
    }
}
