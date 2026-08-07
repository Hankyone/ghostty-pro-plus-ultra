//! Client for `ghostty-keeper`, the per-pane process that owns a pty and its
//! shell so they can outlive us.
//!
//! In keeper mode Ghostty doesn't fork the shell itself. It spawns a keeper,
//! hands it everything the shell needs, and then asks for the pty master back
//! over a unix socket. From that point the master fd is used exactly as if we
//! had opened it ourselves — the socket only carries control messages, so the
//! read thread and write stream are untouched.
//!
//! The keeper outlives us because it leaves our session at startup and holds
//! the master open. That is what lets a pane be picked back up after a quit,
//! and it's also why closing a pane has to go through `kill` here rather than
//! signalling directly: the shell is the keeper's child, not ours.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");

const log = std.log.scoped(.keeper);

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
    @cInclude("errno.h");
    @cInclude("sys/time.h");
    if (builtin.os.tag == .macos) {
        @cInclude("libproc.h");
    }
});

/// The binary we spawn, relative to the resources directory.
const keeper_exe = "ghostty-keeper";

/// Panes that came back to a shell that never stopped.
///
/// The host needs this to tell a resumed pane from a fresh one. Both end up
/// with a keeper and a socket, so the filesystem can't answer it — but only a
/// resumed pane already has the user's work in it, and anything that types
/// into a restored terminal has to leave those alone.
var reattached_mutex: std.Io.Mutex = .init;
var reattached: std.StringHashMapUnmanaged(void) = .{};

/// Deliberately leaks each id. There is one per pane per run, and the answer
/// has to stay available for as long as the pane does.
fn markReattached(pane_id: []const u8) void {
    const alloc = std.heap.page_allocator;
    reattached_mutex.lockUncancelable(global.io());
    defer reattached_mutex.unlock(global.io());
    if (reattached.contains(pane_id)) return;
    const key = alloc.dupe(u8, pane_id) catch return;
    reattached.put(alloc, key, {}) catch alloc.free(key);
}

pub fn wasReattached(pane_id: []const u8) bool {
    reattached_mutex.lockUncancelable(global.io());
    defer reattached_mutex.unlock(global.io());
    return reattached.contains(pane_id);
}

/// How long we wait for a freshly spawned keeper to start listening. Only the
/// very first connect should ever need to retry.
const connect_timeout_ms: usize = 2000;
const connect_poll_ms: usize = 5;

/// Hand the keeper the screen as it stands and leave the shell running.
///
/// Called when the app is going away rather than the pane being closed. The
/// blob is whatever Ghostty's formatter produced; the keeper stores it
/// without looking inside and returns it to whoever attaches next, which may
/// well be a different build of Ghostty after an update.
pub fn detach(session: Session, snapshot: []const u8) bool {
    const sock = connect(session.socket_path) catch {
        log.warn("keeper unreachable at detach; pane keeps running anyway", .{});
        return false;
    };
    defer _ = c.close(sock);

    var header: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &header,
        "{{\"method\":\"detach\",\"len\":{d}}}\n",
        .{snapshot.len},
    ) catch return false;

    if (!writeAll(sock, msg)) return false;
    if (snapshot.len > 0 and !writeAll(sock, snapshot)) return false;

    // Wait for the ack so we know the snapshot landed before we exit — but
    // only for as long as the socket timeout allows. A pane whose screen we
    // couldn't hand over still keeps running; a quit that never finishes is
    // the worse outcome by far.
    var buf: [128]u8 = undefined;
    const n = c.read(sock, &buf, buf.len);
    if (n <= 0) {
        log.warn("keeper did not acknowledge the detach in time", .{});
        return false;
    }
    return std.mem.indexOf(u8, buf[0..@intCast(n)], "\"ok\":true") != null;
}

