//! Money in and money out, as text — shared by both front-ends so the TUI and
//! the GUI can never round, group or label the same figure differently.
//!
//! Two kinds of number live here and they are deliberately not the same type:
//!
//! * **Coin amounts** are `f64` at a per-coin fixed number of decimals, because
//!   that is what the daemons report over JSON-RPC.
//! * **Fiat** is integer **cents**, never a float. A parsed USD amount goes
//!   straight to `i64` and stays there — the stablecoin flows mint and redeem
//!   against these figures, and a rounding artifact in a float would be a
//!   rounding artifact in someone's money.
//!
//! Everything formats into a caller-provided buffer and returns a slice into it.
//! No allocation, so these are safe on a render path or behind the C ABI, and
//! nothing crosses a boundary owned by the wrong side.

const std = @import("std");

/// What a balance figure is replaced with while the privacy toggle is on.
///
/// Shared so both front-ends mask with the same thing — and note the rule that
/// goes with it: **mask at format time, never by skipping the fetch**. The
/// balance is still polled while hidden, so unhiding is instant instead of
/// waiting for the next tick, and a front-end that stopped fetching would show a
/// stale figure the moment it unhid.
pub const balance_mask = "********";

/// Parse a typed USD amount ("125", "125.5", "125.50") into integer cents, or
/// null when it isn't a plain non-negative dollars figure (empty, a bare ".",
/// more than 2 decimal places, stray characters, overflow). Integer arithmetic
/// only — money never rides through a float here.
pub fn parseDollarsToCents(text: []const u8) ?i64 {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return null;
    var dollars: []const u8 = t;
    var frac: []const u8 = "";
    if (std.mem.indexOfScalar(u8, t, '.')) |dot| {
        dollars = t[0..dot];
        frac = t[dot + 1 ..];
        if (frac.len > 2) return null;
        if (dollars.len == 0 and frac.len == 0) return null;
    }
    var cents: i64 = 0;
    if (dollars.len > 0) {
        const d = std.fmt.parseInt(i64, dollars, 10) catch return null;
        if (d < 0) return null;
        cents = std.math.mul(i64, d, 100) catch return null;
    }
    if (frac.len > 0) {
        var f = std.fmt.parseInt(i64, frac, 10) catch return null;
        if (f < 0) return null;
        if (frac.len == 1) f *= 10;
        cents = std.math.add(i64, cents, f) catch return null;
    }
    return cents;
}

/// Parse a typed amount into whole units of a token's **finest** denomination,
/// given how many decimal places that token declares.
///
/// Integer in, integer out — never via an `f64`. A token amount is a count of
/// indivisible units the way fiat is a count of cents (see
/// `parseDollarsToCents`, which is this with `decimals` fixed at 2), and
/// routing it through a float would let a rounding artifact decide how much
/// somebody actually sent.
///
/// Returns null for anything not cleanly convertible: non-numeric text, a
/// negative, more fractional digits than the token has decimals (which would
/// mean silently discarding precision the user typed), or a value that
/// overflows `i64`. `decimals == 0` accepts a bare integer only — an NFT has no
/// fractional part to give.
pub fn parseUnits(text: []const u8, decimals: u8) ?i64 {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return null;

    var whole: []const u8 = t;
    var frac: []const u8 = "";
    if (std.mem.indexOfScalar(u8, t, '.')) |dot| {
        whole = t[0..dot];
        frac = t[dot + 1 ..];
        // More places than the token has is a real loss of intent, not a
        // rounding opportunity: say no rather than quietly truncating.
        if (frac.len > decimals) return null;
        if (whole.len == 0 and frac.len == 0) return null;
    }

    // 10^decimals, built by repeated multiply so an absurd `decimals` overflows
    // here rather than producing a nonsense scale.
    var scale: i64 = 1;
    for (0..decimals) |_| scale = std.math.mul(i64, scale, 10) catch return null;

    var units: i64 = 0;
    if (whole.len > 0) {
        const w = std.fmt.parseInt(i64, whole, 10) catch return null;
        if (w < 0) return null;
        units = std.math.mul(i64, w, scale) catch return null;
    }
    if (frac.len > 0) {
        var f = std.fmt.parseInt(i64, frac, 10) catch return null;
        if (f < 0) return null;
        // "1.5" at 2dp is 150 units, not 15 — pad the fraction out to width.
        for (0..decimals - frac.len) |_| f = std.math.mul(i64, f, 10) catch return null;
        units = std.math.add(i64, units, f) catch return null;
    }
    return units;
}

