import Foundation

/// Parsed MCCS capabilities string, e.g. `(prot(monitor)type(lcd)vcp(10 12 60(0F 11) E0(04 05)))`.
public struct Capabilities {
    public let raw: String
    public let model: String?
    /// VCP code -> allowed values (empty when the code takes a continuous range).
    public let vcp: [UInt8: [UInt8]]

    public init(_ raw: String) {
        self.raw = raw
        model = Self.section("model", in: raw)
        vcp = Self.section("vcp", in: raw).map(Self.parseVCP) ?? [:]
    }

    private static func section(_ name: String, in s: String) -> String? {
        guard let start = s.range(of: name + "(", options: .caseInsensitive) else { return nil }
        var depth = 1
        var i = start.upperBound
        while i < s.endIndex {
            if s[i] == "(" { depth += 1 }
            if s[i] == ")" { depth -= 1; if depth == 0 { return String(s[start.upperBound..<i]) } }
            i = s.index(after: i)
        }
        return String(s[start.upperBound...])
    }

    private static func parseVCP(_ s: String) -> [UInt8: [UInt8]] {
        var out: [UInt8: [UInt8]] = [:]
        let scanner = Scanner(string: s)
        scanner.charactersToBeSkipped = .whitespacesAndNewlines
        while !scanner.isAtEnd {
            guard let tok = scanner.scanCharacters(from: .alphanumerics), let code = UInt8(tok, radix: 16) else {
                _ = scanner.scanCharacter(); continue
            }
            var values: [UInt8] = []
            if scanner.scanString("(") != nil {
                let inner = scanner.scanUpToString(")") ?? ""
                _ = scanner.scanString(")")
                values = inner.split(whereSeparator: \.isWhitespace).compactMap { UInt8($0, radix: 16) }
            }
            out[code] = values
        }
        return out
    }
}