fn writeAll(fd: c_int, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// A pane held by a keeper.
pub const Session = struct {
    /// The pty master, ours to use directly.
    master: posix.fd_t,

    /// The shell. Not our child — only the keeper can reap it — but valid to
    /// observe and to signal as a last resort.
    shell_pid: c.pid_t,

    /// The keeper itself, which *is* our child until we exit.
    keeper_pid: c.pid_t,

    /// Owned by the caller's arena.
    socket_path: [:0]const u8,

    /// The screen this pane was left with, plus anything it printed while
    /// nobody was attached. Feed it to the terminal before reading the fd.
    /// Empty for a pane that has just been started.
    replay: []const u8 = &.{},

    /// Bytes the keeper had to drop while detached, if the pane produced
    /// more output than it could hold.
    dropped: usize = 0,
};

pub const SpawnOptions = struct {
    /// Where `ghostty-keeper` lives.
    resources_dir: []const u8,

    /// Stable per-pane identifier. This is what lets a later run of Ghostty
    /// find this exact pane again, so it must survive a restart — on macOS
    /// that's the surface UUID the window restoration already persists.
    pane_id: []const u8,

    argv: []const [:0]const u8,

    /// Environment as `KEY=VALUE`, already fully assembled by the caller. The
    /// keeper passes it through untouched.
    env: []const []const u8,

    cwd: ?[]const u8 = null,

    rows: u16 = 24,
    cols: u16 = 80,
    width_px: u16 = 0,
    height_px: u16 = 0,
};

/// Start a keeper for a new pane and attach to it.
pub fn spawn(alloc: Allocator, opts: SpawnOptions) !Session {
    const dir = try socketDir(alloc);
    try ensureDir(dir);

    const socket_path = try std.fmt.allocPrintSentinel(
        alloc,
        "{s}/{s}.sock",
        .{ dir, opts.pane_id },
        0,
    );

    // The new keeper's `listen` unlinks any socket at this path. If something
    // is still holding that inode, unlinking orphans it — invisible to a
    // directory scan, still burning a shell. Displace first.
    _ = killByPaneId(alloc, opts.pane_id);

    const spec = try buildSpec(alloc, socket_path, opts);
    const exe_path = try findKeeper(alloc, opts.resources_dir);
    const keeper_pid = try spawnProcess(alloc, exe_path, spec);
    errdefer _ = c.kill(keeper_pid, c.SIGKILL);

    // The keeper needs a moment to bind before it can answer.
    const session = try connectAndAttach(alloc, socket_path, keeper_pid);
    log.info(
        "keeper attached pane={s} shell_pid={} keeper_pid={}",
        .{ opts.pane_id, session.shell_pid, keeper_pid },
    );
    return session;
}

/// Attach to a keeper that is already running — the reattach path.
pub fn attach(alloc: Allocator, pane_id: []const u8) !Session {
    const dir = try socketDir(alloc);
    const socket_path = try std.fmt.allocPrintSentinel(
        alloc,
        "{s}/{s}.sock",
        .{ dir, pane_id },
        0,
    );

    // No keeper pid: we didn't start this one, it predates us.
    const session = try attachOnce(alloc, socket_path, 0);
    markReattached(pane_id);
    return session;
}

/// Ask the keeper to kill the shell and confirm it's gone. Returns true when
/// the keeper reports the shell dead.
///
/// This is how a deliberate close works in keeper mode. The keeper is the
/// shell's parent, so it is the only process that can actually confirm death
/// rather than assume it.
pub fn kill(alloc: Allocator, session: Session) bool {
    const sock = connect(session.socket_path) catch {
        // No keeper to ask. Fall back to signalling what we know about; we
        // can't confirm the outcome, but leaving it running is worse.
        log.warn("keeper unreachable, signalling shell directly", .{});
        if (session.shell_pid > 0) {
            const pgid = c.getpgid(session.shell_pid);
            if (pgid > 0) {
                _ = c.killpg(pgid, c.SIGKILL);
            } else {
                _ = c.kill(session.shell_pid, c.SIGKILL);
            }
        }
        return false;
    };
    defer _ = c.close(sock);

    const req = "{\"method\":\"kill\"}\n";
    if (c.write(sock, req.ptr, req.len) < 0) return false;

    var buf: [256]u8 = undefined;
    const n = c.read(sock, &buf, buf.len);
    if (n <= 0) return false;

    const dead = std.mem.indexOf(u8, buf[0..@intCast(n)], "\"dead\":true") != null;

    // The keeper exits after answering. Reap it so we don't leave a zombie
    // for as long as we live.
    if (session.keeper_pid > 0) {
        var status: c_int = 0;
        _ = c.waitpid(session.keeper_pid, &status, 0);
    }

    _ = alloc;
    return dead;
}

/// A pane currently being held, as seen from outside the app.
pub const HeldPane = struct {
    /// Caller owns this.
    id: []const u8,
    shell_pid: c.pid_t,

    /// False when the socket is there but nothing answers — a keeper that
    /// died without cleaning up after itself.
    alive: bool,
};

/// Every pane a keeper is currently holding for this user.
///
/// Normally these resolve themselves: reopening Ghostty picks them back up.
/// This exists for when they can't be — if the window state naming a pane is
/// lost, its shell keeps running with nothing able to find it, and there has
/// to be some way to see that and end it.
///
/// Entries come from `.sock` files and from `.pid` files (a keeper whose
/// socket name was stolen still leaves a pidfile, and those used to be
/// invisible here).
pub fn list(alloc: Allocator) ![]HeldPane {
    const dir_path = try socketDir(alloc);
    defer alloc.free(dir_path);

    var dir = std.Io.Dir.openDirAbsolute(
        global.io(),
        dir_path,
        .{ .iterate = true },
    ) catch |err| switch (err) {
        error.FileNotFound => return try alloc.alloc(HeldPane, 0),
        else => return err,
    };
    defer dir.close(global.io());

    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer {
        var kit = seen.keyIterator();
        while (kit.next()) |k| alloc.free(k.*);
        seen.deinit(alloc);
    }

    var out: std.ArrayList(HeldPane) = .empty;
    errdefer {
        for (out.items) |p| alloc.free(p.id);
        out.deinit(alloc);
    }

    var it = dir.iterate();
    while (try it.next(global.io())) |entry| {
        const id = paneIdFromDirEntry(entry.name) orelse continue;
        if (id.len == 0) continue;
        if (seen.contains(id)) continue;
        const owned_id = try alloc.dupe(u8, id);
        try seen.put(alloc, owned_id, {});
        try out.append(alloc, try probePane(alloc, dir_path, owned_id));
    }

    return try out.toOwnedSlice(alloc);
}

fn paneIdFromDirEntry(name: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, name, ".sock")) {
        return name[0 .. name.len - ".sock".len];
    }
    if (std.mem.endsWith(u8, name, ".pid")) {
        return name[0 .. name.len - ".pid".len];
    }
    return null;
}

