//
//  ProxyClient+Sudoku.swift
//  Anywhere
//
//  Created by saba-futai on 4/23/26.
//

import Foundation

extension ProxyClient {
    func connectWithSudoku(_ request: ProxyRequest) async throws -> ProxyConnection {
        guard case .sudoku(let sudoku) = configuration.outbound else {
            throw AnywhereError.proxy(.sudoku, .protocolViolation(detail: "missing Sudoku protocol settings"))
        }

        let destinationHost = request.host
        let destinationPort = request.port
        let initialData = request.initialData

        if request.network == .tcp, sudoku.multiplex == .on, tunnel == nil {
            return try await connectWithPooledSudokuMux(
                destinationHost: destinationHost,
                destinationPort: destinationPort,
                initialData: initialData
            )
        }

        let configuration = configuration
        let factory = SudokuConnectionFactory(
            configuration: configuration,
            initialTunnel: tunnel,
            directDialHost: directDialHost
        )

        do {
            let client = try SudokuNativeClient(configuration: configuration, factory: factory)
            let connection: ProxyConnection
            switch request.network {
            case .tcp where client.shouldUseNativeMux:
                let multiplexer = try await client.openMux()
                let stream = try await multiplexer.dialTCP(host: destinationHost, port: destinationPort)
                try await ProxyClient.sendSudokuInitialData(initialData, to: stream)
                connection = SudokuMuxTCPProxyConnection(client: multiplexer, stream: stream)
            case .tcp:
                let stream = try await client.openTCP(host: destinationHost, port: destinationPort)
                try await stream.sendInitialDataIfNeeded(initialData)
                connection = SudokuTCPProxyConnection(stream: stream)
            case .udp:
                let stream = try await client.openUoT()
                connection = SudokuUDPProxyConnection(
                    stream: stream,
                    destinationHost: destinationHost,
                    destinationPort: destinationPort
                )
            }
            return connection
        } catch {
            factory.closeAll()
            throw error
        }
    }

    /// The pooled session outlives this ProxyClient, so nothing here is `own`ed; closing
    /// the connection only closes its stream and re-arms the pool's idle clock.
    private func connectWithPooledSudokuMux(
        destinationHost: String,
        destinationPort: UInt16,
        initialData: Data?
    ) async throws -> ProxyConnection {
        guard let pool = SudokuMultiplexerRegistry.shared.pool(
            for: configuration,
            directDialHost: directDialHost
        ) else {
            throw AnywhereError.proxy(.sudoku, .notReady)
        }

        let (multiplexer, stream) = try await pool.dialTCP(host: destinationHost, port: destinationPort)
        do {
            try await ProxyClient.sendSudokuInitialData(initialData, to: stream)
        } catch {
            stream.close()
            throw error
        }
        return SudokuMuxTCPProxyConnection(
            client: multiplexer,
            stream: stream,
            closesClientOnClose: false,
            onClose: { pool.noteStreamEnded(multiplexer) }
        )
    }

    private static func sendSudokuInitialData(_ data: Data?, to stream: SudokuMuxStream) async throws {
        guard let data, !data.isEmpty else { return }
        try await stream.send(data)
    }
}

private extension SudokuRecordStream {
    func sendInitialDataIfNeeded(_ data: Data?) async throws {
        guard let data, !data.isEmpty else { return }
        try await send(data)
    }
}
