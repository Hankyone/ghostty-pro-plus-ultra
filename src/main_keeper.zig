//! ghostty-keeper holds one pane's pty and its shell.
//!
//! Ghostty spawns one of these per pane instead of forking the shell itself.
//! The keeper opens the pty, forks the shell onto it, and keeps the master
//! end open for as long as the shell lives. Ghostty attaches by connecting to
//! the keeper's socket and receiving a duplicate of that master fd, and from
//! there talks to the shell directly — the socket carries control messages
//! only, never terminal traffic.
//!
//! Because the keeper is the one holding the master, the shell survives
//! Ghostty going away for any reason, crash included. Because the keeper is
//! the shell's parent, it can reap it, which is what makes a deliberate close
//! confirmable.
//!
//! It is deliberately dependency-free and boring. A keeper started by one
//! build has to keep talking to the Ghostty that replaces it after an update,
//! so the less it knows, the less there is to break across versions.
//!
//! It reads its spawn spec as one JSON object on stdin, so nothing depends on
//! argv handling, and speaks newline-delimited JSON on its socket.

const std = @import("std");
const posix = std.posix;

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/stat.h");
    @cInclude("poll.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
    @cInclude("stdlib.h");
});

/// Declared by hand rather than via `util.h`, which isn't in the header set
/// Zig gives a plain libc executable. The symbol lives in libSystem.
extern "c" fn openpty(
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*]u8,
    termp: ?*anyopaque,
    winp: ?*c.struct_winsize,
) c_int;

/// Longest socket path we'll handle. Well beyond what a unix socket accepts
/// anyway, which is around 100 bytes.
const path_max = 1024;

/// Bumped only for a breaking change. Additive fields must never bump it:
/// an old keeper has to stay usable by a newer app, which is the entire
/// point of the thing surviving updates.
const protocol_version: u32 = 1;

/// Kill timings, mirroring the escalation Ghostty applies itself.
const kill_hup_ms: usize = 500;
const kill_force_ms: usize = 1000;
const kill_poll_ms: usize = 10;

/// How long we sit in poll() before looking at the child again.
const accept_poll_ms: c_int = 250;

const log = std.log.scoped(.keeper);

/// What Ghostty tells us to run. Everything the shell needs is decided by
/// Ghostty and passed through verbatim — the keeper adds nothing of its own,
/// so shell-integration and environment behavior can change without the
/// keeper knowing about it.
const SpawnSpec = struct {
    socket_path: []const u8,
    argv: []const []const u8,
    env: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    rows: u16 = 24,
    cols: u16 = 80,
    width_px: u16 = 0,
    height_px: u16 = 0,
};

/// Everything the keeper owns once it's running.
const Keeper = struct {
    alloc: std.mem.Allocator,
    socket_path: []const u8,

    /// The pty master. We hold this open for the process's whole life; it is
    /// what keeps the shell from seeing a hangup when clients come and go.
    master: c_int,

    /// The shell. Ours, so waitpid is meaningful.
    shell_pid: c_int,

    /// Set once the shell has been reaped.
    exited: bool = false,
    exit_status: c_int = 0,

    listener: c_int = -1,
};

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    // A client vanishing mid-handover must not take us with it, and neither
    // should the app's session going away.
    ignoreSignal(posix.SIG.PIPE);
    ignoreSignal(posix.SIG.HUP);

    const spec_json = try readAll(alloc, 0);
    defer alloc.free(spec_json);

    const parsed = std.json.parseFromSlice(
        SpawnSpec,
        alloc,
        spec_json,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        log.err("bad spawn spec: {}", .{err});
        return error.BadSpawnSpec;
    };
    defer parsed.deinit();
    const spec = parsed.value;

    if (spec.argv.len == 0) return error.BadSpawnSpec;

    // Leave Ghostty's session and process group before doing anything else,
    // so nothing aimed at the app can reach us or the shell. Harmless if we
    // are already a group leader.
    _ = c.setsid();

    var keeper = try start(alloc, spec);
    defer cleanup(&keeper);

    try serve(&keeper);
}

