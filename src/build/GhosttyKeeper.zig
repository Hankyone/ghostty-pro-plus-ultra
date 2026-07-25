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

/// Installed into the resources directory rather than bin, because that is
/// the one place the app can find at runtime on every platform: the macOS
/// Xcode project already copies `share/ghostty` into the bundle, and
/// `resourcesDir` resolves to it.
pub fn install(self: *const GhosttyKeeper) void {
    const b = self.exe.step.owner;
    const step = b.addInstallArtifact(self.exe, .{
        .dest_dir = .{ .override = .{ .custom = "share/ghostty" } },
    });
    b.getInstallStep().dependOn(&step.step);
}
