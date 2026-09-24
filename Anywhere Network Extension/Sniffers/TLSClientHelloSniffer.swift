//
//  TLSClientHelloSniffer.swift
//  Anywhere
//
//  Created by NodePassProject on 7/13/26.
//

import Foundation

nonisolated struct TLSClientHelloSniffer {
    enum State: Equatable {
        case needMore
        case notTLS
        case found(serverName: String)
        case unavailable
    }

    private let bufferLimit: Int
    private var buffer = Data()
    private(set) var state: State = .needMore

    init(bufferLimit: Int = TunnelConstants.tlsSnifferBufferLimit) {
        self.bufferLimit = bufferLimit
    }
    
    mutating func feed(_ data: Data) -> State {
        guard state == .needMore, !data.isEmpty else { return state }
        
        if buffer.isEmpty, data[data.startIndex] != 0x16 {
            state = .notTLS
            return state
        }

        buffer.append(data)
        if buffer.count > bufferLimit {
            state = .unavailable
            return state
        }

        state = parse(buffer)
        return state
    }

    // MARK: - Parsing
    
    private func parse(_ buf: Data) -> State {
        guard buf.count >= 5 else { return .needMore }
        let base = buf.startIndex
        guard buf[base] == 0x16 else { return .unavailable }

        var fragment = Data()
        var offset = 0
        var messageLength: Int?
        let total = buf.count
        while true {
            guard total - offset >= 5 else { return .needMore }
            let recordStart = buf.index(base, offsetBy: offset)
            guard buf[recordStart] == 0x16 else { return .unavailable }
            let fragLen = (Int(buf[buf.index(recordStart, offsetBy: 3)]) << 8) | Int(buf[buf.index(recordStart, offsetBy: 4)])
            guard fragLen > 0, fragLen <= 16_384 else { return .unavailable }
            let recordTotal = 5 + fragLen
            guard total - offset >= recordTotal else { return .needMore }
            let fStart = buf.index(recordStart, offsetBy: 5)
            let fEnd = buf.index(fStart, offsetBy: fragLen)
            fragment.append(buf[fStart..<fEnd])
            offset += recordTotal
            if messageLength == nil, fragment.count >= 4 {
                let b = fragment.startIndex
                guard fragment[b] == 0x01 else { return .unavailable } // ClientHello
                let bodyLen = (Int(fragment[fragment.index(b, offsetBy: 1)]) << 16)
                            | (Int(fragment[fragment.index(b, offsetBy: 2)]) << 8)
                            | Int(fragment[fragment.index(b, offsetBy: 3)])
                messageLength = 4 + bodyLen
            }
            if let messageLength, fragment.count >= messageLength {
                return parseHandshake(fragment.prefix(messageLength))
            }
        }
    }
    
    private func parseHandshake(_ frag: Data) -> State {
        var current = Cursor(frag)
        guard let msgType = current.readU8(), msgType == 0x01 else { return .unavailable } // ClientHello
        guard let bodyLen = current.readU24(), let body = current.readBytes(bodyLen) else { return .unavailable }
        return parseClientHello(body)
    }
    
    private func parseClientHello(_ body: Data) -> State {
        var current = Cursor(body)

        guard current.skip(2 + 32) else { return .unavailable }
        guard let sidLen = current.readU8(), current.skip(Int(sidLen)) else { return .unavailable }
        guard let csLen = current.readU16(), current.skip(csLen) else { return .unavailable }
        guard let cmLen = current.readU8(), current.skip(Int(cmLen)) else { return .unavailable }
        guard let extLen = current.readU16(), let extensions = current.readBytes(extLen) else {
            return .unavailable
        }
        return parseExtensions(extensions)
    }

    private func parseExtensions(_ buf: Data) -> State {
        var current = Cursor(buf)
        while !current.isAtEnd {
            guard let extType = current.readU16(),
                  let extLen = current.readU16(),
                  let extData = current.readBytes(extLen) else {
                return .unavailable
            }
            if extType == 0x0000 {
                if let name = parseServerNameList(extData) {
                    return .found(serverName: name)
                }
                return .unavailable
            }
        }
        return .unavailable
    }
    
    private func parseServerNameList(_ buf: Data) -> String? {
        var current = Cursor(buf)
        guard let listLen = current.readU16(), let list = current.readBytes(listLen) else { return nil }
        var listCursor = Cursor(list)
        while !listCursor.isAtEnd {
            guard let nameType = listCursor.readU8(),
                  let nameLen = listCursor.readU16(),
                  let nameData = listCursor.readBytes(nameLen) else { return nil }
            if nameType == 0x00,
               !nameData.isEmpty,
               let host = String(data: nameData, encoding: .utf8)?.lowercased(),
               host.utf8.count <= 253 {
                return host
            }
        }
        return nil
    }

    // MARK: - Cursor

    private struct Cursor {
        let data: Data
        var position: Int

        init(_ data: Data) {
            self.data = data
            self.position = data.startIndex
        }

        var isAtEnd: Bool { position >= data.endIndex }

        mutating func skip(_ n: Int) -> Bool {
            guard n >= 0, position &+ n <= data.endIndex else { return false }
            position += n
            return true
        }

        mutating func readU8() -> UInt8? {
            guard position < data.endIndex else { return nil }
            let v = data[position]
            position += 1
            return v
        }

        mutating func readU16() -> Int? {
            guard position &+ 2 <= data.endIndex else { return nil }
            let v = (Int(data[position]) << 8) | Int(data[position &+ 1])
            position += 2
            return v
        }

        mutating func readU24() -> Int? {
            guard position &+ 3 <= data.endIndex else { return nil }
            let v = (Int(data[position]) << 16) | (Int(data[position &+ 1]) << 8) | Int(data[position &+ 2])
            position += 3
            return v
        }

        mutating func readBytes(_ n: Int) -> Data? {
            guard n >= 0, position &+ n <= data.endIndex else { return nil }
            let slice = data[position..<(position &+ n)]
            position += n
            return slice
        }
    }
}