/// Open the pty, fork the shell onto it, and start listening.
fn start(alloc: std.mem.Allocator, spec: SpawnSpec) !Keeper {
    var ws: c.struct_winsize = .{
        .ws_row = spec.rows,
        .ws_col = spec.cols,
        .ws_xpixel = spec.width_px,
        .ws_ypixel = spec.height_px,
    };

    var master: c_int = -1;
    var slave: c_int = -1;
    if (openpty(&master, &slave, null, null, &ws) != 0) {
        log.err("openpty failed errno={}", .{errnoValue()});
        return error.OpenptyFailed;
    }

    // Build the C-side argv/env before forking. Allocation after fork in a
    // multi-threaded parent is how you get a deadlocked child.
    const argv = try dupeArgv(alloc, spec.argv);
    const envp = try dupeArgv(alloc, spec.env);
    const cwd: ?[:0]const u8 = if (spec.cwd) |v|
        try alloc.dupeZ(u8, v)
    else
        null;

    const rc = posix.system.fork();
    const pid: c_int = switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |err| {
            log.err("fork failed err={}", .{err});
            return error.ForkFailed;
        },
    };

    if (pid == 0) {
        // Child. Nothing here may allocate or return.
        _ = c.setsid();
        _ = c.ioctl(slave, c.TIOCSCTTY, @as(c_ulong, 0));
        if (cwd) |dir| _ = c.chdir(dir.ptr);
        _ = c.dup2(slave, 0);
        _ = c.dup2(slave, 1);
        _ = c.dup2(slave, 2);
        if (slave > 2) _ = c.close(slave);
        _ = c.close(master);

        // Restore the default disposition for what we ignored above, so the
        // shell isn't born with signals it never asked to ignore.
        defaultSignal(posix.SIG.PIPE);
        defaultSignal(posix.SIG.HUP);

        _ = c.execve(argv[0].?, @ptrCast(argv.ptr), @ptrCast(envp.ptr));
        c._exit(127);
    }

    // Parent. Drop the slave: while anyone still holds it open the shell can
    // never see the terminal close.
    _ = c.close(slave);

    var keeper: Keeper = .{
        .alloc = alloc,
        .socket_path = spec.socket_path,
        .master = master,
        .shell_pid = pid,
    };

    keeper.listener = try listen(spec.socket_path);
    log.info("keeper up shell_pid={} socket={s}", .{ pid, spec.socket_path });
    return keeper;
}

/// Bind the control socket. The directory is expected to already exist and be
/// owner-only; we still refuse to bind through a symlink or into anything we
/// don't own, because the socket hands out a live terminal.
fn listen(path: []const u8) !c_int {
    if (path.len == 0) return error.BadSocketPath;

    var buf: [path_max]u8 = undefined;
    if (path.len >= buf.len) return error.BadSocketPath;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&buf);

    try checkDirectory(path);

    // A leftover socket from a keeper that died means nothing is listening;
    // taking the name back is safe and the alternative is being unreachable
    // forever.
    _ = c.unlink(path_z);

    const prev_mask = c.umask(0o077);
    defer _ = c.umask(prev_mask);

    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);

    var addr: c.sockaddr_un = std.mem.zeroes(c.sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    if (path.len >= addr.sun_path.len) return error.BadSocketPath;
    @memcpy(addr.sun_path[0..path.len], path);

    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr_un)) != 0) {
        log.err("bind failed errno={}", .{errnoValue()});
        return error.BindFailed;
    }
    if (c.chmod(path_z, 0o600) != 0) return error.ChmodFailed;
    if (c.listen(fd, 8) != 0) return error.ListenFailed;

    return fd;
}

