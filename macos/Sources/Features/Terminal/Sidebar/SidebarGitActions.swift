import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Background-safe git operations for the sidebar's commit/push actions,
/// including AI commit message generation. All functions are nonisolated
/// and intended to run on a background queue.
enum SidebarGitActions {

    enum Result {
        case success(String)
        case error(String)
    }

    /// How long ordinary git commands may run before we kill them. Push can
    /// sit on a credential prompt or a dead remote forever without this.
    private static let gitTimeout: TimeInterval = 60

    /// Cap on bytes we will buffer from `git diff --cached` before handing
    /// the text to the on-device model. The model prompt is condensed further
    /// (~7KB); this only stops us from loading a multi‑MB diff into memory
    /// or deadlocking on a full pipe.
    private static let diffMaxBytes = 128 * 1024

    /// Stage all changes, generate a commit message, and commit.
    static func performGitCommit(at projectRoot: String) -> Result {
        // Stage all changes
        let add = runCommand(["add", "-A"], at: projectRoot, timeout: gitTimeout)
        guard add.status == 0, !add.timedOut else {
            return .error(add.timedOut ? "Staging timed out" : "Failed to stage changes")
        }

        // Check if there's anything staged
        let diffCheck = runCommand(
            ["diff", "--cached", "--quiet"], at: projectRoot, timeout: gitTimeout
        )
        if diffCheck.timedOut {
            return .error("Checking staged changes timed out")
        }
        if diffCheck.status == 0 {
            return .error("No changes to commit")
        }

        // Generate commit message via LLM
        let result = generateCommitMessage(at: projectRoot)
        guard let message = result.message, !message.isEmpty else {
            // Leave files staged — git add -A already ran, and unstaging
            // would silently discard any pre-existing staging the user had.
            let detail = result.stderr.flatMap { ": \($0)" } ?? ""
            return .error("Failed to generate commit message\(detail)")
        }

        let commit = runCommand(
            ["commit", "-m", message], at: projectRoot, timeout: gitTimeout
        )
        guard commit.status == 0, !commit.timedOut else {
            return .error(commit.timedOut ? "Commit timed out" : "Failed to commit")
        }
        return .success(message)
    }

    /// Push the current branch to its remote.
    static func performGitPush(at projectRoot: String) -> Result {
        let result = runCommand(["push"], at: projectRoot, timeout: gitTimeout)
        if result.timedOut {
            return .error("Push timed out")
        }
        if result.status == 0 {
            return .success("Pushed successfully")
        } else {
            let errMsg = result.output.isEmpty
                ? "Push failed"
                : result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .error(errMsg)
        }
    }

    // MARK: - Commit Message Generation

    /// Result from `generateCommitMessage` — carries the parsed message on
    /// success and stderr on failure so the caller can surface the real reason.
    struct CommitMessageResult {
        let message: String?
        let stderr: String?
    }

    /// Generate a commit message using the on-device Foundation Models framework
    /// (Apple Intelligence). Uses guided generation (@Generable) to guarantee a
    /// structurally valid response — no JSON parsing or shell-out needed.
    ///
    /// The on-device model is small (~3B params, 4096-token context) and there
    /// is no cloud/server Apple model exposed to third-party apps (verified
    /// against the macOS 27 beta SDK), so quality comes from feeding it well:
    /// - `--stat` summary so it sees the FULL scope even when hunks are cut
    /// - per-file truncated hunks instead of a blind prefix of the whole diff
    ///   (a blind prefix showed only the first file or two on real commits)
    /// - recent commit subjects so it matches the repo's style
    ///
    /// Requires macOS 26+ with Apple Intelligence enabled. On older OSes or
    /// when the model is unavailable, returns an error so the caller can surface
    /// it in the sidebar.
    static func generateCommitMessage(at projectRoot: String) -> CommitMessageResult {
        // Byte-capped: a large staged diff used to deadlock here because the
        // old runner waited for git to exit before draining the pipe.
        let diffResult = runCommand(
            ["diff", "--cached"],
            at: projectRoot,
            timeout: gitTimeout,
            maxBytes: diffMaxBytes
        )
        if diffResult.timedOut {
            return CommitMessageResult(message: nil, stderr: "Reading staged diff timed out")
        }
        // Truncation kills git mid-stream (non-zero status) but we still have
        // usable prefix bytes. Only a real failure with no output is fatal.
        let diffUsable = !diffResult.output.isEmpty
            && (diffResult.status == 0 || diffResult.truncated)
        guard diffUsable else {
            return CommitMessageResult(message: nil, stderr: nil)
        }

        // Full-scope summary: file list with change magnitudes.
        let statResult = runCommand(
            ["diff", "--cached", "--stat"], at: projectRoot, timeout: gitTimeout
        )
        let stat = String(statResult.output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(1200))

        // Recent subjects teach the model this repo's conventions.
        let logResult = runCommand(
            ["log", "-5", "--format=%s"], at: projectRoot, timeout: gitTimeout
        )
        let recentSubjects = logResult.status == 0
            ? logResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        var diff = condenseDiff(diffResult.output, budget: 7000, perFileBudget: 1400)
        if diffResult.truncated {
            diff += "\n[... diff truncated for size — see summary above for the full list ...]"
        }

        guard #available(macOS 26.0, *) else {
            return CommitMessageResult(
                message: nil,
                stderr: "On-device AI requires macOS 26 or later"
            )
        }

