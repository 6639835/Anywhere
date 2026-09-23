//
//  RouteTarget+Tag.swift
//  Anywhere
//
//  Created by NodePassProject on 9/23/26.
//

import SwiftUI

extension RouteTarget {
    var tagText: String {
        switch self {
        case .default: String(localized: "Default")
        case .direct: String(localized: "Direct")
        case .reject: String(localized: "Reject")
        case .defaultProxy, .proxy: String(localized: "Proxy")
        }
    }

    var tagColor: Color {
        switch self {
        case .default: .blue
        case .direct: .green
        case .reject: .red
        case .defaultProxy, .proxy: .purple
        }
    }
    
    func outboundName(
        defaultRouteTarget: RouteTarget?,
        configStore: ConfigurationStore,
        chainStore: ChainStore,
        selection: ProxySelection?
    ) -> String? {
        switch self {
        case .default:
            defaultRouteTarget?.displayName(configStore: configStore, chainStore: chainStore, selection: selection)
        case .defaultProxy:
            (defaultRouteTarget ?? .defaultProxy).displayName(configStore: configStore, chainStore: chainStore, selection: selection)
        case .proxy:
            displayName(configStore: configStore, chainStore: chainStore, selection: selection)
        case .direct, .reject:
            nil
        }
    }
}
