//! Mining helpers shared by both front-ends (TUI and GUI).
//!
//! The mining *transport* is per-coin (`nerva.zig` drives the daemon's own
//! `/start_mining`, `/stop_mining`, `/mining_status`). What lives here is the
//! part both front-ends would otherwise each invent: how a hashrate reads, what
//! a failure means in plain language, and how many threads the user may ask for.
//! Two copies of those would drift — the GUI would round differently or accept a
//! thread count the TUI rejects.

const std = @import("std");

/// The machine's logical CPU thread count, bounding the thread prompt (and shown
/// in its hint so the user knows the range). Falls back to 1 when the OS query
/// fails — the safe lower bound.
pub fn cpuThreadCount() u32 {
    const n = std.Thread.getCpuCount() catch return 1;
    return @intCast(std.math.clamp(n, 1, 9999));
}

/// Parse a user-typed thread count, or null if it isn't one this machine can
/// honour. Deliberately rejects rather than clamps: silently turning a typed
/// "16" into 8 would start a different job than the one the user asked for, on
/// hardware where that costs real power.
pub fn parseThreads(text: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, text, " \t");
    const threads = std.fmt.parseInt(u32, trimmed, 10) catch return null;
    if (threads < 1 or threads > cpuThreadCount()) return null;
    return threads;
}

/// Format a hashrate into `buf`: plain H/s below a kilohash, otherwise
/// kH/s / MH/s / GH/s to two decimals. Returns a slice into `buf` — no
/// allocation (callers pass a `[32]u8`).
pub fn formatHashrate(buf: []u8, speed: u64) []const u8 {
    const f = @as(f64, @floatFromInt(speed));
    return if (speed >= 1_000_000_000)
        std.fmt.bufPrint(buf, "{d:.2} GH/s", .{f / 1_000_000_000}) catch "?"
    else if (speed >= 1_000_000)
        std.fmt.bufPrint(buf, "{d:.2} MH/s", .{f / 1_000_000}) catch "?"
    else if (speed >= 1_000)
        std.fmt.bufPrint(buf, "{d:.2} kH/s", .{f / 1_000}) catch "?"
    else
        std.fmt.bufPrint(buf, "{d} H/s", .{speed}) catch "?";
}

/// A human-readable reason for a failed mining start/stop: the error names the
/// user is likely to hit are mapped into plain language; anything unfamiliar
/// passes through verbatim rather than collapsing to a generic "failed".
pub fn failureText(err_name: []const u8) []const u8 {
    if (std.mem.eql(u8, err_name, "DaemonStillSyncing"))
        return "The daemon is still syncing — mining can start once the chain is synced.";
    if (std.mem.eql(u8, err_name, "MiningStartRejected"))
        return "The daemon refused to start mining.";
    if (std.mem.eql(u8, err_name, "MiningStopRejected"))
        return "The daemon refused to stop mining.";
    return err_name;
}

// ---- tests ------------------------------------------------------------------

test "formatHashrate scales at each unit boundary" {
    var buf: [32]u8 = undefined;
    // Below a kilohash the raw integer reads better than "0.99 kH/s".
    try std.testing.expectEqualStrings("0 H/s", formatHashrate(&buf, 0));
    try std.testing.expectEqualStrings("999 H/s", formatHashrate(&buf, 999));
    try std.testing.expectEqualStrings("1.00 kH/s", formatHashrate(&buf, 1_000));
    try std.testing.expectEqualStrings("999.99 kH/s", formatHashrate(&buf, 999_990));
    try std.testing.expectEqualStrings("1.00 MH/s", formatHashrate(&buf, 1_000_000));
    try std.testing.expectEqualStrings("12.34 MH/s", formatHashrate(&buf, 12_340_000));
    try std.testing.expectEqualStrings("1.00 GH/s", formatHashrate(&buf, 1_000_000_000));
}

test "parseThreads accepts 1..cpu threads and rejects everything else" {
    const max = cpuThreadCount();
    var buf: [16]u8 = undefined;

    try std.testing.expectEqual(@as(?u32, 1), parseThreads("1"));
    try std.testing.expectEqual(@as(?u32, 1), parseThreads("  1 ")); // padding is fine
    try std.testing.expectEqual(@as(?u32, max), parseThreads(try std.fmt.bufPrint(&buf, "{d}", .{max})));

    // Out of range in either direction is a rejection, never a silent clamp:
    // starting a different job than the one asked for costs real power.
    try std.testing.expectEqual(@as(?u32, null), parseThreads("0"));
    try std.testing.expectEqual(@as(?u32, null), parseThreads(try std.fmt.bufPrint(&buf, "{d}", .{max + 1})));
    try std.testing.expectEqual(@as(?u32, null), parseThreads("-1"));

    // Not a number at all.
    try std.testing.expectEqual(@as(?u32, null), parseThreads(""));
    try std.testing.expectEqual(@as(?u32, null), parseThreads("   "));
    try std.testing.expectEqual(@as(?u32, null), parseThreads("abc"));
    try std.testing.expectEqual(@as(?u32, null), parseThreads("2x"));
}

test "failureText maps the known reasons and passes the rest through" {
    // "Busy" from the daemon means still syncing — the user should wait, not
    // conclude mining is broken.
    try std.testing.expect(std.mem.startsWith(
        u8,
        failureText("DaemonStillSyncing"),
        "The daemon is still syncing",
    ));
    try std.testing.expectEqualStrings(
        "The daemon refused to start mining.",
        failureText("MiningStartRejected"),
    );
    try std.testing.expectEqualStrings(
        "The daemon refused to stop mining.",
        failureText("MiningStopRejected"),
    );
    // Nothing is swallowed: an unmapped error still shows its name.
    try std.testing.expectEqualStrings("ConnectionRefused", failureText("ConnectionRefused"));
}
