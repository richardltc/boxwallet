const std = @import("std");

/// USD spot prices for the registered coins, fetched from one public endpoint.
///
/// **One request covers every coin.** The quote for a coin is a property of the
/// market, not of its daemon, so this is an app-level poll on a slow cadence
/// rather than anything per-coin — 14 coins cost the same single call as one.
/// That also makes it *privacy-preserving by construction*: the request always
/// asks for the full registered roster, identical for every BoxWallet user,
/// regardless of which coins are installed or which pane is open. Asking only
/// for the coins someone actually runs would leak their portfolio to the price
/// host; this deliberately doesn't.
///
/// Prices are ambient context in a wallet manager, not trading data, so
/// everything here is best-effort: a failed fetch, a coin the host doesn't
/// list, or no network at all must leave the UI working exactly as before.
/// Nothing in this module returns an error the caller has to surface to the
/// user — an unavailable price is simply absent (`Quote.have == false`).
///
/// Memory stays flat: the reply for the whole roster is well under a kilobyte,
/// is capped hard on read, and is parsed into stack scalars — no per-coin
/// allocation is kept, and no string from the response outlives the call.

/// One coin's market data. `have` false means the host returned no entry for
/// that id (an unlisted coin, or a fetch that never ran) — the UI then shows
/// no price at all rather than a misleading zero.
pub const Quote = struct {
    usd: f64 = 0,
    /// Percent change over the last 24h, or null when the host lists the coin
    /// but reports no change figure for it. **Independent of `usd`**: Nexa
    /// currently returns a price with a null change, so a caller must not
    /// assume the two arrive together.
    change_24h: ?f64 = null,
    have: bool = false,
};

/// A coin's own price endpoint, for the ones the roster host prices badly.
///
/// The roster call covers almost everything, but "the host lists it" and "the
/// host's number is right" are different claims. Divi is the worked example:
/// CoinGecko publishes a price off a market doing **$24 a day**, five times
/// below where Divi actually trades, so a balance was shown at a fifth of its
/// worth. A coin in that position declares a source here and is left out of the
/// roster request entirely — there is no falling back to a wrong number, since
/// showing nothing is honest and showing a fifth of the value is not.
///
/// The URL and the reply's shape are the coin's business, so both live in the
/// coin file; this module only carries them to the same capped, best-effort
/// transport the roster uses.
pub const Source = struct {
    /// The complete request URL. **Fixed, with nothing per-user in it** — see
    /// the note on privacy above: this request is made by every BoxWallet on
    /// every cycle whether or not the coin is installed, exactly like the roster
    /// call, so it says nothing about what anyone holds.
    url: []const u8,
    /// Turn this host's reply into a quote. Null for a reply that carries no
    /// usable price — a halted market, a zero — which reads the same as an
    /// unlisted coin: no price shown. Must not retain anything from `body`.
    parse: *const fn (gpa: std.mem.Allocator, body: []const u8) ?Quote,
};

/// How stale a quote may get before the UI should stop showing it. Prices that
/// keep sitting on screen while every refresh fails would misrepresent what a
/// balance is worth, which is worse than showing nothing.
pub const max_age_s: i64 = 60 * 60;

/// The polling cadence: every 5 minutes (~12/hour), one call for the whole
/// roster plus one for each coin with its own `Source` (Divi today — so two
/// calls per cycle). The public tier allows a few calls per *minute* and
/// refreshes its own numbers only every minute or two, so polling harder would
/// burn budget re-fetching identical values. Rate limits are per-IP, so each
/// user has their own budget.
pub const refresh_interval_s: i64 = 5 * 60;

/// Backoff after a failed fetch: 5 → 10 → 20 → 40 min, capped at an hour, so an
/// outage or a rate-limit reply doesn't turn into a retry storm.
pub const max_backoff_s: i64 = 60 * 60;

/// The next retry delay after `failures` consecutive failures.
pub fn backoffSeconds(failures: u32) i64 {
    if (failures == 0) return refresh_interval_s;
    const shift: u6 = @intCast(@min(failures, 8));
    const delay = refresh_interval_s *| (@as(i64, 1) << shift);
    return @min(delay, max_backoff_s);
}

const host = "https://api.coingecko.com/api/v3/simple/price";
const user_agent = "BoxWallet";

/// Hard cap on the response we'll read. The full roster answers in well under a
/// kilobyte; anything wildly larger is a wrong endpoint or a captive portal, and
/// is refused rather than buffered.
const max_response_bytes = 16 * 1024;

