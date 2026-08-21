//! A one-way ratchet over the chain heights a running daemon reports.
//!
//! The network tip is hearsay: it's whatever the peers we happen to be
//! connected to *claim* their height is. Lose the peer that knew the real tip
//! and pick up one that is itself still syncing, and the daemon's answer drops —
//! Salvium is the plain case, since `get_info.target_height` is peer-announced
//! and its `headers` figure *is* that tip (`max(target_height, height)`), so the
//! Headers count visibly counts down and then back up again as peers churn.
//!
//! Nothing about the chain went backwards there; we merely stopped being told
//! about it. So each front-end keeps a high-water mark per daemon run and
//! reports the highest height it has been told about, ignoring a later, lower
//! claim. Once the daemon says it is caught up, the marks snap back to what it
//! reports — a peer that once over-claimed must not be able to hold the gauges
//! short of "Synced" forever.
//!
//! Both front-ends use it: the TUI keeps one per `Activity`, the GUI one per
//! registry index in `Ctx`.

const std = @import("std");
const models = @import("models.zig");

/// Per-daemon-run height marks. Reset (`clear`) whenever the daemon is started
/// or stopped: a fresh run — or a reindex — is entitled to report lower heights.
///
/// Atomic because the poll worker applies it off the UI thread in both
/// front-ends; the marks are independent of each other, so plain monotonic
/// loads/stores are enough (there is nothing to publish alongside them).
pub const Ratchet = struct {
    /// Highest local header height seen this run.
    headers: std.atomic.Value(i64) = .init(0),
    /// Highest peer-announced network height seen this run. Kept apart from
    /// `headers` because for the bitcoin family they are different things — the
    /// local header chain vs. an estimate of the peers' — and letting one raise
    /// the other would claim headers we don't have.
    network: std.atomic.Value(i64) = .init(0),

    pub fn clear(self: *Ratchet) void {
        self.headers.store(0, .monotonic);
        self.network.store(0, .monotonic);
    }

    /// Raise `bs`'s heights to the marks, in place, and take the marks up to
    /// whatever `bs` reports that is higher. Leaves `blocks` alone (a rescan or
    /// a reorg legitimately walks it back) and leaves `verification_progress` /
    /// `seconds_behind` as the daemon reported them — those are its own reading
    /// of its own chain, not a peer's claim about the tip.
    pub fn apply(self: *Ratchet, bs: *models.BlockchainState) void {
        if (bs.synced) {
            // Caught up: the daemon is the authority on its own chain, so the
            // marks follow it down as well as up.
            self.headers.store(@max(bs.headers, 0), .monotonic);
            self.network.store(@max(bs.network_height, 0), .monotonic);
            return;
        }
        bs.headers = raise(&self.headers, bs.headers);
        bs.network_height = raise(&self.network, bs.network_height);
    }

    /// A reported height, floored at the mark. A non-positive report is "not
    /// known" (no peers, or the peer query failed) rather than a low claim, and
    /// stays that way — a front-end that shows "—" for an unknown tip must not
    /// be handed a remembered one instead.
    fn raise(mark: *std.atomic.Value(i64), reported: i64) i64 {
        if (reported <= 0) return reported;
        const high = mark.load(.monotonic);
        if (reported >= high) {
            mark.store(reported, .monotonic);
            return reported;
        }
        return high;
    }
};

const testing = std.testing;

/// A minimal state for the tests below — only the heights matter here.
fn state(blocks: i64, headers: i64, network: i64, synced: bool) models.BlockchainState {
    return .{
        .chain = "mainnet",
        .blocks = blocks,
        .headers = headers,
        .verification_progress = 0,
        .synced = synced,
        .network_height = network,
    };
}

test "a lower tip from a new peer is ignored" {
    var r: Ratchet = .{};
    // Peer that knows the real tip.
    var bs = state(400_000, 600_000, 600_000, false);
    r.apply(&bs);
    try testing.expectEqual(@as(i64, 600_000), bs.headers);

    // That peer goes; the replacement is itself only part-way synced.
    var low = state(400_100, 410_000, 410_000, false);
    r.apply(&low);
    try testing.expectEqual(@as(i64, 600_000), low.headers);
    try testing.expectEqual(@as(i64, 600_000), low.network_height);
    // Blocks are ours, and untouched.
    try testing.expectEqual(@as(i64, 400_100), low.blocks);
}

test "the tip still rises, and the chain growing carries it up" {
    var r: Ratchet = .{};
    var bs = state(400_000, 600_000, 600_000, false);
    r.apply(&bs);
    var higher = state(400_050, 600_010, 600_010, false);
    r.apply(&higher);
    try testing.expectEqual(@as(i64, 600_010), higher.headers);
    try testing.expectEqual(@as(i64, 600_010), higher.network_height);
}

test "an unknown tip stays unknown" {
    var r: Ratchet = .{};
    var bs = state(400_000, 600_000, 600_000, false);
    r.apply(&bs);
    // No peers: the daemon reports no network height at all.
    var none = state(400_000, 599_000, 0, false);
    r.apply(&none);
    try testing.expectEqual(@as(i64, 0), none.network_height);
    try testing.expectEqual(@as(i64, 600_000), none.headers);
}

test "a synced daemon takes the marks back down" {
    var r: Ratchet = .{};
    // A peer over-claimed the tip.
    var bs = state(600_000, 999_999, 999_999, false);
    r.apply(&bs);
    // The daemon says it's caught up at its own, lower height.
    var done = state(600_000, 600_000, 600_000, true);
    r.apply(&done);
    try testing.expectEqual(@as(i64, 600_000), done.headers);
    // And the mark no longer holds the old claim.
    var next = state(600_001, 600_001, 600_001, false);
    r.apply(&next);
    try testing.expectEqual(@as(i64, 600_001), next.headers);
}

test "clear forgets the run" {
    var r: Ratchet = .{};
    var bs = state(400_000, 600_000, 600_000, false);
    r.apply(&bs);
    r.clear();
    var after = state(500, 1_000, 1_000, false);
    r.apply(&after);
    try testing.expectEqual(@as(i64, 1_000), after.headers);
}