fn probePane(alloc: Allocator, dir_path: []const u8, id: []const u8) !HeldPane {
    var pane: HeldPane = .{
        .id = try alloc.dupe(u8, id),
        .shell_pid = 0,
        .alive = false,
    };

    const path = try std.fmt.allocPrintSentinel(
        alloc,
        "{s}/{s}.sock",
        .{ dir_path, id },
        0,
    );
    defer alloc.free(path);

    if (connect(path)) |sock| {
        defer _ = c.close(sock);
        const req = "{\"method\":\"hello\"}\n";
        if (c.write(sock, req.ptr, req.len) > 0) {
            var buf: [256]u8 = undefined;
            const n = c.read(sock, &buf, buf.len);
            if (n > 0) {
                pane.alive = true;
                pane.shell_pid = @intCast(parseUint(buf[0..@intCast(n)], "\"shell_pid\":") orelse 0);
            }
        }
    } else |_| {
        // Socket gone or wedged: a live pidfile still means the pane is held.
        if (readPidfile(alloc, dir_path, id)) |keeper_pid| {
            if (processAlive(keeper_pid)) {
                pane.alive = true;
            }
        }
    }

    return pane;
}

/// End every held pane whose id is not in `keep`.
///
/// Used after window restoration: any keeper the restored surfaces did not
/// claim is an orphan left behind by a prior quit or a lost window, and will
/// otherwise sit forever holding a shell nothing can reach.
pub fn reapExcept(alloc: Allocator, keep: []const []const u8) usize {
    const panes = list(alloc) catch return 0;
    defer {
        for (panes) |p| alloc.free(p.id);
        alloc.free(panes);
    }

    var killed: usize = 0;
    for (panes) |pane| {
        if (idInKeep(pane.id, keep)) continue;
        if (killByPaneId(alloc, pane.id)) killed += 1;
    }

    // Directory scan misses keepers whose socket was unlinked and whose
    // pidfile never landed (or was removed). Sweep leftover processes once
    // every kept pane's keeper pid is accounted for, so we never shoot a
    // live tab's keeper we simply failed to identify.
    killed += reapOrphanProcesses(alloc, keep);
    return killed;
}

