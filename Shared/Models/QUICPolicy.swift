//
//  QUICPolicy.swift
//  Anywhere
//
//  Created by NodePassProject on 5/23/26.
//

import Foundation

nonisolated enum QUICPolicy: String, CaseIterable {
    case blocked
    case automatic
    case unblocked

    var title: String {
        switch self {
        case .blocked: return String(localized: "Blocked")
        case .automatic: return String(localized: "Automatic")
        case .unblocked: return String(localized: "Unblocked")
        }
    }
    
    var blocksAllQUIC: Bool { self == .blocked }

    func blocksQUIC(mitmListed: @autoclosure () -> Bool) -> Bool {
        switch self {
        case .blocked: return true
        case .automatic: return mitmListed()
        case .unblocked: return false
        }
    }

    func blocksQUIC(isProxied: Bool) -> Bool {
        switch self {
        case .blocked: return true
        case .automatic: return isProxied
        case .unblocked: return false
        }
    }
}
