//! What a coin is doing right now, as one line of text — the decision, not the
//! styling.
//!
//! This is the priority ladder both front-ends need and neither should own:
//! installing → not installed → starting/stopping → checking → warming up →
//! waiting for peers → syncing → synced → idle. It lived in `app.zig`, welded to
//! a 2,000-line `Activity`, which is why the GUI grew its own ad-hoc status line
//! instead of the same answer.
//!
//! Everything here is a pure function of `Input`, a plain snapshot. That is
//! deliberate beyond testability: `statusReadout` used to read `daemonState()`
//! and then `awaitingStatus()` read it *again*, two atomic loads that could
//! disagree inside one frame. A snapshot can't.
//!
//! **Text, not presentation.** `Readout.text` is a static, program-lifetime
//! string, and the live log records it verbatim on change — so the appended
//! figures (percentages, heights) are returned separately rather than baked in,
//! or every poll would churn the log with a new "same" status.
//!
//! `PresyncTracker` is the one stateful piece, and it's here rather than in a
//! front-end because deciding whether a node is in Bitcoin Core's presync pass
//! is inference over several polls, not something to re-derive twice.

const std = @import("std");
const models = @import("models.zig");
const warmup = @import("warmup.zig");

/// Whether an install/update is in flight. Narrower than the TUI's own `Phase`,
/// which also tracks finished/failed — those aren't status-line states.
pub const Phase = enum(u8) { idle, downloading, extracting };

/// The daemon's lifecycle, as the front-end understands it.
pub const Daemon = enum(u8) { stopped, starting, running, stopping };

/// Chain sync state.
pub const Sync = enum(u8) { idle, syncing, synced };

/// Front-end-agnostic severity for the status line. The TUI maps this to a
/// `zz.Color`, the GUI to a hex — neither invents its own meaning.
///
/// Note the TUI only actually consults this when `active` is false: an active
/// status reads in the brand colour regardless, so today `warning` and `working`
/// are carried for the GUI's benefit rather than the TUI's.
pub const Tone = enum(u8) { idle, working, warning, ok };

/// Everything the readout reads, as a plain snapshot. One struct rather than a
/// split by which function happens to use which field: `inHeadersPhase` needs
/// `headers_cur` *and* `headers_total`, and splitting those across two structs
/// would mean pre-evaluating the predicate in the caller — which is exactly the
/// policy that shouldn't live in a front-end.
pub const Input = struct {
    installing: Phase = .idle,
    installed: bool = false,
    daemon: Daemon = .stopped,
    /// A start has been asked for but no poll has come back yet, so the daemon's
    /// state genuinely isn't known — distinct from "stopped".
    awaiting_status: bool = false,

    loading_phase: models.LoadingPhase = .none,
    load_stage: warmup.Stage = .none,
    /// Block-loading percentage in basis points, scraped from the daemon's log.
    load_pct_bp: u32 = 0,
    /// Rough time-based estimate for a block-index load, 0 when unknown.
    load_eta_pct: u8 = 0,

    peers: u32 = 0,
    sync: Sync = .idle,
    /// In Bitcoin Core 24+'s throwaway header presync pass (see `PresyncTracker`).
    presync: bool = false,
    /// Presync percentage in basis points, scraped from the daemon's log.
    presync_bp: u32 = 0,

    headers_cur: u64 = 0,
    headers_total: u64 = 0,
    blocks_cur: u64 = 0,
    blocks_total: u64 = 0,
};

/// A coin's live status as plain data: the word(s) for the Status line, the tone
/// they're painted, and whether the state counts as "active" (so the label
/// brightens). The booleans say which figures `suffix` and `height` may append.
pub const Readout = struct {
    text: []const u8,
    tone: Tone,
    active: bool,
    /// The "Pre-synching headers…" line, which takes `presync_bp`.
    presync_pct: bool = false,
    /// The "Loading/Processing blocks…" lines, which take `load_pct_bp`.
    load_progress: bool = false,
    /// The "Loading block index…" line, which takes the `~NN%` estimate.
    block_index_load: bool = false,
    /// The syncing/synced lines, which take a chain height.
    show_blocks: bool = false,
    /// Set with `show_blocks` on the *syncing* lines only, so the height renders
    /// as progress toward a tip rather than a bare "at N".
    sync_progress: bool = false,
};

