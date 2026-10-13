import CIOAVService
import Foundation
import IOKit

public enum DDCError: Error, CustomStringConvertible {
    case noExternalDisplay
    case serviceCreationFailed
    case io(IOReturn, String)
    case badReply(String)

    public var description: String {
        switch self {
        case .noExternalDisplay: return "No external display with DDC found"
        case .serviceCreationFailed: return "IOAVServiceCreateWithService failed"
        case let .io(code, op): return "\(op) failed: IOReturn 0x\(String(UInt32(bitPattern: code), radix: 16))"
        case let .badReply(why): return "Bad DDC reply: \(why)"
        }
    }
}

public struct VCPValue: CustomStringConvertible {
    public let code: UInt8
    public let current: UInt16
    public let maximum: UInt16
    public init(code: UInt8, current: UInt16, maximum: UInt16) {
        self.code = code
        self.current = current
        self.maximum = maximum
    }

    public var description: String { "VCP 0x\(String(format: "%02X", code)) = \(current) (max \(maximum))" }
}

/// DDC/CI over the Apple Silicon IOAVService I2C bridge. Not thread-safe; MonitorController
/// confines each instance to one serial queue.
public final class DDCDisplay: @unchecked Sendable {
    private static let chipAddress: UInt32 = 0x37  // DDC/CI 7-bit address
    private static let dataAddress: UInt32 = 0x51  // host source address
    private static let destWrite: UInt8 = 0x6E      // 0x37 << 1
    private static let replyHost: UInt8 = 0x50      // used in reply checksums

    private let service: IOAVService
    /// Wait between write and read; DDC/CI requires 40–50 ms.
    public var replyDelay: TimeInterval = 0.05
    public var retries = 6
    /// Pause after a Set VCP that changes a setting. Measured on XV275U P3: requests within
    /// ~0.5 s get a null reply or a garbage value.
    public var settleDelay: TimeInterval = 0.5
    /// Pause between selecting an Acer register index and reading/writing its value.
    public var selectDelay: TimeInterval = 0.3

    init(service: IOAVService) {
        self.service = service
        // Timing experiments without rebuilding.
        if let v = ProcessInfo.processInfo.environment["DDC_SELECT_DELAY"].flatMap(Double.init) { selectDelay = v }
    }