/// Format whole units of a token's finest denomination back into a readable
/// figure at that token's decimals, trailing zeros trimmed ("150" at 2dp →
/// "1.5"; "1" at 0dp → "1"). The inverse of `parseUnits`, and integer-only for
/// the same reason.
pub fn formatUnits(buf: []u8, units: i64, decimals: u8) []const u8 {
    if (decimals == 0) return std.fmt.bufPrint(buf, "{d}", .{units}) catch "?";

    var scale: i64 = 1;
    for (0..decimals) |_| scale = std.math.mul(i64, scale, 10) catch return "?";

    const abs: u64 = @abs(units);
    const uscale: u64 = @intCast(scale);
    var tmp: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&tmp, "{s}{d}.{d:0>[3]}", .{
        if (units < 0) "-" else "",
        abs / uscale,
        abs % uscale,
        @as(usize, decimals),
    }) catch return "?";

    const trimmed = trimTrailingZeros(text);
    const n = @min(trimmed.len, buf.len);
    @memcpy(buf[0..n], trimmed[0..n]);
    return buf[0..n];
}

/// Format integer cents as a dollars figure ("$1234.56", "-$0.05") into `buf`.
/// Callers pass a `[32]u8`.
pub fn formatCents(buf: []u8, cents: i64) []const u8 {
    const abs: u64 = @abs(cents);
    return std.fmt.bufPrint(buf, "{s}${d}.{d:0>2}", .{
        if (cents < 0) "-" else "", abs / 100, abs % 100,
    }) catch "?";
}

/// Format an oracle price in micro-USD per coin ("$0.014230") into `buf` — six
/// decimals, since sub-cent coins are the normal case.
pub fn formatMicroUsd(buf: []u8, micro: u64) []const u8 {
    return std.fmt.bufPrint(buf, "${d}.{d:0>6}", .{ micro / 1_000_000, micro % 1_000_000 }) catch "?";
}

/// Format a coin amount into `buf` at a *fixed* `decimals` places with thousands
/// separators and no abbrev (1234567.5 at 8dp → "1,234,567.50000000"; 0 at 8dp →
/// "0.00000000"). The figure is always shown to the coin's full precision —
/// trailing zeros are kept, not stripped — so a zero balance reads as a balance
/// rather than a bare "0". The integer part is then grouped in threes. Returns a
/// slice into `buf`; callers pass a `[64]u8`, which fits any f64 in this
/// notation.
pub fn formatAmount(buf: []u8, value: f64, decimals: u8) []const u8 {
    var raw: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&raw);
    w.printFloat(value, .{ .mode = .decimal, .precision = decimals }) catch return "?";
    const s = w.buffered();
    const dot = std.mem.indexOfScalar(u8, s, '.');
    const int_part = if (dot) |d| s[0..d] else s;
    // printFloat pads to exactly `decimals` digits, so the fraction is taken
    // verbatim — no trailing-zero stripping (fixed-width display).
    const frac: []const u8 = if (dot) |d| s[d + 1 ..] else "";

    // Group the integer digits in threes: a comma precedes digit `i` when the
    // count of digits after it is a positive multiple of 3.
    var gi: usize = 0;
    var i: usize = 0;
    while (i < int_part.len and gi < buf.len) : (i += 1) {
        if (i != 0 and (int_part.len - i) % 3 == 0) {
            buf[gi] = ',';
            gi += 1;
        }
        buf[gi] = int_part[i];
        gi += 1;
    }
    if (frac.len > 0 and gi + 1 + frac.len <= buf.len) {
        buf[gi] = '.';
        gi += 1;
        @memcpy(buf[gi .. gi + frac.len], frac);
        gi += frac.len;
    }
    return buf[0..gi];
}

/// Trim trailing zeros from a fixed-decimal string produced by `formatAmount`
/// ("498.00000000" → "498", "2.50000000" → "2.5"; "1.25000000" is unaffected
/// past its non-zero digits → "1.25"). Drops the decimal point too if nothing is
/// left after it. Strings with no '.' pass through unchanged. Operates on the
/// slice in place.
///
/// For transaction *lists*, where a column of full-precision figures is noise.
/// Balances keep their full fixed precision — see `formatAmount`.
pub fn trimTrailingZeros(s: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse return s;
    var end = s.len;
    while (end > dot + 1 and s[end - 1] == '0') : (end -= 1) {}
    if (end == dot + 1) end -= 1; // nothing left after the dot — drop it too
    return s[0..end];
}

