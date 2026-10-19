import Foundation

/// Async front end for a `DDCDisplay`. Every request runs on one serial queue, so reads and writes
/// never interleave on the I2C bus (DDCDisplay blocks with sleeps to honour the monitor's timing).
public final class MonitorController: @unchecked Sendable {
    private let display: DDCDisplay
    private let queue = DispatchQueue(label: "acer.ddc", qos: .userInitiated)

    public init(display: DDCDisplay) {
        self.display = display
    }

    /// The first external display that answers a capabilities request, with its parsed capabilities.
    /// If none answers (e.g. the bus is busy), falls back to `cachedCapabilities` on the first display.
    public static func connect(cachedCapabilities: String? = nil) async throws -> (MonitorController, Capabilities) {
        let displays = DDCDisplay.externalDisplays()
        for display in displays {
            let controller = MonitorController(display: display)
            if let raw = try? await controller.run({ try $0.capabilities() }) {
                return (controller, Capabilities(raw))
            }
        }
        if let cached = cachedCapabilities, let first = displays.first {
            return (MonitorController(display: first), Capabilities(cached))
        }
        throw DDCError.noExternalDisplay
    }

    private func run<T>(_ body: @escaping (DDCDisplay) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [display] in
                continuation.resume(with: Result { try body(display) })
            }
        }
    }

    /// Reads until two consecutive reads agree. With another app on the bus, a single read can
    /// return a garbled value that still passes the checksum (seen: 0xE2 = 0xE200), or an indexed
    /// read can hit the wrong register when the index select was dropped.
    public func read(_ feature: Feature) async throws -> VCPValue {
        try await run { display in
            func once() throws -> VCPValue {
                let value: VCPValue
                switch feature.access {
                case let .vcp(code): value = try display.get(code)
                case let .indexed(selector, index): value = try display.getIndexed(selector: selector, index: index)
                }
                return Self.lowByteIfOutOfRange(value)
            }
            var previous = try once()
            for _ in 0..<4 {
                let next = try once()
                if next.current == previous.current { return next }
                previous = next
            }
            throw DDCError.badReply("\(feature.name) never read the same value twice")
        }
    }

    /// Writes and reads back until the value sticks. Writes can be dropped like reads (seen: a
    /// display-mode write ignored on the first try), and a write gets no reply to check otherwise.
    public func write(_ feature: Feature, _ value: UInt16) async throws {
        try await run { display in
            switch feature.access {
            case let .vcp(code):
                var lastError: Error = DDCError.badReply("no attempts")
                for attempt in 0..<3 {
                    // A failed I2C write usually means the bus is busy (another app, or the monitor
                    // still switching); retrying at once fails the same way.
                    if attempt > 0 { Thread.sleep(forTimeInterval: Double(attempt)) }
                    do {
                        try display.set(code, to: value)
                    } catch {
                        lastError = error
                        continue
                    }
                    // A display-mode change keeps the monitor busy for longer than settleDelay. Poll the
                    // read-back rather than resending the write while the first one is still applying.
                    let deadline = Date().addingTimeInterval(Self.verifyTimeout)
                    repeat {
                        do {
                            let current = try Self.lowByteIfOutOfRange(display.get(code)).current
                            if current == value { return }
                            lastError = DDCError.badReply("\(feature.name): wrote \(value), monitor reports \(current)")
                        } catch {
                            lastError = error
                        }
                        Thread.sleep(forTimeInterval: 0.25)
                    } while Date() < deadline
                }
                throw lastError
            case let .indexed(selector, index):
                try display.setIndexed(selector: selector, index: index, to: value)
            }
        }
    }

    /// How long a write's read-back may take to show the new value.
    static let verifyTimeout: TimeInterval = 3

    /// XV275U P3 firmware sometimes puts the VCP code in the high byte (0xE2 reads 0xE200 for
    /// mode 0). A value above the reported maximum is never valid; keep the low byte.
    static func lowByteIfOutOfRange(_ value: VCPValue) -> VCPValue {
        guard value.maximum > 0, value.current > value.maximum else { return value }
        return VCPValue(code: value.code, current: value.current & 0xFF, maximum: value.maximum)
    }

    public func get(_ code: UInt8) async throws -> VCPValue {
        try await run { try $0.get(code) }
    }
}
