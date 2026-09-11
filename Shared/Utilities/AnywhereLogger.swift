//
//  AnywhereLogger.swift
//  Anywhere
//
//  Created by NodePassProject on 4/8/26.
//

import Foundation
import Synchronization
import os.log

nonisolated struct AnywhereLogger {
    private let logger: Logger
    
    private static let _logSink = Mutex<(@Sendable (String, Level) -> Void)?>(nil)
    static func installLogSink(_ sink: (@Sendable (String, Level) -> Void)?) {
        _logSink.withLock { $0 = sink }
    }
    static let minimumSinkLevel: Level = .info
    
    enum Level: Int, Comparable, Sendable {
        case debug = 0
        case info = 1
        case warning = 2
        case error = 3

        static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    init(category: String) {
        self.logger = Logger(subsystem: "com.argsment.Anywhere", category: category)
    }
    
    func debug(_ message: @autoclosure () -> String) {
#if DEBUG
        let text = message()
        logger.debug("\(text, privacy: .public)")
#endif
    }
    func info(_ message: @autoclosure () -> String) { emit(message(), level: .info) }
    func warning(_ message: @autoclosure () -> String) { emit(message(), level: .warning) }
    func error(_ message: @autoclosure () -> String) { emit(message(), level: .error) }

    private func emit(_ message: String, level: Level) {
        switch level {
        case .debug: break // unreachable: debug() logs to os.log directly
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }

        if level >= Self.minimumSinkLevel {
            let sink = Self._logSink.withLock { $0 }
            sink?(message, level)
        }
    }
}
