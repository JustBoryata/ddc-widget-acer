import Foundation

/// How a feature is addressed on the monitor.
public enum FeatureAccess: Hashable {
    /// A plain MCCS VCP code.
    case vcp(UInt8)
    /// Acer indexed register: write `index` to `selector`, then use `selector + 1` for the value.
    case indexed(selector: UInt8, index: UInt8)
}

public struct FeatureOption: Hashable, Identifiable {
    public let value: UInt16
    public let name: String
    public var id: UInt16 { value }

    public init(_ value: UInt16, _ name: String) {
        self.value = value
        self.name = name
    }
}

public enum FeatureKind {
    /// Continuous value from 0 to the maximum the monitor reports.
    case range
    case options([FeatureOption])
    case toggle
}

public enum FeatureSection: String, CaseIterable {
    case picture = "Picture"
    case color = "Color"
    case gaming = "Gaming"
    case system = "System"
}

public struct Feature: Identifiable {
    public let id: String
    public let name: String
    public let section: FeatureSection
    public let access: FeatureAccess
    public let kind: FeatureKind

    public init(id: String, name: String, section: FeatureSection, access: FeatureAccess, kind: FeatureKind) {
        self.id = id
        self.name = name
        self.section = section
        self.access = access
        self.kind = kind
    }

    /// Whether the monitor's capabilities string lists this feature.
    public func isSupported(by caps: Capabilities) -> Bool {
        switch access {
        case let .vcp(code):
            // Display mode (E2) isn't listed in XV275U P3 capabilities but works; E3 is its support list.
            if code == 0xE2 { return caps.vcp[0xE2] != nil || caps.vcp[0xE3] != nil }
            return caps.vcp[code] != nil
        case let .indexed(selector, index):
            return caps.vcp[selector]?.contains(index) ?? false
        }
    }
}

/// Feature table from Acer Display Widget 1.0.2.0 (see analysis/vcp-map.md).
public enum AcerFeatures {
    public static let brightness = Feature(id: "brightness", name: "Brightness", section: .picture, access: .vcp(0x10), kind: .range)
    public static let contrast = Feature(id: "contrast", name: "Contrast", section: .picture, access: .vcp(0x12), kind: .range)
    public static let blackBoost = Feature(id: "blackBoost", name: "Black Boost", section: .picture, access: .vcp(0xE5), kind: .range)
    public static let displayMode = Feature(id: "displayMode", name: "Mode", section: .picture, access: .vcp(0xE2), kind: .options(displayModes))
    public static let input = Feature(id: "input", name: "Input", section: .system, access: .vcp(0x60), kind: .options(inputs))
    public static let volume = Feature(id: "volume", name: "Volume", section: .system, access: .vcp(0x62), kind: .range)
    public static let keyLock = Feature(id: "keyLock", name: "Lock monitor buttons", section: .system,
                                        access: .indexed(selector: 0xE0, index: 0), kind: .toggle)
    public static let overdrive = Feature(id: "overdrive", name: "Overdrive", section: .gaming,
                                          access: .indexed(selector: 0xE0, index: 4),
                                          kind: .options([.init(0, "Off"), .init(1, "Normal"), .init(2, "Extreme")]))
    public static let blueLight = Feature(id: "blueLight", name: "Blue Light", section: .color,
                                          access: .indexed(selector: 0xE7, index: 0),
                                          kind: .options([.init(0, "Off"), .init(1, "80%"), .init(2, "70%"), .init(3, "60%"), .init(4, "50%")]))
    public static let gamma = Feature(id: "gamma", name: "Gamma", section: .color,
                                      access: .indexed(selector: 0xE7, index: 1),
                                      kind: .options([.init(0, "1.8"), .init(1, "2.0"), .init(2, "2.2"), .init(3, "2.4"), .init(4, "2.6")]))
    public static let colorTemp = Feature(id: "colorTemp", name: "Color Temp", section: .color,
                                          access: .indexed(selector: 0xE7, index: 2),
                                          kind: .options([.init(0, "Warm"), .init(1, "Normal"), .init(2, "Cool"), .init(3, "Bluelight"), .init(4, "User")]))

    public static let all: [Feature] = [
        displayMode, brightness, contrast, blackBoost,
        colorTemp, gamma, blueLight,
        overdrive,
        input, volume, keyLock,
    ]

    /// Input codes used by the widget (0x60). On the XV275U P3, USB-C reports as DisplayPort 1.
    public static let inputs: [FeatureOption] = [
        .init(0x0F, "DisplayPort / USB-C"), .init(0x10, "DisplayPort 2"),
        .init(0x11, "HDMI 1"), .init(0x12, "HDMI 2"), .init(0x13, "USB-C"), .init(0x01, "VGA"),
    ]

    /// Every display mode value the widget knows (0xE2).
    public static let displayModes: [FeatureOption] = [
        .init(0, "User"), .init(1, "Standard"), .init(2, "ECO"), .init(3, "Graphics"), .init(4, "Movie"),
        .init(5, "Game 1"), .init(6, "Game 2"), .init(7, "Game 3"), .init(8, "AdobeRGB"), .init(9, "sRGB"),
        .init(10, "Rec.709"), .init(11, "HDR"), .init(12, "Reading"), .init(13, "Dark Room"),
        .init(14, "DCI-P3"), .init(15, "CAD/CAM"),
    ]

    /// Display modes this monitor offers. The widget always shows User/Standard/Graphics/ECO/Movie
    /// and enables the rest from the 0xE3 bitmask (bit 8 Game 1, 7 Game 2, 6 Game 3, 5 AdobeRGB,
    /// 4 sRGB, 2 HDR).
    public static func supportedDisplayModes(bitmask: UInt16) -> [FeatureOption] {
        let bitToMode: [(bit: Int, mode: UInt16)] = [(8, 5), (7, 6), (6, 7), (5, 8), (4, 9), (2, 11)]
        var values: Set<UInt16> = [0, 1, 2, 3, 4]
        for (bit, mode) in bitToMode where bitmask & (1 << bit) != 0 { values.insert(mode) }
        return displayModes.filter { values.contains($0.value) }
    }

    /// Inputs listed in the capabilities string, in table order.
    public static func supportedInputs(_ caps: Capabilities) -> [FeatureOption] {
        guard let listed = caps.vcp[0x60], !listed.isEmpty else { return inputs }
        return inputs.filter { listed.contains(UInt8($0.value)) }
    }
}
