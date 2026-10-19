import DDCKit
import Foundation

@MainActor
final class MonitorModel: ObservableObject {
    enum State: Equatable {
        case connecting
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .connecting
    @Published private(set) var modelName = "Acer monitor"
    @Published private(set) var features: [Feature] = []
    @Published private(set) var values: [String: UInt16] = [:]
    @Published private(set) var maxima: [String: UInt16] = [:]
    @Published private(set) var isRefreshing = false
    @Published var lastError: String?
    @Published private(set) var hdrAvailable = false
    @Published private(set) var hdrEnabled = false
    @Published private(set) var hdrBusy = false

    private var controller: MonitorController?
    private var lastRefresh = Date.distantPast
    // Slider drags produce many values; only the latest one per feature is sent.
    private var pending: [String: UInt16] = [:]
    private var writing: Set<String> = []

    func connectIfNeeded() async {
        guard controller == nil else { return }
        await connect()
    }

    private var isConnecting = false

    func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        state = .connecting
        do {
            let cacheKey = "capabilities"
            let (controller, caps) = try await MonitorController.connect(
                cachedCapabilities: UserDefaults.standard.string(forKey: cacheKey))
            UserDefaults.standard.set(caps.raw, forKey: cacheKey)
            self.controller = controller
            modelName = caps.model ?? "Acer monitor"
            var supported = AcerFeatures.all.filter { $0.isSupported(by: caps) }
            // Narrow the option lists to what this monitor reports.
            let modeMask = try? await controller.get(0xE3).current
            supported = supported.map { feature in
                switch feature.id {
                case AcerFeatures.displayMode.id:
                    let modes = modeMask.map(AcerFeatures.supportedDisplayModes) ?? AcerFeatures.displayModes
                    return Feature(id: feature.id, name: feature.name, section: feature.section, access: feature.access, kind: .options(modes))
                case AcerFeatures.input.id:
                    return Feature(id: feature.id, name: feature.name, section: feature.section, access: feature.access,
                                   kind: .options(AcerFeatures.supportedInputs(caps)))
                default:
                    return feature
                }
            }
            features = supported
            state = .ready
            startHDRSync()
            await refresh(force: true)
        } catch {
            state = .failed(String(describing: error))
        }
    }