/// Refuse to bind inside a directory that isn't ours and only ours.
fn checkDirectory(path: []const u8) !void {
    const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.BadSocketPath;
    if (idx == 0) return error.BadSocketPath;

    var buf: [path_max]u8 = undefined;
    @memcpy(buf[0..idx], path[0..idx]);
    buf[idx] = 0;

    var st: c.struct_stat = undefined;
    if (c.lstat(@ptrCast(&buf), &st) != 0) return error.SocketDirMissing;
    if ((st.st_mode & c.S_IFMT) != c.S_IFDIR) return error.SocketDirNotDir;
    if (st.st_uid != c.getuid()) return error.SocketDirNotOurs;
    if ((st.st_mode & 0o077) != 0) return error.SocketDirTooOpen;
}

/// Accept and serve control connections until the shell is gone.
fn serve(self: *Keeper) !void {
    while (true) {
        // Reap first: if the shell has exited there is nothing left to hold.
        if (reap(self)) {
            log.info("shell exited status={}", .{self.exit_status});
            return;
        }

        var fds = [_]c.struct_pollfd{.{
            .fd = self.listener,
            .events = c.POLLIN,
            .revents = 0,
        }};
        const n = c.poll(&fds, 1, accept_poll_ms);
        if (n <= 0) continue;

        const client = c.accept(self.listener, null, null);
        if (client < 0) continue;
        defer _ = c.close(client);

        // The fd on the other side of this socket is a live shell: readable
        // output, injectable input. Same-uid is the floor, not the ceiling,
        // but it costs nothing and blocks the obvious case.
        if (!peerIsUs(client)) {
            log.warn("rejecting connection from another user", .{});
            continue;
        }

        handleClient(self, client) catch |err| {
            log.warn("client error: {}", .{err});
        };

        if (self.exited) return;
    }
}

