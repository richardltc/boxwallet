const std = @import("std");
const builtin = @import("builtin");
const zz = @import("zigzag");
const app = @import("app.zig");
const App = app.App;
const install = @import("install.zig");
const update = @import("update.zig");
const sigguard = @import("sigguard.zig");

/// Entry point for the BoxWallet Nexa TUI slice.
///
/// 0.16 hands `main` a `std.process.Init` carrying the allocator, io, and
/// environment — exactly what ZigZag's `Program` needs.
pub fn main(init: std.process.Init) !void {
    // First, before any worker thread exists: pin a handler for the signals
    // `std.Io.Threaded` uses. The core builds a `Threaded` per call in a great
    // many places and the poll/action workers run them concurrently, so without
    // this one instance's teardown can leave the process at SIG_DFL and the next
    // cancellation SIGIO kills it outright. See `sigguard.zig`.
    sigguard.install();

    // Before anything draws, apply a self-update staged by a previous session
    // (downloaded + checksum-verified in the background while we last ran). The
    // running binary can't be overwritten in place, so the swap happens here, at
    // launch, and we re-exec into the new binary — the user just restarts.
    applyStagedUpdate(init);

    // Mouse tracking on: the left nav is clickable (and wheel-scrollable). It
    // costs the terminal's own select-to-copy, so `m` turns it back off — see
    // `App.mouse_on`. Defaults must otherwise match ZigZag's.
    var program = try zz.Program(App).initWithOptions(init.gpa, init.io, init.environ_map, .{
        .mouse = true,
    });
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
    _ = @import("version.zig");
    _ = @import("registry.zig");
    _ = @import("sigguard.zig");
    _ = @import("money.zig");
    _ = @import("seed.zig");
    _ = @import("rpc.zig");
    _ = @import("install.zig");
    _ = @import("update.zig");
    _ = @import("disk.zig");
    _ = @import("memory.zig");
    _ = @import("conf.zig");
    _ = @import("proc.zig");
    _ = @import("warmup.zig");
    _ = @import("extwallet.zig");
    _ = @import("mining.zig");
    _ = @import("price.zig");
    _ = @import("coins/nexa.zig");
    _ = @import("coins/divi.zig");
    _ = @import("coins/ergo.zig");
    _ = @import("coins/digibyte.zig");
    _ = @import("coins/zano.zig");
    _ = @import("coins/nerva.zig");
    _ = @import("coins/reddcoin.zig");
    _ = @import("coins/epic.zig");
    _ = @import("coins/salvium.zig");
    _ = @import("coins/monero.zig");
    _ = @import("coins/litecoin.zig");
    _ = @import("coins/bitcoin.zig");
    _ = @import("coins/bitcoinz.zig");
    _ = @import("coins/spiderbyte.zig");
    _ = @import("bzip2.zig");
    _ = @import("bip39.zig");
    _ = @import("qrcode.zig");
    _ = @import("capi.zig");
    _ = @import("app.zig");
}
