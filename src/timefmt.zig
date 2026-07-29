//! Durations, block timestamps and storage figures, as text.
//!
//! Both front-ends will want these — the sync readouts, the DigiDollar
//! activation countdown, the transaction dates — but be honest about today: the
//! **TUI is the only caller**. The GUI's own `relative_time` and
//! `humanize_bytes` answer different questions ("3 minutes ago", "1.2 GB") and
//! are not replaced by anything here. So unlike `money.zig` and `seed.zig`, this
//! module de-duplicates nothing yet; it exists so that when the GUI needs
//! "behind by …" or a countdown it takes the TUI's wording rather than inventing
//! a second one.
//!
//! What it does buy immediately: everything formats into a caller buffer instead
//! of allocating. These run on a render path, once per frame per readout, and
//! CLAUDE.md's rule is to prefer a bounded buffer over an allocation. It is also
//! what makes them usable behind the C ABI later, where returning an allocation
//! would mean deciding who frees it.

const std = @import("std");

/// Longest string any of these produce, so callers can size a buffer once.
/// "12 months and 4 weeks" is 21; the date form is 16.
pub const max_len = 48;

/// Human-readable approximate duration from `secs` — the largest non-zero unit,
/// plus the next one down when it too is non-zero ("3 months and 1 week", never
/// "2 years and 1 day"). Empty for anything under a minute, negatives included,
/// so a caller can treat "" as "effectively nothing".
pub fn duration(buf: []u8, secs: i64) []const u8 {
    if (secs < std.time.s_per_min) return "";
    var rem: u64 = @intCast(secs);

    // Largest → smallest, each consuming its slice of the remainder.
    const divisors = [_]u64{
        365 * std.time.s_per_day, 30 * std.time.s_per_day, std.time.s_per_week,
        std.time.s_per_day,       std.time.s_per_hour,     std.time.s_per_min,
    };
    const singular = [_][]const u8{ "year", "month", "week", "day", "hour", "minute" };
    const plural = [_][]const u8{ "years", "months", "weeks", "days", "hours", "minutes" };

    var counts: [divisors.len]u64 = undefined;
    for (divisors, 0..) |d, idx| {
        counts[idx] = rem / d;
        rem %= d;
    }

    // Index of the most significant non-zero unit.
    var i: usize = 0;
    while (i < counts.len and counts[i] == 0) : (i += 1) {}
    if (i == counts.len) return ""; // unreachable given the >= 1 minute guard

    var w = std.Io.Writer.fixed(buf);
    w.print("{d} {s}", .{
        counts[i], if (counts[i] == 1) singular[i] else plural[i],
    }) catch return w.buffered();
    // Append the next unit down only when it's non-zero, so the readout stays
    // contiguous.
    if (i + 1 < counts.len and counts[i + 1] != 0) {
        const j = i + 1;
        w.print(" and {d} {s}", .{
            counts[j], if (counts[j] == 1) singular[j] else plural[j],
        }) catch return w.buffered();
    }
    return w.buffered();
}

/// "… behind" text from `secs` seconds behind the chain tip — see `duration`
/// for the unit rules. "" when effectively caught up, so a caller can render
/// nothing rather than "0 minutes behind".
pub fn behind(buf: []u8, secs: i64) []const u8 {
    var dbuf: [max_len]u8 = undefined;
    const d = duration(&dbuf, secs);
    if (d.len == 0) return "";
    return std.fmt.bufPrint(buf, "{s} behind", .{d}) catch d;
}

/// Human date/time of a block at unix timestamp `unix_secs`, as
/// "YYYY-MM-DD HH:MM" in **UTC**. "" for a non-positive timestamp (no block).
///
/// UTC deliberately: a block's timestamp is a consensus value, the same for
/// everyone who verifies the chain, and rendering it in local time invites
/// comparing it against a wall clock it was never in.
pub fn blockTime(buf: []u8, unix_secs: i64) []const u8 {
    if (unix_secs <= 0) return "";
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(unix_secs) };
    const day = epoch.getEpochDay();
    const day_secs = epoch.getDaySeconds();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
    }) catch "";
}

