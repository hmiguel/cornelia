import Foundation

struct Channel: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let url: String
    let group: String
    let logo: String?
    let userAgent: String?
    let referrer: String?
    let searchKey: String
}

enum M3UParser {
    private static let hash = UInt8(ascii: "#"), quote = UInt8(ascii: "\""), comma = UInt8(ascii: ",")
    private static let eq = UInt8(ascii: "="), space = UInt8(ascii: " "), tab = UInt8(ascii: "\t")
    private static let nl = UInt8(ascii: "\n"), cr = UInt8(ascii: "\r")

    static func parse(_ text: String) -> [Channel] {
        var text = text
        return text.withUTF8 { parse(bytes: $0) }
    }

    static func parse(bytes buf: UnsafeBufferPointer<UInt8>) -> [Channel] {
        var result: [Channel] = []
        result.reserveCapacity(max(64, buf.count / 180))

        var name: String?
        var tvgName: String?
        var group: String?
        var logo: String?
        var extGroup: String?
        var userAgent: String?
        var referrer: String?

        let n = buf.count
        var i = 0
        while i < n {
            // Find line bounds, trimmed.
            var end = i
            while end < n && buf[end] != nl { end += 1 }
            let next = end + 1
            var a = i, b = end
            while a < b && (buf[a] == space || buf[a] == tab || buf[a] == cr || buf[a] == 0xEF || buf[a] == 0xBB || buf[a] == 0xBF) { a += 1 }
            while b > a && (buf[b - 1] == space || buf[b - 1] == tab || buf[b - 1] == cr) { b -= 1 }
            i = next
            if a >= b { continue }

            if buf[a] == hash {
                if hasPrefix(buf, a, b, "#EXTINF:") {
                    parseExtinf(buf, a + 8, b) { key, va, vb in
                        switch key {
                        case .groupTitle: group = str(buf, va, vb)
                        case .tvgLogo: logo = va < vb ? str(buf, va, vb) : nil
                        case .tvgName: tvgName = str(buf, va, vb)
                        case .userAgent: userAgent = str(buf, va, vb)
                        case .name: name = str(buf, va, vb)
                        }
                    }
                } else if hasPrefix(buf, a, b, "#EXTGRP:") {
                    extGroup = str(buf, a + 8, b).trimmingCharacters(in: .whitespaces)
                } else if hasPrefix(buf, a, b, "#EXTVLCOPT:") {
                    let opt = str(buf, a + 11, b)
                    if let e = opt.firstIndex(of: "=") {
                        let key = opt[..<e].lowercased()
                        let value = String(opt[opt.index(after: e)...])
                        if key == "http-user-agent" { userAgent = value }
                        if key == "http-referrer" || key == "http-referer" { referrer = value }
                    }
                }
                continue
            }

            let url = str(buf, a, b)
            let finalName = (name?.isEmpty == false ? name : nil) ?? (tvgName?.isEmpty == false ? tvgName : nil) ?? url
            var g = group ?? extGroup ?? ""
            if g.isEmpty { g = "Uncategorized" }
            result.append(Channel(
                id: result.count, name: finalName, url: url, group: g, logo: logo,
                userAgent: userAgent, referrer: referrer, searchKey: searchKey(finalName)
            ))
            name = nil; tvgName = nil; group = nil; logo = nil
            extGroup = nil; userAgent = nil; referrer = nil
        }
        return result
    }

    /// Lowercased, accent-free key. Fast path for ASCII.
    static func searchKey(_ s: String) -> String {
        var ascii = true
        for c in s.utf8 where c >= 0x80 { ascii = false; break }
        if ascii { return s.lowercased() }
        return s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Fast substring test on UTF-8 bytes.
    static func fastContains(_ hay: String, _ needle: String) -> Bool {
        var h = hay, nd = needle
        return h.withUTF8 { hb in nd.withUTF8 { nb in
            nb.isEmpty || (hb.count >= nb.count && memmem(hb.baseAddress, hb.count, nb.baseAddress, nb.count) != nil)
        } }
    }

    enum Key { case groupTitle, tvgLogo, tvgName, userAgent, name }

    @inline(__always)
    private static func str(_ buf: UnsafeBufferPointer<UInt8>, _ a: Int, _ b: Int) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: buf[a..<b]), as: UTF8.self)
    }

    @inline(__always)
    private static func hasPrefix(_ buf: UnsafeBufferPointer<UInt8>, _ a: Int, _ b: Int, _ p: StaticString) -> Bool {
        let len = p.utf8CodeUnitCount
        guard b - a >= len else { return false }
        let pp = p.utf8Start
        for k in 0..<len where buf[a + k] != pp[k] { return false }
        return true
    }

    private static func keyMatches(_ buf: UnsafeBufferPointer<UInt8>, _ a: Int, _ b: Int, _ p: StaticString) -> Bool {
        guard b - a == p.utf8CodeUnitCount else { return false }
        let pp = p.utf8Start
        for k in 0..<(b - a) {
            var c = buf[a + k]
            if c >= 65 && c <= 90 { c += 32 }
            if c != pp[k] { return false }
        }
        return true
    }

    /// Parses `-1 tvg-id="x" group-title="y",Channel Name` between a and b.
    private static func parseExtinf(_ buf: UnsafeBufferPointer<UInt8>, _ a: Int, _ b: Int,
                                    _ emit: (Key, Int, Int) -> Void) {
        // Find the first comma outside quotes.
        var inQuote = false
        var c = b
        var k = a
        while k < b {
            let ch = buf[k]
            if ch == quote { inQuote.toggle() } else if ch == comma && !inQuote { c = k; break }
            k += 1
        }
        if c < b {
            var na = c + 1, nb = b
            while na < nb && (buf[na] == space || buf[na] == tab) { na += 1 }
            while nb > na && (buf[nb - 1] == space || buf[nb - 1] == tab) { nb -= 1 }
            emit(.name, na, nb)
        }
        // Attributes in [a, c).
        var j = a
        while j < c {
            var e = j
            while e < c && buf[e] != eq { e += 1 }
            if e >= c { break }
            var ks = e
            while ks > j && buf[ks - 1] != space && buf[ks - 1] != tab { ks -= 1 }
            var vs = e + 1
            var ve: Int
            if vs < c && buf[vs] == quote {
                vs += 1
                ve = vs
                while ve < c && buf[ve] != quote { ve += 1 }
                j = min(c, ve + 1)
            } else {
                ve = vs
                while ve < c && buf[ve] != space && buf[ve] != tab { ve += 1 }
                j = ve
            }
            if keyMatches(buf, ks, e, "group-title") { emit(.groupTitle, vs, ve) }
            else if keyMatches(buf, ks, e, "tvg-logo") { emit(.tvgLogo, vs, ve) }
            else if keyMatches(buf, ks, e, "tvg-name") { emit(.tvgName, vs, ve) }
            else if keyMatches(buf, ks, e, "user-agent") { emit(.userAgent, vs, ve) }
        }
    }
}