/// How far short of the tip a node's headers may sit and still count as caught
/// up on headers.
///
/// A node whose headers are at the tip still reads a few blocks short of the best
/// peer height, because the chain advances and peers announce it before we commit
/// it. Without the slack that permanent last-few-blocks gap pins the headers
/// phase on for the entire full-block download — which is exactly the state a
/// freshly-installed Ergo node is in (headers at the tip, blocks a million
/// behind). Real header sync is thousands-to-millions short, far outside this, so
/// the slack only ever reclassifies the tail of the headers phase.
pub const header_tip_slack: u64 = 100;

/// Whether the node is still downloading headers, as opposed to catching its
/// blocks up to headers it already has. A 0 total means the tip isn't known yet —
/// treated as block catch-up rather than claiming a headers phase we can't
/// measure.
pub fn inHeadersPhase(in: Input) bool {
    if (in.headers_total == 0) return false;
    return in.headers_cur + header_tip_slack < in.headers_total;
}

/// Resolve a coin's current status. Priority, highest first: installing →
/// not installed → starting/stopping → checking → warm-up phase → waiting for
/// peers → syncing → synced; "Idle" when installed but off.
pub fn readout(in: Input) Readout {
    // An install/update in flight outranks everything: it runs before the daemon
    // exists (and before `installed` flips), so check it first.
    switch (in.installing) {
        .downloading => return .{ .text = "Downloading…", .tone = .working, .active = true },
        .extracting => return .{ .text = "Extracting…", .tone = .working, .active = true },
        .idle => {},
    }

    if (!in.installed) return .{ .text = "Not installed", .tone = .idle, .active = false };

    return switch (in.daemon) {
        .starting => .{ .text = "Starting…", .tone = .working, .active = true },
        .stopping => .{ .text = "Stopping…", .tone = .working, .active = true },
        .stopped => if (in.awaiting_status)
            .{ .text = "Checking…", .tone = .working, .active = true }
        else
            .{ .text = "Idle", .tone = .idle, .active = false },
        .running => if (in.loading_phase != .none) blk: {
            // RPC's "-28" warm-up message only ever says the coarse "Loading
            // block index..." for the whole block-loading window; some daemons
            // (DigiByte) additionally log a finer-grained percentage for two
            // sub-stages debug.log distinguishes but RPC doesn't — say so, and
            // let the caller append the live percentage.
            if (in.loading_phase == .loading and in.load_stage != .none) {
                break :blk .{
                    .text = switch (in.load_stage) {
                        .loading_blocks => "Loading blocks…",
                        .processing_blocks => "Processing blocks…",
                        .none => unreachable,
                    },
                    .tone = .warning,
                    .active = true,
                    .load_progress = true,
                };
            }
            // A NovaCoin-era block-index load has no in-daemon percentage; the
            // caller appends a rough time-based `~NN%` when a prior duration is
            // known.
            if (in.loading_phase == .loading_block_index) {
                break :blk .{
                    .text = warmup.phaseText(in.loading_phase),
                    .tone = .warning,
                    .active = true,
                    .block_index_load = true,
                };
            }
            break :blk .{ .text = warmup.phaseText(in.loading_phase), .tone = .warning, .active = true };
        } else if (in.peers == 0)
            .{ .text = "Waiting for peers…", .tone = .warning, .active = true }
        else if (in.sync == .syncing) blk: {
            // Headers stream in first, then blocks validate against them. While
            // the Headers bar is still filling we're downloading headers;
            // otherwise we're catching the blocks up. Within the headers phase, a
            // stalled committed-header height means the node is in Core 24+'s
            // throwaway presync pass — say so, and let the caller append the live
            // percentage, since the bar can't move.
            const in_headers = inHeadersPhase(in);
            const is_presync = in_headers and in.presync;
            break :blk .{
                .text = if (!in_headers)
                    "Syncing blocks…"
                else if (is_presync)
                    "Pre-synching headers…"
                else
                    "Syncing headers…",
                .tone = .working,
                .active = true,
                .presync_pct = is_presync,
                .show_blocks = true,
                .sync_progress = true,
            };
        } else if (in.sync == .synced)
            .{ .text = "Synced", .tone = .ok, .active = true, .show_blocks = true }
        else
            .{ .text = "Running", .tone = .ok, .active = true },
    };
}

