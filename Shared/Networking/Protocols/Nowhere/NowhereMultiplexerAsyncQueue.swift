//
//  NowhereMultiplexerAsyncQueue.swift
//  Anywhere
//
//  Created by NodePassProject on 8/24/26.
//

import Foundation
import Synchronization

nonisolated final class NowhereMultiplexerAsyncQueue<Element: Sendable>: Sendable {
    enum OfferResult {
        case accepted
        case full
        case finished
    }

    private struct State {
        var elements: [Element] = []
        var headIndex = 0
        var finished = false
        var failure: Error?
        var consumerGate = H2FlowGate()

        var bufferedCount: Int { elements.count - headIndex }

        mutating func popFirst() -> Element? {
            guard headIndex < elements.count else { return nil }
            let element = elements[headIndex]
            headIndex += 1

            if headIndex == elements.count {
                elements.removeAll(keepingCapacity: true)
                headIndex = 0
            } else if headIndex >= 64, headIndex * 2 >= elements.count {
                elements.removeFirst(headIndex)
                headIndex = 0
            }
            return element
        }

        mutating func discardBuffered() -> [Element] {
            guard headIndex < elements.count else {
                elements.removeAll(keepingCapacity: false)
                headIndex = 0
                return []
            }
            let discarded = Array(elements[headIndex...])
            elements.removeAll(keepingCapacity: false)
            headIndex = 0
            return discarded
        }
    }

    private enum ReceiveStep {
        case element(Element)
        case end
        case failed(Error)
        case wait(AsyncStream<Never>)
    }

    private let capacity: Int
    private let state = Mutex(State())

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func offer(_ element: Element) -> OfferResult {
        state.withLock { state in
            guard !state.finished else { return .finished }
            guard state.bufferedCount < capacity else { return .full }
            state.elements.append(element)
            state.consumerGate.wakeAll()
            return .accepted
        }
    }

    func next() async throws -> Element? {
        while true {
            try Task.checkCancellation()
            let step: ReceiveStep = state.withLock { state in
                if let element = state.popFirst() {
                    return .element(element)
                }
                if let failure = state.failure {
                    state.failure = nil
                    return .failed(failure)
                }
                if state.finished { return .end }
                return .wait(state.consumerGate.enroll())
            }
            switch step {
            case .element(let element):
                return element
            case .end:
                return nil
            case .failed(let error):
                throw error
            case .wait(let gate):
                for await _ in gate {}
            }
        }
    }

    @discardableResult
    func finish(throwing error: Error? = nil, discardingBuffered: Bool = false) -> [Element] {
        state.withLock { state in
            if !state.finished {
                state.finished = true
                state.failure = error
            } else if let error, state.failure == nil, discardingBuffered {
                state.failure = error
            }
            let discarded: [Element]
            if discardingBuffered {
                discarded = state.discardBuffered()
            } else {
                discarded = []
            }
            state.consumerGate.wakeAll()
            return discarded
        }
    }
}