/// The response shape: `{"bitcoin":{"usd":64435,"usd_24h_change":0.3}}`. Field
/// names are the host's; defaults keep parsing resilient to omitted fields, and
/// the optional change absorbs an explicit `null`.
const RawQuote = struct {
    usd: f64 = 0,
    usd_24h_change: ?f64 = null,
};

/// Fetch USD quotes for `ids`, writing each coin's result into the parallel
/// `out` slice (`out[i]` is `ids[i]`'s). `out` is fully overwritten: an id the
/// host doesn't list lands as `have = false`, so a coin dropping off the API
/// clears rather than freezing at its last value.
///
/// Errors only for a genuine transport/parse failure — the caller treats that
/// as "no update this round" and keeps whatever it had until `max_age_s`.
pub fn fetch(
    gpa: std.mem.Allocator,
    io: std.Io,
    ids: []const []const u8,
    out: []Quote,
) !void {
    std.debug.assert(ids.len == out.len);
    for (out) |*q| q.* = .{};
    if (ids.len == 0) return;

    const url = try buildUrl(gpa, ids);
    defer gpa.free(url);

    const body = try fetchText(gpa, io, url);
    defer gpa.free(body);

    var parsed = try std.json.parseFromSlice(
        std.json.ArrayHashMap(RawQuote),
        gpa,
        body,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    // Copy out scalars only — nothing from the parse arena outlives this call.
    for (ids, out) |id, *q| {
        const raw = parsed.value.map.get(id) orelse continue;
        q.* = .{ .usd = raw.usd, .change_24h = raw.usd_24h_change, .have = raw.usd > 0 };
    }
}

/// Fetch one coin's quote from its own `Source`. Same transport, cap and
/// best-effort contract as `fetch`: an error means "no update this round", and a
/// reply the source can't read means "no price" (`have` false) rather than an
/// error the caller has to surface.
pub fn fetchOne(gpa: std.mem.Allocator, io: std.Io, source: Source) !Quote {
    const body = try fetchText(gpa, io, source.url);
    defer gpa.free(body);
    return source.parse(gpa, body) orelse .{};
}

/// Build the query URL for `ids` (comma-joined). Caller owns the result.
fn buildUrl(gpa: std.mem.Allocator, ids: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll(host ++ "?ids=");
    for (ids, 0..) |id, i| {
        if (i > 0) try out.writer.writeByte(',');
        try out.writer.writeAll(id);
    }
    try out.writer.writeAll("&vs_currencies=usd&include_24hr_change=true");
    return out.toOwnedSlice();
}

/// GET `url` into a freshly allocated buffer, capped at `max_response_bytes`.
/// Mirrors `update.zig`'s `fetchText` (the same small-JSON shape); kept separate
/// so the updater's own transport policy stays independent of this one.
fn fetchText(gpa: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        .headers = .{
            .user_agent = .{ .override = user_agent },
            // Raw bytes, no re-encoding — keeps the JSON intact.
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
    });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) return error.HttpStatus;

    var transfer_buffer: [8 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    while (true) {
        _ = reader.stream(&out.writer, .limited(8 * 1024)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return error.ReadFailed,
        };
        if (out.written().len > max_response_bytes) return error.TooLarge;
    }
    return out.toOwnedSlice();
}

// --- formatting -------------------------------------------------------------

/// Format a *unit price* into `buf`, returning a slice of it.
///
/// A fixed 2 decimal places can't express this roster: BitcoinZ trades around
/// $0.00002114 and ReddCoin around $0.00003085, both of which would render as
/// "$0.00" — indistinguishable from worthless, and from each other. So a price
/// below $1 is shown to **4 significant figures** instead, which keeps the
/// meaningful digits whatever the magnitude (0.2225, 0.003253, 0.00002114),
/// while $1-and-up keeps the familiar 2 decimal places.
///
/// The host sends small numbers in scientific notation (`2.114e-05`); JSON
/// parsing turns that into an ordinary f64, and `.decimal` mode keeps it out of
/// the rendered string.
pub fn formatUsd(buf: []u8, price: f64) []const u8 {
    if (!(price > 0) or !std.math.isFinite(price)) return "—";

    var decimals: u8 = 2;
    if (price < 1) {
        // exp is the position of the first significant digit (-1 for 0.2…,
        // -5 for 0.00002…); 3 more places carries 4 significant figures.
        const exp: i32 = @intFromFloat(@floor(std.math.log10(price)));
        const want = -exp + 3;
        decimals = @intCast(std.math.clamp(want, 2, 12));
    }

    var w = std.Io.Writer.fixed(buf);
    w.writeByte('$') catch return "—";
    w.printFloat(price, .{ .mode = .decimal, .precision = decimals }) catch return "—";
    return w.buffered();
}