        return generateCommitMessageWithFoundationModels(
            stat: stat, recentSubjects: recentSubjects, diff: diff
        )
    }

    /// Split a full staged diff into per-file chunks and take the head of
    /// each until the total budget is spent. Every changed file gets some
    /// representation, unlike a blind prefix of the concatenated diff.
    static func condenseDiff(_ fullDiff: String, budget: Int, perFileBudget: Int) -> String {
        let chunks = fullDiff.components(separatedBy: "\ndiff --git ")
        var remaining = budget
        var parts: [String] = []
        var omitted = 0
        for (i, chunk) in chunks.enumerated() {
            guard remaining > 200 else {
                omitted += chunks.count - i
                break
            }
            let restored = i == 0 ? chunk : "diff --git " + chunk
            let take = min(perFileBudget, remaining)
            if restored.count > take {
                parts.append(String(restored.prefix(take)) + "\n[... truncated ...]")
            } else {
                parts.append(restored)
            }
            remaining -= min(restored.count, take)
        }
        var result = parts.joined(separator: "\n")
        if omitted > 0 {
            result += "\n[... \(omitted) more files omitted — see summary above for the full list ...]"
        }
        return result
    }

    /// macOS 26+ implementation using the FoundationModels framework.
    /// Separated so the caller can gate on availability without polluting the
    /// main code path with `@available` annotations on every line.
    @available(macOS 26.0, *)
    private static func generateCommitMessageWithFoundationModels(
        stat: String, recentSubjects: String, diff: String
    ) -> CommitMessageResult {
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            let reason: String
            switch model.availability {
            case .unavailable(.deviceNotEligible):
                reason = "device not eligible for Apple Intelligence"
            case .unavailable(.appleIntelligenceNotEnabled):
                reason = "Apple Intelligence is not enabled in System Settings"
            case .unavailable(.modelNotReady):
                reason = "on-device model is not ready (still downloading)"
            case .unavailable(let other):
                reason = "on-device model unavailable: \(other)"
            default:
                reason = "unknown"
            }
            return CommitMessageResult(message: nil, stderr: reason)
        }

        let session = LanguageModelSession(instructions: """
            You write concise git commit messages. \
            Use lowercase, imperative mood. If you can identify the subsystem \
            from file paths, prefix the subject with it (e.g. 'macos: fix tab rendering'). \
            The subject must name the dominant change and why it matters — never \
            vague filler like 'update files' or 'make changes', and never a list \
            of file names. Match the style of the repo's recent commit subjects \
            when they are provided. Include a body after a blank line only if \
            the changes warrant explanation. Keep the subject under 72 characters.
            """)

        var prompt = "Write a git commit message for these staged changes.\n"
        if !recentSubjects.isEmpty {
            prompt += "\nRecent commit subjects in this repo (match their style):\n\(recentSubjects)\n"
        }
        if !stat.isEmpty {
            prompt += "\nAll changed files:\n\(stat)\n"
        }
        prompt += "\nDiff (long files truncated):\n\(diff)"

        // Bridge async → sync with a 30-second timeout, matching the
        // previous claude CLI implementation's timeout behavior.
        let done = DispatchSemaphore(value: 0)
        var result: CommitMessageResult!

        Task {
            defer { done.signal() }
            do {
                // Low temperature: commit messages should be deterministic
                // descriptions, not creative writing.
                let options = GenerationOptions(temperature: 0.3)
                let response = try await session.respond(
                    to: prompt, generating: CommitMessageOutput.self, options: options
                )
                let msg = response.content.message
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                result = CommitMessageResult(
                    message: msg.isEmpty ? nil : msg, stderr: nil
                )
            } catch {
                result = CommitMessageResult(
                    message: nil,
                    stderr: "Foundation Models error: \(error.localizedDescription)"
                )
            }
        }

        if done.wait(timeout: .now() + .seconds(30)) == .timedOut {
            return CommitMessageResult(
                message: nil, stderr: "on-device model timed out (30s)"
            )
        }
        return result
    }

    /// Structured output type for guided generation of commit messages.
    /// The @Generable macro uses constrained decoding to guarantee the model
    /// produces a valid instance — no manual JSON parsing needed.
    @available(macOS 26.0, *)
    @Generable(description: "A git commit message")
    fileprivate struct CommitMessageOutput {
        @Guide(description: "The full commit message including optional body")
        var message: String
    }

    // MARK: - Process Helpers

    struct CommandResult {
        let output: String
        let status: Int32
        let timedOut: Bool
        let truncated: Bool
    }

    /// Run a git command and return success/failure.
    static func runGit(_ args: [String], at dir: String) -> Bool {
        let result = runCommand(args, at: dir, timeout: gitTimeout)
        return result.status == 0 && !result.timedOut
    }

    /// Run a command and return its output + exit status.
    ///
    /// Kept for call-site compatibility; prefer `runCommand` when timeout or
    /// truncation matters.
    static func runGitOutput(
        _ args: [String], at dir: String, executable: String = "/usr/bin/git"
    ) -> (output: String, status: Int32) {
        let result = runCommand(args, at: dir, executable: executable, timeout: gitTimeout)
        return (result.output, result.timedOut ? 124 : result.status)
    }

    /// Run a command, draining stdout/stderr while it runs so a large write
    /// cannot fill the pipe and deadlock against `waitUntilExit`.
    static func runCommand(
        _ args: [String],
        at dir: String,
        executable: String = "/usr/bin/git",
        timeout: TimeInterval = 60,
        maxBytes: Int? = nil
    ) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: dir)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let state = PipeDrainState(maxBytes: maxBytes)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            state.consume(handle, intoStdout: true)
            if state.shouldStopProcess {
                // Cap hit: stop git so it doesn't keep producing forever.
                if process.isRunning { process.terminate() }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            state.consume(handle, intoStdout: false)
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            finished.signal()
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return CommandResult(output: "", status: 1, timedOut: false, truncated: false)
        }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            if process.isRunning { process.terminate() }
            // Give terminate a moment to deliver EOF to the readers.
            _ = finished.wait(timeout: .now() + .seconds(2))
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        // Final drain: small outputs can finish before the readability handler
        // ever fires, and anything still buffered after terminate lands here.
        state.consumeToEnd(outPipe.fileHandleForReading, intoStdout: true)
        state.consumeToEnd(errPipe.fileHandleForReading, intoStdout: false)

        let snapshot = state.snapshot()
        let output = snapshot.stdout.isEmpty ? snapshot.stderr : snapshot.stdout
        let status: Int32 = timedOut ? 124 : process.terminationStatus
        return CommandResult(
            output: output,
            status: status,
            timedOut: timedOut,
            truncated: snapshot.truncated
        )
    }

    /// Thread-safe accumulator for pipe bytes with an optional cap.
    private final class PipeDrainState: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        private(set) var truncated = false
        private let maxBytes: Int?

        init(maxBytes: Int?) {
            self.maxBytes = maxBytes
        }

        var shouldStopProcess: Bool {
            lock.lock()
            defer { lock.unlock() }
            guard let maxBytes else { return false }
            return truncated || stdout.count >= maxBytes
        }

        func consume(_ handle: FileHandle, intoStdout: Bool) {
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            append(chunk, intoStdout: intoStdout)
        }

        func consumeToEnd(_ handle: FileHandle, intoStdout: Bool) {
            let chunk = handle.readDataToEndOfFile()
            if !chunk.isEmpty {
                append(chunk, intoStdout: intoStdout)
            }
        }

        private func append(_ chunk: Data, intoStdout: Bool) {
            lock.lock()
            defer { lock.unlock() }
            if intoStdout {
                if let maxBytes {
                    let room = max(0, maxBytes - stdout.count)
                    if room == 0 {
                        truncated = true
                        return
                    }
                    if chunk.count > room {
                        stdout.append(chunk.prefix(room))
                        truncated = true
                        return
                    }
                }
                stdout.append(chunk)
            } else {
                // Stderr is only used for error text; keep it bounded.
                let errCap = 64 * 1024
                let room = max(0, errCap - stderr.count)
                if room > 0 {
                    stderr.append(chunk.prefix(room))
                }
            }
        }

        func snapshot() -> (stdout: String, stderr: String, truncated: Bool) {
            lock.lock()
            defer { lock.unlock() }
            let out = String(data: stdout, encoding: .utf8)
                ?? String(decoding: stdout, as: UTF8.self)
            let err = String(data: stderr, encoding: .utf8)
                ?? String(decoding: stderr, as: UTF8.self)
            return (out, err, truncated)
        }
    }
}
