import Foundation
import Cocoa

/// Detects which coding-agent CLIs are actually installed, so the new-tab
/// menu can show only the agents the user can launch.
///
/// A GUI app launched from Finder inherits a minimal PATH
/// (`/usr/bin:/bin:/usr/sbin:/sbin`), which misses Homebrew, `~/.local/bin`,
/// `~/.opencode/bin`, nvm, mise, etc. — where most agent binaries live. So we
/// resolve the user's real *login-shell* PATH once and scan it for each
/// agent's binary. The agent-shim directory is skipped so the fake `claude`
/// wrapper installed there never counts as a real install.
@MainActor
final class AgentDetector: ObservableObject {
    static let shared = AgentDetector()

    /// Agents found on the login-shell PATH. Empty until the first scan
    /// completes; the menu simply shows no agents until then (a fraction of a
    /// second after launch).
    @Published private(set) var installed: Set<SidebarTabManager.AgentType> = []

    /// Monotonic timestamp (systemUptime) of the last completed scan, used to
    /// throttle re-scans on rapid app re-activation.
    private var lastScan: TimeInterval = -.infinity
    private var scanning = false

    private init() {
        // Re-detect when the app is re-activated so an agent installed while
        // Ghostty was in the background shows up without a restart.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func appDidBecomeActive() {
        refresh()
    }

    /// Kick off detection on a background thread. Throttled to at most once
    /// every 10 seconds unless `force` is set (used at launch).
    func refresh(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        if !force && (scanning || now - lastScan < 10) { return }
        scanning = true
        let shimDir = AgentShimInstaller.shimDirectory
        DispatchQueue.global(qos: .utility).async {
            let found = Self.scan(shimDir: shimDir)
            DispatchQueue.main.async {
                self.lastScan = ProcessInfo.processInfo.systemUptime
                self.scanning = false
                if self.installed != found { self.installed = found }
            }
        }
    }

    /// Test every known agent binary against the login-shell PATH.
    private static func scan(shimDir: String?) -> Set<SidebarTabManager.AgentType> {
        let dirs = loginShellPath()
        let fm = FileManager.default
        var result: Set<SidebarTabManager.AgentType> = []
        for agent in SidebarTabManager.AgentType.allCases {
            for dir in dirs where dir != shimDir {
                let candidate = (dir as NSString).appendingPathComponent(agent.binaryName)
                if fm.isExecutableFile(atPath: candidate) {
                    result.insert(agent)
                    break
                }
            }
        }
        return result
    }

    /// Resolve the user's login-shell PATH by asking their shell directly, so
    /// PATH mutations from `.zshrc` / `.zprofile` (Homebrew, mise, nvm, …) are
    /// included. Falls back to the process PATH on any failure.
    private static func loginShellPath() -> [String] {
        let fallback = {
            (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").map(String.init).filter { !$0.isEmpty }
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        // -l (login) + -i (interactive) so rc files that set PATH are sourced;
        // printf avoids any trailing newline noise.
        proc.arguments = ["-lic", "printf %s \"$PATH\""]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()  // swallow shell startup chatter

        do {
            try proc.run()
        } catch {
            return fallback()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let path = String(data: data, encoding: .utf8) ?? ""
        let dirs = path.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        return dirs.isEmpty ? fallback() : dirs
    }
}