fn idInKeep(id: []const u8, keep: []const []const u8) bool {
    for (keep) |k| {
        if (std.mem.eql(u8, id, k)) return true;
    }
    return false;
}

/// End a held pane by id, for the case where no window is going to claim it.
pub fn killByPaneId(alloc: Allocator, pane_id: []const u8) bool {
    const dir_path = socketDir(alloc) catch return false;
    defer alloc.free(dir_path);

    const path = std.fmt.allocPrintSentinel(
        alloc,
        "{s}/{s}.sock",
        .{ dir_path, pane_id },
        0,
    ) catch return false;
    defer alloc.free(path);

    var killed = false;

    if (connect(path)) |sock| {
        defer _ = c.close(sock);
        const req = "{\"method\":\"kill\"}\n";
        if (c.write(sock, req.ptr, req.len) >= 0) {
            var buf: [256]u8 = undefined;
            const n = c.read(sock, &buf, buf.len);
            if (n > 0 and std.mem.indexOf(u8, buf[0..@intCast(n)], "\"dead\":true") != null) {
                killed = true;
            }
        }
    } else |_| {}

    // Socket kill is the polite path. If the name was stolen, the inode is
    // gone, or the keeper wedged without answering, the pidfile is how we
    // still find it.
    if (!killed) {
        if (readPidfile(alloc, dir_path, pane_id)) |keeper_pid| {
            if (forceKillPid(keeper_pid)) killed = true;
        }
    }

    _ = c.unlink(path.ptr);
    unlinkPidfile(alloc, dir_path, pane_id);
    return killed;
}

fn readPidfile(alloc: Allocator, dir_path: []const u8, pane_id: []const u8) ?c.pid_t {
    const path = std.fmt.allocPrint(
        alloc,
        "{s}/{s}.pid",
        .{ dir_path, pane_id },
    ) catch return null;
    defer alloc.free(path);

    var file = std.Io.Dir.openFileAbsolute(global.io(), path, .{}) catch return null;
    defer file.close(global.io());

    var buf: [64]u8 = undefined;
    const n = file.readPositionalAll(global.io(), &buf, 0) catch return null;
    if (n == 0) return null;

    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    const pid = std.fmt.parseInt(c.pid_t, trimmed, 10) catch return null;
    if (pid <= 1) return null;
    return pid;
}

fn unlinkPidfile(alloc: Allocator, dir_path: []const u8, pane_id: []const u8) void {
    const path = std.fmt.allocPrintSentinel(
        alloc,
        "{s}/{s}.pid",
        .{ dir_path, pane_id },
        0,
    ) catch return;
    defer alloc.free(path);
    _ = c.unlink(path.ptr);
}

fn processAlive(pid: c.pid_t) bool {
    return c.kill(pid, 0) == 0;
}

fn forceKillPid(pid: c.pid_t) bool {
    if (!processAlive(pid)) return false;
    _ = c.kill(pid, c.SIGTERM);

    var waited: usize = 0;
    while (waited < 500) : (waited += 10) {
        if (!processAlive(pid)) return true;
        _ = c.usleep(10 * 1000);
    }

    _ = c.kill(pid, c.SIGKILL);
    waited = 0;
    while (waited < 500) : (waited += 10) {
        if (!processAlive(pid)) return true;
        _ = c.usleep(10 * 1000);
    }
    return !processAlive(pid);
}

