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
//!
//! RPC is only half the story, and for some coins none of it. Two sources feed
//! this, in order of authority:
//!
//!  1. **The `-28` reply.** Live by construction — the daemon answered — but only
//!     available once its RPC port is bound, and only from daemons that have the
//!     protocol at all.
//!  2. **The daemon's own log.** Written from the very first stage, so it covers
//!     the window before RPC exists, and it is the *only* source for the epee
//!     family (Monero/Nerva/Salvium/Zano, whose RPC server comes up last), Ergo
//!     and Epic (whose APIs simply refuse the connection until they're up). It
//!     also carries far more than `-28` does: every bitcoin-derived daemon logs
//!     an `init message:` line per stage, and the stages are nothing like uniform
//!     — "Rewinding blocks if needed…", "Loading masternode cache…", "Waiting for
//!     Genesis Block…", "Pruning blockstore…".
//!
//! A log line is history, not a live reply, so a stage mined from one is only
//! reported when the daemon process is actually up (see `daemonAlive`).

const std = @import("std");
const models = @import("models.zig");
const conf = @import("conf.zig");
const rpc = @import("rpc.zig");
const proc = @import("proc.zig");
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

/// Whether `coin` can report a warm-up at all — it either answers the
/// bitcoin-style `-28` probe, or writes a daemon log whose start-up narration we
/// can read. A coin with neither always reads `.none`, so callers can skip the
/// probe entirely.
pub fn supported(coin: Coin) bool {
    return coin.warmupProbeMethod() != null or coin.daemonLogFile() != null;
}

/// Probe `coin`'s warm-up state. Only meaningful while the daemon process is
/// believed to be up (a stopped daemon just refuses the connection and reads as
/// `.none`); coins that report no warm-up at all (`supported` false) always read
/// `.none`. Runs entirely on the caller's allocator — one RPC call and one
/// bounded log tail, nothing retained.
pub fn probe(a: std.mem.Allocator, io: std.Io, coin: Coin, home_dir: []const u8) Status {
    if (!supported(coin)) return .{};
    const data_dir = coin.dataDir(a, home_dir) catch return .{};

    var status: Status = .{};
    probe_rpc: {
        const method = coin.warmupProbeMethod() orelse break :probe_rpc;
        const auth = conf.readAuth(
            a,
            io,
            data_dir,
            coin.confFile(),
            coin.rpcDefaultUsername(),
            coin.rpcDefaultPort(),
        ) catch break :probe_rpc;
        // The daemon refuses the connection until its RPC is listening, which is
        // itself part of the start-up — nothing to report from RPC yet, so leave
        // `.none` and let the log below narrate that window.
        const reply = rpc.call(a, auth, method) catch break :probe_rpc;
        status.phase = rpc.scanLoadingPhase(reply);
        // Only mine the message once the reply is known to be a warm-up one, so
        // an ordinary error reply can't be mistaken for a stage.
        if (status.phase != .none) {
            var msg_buf: [96]u8 = undefined;
            status.setMessage(rpc.scanWarmupMessage(reply, &msg_buf));
        }
    }

    // The daemon's own log is the other half of the story, and for some coins the
    // only half — read the tail once and mine everything from it. A generous
    // tail: a NovaCoin daemon (SpiderByte) has its RPC up during the load, so
    // status polls each append a "ThreadRPCServer method=getinfo" line — minutes
    // of that spam accrues after the "Loading block index…" marker, so a small
    // tail would lose it partway through a long load.
    const log_name = coin.daemonLogFile() orelse return status;
    var log_buf: [64 * 1024]u8 = undefined;
    const tail = readDaemonLogTail(io, data_dir, log_name, &log_buf);

    // RPC said nothing, so fall back to what the daemon wrote down. This covers
    // the window before its RPC port is even bound (the *whole* start-up for the
    // epee family, whose RPC server is the last thing to come up), and a daemon
    // whose conf we can't resolve credentials from.
    if (status.phase == .none) {
        const stage = stageFromLog(coin, tail);
        if (stage.len != 0 and daemonAlive(io, coin)) {
            status.setMessage(stage);
            // Every named stage is a load of *something*; `scanLoadingPhase` only
            // classifies the wordings it knows, so anything else still reports as
            // loading rather than vanishing.
            const p = rpc.scanLoadingPhase(stage);
            status.phase = if (p == .none) .loading else p;
        }
    }

    // NovaCoin-era daemons (SpiderByte) predate the `-28` RPC warm-up: their RPC
    // is up during the block-index load but can't serve `getinfo` yet, so the
    // probe above just fails. Let the coin recognise that window from the marker
    // it logs instead.
    if (status.phase == .none) status.phase = coin.warmupPhaseFromLog(tail);

    status.progress = parseLoadProgress(tail);
    return status;
}

