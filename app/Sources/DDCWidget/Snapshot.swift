import AppKit
import DDCKit
import SwiftUI

/// Debug aid: `DDCWidget --snapshot <dir>` connects to the monitor, renders the menu panel in an
/// offscreen window (light and dark), writes PNGs and exits. Needs no screen-recording permission.
enum Snapshot {
    static var outputDirectory: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor
    static func run(to directory: String) async {
        let model = MonitorModel()
        await model.connect()
        let updater = Updater()
        await updater.check(force: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            // A real MenuBarExtra window draws its own material; offscreen we need a solid background.
            let view = ContentView().environmentObject(model).environmentObject(updater).background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: appearance)
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.backgroundColor = appearance == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = URL(fileURLWithPath: directory).appendingPathComponent("menu-\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("wrote \(url.path) \(Int(size.width))x\(Int(size.height))")
        }
        exit(0)
    }
}

/// Debug aid: `DDCWidget --hdr on|off` runs the HDR toggle without the menu, prints the result, exits.
enum HDRTest {
    static var argument: Bool? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--hdr"), i + 1 < args.count else { return nil }
        return args[i + 1] == "on"
    }

    @MainActor
    static func run(_ enabled: Bool) async {
        let model = MonitorModel()
        await model.connect()
        print("before: macOS HDR \(MacHDR.isEnabled), mode \(model.values[AcerFeatures.displayMode.id].map(String.init) ?? "?")")
        model.setHDR(enabled)
        while model.hdrBusy { try? await Task.sleep(nanoseconds: 200_000_000) }
        await model.refresh(force: true)
        print("after:  macOS HDR \(MacHDR.isEnabled), mode \(model.values[AcerFeatures.displayMode.id].map(String.init) ?? "?"), error \(model.lastError ?? "none")")
        exit(0)
    }
}

/// Debug aid: `DDCWidget --dimming on|off` runs the Local Dimming toggle without the menu.
enum DimmingTest {
    static var argument: Bool? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--dimming"), i + 1 < args.count else { return nil }
        return args[i + 1] == "on"
    }

    @MainActor
    static func run(_ enabled: Bool) async {
        let model = MonitorModel()
        await model.connect()
        print("before: dimming \(model.localDimmingOn), mode \(model.values[AcerFeatures.displayMode.id].map(String.init) ?? "?")")
        model.setLocalDimming(enabled)
        try? await Task.sleep(nanoseconds: 100_000_000)
        while model.hdrBusy { try? await Task.sleep(nanoseconds: 200_000_000) }
        await model.refresh(force: true)
        print("after:  dimming \(model.localDimmingOn), mode \(model.values[AcerFeatures.displayMode.id].map(String.init) ?? "?"), error \(model.lastError ?? "none")")
        exit(0)
    }
}