    /// Reads every value from the monitor. Called when the menu opens, never on a timer, so it
    /// doesn't compete with BetterDisplay for the DDC bus.
    func refresh(force: Bool = false) async {
        guard let controller else { return }
        guard !isRefreshing else {
            // A change landed mid-refresh; read everything again once this pass ends.
            if force { refreshAgain = true }
            return
        }
        guard force || Date().timeIntervalSince(lastRefresh) > 3 else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefresh = Date()
        }
        repeat {
            refreshAgain = false
            for feature in features where !writing.contains(feature.id) {
                do {
                    let value = try await controller.read(feature)
                    guard !writing.contains(feature.id) else { continue }
                    values[feature.id] = value.current
                    maxima[feature.id] = value.maximum
                } catch {
                    lastError = "\(feature.name): \(error)"
                }
            }
        } while refreshAgain
    }

    private var refreshAgain = false
    private var refreshAfterChange: Task<Void, Never>?

    /// Other values follow some changes (each display mode has its own brightness, contrast, color
    /// temp…), so re-read everything shortly after one, instead of waiting for the refresh button.
    private func scheduleRefreshAfterChange() {
        refreshAfterChange?.cancel()
        refreshAfterChange = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.refresh(force: true)
        }
    }

    // MARK: - HDR

    private static let hdrModeValue: UInt16 = 11  // display mode "HDR" (0xE2)
    private static let previousModeKey = "modeBeforeHDR"
    private var hdrSyncStarted = false

    /// Mode to restore when HDR goes off; persisted so it survives an app restart.
    private var modeBeforeHDR: UInt16? {
        get { (UserDefaults.standard.object(forKey: Self.previousModeKey) as? Int).map { UInt16(truncatingIfNeeded: $0) } }
        set { UserDefaults.standard.set(newValue.map { Int($0) }, forKey: Self.previousModeKey) }
    }

    private func startHDRSync() {
        hdrAvailable = MacHDR.isAvailable
        hdrEnabled = MacHDR.isEnabled
        guard !hdrSyncStarted else { return }
        hdrSyncStarted = true
        // HDR toggled elsewhere (System Settings, BetterDisplay): follow it on the monitor.
        MacHDR.observeChanges { [weak self] in
            Task { @MainActor in await self?.macHDRChanged() }
        }
    }

    private func macHDRChanged() async {
        hdrAvailable = MacHDR.isAvailable
        let enabled = MacHDR.isEnabled
        guard !hdrBusy, enabled != hdrEnabled else { return }
        EventLog.write("macOS HDR changed outside the app: \(enabled)")
        hdrEnabled = enabled
        await applyMonitorMode(forHDR: enabled)
    }

    /// The HDR button: macOS HDR and the monitor's HDR mode together.
    func setHDR(_ enabled: Bool) {
        guard !hdrBusy else { return }
        EventLog.write("HDR toggle: \(enabled)")
        hdrBusy = true
        hdrEnabled = enabled
        Task {
            if enabled { await rememberCurrentMode() }
            MacHDR.setEnabled(enabled)
            // The monitor resyncs to the new signal; give it time before DDC commands.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await applyMonitorMode(forHDR: enabled)
            hdrEnabled = MacHDR.isEnabled
            hdrBusy = false
        }
    }

    /// Local dimming can't be set over DDC on the XV275U P3, but HDR mode turns it on and User mode
    /// turns it off (verified on hardware). So "on" is the monitor's HDR mode without macOS HDR.
    var localDimmingOn: Bool { values[AcerFeatures.displayMode.id] == Self.hdrModeValue }

    func setLocalDimming(_ enabled: Bool) {
        guard !hdrBusy else { return }
        EventLog.write("Local Dimming toggle: \(enabled)")
        hdrBusy = true
        Task {
            if enabled { await rememberCurrentMode() }
            await applyMonitorMode(forHDR: enabled)
            hdrBusy = false
        }
    }

    /// Mode that "off" returns to, for the UI.
    var modeToRestoreName: String {
        let value = modeBeforeHDR ?? 0
        return AcerFeatures.displayModes.first { $0.value == value }?.name ?? "User"
    }

    private func rememberCurrentMode() async {
        guard let controller else { return }
        let current = (try? await controller.read(AcerFeatures.displayMode))?.current ?? values[AcerFeatures.displayMode.id]
        if let current, current != Self.hdrModeValue { modeBeforeHDR = current }
    }

    private func applyMonitorMode(forHDR enabled: Bool) async {
        guard let controller else { return }
        if enabled, modeBeforeHDR == nil { await rememberCurrentMode() }
        let target = enabled ? Self.hdrModeValue : (modeBeforeHDR ?? 0)
        EventLog.write("monitor mode -> \(target)")
        let id = AcerFeatures.displayMode.id
        // Keeps a refresh from showing the old mode while the write is in flight.
        writing.insert(id)
        defer { writing.remove(id) }
        do {
            try await controller.write(AcerFeatures.displayMode, target)
            values[id] = target
            if !enabled { modeBeforeHDR = nil }
            lastError = nil
        } catch {
            EventLog.write("monitor mode -> \(target) failed: \(error)")
            lastError = "Display mode: \(error)"
            // Show the mode the monitor is really in, so the toggles match it.
            if let actual = try? await controller.read(AcerFeatures.displayMode) { values[id] = actual.current }
        }
        scheduleRefreshAfterChange()
    }

    func set(_ feature: Feature, _ value: UInt16) {
        guard values[feature.id] != value || pending[feature.id] != nil else { return }
        values[feature.id] = value
        pending[feature.id] = value
        guard !writing.contains(feature.id) else { return }
        writing.insert(feature.id)
        Task { await drain(feature) }
    }

    private func drain(_ feature: Feature) async {
        while let value = pending.removeValue(forKey: feature.id) {
            do {
                try await controller?.write(feature, value)
                lastError = nil
            } catch {
                lastError = "\(feature.name): \(error)"
            }
        }
        writing.remove(feature.id)
        // A slider only changes itself; a mode, preset or toggle can change other values.
        if case .range = feature.kind { return }
        scheduleRefreshAfterChange()
    }
}