/// The daemon's own wording for the stage it's at, from its log: the coin's own
/// reader if it wires one, else the generic bitcoin-family `init message:` line.
/// Empty when the log shows no start-up in progress.
fn stageFromLog(coin: Coin, tail: []const u8) []const u8 {
    const own = coin.warmupStageFromLog(tail);
    if (own.len != 0) return own;
    return parseInitMessage(tail);
}

/// Whether the daemon process is up, checked *only* to decide whether a stage
/// mined from its log describes now or history.
///
/// An RPC reply is live by construction — the daemon answered. A log line is
/// not: a daemon that died mid-load leaves its last stage on disk forever, and
/// without this a stopped coin would report "Loading blockchain…" indefinitely
/// (`bw_daemon_stage`'s caller reads any stage as "coming up"). Deliberately
/// paid only on the branch that's about to trust the log, never on the common
/// path where RPC already answered.
fn daemonAlive(io: std.Io, coin: Coin) bool {
    return proc.aliveMatching(io, coin.daemonFile(), coin.daemonProcessCmdline());
}

/// Read the tail (up to `buf.len` bytes) of the coin's `<datadir>/<log_name>`
/// into `buf`, returning the slice actually read — empty on a missing file or any
/// IO hiccup. Bounded by design: the log grows unboundedly, so only the tail is
/// ever read (mirrors `proc.daemonLogReason`).
pub fn readDaemonLogTail(io: std.Io, data_dir: []const u8, log_name: []const u8, buf: []u8) []const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, data_dir, .{}) catch return &.{};
    defer dir.close(io);
    var file = dir.openFile(io, log_name, .{}) catch return &.{};
    defer file.close(io);
    const stat = file.stat(io) catch return &.{};
    const off = if (stat.size > buf.len) stat.size - buf.len else 0;
    const n = file.readPositionalAll(io, buf, off) catch return &.{};
    return buf[0..n];
}

/// The prefix every bitcoin-derived daemon writes its current start-up stage
/// behind, e.g. `init message: Rewinding blocks…`. It is the same string the
/// daemon serves over `-28`, but logged from the first stage onwards — including
/// the window before its RPC port is bound.
const init_message_prefix = "init message: ";

/// The freshest `init message:` stage from a bitcoin-family log tail, or empty
/// when the log shows no start-up in progress.
///
/// This is where the detail is. The `-28` reply carries one message at a time and
/// only while RPC is up; the log carries every stage each daemon actually walks
/// through, and they are far from uniform — BitcoinZ spends over a minute in
/// "Rewinding blocks if needed…", Divi narrates "Loading masternode cache…",
/// Nexa "Waiting for Genesis Block…", Litecoin "Pruning blockstore…", ReddCoin
/// "Starting staking threads…". Every one of them is a better answer than a
/// generic "Loading…".
///
/// The *last* message wins, so a stage transition shows up as soon as it's
/// written. "Done loading" is the daemon's own end-of-start-up marker and maps to
/// empty — that's how a finished run's trailing stage doesn't get reported as
/// current. A later run's messages come after it and re-arm normally.
///
/// Two coins keep talking *after* "Done loading" — Litecoin loads its wallet
/// there, ReddCoin starts its staking threads — so their last message is a live
/// stage rather than empty. That's deliberate, not a miss: by then the daemon's
/// RPC is up and answering, so this is only ever consulted if a status call just
/// failed, and "alive, not answering, last said it was loading the wallet" is the
/// most honest thing available. The one cost is a couple of seconds of a *stale*
/// such message at the very start of the next run, before that run writes its own
/// first line.
pub fn parseInitMessage(tail: []const u8) []const u8 {
    var found: []const u8 = "";
    var it = std.mem.splitScalar(u8, tail, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const at = std.mem.indexOf(u8, line, init_message_prefix) orelse continue;
        const msg = std.mem.trim(u8, line[at + init_message_prefix.len ..], " \t");
        if (msg.len == 0) continue;
        found = if (std.mem.startsWith(u8, msg, "Done loading")) "" else msg;
    }
    return found;
}

/// A line a daemon writes during start-up, and the wording to show for it. An
/// empty `text` means "this line ends the start-up" — the daemon finished coming
/// up, or is going down — so there is no stage to report.
///
/// Matched case-insensitively, which the epee family alone makes necessary: the
/// same stage is capitalised differently across it ("core RPC server started ok"
/// for Monero, "Core rpc server started ok" for Zano).
pub const Marker = struct { needle: []const u8, text: []const u8 };

