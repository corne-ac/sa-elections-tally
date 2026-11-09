import Foundation

/// Shrinks IEC municipality files before JSON decoding.
///
/// Every ward and voting district in `EEID…Munic{id}.js` lists **all** parties on the municipal
/// ballot, mostly with zero votes. Johannesburg's file is 17.5 MB, and about 85% of it is zero-vote rows.
/// This single pass over the raw bytes drops flat party objects whose `"TotalValidVotes"` is 0, so the
/// decoder only sees what matters: decoding peak memory drops from ~110 MB to ~30 MB and time
/// from ~150 ms to ~40 ms for Johannesburg.
///
/// Failsafe: it only removes objects that start with `{"ID":`, contain no nested object or array,
/// and carry `"TotalValidVotes":0` as a whole value. If the IEC ever reformats the file (whitespace,
/// key order), nothing matches and the original bytes decode exactly as before.
enum ZeroVoteFilter {
    private static let objectStart = Array(#"{"ID":"#.utf8)
    private static let zeroVotes = Array(#""TotalValidVotes":0"#.utf8)

    static func strip(_ input: Data) -> Data {
        var out = Data()
        out.reserveCapacity(input.count / 4)
        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = raw.count
            var i = 0
            var copyFrom = 0

            func matches(_ pattern: [UInt8], at index: Int) -> Bool {
                guard index + pattern.count <= n else { return false }
                for k in 0..<pattern.count where base[index + k] != pattern[k] { return false }
                return true
            }

            while i < n {
                guard base[i] == UInt8(ascii: "{"), matches(objectStart, at: i) else { i += 1; continue }

                // Find the end of this object, honouring strings; give up on anything nested.
                var j = i + 1
                var inString = false
                var flat = true
                var hasZero = false
                while j < n {
                    let c = base[j]
                    if inString {
                        if c == UInt8(ascii: "\\") { j += 2; continue }
                        if c == UInt8(ascii: "\"") { inString = false }
                    } else if c == UInt8(ascii: "\"") {
                        if !hasZero, matches(zeroVotes, at: j) {
                            let after = j + zeroVotes.count
                            if after < n, base[after] == UInt8(ascii: ",") || base[after] == UInt8(ascii: "}") { hasZero = true }
                        }
                        inString = true
                    } else if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") {
                        flat = false
                        break
                    } else if c == UInt8(ascii: "}") {
                        break
                    }
                    j += 1
                }

                guard flat, j < n, hasZero else { i += 1; continue }

                // Drop object i...j and exactly one neighbouring comma.
                out.append(base + copyFrom, count: i - copyFrom)
                var next = j + 1
                if next < n, base[next] == UInt8(ascii: ",") {
                    next += 1
                } else if out.last == UInt8(ascii: ",") {
                    out.removeLast()             // it was the last element: remove the comma before it
                }
                copyFrom = next
                i = next
            }
            if copyFrom < n { out.append(base + copyFrom, count: n - copyFrom) }
        }
        return out
    }
}
