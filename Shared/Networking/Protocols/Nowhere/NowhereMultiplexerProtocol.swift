//
//  NowhereMultiplexerProtocol.swift
//  Anywhere
//
//  Created by NodePassProject on 8/24/26.
//

import Foundation

nonisolated enum NowhereMultiplexerConstants {
    static let marker: UInt8 = 0xff
    static let headerSize = 7
    static let maximumFramePayload = 32 * 1024
    static let baseStreamWindowBytes = 4 * 1024 * 1024
    static let baseConnectionWindowBytes = 8 * 1024 * 1024
    static let streamWindowBytes = 16 * 1024 * 1024
    static let connectionWindowBytes = 32 * 1024 * 1024
    static let maximumStreams = 4096
    static let maximumActiveFlowsPerMultiplexer = 4096
    static let maximumMultiplexers = 8
    static let outboundFrameLimit = 512
    static let inboundFrameLimit = 4096
    static let windowUpdateThreshold = 2 * 1024 * 1024
    static let minimumFairCreditBytes = 256 * 1024
    static let idleTimeout: TimeInterval = 30
    static let streamWindowExtensionUnits = UInt16((streamWindowBytes - baseStreamWindowBytes) / 1024)
    static let connectionWindowExtensionUnits = UInt16((connectionWindowBytes - baseConnectionWindowBytes) / 1024)
}

nonisolated enum NowhereMultiplexerFrameKind: UInt8, Sendable {
    case open = 0x01
    case data = 0x02
    case window = 0x03
    case fin = 0x04
    case reset = 0x05
}

nonisolated enum NowhereMultiplexerWireError: Error, Equatable, Sendable {
    case invalidHeaderLength(Int)
    case unknownKind(UInt8)
    case valueTooLarge
    case invalidFlowID
    case invalidData
    case invalidWindow
    case invalidControl
}

extension NowhereMultiplexerWireError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidHeaderLength(let length): "invalid multiplexer header length: \(length)"
        case .unknownKind(let kind): "unknown multiplexer frame kind: \(kind)"
        case .valueTooLarge: "multiplexer frame value exceeds u16"
        case .invalidFlowID: "invalid multiplexer flow ID"
        case .invalidData: "multiplexer DATA must carry payload"
        case .invalidWindow: "multiplexer WINDOW credit must be non-zero"
        case .invalidControl: "multiplexer control frame value must be zero"
        }
    }
}

nonisolated struct NowhereMultiplexerFrameHeader: Equatable, Sendable {
    let kind: NowhereMultiplexerFrameKind
    let value: UInt16
    let flowID: UInt32

    static func open(flowID: UInt32) throws -> Self {
        let header = Self(kind: .open, value: NowhereMultiplexerConstants.streamWindowExtensionUnits, flowID: flowID)
        try header.validate()
        return header
    }

    static func data(flowID: UInt32, payloadLength: Int) throws -> Self {
        guard let value = UInt16(exactly: payloadLength) else { throw NowhereMultiplexerWireError.valueTooLarge }
        let header = Self(kind: .data, value: value, flowID: flowID)
        try header.validate()
        return header
    }

    static func window(flowID: UInt32, creditUnits: Int) throws -> Self {
        guard let value = UInt16(exactly: creditUnits) else { throw NowhereMultiplexerWireError.valueTooLarge }
        let header = Self(kind: .window, value: value, flowID: flowID)
        try header.validate()
        return header
    }

    static func terminal(flowID: UInt32, reset: Bool) throws -> Self {
        let header = Self(kind: reset ? .reset : .fin, value: 0, flowID: flowID)
        try header.validate()
        return header
    }

    func validate() throws {
        switch kind {
        case .open:
            try validateNonzeroFlowID()
        case .data:
            try validateNonzeroFlowID()
            guard value != 0, Int(value) <= NowhereMultiplexerConstants.maximumFramePayload else {
                throw NowhereMultiplexerWireError.invalidData
            }
        case .window:
            guard flowID <= NowhereProtocol.maximumFlowID else { throw NowhereMultiplexerWireError.invalidFlowID }
            guard value != 0 else { throw NowhereMultiplexerWireError.invalidWindow }
        case .fin, .reset:
            try validateNonzeroFlowID()
            guard value == 0 else { throw NowhereMultiplexerWireError.invalidControl }
        }
    }

    private func validateNonzeroFlowID() throws {
        guard (1...NowhereProtocol.maximumFlowID).contains(flowID) else {
            throw NowhereMultiplexerWireError.invalidFlowID
        }
    }

    func encode() throws -> Data {
        try validate()
        return Data([
            kind.rawValue,
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: flowID >> 24),
            UInt8(truncatingIfNeeded: flowID >> 16),
            UInt8(truncatingIfNeeded: flowID >> 8),
            UInt8(truncatingIfNeeded: flowID),
        ])
    }

    static func decode(_ input: Data) throws -> Self {
        guard input.count == NowhereMultiplexerConstants.headerSize else {
            throw NowhereMultiplexerWireError.invalidHeaderLength(input.count)
        }
        let bytes = [UInt8](input)
        guard let kind = NowhereMultiplexerFrameKind(rawValue: bytes[0]) else {
            throw NowhereMultiplexerWireError.unknownKind(bytes[0])
        }
        let header = Self(
            kind: kind,
            value: UInt16(bytes[1]) << 8 | UInt16(bytes[2]),
            flowID: UInt32(bytes[3]) << 24 | UInt32(bytes[4]) << 16 | UInt32(bytes[5]) << 8 | UInt32(bytes[6])
        )
        try header.validate()
        return header
    }
}
