//
//  SpiderManTocTests.swift
//  WhiskyKit
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation
import XCTest
@testable import WhiskyKit

final class SpiderManTocTests: XCTestCase {
    private let arch: UInt32 = 0x398abff0
    private let sizes: UInt32 = 0x65bcf461
    private let offs: UInt32 = 0xdcd720b5
    private let ids: UInt32 = 0x506d7b8a

    private func le(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// Builds a DAT1 raw buffer with the archive list placed last so the other sections keep their offsets.
    private func makeRaw(archives: Int, entries: [(arch: UInt32, off: UInt32)], extra: Data) -> Data {
        var archData = Data()
        for index in 0..<archives {
            archData.append(Data(repeating: UInt8(index + 1), count: 72))
        }
        var idsData = Data()
        var offsData = Data()
        var sizesData = Data()
        for (index, entry) in entries.enumerated() {
            idsData.append(le(UInt32(index)) + le(0))
            offsData.append(le(entry.arch) + le(entry.off))
            sizesData.append(le(entry.off) + le(entry.off) + le(entry.off))
        }
        let bodies: [(UInt32, Data)] = [(ids, idsData), (offs, offsData), (sizes, sizesData), (0x1234, extra), (arch, archData)]
        var raw = Data(repeating: 0, count: 12)
        raw.append(le(UInt32(bodies.count)))
        var offset = UInt32(16 + 12 * bodies.count)
        for (tag, body) in bodies {
            raw.append(le(tag) + le(offset) + le(UInt32(body.count)))
            offset += UInt32(body.count)
        }
        for (_, body) in bodies { raw.append(body) }
        return raw
    }

    private func makeToc(archives: Int, entries: [(arch: UInt32, off: UInt32)], extra: Data) throws -> Data {
        try SpiderManToc.encode(makeRaw(archives: archives, entries: entries, extra: extra))
    }

    private func readEntries(_ toc: Data) throws -> [(UInt32, UInt32)] {
        let raw = try SpiderManToc.decode(toc)
        let count = Int(raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) })
        var offsetsStart = 0
        var entryCount = 0
        for index in 0..<count {
            let base = 16 + 12 * index
            let tag = raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: base, as: UInt32.self) }
            let off = Int(raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: base + 4, as: UInt32.self) })
            let size = Int(raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: base + 8, as: UInt32.self) })
            if tag == offs { offsetsStart = off; entryCount = size / 8 }
        }
        return (0..<entryCount).map { idx in
            let pos = offsetsStart + idx * 8
            return (
                raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos, as: UInt32.self) },
                raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos + 4, as: UInt32.self) }
            )
        }
    }

    private func archiveCount(_ toc: Data) throws -> Int {
        let raw = try SpiderManToc.decode(toc)
        let count = Int(raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) })
        for index in 0..<count {
            let base = 16 + 12 * index
            let tag = raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: base, as: UInt32.self) }
            if tag == arch {
                return Int(raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: base + 8, as: UInt32.self) }) / 72
            }
        }
        return 0
    }

    func testRoundTrip() throws {
        let raw = makeRaw(archives: 2, entries: [(0, 10), (1, 20)], extra: Data([1, 2, 3]))
        XCTAssertEqual(try SpiderManToc.decode(SpiderManToc.encode(raw)), raw)
    }

    func testMergeTakesOnlyNewArchiveEntries() throws {
        let original = try makeToc(archives: 2, entries: [(0, 10), (1, 20), (1, 30)], extra: Data([9]))
        let patched = try makeToc(archives: 3, entries: [(0, 99), (2, 0), (1, 77)], extra: Data([9]))
        let result = try SpiderManToc.merge(original: original, patched: patched)
        XCTAssertEqual(result.redirected, 1)
        XCTAssertEqual(try archiveCount(result.toc), 3)
        let entries = try readEntries(result.toc)
        XCTAssertEqual(entries.map(\.0), [0, 2, 1])
        XCTAssertEqual(entries.map(\.1), [10, 0, 30])
    }

    func testMergeRejectsChangedLayout() throws {
        let original = try makeToc(archives: 2, entries: [(0, 10)], extra: Data([9]))
        let patched = try makeToc(archives: 3, entries: [(0, 10)], extra: Data([8]))
        XCTAssertThrowsError(try SpiderManToc.merge(original: original, patched: patched)) { error in
            guard case SpiderManToc.MergeError.layoutMismatch = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testMergeRejectsBadMagic() {
        XCTAssertThrowsError(try SpiderManToc.merge(original: Data([0, 1, 2, 3, 4, 5, 6, 7, 8]), patched: Data())) { error in
            XCTAssertEqual(error as? SpiderManToc.MergeError, .badMagic)
        }
    }
}