/// The figure to append after the status text, into `buf` — " 7.4%" for a
/// presync or block-loading percentage, " ~20%" for the approximate block-index
/// estimate, or "" when there's nothing to add.
///
/// Returned separately from `text` so the logged-on-change status stays a static
/// string: baking a live percentage into it would rewrite the log every poll.
/// The tilde is load-bearing — that estimate is elapsed-time-over-last-run, not
/// real progress, and it holds at 99% rather than claiming done.
pub fn suffix(buf: []u8, in: Input, r: Readout) []const u8 {
    const bp: ?u32 = if (r.presync_pct and in.presync_bp > 0)
        in.presync_bp
    else if (r.load_progress and in.load_pct_bp > 0)
        in.load_pct_bp
    else
        null;
    if (bp) |v| {
        return std.fmt.bufPrint(buf, " {d:.1}%", .{@as(f64, @floatFromInt(v)) / 100.0}) catch "";
    }
    if (r.block_index_load and in.load_eta_pct > 0) {
        return std.fmt.bufPrint(buf, " ~{d}%", .{in.load_eta_pct}) catch "";
    }
    return "";
}

/// The chain height to show alongside the status, as a decision rather than a
/// string — the TUI paints "of" in the coin's brand colour and so needs the
/// pieces, not a sentence.
pub const Height = union(enum) {
    /// Nothing to show (no height known yet, or a state that doesn't take one).
    none,
    /// A bare height: "Synced at 850,123".
    at: u64,
    /// Progress toward a tip: "Syncing blocks… 123,456 of 850,000".
    progress: struct { cur: u64, total: u64 },
};

/// Which height the status line should carry.
///
/// The tip is the larger of the two denominators — block-validation catch-up for
/// bitcoin-style chains, network tip for single-height ones. If neither exceeds
/// the current height yet it falls back to `at`, so the line never reads a
/// nonsensical "N of N". Suppressed entirely until a height is known, which also
/// keeps it off the header-download phase where no block has been validated.
pub fn height(in: Input, r: Readout) Height {
    if (!r.show_blocks or in.blocks_cur == 0) return .none;
    const total = @max(in.blocks_total, in.headers_total);
    if (r.sync_progress and total > in.blocks_cur) {
        return .{ .progress = .{ .cur = in.blocks_cur, .total = total } };
    }
    return .{ .at = in.blocks_cur };
}

/// A rough, time-based progress estimate for a block-index load: elapsed
/// (`now_ns` − `start_ns`, monotonic) as a percentage of `last_ms`, the previous
/// load's duration. 0 when either input is unknown or the clock reads backwards.
/// Otherwise clamped to 1..99 — never 0 once underway, and never 100 (only the
/// daemon actually answering proves it's done), so an overrunning load holds at
/// 99%.
pub fn loadEtaPercent(start_ns: i64, now_ns: i64, last_ms: u32) u8 {
    if (start_ns == 0 or last_ms == 0) return 0;
    const elapsed_ms = @divTrunc(now_ns - start_ns, std.time.ns_per_ms);
    if (elapsed_ms < 0) return 0;
    const pct = @divTrunc(elapsed_ms * 100, @as(i64, last_ms));
    return @intCast(std.math.clamp(pct, 1, 99));
}

/// How many consecutive stalled polls before a non-advancing header height is
/// taken as a presync freeze. One stalled poll is noise — peer latency, or a poll
/// landing just before a header commits.
pub const presync_stall_threshold: u32 = 2;

