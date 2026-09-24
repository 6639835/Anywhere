//
//  MITMGateRegex.swift
//  Anywhere
//
//  Created by NodePassProject on 6/3/26.
//

import Foundation
import Synchronization

nonisolated private let logger = AnywhereLogger(category: "MITMGateRegex")

nonisolated final class MITMGateRegex: Sendable {
    private let regex: NSRegularExpression
    private let pattern: String
    
    private let isLiteral: Bool
    private let literalPattern: String
    
    private static let regexMetacharacters: Set<Character> = [
        "\\", "^", "$", ".", "|", "?", "*", "+", "(", ")", "[", "]", "{", "}"
    ]
    
    static let matchDeadlineMillis = 100
    static let hardCapSeconds = 30
    static let strikeLimit = 3
    
    private static let maxCacheEntries = 64

    private struct State {
        var cache: [String: Bool] = [:]
        var cacheOrder: [String] = []
        var timeoutStrikes = 0
        var quarantined = false
    }

    private let state = Mutex(State())
    
    init?(pattern: String) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        self.regex = regex
        self.pattern = pattern
        let literal = !pattern.isEmpty
            && !pattern.contains { Self.regexMetacharacters.contains($0) }
        self.isLiteral = literal
        if literal {
            self.literalPattern = Self.lowercasingHostRegion(pattern)
        } else {
            self.literalPattern = pattern
            Self.warnIfHostRegionHasUppercase(pattern)
        }
    }
    
    private static func lowercasingHostRegion(_ pattern: String) -> String {
        guard let sep = pattern.range(of: "://") else { return pattern }
        let authStart = sep.upperBound
        let authEnd = pattern[authStart...].firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? pattern.endIndex
        return pattern[..<authStart].lowercased()
            + pattern[authStart..<authEnd].lowercased()
            + String(pattern[authEnd...])
    }
    
    private static func warnIfHostRegionHasUppercase(_ pattern: String) {
        guard let schemeRange = pattern.range(of: "://") else { return }
        let authority = pattern[schemeRange.upperBound...].prefix { $0 != "/" }
        if authority.contains(where: { $0.isASCII && $0.isUppercase }) {
            logger.warning("gate pattern \"\(pattern)\" has an uppercase letter in its host region; the URL host is matched lowercased, so this rule will never fire — write the host in lowercase")
        }
    }
    
    func peekMatches(_ normalizedURL: String) -> Bool? {
        if isLiteral {
            return normalizedURL.range(of: literalPattern, options: .literal) != nil
        }
        return state.withLock { state in
            if state.quarantined { return false }
            return state.cache[normalizedURL]
        }
    }
    
    func matches(_ normalizedURL: String) async -> Bool {
        if let verdict = peekMatches(normalizedURL) { return verdict }
        if Task.isCancelled { return false }
        
        let regex = self.regex
        let pattern = self.pattern
        let outcome = await MITMRegexConcurrencyBridge.shared.firstMatch(
            regex, in: normalizedURL,
            deadlineMillis: Self.matchDeadlineMillis,
            hardCapSeconds: Self.hardCapSeconds,
            hardCapMessage: { Self.hardCapMessage(pattern: pattern) },
            onResolved: { [weak self] matched in self?.store(normalizedURL, matched) }
        )
        switch outcome {
        case .completed(let matched):
            return matched
        case .timedOut:
            if !Task.isCancelled { recordStrike() }
            return false
        }
    }
    
    func peekFirstMatchCaptures(_ normalizedURL: String) -> [String?]?? {
        if isLiteral {
            guard let r = normalizedURL.range(of: literalPattern, options: .literal) else {
                return .some(nil)
            }
            return [String(normalizedURL[r])]
        }
        if state.withLock({ $0.quarantined }) { return .some(nil) }
        return nil
    }
    
    func firstMatchCaptures(_ normalizedURL: String) async -> [String?]? {
        if let captures = peekFirstMatchCaptures(normalizedURL) { return captures }
        if Task.isCancelled { return nil }
        
        let regex = self.regex
        let pattern = self.pattern
        let outcome = await MITMRegexConcurrencyBridge.shared.firstMatchCaptureGroups(
            regex, in: normalizedURL,
            deadlineMillis: Self.matchDeadlineMillis,
            hardCapSeconds: Self.hardCapSeconds,
            hardCapMessage: { Self.hardCapMessage(pattern: pattern) }
        )
        switch outcome {
        case .completed(let captures):
            return captures
        case .timedOut:
            if !Task.isCancelled { recordStrike() }
            return nil
        }
    }
    
    private static func hardCapMessage(pattern: String) -> String {
        let shown = pattern.count > 200 ? String(pattern.prefix(200)) + "…" : pattern
        return "URL-gate regex did not return \(hardCapSeconds)s after blowing its \(matchDeadlineMillis)ms budget — a worker thread is permanently pinned by catastrophic backtracking and can't be reclaimed. Crashing the Network Extension so the system relaunches it clean. Offending pattern: \(shown)"
    }
    
    private func store(_ url: String, _ matched: Bool) {
        state.withLock { state in
            guard !state.quarantined else { return }
            if state.cache[url] == nil {
                state.cache[url] = matched
                state.cacheOrder.append(url)
                if state.cacheOrder.count > Self.maxCacheEntries {
                    let evicted = state.cacheOrder.removeFirst()
                    state.cache.removeValue(forKey: evicted)
                }
            } else {
                state.cache[url] = matched
            }
        }
    }
    
    private func recordStrike() {
        let message: String? = state.withLock { state in
            guard !state.quarantined else { return nil }
            state.timeoutStrikes += 1
            if state.timeoutStrikes >= Self.strikeLimit {
                state.quarantined = true
                state.cache.removeAll(keepingCapacity: false)
                state.cacheOrder.removeAll(keepingCapacity: false)
                return "URL-gate pattern quarantined after \(Self.strikeLimit) match timeouts (\(Self.matchDeadlineMillis)ms each); the rule is disabled. Pattern: \(pattern)"
            } else {
                return "URL-gate match exceeded its \(Self.matchDeadlineMillis)ms budget (strike \(state.timeoutStrikes)/\(Self.strikeLimit)); failing this match closed. Pattern: \(pattern)"
            }
        }
        if let message {
            logger.warning(message)
        }
    }
}
