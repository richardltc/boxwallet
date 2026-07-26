//! What a daemon is doing while its RPC can't answer yet — shared by both
//! front-ends (TUI and GUI).
//!
//! A bitcoin-derived daemon opens its RPC port long before it can serve a
//! status call, and answers `-28` ("Loading block index…", "Rewinding blocks…",
//! "Verifying blocks…") until it's ready — tens of seconds on a small chain,
//! many minutes on a big one. Reporting "not running" for that whole window is
//! wrong *and* invites a second Start, so both front-ends read the phase out of
//! that `-28` message, refine it from the finer sub-stage lines some daemons log
//! to `debug.log`, and say which stage the daemon is in.

const std = @import("std");
const models = @import("models.zig");
const conf = @import("conf.zig");
const rpc = @import("rpc.zig");
const Coin = @import("coin.zig").Coin;

/// The block-loading sub-stage `debug.log` distinguishes but the `-28` message
/// does not (it says the coarse "Loading block index..." for both).
pub const Stage = enum { none, loading_blocks, processing_blocks };

/// A load sub-stage plus its live percentage, in basis points (1000 ==
/// 10.00%). `.none`/0 when neither line is in the tail.
pub const Progress = struct {
    stage: Stage = .none,
    pct_bp: u32 = 0,
};

/// A daemon's warm-up state: the coarse phase from RPC (or the coin's log
/// marker), the daemon's own wording for it, and the finer sub-stage/percentage
/// when its log carries one. `.none` means not warming up — the daemon is either
/// responsive or down.
pub const Status = struct {
    phase: models.LoadingPhase = .none,
    progress: Progress = .{},
    /// The daemon's own warm-up text ("Loading block index...", "Rewinding
    /// blocks...", "Verifying blocks...", "Loading wallet...", "Activating best
    /// chain..."), copied inline so a `Status` can be returned by value and
    /// outlive the reply it came from. Empty when the daemon gave none.
    ///
    /// Held verbatim rather than folded into `phase`: the enum has one `loading`
    /// value for every "Loading X…" stage, so it can't tell a block-index load
    /// from a wallet load, while these messages walk the user through the whole
    /// start-up. `msg_buf` is sized for the longest of them with room to spare.
    msg_buf: [96]u8 = @splat(0),
    msg_len: u8 = 0,

    /// The daemon's own warm-up text, or empty.
    pub fn message(self: *const Status) []const u8 {
        return self.msg_buf[0..self.msg_len];
    }

    fn setMessage(self: *Status, text: []const u8) void {
        const n = @min(text.len, self.msg_buf.len);
        @memcpy(self.msg_buf[0..n], text[0..n]);
        self.msg_len = @intCast(n);
    }
};

/// Probe `coin`'s warm-up state. Only meaningful while the daemon process is
/// believed to be up (a stopped daemon just refuses the connection and reads as
/// `.none`); coins with no bitcoin-style warm-up (`warmupProbeMethod` null)
/// always read `.none`. Runs entirely on the caller's allocator — one RPC call
/// and one bounded log tail, nothing retained.
pub fn probe(a: std.mem.Allocator, io: std.Io, coin: Coin, home_dir: []const u8) Status {
    const method = coin.warmupProbeMethod() orelse return .{};
    const data_dir = coin.dataDir(a, home_dir) catch return .{};

    var status: Status = .{};
    probe_rpc: {
        const auth = conf.readAuth(
            a,
            io,
            data_dir,
            coin.confFile(),
            coin.rpcDefaultUsername(),
            coin.rpcDefaultPort(),
        ) catch break :probe_rpc;
        // The daemon refuses the connection until its RPC is listening, which is
        // itself part of the start-up — nothing to report yet, so leave `.none`.
        const reply = rpc.call(a, auth, method) catch break :probe_rpc;
        status.phase = rpc.scanLoadingPhase(reply);
        // Only mine the message once the reply is known to be a warm-up one, so
        // an ordinary error reply can't be mistaken for a stage.
        if (status.phase != .none) {
            var msg_buf: [96]u8 = undefined;
            status.setMessage(rpc.scanWarmupMessage(reply, &msg_buf));
        }
    }

    // Both the block-index-load window and its finer sub-stages surface only in
    // debug.log, so read the tail once and mine both from it. A generous tail: a
    // NovaCoin daemon (SpiderByte) has its RPC up during the load, so status
    // polls each append a "ThreadRPCServer method=getinfo" line — minutes of
    // that spam accrues after the "Loading block index…" marker, so a small tail
    // would lose it partway through a long load.
    var log_buf: [64 * 1024]u8 = undefined;
    const tail = readDebugLogTail(io, data_dir, &log_buf);

    // NovaCoin-era daemons (SpiderByte) predate the `-28` RPC warm-up: their RPC
    // is up during the block-index load but can't serve `getinfo` yet, so the
    // probe above just fails. Let the coin recognise that window from the marker
    // it logs instead.
    if (status.phase == .none) status.phase = coin.warmupPhaseFromLog(tail);

    status.progress = parseLoadProgress(tail);
    return status;
}