/// Kill `ghostty-keeper` processes we own that do not belong to a kept pane.
///
/// Only runs the aggressive "anything unmapped dies" pass when every kept
/// pane resolves to a keeper pid — otherwise a missing pidfile could make a
/// live tab look like an orphan.
fn reapOrphanProcesses(alloc: Allocator, keep: []const []const u8) usize {
    if (builtin.os.tag != .macos) return 0;

    const dir_path = socketDir(alloc) catch return 0;
    defer alloc.free(dir_path);

    var protected: std.AutoHashMapUnmanaged(c.pid_t, void) = .{};
    defer protected.deinit(alloc);

    var unresolved: usize = 0;
    for (keep) |id| {
        if (resolveKeeperPid(alloc, dir_path, id)) |pid| {
            protected.put(alloc, pid, {}) catch {};
        } else {
            unresolved += 1;
        }
    }

    // Also protect any pid named by a pidfile whose pane id is kept — covers
    // the case where hello failed but the pidfile is honest.
    for (keep) |id| {
        if (readPidfile(alloc, dir_path, id)) |pid| {
            protected.put(alloc, pid, {}) catch {};
        }
    }

    const pids = listKeeperPids(alloc) catch return 0;
    defer alloc.free(pids);

    var killed: usize = 0;
    for (pids) |pid| {
        if (protected.contains(pid)) continue;

        // A pidfile for a non-kept pane: always safe to kill.
        // An unmapped process with no pidfile: only when every keep id
        // resolved, so we know this isn't a live tab we failed to identify.
        const named = paneIdForKeeperPid(alloc, dir_path, pid);
        defer if (named) |id| alloc.free(id);

        if (named) |id| {
            if (idInKeep(id, keep)) {
                protected.put(alloc, pid, {}) catch {};
                continue;
            }
            if (forceKillPid(pid)) {
                unlinkPidfile(alloc, dir_path, id);
                const sock = std.fmt.allocPrintSentinel(
                    alloc,
                    "{s}/{s}.sock",
                    .{ dir_path, id },
                    0,
                ) catch null;
                if (sock) |path| {
                    defer alloc.free(path);
                    _ = c.unlink(path.ptr);
                }
                killed += 1;
            }
            continue;
        }

        if (unresolved == 0 and forceKillPid(pid)) {
            killed += 1;
        }
    }

    return killed;
}

fn resolveKeeperPid(alloc: Allocator, dir_path: []const u8, pane_id: []const u8) ?c.pid_t {
    if (readPidfile(alloc, dir_path, pane_id)) |pid| {
        if (processAlive(pid)) return pid;
    }

    const path = std.fmt.allocPrintSentinel(
        alloc,
        "{s}/{s}.sock",
        .{ dir_path, pane_id },
        0,
    ) catch return null;
    defer alloc.free(path);

    const sock = connect(path) catch return null;
    defer _ = c.close(sock);

    const req = "{\"method\":\"hello\"}\n";
    if (c.write(sock, req.ptr, req.len) <= 0) return null;
    var buf: [256]u8 = undefined;
    const n = c.read(sock, &buf, buf.len);
    if (n <= 0) return null;
    const pid_u = parseUint(buf[0..@intCast(n)], "\"keeper_pid\":") orelse return null;
    const pid: c.pid_t = @intCast(pid_u);
    if (pid <= 1) return null;
    return pid;
}

fn paneIdForKeeperPid(alloc: Allocator, dir_path: []const u8, pid: c.pid_t) ?[]const u8 {
    var dir = std.Io.Dir.openDirAbsolute(
        global.io(),
        dir_path,
        .{ .iterate = true },
    ) catch return null;
    defer dir.close(global.io());

    var it = dir.iterate();
    while (it.next(global.io()) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".pid")) continue;
        const id = entry.name[0 .. entry.name.len - ".pid".len];
        if (readPidfile(alloc, dir_path, id)) |file_pid| {
            if (file_pid == pid) return alloc.dupe(u8, id) catch null;
        }
    }
    return null;
}

fn listKeeperPids(alloc: Allocator) ![]c.pid_t {
    if (builtin.os.tag != .macos) return try alloc.alloc(c.pid_t, 0);

    const uid: u32 = @intCast(c.getuid());
    // First call asks for the buffer size.
    const bytes_needed = c.proc_listpids(c.PROC_UID_ONLY, uid, null, 0);
    if (bytes_needed <= 0) return try alloc.alloc(c.pid_t, 0);

    const cap: usize = @intCast(bytes_needed);
    const raw = try alloc.alloc(c_int, cap / @sizeOf(c_int) + 8);
    defer alloc.free(raw);

    const got = c.proc_listpids(c.PROC_UID_ONLY, uid, raw.ptr, @intCast(raw.len * @sizeOf(c_int)));
    if (got <= 0) return try alloc.alloc(c.pid_t, 0);
    const count: usize = @as(usize, @intCast(got)) / @sizeOf(c_int);

    var out: std.ArrayList(c.pid_t) = .empty;
    errdefer out.deinit(alloc);

    for (raw[0..count]) |pid_i| {
        if (pid_i <= 1) continue;
        if (!isGhosttyKeeper(@intCast(pid_i))) continue;
        try out.append(alloc, @intCast(pid_i));
    }
    return try out.toOwnedSlice(alloc);
}

