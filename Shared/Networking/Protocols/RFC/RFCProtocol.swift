//
//  RFCProtocol.swift
//  Anywhere
//
//  Created by NodePassProject on 9/11/26.
//

import Foundation

nonisolated enum RFCProtocol {

    // MARK: ALPN

    static let alpnHTTP2 = "h2"
    static let alpnHTTP11 = "http/1.1"
    
    static let defaultALPN = [alpnHTTP2, alpnHTTP11]
    
    enum Version {
        case http11
        case http2

        init(negotiatedALPN: String) {
            self = negotiatedALPN == RFCProtocol.alpnHTTP2 ? .http2 : .http11
        }

        var wire: AnywhereError.Wire {
            switch self {
            case .http11: .http11
            case .http2:  .http2
            }
        }
    }

    // MARK: Authority
    
    static func authority(host: String, port: UInt16) -> String {
        let needsBrackets = host.contains(":") && !host.hasPrefix("[")
        return needsBrackets ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    // MARK: Proxy-Authorization
    
    static func basicCredentials(username: String?, password: String?) -> String? {
        let user = username ?? ""
        let pass = password ?? ""
        guard !user.isEmpty || !pass.isEmpty else { return nil }
        return "Basic " + Data("\(user):\(pass)".utf8).base64EncodedString()
    }

    // MARK: Status
    
    static func tunnelError(status: Int, reason: String?, wire: AnywhereError.Wire) -> AnywhereError? {
        if (200...299).contains(status) { return nil }
        if status == 407 {
            return AnywhereError.proxy(wire, .authenticationRejected(status: status, detail: reason))
        }
        let detail = reason.map { "CONNECT rejected: \(status) \($0)" } ?? "CONNECT rejected: \(status)"
        return AnywhereError.proxy(wire, .tunnelRejected(detail: detail))
    }

    // MARK: - HTTP/1.1 Request
    
    static func http11ConnectRequest(authority: String, credentials: String?) -> Data {
        var request = "CONNECT \(authority) HTTP/1.1\r\n"
        request += "Host: \(authority)\r\n"
        if let credentials {
            request += "Proxy-Authorization: \(credentials)\r\n"
        }
        request += "User-Agent: \(ProxyUserAgent.default)\r\n"
        request += "\r\n"
        return Data(request.utf8)
    }

    // MARK: - HTTP/1.1 Response

    struct HTTP11Response {
        let status: Int
        let reason: String?
        let leftover: Data
    }
    
    private static let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])
    
    static let maxHTTP11HeaderBytes = 16 * 1024
    
    static func parseHTTP11Response(from buffer: Data) throws -> HTTP11Response? {
        var search = buffer
        var consumed = 0

        while true {
            guard let terminator = search.range(of: headerTerminator) else {
                guard buffer.count <= maxHTTP11HeaderBytes else {
                    throw AnywhereError.proxy(.http11, .handshakeFailed(
                        detail: "CONNECT response head exceeded \(maxHTTP11HeaderBytes) bytes"
                    ))
                }
                return nil
            }
            let headEnd = terminator.upperBound
            let head = search[search.startIndex..<terminator.lowerBound]
            guard let text = String(data: Data(head), encoding: .utf8) else {
                throw AnywhereError.proxy(.http11, .handshakeFailed(detail: "Malformed CONNECT response head"))
            }
            let firstLine = text.prefix { $0 != "\r" && $0 != "\n" }
            let (status, reason) = try parseStatusLine(String(firstLine))
            
            if (100...199).contains(status) {
                consumed += search.distance(from: search.startIndex, to: headEnd)
                search = Data(search[headEnd...])
                continue
            }

            consumed += search.distance(from: search.startIndex, to: headEnd)
            return HTTP11Response(
                status: status,
                reason: reason,
                leftover: Data(buffer[(buffer.startIndex + consumed)...])
            )
        }
    }
    
    private static func parseStatusLine(_ line: String) throws -> (status: Int, reason: String?) {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2,
              parts[0].hasPrefix("HTTP/"),
              let status = Int(parts[1]), (100...599).contains(status) else {
            throw AnywhereError.proxy(.http11, .handshakeFailed(detail: "Malformed CONNECT status line: \(line)"))
        }
        let reason = parts.count > 2 ? String(parts[2]) : nil
        return (status, reason?.isEmpty == true ? nil : reason)
    }

    // MARK: - HTTP/2
    
    static let http2Preface = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
    static let http2StreamWindowSize: UInt32 = 4 * 1024 * 1024
    static let http2ConnectionWindowSize: UInt32 = 1024 * 1024 * 1024
    static let http2DefaultMaxConcurrentStreams = 128
    static let http2MaxConcurrentStreamsCap = 256

    enum HTTP2SettingID {
        static let headerTableSize: UInt16 = 0x1
        static let enablePush: UInt16 = 0x2
        static let maxConcurrentStreams: UInt16 = 0x3
        static let initialWindowSize: UInt16 = 0x4
        static let maxFrameSize: UInt16 = 0x5
        static let maxHeaderListSize: UInt16 = 0x6
    }

    enum HTTP2ErrorCode {
        static let noError: UInt32 = 0x0
        static let cancel: UInt32 = 0x8
    }
    
    static func http2ConnectHeaders(authority: String, credentials: String?) -> Data {
        var extra: [(name: String, value: String)] = []
        if let credentials {
            extra.append((name: "proxy-authorization", value: credentials))
        }
        extra.append((name: "user-agent", value: ProxyUserAgent.default))
        return HPACKEncoder.encodeConnectRequest(authority: authority, extraHeaders: extra)
    }
    
    static func http2Status(from headers: [(name: String, value: String)]) -> Int? {
        for header in headers where header.name == ":status" {
            return Int(header.value)
        }
        return nil
    }
}