/// Read the tail (up to `buf.len` bytes) of the coin's `<datadir>/debug.log` into
/// `buf`, returning the slice actually read — empty on a missing file or any IO
/// hiccup. Bounded by design: the log grows unboundedly, so only the tail is ever
/// read (mirrors `proc.daemonLogReason`).
pub fn readDebugLogTail(io: std.Io, data_dir: []const u8, buf: []u8) []const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, data_dir, .{}) catch return &.{};
    defer dir.close(io);
    var file = dir.openFile(io, "debug.log", .{}) catch return &.{};
    defer file.close(io);
    const stat = file.stat(io) catch return &.{};
    const off = if (stat.size > buf.len) stat.size - buf.len else 0;
    const n = file.readPositionalAll(io, buf, off) catch return &.{};
    return buf[0..n];
}

/// Extract the freshest block-loading sub-stage/percentage from a `debug.log`
/// tail — e.g. `"init message: Loading blocks... 10%"` or
/// `"LoadBlockIndex: Processing blocks... 10%"`. The *last* match of either
/// line wins (the freshest), so a transition from one stage to the other is
/// picked up as soon as it appears in the tail. `.{}` (`.none`/0) if neither
/// line is present.
pub fn parseLoadProgress(tail: []const u8) Progress {
    var found: Progress = .{};
    var it = std.mem.splitScalar(u8, tail, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const stage: Stage = if (std.mem.indexOf(u8, line, "Processing blocks") != null)
            .processing_blocks
        else if (std.mem.indexOf(u8, line, "Loading blocks") != null)
            .loading_blocks
        else
            continue;
        // The figure is the number immediately before the trailing "%", e.g.
        // "Loading blocks... 10%".
        const pct_end = std.mem.lastIndexOfScalar(u8, line, '%') orelse continue;
        var start = pct_end;
        while (start > 0 and (std.ascii.isDigit(line[start - 1]) or line[start - 1] == '.')) start -= 1;
        if (start == pct_end) continue;
        const pct = std.fmt.parseFloat(f64, line[start..pct_end]) catch continue;
        const bp = std.math.clamp(pct * 100.0, 0.0, 10000.0);
        found = .{ .stage = stage, .pct_bp = @intFromFloat(@round(bp)) };
    }
    return found;
}

/// Display text for a warm-up phase alone, without any percentage. `.none` has
/// no text (the daemon is either responsive or down, so no phase is shown).
pub fn phaseText(p: models.LoadingPhase) []const u8 {
    return switch (p) {
        .none => "",
        .loading => "Loading…",
        .rescanning => "Rescanning…",
        .rewinding => "Rewinding…",
        .verifying => "Verifying…",
        .calculating => "Calculating money supply…",
        .loading_block_index => "Loading block index…",
    };
}

/// The one-line label for a warm-up `Status`, written into `buf` — e.g.
/// "Loading blocks… 42.00%", "Rewinding blocks…", "Verifying blocks…". Empty
/// for `.none`. Returns a slice into `buf` (or a static string when there's
/// nothing to format), so it lives as long as the caller's buffer.
///
/// Order of preference, most specific first:
///  1. the sub-stage and live percentage from `debug.log`, where the daemon
///     logs finer progress than its `-28` message reports;
///  2. the daemon's own warm-up wording, which names the exact stage;
///  3. the coarse phase text, for a daemon that gave no message (the
///     log-detected block-index load of a NovaCoin-era daemon).
pub fn label(status: Status, buf: []u8) []const u8 {
    if (status.phase == .loading and status.progress.stage != .none) {
        const text = switch (status.progress.stage) {
            .loading_blocks => "Loading blocks…",
            .processing_blocks => "Processing blocks…",
            .none => unreachable,
        };
        if (status.progress.pct_bp > 0) {
            const pct = @as(f64, @floatFromInt(status.progress.pct_bp)) / 100.0;
            return std.fmt.bufPrint(buf, "{s} {d:.2}%", .{ text, pct }) catch text;
        }
        return text;
    }
    const msg = status.message();
    if (msg.len != 0) return tidyMessage(msg, buf);
    return phaseText(status.phase);
}

/// Present a daemon's warm-up message the way the rest of the UI reads: trailing
/// "..." becomes a single "…", so "Loading block index..." shows as "Loading
/// block index…" alongside "Syncing…" and "Installing…". Returns a slice into
/// `buf`, or `msg` itself when it doesn't fit (nothing is lost either way).
fn tidyMessage(msg: []const u8, buf: []u8) []const u8 {
    const body = std.mem.trimEnd(u8, std.mem.trimEnd(u8, msg, " \t"), ".");
    if (body.len == msg.len) return msg; // no trailing dots to fold
    return std.fmt.bufPrint(buf, "{s}…", .{body}) catch msg;
}

