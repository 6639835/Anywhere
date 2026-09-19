//
//  NowhereMultiplexer.swift
//  Anywhere
//
//  Created by NodePassProject on 8/24/26.
//

import Foundation
import Synchronization

nonisolated fileprivate enum NowhereMultiplexerInboundEvent: Sendable {
    case data(Data)
    case fin
}

nonisolated final class NowhereMultiplexer: Multiplexer, Sendable {
    struct LoadSnapshot: Sendable {
        let connectionCredit: Int
        let outboundFrames: Int
        let activeStreams: Int
    }

    struct StreamReservation: Sendable {
        fileprivate let flowID: UInt32
        fileprivate let inbox: NowhereMultiplexerAsyncQueue<NowhereMultiplexerInboundEvent>
        fileprivate let termination: TerminationLatch
    }

    private struct FlowState: Sendable {
        let inbox: NowhereMultiplexerAsyncQueue<NowhereMultiplexerInboundEvent>
        let termination: TerminationLatch
        var onEnd: (@Sendable () -> Void)?

        var acceptsWrites = true
        var localTerminalSent = false
        var peerFinished = false
        var dataInFlight = false
        var sendCredit = NowhereMultiplexerConstants.baseStreamWindowBytes
        var fairSendCredit = NowhereMultiplexerConstants.baseStreamWindowBytes
        var fairLimit = NowhereMultiplexerConstants.baseStreamWindowBytes
        var fairDebt = 0
        var receiveCredit = NowhereMultiplexerConstants.streamWindowBytes
        var pendingReceiveCredit = 0
    }

    private struct RetiredFlow: Sendable {
        var receiveCredit: Int
    }

    private struct State {
        var flows: [UInt32: FlowState] = [:]
        var retiredFlows: [UInt32: RetiredFlow] = [:]
        var draining = false
        var connectionSendCredit = NowhereMultiplexerConstants.baseConnectionWindowBytes
        var connectionReceiveCredit = NowhereMultiplexerConstants.connectionWindowBytes
        var pendingConnectionCredit = 0

        var outboundFrames = 0
        var windowFlushRunning = false
        var forceWindowFlush = false

        var closed = false
        var terminalError: Error?
        var closeHandlerInstalled = false
        var closeHandler: (@Sendable () -> Void)?

        var sendCreditGate = H2FlowGate()
        var outboundGate = H2FlowGate()
    }

    private enum CreditStep {
        case acquired
        case failed(Error)
        case wait(AsyncStream<Never>)
    }

    private enum OutboundStep {
        case acquired
        case failed(Error)
        case wait(AsyncStream<Never>)
    }

    private struct RemovedFlow {
        let inbox: NowhereMultiplexerAsyncQueue<NowhereMultiplexerInboundEvent>
        let termination: TerminationLatch
        let onEnd: (@Sendable () -> Void)?
    }

    private struct LocalClosePreparation {
        let inbox: NowhereMultiplexerAsyncQueue<NowhereMultiplexerInboundEvent>
        let onEnd: (@Sendable () -> Void)?
    }

    private enum ReceiveAdmission {
        case deliver(NowhereMultiplexerAsyncQueue<NowhereMultiplexerInboundEvent>)
        case discard
    }

    private let transport: any ByteTransport
    private let tlsVersion: TLSVersion?
    private let chainHolders: [ProxyClient]
    private let state = Mutex(State())
    private let writer = SerialSender()
    private let readerTask = Mutex<Task<Void, Never>?>(nil)

    init(
        transport: any ByteTransport,
        tlsVersion: TLSVersion?,
        chainHolders: [ProxyClient] = []
    ) {
        self.transport = transport
        self.tlsVersion = tlsVersion
        self.chainHolders = chainHolders
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runReader()
        }
        readerTask.withLock { $0 = task }
    }

    deinit {
        close()
        writer.cancel()
    }

    var outerTLSVersion: TLSVersion? { tlsVersion }

    var isClosed: Bool { state.withLock { $0.closed } }

    var activeStreamCount: Int { state.withLock { Self.activeFlowCount($0) } }

    var loadSnapshot: LoadSnapshot {
        state.withLock {
            LoadSnapshot(
                connectionCredit: $0.connectionSendCredit,
                outboundFrames: $0.outboundFrames,
                activeStreams: Self.activeFlowCount($0)
            )
        }
    }

    func installCloseHandler(_ handler: @escaping @Sendable () -> Void) {
        let immediate: (@Sendable () -> Void)? = state.withLock { state in
            guard !state.closeHandlerInstalled else { return nil }
            state.closeHandlerInstalled = true
            guard !state.closed else { return handler }
            state.closeHandler = handler
            return nil
        }
        immediate?()
    }

    func openStream(flowID: UInt32) async throws -> NowhereMultiplexerStream {
        guard let reservation = try reserveStream(
            flowID: flowID,
            maximumActiveFlows: NowhereMultiplexerConstants.maximumStreams
        ) else {
            throw AnywhereError.proxy(.nowhere, .streamIDsExhausted)
        }
        return try await openStream(reservation)
    }

    func reserveStream(
        flowID: UInt32,
        maximumActiveFlows: Int,
        onEnd: (@Sendable () -> Void)? = nil
    ) throws -> StreamReservation? {
        precondition((1...NowhereMultiplexerConstants.maximumStreams).contains(maximumActiveFlows))
        guard (1...NowhereProtocol.maximumFlowID).contains(flowID) else {
            throw NowhereMultiplexerWireError.invalidFlowID
        }
        var closeDrainedCarrier = false
        let reservation = try state.withLock { state -> StreamReservation? in
            guard !state.closed else { throw Self.closedError(state.terminalError) }
            if let existing = state.flows[flowID] {
                guard existing.acceptsWrites else { return nil }
                throw AnywhereError.proxy(
                    .nowhere,
                    .protocolViolation(detail: "Multiplexer flow \(flowID) already exists")
                )
            }
            guard state.retiredFlows[flowID] == nil else { return nil }
            guard !state.draining else { return nil }
            guard Self.activeFlowCount(state) < maximumActiveFlows else { return nil }
            guard state.flows.count + state.retiredFlows.count < NowhereMultiplexerConstants.maximumStreams else {
                state.draining = true
                closeDrainedCarrier = Self.activeFlowCount(state) == 0
                return nil
            }
            let inbox = NowhereMultiplexerAsyncQueue<NowhereMultiplexerInboundEvent>(
                capacity: NowhereMultiplexerConstants.inboundFrameLimit
            )
            let termination = TerminationLatch()
            state.flows[flowID] = FlowState(
                inbox: inbox,
                termination: termination,
                onEnd: onEnd
            )
            if state.flows.count + state.retiredFlows.count
                >= NowhereMultiplexerConstants.maximumStreams {
                state.draining = true
            }
            Self.rebalanceFairCredits(&state)
            return StreamReservation(
                flowID: flowID,
                inbox: inbox,
                termination: termination
            )
        }
        if closeDrainedCarrier {
            Task { [self] in terminate(error: nil) }
        }
        return reservation
    }

    func openStream(_ reservation: StreamReservation) async throws -> NowhereMultiplexerStream {
        do {
            let syn = try NowhereMultiplexerFrameHeader.open(flowID: reservation.flowID)
            try await writeFrame(
                header: syn,
                payload: Data(),
                shieldCancellation: true
            )
        } catch {
            finishRemovedFlow(
                removeFlow(reservation.flowID),
                error: error,
                discardingBuffered: true
            )
            throw error
        }

        if Task.isCancelled {
            prepareLocalClose(flowID: reservation.flowID, reset: true)
            await Task.detached { [self] in
                await closeStream(flowID: reservation.flowID, reset: true)
            }.value
            throw CancellationError()
        }
        return NowhereMultiplexerStream(
            multiplexer: self,
            flowID: reservation.flowID,
            inbox: reservation.inbox,
            termination: reservation.termination
        )
    }

    func close() {
        terminate(error: nil)
    }

    func close(error: Error?) {
        terminate(error: error)
    }

    func abort() {
        terminate(error: AnywhereError.proxy(.nowhere, .streamClosed))
    }

    // MARK: - Logical stream operations

    fileprivate func containsFlow(_ flowID: UInt32) -> Bool {
        state.withLock { !$0.closed && $0.flows[flowID] != nil }
    }

    fileprivate func prepareLocalClose(flowID: UInt32, reset: Bool) {
        let preparation: LocalClosePreparation? = state.withLock { state in
            guard var flow = state.flows[flowID], flow.acceptsWrites else { return nil }
            flow.acceptsWrites = false
            flow.pendingReceiveCredit = 0
            let onEnd = flow.onEnd
            flow.onEnd = nil
            state.flows[flowID] = flow
            if state.flows.count + state.retiredFlows.count
                >= NowhereMultiplexerConstants.maximumStreams {
                state.draining = true
            }
            Self.rebalanceFairCredits(&state)
            state.sendCreditGate.wakeAll()
            return LocalClosePreparation(inbox: flow.inbox, onEnd: onEnd)
        }
        guard let preparation else { return }
        let error: Error? = reset
            ? AnywhereError.proxy(.nowhere, .streamReset(code: flowID))
            : nil
        let discarded = preparation.inbox.finish(throwing: error, discardingBuffered: true)
        let released = discarded.reduce(into: 0) { total, event in
            if case .data(let data) = event { total += Self.creditBytes(for: data.count) }
        }
        if released != 0 { releaseConnectionReceiveCredit(count: released) }
        preparation.onEnd?()
    }

    fileprivate func sendData(_ data: Data, flowID: UInt32) async throws {
        var offset = 0
        while offset < data.count {
            let length = min(NowhereMultiplexerConstants.maximumFramePayload, data.count - offset)
            let charged = Self.creditBytes(for: length)
            try await acquireSendCredit(flowID: flowID, count: charged)
            let end = offset + length
            let payload = data.subdata(in: offset..<end)
            let header = try NowhereMultiplexerFrameHeader.data(
                flowID: flowID,
                payloadLength: length
            )
            try await writeFrame(header: header, payload: payload) { [self] in
                rollbackSendCredit(flowID: flowID, count: charged)
            }
            releaseDataSlot(flowID: flowID)
            offset = end
        }
    }

    fileprivate func receiveData(
        flowID: UInt32,
        inbox: NowhereMultiplexerAsyncQueue<NowhereMultiplexerInboundEvent>
    ) async throws -> Data? {
        while let event = try await inbox.next() {
            switch event {
            case .data(let data):
                releaseReceiveCredit(flowID: flowID, count: Self.creditBytes(for: data.count))
                return data
            case .fin:
                return nil
            }
        }
        return nil
    }

    fileprivate func closeStream(flowID: UInt32, reset: Bool) async {
        if !isClosed {
            do {
                let header = try NowhereMultiplexerFrameHeader.terminal(flowID: flowID, reset: reset)
                try await writeFrame(header: header, payload: Data())
            } catch {
                terminate(error: error)
                return
            }
        }
        finishLocalClose(flowID: flowID, reset: reset)
    }

    // MARK: - Flow state

    private func finishLocalClose(flowID: UInt32, reset: Bool) {
        let closeDrainedCarrier = state.withLock { state -> Bool in
            guard !state.closed, var flow = state.flows[flowID], !flow.acceptsWrites else {
                return false
            }
            flow.localTerminalSent = true
            state.flows[flowID] = flow
            if flow.peerFinished {
                state.flows.removeValue(forKey: flowID)
            } else if reset {
                state.flows.removeValue(forKey: flowID)
                state.retiredFlows[flowID] = RetiredFlow(receiveCredit: flow.receiveCredit)
                if state.retiredFlows.count >= NowhereMultiplexerConstants.maximumStreams {
                    state.draining = true
                }
            }
            Self.rebalanceFairCredits(&state)
            state.sendCreditGate.wakeAll()
            return state.draining && Self.activeFlowCount(state) == 0
        }
        if closeDrainedCarrier { terminate(error: nil) }
    }

    private func removeFlow(_ flowID: UInt32) -> RemovedFlow? {
        var launchFlush = false
        var closeDrainedCarrier = false
        let removed: RemovedFlow? = state.withLock { state in
            guard let flow = state.flows.removeValue(forKey: flowID) else { return nil }
            Self.rebalanceFairCredits(&state)
            if state.pendingConnectionCredit != 0 {
                state.forceWindowFlush = true
                if !state.windowFlushRunning {
                    state.windowFlushRunning = true
                    launchFlush = true
                }
            }
            state.sendCreditGate.wakeAll()
            closeDrainedCarrier = state.draining && Self.activeFlowCount(state) == 0
            return RemovedFlow(
                inbox: flow.inbox,
                termination: flow.termination,
                onEnd: flow.onEnd
            )
        }
        if launchFlush { launchWindowFlush() }
        if closeDrainedCarrier { terminate(error: nil) }
        return removed
    }

    private func finishRemovedFlow(
        _ removed: RemovedFlow?,
        error: Error?,
        discardingBuffered: Bool
    ) {
        guard let removed else { return }
        let discarded = removed.inbox.finish(
            throwing: error,
            discardingBuffered: discardingBuffered
        )
        let released = discarded.reduce(into: 0) { total, event in
            if case .data(let data) = event { total += Self.creditBytes(for: data.count) }
        }
        if released != 0 { releaseConnectionReceiveCredit(count: released) }
        removed.termination.fire(error)
        removed.onEnd?()
    }

    private static func rebalanceFairCredits(_ state: inout State) {
        let activeFlowIDs = state.flows.compactMap { flowID, flow in
            flow.acceptsWrites ? flowID : nil
        }
        guard !activeFlowIDs.isEmpty else {
            state.sendCreditGate.wakeAll()
            return
        }
        let fairLimit = max(
            NowhereMultiplexerConstants.minimumFairCreditBytes,
            NowhereMultiplexerConstants.connectionWindowBytes / activeFlowIDs.count
        )
        let boundedLimit = min(fairLimit, NowhereMultiplexerConstants.streamWindowBytes)

        for flowID in activeFlowIDs {
            guard var flow = state.flows[flowID] else { continue }
            if boundedLimit < flow.fairLimit {
                let reduction = flow.fairLimit - boundedLimit
                let removed = min(reduction, flow.fairSendCredit)
                flow.fairSendCredit -= removed
                flow.fairDebt += reduction - removed
            } else if boundedLimit > flow.fairLimit {
                let increase = boundedLimit - flow.fairLimit
                let repaid = min(increase, flow.fairDebt)
                flow.fairDebt -= repaid
                flow.fairSendCredit += increase - repaid
            }
            flow.fairLimit = boundedLimit
            state.flows[flowID] = flow
        }
        state.sendCreditGate.wakeAll()
    }

    private static func activeFlowCount(_ state: State) -> Int {
        state.flows.values.reduce(into: 0) { count, flow in
            if flow.acceptsWrites { count += 1 }
        }
    }

    private static func returnFairCredit(_ credit: Int, to flow: inout FlowState) {
        let repaid = min(credit, flow.fairDebt)
        flow.fairDebt -= repaid
        let returned = credit - repaid
        let room = max(0, flow.fairLimit - flow.fairSendCredit)
        flow.fairSendCredit += min(returned, room)
    }

    private func rollbackSendCredit(flowID: UInt32, count: Int) {
        state.withLock { state in
            guard !state.closed, var flow = state.flows[flowID] else { return }
            flow.dataInFlight = false
            flow.sendCredit = min(
                NowhereMultiplexerConstants.streamWindowBytes,
                flow.sendCredit + count
            )
            Self.returnFairCredit(count, to: &flow)
            state.connectionSendCredit = min(
                NowhereMultiplexerConstants.connectionWindowBytes,
                state.connectionSendCredit + count
            )
            state.flows[flowID] = flow
            state.sendCreditGate.wakeAll()
        }
    }

    private func releaseDataSlot(flowID: UInt32) {
        state.withLock { state in
            guard var flow = state.flows[flowID] else { return }
            flow.dataInFlight = false
            state.flows[flowID] = flow
            state.sendCreditGate.wakeAll()
        }
    }

    // MARK: - Send flow control

    private func acquireSendCredit(flowID: UInt32, count: Int) async throws {
        precondition((1...NowhereMultiplexerConstants.maximumFramePayload).contains(count))
        while true {
            try Task.checkCancellation()
            let step: CreditStep = state.withLock { state in
                guard !state.closed else { return .failed(Self.closedError(state.terminalError)) }
                guard var flow = state.flows[flowID], flow.acceptsWrites else {
                    return .failed(AnywhereError.proxy(.nowhere, .streamClosed))
                }
                if !flow.dataInFlight,
                   flow.sendCredit >= count,
                   flow.fairSendCredit >= count,
                   state.connectionSendCredit >= count {
                    flow.dataInFlight = true
                    flow.sendCredit -= count
                    flow.fairSendCredit -= count
                    state.connectionSendCredit -= count
                    state.flows[flowID] = flow
                    return .acquired
                }
                return .wait(state.sendCreditGate.enroll())
            }
            switch step {
            case .acquired:
                return
            case .failed(let error):
                throw error
            case .wait(let gate):
                for await _ in gate {}
            }
        }
    }

    private func receiveWindow(_ header: NowhereMultiplexerFrameHeader) throws {
        let credit = Int(header.value) * 1024
        try state.withLock { state in
            guard !state.closed else { throw Self.closedError(state.terminalError) }
            if header.flowID == 0 {
                guard state.connectionSendCredit + credit <= NowhereMultiplexerConstants.connectionWindowBytes else {
                    throw AnywhereError.proxy(
                        .nowhere,
                        .protocolViolation(detail: "Multiplexer connection window overflow")
                    )
                }
                state.connectionSendCredit += credit
                state.sendCreditGate.wakeAll()
                return
            }

            guard var flow = state.flows[header.flowID] else { return }
            guard flow.sendCredit + credit <= NowhereMultiplexerConstants.streamWindowBytes else {
                throw AnywhereError.proxy(
                    .nowhere,
                    .protocolViolation(detail: "Multiplexer stream window overflow")
                )
            }
            flow.sendCredit += credit
            Self.returnFairCredit(credit, to: &flow)
            state.flows[header.flowID] = flow
            state.sendCreditGate.wakeAll()
        }
    }

    // MARK: - Receive flow control

    private func admitReceive(flowID: UInt32, count: Int) throws -> ReceiveAdmission {
        try state.withLock { state in
            guard !state.closed else { throw Self.closedError(state.terminalError) }
            if var flow = state.flows[flowID] {
                guard !flow.peerFinished else {
                    throw AnywhereError.proxy(
                        .nowhere,
                        .protocolViolation(detail: "STREAM data after Multiplexer FIN for flow \(flowID)")
                    )
                }
                guard flow.receiveCredit >= count, state.connectionReceiveCredit >= count else {
                    throw AnywhereError.proxy(
                        .nowhere,
                        .protocolViolation(detail: "Peer exceeded Multiplexer receive window")
                    )
                }
                flow.receiveCredit -= count
                state.connectionReceiveCredit -= count
                state.flows[flowID] = flow
                return flow.acceptsWrites ? .deliver(flow.inbox) : .discard
            }
            if var retired = state.retiredFlows[flowID] {
                guard retired.receiveCredit >= count, state.connectionReceiveCredit >= count else {
                    throw AnywhereError.proxy(
                        .nowhere,
                        .protocolViolation(detail: "Peer exceeded Multiplexer receive window")
                    )
                }
                retired.receiveCredit -= count
                state.connectionReceiveCredit -= count
                state.retiredFlows[flowID] = retired
                return .discard
            }
            throw AnywhereError.proxy(
                .nowhere,
                .protocolViolation(detail: "STREAM data for unknown Multiplexer flow \(flowID)")
            )
        }
    }

    private func releaseReceiveCredit(flowID: UInt32, count: Int) {
        guard count != 0 else { return }
        let launch = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            state.connectionReceiveCredit = min(
                NowhereMultiplexerConstants.connectionWindowBytes,
                state.connectionReceiveCredit + count
            )
            state.pendingConnectionCredit += count

            var flowTriggered = false
            if var flow = state.flows[flowID], flow.acceptsWrites {
                flow.receiveCredit = min(
                    NowhereMultiplexerConstants.streamWindowBytes,
                    flow.receiveCredit + count
                )
                flow.pendingReceiveCredit += count
                flowTriggered = flow.pendingReceiveCredit >= NowhereMultiplexerConstants.windowUpdateThreshold
                state.flows[flowID] = flow
            }
            let connectionTriggered = state.pendingConnectionCredit >= NowhereMultiplexerConstants.windowUpdateThreshold
            guard (flowTriggered || connectionTriggered), !state.windowFlushRunning else {
                return false
            }
            state.windowFlushRunning = true
            return true
        }
        if launch { launchWindowFlush() }
    }

    private func releaseConnectionReceiveCredit(count: Int) {
        guard count != 0 else { return }
        let launch = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            state.connectionReceiveCredit = min(
                NowhereMultiplexerConstants.connectionWindowBytes,
                state.connectionReceiveCredit + count
            )
            state.pendingConnectionCredit += count
            state.forceWindowFlush = true
            guard !state.windowFlushRunning else { return false }
            state.windowFlushRunning = true
            return true
        }
        if launch { launchWindowFlush() }
    }

    private func launchWindowFlush() {
        Task { [weak self] in
            await self?.flushWindows()
        }
    }

    private func flushWindows() async {
        while !Task.isCancelled {
            let credits: (connection: Int, flows: [(UInt32, Int)])? = state.withLock { state in
                guard !state.closed else {
                    state.windowFlushRunning = false
                    return nil
                }
                let connection = state.pendingConnectionCredit
                state.pendingConnectionCredit = 0
                state.forceWindowFlush = false
                var flows: [(UInt32, Int)] = []
                for flowID in Array(state.flows.keys) {
                    guard var flow = state.flows[flowID], flow.pendingReceiveCredit != 0 else {
                        continue
                    }
                    flows.append((flowID, flow.pendingReceiveCredit))
                    flow.pendingReceiveCredit = 0
                    state.flows[flowID] = flow
                }
                return (connection, flows)
            }
            guard let credits else { return }

            do {
                try await writeWindows(flowID: 0, credit: credits.connection)
                for (flowID, credit) in credits.flows {
                    try await writeWindows(flowID: flowID, credit: credit)
                }
            } catch {
                return
            }

            let again = state.withLock { state -> Bool in
                guard !state.closed else {
                    state.windowFlushRunning = false
                    return false
                }
                let flowReady = state.flows.values.contains {
                    $0.pendingReceiveCredit >= NowhereMultiplexerConstants.windowUpdateThreshold
                }
                let ready = state.forceWindowFlush
                    || state.pendingConnectionCredit >= NowhereMultiplexerConstants.windowUpdateThreshold
                    || flowReady
                if !ready { state.windowFlushRunning = false }
                return ready
            }
            if !again { return }
        }
        state.withLock { $0.windowFlushRunning = false }
    }

    private func writeWindows(flowID: UInt32, credit: Int) async throws {
        var remaining = credit
        while remaining != 0 {
            let delta = min(remaining, Int(UInt16.max) * 1024)
            let header = try NowhereMultiplexerFrameHeader.window(flowID: flowID, creditUnits: delta / 1024)
            try await writeFrame(header: header, payload: Data())
            remaining -= delta
        }
    }

    // MARK: - Bounded serialized writer

    private func acquireOutboundSlot() async throws {
        while true {
            try Task.checkCancellation()
            let step: OutboundStep = state.withLock { state in
                guard !state.closed else { return .failed(Self.closedError(state.terminalError)) }
                guard state.outboundFrames >= NowhereMultiplexerConstants.outboundFrameLimit else {
                    state.outboundFrames += 1
                    return .acquired
                }
                return .wait(state.outboundGate.enroll())
            }
            switch step {
            case .acquired:
                return
            case .failed(let error):
                throw error
            case .wait(let gate):
                for await _ in gate {}
            }
        }
    }

    private func releaseOutboundSlot() {
        state.withLock { state in
            state.outboundFrames = max(0, state.outboundFrames - 1)
            state.outboundGate.wakeAll()
        }
    }

    private func writeFrame(
        header: NowhereMultiplexerFrameHeader,
        payload: Data,
        onAdmissionFailure: (@Sendable () -> Void)? = nil,
        shieldCancellation: Bool = false
    ) async throws {
        let encodedHeader: Data
        do {
            encodedHeader = try header.encode()
        } catch {
            onAdmissionFailure?()
            throw error
        }
        do {
            try await acquireOutboundSlot()
        } catch {
            onAdmissionFailure?()
            throw error
        }
        let encoded = encodedHeader + payload

        let pending = writer.submit { [self] in
            defer { releaseOutboundSlot() }
            guard !isClosed else { throw Self.closedError(nil) }
            do {
                try await transport.send(encoded)
            } catch {
                terminate(error: error)
                throw error
            }
        }
        if shieldCancellation {
            let committed = Task.detached {
                try await pending.value()
            }
            try await committed.value
        } else {
            try await pending.value()
        }
    }

    // MARK: - Reader / parser

    private func runReader() async {
        var buffer = Data()
        do {
            while !Task.isCancelled {
                let chunk: Data
                switch try await transport.receive() {
                case .bytes(let data):
                    chunk = data
                case .end:
                    guard buffer.isEmpty else {
                        throw AnywhereError.proxy(
                            .nowhere,
                            .protocolViolation(detail: "Truncated Multiplexer frame")
                        )
                    }
                    terminate(error: nil)
                    return
                }
                if chunk.isEmpty { continue }
                buffer.append(chunk)

                var consumed = 0
                while buffer.count - consumed >= NowhereMultiplexerConstants.headerSize {
                    let headerEnd = consumed + NowhereMultiplexerConstants.headerSize
                    let header = try NowhereMultiplexerFrameHeader.decode(
                        buffer.subdata(in: consumed..<headerEnd)
                    )
                    let payloadLength: Int
                    switch header.kind {
                    case .data:
                        payloadLength = Int(header.value)
                    case .open, .window, .fin, .reset:
                        payloadLength = 0
                    }
                    guard buffer.count - headerEnd >= payloadLength else { break }
                    let payload = payloadLength == 0
                        ? Data()
                        : buffer.subdata(in: headerEnd..<(headerEnd + payloadLength))
                    consumed = headerEnd + payloadLength
                    try await receiveFrame(header: header, payload: payload)
                }

                if consumed != 0 { buffer.removeSubrange(0..<consumed) }
            }
        } catch is CancellationError {
            if !isClosed {
                terminate(error: AnywhereError.proxy(.nowhere, .streamClosed))
            }
        } catch {
            terminate(error: error)
        }
    }

    private func receiveFrame(header: NowhereMultiplexerFrameHeader, payload: Data) async throws {
        switch header.kind {
        case .window:
            try receiveWindow(header)
        case .open:
            throw AnywhereError.proxy(
                .nowhere,
                .protocolViolation(detail: "Portal initiated an unsupported Multiplexer stream")
            )
        case .reset:
            let retiredClose = state.withLock { state -> Bool? in
                guard state.retiredFlows.removeValue(forKey: header.flowID) != nil else {
                    return nil
                }
                return state.draining && Self.activeFlowCount(state) == 0
            }
            if let retiredClose {
                if retiredClose { terminate(error: nil) }
                return
            }
            let removed = removeFlow(header.flowID)
            guard let removed else { return }
            let reset = AnywhereError.proxy(.nowhere, .streamReset(code: header.flowID))
            finishRemovedFlow(removed, error: reset, discardingBuffered: true)
        case .data:
            let charged = Self.creditBytes(for: payload.count)
            switch try admitReceive(flowID: header.flowID, count: charged) {
            case .discard:
                releaseConnectionReceiveCredit(count: charged)
            case .deliver(let inbox):
                do {
                    try await inbox.send(.data(payload))
                } catch {
                    guard isLocallyFinished(flowID: header.flowID) else { throw error }
                    releaseConnectionReceiveCredit(count: charged)
                }
            }
        case .fin:
            var closeDrainedCarrier = false
            let flow: FlowState? = state.withLock { state in
                if state.retiredFlows.removeValue(forKey: header.flowID) != nil {
                    closeDrainedCarrier = state.draining && Self.activeFlowCount(state) == 0
                    return nil
                }
                guard var flow = state.flows[header.flowID], !flow.peerFinished else {
                    return nil
                }
                if !flow.acceptsWrites {
                    flow.peerFinished = true
                    if flow.localTerminalSent {
                        state.flows.removeValue(forKey: header.flowID)
                    } else {
                        state.flows[header.flowID] = flow
                    }
                    closeDrainedCarrier = state.draining && Self.activeFlowCount(state) == 0
                    return nil
                }
                flow.peerFinished = true
                state.flows[header.flowID] = flow
                return flow
            }
            if closeDrainedCarrier {
                terminate(error: nil)
                return
            }
            if let flow {
                do {
                    try await flow.inbox.send(.fin)
                } catch {
                    guard isLocallyFinished(flowID: header.flowID) else { throw error }
                    return
                }
                flow.inbox.finish()
                flow.termination.fire(nil)
            }
        }
    }

    private func isLocallyFinished(flowID: UInt32) -> Bool {
        state.withLock { state in
            guard !state.closed else { return false }
            guard let flow = state.flows[flowID] else { return true }
            return !flow.acceptsWrites
        }
    }

    private static func creditBytes(for payloadLength: Int) -> Int {
        ((payloadLength + 1023) / 1024) * 1024
    }

    // MARK: - Teardown

    private func terminate(error: Error?) {
        let terminated: (flows: [FlowState], onClose: (@Sendable () -> Void)?)? = state.withLock { state in
            guard !state.closed else { return nil }
            state.closed = true
            state.terminalError = error
            let flows = Array(state.flows.values)
            let onClose = state.closeHandler
            state.flows.removeAll(keepingCapacity: false)
            state.retiredFlows.removeAll(keepingCapacity: false)
            state.closeHandler = nil
            state.sendCreditGate.wakeAll()
            state.outboundGate.wakeAll()
            return (flows, onClose)
        }
        guard let terminated else { return }

        readerTask.withLock { task in
            task?.cancel()
            task = nil
        }
        for flow in terminated.flows {
            flow.inbox.finish(throwing: error)
            flow.termination.fire(error)
            flow.onEnd?()
        }
        transport.cancel()
        for client in chainHolders { client.cancel() }
        terminated.onClose?()
    }

    private static func closedError(_ underlying: Error?) -> Error {
        underlying ?? AnywhereError.proxy(.nowhere, .streamClosed)
    }

}