/// Detects Bitcoin Core 24+'s throwaway header pre-synchronisation pass, across
/// polls.
///
/// During that pass the daemon downloads every header without committing any, so
/// the committed height we display sits still while the node churns through the
/// chain — and RPC exposes no presync height to show instead. Two signals, in
/// priority order:
///
///  1. `debug.log` confirms it directly ("Pre-synchronizing blockheaders…"),
///     which is authoritative where the daemon logs it.
///  2. Otherwise infer it from a *sustained* non-advancing committed height. A
///     real header download jumps by thousands between polls and resets the
///     counter, so a genuine multi-minute freeze still trips within a couple of
///     ticks. Older forks that never log the line (DigiByte) rely on this alone.
///
/// Both are gated on the coin actually having the pass: on a non-Core lineage
/// (Ergo) every header is committed as it arrives, so a height that only creeps
/// forward is a node at the tip with blocks still to fetch — not a freeze.
pub const PresyncTracker = struct {
    prev_headers: u64 = 0,
    stall_polls: u32 = 0,

    /// Fold in one poll's headers and return whether the node is presyncing.
    pub fn update(
        self: *PresyncTracker,
        in: Input,
        /// Whether this coin's lineage has the presync pass at all.
        has_presync: bool,
        /// Whether the daemon's log confirmed it this poll.
        log_confirmed: bool,
    ) bool {
        const in_headers = inHeadersPhase(in);
        const stalled = has_presync and in.peers > 0 and
            in_headers and in.headers_cur <= self.prev_headers;
        self.stall_polls = if (stalled) self.stall_polls + 1 else 0;
        self.prev_headers = in.headers_cur;
        const confirmed = has_presync and in_headers and log_confirmed;
        return confirmed or self.stall_polls >= presync_stall_threshold;
    }
};

test "an install in flight outranks everything else" {
    // It runs before the daemon exists and before `installed` flips, so a
    // downloading coin must not read as "Not installed".
    try std.testing.expectEqualStrings("Downloading…", readout(.{ .installing = .downloading }).text);
    try std.testing.expectEqualStrings("Extracting…", readout(.{ .installing = .extracting }).text);
    try std.testing.expectEqualStrings(
        "Downloading…",
        readout(.{ .installing = .downloading, .installed = true, .daemon = .running }).text,
    );
}

test "the daemon lifecycle states read as themselves" {
    const base: Input = .{ .installed = true };
    try std.testing.expectEqualStrings("Not installed", readout(.{}).text);
    try std.testing.expectEqualStrings("Idle", readout(base).text);
    try std.testing.expectEqualStrings("Starting…", readout(.{ .installed = true, .daemon = .starting }).text);
    try std.testing.expectEqualStrings("Stopping…", readout(.{ .installed = true, .daemon = .stopping }).text);
    // Stopped-but-awaiting is genuinely "we don't know yet", not "off".
    try std.testing.expectEqualStrings(
        "Checking…",
        readout(.{ .installed = true, .daemon = .stopped, .awaiting_status = true }).text,
    );

    // Only the inactive states carry a non-active tone; that pairing is what the
    // TUI's colour rule leans on.
    try std.testing.expect(!readout(.{}).active);
    try std.testing.expect(!readout(base).active);
    try std.testing.expect(readout(.{ .installed = true, .daemon = .starting }).active);
}

test "warm-up outranks peers, and the sub-stage refines the label" {
    const running: Input = .{ .installed = true, .daemon = .running };
    // A loading daemon has no peers yet, but "Waiting for peers…" would be the
    // wrong thing to say — it's busy, not idle.
    var in = running;
    in.loading_phase = .loading_block_index;
    var r = readout(in);
    try std.testing.expect(r.block_index_load);
    try std.testing.expectEqualStrings(warmup.phaseText(.loading_block_index), r.text);

    // The coarse RPC phase refined by what the log says.
    in = running;
    in.loading_phase = .loading;
    in.load_stage = .loading_blocks;
    r = readout(in);
    try std.testing.expectEqualStrings("Loading blocks…", r.text);
    try std.testing.expect(r.load_progress);

    in.load_stage = .processing_blocks;
    try std.testing.expectEqualStrings("Processing blocks…", readout(in).text);

    // No sub-stage: the coarse phase stands.
    in = running;
    in.loading_phase = .loading;
    try std.testing.expectEqualStrings(warmup.phaseText(.loading), readout(in).text);
}