test "the load sub-stage and percentage are scraped from a debug.log tail" {
    const loading = parseLoadProgress("init message: Loading blocks... 10%\n");
    try std.testing.expectEqual(Stage.loading_blocks, loading.stage);
    try std.testing.expectEqual(@as(u32, 1000), loading.pct_bp);

    // The freshest line wins, so a stage transition is picked up immediately.
    const moved = parseLoadProgress(
        \\init message: Loading blocks... 40%
        \\LoadBlockIndex: Processing blocks... 5%
        \\
    );
    try std.testing.expectEqual(Stage.processing_blocks, moved.stage);
    try std.testing.expectEqual(@as(u32, 500), moved.pct_bp);

    try std.testing.expectEqual(Stage.none, parseLoadProgress("nothing here\n").stage);
}

/// A `Status` carrying the daemon's own warm-up wording, as `probe` builds it.
fn statusWith(phase: models.LoadingPhase, msg: []const u8) Status {
    var s: Status = .{ .phase = phase };
    s.setMessage(msg);
    return s;
}

test "the daemon's own wording names the stage, tidied for display" {
    var buf: [96]u8 = undefined;

    // The stages Divi walks through on a normal start, verbatim from its `-28`
    // replies — each one distinct, where `LoadingPhase` folds three of them into
    // the same `.loading`.
    try std.testing.expectEqualStrings(
        "Loading block index…",
        label(statusWith(.loading, "Loading block index..."), &buf),
    );
    try std.testing.expectEqualStrings(
        "Loading wallet…",
        label(statusWith(.loading, "Loading wallet..."), &buf),
    );
    try std.testing.expectEqualStrings(
        "Rewinding blocks…",
        label(statusWith(.rewinding, "Rewinding blocks..."), &buf),
    );
    try std.testing.expectEqualStrings(
        "Verifying blocks…",
        label(statusWith(.verifying, "Verifying blocks..."), &buf),
    );

    // A message with no trailing dots is shown as-is.
    try std.testing.expectEqualStrings(
        "Activating best chain",
        label(statusWith(.loading, "Activating best chain"), &buf),
    );

    // The log's live sub-stage still wins over the coarser message.
    var s = statusWith(.loading, "Loading block index...");
    s.progress = .{ .stage = .loading_blocks, .pct_bp = 1000 };
    try std.testing.expectEqualStrings("Loading blocks… 10.00%", label(s, &buf));
}

test "a warm-up message is scraped out of the daemon's -28 reply" {
    var buf: [96]u8 = undefined;

    // Divi's shape, verified against divid's warm-up replies.
    try std.testing.expectEqualStrings("Loading block index...", rpc.scanWarmupMessage(
        \\{"result":null,"error":{"code":-28,"message":"Loading block index..."},"id":"boxwallet"}
    , &buf));

    // A normal reply carries no message field — nothing to report.
    try std.testing.expectEqualStrings("", rpc.scanWarmupMessage(
        \\{"result":{"blocks":123},"error":null,"id":"boxwallet"}
    , &buf));

    // An escaped quote inside the message doesn't end it early.
    try std.testing.expectEqualStrings("Loading \"foo\" index", rpc.scanWarmupMessage(
        \\{"error":{"code":-28,"message":"Loading \"foo\" index"}}
    , &buf));

    // Truncation is by the caller's buffer, never an overrun.
    var tiny: [7]u8 = undefined;
    try std.testing.expectEqualStrings("Loading", rpc.scanWarmupMessage(
        \\{"error":{"message":"Loading block index..."}}
    , &tiny));
}

test "the label refines the coarse loading phase with the log's sub-stage" {
    var buf: [64]u8 = undefined;

    // No sub-stage known: the plain phase text, as RPC's `-28` reports it.
    try std.testing.expectEqualStrings("Loading…", label(.{ .phase = .loading }, &buf));

    // With a sub-stage the finer wording and its live percentage win.
    try std.testing.expectEqualStrings("Processing blocks… 42.00%", label(.{
        .phase = .loading,
        .progress = .{ .stage = .processing_blocks, .pct_bp = 4200 },
    }, &buf));

    // A percentage-less sub-stage line still refines the wording.
    try std.testing.expectEqualStrings("Loading blocks…", label(.{
        .phase = .loading,
        .progress = .{ .stage = .loading_blocks },
    }, &buf));

    // The distinct phases are reported as themselves — a sub-stage scraped from
    // an older line in the tail must not relabel them.
    try std.testing.expectEqualStrings("Rewinding…", label(.{
        .phase = .rewinding,
        .progress = .{ .stage = .loading_blocks, .pct_bp = 4200 },
    }, &buf));
    try std.testing.expectEqualStrings("Verifying…", label(.{ .phase = .verifying }, &buf));

    // Not warming up: nothing to say.
    try std.testing.expectEqualStrings("", label(.{}, &buf));
}
