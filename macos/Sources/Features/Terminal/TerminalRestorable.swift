import Cocoa
import GhosttyKit

protocol TerminalRestorable: Codable {
    static var selfKey: String { get }
    static var versionKey: String { get }
    static var version: Int { get }
    /// Minimum version that can be decoded safely
    static var minimumVersion: Int { get }
    init(copy other: Self)

    /// Returns a base configuration to use when restoring terminal surfaces.
    /// Override this to provide custom environment variables or other configuration.
    var baseConfig: Ghostty.SurfaceConfiguration? { get }
}

extension TerminalRestorable {
    static var minimumVersion: Int { version }
}

extension TerminalRestorable {
    static var selfKey: String { "state" }
    static var versionKey: String { "version" }

    private var debugDescription: String {
        withUnsafePointer(to: self) { ptr in
            "<\(ptr)>[version: \(Self.version)]"
        }
    }

    /// Default implementation returns nil (no custom base config).
    var baseConfig: Ghostty.SurfaceConfiguration? { nil }

    init?(coder aDecoder: NSCoder) {
        // If the version doesn't match then we can't decode. In the future we can perform
        // version upgrading or something but for now we only have one version so we
        // don't bother.
        let current = aDecoder.decodeInteger(forKey: Self.versionKey)
        guard current >= Self.minimumVersion else {
            AppDelegate.logger.error("error restoring terminal: version not supported: expected=\(Self.minimumVersion, privacy: .public), got=\(current, privacy: .public)")
            return nil
        }

        guard let v = aDecoder.decodeObject(of: CodableBridge<Self>.self, forKey: Self.selfKey) else {
            AppDelegate.logger.error("error restoring terminal: decode failed")
            return nil
        }

        self.init(copy: v.value)
    }

    func encode(with coder: NSCoder) {
        coder.encode(Self.version, forKey: Self.versionKey)
        coder.encode(CodableBridge(self), forKey: Self.selfKey)

        AppDelegate.logger.debug("saved terminal state: \(debugDescription, privacy: .public)")
    }
}

/// The state stored for terminal window restoration.
final class TerminalRestorableState: TerminalRestorable {
    static var version: Int { 7 }
    static var minimumVersion: Int { 5 }

    var focusedSurface: String? {
        internalState.focusedSurface
    }
    var surfaceTree: SplitTree<Ghostty.SurfaceView> {
        internalState.surfaceTree
    }
    var effectiveFullscreenMode: FullscreenMode? {
        internalState.effectiveFullscreenMode
    }
    var tabColor: TerminalTabColor? {
        internalState.tabColor
    }
    var titleOverride: String? {
        internalState.titleOverride
    }

    /// Internal State we use to perform unit tests
    ///
    /// Since we can't really change the type of `TerminalRestorableState`
    /// due to `CodableBridge<TerminalRestorableState>` supporting secure coding,
    /// we use an internal type to perform migration and tests
    private let internalState: InternalState<Ghostty.SurfaceView>

    init(from controller: TerminalController) {
        internalState = .init(from: controller)
    }

    required init(copy other: TerminalRestorableState) {
        self.internalState = other.internalState
    }

    /// This is just wrapper around internalState
    ///
    /// - Important: If you intend to add more things, go to `InternalState`.
    init(from decoder: any Decoder) throws {
        self.internalState = try InternalState<Ghostty.SurfaceView>(from: decoder)
    }

    /// This is just wrapper around internalState
    ///
    /// - Important: If you intend to add more things, go to `InternalState`.
    func encode(to encoder: any Encoder) throws {
        try internalState.encode(to: encoder)
    }
}

enum TerminalRestoreError: Error {
    case delegateInvalid
    case identifierUnknown
    case stateDecodeFailed
    case windowDidNotLoad
}