test "the headers phase, presync and block catch-up are told apart" {
    var in: Input = .{ .installed = true, .daemon = .running, .peers = 8, .sync = .syncing };
    // Headers far short of the tip: still downloading headers.
    in.headers_cur = 1000;
    in.headers_total = 900_000;
    in.blocks_cur = 500;
    try std.testing.expectEqualStrings("Syncing headers…", readout(in).text);

    // Same, but the node is in the presync pass.
    in.presync = true;
    const r = readout(in);
    try std.testing.expectEqualStrings("Pre-synching headers…", r.text);
    try std.testing.expect(r.presync_pct);

    // Headers at the tip: now it's blocks catching up, presync flag or not.
    in.headers_cur = 900_000;
    try std.testing.expectEqualStrings("Syncing blocks…", readout(in).text);

    // Within the slack still counts as caught up on headers — an Ergo node sits
    // exactly here, and without it the whole block download would read as a
    // headers phase. (presync off again, or the headers side would say so.)
    in.presync = false;
    in.headers_cur = 900_000 - header_tip_slack + 1;
    try std.testing.expectEqualStrings("Syncing blocks…", readout(in).text);
    in.headers_cur = 900_000 - header_tip_slack - 1;
    try std.testing.expectEqualStrings("Syncing headers…", readout(in).text);

    // An unknown tip is block catch-up, not a headers phase we can't measure.
    in.headers_total = 0;
    try std.testing.expect(!inHeadersPhase(in));
}

test "peers outrank sync, and synced outranks both" {
    var in: Input = .{ .installed = true, .daemon = .running, .sync = .syncing };
    try std.testing.expectEqualStrings("Waiting for peers…", readout(in).text);
    in.peers = 3;
    in.blocks_cur = 10;
    try std.testing.expect(std.mem.startsWith(u8, readout(in).text, "Syncing"));
    in.sync = .synced;
    const r = readout(in);
    try std.testing.expectEqualStrings("Synced", r.text);
    try std.testing.expect(r.show_blocks);
    try std.testing.expect(!r.sync_progress); // a bare height, not "of"
    try std.testing.expectEqual(Tone.ok, r.tone);
}

test "suffix appends only the figure its line actually takes" {
    var buf: [32]u8 = undefined;
    var in: Input = .{ .installed = true, .daemon = .running, .peers = 1, .sync = .syncing };
    in.headers_cur = 10;
    in.headers_total = 900_000;
    in.presync = true;
    in.presync_bp = 744;
    try std.testing.expectEqualStrings(" 7.4%", suffix(&buf, in, readout(in)));

    // Zero means "not scraped yet" — no bogus " 0.0%".
    in.presync_bp = 0;
    try std.testing.expectEqualStrings("", suffix(&buf, in, readout(in)));

    // The approximate estimate wears a tilde, so it can't be read as progress.
    var load: Input = .{ .installed = true, .daemon = .running, .loading_phase = .loading_block_index };
    load.load_eta_pct = 20;
    try std.testing.expectEqualStrings(" ~20%", suffix(&buf, load, readout(load)));
    load.load_eta_pct = 0; // first-ever load: no prior duration to estimate from
    try std.testing.expectEqualStrings("", suffix(&buf, load, readout(load)));

    // A line that takes no figure gets none, however much is set.
    var idle: Input = .{ .installed = true };
    idle.presync_bp = 500;
    idle.load_pct_bp = 500;
    try std.testing.expectEqualStrings("", suffix(&buf, idle, readout(idle)));
}

