import Foundation
import Darwin

/// Works out which coding agent, if any, is running in a tab, by looking at
/// the process rather than waiting to be told.
///
/// Identity used to arrive only through hooks, which meant it arrived for
/// exactly one agent. Everything else ran unrecognised, and every reader
/// built on top of that identity sat idle no matter how good it was. The
/// foreground process of a tab is the honest answer to "what is running
/// here", and it costs one syscall to ask.
///
/// The process name alone is not enough. Claude presents as `claude`, Cline
/// as `.cline`, and Codex as `node`, because it is a script. So the whole
/// command line is read and every argument considered.
enum AgentProcessDetector {
    /// Cache keyed by pid. A tab's foreground process changes rarely, and
    /// re-reading argv on every sidebar rebuild would be pure waste.
    private static var cache: [pid_t: SidebarTabManager.AgentType?] = [:]
    private static var cacheOrder: [pid_t] = []
    private static let cacheLimit = 256

    /// The agent running as `pid`, or nil for anything we don't recognise.
    static func agent(forProcess pid: pid_t) -> SidebarTabManager.AgentType? {
        guard pid > 0 else { return nil }
        if let cached = cache[pid] { return cached }

        let found = arguments(of: pid).flatMap(match)
        remember(pid, found)
        return found
    }

    /// Forget processes that have exited, so the cache can't grow forever or
    /// answer for a pid the system has since handed to somebody else.
    static func forgetDeadProcesses() {
        let dead = cacheOrder.filter { kill($0, 0) == -1 && errno == ESRCH }
        guard !dead.isEmpty else { return }
        for pid in dead { cache.removeValue(forKey: pid) }
        cacheOrder.removeAll { dead.contains($0) }
    }

    private static func remember(_ pid: pid_t, _ agent: SidebarTabManager.AgentType?) {
        cache[pid] = agent
        cacheOrder.append(pid)
        if cacheOrder.count > cacheLimit {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    /// Match a command line against the agents we know.
    ///
    /// Any argument can carry the name, because the interesting one is often
    /// not the first: Codex runs as `node /opt/homebrew/bin/codex`.
    private static func match(_ argv: [String]) -> SidebarTabManager.AgentType? {
        for argument in argv {
            // Arguments are paths as often as not, and Cline installs itself
            // under a leading dot.
            var name = (argument as NSString).lastPathComponent
            if name.hasPrefix(".") { name.removeFirst() }
            guard !name.isEmpty else { continue }
            for agent in SidebarTabManager.AgentType.allCases
            where agent.binaryName == name {
                return agent
            }
        }
        return nil
    }

    /// Read another process's command line.
    ///
    /// `KERN_PROCARGS2` hands back a blob laid out as an argument count, the
    /// executable path, padding, and then the arguments as null-terminated
    /// strings. It is readable for our own processes without any elevated
    /// privilege, which is the whole reason this approach works at all.
    private static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]

        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        var count: Int32 = 0
        _ = withUnsafeMutableBytes(of: &count) { destination in
            buffer.withUnsafeBytes { source in
                destination.copyBytes(from: UnsafeRawBufferPointer(
                    rebasing: source[0..<MemoryLayout<Int32>.size]))
            }
        }
        guard count > 0 else { return nil }

        var argv: [String] = []
        var index = MemoryLayout<Int32>.size

        // Step over the executable path and the padding that follows it.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        while index < size, argv.count < Int(count) {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            if index > start {
                let bytes = buffer[start..<index].map { UInt8(bitPattern: $0) }
                if let text = String(bytes: bytes, encoding: .utf8) { argv.append(text) }
            }
            index += 1
        }

        return argv.isEmpty ? nil : argv
    }
}
