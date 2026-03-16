import Foundation
import Cocoa

/// Stores per-tab metadata (status entries) that can be set via IPC.
/// Each tab is identified by its surface UUID.
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

    private init() {}

    func setStatus(tabId: UUID, key: String, value: String, icon: String? = nil) {
        if entries[tabId] == nil {
            entries[tabId] = [:]
        }
        entries[tabId]?[key] = StatusEntry(key: key, value: value, icon: icon)
    }

    func clearStatus(tabId: UUID, key: String) {
        entries[tabId]?.removeValue(forKey: key)
        if entries[tabId]?.isEmpty == true {
            entries.removeValue(forKey: tabId)
        }
    }

    func statusEntries(for tabId: UUID) -> [StatusEntry] {
        guard let tabEntries = entries[tabId] else { return [] }
        return tabEntries.values.sorted { $0.key < $1.key }
    }

    func removeAll(for tabId: UUID) {
        entries.removeValue(forKey: tabId)
    }

    /// Sweep stale Claude sessions whose PIDs are no longer alive.
    /// Called periodically from SidebarTabManager.
    func sweepStaleClaude() {
        for (tabId, tabEntries) in entries {
            guard let pidEntry = tabEntries["claude-pid"],
                  let pid = Int32(pidEntry.value) else { continue }

            // kill(pid, 0) checks if the process exists without sending a signal.
            // Returns -1 with ESRCH if the process doesn't exist.
            if kill(pid, 0) == -1 && errno == ESRCH {
                // Process is dead — clean up all Claude-related entries
                entries[tabId]?.removeValue(forKey: "claude")
                entries[tabId]?.removeValue(forKey: "claude-active")
                entries[tabId]?.removeValue(forKey: "claude-pid")
                if entries[tabId]?.isEmpty == true {
                    entries.removeValue(forKey: tabId)
                }
            }
        }
    }
}