test "height reads as progress while syncing and a bare figure once synced" {
    var in: Input = .{ .installed = true, .daemon = .running, .peers = 4, .sync = .syncing };
    in.blocks_cur = 123_456;
    in.blocks_total = 850_000;
    in.headers_cur = 850_000;
    in.headers_total = 850_000;
    switch (height(in, readout(in))) {
        .progress => |p| {
            try std.testing.expectEqual(@as(u64, 123_456), p.cur);
            try std.testing.expectEqual(@as(u64, 850_000), p.total);
        },
        else => return error.ExpectedProgress,
    }

    in.sync = .synced;
    switch (height(in, readout(in))) {
        .at => |v| try std.testing.expectEqual(@as(u64, 123_456), v),
        else => return error.ExpectedBareHeight,
    }

    // No total above us yet — "at N" rather than a nonsensical "N of N".
    in.sync = .syncing;
    in.blocks_total = 123_456;
    in.headers_total = 0;
    switch (height(in, readout(in))) {
        .at => |v| try std.testing.expectEqual(@as(u64, 123_456), v),
        else => return error.ExpectedBareHeight,
    }

    // Nothing at all until a height is known, which also keeps it off the
    // header-download phase where no block has been validated.
    in.blocks_cur = 0;
    try std.testing.expectEqual(Height.none, height(in, readout(in)));
    const idle: Input = .{ .installed = true };
    try std.testing.expectEqual(Height.none, height(idle, readout(idle)));
}

test "loadEtaPercent estimates, clamps, and refuses to claim done" {
    const ms = std.time.ns_per_ms;
    // Half way through a run that last took 1000ms.
    try std.testing.expectEqual(@as(u8, 50), loadEtaPercent(1000 * ms, 1500 * ms, 1000));
    // Never 0 once underway, so the line doesn't read as stalled.
    try std.testing.expectEqual(@as(u8, 1), loadEtaPercent(1000 * ms, 1001 * ms, 1000));
    // Never 100: only the daemon answering proves it's done, so an overrun holds.
    try std.testing.expectEqual(@as(u8, 99), loadEtaPercent(1000 * ms, 9000 * ms, 1000));
    // Unknown inputs, and a clock that ran backwards.
    try std.testing.expectEqual(@as(u8, 0), loadEtaPercent(0, 5000 * ms, 1000));
    try std.testing.expectEqual(@as(u8, 0), loadEtaPercent(1000 * ms, 5000 * ms, 0));
    try std.testing.expectEqual(@as(u8, 0), loadEtaPercent(5000 * ms, 1000 * ms, 1000));
}

test "presync needs a sustained stall, not one quiet poll" {
    var t: PresyncTracker = .{};
    var in: Input = .{ .peers = 4, .headers_cur = 1000, .headers_total = 900_000 };

    // First poll just records the height.
    try std.testing.expect(!t.update(in, true, false));
    // One stalled poll is noise — peer latency, or landing just before a commit.
    try std.testing.expect(!t.update(in, true, false));
    // Sustained is the signal.
    try std.testing.expect(t.update(in, true, false));

    // A real header download resets it: thousands of headers between polls.
    in.headers_cur = 400_000;
    try std.testing.expect(!t.update(in, true, false));
}

test "the log confirms presync immediately, but only where the pass exists" {
    var t: PresyncTracker = .{};
    const in: Input = .{ .peers = 4, .headers_cur = 1000, .headers_total = 900_000 };
    // Authoritative: no waiting for a stall to accumulate.
    try std.testing.expect(t.update(in, true, true));

    // A lineage without the pass never presyncs, however still its headers look.
    // On Ergo every header is committed as it arrives, so a creeping height is a
    // node at the tip with blocks to fetch — not a freeze.
    var no: PresyncTracker = .{};
    try std.testing.expect(!no.update(in, false, true));
    try std.testing.expect(!no.update(in, false, false));
    try std.testing.expect(!no.update(in, false, false));
    try std.testing.expect(!no.update(in, false, false));
}

test "presync can't fire outside the headers phase" {
    // Block catch-up isn't presync, even with the log line and a still height —
    // the pass only ever happens before any block is downloaded.
    var t: PresyncTracker = .{};
    const caught_up: Input = .{ .peers = 4, .headers_cur = 900_000, .headers_total = 900_000 };
    try std.testing.expect(!t.update(caught_up, true, true));
    try std.testing.expect(!t.update(caught_up, true, true));
    try std.testing.expect(!t.update(caught_up, true, true));
}