/// The wording for the freshest `markers` line in a log tail, or empty when none
/// matched (or the freshest match ends the start-up).
///
/// The last matching line wins, so a stage transition shows the moment it's
/// written, and a shutdown — or a *previous* run's shutdown — clears back to
/// empty rather than leaving history on screen. Marker order is test order:
/// the first needle to match a line claims it, so a marker whose needle contains
/// another's must come first.
pub fn lastStage(tail: []const u8, markers: []const Marker) []const u8 {
    var found: []const u8 = "";
    var it = std.mem.splitScalar(u8, tail, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        for (markers) |m| {
            if (containsFold(line, m.needle)) {
                found = m.text;
                break;
            }
        }
    }
    return found;
}

/// The epee start-up pipeline, in the order the markers are *tested* (first hit
/// on a line wins) rather than the order they occur.
///
/// The end and shutdown markers come first and map to empty, because they must
/// beat the start-up needles they contain: "Deinitializing core..." contains
/// "initializing core...", so a cleanly stopped daemon would otherwise report
/// itself as initializing forever.
const epee_markers = [_]Marker{
    // Start-up over — the RPC server is what everything else was waiting for.
    .{ .needle = "rpc server started ok", .text = "" },
    .{ .needle = "the daemon will start synchronizing", .text = "" },
    // Shutting down, not starting.
    .{ .needle = "deinitializing", .text = "" },
    .{ .needle = "stopping core rpc server", .text = "" },
    .{ .needle = "stopping cryptonote protocol", .text = "" },
    // Coming up, in pipeline order.
    .{ .needle = "initializing cryptonote protocol", .text = "Initializing protocol…" },
    .{ .needle = "initializing currency protocol", .text = "Initializing protocol…" },
    .{ .needle = "initializing core...", .text = "Initializing core…" },
    .{ .needle = "loading blockchain from", .text = "Loading blockchain…" },
    .{ .needle = "loading checkpoints", .text = "Loading checkpoints…" },
    .{ .needle = "blockchain initialized", .text = "Blockchain loaded…" },
    .{ .needle = "core initialized ok", .text = "Core loaded…" },
    .{ .needle = "initializing p2p server", .text = "Starting P2P server…" },
    .{ .needle = "p2p server initialized ok", .text = "P2P server started…" },
    .{ .needle = "generating ssl certificate", .text = "Generating SSL certificate…" },
    .{ .needle = "initializing core rpc server", .text = "Starting RPC server…" },
    .{ .needle = "rpc server initialized ok", .text = "Starting RPC server…" },
};

/// The freshest start-up stage from an epee-family daemon log (Monero, Nerva,
/// Salvium, Zano), or empty when the log shows no start-up in progress.
///
/// The epee family has no `-28` protocol and brings its RPC server up *last*, so
/// there is nothing to ask and the log is the only source. It narrates the whole
/// sequence: protocol init, core init, the LMDB open (the slow one — minutes on a
/// large chain), checkpoints, p2p, then RPC. Shared by the four coins because the
/// wording is the family's, not any one coin's; each still opts in from its own
/// file, and Nerva has to be *asked* to log it (see its `daemonArgv`).
pub fn epeeStage(tail: []const u8) []const u8 {
    return lastStage(tail, &epee_markers);
}

/// ASCII case-insensitive substring test.
fn containsFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return needle.len == 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
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
/// "Loading blocks… 42.0%", "Rewinding blocks…", "Verifying blocks…". Empty
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
            return std.fmt.bufPrint(buf, "{s} {d:.1}%", .{ text, pct }) catch text;
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

test "the freshest init message is scraped from a bitcoin-family log tail" {
    // BitcoinZ's real sequence — the stages it walks and how long each takes are
    // exactly what the `-28` reply can't show before the RPC port is bound.
    try std.testing.expectEqualStrings("Rewinding blocks if needed...", parseInitMessage(
        \\2026-08-13 09:01:36 init message: Verifying wallet...
        \\2026-08-13 09:01:36 init message: Loading block index...
        \\2026-08-13 09:01:56 init message: Rewinding blocks if needed...
        \\
    ));

    // "Done loading" is the daemon's own end-of-start-up marker: a finished run's
    // last stage must not be reported as if it were current.
    try std.testing.expectEqualStrings("", parseInitMessage(
        \\2026-08-13 09:03:21 init message: Starting network threads...
        \\2026-08-13 09:03:21 init message: Done loading
        \\
    ));

    // Litecoin loads its wallet after "Done loading", so its last message is a
    // live stage rather than empty — see the note on `parseInitMessage`.
    try std.testing.expectEqualStrings("Loading wallet...", parseInitMessage(
        \\2026-06-15T08:27:02Z init message: Starting network threads...
        \\2026-06-15T08:27:02Z init message: Done loading
        \\2026-06-15T08:27:05Z init message: Loading wallet...
        \\
    ));

    // ...and a later run re-arms, since the last message always wins.
    try std.testing.expectEqualStrings("Loading block index...", parseInitMessage(
        \\2026-07-19 14:24:19 init message: Done loading
        \\2026-08-13 09:01:36 init message: Verifying wallet...
        \\2026-08-13 09:01:36 init message: Loading block index...
        \\
    ));

    // The stages are per-coin and nothing like uniform — Divi's masternode work,
    // Nexa's genesis wait, ReddCoin's staking threads, Litecoin's pruning.
    try std.testing.expectEqualStrings("Loading masternode cache...", parseInitMessage(
        "2026-08-12 10:57:28 init message: Loading masternode cache...\n",
    ));
    try std.testing.expectEqualStrings("Waiting for Genesis Block...", parseInitMessage(
        "2026-06-12 12:07:46 init message: Waiting for Genesis Block...\n",
    ));
    try std.testing.expectEqualStrings("Pruning blockstore...", parseInitMessage(
        "2026-06-15T08:27:02Z init message: Pruning blockstore...\n",
    ));

    // Ordinary log traffic carries no stage.
    try std.testing.expectEqualStrings("", parseInitMessage(
        "2026-08-13T08:25:48Z Opening LevelDB in /home/x/.digibyte/chainstate\n",
    ));
    try std.testing.expectEqualStrings("", parseInitMessage(""));
}

