import Foundation

/// Minimal MP4 box layouts for take files: `RecordingTempStore.isPlayable`
/// reads only the top-level box headers, so no real media is needed.
enum MP4Fixture {
    /// `ftyp`, `moov`, `mdat` — the shape a finished `AVAssetWriter` take has.
    static let playable = box("ftyp", payload: Data("mp42isom".utf8)) + box("moov") + box("mdat", payload: Data(count: 32))

    /// `ftyp` then a `mdat` still being written (size 0 = to the end of the
    /// file) — a take cut off mid-recording: no `moov`.
    static let unfinished = box("ftyp", payload: Data("mp42isom".utf8)) + header(size: 0, "mdat") + Data(count: 32)

    /// `moov` after a `mdat` with a 64-bit size.
    static let playableAfterLargeBox: Data = {
        let payload = Data(count: 24)
        var large = header(size: 1, "mdat")
        large.append(contentsOf: bigEndian(UInt64(16 + payload.count)))
        return box("ftyp") + large + payload + box("moov")
    }()

    /// A box whose size claims more bytes than the file has, then nothing.
    static let truncated = box("ftyp") + header(size: 4096, "mdat") + Data(count: 16)

    /// Malformed or cut-off `moov` boxes after an `ftyp` — none is playable.
    static let brokenMovies: [Data] = {
        var oversized = header(size: 1, "moov")
        oversized.append(contentsOf: bigEndian(UInt64.max))
        return [
            header(size: 4096, "moov"), // header only, payload missing
            header(size: 1, "moov"), // 64-bit size field missing
            header(size: 1, "moov") + Data(bigEndian(UInt32(0))), // 64-bit size field cut short
            header(size: 4, "moov") + Data(count: 16), // shorter than its own header
            oversized + Data(count: 16), // extended size past the end of the file
            header(size: 32, "moov") + Data(count: 8), // payload cut short
        ].map { box("ftyp", payload: Data("mp42isom".utf8)) + $0 }
    }()

    /// An optimized take's layout with a real-sized movie header: `ftyp`, a
    /// 764-byte `moov`, then `mdat`.
    static let playableWithMovie = box("ftyp", payload: Data("mp42isom".utf8))
        + box("moov", payload: Data(count: 756)) + box("mdat", payload: Data(count: 32))

    /// `playableWithMovie` cut off right after the `moov` header.
    static let truncatedAfterMovieHeader = playableWithMovie.prefix(16 + 8)

    static func box(_ type: String, payload: Data = Data()) -> Data {
        header(size: UInt32(8 + payload.count), type) + payload
    }

    static func header(size: UInt32, _ type: String) -> Data {
        Data(bigEndian(size)) + Data(type.utf8)
    }

    private static func bigEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }
}