/// Format a coin balance as `formatAmount` (at `decimals` places) followed by the
/// coin's abbrev ("1,234.50000000 NEXA"), into `buf`. Callers pass a `[96]u8` —
/// `formatAmount`'s 64 plus room for a ticker.
pub fn formatBalance(buf: []u8, value: f64, abbrev: []const u8, decimals: u8) []const u8 {
    var amt: [64]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s} {s}", .{ formatAmount(&amt, value, decimals), abbrev }) catch abbrev;
}

/// How a coin expresses its pruning knob. Mirrors `Coin.Pruning.Mode`, kept
/// separate so this module stays free of the vtable (and usable from the C ABI,
/// which passes the mode across as an int).
pub const PruneMode = enum(u8) {
    /// A disk cap in MiB (bitcoin-family).
    size_mib = 0,
    /// Just on or off, with no size to choose (Monero).
    on_off = 1,
};

/// Describe a cached prune setting in the coin's own terms, into `buf`:
/// `prune_mib` < 0 means never configured, 0 means a full node. A `.size_mib`
/// target reads as "N GB" when it's whole GB — matching how it was chosen — and
/// "N MiB" otherwise. Callers pass a `[48]u8`.
///
/// Text only: the TUI dims it and the GUI colours it, but neither invents its
/// own wording.
pub fn pruneValueText(buf: []u8, mode: PruneMode, prune_mib: i64) []const u8 {
    if (prune_mib < 0) return "not set";
    if (prune_mib == 0) return "disabled (full node)";
    return switch (mode) {
        .on_off => "enabled (~1/3 the chain)",
        .size_mib => if (@rem(prune_mib, 1000) == 0)
            std.fmt.bufPrint(buf, "{d} GB", .{@divTrunc(prune_mib, 1000)}) catch "?"
        else
            std.fmt.bufPrint(buf, "{d} MiB", .{prune_mib}) catch "?",
    };
}

test "parseDollarsToCents parses plain USD amounts and rejects everything else" {
    // Whole dollars, one and two decimals.
    try std.testing.expectEqual(@as(i64, 12500), parseDollarsToCents("125").?);
    try std.testing.expectEqual(@as(i64, 12550), parseDollarsToCents("125.5").?);
    try std.testing.expectEqual(@as(i64, 12550), parseDollarsToCents("125.50").?);
    try std.testing.expectEqual(@as(i64, 5), parseDollarsToCents(".05").?);
    try std.testing.expectEqual(@as(i64, 10000), parseDollarsToCents(" 100 ").?);
    try std.testing.expectEqual(@as(i64, 0), parseDollarsToCents("0").?);
    // Rejected: empty, bare dot, >2 decimals, stray characters, negatives.
    try std.testing.expect(parseDollarsToCents("") == null);
    try std.testing.expect(parseDollarsToCents(".") == null);
    try std.testing.expect(parseDollarsToCents("1.234") == null);
    try std.testing.expect(parseDollarsToCents("12a") == null);
    try std.testing.expect(parseDollarsToCents("-5") == null);
    try std.testing.expect(parseDollarsToCents("1.2.3") == null);
}

test "formatCents and formatMicroUsd render money at fixed precision" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("$125.50", formatCents(&buf, 12550));
    try std.testing.expectEqualStrings("$0.05", formatCents(&buf, 5));
    try std.testing.expectEqualStrings("$100000.00", formatCents(&buf, 10_000_000));
    try std.testing.expectEqualStrings("-$1.25", formatCents(&buf, -125));
    // Oracle price: micro-USD per coin, six decimals (sub-cent coins are normal).
    try std.testing.expectEqualStrings("$0.014230", formatMicroUsd(&buf, 14_230));
    try std.testing.expectEqualStrings("$1.000000", formatMicroUsd(&buf, 1_000_000));
}

test "formatBalance shows fixed decimals and appends the coin abbrev" {
    var buf: [96]u8 = undefined;
    // Whole amounts are padded out to the coin's full precision (here 8dp).
    try std.testing.expectEqualStrings("10.00000000 NEXA", formatBalance(&buf, 10.0, "NEXA", 8));
    // Fractions are padded to the fixed width too — trailing zeros are kept.
    try std.testing.expectEqualStrings("13.50000000 DIVI", formatBalance(&buf, 13.5, "DIVI", 8));
    // Zero reads as a full-width zero, not a bare "0".
    try std.testing.expectEqualStrings("0.00 NEXA", formatBalance(&buf, 0.0, "NEXA", 2));
    // A 12-decimal coin (Nerva/Zano) shows all twelve places.
    try std.testing.expectEqualStrings("0.000000000000 XNV", formatBalance(&buf, 0.0, "XNV", 12));
    // Large amounts get thousands separators on the integer part.
    try std.testing.expectEqualStrings("1,234,567.50000000 XNV", formatBalance(&buf, 1234567.5, "XNV", 8));
}