/// Serve one connection until the peer goes away.
fn handleClient(self: *Keeper, client: c_int) !void {
    var buf: [4096]u8 = undefined;
    var len: usize = 0;

    while (true) {
        const n = c.read(client, buf[len..].ptr, buf.len - len);
        if (n <= 0) return; // peer gone
        len += @intCast(n);

        // Handle every complete line we have.
        while (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |idx| {
            const line = buf[0..idx];
            const done = try handleRequest(self, client, line);

            const rest = len - (idx + 1);
            std.mem.copyForwards(u8, buf[0..rest], buf[idx + 1 ..][0..rest]);
            len = rest;

            if (done) return;
        }

        if (len == buf.len) return error.RequestTooLong;
    }
}

const Request = struct {
    method: []const u8,
};

/// Returns true when the connection should be closed afterward.
fn handleRequest(self: *Keeper, client: c_int, line: []const u8) !bool {
    const parsed = std.json.parseFromSlice(
        Request,
        self.alloc,
        line,
        .{ .ignore_unknown_fields = true },
    ) catch {
        try reply(client, "{\"ok\":false,\"error\":\"bad request\"}");
        return false;
    };
    defer parsed.deinit();

    const method = parsed.value.method;

    if (std.mem.eql(u8, method, "hello")) {
        var out: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(
            &out,
            "{{\"ok\":true,\"version\":{d},\"shell_pid\":{d},\"alive\":{}}}",
            .{ protocol_version, self.shell_pid, !self.exited },
        );
        try reply(client, msg);
        return false;
    }

    if (std.mem.eql(u8, method, "attach")) {
        if (self.exited) {
            try reply(client, "{\"ok\":false,\"error\":\"shell exited\"}");
            return true;
        }

        var out: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(
            &out,
            "{{\"ok\":true,\"shell_pid\":{d}}}\n",
            .{self.shell_pid},
        );
        // The fd rides along with the reply so the client can't observe one
        // without the other.
        try sendFd(client, self.master, msg);
        return false;
    }

    if (std.mem.eql(u8, method, "kill")) {
        const dead = killShell(self);
        var out: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(
            &out,
            "{{\"ok\":true,\"dead\":{}}}",
            .{dead},
        );
        try reply(client, msg);
        self.exited = true;
        return true;
    }

    try reply(client, "{\"ok\":false,\"error\":\"unknown method\"}");
    return false;
}

fn reply(client: c_int, msg: []const u8) !void {
    if (c.write(client, msg.ptr, msg.len) < 0) return error.WriteFailed;
    if (c.write(client, "\n", 1) < 0) return error.WriteFailed;
}

/// A control message carrying exactly one fd, laid out by hand because the
/// CMSG_* macros don't survive translation into Zig.
const ControlBuf = extern struct {
    len: u32,
    level: c_int,
    kind: c_int,
    fd: c_int,
};

fn sendFd(sock: c_int, fd: c_int, msg: []const u8) !void {
    var iov = c.iovec{
        .iov_base = @constCast(msg.ptr),
        .iov_len = msg.len,
    };

    var ctrl = ControlBuf{
        .len = @sizeOf(ControlBuf),
        .level = c.SOL_SOCKET,
        .kind = c.SCM_RIGHTS,
        .fd = fd,
    };

    var hdr: c.msghdr = std.mem.zeroes(c.msghdr);
    hdr.msg_iov = @ptrCast(&iov);
    hdr.msg_iovlen = 1;
    hdr.msg_control = @ptrCast(&ctrl);
    hdr.msg_controllen = @sizeOf(ControlBuf);

    if (c.sendmsg(sock, &hdr, 0) < 0) return error.SendFdFailed;
}

/// Kill the shell's process group, escalating the same way Ghostty does, and
/// confirm death by reaping. Being the parent is what makes this answerable.
fn killShell(self: *Keeper) bool {
    if (self.exited) return true;

    const pgid = c.getpgid(self.shell_pid);
    var elapsed: usize = 0;
    while (true) {
        const signal: c_int = if (elapsed < kill_hup_ms) c.SIGHUP else c.SIGKILL;

        if (pgid > 0) {
            _ = c.killpg(pgid, signal);
        } else {
            _ = c.kill(self.shell_pid, signal);
        }

        if (reap(self)) return true;
        if (elapsed >= kill_hup_ms + kill_force_ms) {
            log.warn("shell survived SIGKILL pid={}", .{self.shell_pid});
            return false;
        }

        _ = c.usleep(@intCast(kill_poll_ms * 1000));
        elapsed += kill_poll_ms;
    }
}

/// Non-blocking reap. Returns true once the shell is gone.
fn reap(self: *Keeper) bool {
    if (self.exited) return true;

    var status: c_int = 0;
    const rc = c.waitpid(self.shell_pid, &status, c.WNOHANG);
    if (rc == self.shell_pid) {
        self.exited = true;
        self.exit_status = status;
        return true;
    }

    // -1 means we have no such child: it's gone and someone else reaped it.
    if (rc < 0) {
        self.exited = true;
        return true;
    }

    return false;
}

fn cleanup(self: *Keeper) void {
    if (self.listener >= 0) _ = c.close(self.listener);

    var buf: [path_max]u8 = undefined;
    if (self.socket_path.len < buf.len) {
        @memcpy(buf[0..self.socket_path.len], self.socket_path);
        buf[self.socket_path.len] = 0;
        _ = c.unlink(@ptrCast(&buf));
    }

    _ = c.close(self.master);
}

// -- helpers ---------------------------------------------------------------

fn errnoValue() c_int {
    return c.__error().*;
}

fn ignoreSignal(sig: anytype) void {
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(sig, &sa, null);
}

fn defaultSignal(sig: anytype) void {
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(sig, &sa, null);
}

fn peerIsUs(sock: c_int) bool {
    var uid: c.uid_t = 0;
    var gid: c.gid_t = 0;
    if (c.getpeereid(sock, &uid, &gid) != 0) return false;
    return uid == c.getuid();
}

/// Turn a list of slices into the null-terminated array of C strings that
/// execve wants.
fn dupeArgv(
    alloc: std.mem.Allocator,
    items: []const []const u8,
) ![]?[*:0]const u8 {
    const out = try alloc.alloc(?[*:0]const u8, items.len + 1);
    for (items, 0..) |item, i| out[i] = (try alloc.dupeZ(u8, item)).ptr;
    out[items.len] = null;
    return out;
}

fn readAll(alloc: std.mem.Allocator, fd: c_int) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0..@intCast(n)]);
    }

    return out.toOwnedSlice(alloc);
}
