//
//  HTTP2Framer.swift
//  Anywhere
//
//  Created by NodePassProject on 3/9/26.
//

import Foundation

// MARK: - Frame Types and Flags

nonisolated enum HTTP2FrameType: UInt8 {
    case data         = 0x0
    case headers      = 0x1
    case rstStream    = 0x3
    case settings     = 0x4
    case ping         = 0x6
    case goaway       = 0x7
    case windowUpdate = 0x8
    case continuation = 0x9
}

nonisolated enum HTTP2FrameFlags {
    static let endStream: UInt8    = 0x1
    static let ack: UInt8          = 0x1
    static let endHeaders: UInt8   = 0x4
    static let padded: UInt8       = 0x8
}

// MARK: - Frame

nonisolated struct HTTP2Frame {
    let type: HTTP2FrameType
    let flags: UInt8
    let streamID: UInt32
    let payload: Data

    func hasFlag(_ flag: UInt8) -> Bool { flags & flag != 0 }

    var serialized: Data {
        var data = Data(capacity: HTTP2Framer.headerSize + payload.count)
        HTTP2FrameWire.appendHeader(
            type: type.rawValue,
            flags: flags,
            streamID: streamID,
            payloadLength: payload.count,
            into: &data
        )
        data.append(payload)
        return data
    }
}

// MARK: - Framer

nonisolated enum HTTP2Framer {
    static let headerSize = HTTP2FrameWire.headerSize
    static let maxDataPayload = 16_384

    // MARK: - Deserialize
    
    static func declaredPayloadLength(in buffer: Data) -> Int? {
        guard buffer.count >= headerSize else { return nil }
        let start = buffer.startIndex
        return Int(buffer[start]) << 16 | Int(buffer[start + 1]) << 8 | Int(buffer[start + 2])
    }

    static func deserialize(from buffer: inout Data) -> HTTP2Frame? {
        guard buffer.count >= headerSize else { return nil }

        let bytes = buffer
        let startIndex = bytes.startIndex

        let length = Int(bytes[startIndex]) << 16 | Int(bytes[startIndex+1]) << 8 | Int(bytes[startIndex+2])
        let totalSize = headerSize + length

        guard buffer.count >= totalSize else { return nil }

        let rawType = bytes[startIndex+3]
        let flags = bytes[startIndex+4]
        let streamID = UInt32(bytes[startIndex+5]) << 24 | UInt32(bytes[startIndex+6]) << 16
                     | UInt32(bytes[startIndex+7]) << 8 | UInt32(bytes[startIndex+8])
        let maskedStreamID = streamID & 0x7FFFFFFF

        let payload = Data(buffer[(startIndex + headerSize)..<(startIndex + totalSize)])
        buffer.removeFirst(totalSize)

        guard let type = HTTP2FrameType(rawValue: rawType) else {
            return HTTP2Frame(type: HTTP2FrameType.data, flags: 0, streamID: maskedStreamID, payload: Data())
        }

        return HTTP2Frame(type: type, flags: flags, streamID: maskedStreamID, payload: payload)
    }

    // MARK: - Convenience Builders

    static func settingsFrame(_ settings: [(id: UInt16, value: UInt32)]) -> HTTP2Frame {
        var payload = Data(capacity: settings.count * 6)
        for (id, value) in settings {
            payload.append(UInt8(id >> 8))
            payload.append(UInt8(id & 0xFF))
            payload.append(UInt8((value >> 24) & 0xFF))
            payload.append(UInt8((value >> 16) & 0xFF))
            payload.append(UInt8((value >> 8) & 0xFF))
            payload.append(UInt8(value & 0xFF))
        }
        return HTTP2Frame(type: HTTP2FrameType.settings, flags: 0, streamID: 0, payload: payload)
    }

    static func settingsAckFrame() -> HTTP2Frame {
        HTTP2Frame(type: HTTP2FrameType.settings, flags: HTTP2FrameFlags.ack, streamID: 0, payload: Data())
    }

    static func windowUpdateFrame(streamID: UInt32, increment: UInt32) -> HTTP2Frame {
        var payload = Data(capacity: 4)
        HTTP2FrameWire.appendUInt32(increment & 0x7FFFFFFF, into: &payload)
        return HTTP2Frame(type: HTTP2FrameType.windowUpdate, flags: 0, streamID: streamID, payload: payload)
    }
    
    static func headersFrame(streamID: UInt32, headerBlock: Data, endStream: Bool = false) -> HTTP2Frame {
        var flags: UInt8 = HTTP2FrameFlags.endHeaders
        if endStream { flags |= HTTP2FrameFlags.endStream }
        return HTTP2Frame(type: HTTP2FrameType.headers, flags: flags, streamID: streamID, payload: headerBlock)
    }

    static func dataFrame(streamID: UInt32, payload: Data, endStream: Bool = false) -> HTTP2Frame {
        var flags: UInt8 = 0
        if endStream { flags |= HTTP2FrameFlags.endStream }
        return HTTP2Frame(type: HTTP2FrameType.data, flags: flags, streamID: streamID, payload: payload)
    }

    static func rstStreamFrame(streamID: UInt32, errorCode: UInt32) -> HTTP2Frame {
        var payload = Data(capacity: 4)
        HTTP2FrameWire.appendUInt32(errorCode, into: &payload)
        return HTTP2Frame(type: HTTP2FrameType.rstStream, flags: 0, streamID: streamID, payload: payload)
    }
    
    static func pingAckFrame(opaqueData: Data) -> HTTP2Frame {
        HTTP2Frame(type: HTTP2FrameType.ping, flags: HTTP2FrameFlags.ack, streamID: 0, payload: opaqueData)
    }

    // MARK: - Payload Parsers

    static func parseSettings(payload: Data) -> [(id: UInt16, value: UInt32)] {
        HTTP2FrameWire.parseSettings(payload)
    }

    static func parseWindowUpdate(payload: Data) -> UInt32? {
        HTTP2FrameWire.readUInt32(payload).map { $0 & 0x7FFFFFFF }
    }

    static func parseGoaway(payload: Data) -> (lastStreamID: UInt32, errorCode: UInt32)? {
        HTTP2FrameWire.parseGoaway(payload)
    }

    static func parseRstStream(payload: Data) -> UInt32? {
        HTTP2FrameWire.readUInt32(payload)
    }
}
