<p align="center">
  <img src="macos/Assets.xcassets/AppIconImage.imageset/macOS-AppIcon-256px-128pt@2x.png" alt="Ghostty Pro Plus Ultra" width="128">
</p>

<h1 align="center">Ghostty Pro Plus Ultra</h1>

<p align="center">
A personal Ghostty fork with a project-grouped sidebar, AI agent integration, on-device AI commit messages, and quality-of-life improvements for macOS.
</p>

<p align="center">
  <img alt="ghostty-sidebar-claude" src="macos/screenshot.png" />
</p>

## Features

### Project-Grouped Sidebar

A T3 Code-inspired sidebar that replaces the native tab bar. Terminals are automatically grouped by project — detected from `.git`, `package.json`, `Cargo.toml`, and other markers. Each project section shows auto-detected favicons (from Xcode, Android, or web projects), git diff stats, and a collapsible tab list. Ungrouped terminals live in an "Other" section at the bottom.

### AI Agent Integration

Built-in support for Claude Code, Codex, Grok, OpenCode, Devin, Cline, Cursor and Antigravity. The sidebar shows live status for each session: an open ring while the model is reasoning, a square while a tool runs, orange when it is waiting on you, green when a turn finished while you were elsewhere. Hovering names the running tool. Each project header has a button to start a new session there. Sessions are resumed for you when the app restarts, not from a button. See [Agent Status](#agent-status) for which agents report which states.

### Git Integration

Each project header shows live git diff stats (`+N -N`) that update as you edit files, powered by FSEvents file watching with a 2-second debounce. The project menu includes Commit, Push, and Commit & Push actions — commit messages are generated on-device using the Foundation Models framework (Apple Intelligence), so there's no paid API or cloud dependency. Requires macOS 26+ with Apple Intelligence enabled.

### Tab Restore

Browser-like session persistence — quit and reopen, and everything comes back. Working directories, tab titles, colors, sidebar metadata, and agent resume commands are all preserved across restarts.

### Agent Status

No setup. Install an agent, run it in a tab, and the sidebar follows along.

The agent is recognised from the process running in the tab, so nothing has
to be registered and nothing has to announce itself. Its state then comes
from the record it already keeps of its own conversation, which cannot drift
out of sync with what is on screen because it is the same thing you are
reading.

| Agent | Found by | Read from | Reports |
| --- | --- | --- | --- |
| Grok | Working directory | Session event log | Thinking, tool, waiting for you, finished |
| Codex | Working directory | Session event log | Thinking, tool, working, finished, aborted |
| Claude | Session id, from the wrapper below | Session transcript | Thinking, tool, working, finished |
| OpenCode | Working directory | Session database | Working, finished |
| Devin | Working directory | Session database | Running tool, whose turn it is |
| Cline | Working directory | Session database | Working, finished |

Cursor and Antigravity are recognised but not yet read. Cursor keeps its
conversation as a protobuf blob tree and Antigravity marks every step
complete as it writes it, so neither yields a live state cheaply. Both fall
back to the plain process indicator.

Two things worth knowing. An agent writes nothing until you send it a first
prompt, so a freshly opened one has no state to report and the sidebar says
so rather than guessing. And agents found by working directory share a
reading when two tabs sit in the same folder running the same agent.

Reading is cheap by design. One file handle and one kernel watch per live
session, nothing polls, a log read looks only at the tail of the file, and a
database read is a single indexed query.

**Claude only:** a wrapper earlier in `PATH` passes Claude Code a settings
file at launch. It is the one agent whose session is found by id rather than
by folder, which is also what lets it report an approval prompt and the text
of your last message. The wrapper is written automatically, applies only
inside this app, and steps aside if you have wired up ghostty hooks
yourself. It needs `jq`.

> **Upgrading from an older version?** Earlier releases asked you to install
> hooks permanently into `~/.claude/settings.json`. Those fired in every
> terminal on the machine, not just this one. They are removed automatically
> on first launch; only entries pointing at our own scripts are touched, and
> the original file is kept beside it as `settings.json.pre-ghostty-shim`.
> The scripts left in `~/.claude/hooks/` are inert and can be deleted.


### CLI

Install: symlink `cli/ghosttyctl` to somewhere on your PATH (e.g. `~/.local/bin/ghosttyctl`).

```bash
ghosttyctl rename "My Tab"                                    # rename tab
ghosttyctl notify --title "Done" --body "Build finished"      # send notification
ghosttyctl set-status server "localhost:3000" --icon network  # add status entry
ghosttyctl clear-status server                                # remove it
ghosttyctl list                                               # list all tabs
ghosttyctl current                                            # current tab info
```

### Config

```
# Choose which fields to show (default: all)
sidebar-fields = title,directory,git-branch,status
```

### Auto-Update

Built-in Sparkle auto-updates. The app checks for new versions automatically and prompts to install.

## Building

```bash
zig build       # debug build
zig build run   # build and launch
```

See [HACKING.md](HACKING.md) for full build instructions.

## Attribution

This project is built on top of:

- [Ghostty](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto — the original terminal emulator ([ghostty.org](https://ghostty.org))
- [pacaya/ghostty](https://github.com/pacaya/ghostty) (aka [tomreinert/ghostty](https://github.com/tomreinert/ghostty)) — added the sidebar tab system

Not affiliated with the upstream Ghostty project.