test "the epee start-up sequence is read from the daemon's own log" {
    // Verbatim from a live nervad run: the whole start, in order. Each line is
    // the freshest, so feeding progressively longer prefixes walks the labels.
    const start =
        \\2026-08-13 19:15:26.937 INFO Initializing cryptonote protocol...
        \\2026-08-13 19:15:26.937 INFO Cryptonote protocol initialized OK
        \\2026-08-13 19:15:26.937 INFO Initializing core...
        \\2026-08-13 19:15:26.937 INFO Loading blockchain from folder /home/x/.nerva/lmdb ...
        \\2026-08-13 19:15:26.957 INFO Loading checkpoints
        \\2026-08-13 19:15:26.957 INFO Core initialized OK
        \\2026-08-13 19:15:26.957 INFO Initializing p2p server...
        \\2026-08-13 19:15:26.959 INFO p2p server initialized OK
        \\2026-08-13 19:15:26.959 INFO Initializing core RPC server...
        \\2026-08-13 19:15:26.959 INFO Generating SSL certificate
        \\2026-08-13 19:15:28.260 INFO core RPC server initialized OK on port: 17566
        \\
    ;
    try std.testing.expectEqualStrings("Starting RPC server…", epeeStage(start));

    // The LMDB open is the slow one — minutes on a large chain, and the whole
    // reason this exists.
    const loading =
        \\2026-08-13 19:15:26.937 INFO Initializing core...
        \\2026-08-13 19:15:26.937 INFO Loading blockchain from folder /home/x/.nerva/lmdb ...
        \\
    ;
    try std.testing.expectEqualStrings("Loading blockchain…", epeeStage(loading));

    // The RPC server coming up ends the start-up: from here the daemon answers
    // for itself and there is no stage to report.
    try std.testing.expectEqualStrings("", epeeStage(start ++
        "2026-08-13 19:15:28.260\tINFO\tcore RPC server started ok\n"));

    // Zano's wording differs only in case ("Core rpc server started ok"), which
    // is why the markers are matched case-insensitively.
    try std.testing.expectEqualStrings("Loading blockchain…", epeeStage(
        \\2026-Aug-13 19:44:51.017581 Loading blockchain from ./zanotest/blockchain_lmdb_v3
        \\
    ));
    try std.testing.expectEqualStrings("", epeeStage(
        \\2026-Aug-13 19:44:51.934696 [SRV_MAIN]Core rpc server started ok
        \\
    ));

    // A cleanly stopped daemon is not a starting one. "Deinitializing core..."
    // contains "initializing core...", so the shutdown markers have to win.
    try std.testing.expectEqualStrings("", epeeStage(
        \\2026-08-13 16:35:28.479 INFO Stopping core RPC server...
        \\2026-08-13 16:35:28.517 INFO Deinitializing core RPC server...
        \\2026-08-13 16:35:28.518 INFO Deinitializing p2p...
        \\2026-08-13 16:35:28.997 INFO Deinitializing core...
        \\
    ));

    // ...and the run after that shutdown reports normally again.
    try std.testing.expectEqualStrings("Loading blockchain…", epeeStage(
        \\2026-08-13 16:35:28.997 INFO Deinitializing core...
        \\2026-08-13 19:15:26.937 INFO Initializing core...
        \\2026-08-13 19:15:26.937 INFO Loading blockchain from folder /home/x/.nerva/lmdb ...
        \\
    ));

    try std.testing.expectEqualStrings("", epeeStage("nothing to see here\n"));
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
    try std.testing.expectEqualStrings("Loading blocks… 10.0%", label(s, &buf));
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
    try std.testing.expectEqualStrings("Processing blocks… 42.0%", label(.{
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