test "trimTrailingZeros drops trailing zeros and a bare decimal point" {
    // All-zero fraction collapses to a bare integer.
    try std.testing.expectEqualStrings("498", trimTrailingZeros("498.00000000"));
    // Partial trim keeps the significant fractional digits.
    try std.testing.expectEqualStrings("2.5", trimTrailingZeros("2.50000000"));
    // No trailing zeros to trim — unchanged.
    try std.testing.expectEqualStrings("1.23456789", trimTrailingZeros("1.23456789"));
    // No decimal point at all (e.g. a 0-decimal coin) — passes through unchanged.
    try std.testing.expectEqualStrings("498", trimTrailingZeros("498"));
}

test "pruneValueText speaks each coin's own units" {
    var buf: [48]u8 = undefined;
    // Never configured is distinct from deliberately unpruned — the difference is
    // exactly what decides whether it's safe to offer pruning at all.
    try std.testing.expectEqualStrings("not set", pruneValueText(&buf, .size_mib, -1));
    try std.testing.expectEqualStrings("disabled (full node)", pruneValueText(&buf, .size_mib, 0));
    // Whole GB reads back the way it was chosen; anything else stays in MiB.
    try std.testing.expectEqualStrings("2 GB", pruneValueText(&buf, .size_mib, 2000));
    try std.testing.expectEqualStrings("1500 MiB", pruneValueText(&buf, .size_mib, 1500));
    // An on/off coin has no size to report.
    try std.testing.expectEqualStrings("enabled (~1/3 the chain)", pruneValueText(&buf, .on_off, 1));
}

test "parseUnits converts a typed figure to a token's finest units" {
    // 2 decimals: the regtest token used to verify `token send`.
    try std.testing.expectEqual(@as(?i64, 12345), parseUnits("123.45", 2));
    try std.testing.expectEqual(@as(?i64, 150), parseUnits("1.5", 2));
    try std.testing.expectEqual(@as(?i64, 100), parseUnits("1", 2));
    try std.testing.expectEqual(@as(?i64, 5), parseUnits("0.05", 2));
    try std.testing.expectEqual(@as(?i64, 0), parseUnits("0", 2));
    try std.testing.expectEqual(@as(?i64, 12345), parseUnits("  123.45  ", 2));
}

test "parseUnits refuses precision the token cannot hold" {
    // Truncating here would send a different amount than the one typed.
    try std.testing.expectEqual(@as(?i64, null), parseUnits("1.234", 2));
    // An NFT has no fractional part at all.
    try std.testing.expectEqual(@as(?i64, null), parseUnits("1.5", 0));
    try std.testing.expectEqual(@as(?i64, 1), parseUnits("1", 0));
}

test "parseUnits rejects junk, negatives and overflow rather than guessing" {
    try std.testing.expectEqual(@as(?i64, null), parseUnits("", 2));
    try std.testing.expectEqual(@as(?i64, null), parseUnits("abc", 2));
    try std.testing.expectEqual(@as(?i64, null), parseUnits("-1", 2));
    try std.testing.expectEqual(@as(?i64, null), parseUnits(".", 2));
    // Would overflow i64 once scaled to the finest unit.
    try std.testing.expectEqual(@as(?i64, null), parseUnits("9223372036854775807", 8));
}

test "parseUnits and formatUnits round-trip" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1.5", formatUnits(&buf, 150, 2));
    try std.testing.expectEqualStrings("123.45", formatUnits(&buf, 12345, 2));
    try std.testing.expectEqualStrings("1", formatUnits(&buf, 1, 0));
    try std.testing.expectEqualStrings("0", formatUnits(&buf, 0, 2));

    const cases = [_]struct { text: []const u8, dp: u8 }{
        .{ .text = "123.45", .dp = 2 },
        .{ .text = "0.00000001", .dp = 8 },
        .{ .text = "7", .dp = 0 },
    };
    for (cases) |c| {
        const units = parseUnits(c.text, c.dp) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(c.text, formatUnits(&buf, units, c.dp));
    }
}