fn isGhosttyKeeper(pid: c.pid_t) bool {
    if (builtin.os.tag != .macos) return false;
    var path_buf: [c.PROC_PIDPATHINFO_MAXSIZE]u8 = undefined;
    const n = c.proc_pidpath(pid, &path_buf, path_buf.len);
    if (n <= 0) return false;
    const path = path_buf[0..@intCast(n)];
    return std.mem.endsWith(u8, path, "/" ++ keeper_exe) or
        std.mem.eql(u8, path, keeper_exe);
}

// -- internals -------------------------------------------------------------

fn errnoValue() c_int {
    return c.__error().*;
}

/// Locate the keeper binary.
///
/// The resources directory is the obvious answer and usually right, but it
/// isn't always resolvable — a debug build detects it by looking for terminfo,
/// which isn't always where it expects. The keeper ships beside us in the same
/// bundle either way, so fall back to deriving it from our own path rather
/// than failing to start a pane over it.
fn findKeeper(alloc: Allocator, resources_dir: ?[]const u8) ![:0]const u8 {
    if (resources_dir) |dir| {
        if (dir.len > 0) {
            const path = try std.fmt.allocPrintSentinel(
                alloc,
                "{s}/{s}",
                .{ dir, keeper_exe },
                0,
            );
            if (c.access(path.ptr, c.X_OK) == 0) return path;
            alloc.free(path);
        }
    }

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = exe_buf[0 .. std.process.executablePath(
        global.io(),
        &exe_buf,
    ) catch return error.KeeperNotFound];
    const exe_dir = std.fs.path.dirname(exe) orelse return error.KeeperNotFound;

    // Contents/MacOS/ghostty -> Contents/Resources/ghostty/ghostty-keeper, and
    // the plain sibling layout everything else uses.
    for ([_][]const u8{
        "../Resources/ghostty/" ++ keeper_exe,
        keeper_exe,
    }) |rel| {
        const path = try std.fmt.allocPrintSentinel(
            alloc,
            "{s}/{s}",
            .{ exe_dir, rel },
            0,
        );
        if (c.access(path.ptr, c.X_OK) == 0) return path;
        alloc.free(path);
    }

    return error.KeeperNotFound;
}

/// Per-user directory holding one socket per live pane.
///
/// Deliberately short: a unix socket path is capped near 104 bytes, which a
/// long container path plus a UUID would blow straight past.
fn socketDir(alloc: Allocator) ![]const u8 {
    return try std.fmt.allocPrint(
        alloc,
        "/tmp/ghostty-keep-{d}",
        .{c.getuid()},
    );
}

fn ensureDir(dir: []const u8) !void {
    var buf: [512]u8 = undefined;
    if (dir.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = 0;

    if (c.mkdir(@ptrCast(&buf), 0o700) != 0) {
        // Already existing is the normal case after the first pane.
        if (errnoValue() != c.EEXIST) return error.MakeDirFailed;
    }

    // Owner-only, and ours. The keeper re-checks this before binding, since
    // what it serves over that socket is a live shell.
    if (c.chmod(@ptrCast(&buf), 0o700) != 0) return error.ChmodFailed;

    var st: c.struct_stat = undefined;
    if (c.lstat(@ptrCast(&buf), &st) != 0) return error.StatFailed;
    if (st.st_uid != c.getuid()) return error.SocketDirNotOurs;
}

/// Build the JSON spawn spec. Written by hand rather than through a
/// serializer so the wire format is visible in one place — an old keeper has
/// to keep parsing what a newer Ghostty sends.
fn buildSpec(
    alloc: Allocator,
    socket_path: []const u8,
    opts: SpawnOptions,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, "{\"socket_path\":");
    try appendJsonString(alloc, &out, socket_path);

    try out.appendSlice(alloc, ",\"argv\":[");
    for (opts.argv, 0..) |arg, i| {
        if (i > 0) try out.append(alloc, ',');
        try appendJsonString(alloc, &out, arg);
    }

    try out.appendSlice(alloc, "],\"env\":[");
    for (opts.env, 0..) |e, i| {
        if (i > 0) try out.append(alloc, ',');
        try appendJsonString(alloc, &out, e);
    }
    try out.append(alloc, ']');

    if (opts.cwd) |cwd| {
        try out.appendSlice(alloc, ",\"cwd\":");
        try appendJsonString(alloc, &out, cwd);
    }

    const tail = try std.fmt.allocPrint(
        alloc,
        ",\"rows\":{d},\"cols\":{d},\"width_px\":{d},\"height_px\":{d}}}",
        .{ opts.rows, opts.cols, opts.width_px, opts.height_px },
    );
    try out.appendSlice(alloc, tail);

    return try out.toOwnedSlice(alloc);
}

