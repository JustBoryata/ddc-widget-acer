import AppKit
import Foundation

/// Checks GitHub Releases for a newer version and installs it with Homebrew (the app is
/// distributed as a source-building formula, so `brew upgrade` is the update path).
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case available(version: String)
        case updating
        case failed(String)
    }

    static let repo = "JustBoryata/ddc-widget-acer"
    static let formula = "justboryata/tap/ddc-widget-acer"
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let lastCheckKey = "lastUpdateCheck"

    @Published private(set) var state: State = .idle
    @Published private(set) var releaseURL = URL(string: "https://github.com/\(Updater.repo)/releases/latest")!

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    /// Asks GitHub for the latest release at most once a day unless `force`d.
    func check(force: Bool = false) async {
        guard state != .updating else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard force || Date().timeIntervalSince1970 - last > Self.checkInterval else { return }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        struct Release: Decodable { let tag_name: String; let html_url: String; let draft: Bool; let prerelease: Bool }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              !release.draft, !release.prerelease else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        if let url = URL(string: release.html_url) { releaseURL = url }
        if Self.isNewer(latest, than: currentVersion) {
            EventLog.write("update available: \(latest)")
            state = .available(version: latest)
        } else if case .available = state {
            state = .idle
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Installed by Homebrew (the app bundle lives in the Cellar, possibly behind a symlink).
    var installedWithBrew: Bool {
        Bundle.main.bundleURL.resolvingSymlinksInPath().path.contains("/Cellar/") && Self.brewPath != nil
    }

    func openReleasePage() { NSWorkspace.shared.open(releaseURL) }

    /// Runs `brew upgrade` (it builds from source, about a minute), then relaunches the new app.
    func update() {
        guard let brew = Self.brewPath, installedWithBrew else { return openReleasePage() }
        state = .updating
        EventLog.write("updating with brew")
        Task.detached {
            let result = Self.run(brew, ["upgrade", Self.formula])
            await MainActor.run { self.finishUpdate(result) }
        }
    }

    private func finishUpdate(_ result: (status: Int32, output: String)) {
        guard result.status == 0 else {
            let tail = result.output.split(separator: "\n").suffix(2).joined(separator: " ")
            EventLog.write("brew upgrade failed (\(result.status)): \(result.output)")
            state = .failed(tail.isEmpty ? "brew upgrade failed (\(result.status))" : tail)
            return
        }
        EventLog.write("brew upgrade done, relaunching")
        // The opt symlink now points at the new version; /Applications links there too.
        let prefix = Self.brewPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path }
            ?? "/opt/homebrew"
        let app = "\(prefix)/opt/ddc-widget-acer/DDC Widget.app"
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app]
        try? relaunch.run()
        NSApplication.shared.terminate(nil)
    }

    nonisolated private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        // A menu-bar app gets a minimal PATH; brew needs its own bin and the system tools (swift, git).
        let brewBin = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        env["PATH"] = "\(brewBin):/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, String(describing: error)) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