/// A byte count as a two-decimal "X.XX GB" figure, for a storage readout.
///
/// Decimal GB (÷1000³, i.e. SI), so the number matches what a Linux/GNOME file
/// manager's Properties dialog reports — GNOME (and macOS Finder) quote SI GB,
/// which is the "same as right-click → Properties" reference the figure targets.
/// Windows Explorer instead quotes binary GiB but labels it "GB", so it reads
/// ~7% smaller there — an unavoidable OS convention difference.
pub fn storageGB(buf: []u8, bytes: u64) []const u8 {
    const gb = @as(f64, @floatFromInt(bytes)) / (1000.0 * 1000.0 * 1000.0);
    return std.fmt.bufPrint(buf, "{d:.2} GB", .{gb}) catch "0.00 GB";
}

test "duration names the largest unit, and the next one only when non-zero" {
    var buf: [max_len]u8 = undefined;
    const minute = std.time.s_per_min;
    const hour = std.time.s_per_hour;
    const day = std.time.s_per_day;

    // Singular and plural.
    try std.testing.expectEqualStrings("1 minute", duration(&buf, minute));
    try std.testing.expectEqualStrings("2 minutes", duration(&buf, 2 * minute));
    try std.testing.expectEqualStrings("1 hour", duration(&buf, hour));

    // Two units, contiguous only.
    try std.testing.expectEqualStrings("1 hour and 30 minutes", duration(&buf, hour + 30 * minute));
    // A day and a minute: the minute is NOT contiguous with days (hours is the
    // next unit down and it's zero), so it's dropped rather than jumping units.
    try std.testing.expectEqualStrings("1 day", duration(&buf, day + minute));
    try std.testing.expectEqualStrings("1 day and 2 hours", duration(&buf, day + 2 * hour));
}

test "anything under a minute reads as nothing at all" {
    var buf: [max_len]u8 = undefined;
    // Including negatives — a caller ahead of the tip must not see "-3 minutes".
    try std.testing.expectEqualStrings("", duration(&buf, 0));
    try std.testing.expectEqualStrings("", duration(&buf, -100));
    try std.testing.expectEqualStrings("", duration(&buf, std.time.s_per_min - 1));
}

test "behind appends the word, and stays empty when caught up" {
    var buf: [max_len]u8 = undefined;
    try std.testing.expectEqualStrings("", behind(&buf, 0));
    try std.testing.expectEqualStrings("", behind(&buf, -100));
    try std.testing.expectEqualStrings("1 minute behind", behind(&buf, std.time.s_per_min));
    try std.testing.expectEqualStrings(
        "2 hours and 5 minutes behind",
        behind(&buf, 2 * std.time.s_per_hour + 5 * std.time.s_per_min),
    );
}

test "blockTime renders UTC, and nothing for a block that isn't there" {
    var buf: [max_len]u8 = undefined;
    // The bitcoin genesis block, 2009-01-03 18:15:05 UTC.
    try std.testing.expectEqualStrings("2009-01-03 18:15", blockTime(&buf, 1231006505));
    // The unix epoch itself, and the absence of a timestamp.
    try std.testing.expectEqualStrings("1970-01-01 00:00", blockTime(&buf, 1));
    try std.testing.expectEqualStrings("", blockTime(&buf, 0));
    try std.testing.expectEqualStrings("", blockTime(&buf, -1));
}

test "storageGB quotes SI gigabytes to two places" {
    var buf: [max_len]u8 = undefined;
    try std.testing.expectEqualStrings("0.00 GB", storageGB(&buf, 0));
    try std.testing.expectEqualStrings("1.00 GB", storageGB(&buf, 1000 * 1000 * 1000));
    // SI, not binary: 2^30 bytes is 1.07 GB, not 1.00.
    try std.testing.expectEqualStrings("1.07 GB", storageGB(&buf, 1024 * 1024 * 1024));
    try std.testing.expectEqualStrings("523.45 GB", storageGB(&buf, 523_450_000_000));
}

test "every output fits the advertised max_len" {
    // Callers size a single buffer from `max_len`; an output that outgrew it
    // would truncate silently rather than fail.
    var buf: [max_len]u8 = undefined;
    // The longest duration form: two units, both plural, both two digits.
    const long = 11 * 30 * std.time.s_per_day + 3 * std.time.s_per_week;
    try std.testing.expect(duration(&buf, long).len <= max_len);
    try std.testing.expect(behind(&buf, long).len <= max_len);
    try std.testing.expect(blockTime(&buf, 4102444800).len <= max_len);
    try std.testing.expect(storageGB(&buf, std.math.maxInt(u64)).len <= max_len);
}
