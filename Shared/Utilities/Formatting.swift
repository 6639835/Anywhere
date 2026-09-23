//
//  Formatting.swift
//  Anywhere
//
//  Created by NodePassProject on 9/23/26.
//

import Foundation

nonisolated enum Formatting {
    private static let byteCountStyle = ByteCountFormatStyle(style: .binary, spellsOutZero: false)

    static func formatBytes(_ bytes: Int64) -> String {
        bytes.formatted(byteCountStyle)
    }

    static func formatBytesPerSecond(_ bytesPerSecond: Int64?) -> String {
        guard let bytesPerSecond else { return "—" }
        return String(localized: "\(formatBytes(bytesPerSecond))/s")
    }

    static func formatMilliseconds(_ ms: Int?) -> String {
        guard let ms else { return "—" }
        return String(localized: "\(ms) ms")
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)
        )
    }
}