nonisolated final class NowhereMultiplexerStream: ProxyConnection, NowhereTerminationObservable {
    private struct Lifecycle {
        var closed = false
    }

    let flowID: UInt32

    private let multiplexer: NowhereMultiplexer
    private let inbox: NowhereMultiplexerAsyncQueue<NowhereMultiplexerInboundEvent>
    private let termination: TerminationLatch
    private let operations = SerialSender()
    private let lifecycle = Mutex(Lifecycle())

    fileprivate init(
        multiplexer: NowhereMultiplexer,
        flowID: UInt32,
        inbox: NowhereMultiplexerAsyncQueue<NowhereMultiplexerInboundEvent>,
        termination: TerminationLatch
    ) {
        self.multiplexer = multiplexer
        self.flowID = flowID
        self.inbox = inbox
        self.termination = termination
    }

    deinit {
        finish(reset: false)
    }

    var outerTLSVersion: TLSVersion? { multiplexer.outerTLSVersion }

    var isConnected: Bool {
        !lifecycle.withLock { $0.closed } && multiplexer.containsFlow(flowID)
    }

    func setNowhereTerminationHandler(_ handler: (@Sendable (Error?) -> Void)?) {
        termination.install(handler)
    }

    func sendRaw(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        let pending: SerialSender.Pending? = lifecycle.withLock { lifecycle in
            guard !lifecycle.closed else { return nil }
            return operations.submit { [multiplexer, flowID] in
                try await multiplexer.sendData(data, flowID: flowID)
            }
        }
        guard let pending else { throw AnywhereError.proxy(.nowhere, .streamClosed) }
        try await pending.value()
    }

    func receiveRaw() async throws -> Data? {
        try await multiplexer.receiveData(flowID: flowID, inbox: inbox)
    }

    func cancel() {
        finish(reset: false)
    }

    func closeGracefully(
        onComplete: @escaping @Sendable () -> Void
    ) {
        finish(reset: false, onComplete: onComplete)
    }

    func abort() {
        finish(reset: true)
    }

    private func finish(
        reset: Bool,
        onComplete: (@Sendable () -> Void)? = nil
    ) {
        let submitted: SerialSender.Pending? = lifecycle.withLock { lifecycle in
            guard !lifecycle.closed else { return nil }
            lifecycle.closed = true
            multiplexer.prepareLocalClose(flowID: flowID, reset: reset)
            return operations.submit { [multiplexer, flowID] in
                await multiplexer.closeStream(flowID: flowID, reset: reset)
            }
        }
        guard let submitted else {
            onComplete?()
            return
        }
        termination.fire(AnywhereError.proxy(.nowhere, .streamClosed))
        let sender = operations
        Task {
            try? await submitted.value()
            onComplete?()
            sender.cancel()
        }
    }
}
