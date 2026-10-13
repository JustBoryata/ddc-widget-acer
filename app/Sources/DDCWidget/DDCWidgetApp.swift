import AppKit
import DDCKit
import SwiftUI

@main
struct DDCWidgetApp: App {
    @StateObject private var model = MonitorModel()

    init() {
        // Menu-bar only, no Dock icon (also set via LSUIElement in the bundle).
        NSApplication.shared.setActivationPolicy(.accessory)
        if let enabled = DimmingTest.argument {
            Task { @MainActor in await DimmingTest.run(enabled) }
        } else if let enabled = HDRTest.argument {
            Task { @MainActor in await HDRTest.run(enabled) }
        } else if let directory = Snapshot.outputDirectory {
            Task { @MainActor in await Snapshot.run(to: directory) }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(model)
                .task { await model.connectIfNeeded() }
        } label: {
            Image(systemName: "display")
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch model.state {
            case .connecting:
                ProgressView("Connecting to monitor…").frame(maxWidth: .infinity)
            case let .failed(message):
                Text(message).foregroundStyle(.secondary).font(.callout)
                Button("Retry") { Task { await model.connect() } }
            case .ready:
                HDRRow()
                ForEach(FeatureSection.allCases, id: \.self) { section in
                    let items = model.features.filter { $0.section == section }
                    if !items.isEmpty {
                        GroupBox(section.rawValue) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(items) { FeatureRow(feature: $0) }
                            }
                            .padding(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            Divider()
            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .topLeading)
        .onAppear { Task { await model.refresh() } }
    }

    private var header: some View {
        HStack {
            Image(systemName: "display")
            Text(model.modelName).font(.headline)
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await model.refresh(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Read settings from the monitor")
                .disabled(model.state != .ready)
            }
        }
    }
}

struct FeatureRow: View {
    @EnvironmentObject private var model: MonitorModel
    let feature: Feature

    private var value: UInt16? { model.values[feature.id] }

    /// Fixed-width label so pickers in a section line up.
    private var label: some View {
        Text(feature.name).frame(width: 84, alignment: .leading)
    }

    var body: some View {
        switch feature.kind {
        case .range:
            let maximum = Double(max(model.maxima[feature.id] ?? 100, 1))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(feature.name)
                    Spacer()
                    Text(value.map(String.init) ?? "–").monospacedDigit().foregroundStyle(.secondary)
                }
                // No `step`: it draws a tick per value, which is a solid bar for 0–100.
                Slider(value: Binding(
                    get: { Double(value ?? 0) },
                    set: { model.set(feature, UInt16($0.rounded())) }
                ), in: 0...maximum)
                .disabled(value == nil)
            }
        case let .options(options):
            let binding = Binding<UInt16>(
                get: { value ?? UInt16.max },
                set: { model.set(feature, $0) }
            )
            // Segmented only when it fits next to the label in the 320 pt panel.
            if options.count <= 3, options.allSatisfy({ $0.name.count <= 8 }) {
                HStack {
                    label
                    Picker(feature.name, selection: binding) {
                        ForEach(options) { Text($0.name).tag($0.value) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(value == nil)
                }
            } else {
                HStack {
                    label
                    Picker(feature.name, selection: binding) {
                        if value == nil || !options.contains(where: { $0.value == value }) {
                            Text(value.map { "Unknown (\($0))" } ?? "–").tag(value ?? UInt16.max)
                        }
                        ForEach(options) { Text($0.name).tag($0.value) }
                    }
                    .labelsHidden()
                    .disabled(value == nil)
                }
            }
        case .toggle:
            Toggle(feature.name, isOn: Binding(
                get: { (value ?? 0) != 0 },
                set: { model.set(feature, $0 ? 1 : 0) }
            ))
            .disabled(value == nil)
        }
    }
}

struct HDRRow: View {
    @EnvironmentObject private var model: MonitorModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "sun.max.fill")
                    Toggle("HDR", isOn: Binding(get: { model.hdrEnabled }, set: { model.setHDR($0) }))
                        .toggleStyle(.switch)
                        .font(.headline)
                        .disabled(!model.hdrAvailable)
                    if model.hdrBusy { ProgressView().controlSize(.small) }
                }
                Text("macOS HDR + monitor HDR mode (local dimming on). Off restores \(model.modeToRestoreName) mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider().padding(.vertical, 2)
                HStack {
                    Image(systemName: "circle.lefthalf.filled")
                    Toggle("Local Dimming", isOn: Binding(get: { model.localDimmingOn }, set: { model.setLocalDimming($0) }))
                        .toggleStyle(.switch)
                }
                Text("Uses the monitor's HDR mode, where dimming is active. Off returns to \(model.modeToRestoreName) mode. The level is set in the monitor's menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DisclosureGroup("One-time monitor setup") {
                    Text("""
                    On the monitor, using its own buttons:
                    1. Set the profile to User.
                    2. Gaming settings → Local Dimming → Off.
                    3. Save the profile to Gaming 3 (Sports).
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
