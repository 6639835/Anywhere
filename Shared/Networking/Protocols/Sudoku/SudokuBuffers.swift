//
//  SudokuBuffers.swift
//  Anywhere
//

import Foundation
import Synchronization

/// Buffers are writable only during initialization. Publishing a Data transfers
/// ownership until its last slice is released, including asynchronous sends.
nonisolated enum SudokuBufferPool {
    // Bounded globally, with no eager per-connection allocation.
    private static let sizes = [4_096, 16_384, 65_536, 131_072, 262_144, 524_288, 1_048_576]
    private struct State {
        var buckets = [[Storage]](repeating: [], count: sizes.count)
        var bytes = 0
    }
    private static let idle = Mutex(State())
    private static let maxIdlePerSize = 2
    private static let maxIdleBytes = 2 * 1024 * 1024

    // The pool lock transfers exclusive ownership. After publication only Data
    // reads the bytes; its deallocator returns storage after all readers finish.
    private final class Storage: @unchecked Sendable {
        let bytes: UnsafeMutableRawPointer
        let capacity: Int
        let bucket: Int?

        init(capacity: Int, bucket: Int?) {
            self.capacity = capacity
            self.bucket = bucket
            bytes = .allocate(byteCount: capacity, alignment: 16)
        }

        deinit { bytes.deallocate() }
    }

    static func makeData(capacity: Int, initialize: (UnsafeMutableRawBufferPointer) throws -> Int) rethrows -> Data {
        guard capacity > 0 else { return Data() }
        let bucket = sizes.firstIndex { $0 >= capacity }
        let storage = bucket.flatMap { index in
            idle.withLock { state -> Storage? in
                guard let storage = state.buckets[index].popLast() else { return nil }
                state.bytes -= storage.capacity
                return storage
            }
        } ?? Storage(capacity: bucket.map { sizes[$0] } ?? capacity, bucket: bucket)
        let count: Int
        do {
            count = try initialize(UnsafeMutableRawBufferPointer(start: storage.bytes, count: capacity))
        } catch {
            recycle(storage)
            throw error
        }
        precondition(count >= 0 && count <= capacity)
        guard count > 0 else {
            recycle(storage)
            return Data()
        }
        return Data(bytesNoCopy: storage.bytes, count: count, deallocator: .custom { _, _ in
            recycle(storage)
        })
    }

    private static func recycle(_ storage: Storage) {
        guard let bucket = storage.bucket else { return }
        idle.withLock { state in
            if state.buckets[bucket].count < maxIdlePerSize,
               state.bytes + storage.capacity <= maxIdleBytes {
                state.buckets[bucket].append(storage)
                state.bytes += storage.capacity
            }
        }
    }
}

/// Retains immutable chunks instead of copying payloads into a growing Data.
/// Consumed slots are cleared immediately; compaction moves only references.
nonisolated struct SudokuDataQueue {
    private var chunks: [Data] = []
    private var head = 0
    private var offset = 0
    private(set) var count = 0

    var isEmpty: Bool { count == 0 }

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        // Bound metadata for peers sending many tiny fragments. Large payloads
        // stay shared; only small tails are coalesced, up to one 4 KiB chunk.
        if data.count <= 1024, let last = chunks.indices.last,
           (last > head || offset == 0), chunks[last].count <= 4096 - data.count {
            chunks[last].append(data)
            count += data.count
            return
        }
        chunks.append(data)
        count += data.count
    }

    mutating func append(_ data: Data, from start: Int) {
        precondition(start >= 0 && start <= data.count)
        append(data.dropFirst(start))
    }

    /// May return fewer than max bytes at a chunk boundary, as a stream read may.
    mutating func read(max: Int) -> Data {
        guard max > 0, !isEmpty else { return Data() }
        let chunk = chunks[head]
        let n = min(max, chunk.count - offset)
        let start = chunk.startIndex + offset
        let result = chunk[start..<(start + n)]
        consume(n)
        return result
    }

    /// Used only when the caller needs a contiguous batch (e.g. one HTTP body).
    mutating func readCoalesced(max: Int) -> Data {
        let n = min(max, count)
        guard n > 0 else { return Data() }
        if n <= chunks[head].count - offset { return read(max: n) }
        return SudokuBufferPool.makeData(capacity: n) { drain(into: $0) }
    }

    mutating func drain(exact count: Int, into out: inout Data) {
        var remaining = min(count, self.count)
        while remaining > 0 {
            let chunk = read(max: remaining)
            out.append(chunk)
            remaining -= chunk.count
        }
    }

    mutating func drain(into output: UnsafeMutableRawBufferPointer) -> Int {
        var written = 0
        while written < output.count, !isEmpty {
            let n = min(output.count - written, chunks[head].count - offset)
            chunks[head].withUnsafeBytes { input in
                output.baseAddress!.advanced(by: written).copyMemory(
                    from: input.baseAddress!.advanced(by: offset), byteCount: n)
            }
            consume(n)
            written += n
        }
        return written
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        chunks.removeAll(keepingCapacity: keepingCapacity)
        head = 0
        offset = 0
        count = 0
    }

    private mutating func consume(_ n: Int) {
        count -= n
        offset += n
        if offset == chunks[head].count {
            chunks[head] = Data()
            head += 1
            offset = 0
            if head == chunks.count {
                removeAll(keepingCapacity: true)
            } else if head >= 64 && head >= chunks.count / 2 {
                chunks.removeFirst(head)
                head = 0
            }
        }
    }
}
