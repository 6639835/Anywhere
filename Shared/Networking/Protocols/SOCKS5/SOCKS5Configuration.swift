//
//  SOCKS5Configuration.swift
//  Anywhere
//
//  Created by NodePassProject on 9/13/26.
//

import Foundation

nonisolated struct SOCKS5Configuration: Hashable, Sendable {
    let username: String?
    let password: String?

    init(username: String? = nil, password: String? = nil) {
        self.username = username
        self.password = password
    }

    var hasCredentials: Bool { !(username ?? "").isEmpty }
}

nonisolated extension SOCKS5Configuration: Codable {
    private enum CodingKeys: String, CodingKey {
        case username, password
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            username: try container.decodeIfPresent(String.self, forKey: .username),
            password: try container.decodeIfPresent(String.self, forKey: .password)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encodeIfPresent(password, forKey: .password)
    }
}
