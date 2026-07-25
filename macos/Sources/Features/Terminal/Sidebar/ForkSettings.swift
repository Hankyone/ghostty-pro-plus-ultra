import Foundation
import OSLog

/// Reads and writes the handful of settings this fork adds, by editing the
/// user's Ghostty config file in place.
///
/// There's no settings store to write to — Ghostty is configured by a text
/// file the user owns and may have organised however they like. So a toggle
/// rewrites just its own line and leaves everything else, comments and order
/// included, exactly as it was. Anything we can't do safely we don't do: if
/// the file can't be read or written, the toggle reports failure rather than
/// risking someone's config.
enum ForkSettings {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.hankyone.ghostty-ppu",
        category: "ForkSettings"
    )

    /// The config file Ghostty actually reads, following the same search order
    /// it does. Returns the first that exists; otherwise the preferred path,
    /// which is where we'd create one.
    static var configPath: String {
        let fm = FileManager.default
        var candidates: [String] = []

        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            candidates.append("\(xdg)/ghostty/config")
        }
        candidates.append(NSHomeDirectory() + "/.config/ghostty/config")
        if let bundleID = Bundle.main.bundleIdentifier {
            candidates.append(
                NSHomeDirectory() +
                "/Library/Application Support/\(bundleID)/config"
            )
        }

        for path in candidates where fm.fileExists(atPath: path) { return path }
        return candidates.first ?? NSHomeDirectory() + "/.config/ghostty/config"
    }

    /// Set a config key to a value, replacing an existing assignment if there
    /// is one and appending otherwise.
    ///
    /// Returns false if nothing could be written, so the caller can say so
    /// rather than silently appearing to have worked.
    @discardableResult
    static func write(key: String, value: String) -> Bool {
        let path = configPath
        let fm = FileManager.default

        var lines: [String] = []
        if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
            lines = existing.components(separatedBy: "\n")
        } else if fm.fileExists(atPath: path) {
            // It's there but unreadable. Don't overwrite what we can't read.
            logger.warning("config exists but could not be read: \(path)")
            return false
        }

        // Match `key = value` allowing whitespace, and skip comments so a
        // commented-out example doesn't get rewritten into a live setting.
        var replaced = false
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            guard name == key else { continue }
            lines[i] = "\(key) = \(value)"
            replaced = true
            // Keep going: a later assignment would otherwise win over ours.
        }

        if !replaced {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append("\(key) = \(value)")
            lines.append("")
        }

        let dir = (path as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true
            )
        }

        do {
            try lines.joined(separator: "\n").write(
                toFile: path,
                atomically: true,
                encoding: .utf8
            )
            return true
        } catch {
            logger.warning("could not write config at \(path): \(error)")
            return false
        }
    }
}
