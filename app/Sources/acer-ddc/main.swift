import DDCKit
import Foundation

func usage() -> Never {
    print("""
    usage: acer-ddc [--display N] <command>
      list                 list external DDC displays
      caps                 read and parse the capabilities string (read-only)
      get <vcp>            read a VCP code, e.g. get 0x10 (read-only)
      set <vcp> <value>    write a VCP code (changes the monitor)
      iget <sel> <index>   read an Acer indexed register, e.g. iget 0xE0 4 (Overdrive)
      iset <sel> <index> <value>  write an Acer indexed register (changes the monitor)
      scan                 read every plain VCP code 3x, print the majority value (read-only)
      dump                 read every VCP code and Acer indexed register (read-only; selects indexes)
    """)
    exit(2)
}

func parseByte(_ s: String) -> UInt8? { s.hasPrefix("0x") ? UInt8(s.dropFirst(2), radix: 16) : UInt8(s) }

var args = Array(CommandLine.arguments.dropFirst())
var index = 0
if let i = args.firstIndex(of: "--display"), i + 1 < args.count, let n = Int(args[i + 1]) {
    index = n
    args.removeSubrange(i...i + 1)
}
guard let command = args.first else { usage() }

let displays = DDCDisplay.externalDisplays()
if command == "list" {
    print("\(displays.count) external DDC display(s)")
    exit(0)
}
guard displays.indices.contains(index) else { fputs("No external display at index \(index)\n", stderr); exit(1) }
let display = displays[index]

do {
    switch command {
    case "caps":
        let caps = Capabilities(try display.capabilities())
        print("raw: \(caps.raw)\n")
        print("model: \(caps.model ?? "?")")
        for code in caps.vcp.keys.sorted() {
            let values = caps.vcp[code]!.map { String(format: "%02X", $0) }.joined(separator: " ")
            print(String(format: "  VCP %02X", code) + (values.isEmpty ? "" : "  [\(values)]"))
        }
    case "get":
        guard args.count == 2, let code = parseByte(args[1]) else { usage() }
        print(try display.get(code))
    case "set":
        guard args.count == 3, let code = parseByte(args[1]), let value = UInt16(args[2]) else { usage() }
        try display.set(code, to: value)
        print("ok")
    case "scan":
        for code in UInt8(0x01)...UInt8(0xFF) where ![0x04, 0x05, 0x06, 0x08, 0xE0, 0xE7, 0xEB, 0xED].contains(code) {
            let reads = (0..<3).compactMap { _ in try? display.get(code).current }
            guard reads.count >= 2 else { continue }
            let majority = Dictionary(grouping: reads, by: { $0 }).max { $0.value.count < $1.value.count }!.key
            print(String(format: "%02X ", code) + "\(majority)")
        }
    case "dump":
        // Diff two dumps taken before/after changing a setting in the monitor's OSD to find its code.
        func agreed(_ read: () throws -> VCPValue) -> String? {
            guard let a = try? read(), let b = try? read() else { return nil }
            return a.current == b.current ? "\(a.current)/\(a.maximum)" : "\(a.current)|\(b.current)/\(a.maximum)"
        }
        for code in UInt8(0x01)...UInt8(0xFF) where code != 0x04 && code != 0x05 && code != 0x06 && code != 0x08 {
            if let v = agreed({ try display.get(code) }) { print(String(format: "%02X ", code) + v) }
        }
        for selector: UInt8 in [0xE0, 0xE7, 0xEB, 0xED] {
            for index in UInt8(0)...UInt8(15) {
                if let v = agreed({ try display.getIndexed(selector: selector, index: index) }) {
                    print(String(format: "%02X[%02d] ", selector, index) + v)
                }
            }
        }
    case "iget":
        guard args.count == 3, let sel = parseByte(args[1]), let idx = parseByte(args[2]) else { usage() }
        print("[\(args[1]) idx \(idx)] " + String(describing: try display.getIndexed(selector: sel, index: idx)))
    case "iset":
        guard args.count == 4, let sel = parseByte(args[1]), let idx = parseByte(args[2]), let value = UInt16(args[3]) else { usage() }
        try display.setIndexed(selector: sel, index: idx, to: value)
        print("ok")
    default:
        usage()
    }
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