/// Format a *fiat value* (a holding's worth: amount × price) into `buf`. Always
/// 2 decimal places with thousands separators — this is a dollar figure to read
/// at a glance, not a precision quote. A tiny non-zero holding honestly reads
/// "$0.00"; that's the truth about its worth, not a formatting failure.
pub fn formatValue(buf: []u8, amount: f64, price: f64) []const u8 {
    const value = amount * price;
    if (!std.math.isFinite(value) or value < 0) return "—";

    // Render plainly first, then splice separators into the integer part.
    var plain_buf: [64]u8 = undefined;
    var pw = std.Io.Writer.fixed(&plain_buf);
    pw.printFloat(value, .{ .mode = .decimal, .precision = 2 }) catch return "—";
    const plain = pw.buffered();

    const dot = std.mem.indexOfScalar(u8, plain, '.') orelse plain.len;
    const int_part = plain[0..dot];
    const frac = plain[dot..];

    var w = std.Io.Writer.fixed(buf);
    w.writeByte('$') catch return "—";
    for (int_part, 0..) |c, i| {
        const remaining = int_part.len - i;
        if (i > 0 and remaining % 3 == 0) w.writeByte(',') catch return "—";
        w.writeByte(c) catch return "—";
    }
    w.writeAll(frac) catch return "—";
    return w.buffered();
}

/// Which way a 24h change points — drives both the arrow glyph and its colour.
pub const Direction = enum { up, down, flat };

/// Classify a 24h change percentage. Exactly zero (and a change the host didn't
/// report) is `flat`, so no misleading arrow is drawn.
pub fn direction(change_24h: ?f64) Direction {
    const c = change_24h orelse return .flat;
    if (!std.math.isFinite(c) or c == 0) return .flat;
    return if (c > 0) .up else .down;
}

/// The arrow glyph for a direction. Solid triangles read bolder than ↑/↓ at a
/// terminal's fixed cell size (the same reasoning as the ✔/✘ status marks).
pub fn arrow(dir: Direction) []const u8 {
    return switch (dir) {
        .up => "▲",
        .down => "▼",
        .flat => "",
    };
}

/// Format a 24h change as `▲ 2.34%` / `▼ 5.52%` into `buf`. The percentage is
/// always shown unsigned — the arrow already carries the sign, and "▼ -5.52%"
/// reads as a double negative. Empty when there's no change to report.
pub fn formatChange(buf: []u8, change_24h: ?f64) []const u8 {
    const c = change_24h orelse return "";
    if (!std.math.isFinite(c)) return "";
    const dir = direction(change_24h);
    if (dir == .flat) return "";

    var w = std.Io.Writer.fixed(buf);
    w.writeAll(arrow(dir)) catch return "";
    w.writeByte(' ') catch return "";
    w.printFloat(@abs(c), .{ .mode = .decimal, .precision = 2 }) catch return "";
    w.writeByte('%') catch return "";
    return w.buffered();
}

test "formatUsd keeps significant digits for sub-cent coins" {
    var buf: [64]u8 = undefined;
    // $1-and-up: the familiar 2 decimal places.
    try std.testing.expectEqualStrings("$64435.00", formatUsd(&buf, 64435));
    try std.testing.expectEqualStrings("$47.09", formatUsd(&buf, 47.09));
    try std.testing.expectEqualStrings("$9.59", formatUsd(&buf, 9.59));
    // Below $1: 4 significant figures, whatever the magnitude. A fixed 2dp
    // would render every one of these as "$0.00".
    try std.testing.expectEqualStrings("$0.2225", formatUsd(&buf, 0.222469));
    try std.testing.expectEqualStrings("$0.003253", formatUsd(&buf, 0.00325307));
    // BitcoinZ / ReddCoin territory — the host sends these as 2.114e-05.
    try std.testing.expectEqualStrings("$0.00002114", formatUsd(&buf, 2.114e-05));
    try std.testing.expectEqualStrings("$0.00003085", formatUsd(&buf, 3.085e-05));
    // No price / nonsense reads as an em dash, never "$0.00".
    try std.testing.expectEqualStrings("—", formatUsd(&buf, 0));
    try std.testing.expectEqualStrings("—", formatUsd(&buf, -1));
    try std.testing.expectEqualStrings("—", formatUsd(&buf, std.math.nan(f64)));
}

