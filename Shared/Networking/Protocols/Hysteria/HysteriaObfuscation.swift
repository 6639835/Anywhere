//
//  HysteriaObfuscation.swift
//  Anywhere
//
//  Created by NodePassProject on 6/23/26.
//

import Foundation

nonisolated enum HysteriaObfuscation: Hashable {
    case salamander(password: String)
    case gecko(password: String, minPacketSize: Int, maxPacketSize: Int)

    var password: String {
        switch self {
        case .salamander(let password): return password
        case .gecko(let password, _, _): return password
        }
    }
    
    var typeTag: String {
        switch self {
        case .salamander: return "salamander"
        case .gecko: return "gecko"
        }
    }
    
    static let geckoMinPacketSizeDefault = 512
    static let geckoMaxPacketSizeDefault = 1200
    static let geckoPacketSizeRange: ClosedRange<Int> = 0...2048
    
    static func normalizedGeckoSizes(min rawMin: Int?, max rawMax: Int?) -> (min: Int, max: Int) {
        func clamp(_ value: Int) -> Int {
            Swift.max(geckoPacketSizeRange.lowerBound, Swift.min(geckoPacketSizeRange.upperBound, value))
        }
        let lo = clamp((rawMin ?? 0) > 0 ? rawMin! : geckoMinPacketSizeDefault)
        let hi = clamp((rawMax ?? 0) > 0 ? rawMax! : geckoMaxPacketSizeDefault)
        return hi >= lo ? (lo, hi) : (lo, lo)
    }
    
    static func make(
        type rawType: String?,
        password: String?,
        geckoMinPacketSize: Int? = nil,
        geckoMaxPacketSize: Int? = nil
    ) -> HysteriaObfuscation? {
        guard let rawType, !rawType.isEmpty else { return nil }
        let password = password ?? ""
        switch rawType.lowercased() {
        case "salamander":
            return .salamander(password: password)
        case "gecko":
            let sizes = normalizedGeckoSizes(min: geckoMinPacketSize, max: geckoMaxPacketSize)
            return .gecko(password: password, minPacketSize: sizes.min, maxPacketSize: sizes.max)
        default:
            return nil
        }
    }
}

nonisolated extension HysteriaObfuscation: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, password, minPacketSize, maxPacketSize
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard let obfuscation = HysteriaObfuscation.make(
            type: type,
            password: try container.decodeIfPresent(String.self, forKey: .password),
            geckoMinPacketSize: try container.decodeIfPresent(Int.self, forKey: .minPacketSize),
            geckoMaxPacketSize: try container.decodeIfPresent(Int.self, forKey: .maxPacketSize)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported Hysteria obfuscation type: \(type)"
            )
        }
        self = obfuscation
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(typeTag, forKey: .type)
        try container.encode(password, forKey: .password)
        if case .gecko(_, let minPacketSize, let maxPacketSize) = self {
            try container.encode(minPacketSize, forKey: .minPacketSize)
            try container.encode(maxPacketSize, forKey: .maxPacketSize)
        }
    }
}
