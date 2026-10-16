//
//  SpiderManToc.swift
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
import zlib

/// Rebuilds Marvel's Spider-Man Remastered `asset_archive/toc` after a Turkish patch installer overwrote it
/// with an outdated copy: keeps the current game's toc and takes only the records the patch redirects
/// into its newly added archive.
public enum SpiderManToc {
    public enum MergeError: Error, Equatable {
        case badMagic
        case corrupt
        case layoutMismatch(String)
    }

    private static let magic: [UInt8] = [0xAF, 0x12, 0xAF, 0x77]
    private static let archTag: UInt32 = 0x398abff0
    private static let sizesTag: UInt32 = 0x65bcf461
    private static let offsTag: UInt32 = 0xdcd720b5
    private static let idsTag: UInt32 = 0x506d7b8a
    private static let archiveRecord = 72

    private struct Section: Equatable {
        let offset: Int
        let size: Int
    }

    /// original = Kadeh's pre-install backup, patched = what the installer wrote.
    public static func merge(original: Data, patched: Data) throws -> (toc: Data, redirected: Int) {
        let orig = try decode(original)
        let yama = try decode(patched)
        let so = try sections(orig)
        let sy = try sections(yama)

        for (tag, secO) in so {
            let hex = String(tag, radix: 16)
            guard let secY = sy[tag] else { throw MergeError.layoutMismatch(hex) }
            if tag != archTag && tag != sizesTag && tag != offsTag {
                guard let a = slice(orig, secO), let b = slice(yama, secY) else { throw MergeError.corrupt }
                guard a == b else { throw MergeError.layoutMismatch(hex) }
            }
            if tag != archTag, secO != secY { throw MergeError.layoutMismatch(hex) }
        }
        guard let archO = so[archTag], let archY = sy[archTag],
              let oa = slice(orig, archO), let ya = slice(yama, archY),
              let idsSec = so[idsTag], let offsSec = so[offsTag], let sizesSec = so[sizesTag]
        else { throw MergeError.layoutMismatch(String(archTag, radix: 16)) }
        guard ya.count >= oa.count, ya.prefix(oa.count) == oa else {
            throw MergeError.layoutMismatch(String(archTag, radix: 16))
        }

        let newIndex = oa.count / archiveRecord
        let count = idsSec.size / 8
        guard offsSec.offset + count * 8 <= min(orig.count, yama.count),
              sizesSec.offset + count * 12 <= min(orig.count, yama.count)
        else { throw MergeError.corrupt }

        var out = yama
        var kept = 0
        for index in 0..<count {
            let offPos = offsSec.offset + index * 8
            if readU32(yama, offPos) >= UInt32(newIndex) {
                kept += 1
                continue
            }
            out.replaceSubrange(offPos..<offPos + 8, with: orig[offPos..<offPos + 8])
            let sizePos = sizesSec.offset + index * 12
            out.replaceSubrange(sizePos..<sizePos + 12, with: orig[sizePos..<sizePos + 12])
        }
        return (try encode(out), kept)
    }

    static func decode(_ toc: Data) throws -> Data {
        let bytes = [UInt8](toc)
        guard bytes.count >= 4, Array(bytes[0..<4]) == magic else { throw MergeError.badMagic }
        guard bytes.count > 8 else { throw MergeError.corrupt }
        let rawSize = Int(readU32(toc, 4))
        guard rawSize > 0, rawSize < 1 << 30 else { throw MergeError.corrupt }
        var dest = [UInt8](repeating: 0, count: rawSize)
        var destLen = uLongf(rawSize)
        let status = bytes.withUnsafeBufferPointer { src in
            dest.withUnsafeMutableBufferPointer { dst in
                uncompress(dst.baseAddress, &destLen, src.baseAddress! + 8, uLong(bytes.count - 8))
            }
        }
        guard status == Z_OK, Int(destLen) == rawSize else { throw MergeError.corrupt }
        return Data(dest)
    }

    static func encode(_ raw: Data) throws -> Data {
        let src = [UInt8](raw)
        var destLen = compressBound(uLong(src.count))
        var dest = [UInt8](repeating: 0, count: Int(destLen))
        let status = src.withUnsafeBufferPointer { s in
            dest.withUnsafeMutableBufferPointer { d in
                compress2(d.baseAddress, &destLen, s.baseAddress, uLong(src.count), 9)
            }
        }
        guard status == Z_OK else { throw MergeError.corrupt }
        var out = Data(magic)
        withUnsafeBytes(of: UInt32(src.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(contentsOf: dest[0..<Int(destLen)])
        return out
    }

    // MARK: - Helpers

    private static func readU32(_ data: Data, _ pos: Int) -> UInt32 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos, as: UInt32.self) }.littleEndian
    }

    private static func sections(_ buf: Data) throws -> [UInt32: Section] {
        guard buf.count >= 16 else { throw MergeError.corrupt }
        let count = Int(readU32(buf, 12))
        guard count >= 0, 16 + 12 * count <= buf.count else { throw MergeError.corrupt }
        var result: [UInt32: Section] = [:]
        for index in 0..<count {
            let base = 16 + 12 * index
            result[readU32(buf, base)] = Section(offset: Int(readU32(buf, base + 4)), size: Int(readU32(buf, base + 8)))
        }
        return result
    }

    private static func slice(_ buf: Data, _ section: Section) -> Data? {
        guard section.offset >= 0, section.size >= 0, section.offset + section.size <= buf.count else { return nil }
        return buf.subdata(in: section.offset..<section.offset + section.size)
    }
}
