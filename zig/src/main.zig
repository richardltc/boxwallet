const std = @import("std");
const builtin = @import("builtin");
const zz = @import("zigzag");
const app = @import("app.zig");
const App = app.App;
const install = @import("install.zig");
const update = @import("update.zig");

/// Entry point for the BoxWallet Nexa TUI slice.
///
/// 0.16 hands `main` a `std.process.Init` carrying the allocator, io, and
/// environment — exactly what ZigZag's `Program` needs.
pub fn main(init: std.process.Init) !void {
    // Before anything draws, apply a self-update staged by a previous session
    // (downloaded + checksum-verified in the background while we last ran). The
    // running binary can't be overwritten in place, so the swap happens here, at
    // launch, and we re-exec into the new binary — the user just restarts.
    applyStagedUpdate(init);

    var program = try zz.Program(App).init(init.gpa, init.io, init.environ_map);
    defer program.deinit();
    try program.run();
}

/// Swap in and re-exec a staged update if one is ready. Best-effort: any failure
/// (no update, no permission to replace the binary, re-exec failure) just falls
/// through and runs the current build. `std.process.replace` does not return on
/// success — the freshly swapped binary takes over this process.
fn applyStagedUpdate(init: std.process.Init) void {
    const home_key = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = init.environ_map.get(home_key) orelse return;
    const root = install.installRoot(init.gpa, home) catch return;
    defer init.gpa.free(root);

    const applied = (update.applyPending(init.gpa, init.io, root, app.app_version) catch return) orelse return;
    // `replace` does not return on success — it replaces this process image with
    // the freshly swapped binary. It only returns (an error) on failure, in which
    // case the binary on disk is already the new one, so the next launch is clean;
    // run the current image for now.
    const err = std.process.replace(init.io, .{ .argv = &.{applied.exe_path} });
    std.log.warn("self-update re-exec failed: {s}", .{@errorName(err)});
    init.gpa.free(applied.exe_path);
}

// Offline unit tests live in the backend modules (no daemon, no TUI needed).
test {
    std.testing.refAllDecls(@This());
    _ = @import("rpc.zig");
    _ = @import("install.zig");
    _ = @import("update.zig");
    _ = @import("disk.zig");
    _ = @import("memory.zig");
    _ = @import("conf.zig");
    _ = @import("coins/nexa.zig");
    _ = @import("coins/divi.zig");
    _ = @import("coins/ergo.zig");
    _ = @import("coins/digibyte.zig");
    _ = @import("coins/zano.zig");
    _ = @import("coins/nerva.zig");
    _ = @import("coins/reddcoin.zig");
    _ = @import("bzip2.zig");
    _ = @import("app.zig");
}
