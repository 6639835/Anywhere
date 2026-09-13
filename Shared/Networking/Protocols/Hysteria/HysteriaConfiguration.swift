//
//  HysteriaConfiguration.swift
//  Anywhere
//
//  Created by NodePassProject on 4/13/26.
//

import Foundation

// MARK: - Stored Configuration

nonisolated struct HysteriaConfiguration: Hashable, Sendable {
    let password: String
    
    let congestionControl: HysteriaCongestionControl
    let uploadMbps: Int
    let downloadMbps: Int
    
    let obfuscation: HysteriaObfuscation?
    
    let serverName: String

    init(
        password: String,
        congestionControl: HysteriaCongestionControl = .brutal,
        uploadMbps: Int = HysteriaCongestionControl.uploadMbpsDefault,
        downloadMbps: Int = HysteriaCongestionControl.downloadMbpsDefault,
        obfuscation: HysteriaObfuscation? = nil,
        serverName: String
    ) {
        self.password = password
        self.congestionControl = congestionControl
        self.uploadMbps = HysteriaCongestionControl.clampUploadMbps(uploadMbps)
        self.downloadMbps = HysteriaCongestionControl.clampDownloadMbps(downloadMbps)
        self.obfuscation = obfuscation
        self.serverName = serverName
    }
}

// MARK: - Runtime Configuration

nonisolated struct HysteriaRuntimeConfiguration {
    let proxyHost: String
    let proxyPort: UInt16
    let password: String
    
    let congestionControl: HysteriaCongestionControl
    let uploadMbps: Int
    let downloadMbps: Int
    var uploadBytesPerSec: UInt64 {
        UInt64(max(0, uploadMbps)) * 1_000_000 / 8
    }
    var downloadBytesPerSec: UInt64 {
        UInt64(max(0, downloadMbps)) * 1_000_000 / 8
    }
    var clientRxBytesPerSec: UInt64 {
        congestionControl == .brutal ? downloadBytesPerSec : 0
    }
    
    let obfuscation: HysteriaObfuscation?
    
    let sni: String

    init(configuration: HysteriaConfiguration, proxyHost: String, proxyPort: UInt16) {
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.password = configuration.password
        self.congestionControl = configuration.congestionControl
        self.uploadMbps = configuration.uploadMbps
        self.downloadMbps = configuration.downloadMbps
        self.obfuscation = configuration.obfuscation
        self.sni = configuration.serverName
    }
}

nonisolated extension HysteriaConfiguration: Codable {
    private enum CodingKeys: String, CodingKey {
        case password, congestionControl, uploadMbps, downloadMbps, obfuscation, serverName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            password: try container.decode(String.self, forKey: .password),
            congestionControl: try container.decodeIfPresent(HysteriaCongestionControl.self, forKey: .congestionControl) ?? .brutal,
            uploadMbps: try container.decodeIfPresent(Int.self, forKey: .uploadMbps) ?? HysteriaCongestionControl.uploadMbpsDefault,
            downloadMbps: try container.decodeIfPresent(Int.self, forKey: .downloadMbps) ?? HysteriaCongestionControl.downloadMbpsDefault,
            obfuscation: try container.decodeIfPresent(HysteriaObfuscation.self, forKey: .obfuscation),
            serverName: try container.decode(String.self, forKey: .serverName)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(password, forKey: .password)
        try container.encode(congestionControl, forKey: .congestionControl)
        try container.encode(uploadMbps, forKey: .uploadMbps)
        try container.encode(downloadMbps, forKey: .downloadMbps)
        try container.encodeIfPresent(obfuscation, forKey: .obfuscation)
        try container.encode(serverName, forKey: .serverName)
    }
}
