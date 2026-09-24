//
//  UDPFraming.swift
//  Anywhere
//
//  Created by NodePassProject on 3/1/26.
//

import Foundation
import Synchronization

nonisolated struct UDPFramingState {
    var buffer = Data()
    var bufferOffset = 0
}

nonisolated protocol UDPFramingCapable: AnyObject {
    var udpState: Mutex<UDPFramingState> { get }
}

nonisolated extension UDPFramingCapable {
    func frameUDPPacket(_ data: Data) -> Data? {
        guard let length = UInt16(exactly: data.count) else { return nil }
        var framedData = Data(capacity: 2 + data.count)
        framedData.append(UInt8(length >> 8))
        framedData.append(UInt8(length & 0xFF))
        framedData.append(data)
        return framedData
    }
    
    func extractUDPPacket(from state: inout UDPFramingState) -> Data? {
        let available = state.buffer.count - state.bufferOffset
        guard available >= 2 else { return nil }

        let length = Int(UInt16(state.buffer[state.bufferOffset]) << 8 | UInt16(state.buffer[state.bufferOffset + 1]))
        guard available >= 2 + length else { return nil }

        let packetStart = state.bufferOffset + 2
        let packetEnd = packetStart + length
        let packet = Data(state.buffer[packetStart..<packetEnd])

        state.bufferOffset = packetEnd
        
        if state.bufferOffset > 8192 {
            state.buffer.removeSubrange(0..<state.bufferOffset)
            state.bufferOffset = 0
        }

        return packet
    }
    
    nonisolated func clearUDPBuffer(_ state: inout UDPFramingState) {
        state.buffer = Data()
        state.bufferOffset = 0
    }
}
