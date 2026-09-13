//
//  ShadowsocksConfiguration.swift
//  Anywhere
//
//  Created by NodePassProject on 9/13/26.
//

import Foundation

nonisolated struct ShadowsocksConfiguration: Hashable, Sendable {
    let password: String
    let method: String

    init(password: String, method: String) {
        self.password = password
        self.method = method
    }

    var cipher: ShadowsocksCipher? { ShadowsocksCipher(method: method) }
}

nonisolated extension ShadowsocksConfiguration: Codable {
    private enum CodingKeys: String, CodingKey {
        case password, method
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            password: try container.decode(String.self, forKey: .password),
            method: try container.decode(String.self, forKey: .method)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(password, forKey: .password)
        try container.encode(method, forKey: .method)
    }
}
