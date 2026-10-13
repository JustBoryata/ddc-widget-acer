import AppKit
import CoreGraphics

/// macOS "High Dynamic Range" switch for the external display, via the private MonitorPanel
/// framework (`MPDisplay.preferHDRModes`, the setting System Settings toggles) and SkyLight
/// (`SLSDisplayIsHDRModeEnabled`, the live state). Verified on macOS 27 with the XV275U P3.
enum MacHDR {
    private typealias IsEnabledFn = @convention(c) (CGDirectDisplayID) -> Bool

    private static let isEnabledFn: IsEnabledFn? = {
        dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY)
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SLSDisplayIsHDRModeEnabled") else { return nil }
        return unsafeBitCast(symbol, to: IsEnabledFn.self)
    }()

    /// The first external display that supports HDR. The display list changes on reconfiguration,
    /// so a fresh MPDisplayMgr is used each time.
    private static func externalDisplay() -> (display: NSObject, id: CGDirectDisplayID)? {
        _ = isEnabledFn  // loads the frameworks
        guard let managerClass = NSClassFromString("MPDisplayMgr") as? NSObject.Type,
              let displays = managerClass.init().value(forKey: "displays") as? [NSObject] else { return nil }
        for display in displays {
            guard let id = (display.value(forKey: "displayID") as? NSNumber)?.uint32Value,
                  CGDisplayIsBuiltin(id) == 0,
                  (display.value(forKey: "hasHDRModes") as? NSNumber)?.boolValue == true else { continue }
            return (display, id)
        }
        return nil
    }

    static var isAvailable: Bool { externalDisplay() != nil }

    static var isEnabled: Bool {
        guard let (display, id) = externalDisplay() else { return false }
        if let isEnabledFn { return isEnabledFn(id) }
        return (display.value(forKey: "preferHDRModes") as? NSNumber)?.boolValue ?? false
    }

    static func setEnabled(_ enabled: Bool) {
        EventLog.write("macOS HDR -> \(enabled)")
        externalDisplay()?.display.setValue(enabled, forKey: "preferHDRModes")
    }

    /// Calls `handler` on the main queue after display reconfigurations settle (they fire in bursts).
    static func observeChanges(_ handler: @escaping () -> Void) {
        changeHandler = handler
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DispatchQueue.main.async {
                MacHDR.pendingChange?.cancel()
                let work = DispatchWorkItem { MacHDR.changeHandler?() }
                MacHDR.pendingChange = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
            }
        }, nil)
    }

    private static var changeHandler: (() -> Void)?
    private static var pendingChange: DispatchWorkItem?
}