    /// All external displays that expose a DDC service, in IORegistry order.
    public static func externalDisplays() -> [DDCDisplay] {
        var result: [DDCDisplay] = []
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else {
            return result
        }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External", let svc = IOAVServiceCreateWithService(kCFAllocatorDefault, entry) else { continue }
            result.append(DDCDisplay(service: svc))
        }
        return result
    }

    // MARK: - Low level

    private func write(_ payload: [UInt8]) throws {
        var packet = [UInt8(0x80 | payload.count)] + payload
        packet.append(packet.reduce(Self.destWrite ^ UInt8(Self.dataAddress), ^))
        let rc = packet.withUnsafeMutableBytes {
            IOAVServiceWriteI2C(service, Self.chipAddress, Self.dataAddress, $0.baseAddress!, UInt32($0.count))
        }
        guard rc == kIOReturnSuccess else { throw DDCError.io(rc, "WriteI2C") }
    }

    private func read(count: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: count)
        let rc = buf.withUnsafeMutableBytes {
            IOAVServiceReadI2C(service, Self.chipAddress, 0, $0.baseAddress!, UInt32($0.count))
        }
        guard rc == kIOReturnSuccess else { throw DDCError.io(rc, "ReadI2C") }
        if ProcessInfo.processInfo.environment["DDC_DEBUG"] != nil { FileHandle.standardError.write("read: \(hex(buf))\n".data(using: .utf8)!) }
        return buf
    }

    /// Validates the reply framing and checksum; returns the message body (after the length byte).
    private func body(of reply: [UInt8]) throws -> [UInt8] {
        guard reply.count >= 3, reply[0] == Self.destWrite, reply[1] & 0x80 != 0 else {
            throw DDCError.badReply("header \(hex(Array(reply.prefix(3))))")
        }
        let length = Int(reply[1] & 0x7F)
        // Null message (6E 80 BE): the monitor is busy or missed the request. Thrown so transact retries.
        guard length > 0 else { throw DDCError.badReply("null message (monitor busy)") }
        guard reply.count >= 2 + length + 1 else { throw DDCError.badReply("truncated") }
        let checksum = reply[0..<(2 + length)].reduce(Self.replyHost, ^)
        guard checksum == reply[2 + length] else { throw DDCError.badReply("checksum") }
        return Array(reply[2..<(2 + length)])
    }

    /// Sends `payload` and returns the reply body. Replies that fail `matches` are retried: other
    /// apps (e.g. BetterDisplay) share the bus, so a read can return the answer to their request.
    private func transact(_ payload: [UInt8], replyLength: Int, attempts: Int? = nil,
                          matches: ([UInt8]) -> Bool) throws -> [UInt8] {
        var lastError: Error = DDCError.badReply("no attempts")
        for attempt in 0..<(attempts ?? retries) {
            do {
                // Like MonitorControl: send the request twice; some monitors drop the first one.
                try write(payload)
                Thread.sleep(forTimeInterval: 0.01)
                try write(payload)
                Thread.sleep(forTimeInterval: replyDelay)
                let reply = try body(of: read(count: replyLength))
                guard matches(reply) else { throw DDCError.badReply("unexpected reply \(hex(reply))") }
                return reply
            } catch {
                // A null message means the monitor is still busy (e.g. ~0.5 s after a Set), so back off.
                lastError = error
                Thread.sleep(forTimeInterval: replyDelay * Double(1 << min(attempt, 3)))
            }
        }
        throw lastError
    }

    // MARK: - MCCS commands

    /// Get VCP Feature (0x01). Read-only.
    public func get(_ code: UInt8) throws -> VCPValue {
        let b = try transact([0x01, code], replyLength: 11) { $0.count >= 8 && $0[0] == 0x02 && $0[2] == code }
        guard b[1] == 0x00 else { throw DDCError.badReply("VCP 0x\(String(format: "%02X", code)) unsupported") }
        return VCPValue(code: code, current: UInt16(b[6]) << 8 | UInt16(b[7]), maximum: UInt16(b[4]) << 8 | UInt16(b[5]))
    }

    /// Set VCP Feature (0x03). Changes monitor state.
    public func set(_ code: UInt8, to value: UInt16) throws {
        try set(code, to: value, settle: settleDelay)
    }

    private func set(_ code: UInt8, to value: UInt16, settle: TimeInterval) throws {
        // Sent twice for the same reason as reads (see transact).
        let payload: [UInt8] = [0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        try write(payload)
        Thread.sleep(forTimeInterval: 0.01)
        try write(payload)
        // The monitor ignores requests while it applies a change; give it time before the next command.
        Thread.sleep(forTimeInterval: settle)
    }

    /// Acer indexed register: write `index` to the selector code (E0/E7/EB/ED), then read the value
    /// code that follows it (E1/E8/EC/EE). Selecting an index doesn't change any visible setting.
    public func getIndexed(selector: UInt8, index: UInt8) throws -> VCPValue {
        // Selecting an index changes nothing visible, so the monitor isn't busy afterwards.
        // If the read fails, the select may have been dropped, so redo both.
        var lastError: Error = DDCError.badReply("no attempts")
        for _ in 0..<3 {
            do {
                try set(selector, to: UInt16(index), settle: selectDelay)
                return try get(selector + 1)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Acer indexed register write: select `index`, then write `value` to the value code, then read it
    /// back. A dropped select would send the value to the previously selected setting (seen: a write
    /// meant for E0[7] changed the aim point at E0[6]), so the read beforehand wakes the bus, the
    /// select is sent twice, and the result is verified.
    public func setIndexed(selector: UInt8, index: UInt8, to value: UInt16) throws {
        var lastError: Error = DDCError.badReply("no attempts")
        for _ in 0..<3 {
            do {
                _ = try? get(selector + 1)
                try set(selector, to: UInt16(index), settle: selectDelay)
                try set(selector, to: UInt16(index), settle: selectDelay)
                try set(selector + 1, to: value)
                let readBack = try getIndexed(selector: selector, index: index)
                guard readBack.current == value else {
                    throw DDCError.badReply("wrote \(value) to \(String(format: "%02X", selector))[\(index)], read back \(readBack.current)")
                }
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Capabilities Request (0xF3), reassembled from 32-byte fragments. Read-only.
    public func capabilities() throws -> String {
        var data: [UInt8] = []
        var offset = 0
        while offset < 4096 {
            // Capabilities are read once and cached by the app, so be patient with a noisy bus.
            let b = try transact([0xF3, UInt8(offset >> 8), UInt8(offset & 0xFF)], replyLength: 38, attempts: 12) {
                $0.count >= 3 && $0[0] == 0xE3 && Int($0[1]) << 8 | Int($0[2]) == offset
            }
            let fragment = b.dropFirst(3)
            if fragment.isEmpty { break }
            data += fragment
            offset += fragment.count
            Thread.sleep(forTimeInterval: replyDelay)
        }
        return String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
    }
}

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
