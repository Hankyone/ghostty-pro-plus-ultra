import Foundation
import Cocoa

/// Stores per-tab metadata (status entries) that can be set via IPC.
/// Each tab is identified by its surface UUID.
///
/// Entries are persisted to disk as JSON so sidebar metadata survives
/// app restart. Transient keys (`claude-pid`, `claude-active`) are
/// excluded from persistence.
@MainActor
final class TabMetadataStore: ObservableObject {
    static let shared = TabMetadataStore()

    struct StatusEntry: Equatable, Codable {
        let key: String
        let value: String
        let icon: String?  // SF Symbol name, optional
    }

    /// Status entries keyed by tab UUID, then by status key
    @Published private(set) var entries: [UUID: [String: StatusEntry]] = [:]

    /// Keys that are transient and should not be persisted to disk.
    private static let transientKeys: Set<String> = ["claude-pid", "claude-active", "claude-done-at", "codex-pid", "codex-active", "codex-done-at"]

    private var pendingSave: DispatchWorkItem?

    private init() {
        loadFromDisk()
    }

    /// Session keys that are mutually exclusive — setting one clears the other.
    private static let exclusiveSessionKeys: [String: String] = [
        "claude-session": "codex-session",
        "codex-session": "claude-session",
    ]

    func setStatus(tabId: UUID, key: String, value: String, icon: String? = nil) {
        if entries[tabId] == nil {
            entries[tabId] = [:]
        }
        // Session keys are mutually exclusive: setting one clears the other
        // so a tab is always either Claude or Codex, never both.
        if let conflicting = Self.exclusiveSessionKeys[key] {
            entries[tabId]?.removeValue(forKey: conflicting)
        }
        entries[tabId]?[key] = StatusEntry(key: key, value: value, icon: icon)
        if !Self.transientKeys.contains(key) {
            scheduleSave()
        }
    }

    func clearStatus(tabId: UUID, key: String) {
        entries[tabId]?.removeValue(forKey: key)
        if entries[tabId]?.isEmpty == true {
            entries.removeValue(forKey: tabId)
        }
        if !Self.transientKeys.contains(key) {
            scheduleSave()
        }
    }

    func statusEntries(for tabId: UUID) -> [StatusEntry] {
        guard let tabEntries = entries[tabId] else { return [] }
        return tabEntries.values.sorted { $0.key < $1.key }
    }

    func removeAll(for tabId: UUID) {
        entries.removeValue(forKey: tabId)
        scheduleSave()
    }

    /// Sweep stale Claude and Codex sessions whose PIDs are no longer alive.
    /// Called periodically from SidebarTabManager.
    func sweepStaleSessions() {
        for (tabId, tabEntries) in entries {
            // Sweep stale Claude sessions
            if let pidEntry = tabEntries["claude-pid"],
               let pid = Int32(pidEntry.value) {
                // kill(pid, 0) checks if the process exists without sending a signal.
                // Returns -1 with ESRCH if the process doesn't exist.
                if kill(pid, 0) == -1 && errno == ESRCH {
                    entries[tabId]?.removeValue(forKey: "claude")
                    entries[tabId]?.removeValue(forKey: "claude-active")
                    entries[tabId]?.removeValue(forKey: "claude-pid")
                }
            }

            // Sweep stale Codex sessions
            if let pidEntry = tabEntries["codex-pid"],
               let pid = Int32(pidEntry.value) {
                if kill(pid, 0) == -1 && errno == ESRCH {
                    entries[tabId]?.removeValue(forKey: "codex")
                    entries[tabId]?.removeValue(forKey: "codex-active")
                    entries[tabId]?.removeValue(forKey: "codex-pid")
                }
            }

            if entries[tabId]?.isEmpty == true {
                entries.removeValue(forKey: tabId)
            }
        }
    }

    /// Legacy name — calls sweepStaleSessions().
    func sweepStaleClaude() {
        sweepStaleSessions()
    }

    /// Remove entries for surface UUIDs that no longer exist.
    /// Called after window restoration completes.
    func pruneOrphanedEntries(liveSurfaceIds: Set<UUID>) {
        var changed = false
        for tabId in entries.keys where !liveSurfaceIds.contains(tabId) {
            entries.removeValue(forKey: tabId)
            changed = true
        }
        if changed {
            save()
        }
    }

    // MARK: - Persistence

    private static var persistenceURL: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let dir = appSupport.appendingPathComponent("com.mitchellh.ghostty")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tab-metadata.json")
    }

    private struct PersistedMetadata: Codable {
        let entries: [String: [String: StatusEntry]]
    }

    private func loadFromDisk() {
        guard let url = Self.persistenceURL,
              let data = try? Data(contentsOf: url) else { return }
        guard let persisted = try? JSONDecoder().decode(PersistedMetadata.self, from: data) else { return }
        for (uuidStr, tabEntries) in persisted.entries {
            guard let uuid = UUID(uuidString: uuidStr) else { continue }
            entries[uuid] = tabEntries
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.save()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func save() {
        guard let url = Self.persistenceURL else { return }
        var filtered: [String: [String: StatusEntry]] = [:]
        for (tabId, tabEntries) in entries {
            let kept = tabEntries.filter { !Self.transientKeys.contains($0.key) }
            if !kept.isEmpty {
                filtered[tabId.uuidString] = kept
            }
        }
        let persisted = PersistedMetadata(entries: filtered)
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