fn appendJsonString(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    s: []const u8,
) !void {
    try out.append(alloc, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => if (ch < 0x20) {
            const esc = try std.fmt.allocPrint(alloc, "\\u{x:0>4}", .{ch});
            try out.appendSlice(alloc, esc);
        } else {
            try out.append(alloc, ch);
        },
    };
    try out.append(alloc, '"');
}

/// Fork and exec the keeper, feeding it the spec on stdin.
fn spawnProcess(alloc: Allocator, exe_path: [:0]const u8, spec: []const u8) !c.pid_t {
    _ = alloc;

    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.PipeFailed;
    const read_end = fds[0];
    const write_end = fds[1];

    const rc = posix.system.fork();
    const pid: c.pid_t = switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => {
            _ = c.close(read_end);
            _ = c.close(write_end);
            return error.ForkFailed;
        },
    };

    if (pid == 0) {
        // Child. The spec arrives on stdin; stdout and stderr stay inherited
        // so keeper logs land wherever ours do.
        _ = c.close(write_end);
        _ = c.dup2(read_end, 0);
        if (read_end > 2) _ = c.close(read_end);

        const argv = [_:null]?[*:0]const u8{ exe_path.ptr, null };
        const envp = [_:null]?[*:0]const u8{null};
        _ = c.execve(
            exe_path.ptr,
            @ptrCast(@constCast(&argv)),
            @ptrCast(@constCast(&envp)),
        );
        // Carry the reason out in the exit status; there is nothing else left
        // to report with at this point.
        c._exit(@intCast(errnoValue() & 0x7f));
    }

    _ = c.close(read_end);
    defer _ = c.close(write_end);

    var written: usize = 0;
    while (written < spec.len) {
        const n = c.write(write_end, spec[written..].ptr, spec.len - written);
        if (n <= 0) return error.WriteSpecFailed;
        written += @intCast(n);
    }

    return pid;
}

/// Nothing we ask a keeper may block us indefinitely.
///
/// These calls happen on the app thread, including while quitting, and a
/// keeper that is wedged or slow must cost us a moment rather than the ability
/// to exit. Every operation here is a short local round trip, so a couple of
/// seconds is already far beyond generous.
const io_timeout_ms: usize = 2000;

fn setTimeouts(sock: c_int) void {
    var tv: c.struct_timeval = .{
        .tv_sec = @intCast(io_timeout_ms / 1000),
        .tv_usec = @intCast((io_timeout_ms % 1000) * 1000),
    };
    _ = c.setsockopt(sock, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));
    _ = c.setsockopt(sock, c.SOL_SOCKET, c.SO_SNDTIMEO, &tv, @sizeOf(c.struct_timeval));
}

