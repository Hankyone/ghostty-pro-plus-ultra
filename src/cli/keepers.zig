const std = @import("std");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const args = @import("args.zig");
const global = @import("../global.zig");
const keeper = @import("../termio/keeper.zig");

pub const Options = struct {
    /// Kill a pane by id, or `all` for every one listed.
    kill: ?[]const u8 = null,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `keepers` command lists the panes still being held for you, and can
/// end them.
///
/// With `pane-keeper` enabled, a pane's shell outlives Ghostty so it can be
/// picked back up next launch. Normally that resolves itself: you reopen
/// Ghostty, the pane comes back, and closing it ends the shell.
///
/// It doesn't resolve itself if the window state that names the pane is ever
/// lost — after a restore failure, say, or turning window restoration off.
/// The shell then keeps running with nothing left that knows how to find it.
/// This is how you find it.
///
/// Flags:
///
///   * `--kill=<id>`: end that pane's shell and let its keeper exit.
///   * `--kill=all`: do that for every pane listed.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc, global.args());
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    var buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(global.io(), &buffer);
    const writer = &stdout_writer.interface;

    const panes = keeper.list(alloc) catch |err| {
        try writer.print("could not read the keeper directory: {}\n", .{err});
        try writer.flush();
        return 1;
    };
    defer {
        for (panes) |p| alloc.free(p.id);
        alloc.free(panes);
    }

    if (panes.len == 0) {
        try writer.writeAll("No panes are being held.\n");
        try writer.flush();
        return 0;
    }

    const kill_all = if (opts.kill) |k| std.mem.eql(u8, k, "all") else false;
    var killed: usize = 0;

    for (panes) |pane| {
        const want_kill = kill_all or
            (opts.kill != null and std.mem.eql(u8, opts.kill.?, pane.id));

        if (!want_kill) {
            if (pane.alive) {
                try writer.print(
                    "{s}  shell {d}\n",
                    .{ pane.id, pane.shell_pid },
                );
            } else {
                try writer.print("{s}  unreachable\n", .{pane.id});
            }
            continue;
        }

        if (keeper.killByPaneId(alloc, pane.id)) {
            killed += 1;
            try writer.print("{s}  killed\n", .{pane.id});
        } else {
            try writer.print("{s}  could not be killed\n", .{pane.id});
        }
    }

    if (opts.kill == null) {
        try writer.print(
            "\n{d} held. Reopen Ghostty to pick them back up, or\n" ++
                "`ghostty +keepers --kill=<id>` to end one.\n",
            .{panes.len},
        );
    } else if (killed == 0) {
        try writer.writeAll("\nNothing matched.\n");
    }

    try writer.flush();
    return 0;
}
