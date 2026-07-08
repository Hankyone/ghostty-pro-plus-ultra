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

    /// Stage all changes, generate a commit message, and commit.
    static func performGitCommit(at projectRoot: String) -> Result {
        // Stage all changes
        guard runGit(["add", "-A"], at: projectRoot) else {
            return .error("Failed to stage changes")
        }

        // Check if there's anything staged
        let diffCheck = runGitOutput(["diff", "--cached", "--quiet"], at: projectRoot)
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

        guard runGit(["commit", "-m", message], at: projectRoot) else {
            return .error("Failed to commit")
        }
        return .success(message)
    }

    /// Push the current branch to its remote.
    static func performGitPush(at projectRoot: String) -> Result {
        let result = runGitOutput(["push"], at: projectRoot)
        if result.status == 0 {
            return .success("Pushed successfully")
        } else {
            let errMsg = result.output.isEmpty ? "Push failed" : result.output.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let diffResult = runGitOutput(["diff", "--cached"], at: projectRoot)
        guard diffResult.status == 0, !diffResult.output.isEmpty else {
            return CommitMessageResult(message: nil, stderr: nil)
        }

        // Full-scope summary: file list with change magnitudes.
        let statResult = runGitOutput(["diff", "--cached", "--stat"], at: projectRoot)
        let stat = String(statResult.output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(1200))

        // Recent subjects teach the model this repo's conventions.
        let logResult = runGitOutput(["log", "-5", "--format=%s"], at: projectRoot)
        let recentSubjects = logResult.status == 0
            ? logResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        let diff = condenseDiff(diffResult.output, budget: 7000, perFileBudget: 1400)

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

    /// Run a git command and return success/failure.
    static func runGit(_ args: [String], at dir: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Run a command and return its output + exit status.
    static func runGitOutput(
        _ args: [String], at dir: String, executable: String = "/usr/bin/git"
    ) -> (output: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        guard (try? process.run()) != nil else { return ("", 1) }
        process.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outData, encoding: .utf8) ?? ""
        let errOutput = String(data: errData, encoding: .utf8) ?? ""
        return (output.isEmpty ? errOutput : output, process.terminationStatus)
    }
}