fn connect(path: [:0]const u8) !c_int {
    const sock = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (sock < 0) return error.SocketFailed;
    errdefer _ = c.close(sock);
    setTimeouts(sock);

    var addr: c.sockaddr_un = std.mem.zeroes(c.sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    if (path.len >= addr.sun_path.len) return error.PathTooLong;
    @memcpy(addr.sun_path[0..path.len], path);

    if (c.connect(sock, @ptrCast(&addr), @sizeOf(c.sockaddr_un)) != 0) {
        return error.ConnectFailed;
    }

    return sock;
}

/// Connect with a bounded retry, for the window between spawning a keeper and
/// it binding its socket.
fn connectAndAttach(
    alloc: Allocator,
    socket_path: [:0]const u8,
    keeper_pid: c.pid_t,
) !Session {
    var waited: usize = 0;
    while (true) {
        if (attachOnce(alloc, socket_path, keeper_pid)) |session| {
            return session;
        } else |err| {
            // A keeper that already died is never going to answer.
            var status: c_int = 0;
            if (c.waitpid(keeper_pid, &status, c.WNOHANG) == keeper_pid) {
                log.err(
                    "keeper exited before it could serve status={} socket={s}",
                    .{ status, socket_path },
                );
                return error.KeeperDied;
            }

            if (waited >= connect_timeout_ms) {
                log.err("keeper never came up: {}", .{err});
                return err;
            }

            _ = c.usleep(connect_poll_ms * 1000);
            waited += connect_poll_ms;
        }
    }
}

/// One attach attempt: ask for the pane and take the fd that comes back.
fn attachOnce(
    alloc: Allocator,
    socket_path: [:0]const u8,
    keeper_pid: c.pid_t,
) !Session {
    const sock = try connect(socket_path);
    defer _ = c.close(sock);

    const req = "{\"method\":\"attach\"}\n";
    if (c.write(sock, req.ptr, req.len) < 0) return error.WriteFailed;

    var buf: [512]u8 = undefined;
    var iov = c.iovec{ .iov_base = &buf, .iov_len = buf.len };

    var ctrl: ControlBuf = std.mem.zeroes(ControlBuf);
    var hdr: c.msghdr = std.mem.zeroes(c.msghdr);
    hdr.msg_iov = @ptrCast(&iov);
    hdr.msg_iovlen = 1;
    hdr.msg_control = @ptrCast(&ctrl);
    hdr.msg_controllen = @sizeOf(ControlBuf);

    const n = c.recvmsg(sock, &hdr, 0);
    if (n <= 0) return error.RecvFailed;
    if (ctrl.kind != c.SCM_RIGHTS) return error.NoPaneReturned;

    const master = ctrl.fd;

    // Ours now, and it must not leak into any shell we start later.
    _ = c.fcntl(master, c.F_SETFD, c.FD_CLOEXEC);

    const got = buf[0..@intCast(n)];
    const line_end = std.mem.indexOfScalar(u8, got, '\n') orelse got.len;
    const head = got[0..line_end];

    // The screen the keeper was holding, plus anything the shell said while
    // nobody was listening. Some of it already arrived with the reply.
    const replay_len = parseUint(head, "\"replay_len\":") orelse 0;
    var replay: []u8 = &.{};
    if (replay_len > 0) {
        replay = try alloc.alloc(u8, replay_len);
        const already = if (line_end < got.len) got[line_end + 1 ..] else got[0..0];
        const from_head = @min(already.len, replay_len);
        @memcpy(replay[0..from_head], already[0..from_head]);

        var off = from_head;
        while (off < replay_len) {
            const r = c.read(sock, replay[off..].ptr, replay_len - off);
            if (r <= 0) return error.ShortReplay;
            off += @intCast(r);
        }
    }

    return .{
        .master = master,
        .shell_pid = @intCast(parseUint(head, "\"shell_pid\":") orelse 0),
        .keeper_pid = keeper_pid,
        .socket_path = socket_path,
        .replay = replay,
        .dropped = parseUint(head, "\"dropped\":") orelse 0,
    };
}

/// Pull a number out of a reply without a JSON parser, so a newer keeper
/// adding fields can't break an older reader.
fn parseUint(reply: []const u8, key: []const u8) ?usize {
    const idx = std.mem.indexOf(u8, reply, key) orelse return null;
    const rest = reply[idx + key.len ..];

    var end: usize = 0;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') end += 1;
    if (end == 0) return null;

    return std.fmt.parseInt(usize, rest[0..end], 10) catch null;
}

/// A control message carrying exactly one fd. Laid out by hand because the
/// CMSG_* macros don't survive translation into Zig.
const ControlBuf = extern struct {
    len: u32,
    level: c_int,
    kind: c_int,
    fd: c_int,
};
