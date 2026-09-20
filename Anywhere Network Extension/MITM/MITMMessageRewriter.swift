//
//  MITMMessageRewriter.swift
//  Anywhere
//
//  Created by NodePassProject on 6/4/26.
//

import Foundation

nonisolated protocol MITMMessageRewriter: AnyObject {
    func feed(_ data: Data) async -> Data
    func drainPendingClientBytes() -> Data
    func drainPendingServerBytes() -> Data
    var resolvedUpstream: (host: String, port: UInt16?)? { get }
}