/// The NSWindowRestoration implementation that is called when a terminal window needs to be restored.
/// The encoding of a terminal window is handled elsewhere (usually NSWindowDelegate).
class TerminalWindowRestoration: NSObject, NSWindowRestoration {
    static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping (NSWindow?, Error?) -> Void
    ) {
        // Verify the identifier is what we expect
        guard identifier == .init(String(describing: Self.self)) else {
            completionHandler(nil, TerminalRestoreError.identifierUnknown)
            return
        }

        // The app delegate is definitely setup by now. If it isn't our AppDelegate
        // then something is royally fucked up but protect against it anyhow.
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            completionHandler(nil, TerminalRestoreError.delegateInvalid)
            return
        }

        // If our configuration is "never" then we never restore the state
        // no matter what. Note its safe to use "ghostty.config" directly here
        // because window restoration is only ever invoked on app start so we
        // don't have to deal with config reloads.
        if appDelegate.ghostty.config.windowSaveState == "never" {
            AppDelegate.logger.warning("skip restoration: window-save-state=never")
            completionHandler(nil, nil)
            return
        }

        // Decode the state. If we can't decode the state, then we can't restore.
        guard let state = TerminalRestorableState(coder: state) else {
            completionHandler(nil, TerminalRestoreError.stateDecodeFailed)
            return
        }

        // The window creation has to go through our terminalManager so that it
        // can be found for events from libghostty. This uses the low-level
        // createWindow so that AppKit can place the window wherever it should
        // be.
        let c = TerminalController.init(
            appDelegate.ghostty,
            withSurfaceTree: state.surfaceTree)
        guard let window = c.window else {
            completionHandler(nil, TerminalRestoreError.windowDidNotLoad)
            return
        }

        // Restore our tab color and avoid unnecessary `invalidateRestorableState` calls
        if let tabColor = state.tabColor {
            (window as? TerminalWindow)?.tabColor = tabColor
        }

        // Restore the tab title override
        c.titleOverride = state.titleOverride

        // Setup our restored state on the controller
        // Find the focused surface in surfaceTree
        if let focusedStr = state.focusedSurface {
            var foundView: Ghostty.SurfaceView?
            for view in c.surfaceTree where view.id.uuidString == focusedStr {
                foundView = view
                break
            }

            if let view = foundView {
                c.focusedSurface = view
                restoreFocus(to: view, inWindow: window)
            }
        }

        completionHandler(window, nil)

        // Auto-resume agent sessions for all surfaces in this window.
        // A surface can only have one active session type — session keys are
        // mutually exclusive in TabMetadataStore, so only one will be present.
        for surface in c.surfaceTree {
            attemptSessionResume(for: surface)
            attemptLastCommandRestore(for: surface)
        }

        guard let mode = state.effectiveFullscreenMode, mode != .native else {
            // We let AppKit handle native fullscreen
            return
        }
        // Give the window to AppKit first, then adjust its frame and style
        // to minimise any visible frame changes.
        c.toggleFullscreen(mode: mode)
    }

    /// Attempt to auto-resume an agent session in a restored surface.
    /// A surface can only resume ONE session type. Session keys are mutually
    /// exclusive in TabMetadataStore, so we detect which agent was running
    /// and build the appropriate resume command.
    @MainActor
    private static func attemptSessionResume(for surface: Ghostty.SurfaceView) {
        // A reattached pane's agent never stopped. Typing a resume command
        // into a running agent doesn't resume anything — it feeds text to a
        // live session and corrupts it.
        if wasReattached(surface) { return }

        let surfaceId = surface.id
        let store = TabMetadataStore.shared
        let entries = store.entries[surfaceId] ?? [:]

        // Detect which agent was running from its session key.
        // Session keys are mutually exclusive, so at most one will be present.
        var detected: (agent: SidebarTabManager.AgentType, sessionId: String)?
        for agent in SidebarTabManager.AgentType.allCases {
            if let entry = entries[agent.sessionKey], !entry.value.isEmpty {
                detected = (agent, entry.value)
                break
            }
        }
        guard let (agent, sessionId) = detected else { return }

        // Build the resume command for the detected agent (runs with full
        // permissions). Returns nil if the agent can't resume or the stored
        // session id fails the injection-safety check.
        guard let command = agent.resumeCommand(sessionId: sessionId) else { return }

        // Don't clear session keys here. They persist so that if the app is
        // force-killed before the resume completes, the next restart will
        // try again. The hooks will update them when the session actually starts.

        // Delay to let the shell initialize and display its prompt.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // Type the command but don't execute — let the user press Enter when ready.
            surface.sendText(command)
        }
    }

    /// Pre-type the last executed command into a restored surface's prompt,
    /// so the user can press Enter to re-run it. Only fires when there's no
    /// agent session to resume (those are handled by attemptSessionResume).
    /// Whether this pane came back to a shell that never stopped, in which
    /// case nothing may be typed into it: whatever the user left running is
    /// still there, and its prompt is not ours to fill.
    @MainActor
    private static func wasReattached(_ surface: Ghostty.SurfaceView) -> Bool {
        surface.id.uuidString.withCString { ghostty_pane_was_reattached($0) }
    }

    @MainActor
    private static func attemptLastCommandRestore(for surface: Ghostty.SurfaceView) {
        // Same reasoning as the agent path: a resumed shell already has
        // whatever the user left at its prompt.
        if wasReattached(surface) { return }

        let surfaceId = surface.id
        let store = TabMetadataStore.shared
        let entries = store.entries[surfaceId] ?? [:]

        // If this surface has any agent session, skip — that's handled by
        // attemptSessionResume.
        let hasAgentSession = SidebarTabManager.AgentType.allCases.contains { agent in
            entries[agent.sessionKey] != nil
        }
        if hasAgentSession { return }

        guard let cmd = entries["last-command"]?.value,
              !cmd.isEmpty else { return }

        // Delay to let the shell initialize and display its prompt.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // Type the command but don't execute — let the user press Enter when ready.
            surface.sendText(cmd)
        }
    }

    /// This restores the focus state of the surfaceview within the given window. When restoring,
    /// the view isn't immediately attached to the window since we have to wait for SwiftUI to
    /// catch up. Therefore, we sit in an async loop waiting for the attachment to happen.
    private static func restoreFocus(to: Ghostty.SurfaceView, inWindow: NSWindow, attempts: Int = 0) {
        // For the first attempt, we schedule it immediately. Subsequent events wait a bit
        // so we don't just spin the CPU at 100%. Give up after some period of time.
        let after: DispatchTime
        if attempts == 0 {
            after = .now()
        } else if attempts > 40 {
            // 2 seconds, give up
            return
        } else {
            after = .now() + .milliseconds(50)
        }

        DispatchQueue.main.asyncAfter(deadline: after) {
            // If the view is not attached to a window yet then we repeat.
            guard let viewWindow = to.window else {
                restoreFocus(to: to, inWindow: inWindow, attempts: attempts + 1)
                return
            }

            // If the view is attached to some other window, we give up
            guard viewWindow == inWindow else { return }

            inWindow.makeFirstResponder(to)

            // If the window is main, then we also make sure it comes forward. This
            // prevents a bug found in #1177 where sometimes on restore the windows
            // would be behind other applications.
            if viewWindow.isMainWindow {
                viewWindow.orderFront(nil)
            }
        }
    }
}

