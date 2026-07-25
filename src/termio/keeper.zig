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
});

/// The binary we spawn, relative to the resources directory.
const keeper_exe = "ghostty-keeper";

/// How long we wait for a freshly spawned keeper to start listening. Only the
/// very first connect should ever need to retry.
const connect_timeout_ms: usize = 2000;
const connect_poll_ms: usize = 5;

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

    const spec = try buildSpec(alloc, socket_path, opts);
    const exe_path = try std.fmt.allocPrintSentinel(
        alloc,
        "{s}/{s}",
        .{ opts.resources_dir, keeper_exe },
        0,
    );

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
    return try attachOnce(alloc, socket_path, 0);
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

// -- internals -------------------------------------------------------------

fn errnoValue() c_int {
    return c.__error().*;
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
        c._exit(127);
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

fn connect(path: [:0]const u8) !c_int {
    const sock = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (sock < 0) return error.SocketFailed;
    errdefer _ = c.close(sock);

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
                log.err("keeper exited before it could serve", .{});
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
    _ = alloc;

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

    return .{
        .master = master,
        .shell_pid = parseShellPid(buf[0..@intCast(n)]) orelse 0,
        .keeper_pid = keeper_pid,
        .socket_path = socket_path,
    };
}

/// Pull the shell pid out of the attach reply without a JSON parser, so a
/// newer keeper adding fields can't break an older reader.
fn parseShellPid(reply: []const u8) ?c.pid_t {
    const key = "\"shell_pid\":";
    const idx = std.mem.indexOf(u8, reply, key) orelse return null;
    var rest = reply[idx + key.len ..];

    var end: usize = 0;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') end += 1;
    if (end == 0) return null;

    return std.fmt.parseInt(c.pid_t, rest[0..end], 10) catch null;
}

/// A control message carrying exactly one fd. Laid out by hand because the
/// CMSG_* macros don't survive translation into Zig.
const ControlBuf = extern struct {
    len: u32,
    level: c_int,
    kind: c_int,
    fd: c_int,
};