test "formatValue renders a holding's worth with thousands separators" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("$1,234.56", formatValue(&buf, 1234.56, 1));
    try std.testing.expectEqualStrings("$64,435.00", formatValue(&buf, 1, 64435));
    try std.testing.expectEqualStrings("$999.99", formatValue(&buf, 999.99, 1));
    try std.testing.expectEqualStrings("$1,000,000.00", formatValue(&buf, 1_000_000, 1));
    // A million BTCZ at 2.114e-05 is a real, small number.
    try std.testing.expectEqualStrings("$21.14", formatValue(&buf, 1_000_000, 2.114e-05));
    // Dust is honestly worth $0.00 — not an error.
    try std.testing.expectEqualStrings("$0.00", formatValue(&buf, 0.00000001, 2.114e-05));
    try std.testing.expectEqualStrings("$0.00", formatValue(&buf, 0, 64435));
}

test "direction and formatChange carry the sign in the arrow, not the number" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqual(Direction.up, direction(0.3059));
    try std.testing.expectEqual(Direction.down, direction(-5.5228));
    try std.testing.expectEqual(Direction.flat, direction(0));
    // A coin the host lists without a change figure (Nexa) draws no arrow.
    try std.testing.expectEqual(Direction.flat, direction(null));

    try std.testing.expectEqualStrings("▲ 0.31%", formatChange(&buf, 0.3059));
    // Unsigned: the ▼ already says it fell.
    try std.testing.expectEqualStrings("▼ 5.52%", formatChange(&buf, -5.5228));
    try std.testing.expectEqualStrings("", formatChange(&buf, null));
    try std.testing.expectEqualStrings("", formatChange(&buf, 0));
}

test "backoffSeconds grows after failures and caps at an hour" {
    try std.testing.expectEqual(refresh_interval_s, backoffSeconds(0));
    try std.testing.expectEqual(@as(i64, 600), backoffSeconds(1));
    try std.testing.expectEqual(@as(i64, 1200), backoffSeconds(2));
    try std.testing.expectEqual(@as(i64, 2400), backoffSeconds(3));
    // Capped, and stays capped however long the outage runs.
    try std.testing.expectEqual(max_backoff_s, backoffSeconds(10));
    try std.testing.expectEqual(max_backoff_s, backoffSeconds(1000));
}

test "buildUrl joins the roster into one query" {
    const a = std.testing.allocator;
    const url = try buildUrl(a, &.{ "bitcoin", "monero", "epic-cash" });
    defer a.free(url);
    try std.testing.expectEqualStrings(
        host ++ "?ids=bitcoin,monero,epic-cash&vs_currencies=usd&include_24hr_change=true",
        url,
    );
}

test "parsing fills quotes by id and leaves unlisted coins absent" {
    const a = std.testing.allocator;
    // A real-shaped reply: one healthy coin, one with a null change (Nexa's
    // actual behaviour), and one id the host simply doesn't return.
    const body =
        \\{"bitcoin":{"usd":64435,"usd_24h_change":0.3059086391112687},
        \\"nexa":{"usd":0.00120172,"usd_24h_change":null}}
    ;
    var parsed = try std.json.parseFromSlice(
        std.json.ArrayHashMap(RawQuote),
        a,
        body,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const ids = [_][]const u8{ "bitcoin", "nexa", "spiderbyte" };
    var out: [3]Quote = undefined;
    for (&out) |*q| q.* = .{};
    for (ids, &out) |id, *q| {
        const raw = parsed.value.map.get(id) orelse continue;
        q.* = .{ .usd = raw.usd, .change_24h = raw.usd_24h_change, .have = raw.usd > 0 };
    }

    try std.testing.expect(out[0].have);
    try std.testing.expectEqual(@as(f64, 64435), out[0].usd);
    try std.testing.expectEqual(Direction.up, direction(out[0].change_24h));

    // Priced, but with no change figure — the two are independent.
    try std.testing.expect(out[1].have);
    try std.testing.expect(out[1].change_24h == null);

    // Unlisted (SpiderByte): absent, so the UI shows no price rather than $0.00.
    try std.testing.expect(!out[2].have);
    try std.testing.expectEqual(@as(f64, 0), out[2].usd);
}
