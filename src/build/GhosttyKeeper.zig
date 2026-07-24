//! GhosttyKeeper builds the per-pane keeper helper, which holds a pane's pty
//! and shell so they outlive the app.
//!
//! It is deliberately built without SharedDeps. The keeper links nothing but
//! libc: it has to keep working after Ghostty is replaced by a newer build,
//! so the fewer things it shares with the app, the less can drift underneath
//! it.
const GhosttyKeeper = @This();

const std = @import("std");
const Config = @import("Config.zig");

exe: *std.Build.Step.Compile,

pub fn init(b: *std.Build, cfg: *const Config) !GhosttyKeeper {
    const exe = b.addExecutable(.{
        .name = "ghostty-keeper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_keeper.zig"),
            .target = cfg.target,
            .optimize = cfg.optimize,
            .link_libc = true,
        }),
    });

    return .{ .exe = exe };
}

pub fn install(self: *const GhosttyKeeper) void {
    const b = self.exe.step.owner;
    b.installArtifact(self.exe);
}
