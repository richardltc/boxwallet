const std = @import("std");
const zz = @import("zigzag");
const version_mod = @import("version.zig");
const registry = @import("registry.zig");
const money = @import("money.zig");
const seed_mod = @import("seed.zig");
const walletmenu = @import("walletmenu.zig");
const timefmt = @import("timefmt.zig");
const status_mod = @import("status.zig");
const models = @import("models.zig");
const install_mod = @import("install.zig");
const disk = @import("disk.zig");
const memory = @import("memory.zig");
const conf = @import("conf.zig");
const rpc = @import("rpc.zig");
const updater = @import("update.zig");
const price = @import("price.zig");
const qrcode = @import("qrcode.zig");
const proc_mod = @import("proc.zig");
const warmup = @import("warmup.zig");
const tipwatch = @import("tipwatch.zig");
const extwallet = @import("extwallet.zig");
const mining = @import("mining.zig");
const Coin = @import("coin.zig").Coin;
const Nexa = @import("coins/nexa.zig").Nexa;
const Divi = @import("coins/divi.zig").Divi;
const Ergo = @import("coins/ergo.zig").Ergo;
const DigiByte = @import("coins/digibyte.zig").DigiByte;
const Zano = @import("coins/zano.zig").Zano;
const Nerva = @import("coins/nerva.zig").Nerva;
const Salvium = @import("coins/salvium.zig").Salvium;
const Monero = @import("coins/monero.zig").Monero;
const ReddCoin = @import("coins/reddcoin.zig").ReddCoin;
const Epic = @import("coins/epic.zig").Epic;
const Litecoin = @import("coins/litecoin.zig").Litecoin;
const Bitcoin = @import("coins/bitcoin.zig").Bitcoin;
const SpiderByte = @import("coins/spiderbyte.zig").SpiderByte;
const BitcoinZ = @import("coins/bitcoinz.zig").BitcoinZ;

/// The application's display name, version, and brand colour. The values live in
/// `version.zig` so the GUI reads the same ones (it can't import this module —
/// it would drag ZigZag into the GUI's core library); these are the TUI's names
/// for them. `app_color` is the brand hex used for the "BoxWallet" wording on
/// the Home pane.
pub const app_name = version_mod.tui_name;
pub const app_version = version_mod.app_version;
const app_color = version_mod.brand_color;

/// Fallback install root used only if the home-dir-based path can't be built
/// (e.g. allocation failure at startup). Normally `App.install_root` is the
/// per-platform `~/.boxwallet` dir resolved in `init`.
const fallback_install_root = "boxwallet-coins";

/// BoxWallet's own settings file — shared with the GUI frontend, which keeps its
/// window geometry in the same conf (see `conf.zig`).
const settings_file = conf.settings_file;

/// What a wallet balance figure is replaced with while `App.hide_balances` is on.
/// What a balance figure is replaced with while `App.hide_balances` is on.
/// Shared with the GUI (`bw_balance_mask`) so both mask with the same thing.
const balance_mask = money.balance_mask;

/// Every coin registered in the left bar. Order here is irrelevant — `entries`
/// sorts them alphabetically below — so a newly ported coin can be added in any
/// position. Adding a coin is a matter of extending this list, the `App` field +
/// `init`, the dispatch in `selectedCoin`, and an arm in `entryLive`; the detail
/// pane renders generically through the `Coin` interface, so it needs no per-coin
/// code. A coin whose per-coin `live` constant is false stays registered here but
/// is dropped from `entries` — hidden from the nav entirely until it's ready.
const Entry = enum { home, nexa, divi, ergo, digibyte, zano, nerva, reddcoin, epic, salvium, litecoin, bitcoin, bitcoinz, spiderbyte, monero };
const coin_entries = [_]Entry{ .nexa, .divi, .ergo, .digibyte, .zano, .nerva, .reddcoin, .epic, .salvium, .litecoin, .bitcoin, .bitcoinz, .spiderbyte, .monero };

/// The registered coin backends as their concrete types. Taken from
/// `registry.zig` — the one roster both front-ends read — rather than listed
/// again here. That module also carries the duplicate-binary-name guard, which
/// used to live in this file but is a property of the shared install root, not
/// of the TUI.
const coin_types = registry.coin_types;

// Compile-time guard: `coin_entries` must be the registry's list, in the
// registry's order. It already is — this assertion is zero-diff today — but the
// GUI addresses coins by that index (it's the C ABI, and `gui/app.slint`'s logo
// array is indexed by it), so a coin inserted here and appended there would
// point the GUI at the wrong coin with nothing to catch it. The `.home` row is
// this file's own and sits outside the comparison.
comptime {
    if (coin_entries.len != registry.count)
        @compileError("coin_entries must list every coin in src/registry.zig");
    for (coin_entries, 0..) |e, i| {
        if (!std.mem.eql(u8, entryLabel(e), registry.name(i)))
            @compileError("coin_entries is out of step with src/registry.zig at index " ++
                std.fmt.comptimePrint("{d}", .{i}) ++ ": expected '" ++ registry.name(i) ++
                "', found '" ++ entryLabel(e) ++ "' — the order is the GUI's C ABI");
    }
}

fn entryLabel(e: Entry) []const u8 {
    return switch (e) {
        .home => "HOME",
        .nexa => Nexa.coin_name,
        .divi => Divi.coin_name,
        .ergo => Ergo.coin_name,
        .digibyte => DigiByte.coin_name,
        .zano => Zano.coin_name,
        .nerva => Nerva.coin_name,
        .reddcoin => ReddCoin.coin_name,
        .epic => Epic.coin_name,
        .salvium => Salvium.coin_name,
        .monero => Monero.coin_name,
        .litecoin => Litecoin.coin_name,
        .bitcoin => Bitcoin.coin_name,
        .bitcoinz => BitcoinZ.coin_name,
        .spiderbyte => SpiderByte.coin_name,
    };
}

/// Dim grey for unselected left-nav rows, so only the selected entry shows its
/// brand colour and the current coin stands out at a glance.
const nav_dim_color = "#6b6b6b";

/// The Home row's left-nav label, drawn in two colours: the app name in the
/// brand colour and the version in the default colour (e.g. "BoxWallet v0.0.3").
const home_brand_text = "BoxWallet";
const home_version_text = " v" ++ app_version;

/// Visible width of the nav label column — wide enough for the Home row's full
/// "BoxWallet v<version>" (the longest label), so the `│` separator stays
/// aligned across every row.
const nav_label_w = @max(12, home_brand_text.len + home_version_text.len);

/// Visible width of the trailing selection-marker column — the closing `❮` that
/// brackets the current row against the leading `❯`, plus the space before it.
const nav_trail_w = 2;

/// Total width of a left-nav row: the 2-cell selection marker, the label column,
/// and the 2-cell closing marker. Also the click target — an x below this is in
/// the nav, at or past it is the separator or the detail pane.
const nav_col_w = 2 + nav_label_w + nav_trail_w;

/// The colour a left-nav row is drawn in: its brand colour when `selected`, else
/// a dim grey — so only the current coin shows its colour and the selection pops
/// without a marker alone. Home is exempt: it keeps its brand colour always, as a
/// fixed anchor at the top of the column.
fn navColor(e: Entry, selected: bool) zz.Color {
    if (e == .home or selected) return entryColor(e);
    return zz.Color.hex(nav_dim_color);
}

/// The colour each entry is drawn in on the left nav. Coins use their own brand
/// colour (parsed from the per-coin `coin_color` hex); Home wears the app's
/// brand colour.
fn entryColor(e: Entry) zz.Color {
    return switch (e) {
        .home => zz.Color.hex(app_color),
        .nexa => zz.Color.hex(Nexa.coin_color),
        .divi => zz.Color.hex(Divi.coin_color),
        .ergo => zz.Color.hex(Ergo.coin_color),
        .digibyte => zz.Color.hex(DigiByte.coin_color),
        .zano => zz.Color.hex(Zano.coin_color),
        .nerva => zz.Color.hex(Nerva.coin_color),
        .reddcoin => zz.Color.hex(ReddCoin.coin_color),
        .epic => zz.Color.hex(Epic.coin_color),
        .salvium => zz.Color.hex(Salvium.coin_color),
        .monero => zz.Color.hex(Monero.coin_color),
        .litecoin => zz.Color.hex(Litecoin.coin_color),
        .bitcoin => zz.Color.hex(Bitcoin.coin_color),
        .bitcoinz => zz.Color.hex(BitcoinZ.coin_color),
        .spiderbyte => zz.Color.hex(SpiderByte.coin_color),
    };
}

/// If a log line's leading "<tag>:" names BoxWallet or a coin, return the byte
/// length of that tag and the colour to tint it; null when there's no such tag.
/// `msg` must start at the tag (the timestamp already stripped). Lets the log
/// pane paint just the coin/BoxWallet word in its brand colour, the rest plain.
fn logTagColor(msg: []const u8) ?struct { len: usize, col: zz.Color } {
    const colon = std.mem.indexOfScalar(u8, msg, ':') orelse return null;
    const tag = msg[0..colon];
    if (std.mem.eql(u8, tag, home_brand_text))
        return .{ .len = colon, .col = zz.Color.hex(app_color) };
    for (entries[1..]) |e| // skip Home; coins carry their own brand colour
        if (std.mem.eql(u8, tag, entryLabel(e)))
            return .{ .len = colon, .col = entryColor(e) };
    return null;
}

/// Render a log line's coin `tag` in the coin's full branding — its two-tone
/// wordmark (SpiderByte "Spider"+"Byte", ReddCoin "Redd"+"Coin") when it has one,
/// else its single brand colour — so the log matches the detail-pane header. `tag`
/// is exactly the coin name (the log tag equals `entryLabel`), so a wordmark's
/// byte `split` indexes straight into it. Returns an owned styled slice.
fn brandLogTag(a: std.mem.Allocator, coin: Coin, tag: []const u8) []const u8 {
    const brand = zz.Color.hex(coin.coinColor());
    if (coin.wordmark()) |wm| {
        const hc = if (wm.head_color) |c| zz.Color.hex(c) else brand;
        const h = (zz.Style{}).fg(hc).render(a, tag[0..wm.split]) catch tag[0..wm.split];
        const t = (zz.Style{}).fg(zz.Color.hex(wm.alt_color)).render(a, tag[wm.split..]) catch tag[wm.split..];
        return std.fmt.allocPrint(a, "{s}{s}", .{ h, t }) catch tag;
    }
    return (zz.Style{}).fg(brand).render(a, tag) catch tag;
}

/// Whether a coin is exposed in the nav. Coins gate this on their per-coin `live`
/// constant; a `false` coin is dropped from `entries` entirely (no row, no
/// activity slot, never selectable or polled). Home is always live.
fn entryLive(e: Entry) bool {
    return switch (e) {
        .home => true,
        .nexa => Nexa.live,
        .divi => Divi.live,
        .ergo => Ergo.live,
        .digibyte => DigiByte.live,
        .zano => Zano.live,
        .nerva => Nerva.live,
        .reddcoin => ReddCoin.live,
        .epic => Epic.live,
        .salvium => Salvium.live,
        .monero => Monero.live,
        .litecoin => Litecoin.live,
        .bitcoin => Bitcoin.live,
        .bitcoinz => BitcoinZ.live,
        .spiderbyte => SpiderByte.live,
    };
}

/// The left-column order: Home pinned to the top, then the live coins
/// alphabetically by label. The sort and the live-filter run at comptime, so
/// registering a coin keeps the list ordered without anyone placing it by hand.
/// Index 0 is always Home; the rest are coins, and `activities` is indexed
/// parallel to this.
const entries = blk: {
    var coins = coin_entries;
    std.mem.sort(Entry, &coins, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, entryLabel(a), entryLabel(b));
        }
    }.lessThan);
    // Drop coins whose per-coin `live` flag is false — they vanish from the nav
    // entirely (no row, no activity slot, never selectable or polled).
    var live_coins: [coin_entries.len]Entry = undefined;
    var n: usize = 0;
    for (coins) |e| if (entryLive(e)) {
        live_coins[n] = e;
        n += 1;
    };
    break :blk [_]Entry{.home} ++ live_coins[0..n].*;
};

/// The slice of the coin list (entries[1..]) visible in the left nav, plus
/// whether a "more above/below" indicator row should be drawn on either edge.
const NavWindow = struct { start: usize, len: usize, more_above: bool, more_below: bool };

/// Pick which coins fit in a `rows`-row nav viewport so the selected coin is
/// always on screen. `sel` and `total` index the coin list (Home excluded — it
/// stays pinned above the window). When everything fits the whole list comes
/// back with no indicators, so large terminals render exactly as before. On
/// overflow the window is centred on `sel`; with 3+ rows each needed indicator
/// replaces the edge row it points past (centring keeps `sel` clear of the
/// edges), while 1–2 rows are too tight for indicators and just show the window.
fn navWindow(sel: usize, total: usize, rows: usize) NavWindow {
    if (rows >= total) return .{ .start = 0, .len = total, .more_above = false, .more_below = false };
    if (rows == 0) return .{ .start = 0, .len = 0, .more_above = false, .more_below = false };
    var start = @min(sel -| (rows - 1) / 2, total - rows);
    var len = rows;
    const above = start > 0;
    const below = start + rows < total;
    const indicators = rows >= 3;
    if (indicators) {
        if (above) {
            start += 1;
            len -= 1;
        }
        if (below) len -= 1;
    }
    return .{ .start = start, .len = len, .more_above = above and indicators, .more_below = below and indicators };
}

/// What a single left-nav row holds: an entry (index into `entries`), or one of
/// the dim "the list continues this way" arrows.
const NavRow = union(enum) { entry: usize, more_above, more_below };

/// Lay the left-nav rows out top-to-bottom for a `nav_rows`-row viewport: Home
/// pinned on the first row, then the visible coin window, bracketed by scroll
/// indicators where the list runs past the window. Writes into `out` and returns
/// how many rows were used.
///
/// The renderer and the mouse handler both go through here, so a click on screen
/// row N lands on exactly the entry `renderTwoPane` drew on row N — the mapping
/// can't drift out of sync with the layout.
fn navRows(selected: usize, nav_rows: usize, out: *[entries.len + 2]NavRow) usize {
    // One row is reserved for Home; the coin window gets the rest.
    const total_coins = entries.len - 1;
    const coin_rows = if (nav_rows == 0) total_coins else nav_rows - 1;
    const w = navWindow(selected -| 1, total_coins, coin_rows);

    var n: usize = 0;
    out[n] = .{ .entry = 0 };
    n += 1;
    if (w.more_above) {
        out[n] = .more_above;
        n += 1;
    }
    for (w.start..w.start + w.len) |ci| {
        out[n] = .{ .entry = ci + 1 };
        n += 1;
    }
    if (w.more_below) {
        out[n] = .more_below;
        n += 1;
    }
    return n;
}

/// Where a coin's background install has got to. The UI reads this every frame
/// to paint the coin's pane; the worker thread advances it.
const Phase = enum(u8) { idle, downloading, extracting, done, failed };

/// Whether a coin's daemon is up. `starting`/`stopping` are the in-flight states
/// while a start/stop worker runs (both animate a spinner in the pane), settling
/// to `running` or `stopped` when the worker publishes its outcome.
const DaemonState = enum { stopped, starting, running, stopping };

/// Which tab of the coin detail pane is showing. `home` is everything the pane
/// historically showed (status, sync/disk/memory bars, install activity, daemon
/// button); the rest are scaffolded panes filled in later. The coin name and
/// balance header stay pinned above the tabs regardless of which is active.
/// The capability tabs sit last (past `settings`) so the 1–5 muscle memory of
/// the first five tabs is identical on every coin — `mining` exists only for a
/// coin whose daemon mines in-process (`supportsMining`), `digidollar` only for
/// a coin with a chain-native stablecoin (`supportsStablecoin`). The numbered
/// jumps map over the *visible* strip (see `visibleTabAt`), so each coin's tabs
/// are always a contiguous 1..N.
const DetailTab = enum {
    home,
    transactions,
    receive,
    send,
    settings,
    mining,
    digidollar,
    staking,

    fn label(self: DetailTab) []const u8 {
        return switch (self) {
            .home => "Home",
            .transactions => "Transactions",
            .receive => "Receive",
            .send => "Send",
            .settings => "Settings",
            .mining => "Mining",
            .digidollar => "DigiDollar",
            .staking => "Staking",
        };
    }
};

/// Which capability tabs the current coin earns. A struct rather than a growing
/// list of positional bools: every tab-strip helper takes it, so adding a tab is
/// one field and one `tabVisible` arm instead of re-threading every call site.
const TabCaps = struct {
    mining: bool = false,
    stablecoin: bool = false,
    staking: bool = false,

    fn of(coin: Coin) TabCaps {
        return .{
            .mining = coin.supportsMining(),
            .stablecoin = coin.supportsStablecoin(),
            // The *action* earns the tab, not the list: a coin that can stake
            // but can't yet enumerate its stakes still has something to put
            // there. The list is the tab's body, and its absence is a shorter
            // page, not a missing tab.
            .staking = coin.supportsStakeAction(),
        };
    }
};

/// Whether `t` exists on the current coin's strip — the capability tabs only
/// exist where the coin wires the capability.
fn tabVisible(t: DetailTab, caps: TabCaps) bool {
    return switch (t) {
        .mining => caps.mining,
        .digidollar => caps.stablecoin,
        .staking => caps.staking,
        else => true,
    };
}

/// How many tabs the current coin shows — 5 plus its capability tabs. Drives
/// the strip hint's "1-N".
fn visibleTabCount(caps: TabCaps) usize {
    var n: usize = 0;
    inline for (std.meta.tags(DetailTab)) |t| {
        if (tabVisible(t, caps)) n += 1;
    }
    return n;
}

/// The `idx`-th (0-based) *visible* tab for the current coin, or null past the
/// end. The numbered jumps go through this so tab numbers are positional over
/// what's on screen: a coin with a stablecoin tab (and no mining) gets it on
/// `6`, exactly where a mining coin's Mining tab sits.
fn visibleTabAt(idx: usize, caps: TabCaps) ?DetailTab {
    var n: usize = 0;
    inline for (std.meta.tags(DetailTab)) |t| {
        if (tabVisible(t, caps)) {
            if (n == idx) return t;
            n += 1;
        }
    }
    return null;
}

/// Step to the next/previous detail tab, wrapping around the ends. `delta` is
/// +1 (right) or -1 (left). Tabs the coin doesn't have (`tabVisible` false) are
/// skipped straight over, so the cycle only ever lands on the visible strip.
fn cycleTab(t: DetailTab, delta: i2, caps: TabCaps) DetailTab {
    const n: i32 = @typeInfo(DetailTab).@"enum".fields.len;
    var next: DetailTab = t;
    // At most enum-length steps: enough to skip past every hidden tab even if
    // they sit adjacent at the wrap point.
    for (0..@typeInfo(DetailTab).@"enum".fields.len) |_| {
        next = @enumFromInt(@mod(@as(i32, @intFromEnum(next)) + delta, n));
        if (tabVisible(next, caps)) break;
    }
    return next;
}

/// Chain sync progress. `syncing` shows a spinner ("Syncing"), `synced` a green
/// tick ("Synced"), `idle` a red cross. Live sync polling lands later — for now
/// this defaults to `idle`.
/// Chain sync state — `status.zig`'s, so the readout and the TUI can't
/// disagree about what "syncing" means.
const SyncState = status_mod.Sync;

/// The sync spinner is a two-dot braille "puck" that circulates a rectangular
/// track `sync_track_cells` cells wide and one cell tall: along the top edge,
/// down the right, back along the bottom, and up the left. It laps clockwise
/// while connected (peers > 0) and anti-clockwise with no peers, so the
/// direction of travel signals connectivity at a glance.
const sync_track_cells = 4;

/// The four braille glyphs the puck wears at each height of a cell, so it reads
/// as a solid block riding the rectangle's edge: top row (dots 1+4), upper-mid
/// (2+5), lower-mid (3+6), bottom row (7+8).
const sync_top = "⠉";
const sync_mid_hi = "⠒";
const sync_mid_lo = "⠤";
const sync_bottom = "⣀";

/// Build one lap of the rectangular orbit at comptime as (cell, glyph) steps,
/// then render each step into a `sync_track_cells`-wide frame (the puck glyph in
/// its cell, blanks elsewhere). The clockwise lap runs top→right→bottom→left;
/// the anti-clockwise lap is the same path reversed. Both directions produce the
/// same frame count and constant width, so `onTick` can swap `frames`
/// mid-animation without the spinner's frame index going out of range or the
/// status line jittering. Frames per lap = 2·cells + 4 (top `cells`, right 3,
/// bottom `cells`-1, left 2) — at the spinner's 10fps, ~1.2s per lap at width 4.
fn syncOrbitFrames(comptime clockwise: bool) *const [2 * sync_track_cells + 4][]const u8 {
    comptime {
        @setEvalBranchQuota(20_000);
        const W = sync_track_cells;
        const Step = struct { cell: usize, ch: []const u8 };

        var steps: [2 * W + 4]Step = undefined;
        var n: usize = 0;
        // Top edge, left → right.
        var c: usize = 0;
        while (c < W) : (c += 1) {
            steps[n] = .{ .cell = c, .ch = sync_top };
            n += 1;
        }
        // Right edge, descending the last cell (top corner already placed).
        steps[n] = .{ .cell = W - 1, .ch = sync_mid_hi };
        n += 1;
        steps[n] = .{ .cell = W - 1, .ch = sync_mid_lo };
        n += 1;
        steps[n] = .{ .cell = W - 1, .ch = sync_bottom };
        n += 1;
        // Bottom edge, right → left (bottom-right corner already placed).
        c = W - 1;
        while (c > 0) : (c -= 1) {
            steps[n] = .{ .cell = c - 1, .ch = sync_bottom };
            n += 1;
        }
        // Left edge, ascending the first cell back toward the top (which the next
        // lap re-places, so it isn't repeated here).
        steps[n] = .{ .cell = 0, .ch = sync_mid_lo };
        n += 1;
        steps[n] = .{ .cell = 0, .ch = sync_mid_hi };
        n += 1;

        var frames: [2 * W + 4][]const u8 = undefined;
        for (steps, 0..) |st, i| {
            var s: []const u8 = "";
            var cc: usize = 0;
            while (cc < W) : (cc += 1) s = s ++ (if (cc == st.cell) st.ch else " ");
            // Reverse the frame order for the anti-clockwise lap.
            frames[if (clockwise) i else frames.len - 1 - i] = s;
        }
        const out = frames;
        return &out;
    }
}

const sync_frames_cw = syncOrbitFrames(true);
const sync_frames_ccw = syncOrbitFrames(false);

test "sync orbit frames: equal counts, every frame exactly sync_track_cells wide" {
    // Equal length keeps the mid-animation `frames` swap in `onTick` in range.
    try std.testing.expectEqual(sync_frames_cw.len, sync_frames_ccw.len);
    // Constant display width keeps the status line from jittering frame to frame.
    for (sync_frames_cw) |f| try std.testing.expectEqual(@as(usize, sync_track_cells), zz.width(f));
    for (sync_frames_ccw) |f| try std.testing.expectEqual(@as(usize, sync_track_cells), zz.width(f));
}

/// Wallet encryption/lock status as the TUI renders it. The *state* itself is
/// `models.WalletSecurity`, straight from the coin layer — this side owns only
/// the display text and colour. There used to be a parallel `WalletState` enum
/// here, with a `fromSecurity` mapper and a test whose whole job was asserting
/// the two stayed in step; the state now makes one round-trip fewer.
fn walletText(w: models.WalletSecurity) []const u8 {
    return switch (w) {
        .unknown => "Unknown",
        .unencrypted => "Unencrypted",
        .locked => "Locked",
        .unlocked => "Unlocked",
        .unlocked_for_staking => "Unlocked for staking",
    };
}

fn walletColor(w: models.WalletSecurity) zz.Color {
    return switch (w) {
        .unknown => .brightBlack,
        .unencrypted => .red,
        .locked => .yellow,
        .unlocked => .cyan,
        .unlocked_for_staking => .green,
    };
}

/// Display text for a daemon warm-up phase — shared with the GUI front-end, so
/// both name the stages identically (see `warmup.zig`).
const loadingPhaseText = warmup.phaseText;

/// Render the coin's one-line **Status** — a live readout of what the daemon is
/// doing right now, distinct from the per-axis ticks below it. Priority, highest
/// first: installing (downloading/extracting) → not installed → starting/stopping
/// → checking (first poll pending) → warm-up phase (Loading/Verifying/…) →
/// waiting for peers → syncing → synced; "Idle" when the daemon is installed but
/// off. The wording alone carries the state — no spinner icon — and refreshes
/// each poll/tick.
fn renderStatus(a: std.mem.Allocator, act: *const Activity, brand: zz.Color) []const u8 {
    const in = act.statusInput();
    const r = status_mod.readout(in);
    const label = App.statusLabel(a, brand, "Status", r.active);

    // The appended figure — a presync/block-loading percentage, or the tilde'd
    // block-index estimate. `status.zig` decides which (if any) this line takes,
    // so the GUI appends the same one at the same precision; it stays out of
    // `r.text` because the log records that verbatim on change and a live
    // percentage would churn it every poll.
    var sbuf: [32]u8 = undefined;
    const suffix = status_mod.suffix(&sbuf, in, r);
    const text = if (suffix.len == 0)
        r.text
    else
        std.fmt.allocPrint(a, "{s}{s}", .{ r.text, suffix }) catch r.text;

    // Every live status reads in the *coin's* colour — one colour for the whole
    // line, whatever it currently says, rather than BoxWallet green for some
    // states and a per-state cyan/yellow/green for others. Inactive states (Not
    // installed / Idle) keep their own tone's grey, which is what pairs them
    // with the greyed label.
    //
    // The wording is the whole line: no chain height is appended, because the
    // Blocks bar below already says how far the chain has reached — this line
    // answers "what is it doing?" and reads "Syncing blocks…" then "Synced".
    const text_col: zz.Color = if (r.active) brand else toneColor(r.tone);
    const value = (zz.Style{}).bold(true).fg(text_col).render(a, text) catch text;
    return std.fmt.allocPrint(a, "{s}: {s}", .{ label, value }) catch value;
}

const loadEtaPercent = status_mod.loadEtaPercent;
const StatusReadout = status_mod.Readout;

/// The status readout for this activity. A thin shim over `status_mod.readout`:
/// `Activity.statusInput` is then the one place a field can be mis-mapped, and
/// the snapshot also makes the readout self-consistent — this used to call
/// `daemonState()` and then `awaitingStatus()` called it *again*, two atomic
/// loads that could disagree inside one frame.
fn statusReadout(act: *const Activity) StatusReadout {
    return status_mod.readout(act.statusInput());
}

/// `status_mod.Tone` → the TUI's palette. Only ever consulted for an *inactive*
/// status: an active one reads in the brand colour regardless (see
/// `renderStatus`), which is why the working/warning tones look unused here.
fn toneColor(t: status_mod.Tone) zz.Color {
    return switch (t) {
        .idle => .brightBlack,
        .working => .cyan,
        .warning => .yellow,
        .ok => .green,
    };
}


// Which wallet actions a coin offers, and in which state, is policy rather than
// presentation — it lives in `walletmenu.zig` so the GUI can't reach a different
// answer. The labels go with it: `restore` and `restore_file_offline` take
// different files and BitcoinZ offers both at once, so a front-end inventing its
// own wording is how someone picks the wrong one.
const WalletAction = walletmenu.Action;
const WalletSetupOp = walletmenu.SetupOp;
const SetupChoice = walletmenu.SetupChoice;
const menuChoicesFor = walletmenu.choicesFor;


/// The `w` wallet menu — a small modal drawn over the dashboard for managing the
/// selected coin's wallet. It walks menu → passphrase entry → working → result;
/// the chosen action runs against the daemon on a worker thread (so the UI never
/// blocks), with the passphrase held only in the `App`'s `pw_input` and the
/// worker's bounded buffer, both cleared once the action is sent.
const Modal = struct {
    /// The bitcoin in-daemon flow uses `menu`/`password`; the external-wallet
    /// (Monero) flow adds `setup_*`. `working`/`result` are shared by both.
    const Stage = enum {
        menu,
        password,
        working,
        result,
        /// External-wallet setup: pick create / restore-seed / restore-file.
        setup_menu,
        /// External-wallet: enter the new/opening wallet password.
        setup_password,
        /// External-wallet: re-enter a *new* password to confirm it matches (so a
        /// typo can't lock the user out of a wallet they can never reopen).
        setup_password_confirm,
        /// External-wallet: type/paste the restore seed (length per coin).
        setup_seed_input,
        /// External-wallet: browse for a wallet file to import. Also reused by the
        /// bitcoin-style offline file restore (`restore_file_offline`).
        setup_file,
        /// Confirm the destructive offline file restore (`restore_file_offline`):
        /// the current wallet.dat is replaced — the daemon is bounced to load the
        /// backup. The old wallet.dat is kept as a `.bak`, so this is a plain
        /// enter-to-proceed confirm, not a typed-word gate.
        restore_file_confirm,
        /// External-wallet: show the freshly-created seed to write down.
        setup_seed_show,
        /// External-wallet: quiz the user on a few seed words to confirm the backup.
        setup_seed_verify,
        /// External-wallet: typed confirmation before destroying an existing wallet
        /// to create/restore a different one (the "Replace wallet" path).
        setup_replace_confirm,
    };

    stage: Stage = .menu,
    /// Index into `options[0..option_count]`.
    sel: usize = 0,
    options: [walletmenu.max_options]WalletAction = undefined,
    option_count: usize = 0,
    /// The action chosen at the menu (valid from the password stage on).
    action: WalletAction = .unlock,
    /// The entry slot the modal acts on, so its worker writes the right Activity
    /// even if the left-nav selection changes while it's open.
    coin_idx: usize = 0,
    /// Whether the finished action succeeded (tints the result line).
    ok: bool = false,
    /// Outcome text shown in the `result` stage (fixed buffer — no allocation).
    msg_buf: [200]u8 = undefined,
    msg_len: usize = 0,

    // --- external-wallet (setup) flow --------------------------------------
    /// Cursor on the setup menu, into `setup_options[0..setup_option_count]`.
    setup_sel: usize = 0,
    /// The menu choices for this coin/state, filled when the menu opens (the
    /// setup choices via `menuChoicesFor`, or a single `.lock` for an open wallet).
    setup_options: [walletmenu.max_choices]SetupChoice = undefined,
    setup_option_count: usize = 0,
    /// The first entry of a new password, stashed while the confirm field is typed
    /// so the two can be compared. Plaintext, so it's wiped as soon as it's used or
    /// the modal closes (memory/secret hygiene, like the worker's copy).
    pw_first_buf: [wallet_pw_max]u8 = undefined,
    pw_first_len: usize = 0,
    /// Set when a confirm entry didn't match, so the password prompt can say so.
    pw_mismatch: bool = false,
    /// The external-wallet op in flight (chosen at the setup menu, or `.open`).
    setup_op: WalletSetupOp = .create,
    /// The mnemonic to display at `setup_seed_show`, copied from the worker's
    /// result when a create succeeds.
    seed: models.Seed = .{},
    /// Backup-verification quiz (`setup_seed_verify`): the three 1-based seed-word
    /// positions the user must re-enter to prove they wrote the mnemonic down, the
    /// current step into them, and whether the last answer was wrong (for the note).
    verify_pos: [3]usize = .{ 0, 0, 0 },
    verify_step: usize = 0,
    verify_bad: bool = false,
    /// Whether the typed text on `setup_replace_confirm` didn't match the required
    /// confirmation word yet (drives the "type REPLACE to confirm" hint state).
    replace_bad: bool = false,

    fn setMsg(self: *Modal, ok: bool, text: []const u8) void {
        self.ok = ok;
        const n = @min(text.len, self.msg_buf.len);
        @memcpy(self.msg_buf[0..n], text[0..n]);
        self.msg_len = n;
        self.stage = .result;
    }
};

/// The QuickSync prompt — a small modal shown when starting a daemon on a coin
/// whose sync accelerator (Nerva's quicksync) is on offer (chain not yet synced,
/// helper not already present). It walks confirm → downloading → (failed); on the
/// user's yes the ~130 MB helper downloads on a worker thread, then the daemon
/// starts. Distinct from the wallet `Modal` so the two flows don't entangle.
const QuickSyncModal = struct {
    const Stage = enum {
        /// Yes/No: download the accelerator and sync fast, or sync normally.
        confirm,
        /// The accelerator is downloading (progress read from the Activity).
        downloading,
        /// The user paused it. What's on disk is kept, so this is a resting
        /// state, not an error — resume it now, or start without it and pick it
        /// up on a later run.
        paused,
        /// The download failed; offer to start without it or cancel.
        failed,
    };

    stage: Stage = .confirm,
    /// The entry the prompt acts on, so the worker/reap target the right Activity
    /// even if the left-nav selection moves while it's open.
    coin_idx: usize = 0,
    /// Cursor on the confirm menu (0 = Yes, 1 = No).
    sel: usize = 0,
    /// Accelerator name + one-line pitch, copied from the coin's capability.
    name: []const u8 = "",
    detail: []const u8 = "",
    /// The trust caution, when this accelerator carries one (`trusts_publisher`)
    /// — empty when it doesn't. Held as the text rather than a flag so the
    /// wording stays in one place, shared with the GUI.
    trust_note: []const u8 = "",
    /// Bytes of a resumable download already on disk from an interrupted attempt
    /// (0 when there's nothing to resume). Sampled once when the prompt opens —
    /// it can't change while the prompt is up — so the confirm stage can say the
    /// download continues rather than restarts.
    resume_from: u64 = 0,
    /// Whether this accelerator survives an interrupted download at all, copied
    /// from the coin's capability. Distinct from `resume_from`, which is only
    /// non-zero once there *is* a partial: a first attempt is resumable but has
    /// nothing waiting yet.
    resumable: bool = false,
    /// Failure reason shown on the `failed` stage (fixed buffer — no allocation).
    msg_buf: [200]u8 = undefined,
    msg_len: usize = 0,

    fn setMsg(self: *QuickSyncModal, text: []const u8) void {
        const n = @min(text.len, self.msg_buf.len);
        @memcpy(self.msg_buf[0..n], text[0..n]);
        self.msg_len = n;
        self.stage = .failed;
    }
};

/// The Send prompt — enter a destination address, an amount, confirm, then
/// broadcast. A standalone modal (not folded into the wallet `Modal`'s
/// `WalletAction`, which is tightly coupled to the password/wallet-menu flow
/// and has no room for an address+amount payload) so it can own its own
/// worker and inputs cleanly, mirroring `QuickSyncModal`'s shape.
const SendModal = struct {
    const Stage = enum {
        /// Type/paste the destination address.
        address,
        /// Enter the amount to send.
        amount,
        /// Yes/No: send exactly this amount to this address? Shows the full,
        /// untruncated address — the one typo safety net a machine can't
        /// provide (format validation catches malformed addresses, not
        /// wrong-but-valid ones).
        confirm,
        /// The send RPC is in flight (outcome read from the Activity).
        working,
        /// Success (txid) or the daemon's own failure reason.
        result,
    };

    /// What the prompt does with the amount. `stake` (coins wiring
    /// `wallet_stake` — Salvium) reuses the same machinery minus the address
    /// stage: a stake pays the wallet's own address, so the flow starts at
    /// `amount` and the coin supplies the destination itself.
    const Mode = enum { send, stake };

    mode: Mode = .send,
    stage: Stage = .address,
    /// The entry the prompt acts on, so the worker/reap target the right
    /// Activity even if the left-nav selection moves while it's open.
    coin_idx: usize = 0,
    /// Confirm-menu cursor (0 = Yes, 1 = No).
    sel: u8 = 0,
    /// Set when the amount field failed to parse (non-numeric, zero, or
    /// negative) — never for "exceeds balance", since the cached balance can
    /// be stale; the daemon's own live check is the real gate.
    bad_input: bool = false,
    /// Whether the finished send succeeded (tints the result line).
    ok: bool = false,
    /// Outcome text shown in the `result` stage: the txid or the daemon's own
    /// failure reason (fixed buffer — no allocation).
    msg_buf: [256]u8 = undefined,
    msg_len: usize = 0,

    fn setMsg(self: *SendModal, ok: bool, text: []const u8) void {
        self.ok = ok;
        const n = @min(text.len, self.msg_buf.len);
        @memcpy(self.msg_buf[0..n], text[0..n]);
        self.msg_len = n;
        self.stage = .result;
    }
};

/// The Mining prompt — opened by `enter` on the Mining tab of a coin whose
/// daemon mines in-process (Nerva). Two entry stages, chosen by the miner's
/// current state: idle opens at `threads` (how many CPU threads to mine on,
/// typed into `mining_input`), active opens at `confirm_stop` (a plain
/// Yes/No). Both funnel into the same worker → `working` → `result` tail the
/// Send prompt uses.
const MiningModal = struct {
    const Stage = enum {
        /// Type the CPU thread count to mine on (1..the machine's threads).
        threads,
        /// Yes/No: stop the running miner?
        confirm_stop,
        /// The start/stop RPC is in flight (outcome read from the Activity).
        working,
        /// Success or the failure reason.
        result,
    };

    stage: Stage = .threads,
    /// The entry the prompt acts on, so the worker/reap target the right
    /// Activity even if the left-nav selection moves while it's open.
    coin_idx: usize = 0,
    /// Whether the in-flight op is a start (labels/messages); stops are the
    /// `confirm_stop` path.
    starting: bool = true,
    /// Confirm-menu cursor (0 = Yes, 1 = No).
    sel: u8 = 0,
    /// Set when the thread-count field failed to parse or is out of range.
    bad_input: bool = false,
    /// Whether the finished op succeeded (tints the result line).
    ok: bool = false,
    /// Outcome text shown in the `result` stage (fixed buffer — no allocation).
    msg_buf: [256]u8 = undefined,
    msg_len: usize = 0,

    fn setMsg(self: *MiningModal, ok: bool, text: []const u8) void {
        self.ok = ok;
        const n = @min(text.len, self.msg_buf.len);
        @memcpy(self.msg_buf[0..n], text[0..n]);
        self.msg_len = n;
        self.stage = .result;
    }
};

/// Which stablecoin op the Activity's stablecoin worker runs. `estimate` is
/// the mint flow's pre-confirm collateral quote; the rest are the real
/// transactions.
const StablecoinOp = enum { estimate, mint, send, redeem };

/// How many recent stablecoin transactions / collateral positions are cached
/// per coin for the stablecoin tab. Bounded like `tx_cache_cap`, per the
/// memory rule.
const sc_tx_cache_cap: usize = 10;
const sc_pos_cache_cap: usize = 8;

/// The stablecoin (DigiDollar) prompt — opened by `enter` on the stablecoin
/// tab of a coin with the capability. A small action menu fans out into the
/// three flows, all funnelling into the same confirm → working → result tail
/// the Send prompt uses:
///
///   mint:   amount → tier → estimating (collateral quote) → confirm
///   send:   address → amount → confirm
///   redeem: position (pick a redeemable vault) → confirm
///
/// The mint confirm shows the estimated collateral before anything is
/// committed — locking thousands of DGB is exactly the kind of action the
/// "don't lose the user's money to a typo" rule wants spelled out first.
const StablecoinModal = struct {
    const Stage = enum {
        /// Choose mint / send / redeem.
        menu,
        /// Type the recipient stablecoin address (send flow).
        address,
        /// Enter the USD amount (mint and send flows).
        amount,
        /// Pick a lock tier (mint flow).
        tier,
        /// The collateral estimate RPC is in flight (mint flow).
        estimating,
        /// Pick which redeemable position to redeem (redeem flow).
        position,
        /// Yes/No, with the full details spelled out.
        confirm,
        /// The mint/send/redeem RPC is in flight (outcome read from the Activity).
        working,
        /// Success (txid + collateral detail) or the daemon's own failure reason.
        result,
    };

    const Mode = enum { mint, send, redeem };

    stage: Stage = .menu,
    mode: Mode = .mint,
    /// The entry the prompt acts on, so the worker/reap target the right
    /// Activity even if the left-nav selection moves while it's open.
    coin_idx: usize = 0,
    /// Cursor on the action menu (0 = mint, 1 = send, 2 = redeem).
    menu_sel: u8 = 0,
    /// Cursor on the tier list (mint flow).
    tier_sel: u8 = 0,
    /// Cursor over the redeemable positions (redeem flow).
    pos_sel: u8 = 0,
    /// Confirm-menu cursor (0 = Yes, 1 = No).
    sel: u8 = 0,
    /// Set when the amount field failed to parse or is outside the mint bounds.
    bad_input: bool = false,
    /// The amount being minted/sent/redeemed, in integer cents (parsed at the
    /// amount stage; copied from the chosen position for a redeem).
    cents: i64 = 0,
    /// Estimated collateral (coin units) for the pending mint, from the
    /// estimate worker. Negative = the estimate failed; the confirm still
    /// proceeds but says the figure is unavailable (the daemon re-checks the
    /// real requirement at mint time regardless).
    estimate: f64 = -1,
    /// The chosen position's redeem handle (redeem flow), copied out of the
    /// poll cache at selection time so a mid-flow poll refresh can't swap the
    /// target under the confirm.
    pos_id_buf: [64]u8 = undefined,
    pos_id_len: usize = 0,
    /// Whether the finished op succeeded (tints the result line).
    ok: bool = false,
    /// Outcome text shown in the `result` stage (fixed buffer — no allocation).
    msg_buf: [256]u8 = undefined,
    msg_len: usize = 0,

    fn setMsg(self: *StablecoinModal, ok: bool, text: []const u8) void {
        self.ok = ok;
        const n = @min(text.len, self.msg_buf.len);
        @memcpy(self.msg_buf[0..n], text[0..n]);
        self.msg_len = n;
        self.stage = .result;
    }

    fn posId(self: *const StablecoinModal) []const u8 {
        return self.pos_id_buf[0..self.pos_id_len];
    }
};

/// How many of the coin's cached vaults are redeemable right now — the redeem
/// picker's list length.
fn redeemableCount(act: *const Activity) usize {
    var n: usize = 0;
    for (act.sc_pos_buf[0..act.sc_pos_count]) |*p| {
        if (p.can_redeem) n += 1;
    }
    return n;
}

/// The `idx`-th redeemable vault in the coin's cached position list (cache
/// order), or null past the end. The redeem picker walks only redeemable
/// vaults — locked ones are shown on the tab, not offered for redemption.
fn redeemablePositionAt(act: *const Activity, idx: usize) ?*const models.StablecoinPosition {
    var n: usize = 0;
    for (act.sc_pos_buf[0..act.sc_pos_count]) |*p| {
        if (!p.can_redeem) continue;
        if (n == idx) return p;
        n += 1;
    }
    return null;
}

// Money in and out, as text, lives in `money.zig` so the GUI renders the same
// figure the same way — it used to carry its own C++ amount formatter, which is
// how two front-ends end up printing one balance differently.
const parseDollarsToCents = money.parseDollarsToCents;
const formatCents = money.formatCents;
const formatMicroUsd = money.formatMicroUsd;


/// The prune prompt — a small modal shown the first time a prune-capable coin's
/// daemon starts (Bitcoin, Litecoin, Monero), asking how the blockchain should be
/// stored. On a choice it writes the coin's conf, then the daemon starts (via
/// `startAfterPrune`). Distinct from the wallet/QuickSync modals so the flows
/// don't entangle.
///
/// The menu is the coin's own `Coin.Pruning.presets`, since daemons don't agree on
/// the knob: a `.size_mib` coin picks a disk cap and gets a trailing "Custom…" row
/// that advances to a GB text field (`prune_input`); an `.on_off` coin (Monero)
/// just picks pruned or not, and has no custom row. Both are cached at open so the
/// key handler and the renderer agree on the row count.
const PruneModal = struct {
    const Stage = enum { menu, custom };

    stage: Stage = .menu,
    /// The entry the prompt acts on, so a moved left-nav selection doesn't misfire.
    coin_idx: usize = 0,
    /// Cursor over the menu: 0..presets.len presets, then `customRow` when offered.
    sel: usize = 0,
    /// The coin's menu rows, captured at open.
    presets: []const Coin.PrunePreset = &.{},
    /// Whether a trailing "Custom…" row is offered (`.size_mib` coins only).
    allow_custom: bool = false,
    /// Set when a typed custom amount didn't parse, so the field can flag it.
    bad_input: bool = false,

    /// Menu index of the trailing "Custom…" row (only meaningful when
    /// `allow_custom`), and the last selectable row.
    fn customRow(self: *const PruneModal) usize {
        return self.presets.len;
    }
    fn lastRow(self: *const PruneModal) usize {
        return if (self.allow_custom) self.presets.len else self.presets.len -| 1;
    }
};

/// The update-confirm prompt — shown when the user presses `u` on a coin with an
/// available update. Confirm-only: on Yes the stop → reinstall → restart sequence
/// runs and its progress is shown in the main pane (Stopping… → Downloading… →
/// Starting…), so there's no multi-stage modal to drive. `from` is the installed
/// version captured at open; the target is the coin's pinned `core_version`.
const UpdateModal = struct {
    coin_idx: usize,
    /// Confirm-menu cursor (0 = Yes, 1 = No).
    sel: u8 = 0,
    from_buf: [32]u8 = undefined,
    from_len: usize = 0,
    /// True when opened by `i` on an already-installed coin (a deliberate
    /// reinstall) rather than by `u` for an available update — drives the
    /// title/wording. Both confirm into the same stop → install → restart flow.
    reinstall: bool = false,

    fn from(self: *const UpdateModal) []const u8 {
        return self.from_buf[0..self.from_len];
    }
};

/// Upper bound on a wallet passphrase, sizing the worker's copy buffer and the
/// modal input's char limit. Comfortably past any sane passphrase length while
/// keeping the secret in a small fixed buffer (memory constraint).
const wallet_pw_max = 256;

/// Inner content width (columns) of the wallet modal box — the area between the
/// `│ ` and ` │`. Sized to hold the longest menu label, the passphrase field,
/// and the footer hints without wrapping, while fitting an 80-column terminal.
const modal_inner_w = 42;

// Seed handling — counting, indexing and the backup quiz — lives in `seed.zig`
// so both front-ends ask the same question the same way. The GUI used to pick
// the quiz positions from a clock-seeded `std::mt19937`.
const seedCountAccepted = seed_mod.countAccepted;

/// Per-coin install activity.
///
/// An install runs on its own background thread so the event loop stays
/// responsive — you can kick off a download on one coin, switch to another and
/// start a second, then come back and watch the first finish. The thread and
/// the UI communicate only through the atomics below, so no coin's activity
/// touches another's, and the UI paints whichever coin is selected from this
/// state without ever blocking.
///
/// Memory stays flat per the project's constraint: each worker installs through
/// its own arena over the page allocator (freed when the task ends), and the UI
/// side holds only these few fixed fields — no buffered payloads.
const Activity = struct {
    // --- shared with the worker thread ---------------------------------
    // `phase` carries the synchronization edge: the worker publishes its final
    // result with a release store, the UI observes it with an acquire load, and
    // that pairing also publishes `err_name`. The byte counters are a cosmetic
    // progress bar, so they ride along on plain monotonic ordering.
    phase: std.atomic.Value(u8) = .init(@intFromEnum(Phase.idle)),
    dl_cur: std.atomic.Value(u64) = .init(0),
    dl_total: std.atomic.Value(u64) = .init(0),
    /// Streaming-extract byte tally (no meaningful total — drives the spinner).
    ex_count: std.atomic.Value(u64) = .init(0),
    /// Static error name (program-lifetime). Safe to read once `phase` reads
    /// `.failed` via the acquire load.
    err_name: []const u8 = "",

    // --- sync-accelerator (QuickSync) download worker ----------------------
    // Reuses `dl_cur`/`dl_total` for the progress bar (no install runs for the
    // same coin while its daemon is being started). `qs_done` carries the sync
    // edge: the worker stores it release, the UI loads it acquire, publishing
    // `qs_ok`/`qs_err` alongside.
    /// The accelerator-download worker, reaped by the UI when `qs_done` is seen.
    qs_thread: ?std.Thread = null,
    qs_done: std.atomic.Value(bool) = .init(false),
    /// Whether the download succeeded (read once `qs_done` is observed).
    qs_ok: bool = false,
    /// Static error name on failure (program-lifetime — `@errorName`).
    qs_err: []const u8 = "",
    /// Which step the worker is on, so the prompt can distinguish the download
    /// from the unpack that follows it for a chain snapshot — two very long
    /// phases, and a bar that silently restarts at 0% reads as a bug. Values are
    /// `install_mod.Phase`; polled by the render path, hence atomic.
    qs_phase: std.atomic.Value(u8) = .init(@intFromEnum(install_mod.Phase.download)),
    /// Pause request for the accelerator worker: set by the UI thread, polled by
    /// the transfer between chunks. A chain snapshot runs for the better part of
    /// an hour, so the user must be able to stop it — and the app must be able to
    /// stop it on the way out — without losing the bytes already fetched.
    qs_pause: std.atomic.Value(bool) = .init(false),

    // --- worker inputs: set by the UI before spawn, read by the worker -----
    coin: Coin = undefined,
    install_root: []const u8 = "",
    /// Process home dir, copied in before a poll spawns so the worker can find
    /// the coin's conf (e.g. `~/.divi/divi.conf`) for its RPC credentials.
    home_dir: []const u8 = "",
    /// Process environment, set before a daemon-start worker spawns so the
    /// daemon inherits $HOME etc. and can resolve its datadir. Null until set.
    environ_map: ?*const std.process.Environ.Map = null,

    // --- live getinfo poll (shared with the poll worker) -------------------
    // A short-lived worker fires one `getinfo` and publishes the result. Like
    // `phase`, `poll_done` carries the synchronization edge: the worker stores
    // it with release, the UI loads it with acquire, and that pairing publishes
    // `poll_ok` and the counter stores alongside it.
    /// One-shot `getinfo` poll worker, reaped on a later tick.
    poll_thread: ?std.Thread = null,
    /// For coins that need an explicit wallet (Bitcoin-Core 0.21+ forks): set once
    /// the wallet has been loaded/created this daemon run, so the one-time
    /// `ensureWallet` runs on the first successful poll and not every poll. Reset
    /// when the daemon is (re)started, since a fresh daemon won't have it loaded.
    wallet_ensured: bool = false,
    /// Highest chain heights this coin's daemon has reported since it was
    /// started, so a peer that knows less than the one it replaced can't walk the
    /// Headers readout backwards (see `tipwatch`). Reset on start/stop, where a
    /// lower height is legitimate.
    tip_marks: tipwatch.Ratchet = .{},
    /// Set once the coin's one-shot post-sync hook (`onSynced`) has been fired, so
    /// it runs the first time the chain reads as fully synced and not every poll
    /// thereafter. Unlike `wallet_ensured` it is *not* reset on daemon restart — the
    /// cleanup (e.g. dropping Nerva's quicksync file) is permanent for the install.
    synced_handled: bool = false,
    /// Set true (release) by the worker when the poll finishes; the UI folds the
    /// result in and joins the thread on its next tick.
    poll_done: std.atomic.Value(bool) = .init(false),
    /// Whether the finished poll reached the daemon. Plain field, published by
    /// the `poll_done` release/acquire pairing.
    poll_ok: bool = false,
    /// Whether the daemon's RPC port was at least reachable (a TCP connect
    /// succeeded), even if the status fetch itself didn't complete. Lets a
    /// busy-but-alive daemon — one accepting connections but stalling its RPC
    /// reply — read as "running" rather than "stopped". Plain field, published by
    /// the `poll_done` release/acquire pairing alongside `poll_ok`.
    poll_alive: bool = false,
    /// True once the first poll for this coin has been reaped (success or not).
    /// Until then — from the moment the coin is selected/installed and a poll is
    /// pending — the Running/Staking marks animate instead of showing a stale ✘.
    poll_completed: bool = false,
    /// Whether the "checking/received" status log pair has been emitted for the
    /// current selection. Reset each time the coin is (re)selected so a single
    /// pair is logged per selection rather than on every ~2s poll.
    status_logged: bool = false,
    /// The Status word last written to the live log for this coin, so a line is
    /// emitted only when the status actually changes (not every tick). Empty
    /// until the first status is logged; holds a static `StatusReadout.text`.
    last_status: []const u8 = "",
    /// Latest polled peer count / staking flag (1/0).
    poll_peers: std.atomic.Value(u32) = .init(0),
    poll_staking: std.atomic.Value(u8) = .init(0),
    /// Latest polled wallet security state (`@intFromEnum(models.WalletSecurity)`), from
    /// `getwalletinfo`. Only set for coins that expose a manageable wallet;
    /// otherwise stays at `unknown`. Published by the `poll_done` edge.
    poll_wallet: std.atomic.Value(u8) = .init(@intFromEnum(models.WalletSecurity.unknown)),
    /// Latest polled wallet balances, from `getwalletinfo` — only set for coins
    /// that report a balance (`supportsBalance`). The two figures are `f64`s held
    /// as their `u64` bit patterns (atomics take integers); `poll_has_balance`
    /// gates them so a never-fetched balance reads as "unknown" rather than 0.
    /// Published by the `poll_done` edge.
    poll_balance_total: std.atomic.Value(u64) = .init(0),
    poll_balance_avail: std.atomic.Value(u64) = .init(0),
    poll_has_balance: std.atomic.Value(u8) = .init(0),
    /// Latest polled mining state, for coins whose daemon mines in-process
    /// (`supportsMining` — Nerva). `poll_has_mining` gates them so the Mining
    /// tab reads "checking…" until the first successful fetch rather than a
    /// misleading "not mining". Published by the `poll_done` edge.
    poll_mining_active: std.atomic.Value(u8) = .init(0),
    poll_mining_threads: std.atomic.Value(u32) = .init(0),
    poll_mining_speed: std.atomic.Value(u64) = .init(0),
    poll_has_mining: std.atomic.Value(u8) = .init(0),
    /// Latest polled wallet rescan progress, for an in-daemon external wallet that
    /// re-scans after a restore (Ergo, via `ExternalWallet.rescan_progress`).
    /// `poll_rescanning` gates the scanned/target heights: 1 while a rescan is in
    /// flight, 0 when caught up or not applicable. Drives the "Rescanning… X%"
    /// wallet-line indicator. Published by the `poll_done` edge.
    poll_rescan_scanned: std.atomic.Value(u64) = .init(0),
    poll_rescan_target: std.atomic.Value(u64) = .init(0),
    poll_rescanning: std.atomic.Value(u8) = .init(0),
    /// Latest probed daemon warm-up phase (`@intFromEnum(models.LoadingPhase)`).
    /// Set on every poll: `none` when the daemon answered normally, otherwise the
    /// phase parsed from its "-28 in warm-up" reply. Published by the `poll_done`
    /// edge.
    poll_phase: std.atomic.Value(u8) = .init(@intFromEnum(models.LoadingPhase.none)),
    /// Block-loading sub-stage/percentage scraped from `debug.log` during the
    /// `.loading` warm-up phase (`@intFromEnum(LoadStage)` /
    /// basis points). Set alongside `poll_phase` in `probeLoadingPhase`;
    /// `.none`/0 when no such line is in the tail.
    poll_load_stage: std.atomic.Value(u8) = .init(@intFromEnum(LoadStage.none)),
    poll_load_pct_bp: std.atomic.Value(u32) = .init(0),
    /// Latest polled chain heights and sync flag, from `getblockchaininfo`.
    poll_headers: std.atomic.Value(u64) = .init(0),
    poll_blocks: std.atomic.Value(u64) = .init(0),
    poll_synced: std.atomic.Value(u8) = .init(0),
    /// Estimated network tip (max peer `synced_headers`), the Headers bar target.
    poll_network: std.atomic.Value(u64) = .init(0),
    /// Latest headers pre-sync percentage in basis points (744 == 7.44%), scraped
    /// from `debug.log` while syncing; 0 when synced or no presync line is found.
    /// The presync pass's progress isn't in RPC, so this is the only source.
    poll_presync_bp: std.atomic.Value(u32) = .init(0),
    /// Whether the last poll actually found a `"Pre-synchronizing
    /// blockheaders…"` line in `debug.log` — kept separate from
    /// `poll_presync_bp` so "found at 0.00%" isn't indistinguishable from "no
    /// line found" (both would otherwise read back as 0). When true this is an
    /// authoritative presync signal; when false (older forks whose daemon never
    /// logs the line, e.g. DigiByte) `applyPoll` falls back to inferring it.
    poll_presync_found: std.atomic.Value(u8) = .init(0),
    /// Seconds behind the chain tip (wall clock now − tip block timestamp),
    /// computed in the poll worker where the real-time clock is reachable.
    /// -1 means unknown (the daemon reports no tip timestamp). Drives the
    /// "behind by …" estimate on the Blocks line.
    poll_behind: std.atomic.Value(i64) = .init(-1),
    /// Tip block's own timestamp (unix seconds), for showing the date/time of
    /// the block being synced beside the Blocks bar. 0 when the daemon reports
    /// no usable tip timestamp.
    poll_tip_time: std.atomic.Value(i64) = .init(0),
    /// On-disk size of the coin's whole data directory (bytes), sampled by the
    /// poll worker on a slow cadence (a bounded directory walk — see
    /// `sampleStorage`). Drives the "Storage" line under the Blocks bar. Disk-
    /// derived, so it's meaningful whether or not the daemon is running.
    poll_storage_bytes: std.atomic.Value(u64) = .init(0),
    /// Whether the size above has been measured at least once (a real data dir
    /// was found and walked). Kept separate from `poll_storage_bytes` so a
    /// genuine tiny size isn't indistinguishable from "not measured yet / no
    /// data dir" — the render shows a dim "—" until this flips true.
    poll_storage_sampled: std.atomic.Value(u8) = .init(0),
    /// Worker-owned monotonic deadline (ns, from `std.Io.Clock.awake`) for the
    /// next storage sample. 0 = sample on the first poll; then set 30s ahead so
    /// the directory walk never rides the ~2s poll cadence.
    storage_next_ns: i128 = 0,

    // --- wallet action worker (the `w` menu) -------------------------------
    // A short-lived worker runs one encrypt/unlock/lock RPC so the UI never
    // blocks on it. Like the poll, `wallet_done` carries the synchronization
    // edge: the worker stores it with release, the UI loads it with acquire, and
    // that pairing publishes `wallet_ok`/`wallet_err`.
    wallet_thread: ?std.Thread = null,
    wallet_action: WalletAction = .unlock,
    /// The passphrase for the in-flight action, copied in before the worker is
    /// spawned and zeroed once the worker has consumed it. Bounded so the secret
    /// never lands in a growing buffer and memory stays flat.
    wallet_pw_buf: [wallet_pw_max]u8 = undefined,
    wallet_pw_len: usize = 0,
    /// Set true (release) by the worker when the action finishes.
    wallet_done: std.atomic.Value(bool) = .init(false),
    /// Whether the finished action succeeded. Published by the `wallet_done` edge.
    wallet_ok: bool = false,
    /// Error name from a failed action (static, program-lifetime), published with
    /// the `wallet_done` edge.
    wallet_err: []const u8 = "",

    // --- send worker (the Send tab) -----------------------------------------
    // A short-lived worker runs one `sendtoaddress`-style RPC so the UI never
    // blocks on it. Same synchronization edge as the wallet-action worker:
    // the worker stores `send_done` with release, the UI loads it with
    // acquire, and that pairing publishes `send_ok`/`send_result_buf`.
    // Standalone rather than folded into `wallet_thread`/`WalletAction` —
    // that pipeline is tightly coupled to the password/wallet-menu flow and
    // has no room for an address+amount payload.
    send_thread: ?std.Thread = null,
    /// The destination address for the in-flight send, copied in before the
    /// worker is spawned.
    send_addr_buf: [128]u8 = undefined,
    send_addr_len: usize = 0,
    send_amount: f64 = 0,
    /// True when the in-flight "send" is a stake (the Stake prompt) — routes
    /// the worker to `walletStake`, which needs no destination address.
    send_is_stake: bool = false,
    /// Set true (release) by the worker when the send finishes.
    send_done: std.atomic.Value(bool) = .init(false),
    /// Whether the finished send succeeded. Published by the `send_done` edge.
    send_ok: bool = false,
    /// The txid (success) or the daemon's own failure reason (rejection) —
    /// never a generic "it failed." Published by the `send_done` edge.
    send_result_buf: [256]u8 = undefined,
    send_result_len: usize = 0,

    // --- mining worker (the Mining tab) --------------------------------------
    // A short-lived worker runs one start_mining/stop_mining RPC so the UI
    // never blocks on it. Same synchronization edge as the send worker: the
    // worker stores `mining_done` with release, the UI loads it with acquire,
    // and that pairing publishes `mining_ok`/`mining_err`.
    mining_thread: ?std.Thread = null,
    /// Whether the in-flight op is a start (routes the worker and labels the
    /// reap log line).
    mining_starting: bool = true,
    /// CPU thread count for an in-flight start, copied in before spawn.
    mining_threads_req: u32 = 0,
    /// The payout address for an in-flight start — the wallet's own cached
    /// receive address, copied in before the worker is spawned (the cache
    /// itself is rewritten on the UI thread every poll, so the worker must not
    /// read it directly).
    mining_addr_buf: [128]u8 = undefined,
    mining_addr_len: usize = 0,
    /// Set true (release) by the worker when the op finishes.
    mining_done: std.atomic.Value(bool) = .init(false),
    /// Whether the finished op succeeded. Published by the `mining_done` edge.
    mining_ok: bool = false,
    /// Error name from a failed op (static, program-lifetime), published with
    /// the `mining_done` edge.
    mining_err: []const u8 = "",

    // --- stablecoin worker (the DigiDollar tab) ------------------------------
    // A short-lived worker runs one stablecoin RPC (a collateral estimate, or
    // a mint/send/redeem) so the UI never blocks on it. Same synchronization
    // edge as the send worker: the worker stores `sc_done` with release, the
    // UI loads it with acquire, and that pairing publishes
    // `sc_ok`/`sc_estimate`/`sc_result_buf`.
    sc_thread: ?std.Thread = null,
    /// Which op is in flight (routes the worker).
    sc_op: StablecoinOp = .estimate,
    /// The amount for the in-flight op, in integer cents, copied in before spawn.
    sc_cents: i64 = 0,
    /// The lock tier for an in-flight estimate/mint, copied in before spawn.
    sc_tier: u8 = 0,
    /// The destination address for an in-flight send, copied in before spawn.
    sc_send_addr_buf: [128]u8 = undefined,
    sc_send_addr_len: usize = 0,
    /// The position handle for an in-flight redeem, copied in before spawn.
    sc_position_buf: [64]u8 = undefined,
    sc_position_len: usize = 0,
    /// Set true (release) by the worker when the op finishes.
    sc_done: std.atomic.Value(bool) = .init(false),
    /// Whether the finished op succeeded. Published by the `sc_done` edge.
    sc_ok: bool = false,
    /// A finished estimate's collateral figure (coin units). Published by the
    /// `sc_done` edge.
    sc_estimate: f64 = 0,
    /// The txid (success, possibly with a collateral detail) or the daemon's
    /// own failure reason. Published by the `sc_done` edge.
    sc_result_buf: [256]u8 = undefined,
    sc_result_len: usize = 0,

    // --- stablecoin poll caches ----------------------------------------------
    // Live DigiDollar state for the stablecoin tab, only ever populated for a
    // coin whose `supportsStablecoin()` is true. Same staging/fold pattern as
    // the transaction/receive-address caches: the poll worker writes the
    // `poll_sc_*` fields before storing `poll_done` (release), and the UI folds
    // them after observing it (acquire). All fixed-capacity, per the memory rule.
    /// System state (deployment status, oracle price, supply/health), gated by
    /// `sc_has_info` so the tab reads "checking…" until the first fetch.
    sc_info: models.StablecoinInfo = .{},
    sc_has_info: bool = false,
    poll_sc_info: models.StablecoinInfo = .{},
    poll_sc_has_info: bool = false,
    /// The wallet's stablecoin balance (cents), gated by `sc_has_balance`.
    sc_balance: models.StablecoinBalance = .{},
    sc_has_balance: bool = false,
    poll_sc_balance: models.StablecoinBalance = .{},
    poll_sc_has_balance: bool = false,
    /// Recent stablecoin transactions, newest-first.
    sc_tx_buf: [sc_tx_cache_cap]models.StablecoinTx = undefined,
    sc_tx_count: usize = 0,
    poll_sc_tx_buf: [sc_tx_cache_cap]models.StablecoinTx = undefined,
    poll_sc_tx_count: usize = 0,
    /// Collateral positions (vaults).
    sc_pos_buf: [sc_pos_cache_cap]models.StablecoinPosition = undefined,
    sc_pos_count: usize = 0,
    poll_sc_pos_buf: [sc_pos_cache_cap]models.StablecoinPosition = undefined,
    poll_sc_pos_count: usize = 0,
    /// The stablecoin deposit address — like the coin's own receive address,
    /// fetched once (or on an explicit "new address"), never re-polled, so the
    /// displayed address can't rotate out from under the user.
    sc_addr_buf: [128]u8 = undefined,
    sc_addr_len: usize = 0,
    poll_sc_addr_buf: [128]u8 = undefined,
    poll_sc_addr_len: usize = 0,
    /// Set at the pre-spawn staging point (never while a poll is in flight)
    /// when the user pressed the stablecoin tab's "New address" key; consumed
    /// by `fetchStatus` whether or not the fetch succeeded.
    want_new_sc_address: bool = false,

    // --- external wallet process (Monero-style coins, e.g. Nerva) -----------
    // For `coin.hasExternalWallet()` coins the wallet is a *second* process
    // (`nerva-wallet-rpc`) BoxWallet spawns alongside the daemon and tears down
    // with it. The setup worker (below) creates/restores/opens a wallet through
    // its RPC; balance polling reads it once open.
    /// The wallet-rpc process and the per-session credentials it's locked to —
    /// the shared lifecycle in `extwallet.zig`, which the GUI drives too. Owned
    /// and touched only on the UI thread, except while the setup worker holds it
    /// during `launchWalletServer` (see the guard on the teardown call site).
    wallet_rpc: extwallet.Session = .{},
    /// Whether the managed wallet has been opened this session (create/restore/
    /// open succeeded). Gates balance polling; read on the poll worker, written on
    /// the UI thread, so it's atomic. Reset when the wallet-rpc is killed.
    ext_wallet_open: std.atomic.Value(u8) = .init(0),
    /// Whether a wallet file exists on disk (`externalWallet.exists`), refreshed
    /// on the UI thread. Drives the "no wallet / locked / open" pane hint and which
    /// setup flow `w` opens. UI-thread only.
    ext_wallet_exists: bool = false,

    /// The coin's configured prune target for the Settings tab, in MiB (0 = full
    /// node), or -1 when unknown/unset. Cached so the tab doesn't read the conf in
    /// the render path; refreshed lazily on the UI thread (`refreshPruneState`) and
    /// written directly when the prune prompt applies a value. UI-thread only.
    prune_mib: i64 = -1,
    /// Whether `prune_mib` has been read from the conf yet — a one-shot latch so the
    /// read happens once per selection rather than every tick. Re-armed nowhere: the
    /// value only changes via the prune prompt, which sets `prune_mib` directly.
    prune_read: bool = false,

    // --- external-wallet setup worker --------------------------------------
    // Mirrors the wallet-action worker: one create/restore/open RPC on a private
    // arena, published via `wallet_setup_done` (release) and reaped in `onTick`.
    wallet_setup_thread: ?std.Thread = null,
    wallet_setup_op: WalletSetupOp = .create,
    wallet_setup_done: std.atomic.Value(bool) = .init(false),
    wallet_setup_ok: bool = false,
    wallet_setup_err: []const u8 = "",
    /// The daemon's own failure message (when it gave one), filled by the wallet op
    /// via `wallet_setup_sink`. Logged alongside the error name and shown in the
    /// modal so the user sees the real reason, not just a generic error.
    wallet_setup_sink: Coin.WalletErrSink = .{},
    /// Mnemonic produced by a successful `create`, read by the UI after the edge.
    wallet_setup_seed: models.Seed = .{},
    /// Restore-seed words, copied in before spawn (bounded; cleared after use).
    wallet_seed_buf: [256]u8 = undefined,
    wallet_seed_len: usize = 0,
    /// Restore-file source path, copied in before spawn.
    wallet_file_buf: [1024]u8 = undefined,
    wallet_file_len: usize = 0,

    // --- UI-thread-only ----------------------------------------------------
    thread: ?std.Thread = null,
    /// Joins the daemon start/stop worker once it has published its result.
    daemon_thread: ?std.Thread = null,
    /// Handle to a *foreground* daemon we launched this session, retained so a
    /// coin with no shutdown RPC (Zano's zanod) can be stopped by killing it.
    /// Only meaningful for foreground coins — fork coins double-fork, so the
    /// spawned launcher isn't the daemon. Set by the start worker, read/killed by
    /// the stop worker, cleared on the UI thread once a stop is reaped; these are
    /// serialized through `daemon_thread`, so never touched concurrently. Null
    /// when no foreground daemon was started here (e.g. zanod from a prior session
    /// — the stop path then finds it by name).
    daemon_child: ?std.process.Child = null,
    /// Which daemon worker is in flight on `daemon_thread`, so the reap can log
    /// the right outcome (started/failed-to-start vs stopped/failed-to-stop).
    daemon_action: enum { start, stop } = .start,
    /// Set when the user pressed stop while a status poll was still in flight.
    /// The stop worker can't spawn until that poll is reaped (it would race the
    /// poll on `coin`), so `onTick` defers the spawn instead of the UI thread
    /// blocking on `poll_thread.join()`.
    stop_pending: bool = false,
    /// Latched true when BoxWallet deliberately stopped this daemon (the stop
    /// worker confirmed `.stopped`). While set, an automatic status poll must not
    /// resurrect the daemon to `.running` just because the node is still finishing
    /// its shutdown / still briefly answering. Cleared on the next explicit start.
    /// (The poll-driven running detection is wanted for a daemon started *outside*
    /// BoxWallet — this only suppresses it after our own stop.)
    stopped_by_us: bool = false,
    /// True when this run updates an existing daemon (heading reads "updating").
    updating: bool = false,
    /// Cleared when a run starts, set once its completion has been folded back
    /// into `installed` — so we re-check the daemon on disk exactly once.
    acked: bool = true,
    /// Cached "is the daemon on disk?", for the idle view + button label.
    installed: bool = false,
    /// Installed daemon version from the on-disk marker (empty = no marker, or not
    /// installed). Program-lifetime fixed buffer; versions are short.
    installed_version_buf: [32]u8 = undefined,
    installed_version_len: usize = 0,
    /// True when the pinned `core_version` is newer than the installed version.
    /// Recomputed whenever `installed` is refreshed; drives the "update available"
    /// badge and the `u` action.
    ///
    /// An installed coin with *no* version marker reads as **up to date**, not as
    /// "update available" — see `refreshUpdateState`. That's only safe because the
    /// marker always gets backfilled: from the live daemon for coins whose RPC
    /// reports a version, and from `<daemon> --version` for those whose doesn't
    /// (`stampVersionFromBinary`). A coin that has neither is invisible to update
    /// detection no matter how stale it is.
    update_available: bool = false,
    /// Set while a one-click update is mid-sequence: `update_await_stop` means we've
    /// asked the daemon to stop and the reinstall fires once it's down;
    /// `update_restart` means the daemon was up when the update began, so it's
    /// restarted once the reinstall completes. Both cleared as the sequence advances
    /// (or aborts).
    update_await_stop: bool = false,
    update_restart: bool = false,
    /// Set while an in-app "Replace wallet" is mid-sequence: we've asked the daemon
    /// to stop, and once it's down the old wallet is deleted and the daemon
    /// restarted (an in-daemon wallet like Ergo caches its secret, so the node must
    /// bounce before a new wallet can be created/restored). Cleared as it advances.
    wallet_replace_await_stop: bool = false,
    /// Set while an in-app offline wallet-file restore is mid-sequence: we've asked
    /// the daemon to stop, and once it's down the picked backup (in `wallet_file_buf`)
    /// is swapped over `wallet.dat` and the daemon restarted so it loads it (the
    /// daemon holds `wallet.dat` open while running, e.g. SpiderByte). Cleared as it
    /// advances.
    wallet_restore_await_stop: bool = false,
    /// Whether that restore should start the daemon once the swap is done — set
    /// only when the restore itself stopped a *running* daemon. A user who
    /// stopped the node first (the offline restore is now reachable that way, and
    /// it's the state the whole action wants) didn't ask for it back up, so it's
    /// left as they had it.
    wallet_restore_restart: bool = false,
    /// The running daemon's self-reported version (empty when down/unknown), for
    /// the "Running" line. Folded from `poll_version_*` after a poll; cleared on
    /// stop. Program-lifetime fixed buffer.
    version_buf: [32]u8 = undefined,
    version_len: usize = 0,
    /// Poll-staging for the running version: written by the poll worker before it
    /// stores `poll_done` (release), read by the UI after observing it (acquire),
    /// so those writes are ordered without a separate atomic.
    poll_version_buf: [32]u8 = undefined,
    poll_version_len: usize = 0,
    /// The daemon's own wording for the warm-up stage it's in ("Rewinding
    /// blocks…", "Loading masternode cache…"), and its poll-staging counterpart.
    /// Folded in on every reap alongside `loading_phase` — whether or not the poll
    /// reached the daemon, since this is published precisely when it didn't.
    ///
    /// Same size as `warmup.Status.msg_buf`, which is what fills it: sized for the
    /// longest stage message with room to spare.
    stage_buf: [96]u8 = undefined,
    stage_len: usize = 0,
    poll_stage_buf: [96]u8 = undefined,
    poll_stage_len: usize = 0,
    /// The coin's cached recent transactions (Transactions tab), newest-first.
    /// Folded from `poll_tx_*` after a poll; cleared on daemon stop. Only ever
    /// populated for a coin whose `supportsTransactions()` is true — stays empty
    /// (and unused) for every other coin. Fixed-capacity, matching the project's
    /// "bound the working set" memory rule.
    tx_buf: [tx_cache_cap]models.WalletTx = undefined,
    tx_count: usize = 0,
    /// Poll-staging for the transaction cache — same ordering rationale as
    /// `poll_version_buf`: written by the poll worker before `poll_done` (release),
    /// read by the UI after observing it (acquire).
    poll_tx_buf: [tx_cache_cap]models.WalletTx = undefined,
    poll_tx_count: usize = 0,
    /// The coin's cached stakes (Staking tab), newest-first, and its poll-staging
    /// counterpart. Same fixed-capacity, plain-buffer pattern as the transaction
    /// cache; only ever populated for a coin whose `supportsStakeList()` is true.
    stake_buf: [stake_cache_cap]models.Stake = undefined,
    stake_count: usize = 0,
    poll_stake_buf: [stake_cache_cap]models.Stake = undefined,
    poll_stake_count: usize = 0,
    /// The coin's cached receive address (Receive tab), and its poll-staging
    /// counterpart — same cross-thread plain-buffer pattern as the version/
    /// transaction caches. Unlike balance/transactions, this is fetched at
    /// most once passively (see `want_new_receive_address`), never every
    /// poll: `getaccountaddress` silently rotates once the address has been
    /// paid, so polling it on a timer would swap the displayed address out
    /// from under the user without their consent.
    receive_addr_buf: [128]u8 = undefined,
    receive_addr_len: usize = 0,
    poll_receive_addr_buf: [128]u8 = undefined,
    poll_receive_addr_len: usize = 0,
    /// Set by the UI thread (only at the pre-spawn staging point, never while
    /// a poll is in flight — see the spawn site) when the user pressed the
    /// Receive tab's "New address" key. `fetchStatus` consumes it: true means
    /// mint a brand-new address (`getnewaddress`) instead of the stable
    /// "current" one, and clears the flag whether or not the fetch succeeded.
    want_new_receive_address: bool = false,
    /// Set once we've stamped the version marker from the live daemon for an install
    /// that had none — so a pre-marker (legacy) install stops reading as "update
    /// available" without a reinstall. One-shot per session.
    version_stamp_done: bool = false,
    /// Set once the offline `--version` probe has been attempted (see
    /// `stampVersionFromBinary`). Separate from `version_stamp_done` so a probe that
    /// *fails* — missing binary, unparseable banner — isn't retried on every poll,
    /// spawning a process each time, while still leaving the RPC stamp free to fire.
    version_probe_done: bool = false,
    /// Whether this coin's daemon is up. Drives the "daemon running" line.
    /// Written by the daemon-start worker (release) and read by the UI
    /// (acquire), so it's atomic like `phase`.
    daemon: std.atomic.Value(u8) = .init(@intFromEnum(DaemonState.stopped)),
    /// Reason for the last failed daemon start — the daemon's own stderr when it
    /// printed one (e.g. "Cannot obtain a lock on data directory …"), otherwise
    /// the launcher error name. Published alongside the `.stopped` store in
    /// `runDaemon`, so it's safe to read once the UI observes the daemon is no
    /// longer `.starting`. Backed by `daemon_err_buf` (program-lifetime) because
    /// the worker's arena is gone by the time the UI reads it.
    daemon_err: []const u8 = "",
    daemon_err_buf: [200]u8 = undefined,
    /// Connected peer count. Red at 0, green once any peer is connected.
    /// (Live peer polling lands later — for now this stays 0.)
    peers: u32 = 0,
    /// Chain sync state. Drives the "Syncing"/"Synced" line.
    sync: SyncState = .idle,
    /// Wallet encryption/lock status. Drives the "Wallet" line.
    wallet: models.WalletSecurity = .unknown,
    /// Wallet balances, folded in from the poll for coins that report them.
    /// `has_balance` gates the Total/Available lines — false until the first
    /// successful balance fetch, so they stay hidden rather than flashing 0.
    /// `total` updates the instant funds hit the mempool; `available` trails until
    /// they confirm.
    balance_total: f64 = 0,
    balance_avail: f64 = 0,
    has_balance: bool = false,
    /// Wallet rescan progress, folded in from the poll for an external wallet that
    /// re-scans after a restore (Ergo, and the Monero-family wallet-rpc background
    /// refresh — Salvium/Nerva). `rescanning` gates the heights: true while a rescan
    /// is in flight, driving the "Rescanning… X%" wallet-line indicator.
    rescan_scanned: u64 = 0,
    rescan_target: u64 = 0,
    rescanning: bool = false,
    /// Whether the wallet is actively staking. Only shown for proof-of-stake
    /// coins; live staking polling lands later — for now this stays false.
    staking: bool = false,
    /// Live mining state (Mining tab), folded in from the poll for coins whose
    /// daemon mines in-process. `has_mining` gates the readout — false until
    /// the first successful fetch, so the tab shows "checking…" rather than a
    /// premature "not mining". Cleared on daemon stop.
    mining_active: bool = false,
    mining_threads: u32 = 0,
    mining_speed: u64 = 0,
    has_mining: bool = false,
    /// The daemon's warm-up phase while it's coming up (Loading/Verifying/…), or
    /// `none` once it's responsive. Folded in from `poll_phase` on each poll reap;
    /// drives the Wallet line's "loading" readout.
    loading_phase: models.LoadingPhase = .none,
    /// Block-loading sub-stage and its live percentage, folded in from
    /// `poll_load_stage`/`poll_load_pct_bp` alongside `loading_phase`. Only
    /// meaningful while `loading_phase == .loading`; refines that generic
    /// "Loading…" label into "Loading blocks…"/"Processing blocks…" with a
    /// live percentage when `debug.log` carries one of those lines.
    load_stage: LoadStage = .none,
    load_pct_bp: u32 = 0,
    /// Monotonic ns (the tick's `t.timestamp`) when this run's block-index load was
    /// first observed (`loading_phase == .loading_block_index`), or 0 when not
    /// timing one. Paired with `last_load_ms` to show a rough time-based estimate
    /// while a NovaCoin-era daemon (SpiderByte) loads — that load exposes no
    /// in-daemon progress, so the only gauge is "how long it took last time".
    load_timer_start_ns: i64 = 0,
    /// How long the previous block-index load took (ms), read from the coin's
    /// `.<daemon>.loadms` marker when timing starts; 0 = unknown (first ever load,
    /// so no estimate is shown). Persisted on each clean load completion.
    last_load_ms: u32 = 0,
    /// The current block-index-load estimate as a whole percent (1..99), or 0 for
    /// "no estimate" (not loading, or no prior duration). Recomputed each tick from
    /// the two fields above so `renderStatus` stays a pure read.
    load_eta_pct: u8 = 0,
    /// Headers/blocks sync progress (current vs total). Populated by the live
    /// sync poll later; 0/0 renders an empty bar.
    headers_cur: u64 = 0,
    headers_total: u64 = 0,
    blocks_cur: u64 = 0,
    blocks_total: u64 = 0,
    /// Whether the daemon is in Bitcoin Core 24+'s headers *pre-synchronization*
    /// pass. During presync the node downloads every header in a throwaway
    /// anti-DoS pass without committing any, so the committed `headers` height we
    /// display sits still while the node is busy — and RPC exposes no presync
    /// height. True when either `debug.log` confirms the pass directly
    /// (authoritative — see `poll_presync_found`), or, when the daemon never logs
    /// that line, when the committed header height has failed to advance for
    /// `presync_stall_threshold` *consecutive* polls (see `presync_stall_polls`).
    /// Requiring more than one stalled poll for the inferred path avoids flagging
    /// presync on a single momentary stall (peer latency, a poll landing just
    /// before a header lands) during an otherwise-normal header download, which
    /// would flip the "Pre-synching headers…"/"Syncing headers…" label back and
    /// forth every tick.
    presync: bool = false,
    /// Mirror of `coin.hasHeaderPresync()`, staged beside `coin` on the poll path
    /// so `applyPoll` needn't reach through the vtable (it also runs in tests that
    /// build an `Activity` without a coin). False pins `presync` off for coins
    /// with no such pass; true (the default) keeps Core's behaviour.
    has_header_presync: bool = true,
    /// Cross-poll state for the presync inference (previous header height and the
    /// consecutive-stall count). Lives in `status.zig` because deciding whether a
    /// node is in Core's presync pass is inference over several polls, not
    /// something either front-end should re-derive.
    presync_tracker: status_mod.PresyncTracker = .{},
    /// Headers pre-sync progress in basis points (744 == 7.44%), scraped from
    /// `debug.log` (the only place the presync pass exposes it). Appended to the
    /// "Pre-synching headers…" status line at render time; 0 when unknown.
    presync_bp: u32 = 0,
    /// Seconds behind the chain tip, or -1 when unknown. How far behind in
    /// wall-clock time the chain is while syncing.
    behind_secs: i64 = -1,
    /// Tip block's own timestamp (unix seconds), or 0 when unknown. Drives the
    /// "date/time of the block being synced" hint beside the Blocks bar.
    tip_time: i64 = 0,
    /// On-disk size of the coin's data directory (bytes), folded from
    /// `poll_storage_bytes` on poll reap. Rendered as the "Storage" figure.
    storage_bytes: u64 = 0,
    /// Whether `storage_bytes` reflects a real measurement yet (folded from
    /// `poll_storage_sampled`). False renders a dim "—" instead of a figure.
    storage_sampled: bool = false,
    spinner: zz.Spinner = undefined,
    /// Animates the "daemon running" line while `daemon` is `.starting`.
    daemon_spinner: zz.Spinner = undefined,
    /// Animates the sync line while `sync` is `.syncing`.
    sync_spinner: zz.Spinner = undefined,

    fn phaseOf(self: *const Activity) Phase {
        return @enumFromInt(self.phase.load(.acquire));
    }

    fn daemonState(self: *const Activity) DaemonState {
        return @enumFromInt(self.daemon.load(.acquire));
    }

    fn busy(self: *const Activity) bool {
        return switch (self.phaseOf()) {
            .downloading, .extracting => true,
            else => false,
        };
    }

    /// The installed daemon version recorded by the marker (empty when unknown).
    fn installedVersion(self: *const Activity) []const u8 {
        return self.installed_version_buf[0..self.installed_version_len];
    }

    /// The running daemon's self-reported version (empty when down/unknown).
    fn runningVersion(self: *const Activity) []const u8 {
        return self.version_buf[0..self.version_len];
    }

    /// The version of the daemon binary we believe is actually running: what the
    /// daemon reports over RPC, else the marker recorded for the binary on disk.
    ///
    /// The fallback matters because the two Monero forks (Nerva, Salvium) report no
    /// version over RPC at all, so `runningVersion` stays empty for them however long
    /// the daemon is up — and they're precisely the coins whose marker is stamped by
    /// probing the binary (`stampVersionFromBinary`). Since the daemon is launched
    /// *from* that binary, the marker is a faithful stand-in. Empty only when neither
    /// source knows.
    fn effectiveVersion(self: *const Activity) []const u8 {
        const rv = self.runningVersion();
        return if (rv.len > 0) rv else self.installedVersion();
    }

    /// True when the daemon we're running isn't the version BoxWallet pins — drives
    /// the warning on the "Running" line. False when no version is known at all
    /// (nothing to assert), and false for a version that merely *spells* differently
    /// (see `updater.differs`).
    fn versionMismatch(self: *const Activity, pinned: []const u8) bool {
        const v = self.effectiveVersion();
        return v.len > 0 and updater.differs(v, pinned);
    }

    /// Recompute `update_available` / `installed_version` from the on-disk marker
    /// versus the binary's pinned `core_version`. Cheap disk read, safe on the UI
    /// thread. `coin`/`install_root` are passed in because `act.coin` isn't set at
    /// rest.
    ///
    /// An installed coin with *no* marker (a pre-marker or hand-installed binary)
    /// reads as **up to date, not "update available"** — we don't know its version,
    /// and assuming it's behind would nag every legacy install on every coin. The
    /// version gets learned and stamped the first time that coin's daemon runs (see
    /// the poll's one-shot stamp), after which real updates show correctly; a future
    /// offline `--version` probe will fill it in without needing a run.
    fn refreshUpdateState(self: *Activity, allocator: std.mem.Allocator, coin: Coin, install_root: []const u8) void {
        self.installed_version_len = 0;
        self.update_available = false;
        if (!self.installed) return;

        const ver = install_mod.readVersionMarker(allocator, install_root, coin.daemonFile()) orelse return;
        defer allocator.free(ver);
        const n = @min(ver.len, self.installed_version_buf.len);
        @memcpy(self.installed_version_buf[0..n], ver[0..n]);
        self.installed_version_len = n;
        self.update_available = updater.isNewer(coin.coreVersion(), ver);
    }

    /// `install_mod.Progress` sink — runs on the worker thread. Publishes the
    /// running byte counts and the current phase into the shared atomics; the
    /// UI picks them up on its next frame.
    fn onProgress(ctx: *anyopaque, phase: install_mod.Phase, current: u64, total: u64) void {
        const self: *Activity = @ptrCast(@alignCast(ctx));
        switch (phase) {
            .download => {
                self.dl_total.store(total, .monotonic);
                self.dl_cur.store(current, .monotonic);
                self.phase.store(@intFromEnum(Phase.downloading), .monotonic);
            },
            .extract => {
                self.ex_count.store(current, .monotonic);
                self.phase.store(@intFromEnum(Phase.extracting), .monotonic);
            },
        }
    }

    /// `install_mod.Progress` sink for the sync-accelerator worker. Tracks the
    /// byte counters plus which step they belong to — unlike `onProgress` it
    /// leaves the pane's install `phase` alone, so the coin's install state stays
    /// untouched while the prompt's own bar reads `dl_cur`/`dl_total`/`qs_phase`.
    /// `install_mod.Cancel` sink for the accelerator worker: whether the UI has
    /// asked the transfer to stop (Pause, or the app shutting down).
    fn qsPauseRequested(ctx: *anyopaque) bool {
        const self: *Activity = @ptrCast(@alignCast(ctx));
        return self.qs_pause.load(.monotonic);
    }

    fn onQuicksyncProgress(ctx: *anyopaque, phase: install_mod.Phase, current: u64, total: u64) void {
        const self: *Activity = @ptrCast(@alignCast(ctx));
        self.qs_phase.store(@intFromEnum(phase), .monotonic);
        self.dl_total.store(total, .monotonic);
        self.dl_cur.store(current, .monotonic);
    }

    /// Sync-accelerator worker. Fetches the coin's accelerator on a private arena
    /// and, where the accelerator is a chain snapshot rather than a helper file,
    /// unpacks it into the data dir. The outcome is published via `qs_done`; the
    /// UI reaps it and, on success, starts the daemon.
    fn runQuicksyncDownload(self: *Activity) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const sa = self.coin.syncAccelerator() orelse {
            self.qs_err = "Unsupported";
            self.qs_ok = false;
            self.qs_done.store(true, .release);
            return;
        };
        const progress: install_mod.Progress = .{ .ctx = self, .func = onQuicksyncProgress };
        const cancel: install_mod.Cancel = .{ .ctx = self, .func = qsPauseRequested };
        self.qs_phase.store(@intFromEnum(install_mod.Phase.download), .monotonic);
        if (sa.download(a, self.install_root, self.home_dir, progress, cancel)) {
            // Downloaded. A snapshot still has to be put in place before the
            // daemon may start — an archive sitting in the install root does
            // nothing for the sync, so its failure fails the whole opt-in.
            if (sa.apply) |apply| {
                self.qs_phase.store(@intFromEnum(install_mod.Phase.extract), .monotonic);
                self.dl_cur.store(0, .monotonic);
                self.dl_total.store(0, .monotonic);
                if (apply(a, self.install_root, self.home_dir, progress, cancel)) {
                    self.qs_ok = true;
                } else |err| {
                    self.qs_err = @errorName(err);
                    self.qs_ok = false;
                }
            } else {
                self.qs_ok = true;
            }
        } else |err| {
            self.qs_err = @errorName(err);
            self.qs_ok = false;
        }
        self.qs_done.store(true, .release);
    }

    /// Worker thread body. Installs the coin on a private arena (so memory is
    /// bounded and isolated from the other coins' workers and the UI), then
    /// publishes the outcome.
    fn run(self: *Activity) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const progress: install_mod.Progress = .{ .ctx = self, .func = onProgress };
        if (self.coin.install(a, self.install_root, self.home_dir, progress)) {
            // Record what we just installed so update detection works even with the
            // daemon stopped. Best-effort: a marker hiccup doesn't fail an
            // otherwise-good install (detection just falls back to "recommended").
            install_mod.writeVersionMarker(a, self.install_root, self.coin.daemonFile(), self.coin.coreVersion()) catch {};
            self.phase.store(@intFromEnum(Phase.done), .release);
        } else |err| {
            self.err_name = @errorName(err);
            self.phase.store(@intFromEnum(Phase.failed), .release);
        }
    }

    /// Daemon-start worker. Launches `<daemon> -daemon` from the install root —
    /// the coin daemons (bitcoin-derived) fork themselves into the background
    /// and the launcher returns, so this thread is short-lived. Publishes
    /// `.running` on a clean exit, `.stopped` otherwise.
    fn runDaemon(self: *Activity) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        if (self.launchDaemon(a)) {
            self.daemon.store(@intFromEnum(DaemonState.running), .release);
        } else |err| {
            // Prefer the daemon's own stderr (set by launchDaemon); fall back to
            // the launcher error name when it had nothing to say (e.g. the binary
            // couldn't be spawned at all).
            if (self.daemon_err.len == 0) self.daemon_err = @errorName(err);
            self.daemon.store(@intFromEnum(DaemonState.stopped), .release);
        }
    }

    /// Daemon-stop worker. Asks the daemon to shut down via the JSON-RPC `stop`,
    /// then publishes `.stopped`; on an RPC failure it reverts to `.running` and
    /// records the reason. Runs on a private arena, reaped by the UI once the
    /// state settles.
    fn runStopDaemon(self: *Activity) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        if (self.requestStop(a)) {
            self.daemon.store(@intFromEnum(DaemonState.stopped), .release);
        } else |err| {
            self.daemon_err = @errorName(err);
            self.daemon.store(@intFromEnum(DaemonState.running), .release);
        }
    }

    /// Resolve the coin's RPC credentials, issue `stop`, then wait (bounded) for
    /// the daemon to actually exit — probing `getinfo` until it stops answering.
    /// Holding this worker thread blocks the status poll, so a mid-shutdown reply
    /// can't flip the daemon back to running once we've reported it stopped.
    ///
    /// Coins whose daemon has **no** shutdown RPC (`hasRpcStop` false — Zano)
    /// take the kill path instead: there's no request to send and no RPC port to
    /// watch drop, so the process is terminated and its absence confirmed by name.
    fn requestStop(self: *Activity, a: std.mem.Allocator) !void {
        var threaded: std.Io.Threaded = .init(a, .{});
        defer threaded.deinit();
        const io = threaded.io();

        if (!self.coin.hasRpcStop()) return self.stopDaemonByKill(io);

        const data_dir = try self.coin.dataDir(a, self.home_dir);
        const auth = try conf.readAuth(
            a,
            io,
            data_dir,
            self.coin.confFile(),
            self.coin.rpcDefaultUsername(),
            self.coin.rpcDefaultPort(),
        );

        // Ask the daemon to shut down. Bitcoin coins issue the JSON-RPC `stop`;
        // Ergo POSTs its REST `/node/shutdown`. The coin owns the request; the
        // probe loop below confirms it actually went down.
        //
        // A failed request is **not** proof the daemon is still up, so it isn't
        // returned here — only remembered. A busy daemon can act on the request and
        // still not answer it: monerod under a heavy sync leaves the reply sitting
        // behind starved RPC threads until the shutdown it just started tears the
        // RPC server down, so the reply never lands and we see a read failure or a
        // timeout for a stop that worked. Reporting that as "failed to stop" flips
        // the daemon back to running, which then re-spawns the wallet service for a
        // node that has already exited. The probe below is the real answer; the
        // remembered error only speaks if the daemon is still answering at the end.
        const req_err: ?anyerror = if (self.coin.requestStop(a, auth)) null else |err| err;

        // Probe on a small arena reset each round so the wait stays flat in
        // memory. The daemon drops its RPC port early in shutdown, so the first
        // failed probe means it's on its way down; cap the wait so a wedged
        // daemon doesn't pin the worker forever.
        //
        // A foreground daemon we launched is still our child, and an RPC shutdown
        // exits it behind our back — nothing has waited on it. Reap it each round
        // (and once more on the way out) so it doesn't sit as a zombie until the
        // app quits; a fork coin's launcher was already waited on at spawn, and a
        // prior-session daemon isn't ours, so both no-op here.
        var probe = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer probe.deinit();
        defer self.reapDaemonChild();
        var attempts: u8 = 0;
        while (attempts < 40) : (attempts += 1) {
            io.sleep(.fromMilliseconds(250), .awake) catch {};
            _ = probe.reset(.retain_capacity);
            self.reapDaemonChild();
            _ = self.coin.daemonInfo(probe.allocator(), auth) catch return;
        }

        // Still answering after the whole wait: the daemon is genuinely up. If the
        // stop request itself failed, that error is the honest reason to show;
        // otherwise it took the request and is simply slow to go (it's already
        // reported as stopped today, and that stands).
        if (req_err) |err| return err;
    }

    /// Reap the retained foreground child if it has already exited, so it doesn't
    /// linger as a zombie for the life of the app. A no-op when there's no handle,
    /// when it was reaped already, or when it's still running (`WNOHANG`).
    ///
    /// A foreground daemon is deliberately not waited on at spawn — it has to
    /// outlive `launchDaemon` — but we stay its parent, so *something* must
    /// eventually reap it. The kill path does so inline; every other way it can
    /// die (an RPC shutdown, or the process crashing on its own) needs this.
    ///
    /// `daemon_child` is serialized through `daemon_thread`, so call this either
    /// from the daemon worker or from the UI thread with no worker in flight.
    fn reapDaemonChild(self: *Activity) void {
        if (@import("builtin").os.tag == .windows) return; // no zombies to reap
        const child = self.daemon_child orelse return;
        const pid = child.id orelse return; // already reaped
        if (proc_mod.reapNoHang(pid)) self.daemon_child.?.id = null;
    }

    /// Stop a daemon that exposes no shutdown RPC (zanod) by terminating the
    /// process. SIGTERM lets zanod flush its LMDB chain DB; a SIGKILL backstop
    /// bounds a daemon that ignores it (LMDB is crash-safe, so a forced kill at
    /// worst loses unflushed writes and re-syncs). The target is found by binary
    /// name, so this works for both a daemon we started this session (also reaped
    /// via the retained handle, so it doesn't linger as a zombie) and one left
    /// running by a previous session.
    fn stopDaemonByKill(self: *Activity, io: std.Io) !void {
        const name = self.coin.daemonFile();

        if (@import("builtin").os.tag == .windows) {
            // No /proc to scan: kill our own handle if we have it (same session),
            // else fall back to taskkill by image name (prior session).
            if (self.daemon_child) |*child| {
                child.kill(io);
            } else {
                var killer = std.process.spawn(io, .{
                    .argv = &.{ "taskkill", "/F", "/IM", name },
                    .environ_map = self.environ_map,
                    .stdin = .ignore,
                    .stdout = .ignore,
                    .stderr = .ignore,
                    .create_no_window = true,
                }) catch return;
                _ = killer.wait(io) catch {};
            }
            return;
        }

        // POSIX: signal every matching process (covers our child and any from a
        // prior session uniformly), then confirm by name.
        _ = signalProcessesByName(io, name, std.posix.SIG.TERM);

        // Wait for it to actually exit, reaping our own child each round so its
        // zombie doesn't keep reading as alive via /proc (a prior-session daemon
        // is reaped by init, so it just disappears). Cap the wait so a wedged
        // daemon doesn't pin the worker forever.
        var attempts: u8 = 0;
        while (attempts < 40) : (attempts += 1) {
            io.sleep(.fromMilliseconds(250), .awake) catch {};
            if (self.daemon_child) |child| if (child.id) |pid| {
                _ = proc_mod.reapNoHang(pid);
            };
            if (!proc_mod.alive(io, name)) return;
        }

        // Still up after the grace window: force it, then reap our child once more.
        _ = signalProcessesByName(io, name, std.posix.SIG.KILL);
        if (self.daemon_child) |child| if (child.id) |pid| {
            const posix = std.posix;
            var status: if (@import("builtin").link_libc) c_int else u32 = undefined;
            while (posix.errno(posix.system.wait4(pid, &status, 0, null)) == .INTR) {}
        };
    }

    /// Wallet-action worker. Runs the chosen encrypt/unlock/lock RPC on a private
    /// arena (bounded, isolated) and publishes the outcome, reaped by the UI once
    /// `wallet_done` is observed.
    fn runWalletAction(self: *Activity) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        if (self.doWalletAction(a)) {
            self.wallet_ok = true;
        } else |err| {
            self.wallet_err = @errorName(err);
            self.wallet_ok = false;
        }
        self.wallet_done.store(true, .release);
    }

    /// Resolve the coin's RPC credentials and dispatch the in-flight wallet
    /// action. The passphrase comes from `wallet_pw_buf` (the UI copied it in
    /// before spawning); `lock` ignores it.
    fn doWalletAction(self: *Activity, a: std.mem.Allocator) !void {
        var threaded: std.Io.Threaded = .init(a, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const data_dir = try self.coin.dataDir(a, self.home_dir);
        const auth = try conf.readAuth(
            a,
            io,
            data_dir,
            self.coin.confFile(),
            self.coin.rpcDefaultUsername(),
            self.coin.rpcDefaultPort(),
        );

        const pw = self.wallet_pw_buf[0..self.wallet_pw_len];
        const path = self.wallet_file_buf[0..self.wallet_file_len];
        switch (self.wallet_action) {
            .encrypt => try self.coin.walletEncrypt(a, auth, pw),
            .unlock => try self.coin.walletUnlock(a, auth, pw, false),
            .stake => try self.coin.walletUnlock(a, auth, pw, true),
            .lock => try self.coin.walletLock(a, auth),
            .backup => try self.coin.walletBackup(a, auth, path),
            .restore => try self.coin.walletImportFile(a, auth, path),
            // The offline file restore never runs through this RPC worker — it's a
            // daemon-stopped file swap driven by the tick reap loop.
            .restore_file_offline => unreachable,
        }
    }

    /// Send worker. Runs one `sendtoaddress`-style RPC on a private arena
    /// (bounded, isolated) and publishes the outcome, reaped by the UI once
    /// `send_done` is observed. Unlike `runWalletAction`, a daemon-side
    /// rejection (invalid address, insufficient funds, locked wallet) isn't a
    /// Zig error — it's a normal `SendResult.failed` outcome, carrying the
    /// daemon's own message; only a genuine transport/setup failure falls
    /// into the `catch` (and even then, `@errorName` is the best available
    /// reason, matching how `runWalletAction` handles its own catch-all).
    fn runSend(self: *Activity) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const outcome: models.SendResult = self.doSend(a) catch |err| .{ .failed = @errorName(err) };
        switch (outcome) {
            .ok => |txid| {
                self.send_ok = true;
                self.stashSendResult(txid);
            },
            .failed => |msg| {
                self.send_ok = false;
                self.stashSendResult(msg);
            },
        }
        self.send_done.store(true, .release);
    }

    /// Resolve the coin's RPC credentials and dispatch the in-flight send.
    /// The address/amount come from `send_addr_buf`/`send_amount` (the UI
    /// copied them in before spawning).
    fn doSend(self: *Activity, a: std.mem.Allocator) !models.SendResult {
        const address = self.send_addr_buf[0..self.send_addr_len];

        // An external-wallet coin (Monero-style) sends/stakes from its *wallet*
        // process — its endpoint + per-session creds, no daemon conf to read.
        if (self.coin.hasExternalWallet()) {
            const wallet_auth = self.extWalletAuth();
            return if (self.send_is_stake)
                self.coin.walletStake(a, wallet_auth, self.send_amount)
            else
                self.coin.walletSend(a, wallet_auth, address, self.send_amount);
        }

        var threaded: std.Io.Threaded = .init(a, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const data_dir = try self.coin.dataDir(a, self.home_dir);
        const auth = try conf.readAuth(
            a,
            io,
            data_dir,
            self.coin.confFile(),
            self.coin.rpcDefaultUsername(),
            self.coin.rpcDefaultPort(),
        );

        return if (self.send_is_stake)
            self.coin.walletStake(a, auth, self.send_amount)
        else
            self.coin.walletSend(a, auth, address, self.send_amount);
    }

    /// Copy `text` (a txid or a failure reason) into the bounded
    /// `send_result_buf`, truncating if it somehow runs long — same shape as
    /// the transaction/receive-address cache copies elsewhere in this file.
    fn stashSendResult(self: *Activity, text: []const u8) void {
        const n = @min(text.len, self.send_result_buf.len);
        @memcpy(self.send_result_buf[0..n], text[0..n]);
        self.send_result_len = n;
    }

    /// Stablecoin worker. Runs one DigiDollar RPC (estimate / mint / send /
    /// redeem) on a private arena and publishes the outcome, reaped by the UI
    /// once `sc_done` is observed. Same shape as `runSend`.
    fn runStablecoin(self: *Activity) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        self.doStablecoin(a) catch |err| {
            self.sc_ok = false;
            self.stashScResult(@errorName(err));
        };
        self.sc_done.store(true, .release);
    }

    /// Resolve the daemon's RPC credentials and dispatch the in-flight
    /// stablecoin op. The payload (cents/tier/address/position) was copied in
    /// by the UI before spawning. The stablecoin RPCs live in the coin's own
    /// in-daemon wallet, so this always talks to the daemon's endpoint.
    fn doStablecoin(self: *Activity, a: std.mem.Allocator) !void {
        const sc = self.coin.stablecoin() orelse return error.Unsupported;

        var threaded: std.Io.Threaded = .init(a, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const data_dir = try self.coin.dataDir(a, self.home_dir);
        const auth = try conf.readAuth(
            a,
            io,
            data_dir,
            self.coin.confFile(),
            self.coin.rpcDefaultUsername(),
            self.coin.rpcDefaultPort(),
        );

        switch (self.sc_op) {
            .estimate => {
                self.sc_estimate = try sc.estimate_collateral(a, auth, self.sc_cents, self.sc_tier);
                self.sc_ok = true;
                self.sc_result_len = 0;
            },
            .mint => self.adoptScOutcome(try sc.mint(a, auth, self.sc_cents, self.sc_tier)),
            .send => self.adoptScOutcome(try sc.send(
                a,
                auth,
                self.sc_send_addr_buf[0..self.sc_send_addr_len],
                self.sc_cents,
            )),
            .redeem => self.adoptScOutcome(try sc.redeem(
                a,
                auth,
                self.sc_position_buf[0..self.sc_position_len],
                self.sc_cents,
            )),
        }
    }

    /// Publish a mint/send/redeem outcome: the txid (success) or the daemon's
    /// own rejection reason, verbatim.
    fn adoptScOutcome(self: *Activity, outcome: models.SendResult) void {
        switch (outcome) {
            .ok => |txid| {
                self.sc_ok = true;
                self.stashScResult(txid);
            },
            .failed => |msg| {
                self.sc_ok = false;
                self.stashScResult(msg);
            },
        }
    }

    /// Copy `text` into the bounded `sc_result_buf` — same shape as
    /// `stashSendResult`.
    fn stashScResult(self: *Activity, text: []const u8) void {
        const n = @min(text.len, self.sc_result_buf.len);
        @memcpy(self.sc_result_buf[0..n], text[0..n]);
        self.sc_result_len = n;
    }

    /// Mining worker. Runs one start_mining/stop_mining RPC on a private arena
    /// (bounded, isolated) and publishes the outcome, reaped by the UI once
    /// `mining_done` is observed. Same shape as `runWalletAction`.
    fn runMining(self: *Activity) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        if (self.doMining(a)) {
            self.mining_ok = true;
        } else |err| {
            self.mining_err = @errorName(err);
            self.mining_ok = false;
        }
        self.mining_done.store(true, .release);
    }

    /// Resolve the coin's RPC credentials and dispatch the in-flight mining op.
    /// The miner lives in the *daemon* (unlike send/balance, which ride the
    /// wallet process for external-wallet coins), so this always talks to the
    /// daemon's own endpoint. The payout address/thread count come from
    /// `mining_addr_buf`/`mining_threads_req` (the UI copied them in before
    /// spawning).
    fn doMining(self: *Activity, a: std.mem.Allocator) !void {
        var threaded: std.Io.Threaded = .init(a, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const data_dir = try self.coin.dataDir(a, self.home_dir);
        const auth = try conf.readAuth(
            a,
            io,
            data_dir,
            self.coin.confFile(),
            self.coin.rpcDefaultUsername(),
            self.coin.rpcDefaultPort(),
        );

        if (self.mining_starting) {
            try self.coin.miningStart(a, auth, self.mining_addr_buf[0..self.mining_addr_len], self.mining_threads_req);
        } else {
            try self.coin.miningStop(a, auth);
        }
    }

    /// The wallet *process*'s own RPC endpoint, distinct from the daemon's
    /// `CoinAuth` — see `extwallet.authFor`.
    fn extWalletAuth(self: *const Activity) models.CoinAuth {
        return extwallet.authFor(self.coin, &self.wallet_rpc);
    }

    /// External-wallet setup worker. Runs the chosen create/restore/open RPC on a
    /// private arena and publishes the outcome (a created wallet's seed included),
    /// reaped by the UI once `wallet_setup_done` is observed.
    fn runWalletSetup(self: *Activity) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        if (self.doWalletSetup(a)) {
            self.wallet_setup_ok = true;
        } else |err| {
            self.wallet_setup_err = @errorName(err);
            self.wallet_setup_ok = false;
        }
        self.wallet_setup_done.store(true, .release);
    }

    /// Dispatch the in-flight external-wallet op against the wallet process. The
    /// password/seed/file inputs were copied into the activity's bounded buffers
    /// before the worker was spawned. A successful `create` stashes the generated
    /// mnemonic in `wallet_setup_seed` for the UI to display.
    fn doWalletSetup(self: *Activity, a: std.mem.Allocator) !void {
        const ew = self.coin.externalWallet() orelse return error.NoExternalWallet;
        const pw = self.wallet_pw_buf[0..self.wallet_pw_len];
        const detail = &self.wallet_setup_sink;

        // Launch-with-password wallets (Zano `simplewallet`): the RPC server serves
        // only the wallet handed to it at startup, so the *app* launches it per-op
        // with the password. Create materializes the file via a one-shot CLI first,
        // then the running server's RPC is used to read the seed; open just relaunches
        // against the existing file (a wrong password makes the server exit, which
        // `launchWalletServer` surfaces as a failed open).
        if (self.coin.walletLaunchesWithPassword()) {
            switch (self.wallet_setup_op) {
                .create => {
                    try (ew.cli_create orelse return error.Unsupported)(a, self.install_root, self.home_dir, pw, detail);
                    try self.launchWalletServer(pw);
                    self.wallet_setup_seed = try ew.create(a, self.extWalletAuth(), pw, detail);
                },
                .restore_file => {
                    // Import the wallet file onto disk, then launch the server against
                    // it and confirm the password opens it.
                    try (ew.restore_file orelse return error.Unsupported)(a, self.extWalletAuth(), self.home_dir, self.wallet_file_buf[0..self.wallet_file_len], pw, detail);
                    try self.launchWalletServer(pw);
                    try ew.open(a, self.extWalletAuth(), pw, detail);
                },
                .restore_seed => {
                    // Materialize the wallet from the seed via the coin's CLI
                    // (Epic's `init -r`), then launch the server against it and
                    // confirm the password opens it — same shape as restore_file.
                    try ew.restore_seed(a, self.extWalletAuth(), self.install_root, self.home_dir, pw, self.wallet_seed_buf[0..self.wallet_seed_len], detail);
                    try self.launchWalletServer(pw);
                    try ew.open(a, self.extWalletAuth(), pw, detail);
                },
                .open => {
                    try self.launchWalletServer(pw);
                    try ew.open(a, self.extWalletAuth(), pw, detail);
                },
                .lock => return error.Unsupported,
            }
            return;
        }

        const auth = self.extWalletAuth();
        switch (self.wallet_setup_op) {
            .create => self.wallet_setup_seed = try ew.create(a, auth, pw, detail),
            .restore_seed => try ew.restore_seed(a, auth, self.install_root, self.home_dir, pw, self.wallet_seed_buf[0..self.wallet_seed_len], detail),
            .restore_file => try (ew.restore_file orelse return error.Unsupported)(a, auth, self.home_dir, self.wallet_file_buf[0..self.wallet_file_len], pw, detail),
            .open => try ew.open(a, auth, pw, detail),
            .lock => try (ew.lock orelse return error.Unsupported)(a, auth, detail),
        }
    }

    /// Launch the coin's wallet RPC server against the managed wallet file, opened
    /// with `wallet_password`, and wait until it answers — the open path for
    /// launch-with-password external wallets (Zano `simplewallet`), whose RPC can
    /// only serve the wallet it was started on. Any wallet process still serving a
    /// previous wallet is torn down first. On a wrong password the server exits
    /// without ever binding its port, so a bounded reachability wait that elapses is
    /// reported as a failed open. Runs on the setup worker (which owns the child
    /// handle for the duration; the tick loop won't reap it while the worker runs).
    fn launchWalletServer(self: *Activity, wallet_password: []const u8) !void {
        const ew = self.coin.externalWallet().?;
        const argv_fn = ew.launch_server_argv.?;
        const port = ew.rpc_port.?();

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var threaded: std.Io.Threaded = .init(a, .{});
        defer threaded.deinit();
        const io = threaded.io();

        // Tear down any wallet process still serving a previous wallet.
        if (self.wallet_rpc.child) |*child| {
            child.kill(io);
            self.wallet_rpc.child = null;
        }
        self.ext_wallet_open.store(0, .monotonic);

        // Capture the wallet process's stdout+stderr to a scratch file so a failed
        // open surfaces the real reason (a wrong password, an unreadable / corrupt
        // or version-incompatible wallet file, a missing daemon connection) instead
        // of a bare "WalletOpenFailed". The epee family (Zano/…) prints fatal load
        // errors to the console, not only stderr, so both streams are captured to
        // the one file. Per-port name so two coins launching at once don't clash;
        // unlinked once read (an anonymous inode the live process can keep writing
        // to is harmless) — on Windows the delete fails while the process holds it
        // open (caught), and the next launch truncates it instead.
        const cap_name = try std.fmt.allocPrint(a, ".wallet-{s}.startup", .{port});
        const cap_path = try std.fs.path.join(a, &.{ self.install_root, cap_name });
        var cap_file: ?std.Io.File = std.Io.Dir.createFileAbsolute(io, cap_path, .{ .read = true }) catch null;
        defer if (cap_file) |*f| {
            f.close(io);
            std.Io.Dir.deleteFileAbsolute(io, cap_path) catch {};
        };
        const capture: std.process.SpawnOptions.StdIo = if (cap_file) |f| .{ .file = f } else .ignore;

        // argv is consumed by spawn (fork/exec copies it), so the local arena can be
        // freed right after. The wallet password rides argv only — never disk.
        const argv = try argv_fn(a, self.install_root, self.home_dir, port, wallet_password);
        const child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = capture,
            .stderr = capture,
            .create_no_window = @import("builtin").os.tag == .windows,
        }) catch return error.WalletServiceFailed;
        self.wallet_rpc.child = child;

        // Wait for the wallet RPC to bind its port (or the process to die on a bad
        // password / unreadable wallet). Bounded so a never-answering server can't
        // wedge the worker.
        const auth = self.extWalletAuth();
        var waited: u32 = 0;
        const step: u32 = 250;
        const limit: u32 = 25_000;
        while (waited < limit) : (waited += step) {
            if (rpc.daemonReachable(a, auth)) return;
            // Fast failure path: simplewallet refuses a bad password / can't read the
            // wallet and exits before ever binding its port, so reap-on-exit lets us
            // fail at once — with the reason it printed — rather than waiting out the
            // whole timeout. (POSIX; Windows times out then reads the same capture.)
            if (@import("builtin").os.tag != .windows) {
                if (self.wallet_rpc.child) |ch| if (ch.id) |pid| {
                    if (proc_mod.reapNoHang(pid)) {
                        self.wallet_rpc.child = null;
                        if (cap_file) |*f| self.setWalletErrFromCapture(io, f);
                        return error.WalletOpenFailed;
                    }
                };
            }
            io.sleep(.fromMilliseconds(step), .awake) catch {};
        }
        if (cap_file) |*f| self.setWalletErrFromCapture(io, f);
        return error.WalletOpenFailed;
    }

    /// Read the wallet process's captured stdout/stderr and stash the most
    /// error-like line in `wallet_setup_sink`, so a failed launch reports why
    /// (surfaced by `extwallet.friendlyWalletError` and the action log).
    /// Best-effort: leaves the sink untouched on any IO hiccup or when nothing was
    /// printed, so the caller falls back to the generic message.
    fn setWalletErrFromCapture(self: *Activity, io: std.Io, file: *std.Io.File) void {
        const stat = file.stat(io) catch return;
        var buf: [8 * 1024]u8 = undefined;
        // Bias to the tail: the fatal line lands last, just before the process exits.
        const off = if (stat.size > buf.len) stat.size - buf.len else 0;
        const n = file.readPositionalAll(io, &buf, off) catch return;
        const pick = pickWalletError(buf[0..n]);
        if (pick.len != 0) self.wallet_setup_sink.set(pick);
    }

    /// Whether the coin's live status is still being resolved: it's installed and
    /// no poll has come back yet, with the daemon not already known to be
    /// starting/running. During this window the Running/Staking marks animate so
    /// the brief poll latency reads as "loading" rather than "stopped".
    fn awaitingStatus(self: *const Activity) bool {
        return self.installed and !self.poll_completed and self.daemonState() == .stopped;
    }

    /// Fold a finished poll's published values into the display fields the pane
    /// renders. Returns whether the poll reached the daemon, so the caller can
    /// also flip the daemon state to running. A failed poll leaves the last good
    /// values in place rather than zeroing them on a transient blip.
    fn applyPoll(self: *Activity) bool {
        if (!self.poll_ok) return false;
        self.peers = self.poll_peers.load(.monotonic);
        self.staking = self.poll_staking.load(.monotonic) != 0;
        self.wallet = @enumFromInt(self.poll_wallet.load(.monotonic));

        // Running daemon version (staged by the poll worker before `poll_done`).
        const vn = @min(self.poll_version_len, self.version_buf.len);
        @memcpy(self.version_buf[0..vn], self.poll_version_buf[0..vn]);
        self.version_len = vn;

        // Wallet balances — `f64`s carried as their `u64` bit patterns. Only
        // adopted once a balance has actually been fetched (`poll_has_balance`),
        // so the lines stay hidden on coins that don't report one and don't flash
        // a misleading 0 before the first fetch.
        if (self.poll_has_balance.load(.monotonic) != 0) {
            self.balance_total = @bitCast(self.poll_balance_total.load(.monotonic));
            self.balance_avail = @bitCast(self.poll_balance_avail.load(.monotonic));
            self.has_balance = true;
        }

        // Cached transactions (staged by the poll worker before `poll_done`), same
        // ordering rationale as the version buffer above.
        const tn = @min(self.poll_tx_count, self.tx_buf.len);
        @memcpy(self.tx_buf[0..tn], self.poll_tx_buf[0..tn]);
        self.tx_count = tn;
        const sn = @min(self.poll_stake_count, self.stake_buf.len);
        @memcpy(self.stake_buf[0..sn], self.poll_stake_buf[0..sn]);
        self.stake_count = sn;

        // Cached receive address, same ordering rationale.
        const an = @min(self.poll_receive_addr_len, self.receive_addr_buf.len);
        @memcpy(self.receive_addr_buf[0..an], self.poll_receive_addr_buf[0..an]);
        self.receive_addr_len = an;

        // Live mining state (staged by the poll worker; gated so the tab shows
        // "checking…" until the first successful fetch).
        if (self.poll_has_mining.load(.monotonic) != 0) {
            self.mining_active = self.poll_mining_active.load(.monotonic) != 0;
            self.mining_threads = self.poll_mining_threads.load(.monotonic);
            self.mining_speed = self.poll_mining_speed.load(.monotonic);
            self.has_mining = true;
        }

        // Stablecoin caches (staged by the poll worker before `poll_done`),
        // same ordering rationale as the version/transaction buffers. The
        // info/balance snapshots are gated so the tab reads "checking…" until
        // the first successful fetch.
        if (self.poll_sc_has_info) {
            self.sc_info = self.poll_sc_info;
            self.sc_has_info = true;
        }
        if (self.poll_sc_has_balance) {
            self.sc_balance = self.poll_sc_balance;
            self.sc_has_balance = true;
        }
        const sct = @min(self.poll_sc_tx_count, self.sc_tx_buf.len);
        @memcpy(self.sc_tx_buf[0..sct], self.poll_sc_tx_buf[0..sct]);
        self.sc_tx_count = sct;
        const scp = @min(self.poll_sc_pos_count, self.sc_pos_buf.len);
        @memcpy(self.sc_pos_buf[0..scp], self.poll_sc_pos_buf[0..scp]);
        self.sc_pos_count = scp;
        const sca = @min(self.poll_sc_addr_len, self.sc_addr_buf.len);
        @memcpy(self.sc_addr_buf[0..sca], self.poll_sc_addr_buf[0..sca]);
        self.sc_addr_len = sca;

        // Wallet rescan progress (external in-daemon wallets only). The flag is
        // always adopted — clearing it the moment the scan catches up returns the
        // wallet line to "Unlocked".
        self.rescanning = self.poll_rescanning.load(.monotonic) != 0;
        self.rescan_scanned = self.poll_rescan_scanned.load(.monotonic);
        self.rescan_target = self.poll_rescan_target.load(.monotonic);

        // Two separate, accurate sync axes:
        //   Headers  = local headers / network tip (download progress vs peers)
        //   Blocks   = validated blocks / downloaded headers (validation catch-up)
        // The header bar fills first as headers stream in from peers; the block
        // bar then fills as those headers are validated into blocks. Each
        // denominator is `max`-guarded so a momentary lead (we're ahead of peers,
        // or blocks briefly past headers) can't push a bar over 100% or to 0/0.
        const headers = self.poll_headers.load(.monotonic);
        const blocks = self.poll_blocks.load(.monotonic);
        const network = self.poll_network.load(.monotonic);
        self.headers_cur = headers;
        // The network tip is only meaningful once at least one peer is connected.
        // A node loads its local headers from disk before any peer connects, and
        // some daemons (e.g. Ergo) still report a stale/self `maxPeerHeight` with
        // zero peers — anchoring the denominator to either then would read a
        // misleading 100% that collapses the instant a real peer height arrives.
        // So require a peer *and* a known tip; otherwise treat the total as
        // unknown (0 → empty bar). Once both hold, `max`-guard against the tip so
        // being briefly ahead of stale peers pegs full rather than overflowing.
        self.headers_total = if (self.peers > 0 and network > 0) @max(network, headers) else 0;
        self.blocks_cur = blocks;
        self.blocks_total = @max(headers, blocks);

        // Headers pre-synchronization detection (Bitcoin Core 24+). During the
        // initial anti-DoS presync pass the daemon downloads every header without
        // committing any, so the committed `headers` height we display sits still
        // while the node is busy churning through the chain — and RPC exposes no
        // presync height to show instead. Block download hasn't begun yet, so
        // this only ever fires in the headers phase. (The presync pass isn't
        // persisted — a restart mid-presync redoes it.)
        //
        // Two signals feed `presync`, in priority order:
        //   1. `debug.log` confirms the pass directly ("Pre-synchronizing
        //      blockheaders…", scraped into `poll_presync_found`) — authoritative
        //      where the daemon logs it (Core 24+ lineages).
        //   2. Otherwise, infer it from a *sustained* non-advancing committed-
        //      header height: `presync_stall_polls` counts consecutive polls
        //      where the height didn't move, and only trips presync once it
        //      reaches `presync_stall_threshold`. A single stalled poll (peer
        //      latency, a poll landing just before a header commits) no longer
        //      flips the label — during a real header download `headers` jumps
        //      by thousands between polls and resets the counter to 0, so a
        //      genuine multi-minute presync freeze still gets caught within a
        //      couple of poll ticks. Older forks that never log the presync line
        //      (e.g. DigiByte) rely entirely on this fallback.
        //
        // Both signals are gated on the coin actually having the pass: on a
        // non-Core lineage (Ergo) every header is committed as it arrives, so a
        // header height that only creeps forward is just a node sitting at the
        // tip with blocks still to fetch — not a presync freeze.
        self.presync = self.presync_tracker.update(
            self.statusInput(),
            self.has_header_presync,
            self.poll_presync_found.load(.monotonic) != 0,
        );
        self.presync_bp = self.poll_presync_bp.load(.monotonic);

        self.behind_secs = self.poll_behind.load(.monotonic);
        self.tip_time = self.poll_tip_time.load(.monotonic);
        self.sync = if (self.poll_synced.load(.monotonic) != 0) .synced else .syncing;
        return true;
    }

    /// Whether the node is still downloading headers, as opposed to catching its
    /// blocks up to headers it already has. A 0 total means the tip isn't known
    /// yet — treat that as block catch-up rather than claiming a headers phase we
    /// can't measure.
    ///
    /// The tip is allowed `header_tip_slack` of gap: a node whose headers sit at
    /// the tip still reads a few blocks short of the best peer height, because the
    /// chain advances and peers announce it before we commit it. Without the slack
    /// that permanent last-few-blocks gap pins the headers phase on for the entire
    /// full-block download — which is exactly the state a freshly-installed Ergo
    /// node is in (headers at the tip, blocks a million behind). Real header sync
    /// is thousands-to-millions of blocks short, far outside the slack, so this
    /// only ever reclassifies the tail of the headers phase, where blocks are the
    /// long pole anyway.
    fn inHeadersPhase(self: *const Activity) bool {
        return status_mod.inHeadersPhase(self.statusInput());
    }

    /// Snapshot the fields the status readout reads. The single point where an
    /// `Activity` field could be mapped to the wrong `status_mod.Input` one — which
    /// is why the integration test that renders a full pane is the regression
    /// net for this function, not the pure tests in `status.zig`.
    fn statusInput(self: *const Activity) status_mod.Input {
        return .{
            .installing = switch (self.phaseOf()) {
                .downloading => .downloading,
                .extracting => .extracting,
                else => .idle,
            },
            .installed = self.installed,
            .daemon = switch (self.daemonState()) {
                .stopped => .stopped,
                .starting => .starting,
                .running => .running,
                .stopping => .stopping,
            },
            .awaiting_status = self.awaitingStatus(),
            .loading_phase = self.loading_phase,
            .loading_text = self.stage_buf[0..self.stage_len],
            .load_stage = self.load_stage,
            .load_pct_bp = self.load_pct_bp,
            .load_eta_pct = self.load_eta_pct,
            .peers = self.peers,
            .sync = self.sync,
            .presync = self.presync,
            .presync_bp = self.presync_bp,
            .headers_cur = self.headers_cur,
            .headers_total = self.headers_total,
            .blocks_cur = self.blocks_cur,
            .blocks_total = self.blocks_total,
        };
    }

    /// Whether a just-reaped poll should promote the daemon to `.running`. A reply —
    /// a full `applyPoll` *or* a bare `poll_alive` port hit — proves the daemon is
    /// up, which is how a daemon started outside BoxWallet is detected. But it must
    /// not resurrect a daemon while a stop is pending, nor one we deliberately
    /// stopped (`stopped_by_us`): the node can keep answering for a moment as it
    /// shuts down, and resurrecting it would flash "Waiting for peers…" and stick
    /// there. `applyPoll` is always evaluated first, for its fold-in side effect.
    fn shouldAdoptRunning(self: *Activity) bool {
        const replied = self.applyPoll() or self.poll_alive;
        return replied and self.daemonState() != .running and
            !self.stop_pending and !self.stopped_by_us;
    }

    /// Live poll worker. Two RPC round-trips (`getinfo` for peers/staking,
    /// `getblockchaininfo` for the sync heights) publishing into the shared
    /// atomics, then `poll_done`. Runs on a private arena so its working set is
    /// bounded and isolated (per the memory constraint), and is reaped by the UI
    /// once `poll_done` is observed.
    fn runPoll(self: *Activity) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        if (self.fetchStatus(a)) {
            self.poll_ok = true;
            self.poll_alive = true;
            // The daemon answered normally, so it isn't warming up.
            self.poll_phase.store(@intFromEnum(models.LoadingPhase.none), .monotonic);
            self.clearLoadProgress();
        } else |_| {
            self.poll_ok = false;
            // The status fetch failed — but a daemon under heavy load accepts the
            // connection instantly while stalling its RPC reply for seconds (Nerva
            // behind its blockchain lock). Tell that apart from a daemon that's
            // actually down with a cheap connect probe: reachable ⇒ up-but-busy, so
            // the UI keeps it "running" instead of flipping to "stopped".
            self.poll_alive = self.probeReachable(a);
            // The daemon may be up but still warming up — probe its phase so the
            // UI can show *what* it's doing (Loading/Verifying/…) rather than a
            // bare spinner. Best-effort; a failure leaves it `none`.
            self.probeLoadingPhase(a);
        }
        // Last resort for the version marker, once `fetchStatus` has had its go.
        // Runs on this worker thread (never the UI thread) because it execs a
        // process, and outside the branch above because it must work with the
        // daemon down — that's the case the RPC stamp can't reach.
        self.stampVersionFromBinary(a);
        // Refresh the coin's on-disk size (self-gated to a slow cadence). Runs
        // regardless of whether the daemon answered — the chain occupies disk
        // whether it's up or down.
        self.sampleStorage(a);
        self.poll_done.store(true, .release);
    }

    /// Measure the coin's data-directory size into `poll_storage_bytes`, gated to
    /// a ~30s cadence so the directory walk never rides the ~2s poll. Runs on the
    /// poll worker thread (a metadata-only walk can be slow on a spinning disk /
    /// SBC, so it stays off the UI thread) over the caller's poll arena. A missing
    /// data dir or IO hiccup leaves the last figure in place — the atomics persist
    /// across polls — so the line doesn't flicker to "—" on a transient miss.
    fn sampleStorage(self: *Activity, a: std.mem.Allocator) void {
        var threaded: std.Io.Threaded = .init(a, .{});
        defer threaded.deinit();
        const io = threaded.io();

        // Monotonic clock so a wall-clock jump (NTP, manual set) can't stall or
        // spam the sampler. `awake`'s epoch is unspecified but always positive,
        // so the 0 sentinel reliably means "never sampled — do it now".
        const now: i128 = std.Io.Clock.awake.now(io).toNanoseconds();
        if (self.storage_next_ns != 0 and now < self.storage_next_ns) return;
        self.storage_next_ns = now + 30 * std.time.ns_per_s;

        const data_dir = self.coin.dataDir(a, self.home_dir) catch return;
        if (dirSizeBytes(io, a, data_dir)) |bytes| {
            self.poll_storage_bytes.store(bytes, .monotonic);
            self.poll_storage_sampled.store(1, .monotonic);
        }
    }

    /// One-shot: stamp a missing version marker by asking the installed binary its
    /// version, for a coin whose daemon doesn't report one over RPC (Zano).
    ///
    /// The RPC stamp in `fetchStatus` handles every coin whose `daemonInfo` carries
    /// a version, and it has already run by now — so this only fires where that
    /// couldn't: a pre-marker install of a coin wiring `installed_version_probe`.
    /// Without it such an install reads as "up to date" forever, because
    /// `refreshUpdateState` treats a missing marker as "can't vouch, don't nag" and
    /// the absent marker is what suppresses the update prompt that would rewrite it.
    ///
    /// Best-effort throughout: install owns the marker, so an existing one is never
    /// overwritten, and any failure just leaves the coin as it was.
    fn stampVersionFromBinary(self: *Activity, a: std.mem.Allocator) void {
        if (self.version_stamp_done or self.version_probe_done) return;
        // Nothing to resolve paths against — refuse rather than probe a relative
        // binary name off the cwd. Staged before every poll spawn, so this only
        // guards against a future worker forgetting to.
        if (self.install_root.len == 0) return;

        // A marker already on disk means there's nothing to stamp — and the RPC
        // path's stale-marker *correction* is the daemon's business, not ours.
        if (install_mod.readVersionMarker(a, self.install_root, self.coin.daemonFile())) |m| {
            a.free(m);
            self.version_stamp_done = true;
            return;
        }

        // Null = this coin needs no probe (its daemon reports the version over RPC).
        // Leave `version_probe_done` clear: nothing was attempted, and the RPC stamp
        // still owns the job on a later poll once the daemon answers.
        const ver = self.coin.probeInstalledVersion(a, self.install_root) catch {
            self.version_probe_done = true; // probe ran and failed; don't re-exec
            return;
        } orelse return;
        defer a.free(ver);

        self.version_probe_done = true;
        if (ver.len == 0) return;
        install_mod.writeVersionMarker(a, self.install_root, self.coin.daemonFile(), ver) catch return;
        self.version_stamp_done = true;
    }

    /// Cheap "is the daemon up?" check after a failed status fetch: resolve the
    /// coin's RPC credentials and try a bare TCP connect to its port. A daemon
    /// that's merely busy accepts the connection (so this returns true) while one
    /// that's down refuses it. Runs on the caller's poll arena; any resolution
    /// hiccup reads as not reachable.
    fn probeReachable(self: *Activity, a: std.mem.Allocator) bool {
        var threaded: std.Io.Threaded = .init(a, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const data_dir = self.coin.dataDir(a, self.home_dir) catch return false;
        const auth = conf.readAuth(
            a,
            io,
            data_dir,
            self.coin.confFile(),
            self.coin.rpcDefaultUsername(),
            self.coin.rpcDefaultPort(),
        ) catch return false;
        return rpc.daemonReachable(a, auth);
    }

    /// Reset the block-loading sub-stage/percentage and the staged stage message —
    /// used by every early-return branch of `probeLoadingPhase` so a coin with no
    /// warm-up (or a daemon that's actually stopped) doesn't keep showing a
    /// stale percentage or stage from a previous poll.
    fn clearLoadProgress(self: *Activity) void {
        self.poll_load_stage.store(@intFromEnum(LoadStage.none), .monotonic);
        self.poll_load_pct_bp.store(0, .monotonic);
        self.poll_stage_len = 0;
    }

    /// Probe the daemon's warm-up phase after a failed status fetch. Only worth
    /// doing while we believe the daemon is up (a stopped daemon would just refuse
    /// the connection); coins that report no warm-up at all — neither a `-28`
    /// reply nor a daemon log — always read `none`. Runs on the caller's poll
    /// arena.
    fn probeLoadingPhase(self: *Activity, a: std.mem.Allocator) void {
        if (!warmup.supported(self.coin) or self.daemonState() == .stopped) {
            self.poll_phase.store(@intFromEnum(models.LoadingPhase.none), .monotonic);
            self.clearLoadProgress();
            return;
        }

        var threaded: std.Io.Threaded = .init(a, .{});
        defer threaded.deinit();

        // The probe itself (RPC `-28` phase, refined by the sub-stage and
        // percentage its debug.log carries) is shared with the GUI; only the
        // publishing into these atomics is the TUI's own.
        const status = warmup.probe(a, threaded.io(), self.coin, self.home_dir);
        self.poll_phase.store(@intFromEnum(status.phase), .monotonic);
        self.poll_load_stage.store(@intFromEnum(status.progress.stage), .monotonic);
        self.poll_load_pct_bp.store(status.progress.pct_bp, .monotonic);

        // The daemon's own wording for the stage, staged like the version string
        // (plain buffer, ordered by the `poll_done` release the caller does). This
        // is the detail the phase enum can't carry — "Rewinding blocks…" and
        // "Loading wallet…" are both just `.loading` to it.
        const msg = status.message();
        const n = @min(msg.len, self.poll_stage_buf.len);
        @memcpy(self.poll_stage_buf[0..n], msg[0..n]);
        self.poll_stage_len = n;
    }

    /// Resolve the coin's RPC credentials from its conf, then fetch both the
    /// `getinfo` and `getblockchaininfo` snapshots and publish them into the
    /// shared atomics. Everything allocates on the caller's arena. Returns an
    /// error (and publishes nothing) if any step fails — the daemon is treated as
    /// unreachable for this round, leaving the last good values in place.
    fn fetchStatus(self: *Activity, a: std.mem.Allocator) !void {
        var threaded: std.Io.Threaded = .init(a, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const data_dir = try self.coin.dataDir(a, self.home_dir);
        const auth = try conf.readAuth(
            a,
            io,
            data_dir,
            self.coin.confFile(),
            self.coin.rpcDefaultUsername(),
            self.coin.rpcDefaultPort(),
        );

        // Bitcoin-Core 0.21+ forks (DigiByte, ReddCoin) don't auto-create a
        // wallet, so wallet RPCs (staking, addresses) have none until one exists.
        // Load-or-create it once, the first time the daemon answers — done before
        // the status fetch below so the same poll's `staking` call already sees it.
        // Best-effort: a failure (daemon still coming up) just retries next poll.
        if (self.coin.needsWallet() and !self.wallet_ensured) {
            if (self.coin.ensureWallet(a, auth)) {
                self.wallet_ensured = true;
            } else |_| {}
        }

        const info = try self.coin.daemonInfo(a, auth);
        self.poll_peers.store(@as(u32, @intCast(@max(info.connections, 0))), .monotonic);
        self.poll_staking.store(@intFromBool(info.staking_active), .monotonic);

        // Stage the running daemon version for the "Running" line (folded by the UI
        // after this worker stores `poll_done`).
        const vn = @min(info.version.len, self.poll_version_buf.len);
        @memcpy(self.poll_version_buf[0..vn], info.version[0..vn]);
        self.poll_version_len = vn;

        // One-shot: stamp a missing version marker from the live daemon, so an
        // install made before markers existed stops reading as "update available"
        // without forcing a reinstall. Never overwrite an existing marker — install
        // owns it. The live daemon *is* the installed binary, so its reported
        // version is the right value to record.
        if (!self.version_stamp_done and info.version.len > 0) {
            self.version_stamp_done = true;
            if (install_mod.readVersionMarker(a, self.install_root, self.coin.daemonFile())) |m| {
                defer a.free(m);
                // The live daemon *is* the installed binary. If the marker claims we're
                // behind core_version while the daemon reports exactly core_version, the
                // marker is stale/mis-encoded — correct it so it stops nagging a false
                // "update available". Requiring an exact match keeps a genuinely older
                // install (reported != core) untouched, so real updates still show.
                if (updater.isNewer(self.coin.coreVersion(), m) and
                    std.mem.eql(u8, info.version, self.coin.coreVersion()))
                    install_mod.writeVersionMarker(a, self.install_root, self.coin.daemonFile(), info.version) catch {};
            } else {
                install_mod.writeVersionMarker(a, self.install_root, self.coin.daemonFile(), info.version) catch {};
            }
        }

        // Wallet security state, for coins whose wallet BoxWallet can manage —
        // lights up the Wallet line and drives which `w` menu options apply.
        // Best-effort: a hiccup (e.g. no wallet loaded yet) just leaves the last
        // value, so a transient blip doesn't blank the line.
        if (self.coin.supportsWallet()) {
            if (self.coin.walletSecurityState(a, auth)) |sec| {
                self.poll_wallet.store(@intFromEnum(sec), .monotonic);
            } else |_| {}
        }

        // Wallet balance, for coins that report one — the Total/Available lines.
        // `total` (confirmed + mempool + immature) tracks incoming funds the
        // instant they're seen; `available` is the confirmed spendable figure. The
        // `f64`s ride as `u64` bit patterns through the atomics. Best-effort: a
        // hiccup just leaves the last value, so a blip doesn't blank the line.
        if (self.coin.supportsBalance()) {
            if (self.coin.walletBalance(a, auth)) |bal| {
                self.poll_balance_total.store(@bitCast(bal.total), .monotonic);
                self.poll_balance_avail.store(@bitCast(bal.available), .monotonic);
                self.poll_has_balance.store(1, .monotonic);
            } else |_| {}
        }

        // Live mining state (Mining tab), for coins whose daemon mines
        // in-process — every poll, so the hashrate readout stays current.
        // Best-effort: a hiccup just leaves the last value, so a blip doesn't
        // flicker the tab.
        if (self.coin.supportsMining()) {
            if (self.coin.miningStatus(a, auth)) |ms| {
                self.poll_mining_active.store(@intFromBool(ms.active), .monotonic);
                self.poll_mining_threads.store(ms.threads, .monotonic);
                self.poll_mining_speed.store(ms.speed, .monotonic);
                self.poll_has_mining.store(1, .monotonic);
            } else |_| {}
        }

        // Wallet transaction history (Transactions tab), for coins that report
        // one — every poll, regardless of which tab is on screen, so an
        // incoming payment shows up promptly no matter what the user's
        // looking at. Best-effort: a hiccup just leaves the last cached list,
        // so a blip doesn't blank the tab.
        // For an external-wallet coin (Monero-style), the transactions /
        // receive-address RPCs live on the *wallet* process, not the daemon —
        // so they get its endpoint + per-session creds, and are polled only
        // once the wallet has been opened this session (before that the wallet
        // RPC has no wallet to answer for). Bitcoin-family coins keep the
        // daemon's own auth.
        const wallet_rpc_ready = !self.coin.hasExternalWallet() or self.ext_wallet_open.load(.monotonic) != 0;
        const wallet_rpc_auth = if (self.coin.hasExternalWallet()) self.extWalletAuth() else auth;
        if (self.coin.supportsTransactions() and wallet_rpc_ready) {
            if (self.coin.walletTransactions(a, wallet_rpc_auth, tx_cache_cap)) |txs| {
                const n = @min(txs.len, tx_cache_cap);
                @memcpy(self.poll_tx_buf[0..n], txs[0..n]);
                self.poll_tx_count = n;
            } else |_| {}
        }

        // The wallet's stakes (Staking tab), for a coin that can enumerate them.
        // Same best-effort rule as the transaction list: a hiccup leaves the last
        // cached list rather than blanking the tab.
        if (self.coin.supportsStakeList() and wallet_rpc_ready) {
            if (self.coin.walletStakes(a, wallet_rpc_auth, stake_cache_cap)) |stakes| {
                const n = @min(stakes.len, stake_cache_cap);
                @memcpy(self.poll_stake_buf[0..n], stakes[0..n]);
                self.poll_stake_count = n;
            } else |_| {}
        }

        // Wallet receive address (Receive tab). Unlike balance/transactions,
        // this is NOT re-fetched every poll: `getaccountaddress` silently
        // rotates once the address has been paid, so polling it passively
        // would swap the displayed address out from under the user without
        // their consent. Fetched once (no cached address yet) or when the
        // user explicitly asked for a new one via the Receive tab's "New
        // address" key — never otherwise.
        if (self.coin.supportsReceiveAddress() and wallet_rpc_ready and (self.receive_addr_len == 0 or self.want_new_receive_address)) {
            if (self.coin.walletReceiveAddress(a, wallet_rpc_auth, self.want_new_receive_address)) |addr| {
                const n = @min(addr.len, self.poll_receive_addr_buf.len);
                @memcpy(self.poll_receive_addr_buf[0..n], addr[0..n]);
                self.poll_receive_addr_len = n;
            } else |_| {}
            self.want_new_receive_address = false; // consumed either way
        }

        // Stablecoin (DigiDollar) state, for the coin that has one. The system
        // info (deployment status / oracle price / supply) and the wallet's
        // balance, transactions and positions are refreshed every poll — so an
        // incoming DD payment or a vault's expiring timelock shows up promptly —
        // each best-effort (a hiccup leaves the last staged value). The deposit
        // address follows the coin receive address's consent rule: fetched once,
        // or on the user's explicit "new address", never re-polled.
        if (self.coin.stablecoin()) |sc| {
            if (sc.info(a, auth)) |inf| {
                self.poll_sc_info = inf;
                self.poll_sc_has_info = true;
            } else |_| {}
            // Until the feature activates on-chain, every other DD RPC refuses
            // ("DigiDollar is not yet active on this blockchain" — verified on
            // 9.26.4), so skip the four wallet-side calls rather than burning
            // dead round-trips each poll. The moment `active` flips, the same
            // poll cycle starts fetching them.
            const dd_active = self.poll_sc_has_info and self.poll_sc_info.active;
            if (dd_active) {
                if (sc.balance(a, auth)) |bal| {
                    self.poll_sc_balance = bal;
                    self.poll_sc_has_balance = true;
                } else |_| {}
                if (sc.transactions(a, auth, sc_tx_cache_cap)) |txs| {
                    const n = @min(txs.len, sc_tx_cache_cap);
                    @memcpy(self.poll_sc_tx_buf[0..n], txs[0..n]);
                    self.poll_sc_tx_count = n;
                } else |_| {}
                if (sc.positions(a, auth, sc_pos_cache_cap)) |ps| {
                    const n = @min(ps.len, sc_pos_cache_cap);
                    @memcpy(self.poll_sc_pos_buf[0..n], ps[0..n]);
                    self.poll_sc_pos_count = n;
                } else |_| {}
                if (self.sc_addr_len == 0 or self.want_new_sc_address) {
                    if (sc.receive_address(a, auth, self.want_new_sc_address)) |addr| {
                        const n = @min(addr.len, self.poll_sc_addr_buf.len);
                        @memcpy(self.poll_sc_addr_buf[0..n], addr[0..n]);
                        self.poll_sc_addr_len = n;
                    } else |_| {}
                    self.want_new_sc_address = false; // consumed either way
                }
            }
        }

        // Re-adopt a still-unlocked in-daemon wallet after an app restart. The Ergo
        // node outlives the app and keeps the wallet unlocked, but `ext_wallet_open`
        // is a per-session flag that resets to 0 — so the wallet would falsely read
        // "Locked" (and balance/rescan polling would stay paused) until the user
        // re-entered a password the node no longer needs. Promote the flag from the
        // node's real state; only ever *up* (locking stays driven by the explicit
        // lock action and daemon-stop), and only for in-daemon wallets (a process-
        // backed wallet's RPC died with the app, so there's nothing to re-adopt).
        if (self.coin.hasExternalWallet() and !self.coin.hasExternalWalletProcess() and self.ext_wallet_open.load(.monotonic) == 0) {
            if (self.coin.externalWallet().?.is_open) |isOpen| {
                if (isOpen(a, self.extWalletAuth())) |open| {
                    if (open) self.ext_wallet_open.store(1, .monotonic);
                } else |_| {}
            }
        }

        // External-wallet (Monero-style) balance — read from the *wallet* process,
        // not the daemon, and only once the wallet's been opened this session
        // (`ext_wallet_open`). Same Total/Available split published into the same
        // atomics. Best-effort: a hiccup leaves the last value.
        if (self.coin.hasExternalWallet() and self.ext_wallet_open.load(.monotonic) != 0) {
            const ew = self.coin.externalWallet().?;
            if (ew.balance(a, self.extWalletAuth())) |bal| {
                self.poll_balance_total.store(@bitCast(bal.total), .monotonic);
                self.poll_balance_avail.store(@bitCast(bal.available), .monotonic);
                self.poll_has_balance.store(1, .monotonic);
            } else |err| {
                // The wallet-rpc says no wallet is open — it was restarted (e.g. a
                // daemon bounce) and never re-opened, so our "open" flag is stale.
                // Drop it: the wallet line reverts to "Locked", balance polling
                // pauses, and `w` re-prompts to unlock (mirrors the Ergo-relock and
                // kill-wallet-rpc paths). Any other error is transient — leave the
                // last value so the balance doesn't flicker.
                if (err == error.WalletClosed) self.ext_wallet_open.store(0, .monotonic);
            }

            // Rescan progress — for a wallet that re-scans after a restore (Ergo's
            // in-daemon wallet, or a Monero-family wallet-rpc background refresh —
            // Salvium/Nerva). The
            // scanned height comes from the wallet; the target (tip) from the daemon,
            // so both auths are passed. Non-null means a rescan is in flight: publish
            // the heights and flag it; null (caught up / n/a) clears the flag. Best-
            // effort: a read hiccup leaves the last value so the bar doesn't flicker.
            if (ew.rescan_progress) |rescanProgress| {
                if (rescanProgress(a, self.extWalletAuth(), auth)) |maybe| {
                    if (maybe) |rp| {
                        self.poll_rescan_scanned.store(@intCast(@max(rp.scanned, 0)), .monotonic);
                        self.poll_rescan_target.store(@intCast(@max(rp.target, 0)), .monotonic);
                        self.poll_rescanning.store(1, .monotonic);
                    } else {
                        self.poll_rescanning.store(0, .monotonic);
                    }
                } else |_| {}
            }
        }

        var state = try self.coin.blockchainState(a, auth);
        defer state.deinit(a);
        // Don't let a newly-connected, less-informed peer walk the heights back down.
        self.tip_marks.apply(&state);
        self.poll_headers.store(@as(u64, @intCast(@max(state.headers, 0))), .monotonic);
        self.poll_blocks.store(@as(u64, @intCast(@max(state.blocks, 0))), .monotonic);
        self.poll_network.store(@as(u64, @intCast(@max(state.network_height, 0))), .monotonic);
        // The tip block's date and how far behind it puts us, for the hint beside
        // the Blocks bar. Both resolved by `models.BlockchainState.syncDistance`
        // (shared with the GUI, which asks the same question over the C ABI), from
        // whichever of `tip_time`/`seconds_behind` the coin reports. The real-time
        // clock is reachable here (in the poll worker) but not in the render path,
        // so derive it now; 0 / -1 mean "unavailable".
        const dist = state.syncDistance(std.Io.Clock.real.now(io).toSeconds());
        self.poll_behind.store(dist.behind_secs, .monotonic);
        self.poll_tip_time.store(dist.tip_time, .monotonic);
        self.poll_synced.store(@intFromBool(state.synced), .monotonic);

        // Headers pre-sync progress (Bitcoin Core 24+). While syncing, the
        // throwaway presync pass exposes its progress only in debug.log, so scrape
        // the latest percentage there for the status line; once synced there's
        // nothing to show. Harmless on non-Core coins — their log has no such line,
        // so the scrape comes back null. Store found-ness separately from the
        // percentage so `applyPoll` can tell "log confirms presync at 0.00%" apart
        // from "no presync line at all" — both would otherwise read back as 0.
        const presync_scrape = if (!state.synced) presyncPercentBp(io, data_dir) else null;
        self.poll_presync_bp.store(presync_scrape orelse 0, .monotonic);
        self.poll_presync_found.store(@intFromBool(presync_scrape != null), .monotonic);

        // One-shot post-sync hook (Nerva reclaims its quicksync file here). Gated on
        // a *real* sync — caught up AND with at least one peer — so a daemon that
        // momentarily reads "synced" before it has any peers (a low height with no
        // network height yet) can't trigger it early. Best-effort and fired once.
        if (!self.synced_handled and state.synced and info.connections > 0) {
            self.synced_handled = true;
            self.coin.onSynced(a, self.install_root, self.home_dir) catch {};
        }
    }

    /// Spawn the daemon binary and decide whether it started. `argv[0]` carries a
    /// path separator, so it's resolved as a file path rather than via PATH.
    ///
    /// Two strategies by platform. **Windows** daemons don't support `-daemon`
    /// (they run in the foreground), so we spawn detached and return immediately,
    /// letting the status poll confirm the daemon came up — see the branch below.
    /// **POSIX** uses `-daemon` and waits on the brief launcher, capturing its
    /// stderr so a failure can report the reason:
    ///
    /// `-daemon` forks a detached daemon (a new pid) and the launcher exits:
    /// cleanly after daemonizing, or non-zero (or on a signal) after a pre-fork
    /// startup error — a datadir lock, a chain-params assertion, … — that it
    /// prints to stderr. We wait only on the launcher, which is brief either way.
    ///
    /// Stderr goes to a throwaway file, not a pipe: the detached daemon inherits
    /// these descriptors, and a pipe whose read end we then closed would hand the
    /// daemon a SIGPIPE the next time it logs — killing it just after it came up
    /// (some coin daemons don't redirect their descriptors on daemonize). A
    /// regular file never SIGPIPEs and never blocks the wait. Stdout (the
    /// "<coin> server starting" banner) is discarded.
    fn launchDaemon(self: *Activity, a: std.mem.Allocator) !void {
        var threaded: std.Io.Threaded = .init(a, .{});
        defer threaded.deinit();
        const io = threaded.io();

        // Make sure the coin's conf is ready before the daemon reads it — RPC
        // creds (and server=1/daemon=1/rpcport) for a bitcoin-derived key=value
        // conf, or an API-key HOCON for Ergo. Otherwise a bitcoin daemon falls
        // back to cookie auth we can't use, leaving it unmanageable over RPC
        // (poll/stop). The coin owns the format; existing values are kept.
        try self.coin.prepareConf(a, io, self.install_root, self.home_dir);

        // The command to spawn — the bare daemon binary for fork coins, or a full
        // command line (e.g. `java -jar … -c <conf>`) for foreground coins.
        const argv = try self.coin.daemonArgv(a, self.install_root, self.home_dir);

        // Scratch file capturing the spawned process's stderr, read back for the
        // failure reason when a start goes wrong. Per-daemon name so coins
        // starting at once don't share the file.
        // Where to run the daemon. Only Ergo asks for one — it writes its log (and
        // any JVM crash dump) relative to the CWD, so left alone it litters
        // whatever directory BoxWallet was launched from, out of reach of the
        // startup-failure and warm-up readers. Everything else inherits ours.
        const child_cwd: std.process.Child.Cwd =
            if (try self.coin.daemonCwd(a, self.home_dir)) |path| .{ .path = path } else .inherit;

        const err_name = try std.fmt.allocPrint(a, ".{s}.startup", .{self.coin.daemonFile()});
        const err_path = try std.fs.path.join(a, &.{ self.install_root, err_name });
        var err_file = try std.Io.Dir.createFileAbsolute(io, err_path, .{ .read = true });
        defer {
            err_file.close(io);
            // Unlink once read: a process that still holds its own fd keeps the
            // now anonymous inode (which stays near-empty on a healthy run —
            // fatal startup errors are stderr's traffic, routine logging goes to
            // stdout), so its later writes are harmless rather than fatal. On
            // Windows the delete fails while a live daemon holds the file open
            // (caught); the next start truncates it instead.
            std.Io.Dir.deleteFileAbsolute(io, err_path) catch {};
        }

        // Foreground daemons run in their own process rather than forking and
        // exiting — Windows `*coind` (no `-daemon` support) and JVM apps like
        // Ergo's node. The POSIX "wait for the launcher to daemonize" model below
        // would block forever on them, so mirror Go's `cmd /C start /b`: spawn
        // detached and return without waiting. The process stays up on its own,
        // and the status poll flips the UI to "running" once it answers. With no
        // launcher exit code to consult, the fresh process is instead watched
        // briefly for an early death (see below).
        if (self.coin.launchMode() == .foreground) {
            var child = try std.process.spawn(io, .{
                .argv = argv,
                .environ_map = self.environ_map,
                .cwd = child_cwd,
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .{ .file = err_file },
                // Own process group: detach from BoxWallet's job group so the
                // daemon outlives the app cleanly. Otherwise it stays in the
                // terminal's foreground group — the shell won't reclaim the
                // terminal on quit (frozen prompt) and a Ctrl-C would reach the
                // daemon. The bitcoin fork path below gets this for free via the
                // daemon's own fork+setsid. Windows has no process groups and
                // types `pgid` as `?*anyopaque`, so the `0` POSIX sentinel ("new
                // group") doesn't apply there — leave it null.
                .pgid = if (@import("builtin").os.tag == .windows) null else 0,
                // Don't pop a console window for the background daemon (Windows).
                .create_no_window = @import("builtin").os.tag == .windows,
            });

            // Watch the fresh process briefly: a foreground daemon that dies
            // during init (port clash, datadir lock, corrupt DB, a JVM that
            // won't boot) does so within a few seconds, and this is the only way
            // to tell "started" from "flashed and died". A healthy daemon just
            // pays this window before "daemon running" is logged — slightly
            // longer than `confirmAlive`'s, since a failing JVM takes a few
            // seconds to go down.
            var i: u8 = 0;
            while (i < 12) : (i += 1) {
                io.sleep(.fromMilliseconds(250), .awake) catch {};
                const term = probeChild(io, &child) orelse continue;
                // Died during init. Prefer its stderr; fall back to its own
                // daemon log (the epee family reports fatal init errors there,
                // not on stderr; a no-op for coins that declare no log), then to
                // the bare exit status, so the log line always carries a reason.
                var buf: [8 * 1024]u8 = undefined;
                const n = err_file.readPositionalAll(io, &buf, 0) catch 0;
                self.setDaemonErr(buf[0..n]);
                if (self.daemon_err.len == 0) self.setDaemonErrFromDaemonLog(a, io);
                if (self.daemon_err.len == 0) {
                    var tbuf: [48]u8 = undefined;
                    self.storeDaemonErr(termMessage(&tbuf, term));
                }
                return error.DaemonStartFailed;
            }

            // Detached: deliberately not waited on, and in its own process
            // group, so it outlives this call free of the terminal. Retain the
            // handle so a coin with no shutdown RPC (zanod) can be killed on stop.
            // Reap whatever the last start left behind first — overwriting the
            // handle drops our only reference to that pid, stranding its zombie
            // for the life of the app if it died without being waited on.
            self.reapDaemonChild();
            self.daemon_child = child;
            return;
        }

        // Fork path (bitcoin-derived, POSIX): append `-daemon` so the daemon forks
        // itself into the background and the launcher exits, then wait on that
        // brief launcher.
        const forked = try std.mem.concat(a, []const u8, &.{ argv, &.{"-daemon"} });

        var child = try std.process.spawn(io, .{
            .argv = forked,
            .environ_map = self.environ_map,
            .cwd = child_cwd,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .{ .file = err_file },
        });
        switch (try child.wait(io)) {
            .exited => |code| if (code == 0) {
                // The launcher daemonized. But some daemons (e.g. nexad) fork
                // early and only then fail during init — a bad datadir, a
                // corrupt block index — so the launcher exits 0 while the real
                // daemon dies seconds later. Confirm it actually stayed up; if
                // not, the reason is in its own debug.log (its daemonized stderr
                // was redirected away from our scratch file), so surface that.
                if (self.confirmAlive(io)) return;
                self.setDaemonErrFromDaemonLog(a, io);
                return error.DaemonStartFailed;
            },
            else => {},
        }
        // The launcher itself exited non-zero / on a signal: a pre-fork failure
        // (datadir lock, chain-params assertion) it printed to its stderr.
        var buf: [8 * 1024]u8 = undefined;
        const n = err_file.readPositionalAll(io, &buf, 0) catch 0;
        self.setDaemonErr(buf[0..n]);
        return error.DaemonStartFailed;
    }

    /// After the launcher daemonizes, confirm the daemon process actually stuck
    /// around rather than forking and dying. Polls liveness over a short window
    /// (a failed daemon is gone almost immediately; a healthy one's process is
    /// present from the fork on). Returns false the moment it's seen gone.
    ///
    /// Liveness is by process name (like the Go `FindProcess`), so it needs no
    /// RPC and works before the daemon opens its RPC port. `/proc` on Linux,
    /// `pgrep` elsewhere; where neither can run, `proc_mod.alive` conservatively
    /// reports alive (we fall back to trusting the launcher's exit code, the
    /// prior behaviour).
    fn confirmAlive(self: *Activity, io: std.Io) bool {
        return proc_mod.stayedAlive(io, self.coin.daemonFile(), self.coin.daemonProcessCmdline());
    }

    /// Surface a failed start's reason from the coin's own daemon log (e.g.
    /// `<datadir>/debug.log`) — a daemonized child logs there rather than to the
    /// stderr we captured, and the epee family (Nerva/Salvium/Zano) writes fatal
    /// init errors to its log/console, not stderr. Reads only the tail (bounded,
    /// the file grows unboundedly) and picks the most error-like line.
    /// Best-effort: leaves `daemon_err` empty on any IO hiccup — or for a coin
    /// that declares no daemon log — so the caller falls back further.
    fn setDaemonErrFromDaemonLog(self: *Activity, a: std.mem.Allocator, io: std.Io) void {
        const log_name = self.coin.daemonLogFile() orelse return;
        const data_dir = self.coin.dataDir(a, self.home_dir) catch return;
        var buf: [4 * 1024]u8 = undefined;
        const pick = proc_mod.daemonLogReason(io, data_dir, log_name, &buf);
        if (pick.len != 0) self.storeDaemonErr(pick);
    }

    /// Stash a daemon-start failure reason into the program-lifetime
    /// `daemon_err_buf`. Prefers the first non-empty line of the daemon's stderr
    /// (the actionable message); leaves `daemon_err` empty when stderr is blank so
    /// `runDaemon` falls back to the launcher error name.
    fn setDaemonErr(self: *Activity, stderr: []const u8) void {
        var it = std.mem.splitScalar(u8, stderr, '\n');
        while (it.next()) |raw| {
            const t = std.mem.trim(u8, raw, " \t\r");
            if (t.len != 0) return self.storeDaemonErr(t);
        }
    }

    /// Copy `line` (trimmed/truncated to the buffer) into `daemon_err_buf` and
    /// point `daemon_err` at it.
    fn storeDaemonErr(self: *Activity, line: []const u8) void {
        const n = @min(line.len, self.daemon_err_buf.len);
        @memcpy(self.daemon_err_buf[0..n], line[0..n]);
        self.daemon_err = self.daemon_err_buf[0..n];
    }
};

/// Strip a log line's leading timestamp — shared with the GUI front-end, which
/// surfaces the same start-failure reasons (see `proc.zig`).
const stripLogTimestamp = proc_mod.stripLogTimestamp;

/// Pick the failure reason out of a daemon-log tail — shared with the GUI
/// front-end, which surfaces the same reasons (see `proc.zig`).
const pickDebugLogError = proc_mod.pickLogError;

/// Choose the most informative line from a wallet process's captured
/// stdout/stderr tail. `simplewallet` (and the epee family generally) prints a
/// clear reason on a failed open — a wrong password, an unreadable / corrupt or
/// version-incompatible wallet file, a refused daemon connection — usually right
/// before it exits, so the *last* error-like line wins, falling back to the last
/// non-empty line. Leading log timestamps are stripped. Returns a slice into
/// `tail` (empty only if `tail` has no content).
fn pickWalletError(tail: []const u8) []const u8 {
    const markers = [_][]const u8{
        "error",    "invalid", "wrong",  "failed", "exception",
        "unable",   "corrupt", "cannot", "denied", "not found",
        "password",
    };
    // Help/usage text a daemon or wallet dumps on an *argument* error is not the
    // failure reason, but reads like one. The worst offender is Zano
    // `simplewallet`'s `--seed-doctor` option description ("…doing back up(typo,
    // wrong words order, missing word)…"), which matches "wrong" and, printed
    // last in the options dump, wins over the real "failed to load wallet: <why>"
    // line above it — so a wrong password on a Zano *file* import surfaces as a
    // bogus seed complaint. Skip such lines so the true reason wins.
    const noise = [_][]const u8{
        "seed-doctor", "doing back up", "wrong words order",
    };
    var hit: []const u8 = "";
    var fallback: []const u8 = "";
    var it = std.mem.splitScalar(u8, tail, '\n');
    while (it.next()) |raw| {
        const line = stripLogTimestamp(std.mem.trim(u8, raw, " \t\r"));
        if (line.len == 0) continue;
        if (matchesAny(line, &noise)) continue;
        fallback = line;
        if (matchesAny(line, &markers)) hit = line;
    }
    return if (hit.len != 0) hit else fallback;
}

/// Consecutive stalled polls (~2s apart) required before `applyPoll` infers
/// presync from a non-advancing header height, when `debug.log` doesn't
/// confirm it directly. One stalled poll is noise (peer latency); this many in
/// a row is a real freeze.
const presync_stall_threshold = status_mod.presync_stall_threshold;

/// How far short of the network tip the local header height may sit while still
/// counting as "headers done" (see `Activity.inHeadersPhase`). Sized to absorb
/// the routine lag between a peer announcing a block and us committing its
/// header — tens of blocks on a fast chain — without swallowing a real header
/// download, which is orders of magnitude further behind.
const header_tip_slack = status_mod.header_tip_slack;

/// How many of a coin's most recent transactions the Transactions tab caches
/// and fetches per poll. Bounds both the RPC page size and the fixed-capacity
/// display buffer (`Activity.tx_buf`/`poll_tx_buf`) — no unbounded growth.
const tx_cache_cap: usize = 20;

/// The same bound for the Staking tab's list. A stake is a rarer event than a
/// transaction — one every few weeks, by the nature of a 30-day term — so 20
/// rows is a deep history here, not a page.
const stake_cache_cap: usize = 20;

const dirSizeBytes = disk.dirSizeBytes;

fn presyncPercentBp(io: std.Io, data_dir: []const u8) ?u32 {
    var dir = std.Io.Dir.cwd().openDir(io, data_dir, .{}) catch return null;
    defer dir.close(io);
    var file = dir.openFile(io, "debug.log", .{}) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    // A modest tail keeps the read flat and biases toward the latest presync
    // line; presync logs every couple of seconds, so the most recent one is
    // comfortably within the last few KiB.
    var buf: [4 * 1024]u8 = undefined;
    const off = if (stat.size > buf.len) stat.size - buf.len else 0;
    const n = file.readPositionalAll(io, &buf, off) catch return null;
    return parsePresyncPercentBp(buf[0..n]);
}

/// Extract the most recent headers pre-sync percentage from a `debug.log` tail,
/// as basis points (744 == 7.44%), or null if no presync line is present. Matches
/// only the presync pass line ("Pre-synchronizing blockheaders … (~X%)"), not the
/// later "Synchronizing blockheaders" redownload pass (during which the committed
/// header height climbs on its own). The *last* match wins — the freshest log
/// line. Returns a value clamped to 0..10000.
fn parsePresyncPercentBp(tail: []const u8) ?u32 {
    var found: ?u32 = null;
    var it = std.mem.splitScalar(u8, tail, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.indexOf(u8, line, "Pre-synchronizing blockheaders") == null) continue;
        // The figure sits between "(~" and the trailing "%" — e.g. "(~7.44%)".
        const open = std.mem.indexOf(u8, line, "(~") orelse continue;
        const rest = line[open + 2 ..];
        const pct_end = std.mem.indexOfScalar(u8, rest, '%') orelse continue;
        const num = std.mem.trim(u8, rest[0..pct_end], " ");
        const pct = std.fmt.parseFloat(f64, num) catch continue;
        const bp = pct * 100.0; // percent → basis points (two-decimal precision)
        const clamped = std.math.clamp(bp, 0.0, 10000.0);
        found = @intFromFloat(@round(clamped));
    }
    return found;
}

/// Which sub-stage of the block-index-loading window the daemon is in, per
/// `debug.log` — RPC's "-28" warm-up message only ever says the coarse
/// "Loading block index..." for this whole window; some daemons (DigiByte)
/// additionally log a finer-grained, percentage-bearing line for two
/// sub-stages RPC doesn't distinguish.
/// The daemon warm-up machinery is shared with the GUI front-end, which reports
/// the same stages (see `warmup.zig`).
const LoadStage = warmup.Stage;
const LoadProgress = warmup.Progress;
const readDaemonLogTail = warmup.readDaemonLogTail;
const parseLoadProgress = warmup.parseLoadProgress;

/// True if `line` contains any of `needles` (case-insensitive).
fn matchesAny(line: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (containsIgnoreCase(line, needle)) return true;
    return false;
}

/// Case-insensitive substring test (ASCII).
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return needle.len == 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Send `sig` to every process named `name` (matched against `/proc/<pid>/comm`,
/// truncated to 15 bytes), returning how many were signaled. The companion to
/// `processAlive` for the no-shutdown-RPC stop path: it terminates a daemon
/// found by binary name, whether or not we hold a handle to it. POSIX-only
/// (`/proc` + `kill`); the Windows stop path uses the handle / `taskkill`.
fn signalProcessesByName(io: std.Io, name: []const u8, sig: std.posix.SIG) usize {
    var proc = std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch return 0;
    defer proc.close(io);

    const want = if (name.len > 15) name[0..15] else name;

    var signaled: usize = 0;
    var it = proc.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory or entry.name.len == 0 or !std.ascii.isDigit(entry.name[0])) continue;
        var path_buf: [32]u8 = undefined;
        const comm_path = std.fmt.bufPrint(&path_buf, "{s}/comm", .{entry.name}) catch continue;
        var f = proc.openFile(io, comm_path, .{}) catch continue;
        defer f.close(io);
        var cbuf: [64]u8 = undefined;
        const n = f.readPositionalAll(io, &cbuf, 0) catch continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, cbuf[0..n], " \t\r\n"), want)) continue;
        const pid = std.fmt.parseInt(std.posix.pid_t, entry.name, 10) catch continue;
        std.posix.kill(pid, sig) catch continue;
        signaled += 1;
    }
    return signaled;
}

/// Non-blocking probe of a just-spawned child — see `proc_mod.probeChild`, which
/// the GUI drives too. Kept as a local alias so the call sites below read
/// unchanged.
const probeChild = proc_mod.probeChild;

/// Render a child's exit Term as a short human reason for the failed-start log
/// line ("exited with code 1", "killed by signal 11") — the last-resort
/// `daemon_err` when a dead daemon left nothing in its stderr or debug.log.
/// Copied out by `storeDaemonErr`, so a stack `buf` is fine.
fn termMessage(buf: []u8, term: std.process.Child.Term) []const u8 {
    return switch (term) {
        .exited => |code| std.fmt.bufPrint(buf, "exited with code {d}", .{code}) catch "exited during startup",
        .signal => |sig| if (std.posix.SIG == void)
            "killed by a signal"
        else
            std.fmt.bufPrint(buf, "killed by signal {d}", .{@intFromEnum(sig)}) catch "killed by a signal",
        .stopped => |sig| if (std.posix.SIG == void)
            "stopped by a signal"
        else
            std.fmt.bufPrint(buf, "stopped by signal {d}", .{@intFromEnum(sig)}) catch "stopped by a signal",
        .unknown => "exited during startup",
    };
}

/// Bounded action log. One fixed-capacity line per entry, kept in a ring so the
/// log's memory is flat regardless of how long the session runs (per the
/// project's memory constraint — no growing buffer).
const log_capacity = 128;
/// Wide enough to hold a full daemon-start failure reason (the daemon's own
/// stderr line — assertions and lock errors run long) after the timestamp and
/// "<coin>: daemon failed to start (…)" framing, rather than clipping its tail.
const log_line_max = 256;
const LogLine = struct {
    buf: [log_line_max]u8 = undefined,
    len: usize = 0,
};

/// How many of the most recent log entries the bottom pane shows at once
/// (toggled on/off with `l`). The pane is this many lines plus the separator
/// row above them; older entries scroll off the top.
const log_visible_lines = 6;

/// Outlook-style master/detail TUI: a navigation column on the left (Home +
/// coins) is always visible, a detail pane on the right shows the selected
/// coin. `up`/`down` move the selection, `i` installs/updates the selected
/// coin's daemon (in the background — you can navigate away while it runs), `q`
/// quits. An action log runs along the bottom, sized to ~20% of the terminal
/// height and toggled on/off with `l`.
pub const App = struct {
    /// Persistent (model-lifetime) allocator. Owns `install_root` and backs the
    /// transient work in `isInstalled`. Not the per-frame `ctx.allocator`.
    allocator: std.mem.Allocator,
    /// Per-platform `~/.boxwallet` dir where coin daemons are extracted.
    /// Resolved once in `init` from the process environment ($HOME, or
    /// %USERPROFILE% on Windows); lives for the program.
    install_root: []const u8,
    /// True when `install_root` is heap-allocated (and so must be freed in
    /// `deinit`); false when it's the static `fallback_install_root`.
    install_root_owned: bool,
    /// Process home dir ($HOME / %USERPROFILE%), duped onto the persistent
    /// allocator at `init` and freed in `deinit`. Passed to poll workers so they
    /// can locate each coin's conf for RPC credentials. Empty if unresolved.
    home_dir: []const u8,
    /// True when `home_dir` is heap-allocated (and so must be freed in `deinit`).
    home_dir_owned: bool,
    /// The process environment, handed to a daemon we spawn so it inherits $HOME
    /// (and the rest) — without it the daemon can't resolve its datadir and some
    /// coin daemons abort on startup. Borrowed from `ctx`; lives for the program.
    environ_map: *const std.process.Environ.Map,
    /// Monotonic timestamp (ns) of the last getinfo poll round, from the tick
    /// clock. Drives the shared ~2s poll cadence across all installed coins.
    last_poll_ns: i64 = 0,
    /// Monotonic timestamp (ns) of the last all-coins update scan, and whether one
    /// has run yet — so the left-nav arrows and Home summary cover every coin, not
    /// just the selected one. Scanned once up front, then on a slow ~5s cadence.
    last_update_scan_ns: i64 = 0,
    update_scan_done: bool = false,
    /// Disk usage of the filesystem that holds the install root (where the
    /// blockchains grow), refreshed on a slow ~30s cadence so the "Disk" bar
    /// reflects current fill without the cost of a per-frame `statfs`. `total`
    /// 0 means "not yet known / unavailable on this platform" → an empty bar.
    disk_used: u64 = 0,
    disk_total: u64 = 0,
    /// Monotonic timestamp (ns) of the last disk-usage refresh; 0 forces the
    /// first tick to sample immediately.
    last_disk_ns: i64 = 0,
    /// System physical-memory usage, sampled on a short (~3s) cadence and drawn
    /// as a bar under the Disk bar. `mem_total` 0 means "not yet known /
    /// unavailable on this platform" → an empty bar.
    mem_used: u64 = 0,
    mem_total: u64 = 0,
    /// Monotonic timestamp (ns) of the last memory sample; the first sample is
    /// taken in `init`, so this paces the refreshes thereafter.
    last_mem_ns: i64 = 0,
    /// The program's `std.Io` (captured from `ctx` in `init`). Used to read the
    /// wall clock for log timestamps; the backing implementation outlives the
    /// model, so holding the lightweight vtable handle is safe.
    io: std.Io,
    /// Local timezone's UTC offset in seconds, resolved once from the system
    /// zoneinfo at `init` and applied to log timestamps. 0 (UTC) if it can't be
    /// resolved. Fixed for the session — a mid-session DST change isn't tracked.
    tz_offset_s: i32,
    nexa: Nexa,
    divi: Divi,
    ergo: Ergo,
    digibyte: DigiByte,
    zano: Zano,
    nerva: Nerva,
    reddcoin: ReddCoin,
    epic: Epic,
    salvium: Salvium,
    monero: Monero,
    litecoin: Litecoin,
    bitcoin: Bitcoin,
    bitcoinz: BitcoinZ,
    spiderbyte: SpiderByte,
    selected: usize,
    /// Which tab of the selected coin's detail pane is showing. Global rather
    /// than per-coin: switching coins resets it to Home (see `move`).
    active_tab: DetailTab = .home,
    /// A "New address" request from the Receive tab's `n` key, waiting to be
    /// staged onto the selected coin's `Activity` at the next poll spawn (see
    /// that site). Only ever touched by the UI thread.
    pending_new_receive_address: bool = false,
    /// One per `entries` slot (index 0 / Home is unused), holding that coin's
    /// independent install state. Parallel to `entries` so the selected coin's
    /// activity is `activities[selected]`.
    activities: [entries.len]Activity,
    /// Ring buffer of recent action messages, painted in the bottom log pane.
    log_lines: [log_capacity]LogLine = [_]LogLine{.{}} ** log_capacity,
    /// Total messages ever logged; the live slot is `log_count % log_capacity`.
    log_count: usize = 0,
    /// Whether the bottom log pane is shown; `l` toggles it.
    log_visible: bool = true,
    /// Privacy toggle: when set, every wallet balance figure is masked with
    /// `balance_mask` (`*****`) instead of the amount — for shoulder-surfers,
    /// screen-shares, and screen recordings. `h` toggles it, and the choice is
    /// persisted to `boxwallet.conf` under the install root so it survives a
    /// restart (loaded in `init`, written in `toggleHideBalances`). Masks the
    /// user's own holdings (header Total/Available, Send/Stake available, the
    /// DigiDollar balance) — not public chain stats or transaction history.
    hide_balances: bool = false,

    // --- USD prices (background, app-level) --------------------------------
    // One request covers the whole coin roster on a slow cadence — see
    // `src/price.zig` for the cadence and the privacy rationale.
    /// Opt-out: prices are on by default and `p` turns them off, persisted to
    /// `boxwallet.conf` beside `hide_balances`. **Off means no request is ever
    /// made** — not a fetch whose result is hidden — so disabling it is a real
    /// network opt-out, which is the whole point of offering it.
    show_prices: bool = true,
    /// Latest quote per `entries` slot (index 0 / Home unused), parallel to
    /// `activities`. `have` false = no price to show for that coin.
    prices: [entries.len]price.Quote = [_]price.Quote{.{}} ** entries.len,
    /// Wall-clock (unix seconds) of the last *successful* fetch, 0 if none yet.
    /// Quotes older than `price.max_age_s` stop being displayed rather than
    /// misrepresenting what a balance is worth.
    price_fetched_at: i64 = 0,
    /// Monotonic ns of the last fetch attempt, and how many have failed in a
    /// row — together these drive the backoff (`price.backoffSeconds`).
    price_last_try_ns: i64 = 0,
    price_failures: u32 = 0,
    /// True once the first fetch has been kicked off, so startup isn't delayed
    /// by a network round trip (same deferral as the update check).
    price_started: bool = false,
    /// The in-flight fetch worker, joined when `price_done` is observed.
    price_thread: ?std.Thread = null,
    /// Sync edge: stored with release by the worker when the fetch finishes; the
    /// UI loads it with acquire, then reads `price_result`/`price_ok` and joins.
    price_done: std.atomic.Value(bool) = .init(false),
    /// Worker output, read by the UI only after the `price_done` edge — so these
    /// plain fields need no atomics.
    price_result: [entries.len]price.Quote = [_]price.Quote{.{}} ** entries.len,
    price_ok: bool = false,

    /// The open `w` wallet modal, or null when no modal is up. While set, the
    /// modal owns keyboard input and is composited over the dashboard.
    modal: ?Modal = null,
    /// The open QuickSync (daemon-start) prompt, or null. Mutually exclusive with
    /// `modal`; while set it owns keyboard input and is composited over the
    /// dashboard, same as the wallet modal.
    qs_modal: ?QuickSyncModal = null,
    /// The open update-confirm prompt, or null. Mutually exclusive with the other
    /// modals; while set it owns keyboard input and is composited over the dashboard.
    update_modal: ?UpdateModal = null,
    /// The open first-start prune prompt, or null. Mutually exclusive with the
    /// other modals; while set it owns keyboard input and is composited over the
    /// dashboard, same as the wallet/QuickSync modals.
    prune_modal: ?PruneModal = null,
    /// The open Send prompt, or null. Mutually exclusive with the other
    /// modals; while set it owns keyboard input and is composited over the
    /// dashboard, same as the others.
    send_modal: ?SendModal = null,
    /// The open Mining prompt, or null. Mutually exclusive with the other
    /// modals; while set it owns keyboard input and is composited over the
    /// dashboard, same as the others.
    mining_modal: ?MiningModal = null,
    /// The open stablecoin (DigiDollar) prompt, or null. Mutually exclusive
    /// with the other modals; while set it owns keyboard input and is
    /// composited over the dashboard, same as the others.
    sc_modal: ?StablecoinModal = null,
    /// A "New address" request from the stablecoin tab's `n` key, waiting to
    /// be staged onto the selected coin's `Activity` at the next poll spawn —
    /// the stablecoin twin of `pending_new_receive_address`.
    pending_new_sc_address: bool = false,
    /// Masked passphrase entry for the wallet modal. Persistent (its backing
    /// buffer outlives a single modal), created in `init` and freed in `deinit`;
    /// its value is cleared whenever the modal closes or an action is sent.
    pw_input: zz.TextInput,
    /// Visible entry for a restore seed (external-wallet flow). Like
    /// `pw_input`, persistent and cleared on close/submit.
    seed_input: zz.TextInput,
    /// Visible entry for a custom prune amount in GB (prune prompt). Persistent
    /// like the others; digits only, cleared whenever the prompt opens.
    prune_input: zz.TextInput,
    /// Visible entry for a send destination address. Persistent like the
    /// others; unrestricted characters (base58/bech32), cleared whenever the
    /// Send modal opens.
    send_addr_input: zz.TextInput,
    /// Visible entry for a send amount. Persistent like the others; digits
    /// and one decimal point, cleared whenever the Send modal opens.
    send_amount_input: zz.TextInput,
    /// Visible entry for the Mining prompt's CPU thread count. Persistent like
    /// the others; digits only, cleared whenever the prompt opens.
    mining_input: zz.TextInput,
    /// File browser for the restore-from-file flow (external-wallet coins).
    /// Persistent; navigated on demand, freed in `deinit`.
    file_picker: zz.components.FilePicker,
    /// The directory the last restore-from-file browsed to, remembered for this
    /// session so a subsequent restore re-opens there instead of home. In-memory
    /// only (never written to disk); empty until the first file is picked.
    last_file_dir_buf: [1024]u8 = undefined,
    last_file_dir_len: usize = 0,

    // --- in-app self-update check (background) -----------------------------
    // A one-shot worker asks GitHub for the latest release and, if it's newer,
    // downloads + checksum-verifies it and stages it for next launch (the swap
    // itself happens in `main` before the TUI starts). The Home pane shows a
    // "restart to apply" notice once a build is staged.
    /// Set true once the check has been kicked off, so it runs once per session.
    update_started: bool = false,
    /// The update-check worker handle, joined when `update_done` is observed.
    update_thread: ?std.Thread = null,
    /// Sync edge: stored with release by the worker when the check finishes; the
    /// UI loads it with acquire, then reads the result fields and joins.
    update_done: std.atomic.Value(bool) = .init(false),
    /// Sync edge: stored with release by the worker the moment it commits to
    /// downloading a newer build (before the download), so the UI can log
    /// "downloading vX" up front. The UI loads it with acquire, then reads
    /// `update_dl_version`.
    update_downloading: std.atomic.Value(bool) = .init(false),
    /// The version being downloaded, written once by the worker before it sets
    /// `update_downloading`; read by the UI after that acquire edge. Distinct
    /// from `update_version` so the two writes never race.
    update_dl_version: updater.VersionBuf = .{},
    /// UI-thread-only latch so the "downloading vX" line is logged just once.
    update_dl_logged: bool = false,
    /// Worker result, read by the UI only after the `update_done` edge — so
    /// these plain fields need no atomics.
    update_status: updater.CheckStatus = .up_to_date,
    update_version: updater.VersionBuf = .{},
    /// True once a newer build has been staged for next launch.
    update_available: bool = false,
    /// True when an update is staged but the executable's directory isn't
    /// writable, so a restart wouldn't apply it — the Home pane says so instead
    /// of a "restart to apply" that wouldn't take.
    update_blocked: bool = false,
    /// Whether mouse tracking is on (it is at startup — see `main.zig`). While on,
    /// the terminal reports clicks to us instead of doing its own text selection,
    /// so `m` turns it off to hand selection (and copy) back to the terminal.
    mouse_on: bool = true,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        /// A click, drag, or wheel notch. ZigZag only routes these to us because
        /// this field exists (see its `processMouseEvent`), and only while mouse
        /// tracking is on.
        mouse: zz.MouseEvent,
        /// Periodic tick (see the `.every` in `init`): advances the extract
        /// spinners and folds finished installs back into `installed`.
        tick: zz.msg.Tick,
    };

    pub fn init(self: *App, ctx: *zz.Context) zz.Cmd(Msg) {
        // Resolve ~/.boxwallet (or %USERPROFILE%\AppData\Roaming\BoxWallet on
        // Windows) from the home dir in the process environment. ZigZag 0.1.5
        // exposes the raw env map rather than a captured home dir, so read
        // $HOME (%USERPROFILE% on Windows) ourselves. Held on the persistent
        // allocator so it outlives the per-frame arena (and is freed in
        // `deinit`); on the unlikely allocation failure, fall back to a relative
        // dir that we don't own.
        const home_key = if (@import("builtin").os.tag == .windows) "USERPROFILE" else "HOME";
        const home_dir = ctx.environ_map.get(home_key) orelse "";

        var install_root: []const u8 = fallback_install_root;
        var install_root_owned = false;
        if (install_mod.installRoot(ctx.persistent_allocator, home_dir)) |root| {
            install_root = root;
            install_root_owned = true;
        } else |_| {}

        // Keep our own copy of the home dir: the env map's slice isn't ours to
        // hold, and poll workers read it off another thread.
        var home_owned: []const u8 = "";
        var home_owned_flag = false;
        if (home_dir.len > 0) {
            if (ctx.persistent_allocator.dupe(u8, home_dir)) |h| {
                home_owned = h;
                home_owned_flag = true;
            } else |_| {}
        }

        self.* = .{
            .allocator = ctx.persistent_allocator,
            .install_root = install_root,
            .install_root_owned = install_root_owned,
            .home_dir = home_owned,
            .home_dir_owned = home_owned_flag,
            .environ_map = ctx.environ_map,
            .io = ctx.io,
            .tz_offset_s = localOffsetSeconds(
                ctx.persistent_allocator,
                ctx.io,
                std.Io.Timestamp.now(ctx.io, .real).toSeconds(),
            ),
            .nexa = .{},
            .divi = .{},
            .ergo = .{},
            .digibyte = .{},
            .zano = .{},
            .nerva = .{},
            .reddcoin = .{},
            .epic = .{},
            .salvium = .{},
            .monero = .{},
            .litecoin = .{},
            .bitcoin = .{},
            .bitcoinz = .{},
            .spiderbyte = .{},
            .selected = 0,
            .activities = undefined,
            .pw_input = zz.TextInput.init(ctx.persistent_allocator),
            .seed_input = zz.TextInput.init(ctx.persistent_allocator),
            .prune_input = zz.TextInput.init(ctx.persistent_allocator),
            .send_addr_input = zz.TextInput.init(ctx.persistent_allocator),
            .send_amount_input = zz.TextInput.init(ctx.persistent_allocator),
            .mining_input = zz.TextInput.init(ctx.persistent_allocator),
            .file_picker = zz.components.FilePicker.init(ctx.persistent_allocator),
        };
        // The wallet passphrase field masks its input and stays a fixed width.
        self.pw_input.setEchoMode(.password);
        self.pw_input.setWidth(24);
        self.pw_input.setCharLimit(wallet_pw_max);
        // The seed field shows its words (you're transcribing a known phrase) and
        // is wide enough for a 25-word mnemonic.
        self.seed_input.setWidth(modal_inner_w - 6);
        self.seed_input.setCharLimit(256);
        // The custom-prune field takes a plain GB number — visible, narrow, and
        // capped at a handful of digits.
        self.prune_input.setWidth(10);
        self.prune_input.setCharLimit(6);
        // The send-address field is wide enough for any realistic coin address
        // and generous on length (unrestricted characters — base58/bech32).
        self.send_addr_input.setWidth(modal_inner_w - 6);
        self.send_addr_input.setCharLimit(128);
        // The send-amount field is a plain decimal number — visible, narrow.
        self.send_amount_input.setWidth(20);
        self.send_amount_input.setCharLimit(20);
        // The mining thread-count field takes a small integer — visible, tiny.
        self.mining_input.setWidth(6);
        self.mining_input.setCharLimit(4);
        // The file browser is for picking a wallet file, in a modest viewport
        // that fits the centered modal. `file_only` must stay false: ZigZag
        // implements it by hiding every directory from the listing (not just
        // making them unselectable), which would strip the subdirectories you
        // need to navigate through to reach the file. Directories navigate on
        // Enter; only an actual file is ever submitted (see selectCurrent).
        self.file_picker.file_only = false;
        self.file_picker.height = 12;
        // ZigZag defaults the entry icons to emoji (📁/📄/🔗/📂), which render
        // as boxes or wrong-width glyphs on terminals without emoji fonts (SSH,
        // the Linux console), mangling row alignment so paths can't be read.
        // Plain ASCII markers stay aligned everywhere.
        self.file_picker.dir_icon = "[D] ";
        self.file_picker.parent_icon = "[^] ";
        self.file_picker.link_icon = "[L] ";
        self.file_picker.file_icon = "[F] ";
        self.file_picker.blur();
        // Every animation is the same orbiting braille puck: Running/Staking/
        // Peers and the install progress via `makeSpinner`, and the sync line
        // via a bare `init()` whose frames `onTick` swaps cw/ccw by peer count.
        for (&self.activities) |*act| act.* = .{ .spinner = makeSpinner(), .daemon_spinner = makeSpinner(), .sync_spinner = zz.Spinner.init() };
        self.refreshSelectedInstalled();
        // Restore the persisted balance-privacy toggle (off if never set).
        self.hide_balances = self.loadHideBalances();
        self.show_prices = self.loadShowPrices();

        // Take the first disk-usage sample now, synchronously, so the bar is
        // populated before the first frame is drawn rather than blank until the
        // 30s refresh cadence first fires (the tick clock is elapsed-since-start,
        // so a 0 `last_disk_ns` wouldn't come due for 30s). It's a single cheap
        // `statfs` — microseconds, no disk scan — so it's fine at startup.
        self.refreshDisk();
        // Take the first memory sample now too, so its bar isn't empty until the
        // ~3s refresh cadence first fires.
        self.refreshMemory();

        // Seed the action log so the pane starts with a line announcing the
        // running build rather than an empty box.
        self.logf("{s}: TUI v{s} started", .{ home_brand_text, app_version });

        // A modest repeating tick so background installs animate and their
        // completions are noticed without waiting on a keypress. Idle ticks are
        // cheap — the renderer only repaints when the view actually changes.
        return .{ .every = 100 * std.time.ns_per_ms };
    }

    /// Called by ZigZag's `Program.deinit` at shutdown. Joins any in-flight
    /// install workers (so they don't outlive the state they write into), then
    /// frees the model's owned allocations.
    pub fn deinit(self: *App) void {
        // Ask any accelerator transfer to stop *before* joining anything. A chain
        // snapshot runs for the better part of an hour, so without this, quitting
        // mid-download would hang the exit until it finished. Pausing is exactly
        // the right answer anyway: the partial is flushed and kept, and the next
        // run offers to continue from there.
        for (&self.activities) |*act| act.qs_pause.store(true, .monotonic);

        // Join the background update-check worker so it doesn't outlive the App
        // fields it writes into.
        if (self.update_thread) |t| {
            t.join();
            self.update_thread = null;
        }
        // Same for the price worker — it writes into App fields.
        if (self.price_thread) |t| {
            t.join();
            self.price_thread = null;
        }
        for (&self.activities) |*act| {
            if (act.thread) |t| {
                t.join();
                act.thread = null;
            }
            if (act.daemon_thread) |t| {
                t.join();
                act.daemon_thread = null;
            }
            if (act.qs_thread) |t| {
                t.join();
                act.qs_thread = null;
            }
            if (act.poll_thread) |t| {
                t.join();
                act.poll_thread = null;
            }
            if (act.wallet_thread) |t| {
                t.join();
                act.wallet_thread = null;
            }
            if (act.wallet_setup_thread) |t| {
                t.join();
                act.wallet_setup_thread = null;
            }
            if (act.send_thread) |t| {
                t.join();
                act.send_thread = null;
            }
            if (act.mining_thread) |t| {
                t.join();
                act.mining_thread = null;
            }
            if (act.sc_thread) |t| {
                t.join();
                act.sc_thread = null;
            }
            // Tear down the external wallet process so it doesn't outlive the app.
            self.killWalletRpc(act);
            // Secrets may still be resident if a worker was in flight at shutdown —
            // clear them rather than leave them in freed memory.
            @memset(&act.wallet_pw_buf, 0);
            @memset(&act.wallet_seed_buf, 0);
            act.wallet_setup_seed = .{};
        }
        self.pw_input.deinit();
        self.seed_input.deinit();
        self.prune_input.deinit();
        self.send_addr_input.deinit();
        self.send_amount_input.deinit();
        self.mining_input.deinit();
        self.file_picker.deinit();
        if (self.install_root_owned) self.allocator.free(self.install_root);
        if (self.home_dir_owned) self.allocator.free(self.home_dir);
    }

    pub fn update(self: *App, msg: Msg, ctx: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            // While the wallet modal is open it owns the keyboard — global keys
            // (quit/install/navigate) are suppressed so typing a passphrase or
            // walking the menu doesn't also drive the dashboard.
            .key => |k| {
                // The QuickSync prompt (daemon-start) and the wallet modal each own
                // the keyboard while open; only one is ever open at a time.
                if (self.update_modal != null) {
                    self.updateModalKey(k);
                    return .none;
                }
                if (self.qs_modal != null) {
                    self.qsModalKey(k);
                    return .none;
                }
                if (self.prune_modal != null) {
                    self.pruneModalKey(k);
                    return .none;
                }
                if (self.modal != null) {
                    self.modalKey(k);
                    return .none;
                }
                if (self.send_modal != null) {
                    self.sendModalKey(k);
                    return .none;
                }
                if (self.mining_modal != null) {
                    self.miningModalKey(k);
                    return .none;
                }
                if (self.sc_modal != null) {
                    self.scModalKey(k);
                    return .none;
                }
                // Detail-pane tabs only exist for a selected coin, not the Home
                // screen — so left/right and the numbered jumps are live only
                // then. The capability tabs (Mining, DigiDollar, Staking) exist
                // only for a coin wiring the capability, so their jump/cycle
                // stops are gated per coin.
                const on_coin = self.selectedCoin() != null;
                const caps: TabCaps = if (self.selectedCoin()) |c| TabCaps.of(c) else .{};
                switch (k.key) {
                    .char => |c| switch (c) {
                        'q' => return .quit,
                        'i' => self.tryInstall(),
                        'u' => self.tryUpdate(),
                        's' => self.tryToggleDaemon(),
                        'w' => self.openWalletModal(),
                        'k' => self.move(-1),
                        'j' => self.move(1),
                        'l' => self.log_visible = !self.log_visible,
                        'h' => self.toggleHideBalances(),
                        'p' => self.togglePrices(),
                        // Mouse tracking claims the terminal's own click handling,
                        // which is what normally drives select-to-copy. Toggling it
                        // off hands that back, so an address in the detail pane can
                        // be selected with the mouse the usual way.
                        'm' => {
                            self.mouse_on = !self.mouse_on;
                            self.logf("{s}", .{if (self.mouse_on)
                                "Mouse on — click the left bar to switch coin"
                            else
                                "Mouse off — terminal text selection restored (m: back on)"});
                            return if (self.mouse_on) .enable_mouse else .disable_mouse;
                        },
                        'c' => if (on_coin and self.active_tab == .receive)
                            self.copyReceiveAddress(ctx)
                        else if (on_coin and self.active_tab == .digidollar)
                            self.copyStablecoinAddress(ctx),
                        'n' => if (on_coin and self.active_tab == .receive)
                            self.requestNewReceiveAddress()
                        else if (on_coin and self.active_tab == .digidollar)
                            self.requestNewStablecoinAddress(),
                        // Capital S — lowercase 's' toggles the daemon. Opens the
                        // Stake prompt on the Send tab for coins with a stake
                        // action (openStakeModal checks the capability itself).
                        'S' => if (on_coin and self.active_tab == .staking) self.openStakeModal(),
                        't' => if (on_coin) self.copyTipAddress(ctx),
                        // Jump straight to a tab by number, positional over the
                        // *visible* strip (1 = Home … 5 = Settings, 6 = the
                        // coin's capability tab when it has one).
                        '1'...'7' => if (on_coin) {
                            if (visibleTabAt(c - '1', caps)) |t| self.active_tab = t;
                        },
                        else => {},
                    },
                    .up => self.move(-1),
                    .down => self.move(1),
                    .left => if (on_coin) {
                        self.active_tab = cycleTab(self.active_tab, -1, caps);
                    },
                    .right => if (on_coin) {
                        self.active_tab = cycleTab(self.active_tab, 1, caps);
                    },
                    .enter => if (on_coin) switch (self.active_tab) {
                        .send => self.openSendModal(),
                        .mining => self.openMiningModal(),
                        .digidollar => self.openStablecoinModal(),
                        else => {},
                    },
                    else => {},
                }
            },
            .mouse => |m| self.onMouse(m, ctx),
            .tick => |t| self.onTick(t),
        }
        return .none;
    }

    /// Whether any modal is up. While one is, it owns the input — the dashboard
    /// underneath is inert (the `.key` arm above enforces the same for keys).
    fn modalOpen(self: *const App) bool {
        return self.update_modal != null or self.qs_modal != null or self.prune_modal != null or
            self.modal != null or self.send_modal != null or self.mining_modal != null or
            self.sc_modal != null;
    }

    /// Handle a mouse event: click a left-nav row to select that coin, or wheel
    /// over the nav to step the selection. Everything else — moves, drags,
    /// releases, and anything outside the nav column — is ignored, so the mouse
    /// can't reach an action that spends funds or starts a daemon; those stay on
    /// the keyboard. A modal swallows the event entirely: its buttons aren't
    /// hit-tested, and a stray click behind it must not move the dashboard.
    fn onMouse(self: *App, m: zz.MouseEvent, ctx: *const zz.Context) void {
        // `disable_mouse` only *asks* the terminal to stop reporting; a terminal or
        // multiplexer that keeps sending anyway must not still move the selection —
        // the user turned the mouse off precisely to select text with it. So the
        // toggle is enforced here rather than trusted to the terminal.
        if (!self.mouse_on) return;
        if (self.modalOpen()) return;
        if (m.event_type != .press) return;
        if (m.x >= nav_col_w) return;

        switch (m.button) {
            // Wheel notches step the selection like j/k, so the list scrolls under
            // the cursor. `move` clamps at both ends.
            .wheel_up => self.move(-1),
            .wheel_down => self.move(1),
            .left => {
                // Re-derive the rows exactly as this frame drew them, then map the
                // clicked row to its entry. A click on a scroll-indicator row (or
                // past the last row) selects nothing.
                var rows: [entries.len + 2]NavRow = undefined;
                const n = navRows(self.selected, self.navRowBudget(ctx.height), &rows);
                if (m.y >= n) return;
                switch (rows[m.y]) {
                    .entry => |ei| {
                        // Go through `move` rather than assigning `selected`, so a
                        // click takes the same path as the arrow keys — refreshing
                        // the newly selected coin and resetting its poll clock.
                        const delta = @as(i32, @intCast(ei)) - @as(i32, @intCast(self.selected));
                        if (delta != 0) self.move(delta);
                    },
                    .more_above, .more_below => {},
                }
            },
            else => {},
        }
    }

    /// How many terminal rows the two-pane block gets: everything the log pane
    /// isn't using. 0 means "height unknown" (e.g. tests) and leaves it unbounded.
    /// A known height always keeps at least one row, so a terminal shorter than
    /// the log pane still stays bounded rather than falling into "unlimited".
    fn navRowBudget(self: *const App, height: u16) usize {
        if (height == 0) return 0;
        return @max(1, @as(usize, height) -| (if (self.log_visible) @as(usize, log_pane_rows) else 0));
    }

    /// Handle a keypress while the wallet modal is open. Drives the modal's small
    /// state machine: walk the menu, type the passphrase, then `enter` fires the
    /// action; `esc` cancels (or dismisses the result). Keys are swallowed here so
    /// nothing reaches the dashboard.
    fn modalKey(self: *App, k: zz.KeyEvent) void {
        if (self.modal == null) return;
        const m = &self.modal.?;
        switch (m.stage) {
            .menu => switch (k.key) {
                .escape => self.closeWalletModal(),
                .up => if (m.sel > 0) {
                    m.sel -= 1;
                },
                .down => if (m.sel + 1 < m.option_count) {
                    m.sel += 1;
                },
                .enter => {
                    if (m.option_count == 0) return;
                    m.action = m.options[m.sel];
                    if (m.action == .restore or m.action == .restore_file_offline) {
                        // Restore needs a backup file — browse for it, then submit
                        // (no password: the RPC import runs on the unlocked wallet,
                        // and the offline swap runs with the daemon stopped).
                        m.stage = .setup_file;
                        self.startFilePicker();
                    } else if (m.action.needsPassword()) {
                        m.stage = .password;
                        self.pw_input.setValue("") catch {};
                        self.pw_input.focus();
                    } else {
                        self.submitWalletAction();
                    }
                },
                .char => |c| switch (c) {
                    'k' => if (m.sel > 0) {
                        m.sel -= 1;
                    },
                    'j' => if (m.sel + 1 < m.option_count) {
                        m.sel += 1;
                    },
                    else => {},
                },
                else => {},
            },
            .password => switch (k.key) {
                .escape => self.closeWalletModal(),
                // Submit only with a non-empty passphrase; an empty enter is a
                // no-op (the daemon would just reject it).
                .enter => if (self.pw_input.getValue().len > 0) self.submitWalletAction(),
                // Everything else (chars, backspace, paste) edits the field.
                else => self.pw_input.handleKey(k),
            },
            // --- external-wallet setup flow ---------------------------------
            .setup_menu => switch (k.key) {
                .escape => self.closeWalletModal(),
                .up => if (m.setup_sel > 0) {
                    m.setup_sel -= 1;
                },
                .down => if (m.setup_sel + 1 < m.setup_option_count) {
                    m.setup_sel += 1;
                },
                .enter => {
                    // create → set new password; restores collect input first;
                    // unlock → existing password; lock fires straight away; replace
                    // goes to the destructive typed confirmation.
                    switch (m.setup_options[m.setup_sel]) {
                        .create => {
                            m.setup_op = .create;
                            m.stage = .setup_password;
                            self.pw_input.setValue("") catch {};
                            self.pw_input.focus();
                        },
                        .restore_seed => {
                            m.setup_op = .restore_seed;
                            m.stage = .setup_seed_input;
                            self.seed_input.setValue("") catch {};
                            self.seed_input.focus();
                        },
                        .restore_file => {
                            m.setup_op = .restore_file;
                            m.stage = .setup_file;
                            self.startFilePicker();
                        },
                        .unlock => {
                            m.setup_op = .open;
                            m.stage = .setup_password;
                            self.pw_input.setValue("") catch {};
                            self.pw_input.focus();
                        },
                        .lock => {
                            m.setup_op = .lock;
                            self.submitWalletSetup();
                        },
                        .replace => {
                            m.replace_bad = false;
                            m.stage = .setup_replace_confirm;
                            self.seed_input.setValue("") catch {};
                            self.seed_input.focus();
                        },
                    }
                },
                .char => |c| switch (c) {
                    'k' => if (m.setup_sel > 0) {
                        m.setup_sel -= 1;
                    },
                    'j' => if (m.setup_sel + 1 < m.setup_option_count) {
                        m.setup_sel += 1;
                    },
                    else => {},
                },
                else => {},
            },
            // New-password ops go on to a confirm step; `open` (existing password)
            // submits straight to the worker. Ops that open an existing wallet also
            // accept a blank password (an unencrypted restored/imported wallet).
            .setup_password => switch (k.key) {
                .escape => self.closeWalletModal(),
                .enter => if (self.pw_input.getValue().len > 0 or m.setup_op.allowsEmptyPassword()) {
                    if (m.setup_op.setsNewPassword()) {
                        // Stash this entry and ask for it again.
                        const pw = self.pw_input.getValue();
                        const n = @min(pw.len, m.pw_first_buf.len);
                        @memcpy(m.pw_first_buf[0..n], pw[0..n]);
                        m.pw_first_len = n;
                        m.stage = .setup_password_confirm;
                        self.pw_input.setValue("") catch {};
                        self.pw_input.focus();
                    } else {
                        self.submitWalletSetup();
                    }
                },
                // Typing dismisses a prior mismatch note.
                else => {
                    m.pw_mismatch = false;
                    self.pw_input.handleKey(k);
                },
            },
            // Confirm the new password matches; mismatch resets to the first entry.
            .setup_password_confirm => switch (k.key) {
                .escape => self.closeWalletModal(),
                .enter => if (self.pw_input.getValue().len > 0) {
                    if (std.mem.eql(u8, self.pw_input.getValue(), m.pw_first_buf[0..m.pw_first_len])) {
                        self.submitWalletSetup();
                    } else {
                        // Wipe both entries and send them back to re-enter.
                        @memset(&m.pw_first_buf, 0);
                        m.pw_first_len = 0;
                        m.pw_mismatch = true;
                        m.stage = .setup_password;
                        self.pw_input.setValue("") catch {};
                        self.pw_input.focus();
                    }
                },
                else => self.pw_input.handleKey(k),
            },
            // Seed words entered → on to the password step.
            .setup_seed_input => switch (k.key) {
                .escape => self.closeWalletModal(),
                .enter => if (self.seed_input.getValue().len > 0) {
                    m.stage = .setup_password;
                    self.pw_input.setValue("") catch {};
                    self.pw_input.focus();
                },
                else => self.seed_input.handleKey(k),
            },
            // The file picker owns navigation; a file selection moves on. The
            // external-wallet restore then asks for a password; the in-daemon
            // restore (bitcoin coins) submits straight away — its wallet is
            // already unlocked, so no password is needed.
            .setup_file => switch (k.key) {
                .escape => self.closeWalletModal(),
                else => {
                    const selected = self.file_picker.handleKey(self.io, self.environ_map, k) catch false;
                    if (selected) {
                        // Remember where they browsed so the next restore starts here.
                        if (self.file_picker.getSelected()) |fp| self.rememberFileDir(fp);
                        const ext = if (self.coinAt(m.coin_idx)) |c| c.hasExternalWallet() else false;
                        if (ext) {
                            m.stage = .setup_password;
                            self.pw_input.setValue("") catch {};
                            self.pw_input.focus();
                        } else if (m.action == .restore_file_offline) {
                            // Bitcoin-style offline swap: stash the picked path and
                            // confirm before bouncing the daemon to load it.
                            const act = &self.activities[m.coin_idx];
                            const fp = self.file_picker.getSelected() orelse "";
                            const fl = @min(fp.len, act.wallet_file_buf.len);
                            @memcpy(act.wallet_file_buf[0..fl], fp[0..fl]);
                            act.wallet_file_len = fl;
                            m.stage = .restore_file_confirm;
                        } else {
                            self.submitWalletAction();
                        }
                    }
                },
            },
            // The freshly-created seed is on screen; any key moves to the backup
            // quiz (the wallet is already created at this point — the quiz just
            // confirms the user wrote the words down correctly). `esc` skips it.
            .setup_seed_show => switch (k.key) {
                .escape => self.closeWalletModal(),
                else => {
                    m.verify_step = 0;
                    m.verify_bad = false;
                    _ = pickVerifyPositions(self.io, countWords(m.seed.slice()), &m.verify_pos);
                    m.stage = .setup_seed_verify;
                    self.seed_input.setValue("") catch {};
                    self.seed_input.focus();
                },
            },
            // Backup quiz: each correct word advances; the third finishes. A wrong
            // answer sends them back to the seed so they can fix their written copy.
            .setup_seed_verify => switch (k.key) {
                .escape => self.closeWalletModal(),
                .enter => {
                    const entered = std.mem.trim(u8, self.seed_input.getValue(), " \t\r\n");
                    if (entered.len == 0) {} else if (std.ascii.eqlIgnoreCase(entered, nthWord(m.seed.slice(), m.verify_pos[m.verify_step]))) {
                        self.seed_input.setValue("") catch {};
                        m.verify_bad = false;
                        if (m.verify_step + 1 >= 3) {
                            self.seed_input.blur();
                            m.setMsg(true, "Backup verified — your wallet is ready.");
                        } else {
                            m.verify_step += 1;
                        }
                    } else {
                        // Their written copy is wrong — show the seed again to fix.
                        m.verify_bad = true;
                        m.stage = .setup_seed_show;
                        self.seed_input.setValue("") catch {};
                    }
                },
                else => self.seed_input.handleKey(k),
            },
            // Destructive replace: only the exact confirmation word proceeds.
            .setup_replace_confirm => switch (k.key) {
                .escape => self.closeWalletModal(),
                .enter => if (std.mem.eql(u8, self.seed_input.getValue(), replace_confirm_word)) {
                    self.beginWalletReplace();
                } else {
                    m.replace_bad = true;
                },
                else => {
                    m.replace_bad = false;
                    self.seed_input.handleKey(k);
                },
            },
            // Confirm the offline file restore: enter bounces the daemon to swap in
            // the picked backup; esc cancels. The old wallet.dat is kept as a .bak.
            .restore_file_confirm => switch (k.key) {
                .escape => self.closeWalletModal(),
                .enter => self.beginWalletFileRestore(),
                else => {},
            },
            // While the RPC is in flight, ignore input — the reap moves us on.
            .working => {},
            // Any key dismisses the result.
            .result => self.closeWalletModal(),
        }
    }

    /// Per-tick housekeeping for every coin's activity: animate the extract
    /// spinner while extracting, and — once — reap a finished worker and refresh
    /// the cached installed flag from disk.
    fn onTick(self: *App, t: zz.msg.Tick) void {
        // Kick off the one-shot background update check on the first tick —
        // deferred off `init` so a network round-trip never delays startup.
        if (!self.update_started) {
            self.update_started = true;
            self.update_thread = std.Thread.spawn(.{}, runUpdateCheck, .{self}) catch null;
        }
        // Refresh USD prices when due (one request for the whole roster on a
        // slow cadence; a no-op while switched off).
        self.servicePrices(t.timestamp);

        // Announce the download once, the moment the worker commits to it — so
        // "downloading vX" shows up front rather than only when it lands.
        if (self.update_thread != null and !self.update_dl_logged and self.update_downloading.load(.acquire)) {
            self.update_dl_logged = true;
            self.logf("{s}: downloading update v{s}…", .{ home_brand_text, self.update_dl_version.slice() });
        }
        // Reap a finished update check: fold the outcome in and log it once.
        if (self.update_thread != null and self.update_done.load(.acquire)) {
            self.update_thread.?.join();
            self.update_thread = null;
            switch (self.update_status) {
                .staged => {
                    self.update_available = true;
                    if (self.update_blocked)
                        self.logf("{s}: update v{s} downloaded, but BoxWallet's folder isn't writable — move it somewhere writable, then restart", .{ home_brand_text, self.update_version.slice() })
                    else
                        self.logf("{s}: update v{s} downloaded — restart to apply", .{ home_brand_text, self.update_version.slice() });
                },
                .up_to_date => self.logf("{s}: up to date (v{s})", .{ home_brand_text, app_version }),
                // Repeatedly failed to swap this version in, so we've stopped
                // trying it. Say so — silence here would look like "no update".
                .gave_up => self.logf("{s}: update v{s} couldn't be applied after several tries — giving up on it (reinstall to update)", .{ home_brand_text, self.update_version.slice() }),
                // Quiet otherwise: no published binary for this target, or a
                // best-effort network/verify miss that retries next launch.
                .unsupported, .network_error, .verify_failed => {},
            }
        }

        // Refresh the disk-usage figure on a slow ~30s cadence (the bar shows
        // how full the volume holding the blockchains is). The very first sample
        // is taken in `init`, so the bar is already populated here — this just
        // keeps it current. The tick timestamp is elapsed-since-start, so the
        // first refresh lands ~30s into the session.
        if (t.timestamp - self.last_disk_ns >= 30 * std.time.ns_per_s) {
            self.last_disk_ns = t.timestamp;
            self.refreshDisk();
        }

        // Sample memory on a livelier ~3s cadence so the sparkline fills in a
        // minute or two and reflects recent activity. Also seeded in `init`, so
        // it's never empty; the query is a cheap inline read like the disk one.
        if (t.timestamp - self.last_mem_ns >= 3 * std.time.ns_per_s) {
            self.last_mem_ns = t.timestamp;
            self.refreshMemory();
        }

        // Refresh every coin's installed/update state up front and on a slow ~5s
        // cadence, so the left-nav arrows and Home summary reflect *all* coins
        // (the selected one is also kept current by `refreshSelectedInstalled`).
        // Cheap: a stat + small marker read per coin.
        if (!self.update_scan_done or t.timestamp - self.last_update_scan_ns >= 5 * std.time.ns_per_s) {
            self.update_scan_done = true;
            self.last_update_scan_ns = t.timestamp;
            self.scanAllUpdates();
        }

        // All installed coins are polled for live status on a shared ~2s cadence.
        const poll_due = t.timestamp - self.last_poll_ns >= 2 * std.time.ns_per_s;
        for (&self.activities, 0..) |*act, i| {
            if (entries[i] == .home) continue;
            // A foreground daemon that dies on its own — a JVM crash, an OOM
            // kill, an operator `kill` — is never waited on by the start or stop
            // paths, so reap it here. Skipped while a daemon worker is in flight,
            // since that worker owns `daemon_child` (the join before
            // `daemon_thread = null` publishes its writes to us).
            if (act.daemon_thread == null) act.reapDaemonChild();
            const p = act.phaseOf();
            if (p == .extracting) {
                _ = act.spinner.update(t.timestamp);
            }
            const ds = act.daemonState();
            // The daemon spinner animates while a start or stop is in flight,
            // during the brief pre-first-poll window, and while the daemon is up
            // but no peer has connected yet — so Running/Staking/Peers read as
            // "loading" until the first result lands.
            if (ds == .starting or ds == .stopping or act.awaitingStatus() or
                (ds == .running and act.peers == 0))
            {
                // Reverse the puck while the daemon is on its way down, so a stop
                // reads as "unwinding" at a glance; every other loading state
                // orbits clockwise. Assign `frames` directly (not `setFrames`,
                // which resets the index and would freeze the animation).
                act.daemon_spinner.frames = if (ds == .stopping) sync_frames_ccw else sync_frames_cw;
                _ = act.daemon_spinner.update(t.timestamp);
            }
            if ((ds == .running or ds == .stopped) and act.daemon_thread != null) {
                // The worker has settled on a terminal state; reap it. The
                // store/return are back to back, so this never blocks.
                act.daemon_thread.?.join();
                act.daemon_thread = null;
                // The deferred-stop latch is serviced once the stop worker is
                // reaped — clear it so a later poll doesn't re-dispatch
                // beginDaemonStop and bounce the daemon back into "stopping".
                // Covers both outcomes: a successful stop and a failed stop that
                // reverted to running (so a daemon that won't stop isn't retried
                // forever). Safe for the start path too — no stop can be pending
                // while starting.
                act.stop_pending = false;
                switch (act.daemon_action) {
                    .start => if (ds == .running)
                        self.logf("{s}: daemon running", .{act.coin.coinName()})
                    else
                        self.logf("{s}: daemon failed to start ({s})", .{ act.coin.coinName(), act.daemon_err }),
                    .stop => if (ds == .stopped) {
                        // We deliberately stopped it: latch so an automatic poll
                        // can't resurrect it to "running" while the node is still
                        // finishing its shutdown (it'd flash "Waiting for peers…"
                        // and stick there). Cleared on the next explicit start.
                        act.stopped_by_us = true;
                        // Daemon is down — clear the live readings so the pane
                        // doesn't keep showing stale peers/sync from when it ran.
                        act.peers = 0;
                        act.staking = false;
                        act.sync = .idle;
                        act.headers_cur = 0;
                        act.headers_total = 0;
                        act.blocks_cur = 0;
                        act.blocks_total = 0;
                        act.behind_secs = -1;
                        act.wallet = .unknown;
                        act.poll_wallet.store(@intFromEnum(models.WalletSecurity.unknown), .monotonic);
                        act.has_balance = false;
                        act.poll_has_balance.store(0, .monotonic);
                        // Zero the figures so the always-on header balance reads
                        // "Total: 0" for a stopped daemon rather than a stale amount.
                        act.balance_total = 0;
                        act.balance_avail = 0;
                        // Drop the cached transaction list — the daemon's gone.
                        act.tx_count = 0;
                        act.stake_count = 0;
                        act.poll_tx_count = 0;
                        // The miner died with the daemon — clear its readout so
                        // the Mining tab doesn't show a stale hashrate.
                        act.mining_active = false;
                        act.mining_threads = 0;
                        act.mining_speed = 0;
                        act.has_mining = false;
                        act.poll_mining_active.store(0, .monotonic);
                        act.poll_mining_threads.store(0, .monotonic);
                        act.poll_mining_speed.store(0, .monotonic);
                        act.poll_has_mining.store(0, .monotonic);
                        // Drop the cached receive address too — re-fetched fresh
                        // (the stable "current" address) next time the daemon comes
                        // up and polls.
                        act.receive_addr_len = 0;
                        act.poll_receive_addr_len = 0;
                        // Drop the stablecoin caches — the daemon (and the wallet
                        // answering the DD RPCs) is gone with it.
                        act.sc_has_info = false;
                        act.poll_sc_has_info = false;
                        act.sc_has_balance = false;
                        act.poll_sc_has_balance = false;
                        act.sc_tx_count = 0;
                        act.poll_sc_tx_count = 0;
                        act.sc_pos_count = 0;
                        act.poll_sc_pos_count = 0;
                        act.sc_addr_len = 0;
                        act.poll_sc_addr_len = 0;
                        // Drop any stashed send address/result too, for the same reason.
                        act.send_addr_len = 0;
                        act.send_result_len = 0;
                        // Drop any rescan indicator — the wallet's gone with the node.
                        act.rescanning = false;
                        act.poll_rescanning.store(0, .monotonic);
                        act.loading_phase = .none;
                        act.poll_phase.store(@intFromEnum(models.LoadingPhase.none), .monotonic);
                        act.load_stage = .none;
                        act.load_pct_bp = 0;
                        act.stage_len = 0;
                        act.clearLoadProgress();
                        // Forget the running version — the daemon's down.
                        act.version_len = 0;
                        act.poll_version_len = 0;
                        // Keep the retained foreground handle rather than dropping
                        // it. The kill path reaps inline, but an RPC shutdown only
                        // waits for the *port* to close — which the daemon does
                        // early on its way down — so the process is often still
                        // exiting right now. Dropping the handle here would strand
                        // its zombie with nothing left holding the pid; instead
                        // let the tick reap collect it once it's really gone. It
                        // can't be mistaken for a live daemon: the reap nulls the
                        // pid, and the next start reaps and overwrites it anyway.
                        act.reapDaemonChild();
                        self.logf("{s}: daemon stopped", .{act.coin.coinName()});
                    } else self.logf("{s}: daemon failed to stop ({s})", .{ act.coin.coinName(), act.daemon_err }),
                }
            }

            // One-click update, step 2: we asked the daemon to stop before
            // reinstalling. Once it's down (worker reaped above), kick the install;
            // if it wouldn't stop, abort rather than reinstall under a live daemon
            // (Windows can't replace a running binary, and it's the safe choice
            // everywhere). `update_restart` stays set so the daemon comes back up
            // on the new binary when the install finishes.
            if (act.update_await_stop and act.daemon_thread == null and act.daemonState() != .stopping) {
                act.update_await_stop = false;
                if (act.daemonState() == .stopped) {
                    if (self.coinAt(i)) |c| {
                        self.logf("{s}: updating — reinstalling…", .{c.coinName()});
                        self.beginInstall(c, act);
                    }
                } else {
                    act.update_restart = false;
                    if (self.coinAt(i)) |c| self.logf("{s}: update aborted (daemon wouldn't stop)", .{c.coinName()});
                }
            }

            // "Replace wallet", step 2: the daemon was asked to stop. Once it's down
            // (worker reaped above), delete the old wallet and restart so the node
            // forgets its cached secret; pressing `w` then offers create/restore. If
            // it wouldn't stop, abort rather than delete under a live daemon.
            if (act.wallet_replace_await_stop and act.daemon_thread == null and act.daemonState() != .stopping) {
                act.wallet_replace_await_stop = false;
                if (act.daemonState() == .stopped) {
                    if (self.coinAt(i)) |c| {
                        if (c.externalWallet()) |ew| {
                            if (ew.remove) |remove| {
                                if (remove(self.allocator, self.home_dir)) {
                                    act.ext_wallet_exists = false;
                                    self.logf("{s}: previous wallet removed — restarting daemon", .{c.coinName()});
                                } else |err| {
                                    self.logf("{s}: couldn't remove wallet ({s})", .{ c.coinName(), @errorName(err) });
                                }
                            }
                        }
                        // Restart regardless: the user expects the node back up. If
                        // the delete failed, the create/restore menu just won't show.
                        self.beginDaemonStart(c, act);
                    }
                } else {
                    if (self.coinAt(i)) |c| self.logf("{s}: replace aborted (daemon wouldn't stop)", .{c.coinName()});
                }
            }

            // Offline wallet-file restore, step 2: the daemon was asked to stop.
            // Once it's down, swap the picked backup over wallet.dat and restart so
            // the daemon loads it. If it wouldn't stop, abort rather than overwrite a
            // wallet.dat a live daemon still holds open.
            if (act.wallet_restore_await_stop and act.daemon_thread == null and act.daemonState() != .stopping) {
                act.wallet_restore_await_stop = false;
                if (act.daemonState() == .stopped) {
                    if (self.coinAt(i)) |c| {
                        const src = act.wallet_file_buf[0..act.wallet_file_len];
                        const restart = act.wallet_restore_restart;
                        if (c.walletRestoreFileOffline(self.allocator, self.home_dir, src)) {
                            if (restart) {
                                self.logf("{s}: wallet restored — restarting daemon", .{c.coinName()});
                            } else {
                                self.logf("{s}: wallet restored — start the daemon to load it", .{c.coinName()});
                            }
                        } else |err| {
                            self.logf("{s}: wallet restore failed ({s})", .{ c.coinName(), @errorName(err) });
                        }
                        act.wallet_file_len = 0;
                        act.wallet_restore_restart = false;
                        // Restart regardless of the outcome, but only if we were the
                        // ones who stopped it: the user expects their node back the
                        // way it was. On a failed swap the previous wallet.dat (or
                        // its .bak) is intact either way.
                        if (restart) self.beginDaemonStart(c, act);
                    }
                } else {
                    act.wallet_file_len = 0;
                    act.wallet_restore_restart = false;
                    if (self.coinAt(i)) |c| self.logf("{s}: restore aborted (daemon wouldn't stop)", .{c.coinName()});
                }
            }

            // Reap a finished sync-accelerator worker: on success close the prompt
            // and start the daemon (the helper is on disk for `daemonArgv` to
            // pass, or the snapshot is unpacked in the data dir); on failure flip
            // the prompt to its `failed` stage so the user can start without it or
            // cancel. A failed *resumable* download keeps its partial, so the next
            // start offers to continue from where it stopped.
            if (act.qs_thread != null and act.qs_done.load(.acquire)) {
                act.qs_thread.?.join();
                act.qs_thread = null;
                const coin_opt = self.coinAt(i);
                const qs_name = if (coin_opt) |c| blk: {
                    const sa = c.syncAccelerator() orelse break :blk "Sync accelerator";
                    break :blk sa.name;
                } else "Sync accelerator";
                if (act.qs_ok) {
                    self.qs_modal = null;
                    if (coin_opt) |c| {
                        self.logf("{s}: {s} ready — starting daemon", .{ c.coinName(), qs_name });
                        self.beginDaemonStart(c, act);
                    }
                } else if (std.mem.eql(u8, act.qs_err, "Paused")) {
                    // Not a failure: the bytes are on disk and the transfer is
                    // resumable, so the prompt rests rather than erroring.
                    if (self.qs_modal != null and self.qs_modal.?.coin_idx == i)
                        self.qs_modal.?.stage = .paused;
                    if (coin_opt) |c| self.logf("{s}: {s} paused — resumes where it stopped", .{ c.coinName(), qs_name });
                } else {
                    if (self.qs_modal != null and self.qs_modal.?.coin_idx == i)
                        self.qs_modal.?.setMsg(act.qs_err);
                    if (coin_opt) |c| self.logf("{s}: {s} failed ({s})", .{ c.coinName(), qs_name, act.qs_err });
                }
            }

            // Settle a finished send: join the worker, log the outcome, and — if
            // the Send modal is still open for this coin — show the txid or the
            // daemon's own failure reason. Re-poll promptly so the balance and
            // transaction list reflect the send immediately.
            if (act.send_thread != null and act.send_done.load(.acquire)) {
                act.send_thread.?.join();
                act.send_thread = null;
                const ok = act.send_ok;
                const result = act.send_result_buf[0..act.send_result_len];
                if (self.coinAt(i)) |c| {
                    self.logf("{s}: {s}", .{ c.coinName(), if (ok) "sent" else "send failed" });
                }
                if (self.send_modal != null and self.send_modal.?.coin_idx == i) {
                    self.send_modal.?.setMsg(ok, result);
                }
                self.last_poll_ns = 0;
            }

            // Settle a finished mining start/stop: join the worker, log the
            // outcome, and — if the Mining prompt is still open for this coin —
            // show it there too. Re-poll promptly so the tab's status/hashrate
            // reflects the change immediately.
            if (act.mining_thread != null and act.mining_done.load(.acquire)) {
                act.mining_thread.?.join();
                act.mining_thread = null;
                const ok = act.mining_ok;
                if (self.coinAt(i)) |c| {
                    if (ok)
                        self.logf("{s}: mining {s}", .{ c.coinName(), if (act.mining_starting) "started" else "stopped" })
                    else
                        self.logf("{s}: mining {s} failed ({s})", .{ c.coinName(), if (act.mining_starting) "start" else "stop", act.mining_err });
                }
                if (self.mining_modal != null and self.mining_modal.?.coin_idx == i) {
                    if (ok) {
                        // Success needs no lingering box — the tab behind it now
                        // shows the live state.
                        self.mining_modal = null;
                    } else {
                        self.mining_modal.?.setMsg(false, mining.failureText(act.mining_err));
                    }
                }
                self.last_poll_ns = 0;
            }

            // Settle a finished stablecoin op: join the worker and — if the
            // prompt is still open for this coin — advance it. An estimate
            // resolves into the mint confirm (a failed estimate just reads as
            // "figure unavailable"; the daemon computes and enforces the real
            // collateral at mint time regardless). A real op shows the txid or
            // the daemon's own failure reason, and re-polls promptly so the DD
            // balance/positions reflect it immediately.
            if (act.sc_thread != null and act.sc_done.load(.acquire)) {
                act.sc_thread.?.join();
                act.sc_thread = null;
                const ok = act.sc_ok;
                if (self.sc_modal != null and self.sc_modal.?.coin_idx == i) {
                    const m = &self.sc_modal.?;
                    if (m.stage == .estimating) {
                        m.estimate = if (ok) act.sc_estimate else -1;
                        m.sel = 0;
                        m.stage = .confirm;
                    } else if (m.stage == .working) {
                        m.setMsg(ok, act.sc_result_buf[0..act.sc_result_len]);
                    }
                }
                if (act.sc_op != .estimate) {
                    if (self.coinAt(i)) |c| {
                        const what: []const u8 = switch (act.sc_op) {
                            .mint => "mint",
                            .send => "stablecoin send",
                            .redeem => "redeem",
                            .estimate => unreachable,
                        };
                        self.logf("{s}: {s} {s}", .{ c.coinName(), what, if (ok) "succeeded" else "failed" });
                    }
                    self.last_poll_ns = 0;
                }
            }

            // External wallet (Monero-style) process lifecycle: bring it up
            // alongside a running daemon and tear it down once the daemon is gone.
            // Applies to every external-wallet coin (so a wallet service started
            // for one persists if you navigate away, and is reaped when you stop
            // that coin's daemon), while the on-disk "wallet exists?" flag is
            // refreshed only for the coin on screen.
            if (self.coinAt(i)) |xcoin| {
                if (xcoin.hasExternalWallet()) {
                    if (xcoin.hasExternalWalletProcess()) {
                        // Process-backed: bring the wallet service up alongside a
                        // running daemon and reap it once the daemon's gone. The
                        // Monero model (Nerva) spawns it eagerly and password-less;
                        // the Zano model launches it per-open with the password, so
                        // here we only ever tear it down (never eager-spawn), and not
                        // while a setup op is mid-flight (it owns the child handle).
                        if (act.daemonState() == .running) {
                            if (!xcoin.walletLaunchesWithPassword())
                                self.ensureWalletRpc(act, xcoin);
                        } else if (act.wallet_rpc.child != null and act.wallet_setup_thread == null) {
                            self.killWalletRpc(act);
                        }
                    } else if (act.daemonState() != .running and act.ext_wallet_open.load(.monotonic) != 0) {
                        // In-daemon wallet (Ergo): no process to manage, but the
                        // node relocks the wallet when it stops — drop our "open"
                        // flag so balance polling pauses and `w` re-prompts to unlock.
                        act.ext_wallet_open.store(0, .monotonic);
                    }
                    if (i == self.selected) self.refreshExtWalletExists(xcoin, act);
                }
                // Cache the selected coin's prune setting for the Settings tab — a
                // one-shot, cheap conf read, independent of daemon state so it
                // shows even while the daemon is stopped.
                if (i == self.selected) self.refreshPruneState(xcoin, act);
            }

            if (act.sync == .syncing) {
                // Lap the track clockwise when connected, anti-clockwise with no
                // peers. Assign `frames` directly (not `setFrames`, which would
                // reset the index every tick and freeze the animation). Bold so
                // the puck reads as a solid block riding the edge.
                act.sync_spinner.frames = if (act.peers > 0) sync_frames_cw else sync_frames_ccw;
                act.sync_spinner.spinner_style = act.sync_spinner.spinner_style.bold(true);
                _ = act.sync_spinner.update(t.timestamp);
            }

            // Time a NovaCoin-era block-index load (SpiderByte) so the next one can
            // show a rough estimate — that load exposes no in-daemon progress, so
            // "how long it took last time" is the only gauge. Start the clock when
            // the phase first appears (reading the persisted figure then); when it
            // clears with the daemon now answering — a clean finish, not a stop or
            // crash — persist how long it actually took. Both the marker read and
            // write fire once per load (guarded by `load_timer_start_ms`), not each
            // tick.
            if (act.daemonState() == .running and act.loading_phase == .loading_block_index) {
                if (act.load_timer_start_ns == 0) {
                    act.load_timer_start_ns = t.timestamp;
                    act.last_load_ms = install_mod.readLoadMsMarker(self.allocator, act.install_root, act.coin.daemonFile()) orelse 0;
                }
                act.load_eta_pct = loadEtaPercent(act.load_timer_start_ns, t.timestamp, act.last_load_ms);
            } else if (act.load_timer_start_ns != 0) {
                const elapsed_ms = @divTrunc(t.timestamp - act.load_timer_start_ns, std.time.ns_per_ms);
                act.load_timer_start_ns = 0;
                act.load_eta_pct = 0;
                // Persist only a plausibly-complete load: the daemon is answering now
                // (so it really did finish), and the duration is in a sane range. A
                // stop or crash mid-load leaves the daemon not-running and is
                // discarded, so a partial time can't poison the estimate.
                if (act.daemonState() == .running and elapsed_ms > 3_000 and elapsed_ms < 6 * 60 * 60 * 1000) {
                    const ms: u32 = @intCast(elapsed_ms);
                    install_mod.writeLoadMsMarker(self.allocator, act.install_root, act.coin.daemonFile(), ms) catch {};
                    act.last_load_ms = ms;
                }
            }

            // Fold in a finished getinfo poll: take the live peer count and
            // staking flag, and — since a reply proves the daemon is up — mark it
            // running (covers a daemon started outside BoxWallet).
            if (act.poll_thread != null and act.poll_done.load(.acquire)) {
                act.poll_thread.?.join();
                act.poll_thread = null;
                act.poll_completed = true;
                // The warm-up phase is published whether or not the poll reached
                // the daemon, so fold it in regardless of `applyPoll`.
                act.loading_phase = @enumFromInt(act.poll_phase.load(.monotonic));
                act.load_stage = @enumFromInt(act.poll_load_stage.load(.monotonic));
                act.load_pct_bp = act.poll_load_pct_bp.load(.monotonic);
                // ...including the daemon's own wording for that phase, staged in
                // a plain buffer and ordered by the `poll_done` acquire above.
                const sn = @min(act.poll_stage_len, act.stage_buf.len);
                @memcpy(act.stage_buf[0..sn], act.poll_stage_buf[0..sn]);
                act.stage_len = sn;
                // On-disk size is disk-derived (published whether or not the poll
                // reached the daemon), so fold it in here too.
                act.storage_bytes = act.poll_storage_bytes.load(.monotonic);
                act.storage_sampled = act.poll_storage_sampled.load(.monotonic) != 0;
                // Promote to running only when a reply proves the daemon is up and
                // we haven't asked it to stop — see `shouldAdoptRunning` (which also
                // runs `applyPoll` for its fold-in side effect).
                if (act.shouldAdoptRunning())
                    act.daemon.store(@intFromEnum(DaemonState.running), .release);
                // Mark the just-reaped poll as received once per selection; the
                // matching "checking" line was logged when this poll started.
                if (i == self.selected and !act.status_logged) {
                    act.status_logged = true;
                    self.logf("{s}: status received", .{act.coin.coinName()});
                }
                // A stop was requested while this poll was in flight; now that the
                // poll is reaped (no race on `coin`), launch the stop worker. Done
                // before the next-poll-spawn gate below so its `daemon_thread`
                // keeps a fresh poll from starting mid-shutdown.
                if (act.stop_pending and act.daemon_thread == null)
                    self.beginDaemonStop(act);
            }

            // Settle a finished wallet action: clear the secret, update the modal,
            // and log the outcome. A successful encrypt stops the daemon (bitcoin
            // daemons shut down after encrypting), so reflect that.
            if (act.wallet_thread != null and act.wallet_done.load(.acquire)) {
                act.wallet_thread.?.join();
                act.wallet_thread = null;
                const action = act.wallet_action;
                const ok = act.wallet_ok;
                @memset(&act.wallet_pw_buf, 0);
                act.wallet_pw_len = 0;

                if (ok) {
                    if (action == .encrypt) {
                        act.daemon.store(@intFromEnum(DaemonState.stopped), .release);
                        act.wallet = .unknown;
                        act.poll_wallet.store(@intFromEnum(models.WalletSecurity.unknown), .monotonic);
                    }
                    self.logf("{s}: {s} succeeded", .{ act.coin.coinName(), action.label() });
                } else {
                    self.logf("{s}: {s} failed ({s})", .{ act.coin.coinName(), action.label(), act.wallet_err });
                }
                // Re-poll promptly so the Wallet line reflects the change.
                self.last_poll_ns = 0;

                if (self.modal) |*m| {
                    if (m.coin_idx == i and m.stage == .working) {
                        if (ok and action == .backup) {
                            // Show the path so the user can find the backup — never
                            // its contents (it holds private keys).
                            var buf: [200]u8 = undefined;
                            const text = std.fmt.bufPrint(&buf, "Backed up to {s} — keep this file safe; it holds your keys.", .{act.wallet_file_buf[0..act.wallet_file_len]}) catch "Wallet backed up — keep the backup file safe.";
                            m.setMsg(true, text);
                        } else if (ok) {
                            m.setMsg(true, switch (action) {
                                .encrypt => "Wallet encrypted. Restart the daemon (s), then unlock.",
                                .unlock => "Wallet unlocked.",
                                .stake => "Wallet unlocked for staking.",
                                .lock => "Wallet locked.",
                                .restore => "Wallet restored — your balance will appear after it rescans.",
                                // Not RPC-worker actions: backup is handled above;
                                // the offline restore is driven by the tick loop.
                                .backup, .restore_file_offline => unreachable,
                            });
                        } else {
                            var buf: [200]u8 = undefined;
                            const text = std.fmt.bufPrint(&buf, "Failed: {s}", .{act.wallet_err}) catch action.label();
                            m.setMsg(false, text);
                        }
                    }
                }
            }

            // Settle a finished external-wallet setup op (create/restore/open):
            // clear the secrets we copied in, mark the wallet open on success, and
            // advance the modal — to the seed display for a create, or a result
            // line otherwise.
            if (act.wallet_setup_thread != null and act.wallet_setup_done.load(.acquire)) {
                act.wallet_setup_thread.?.join();
                act.wallet_setup_thread = null;
                const op = act.wallet_setup_op;
                const ok = act.wallet_setup_ok;
                @memset(&act.wallet_pw_buf, 0);
                act.wallet_pw_len = 0;
                @memset(&act.wallet_seed_buf, 0);
                act.wallet_seed_len = 0;
                act.wallet_file_len = 0;

                const detail = act.wallet_setup_sink.slice();
                if (ok) {
                    // Lock closes the wallet; every other op leaves it open.
                    act.ext_wallet_open.store(if (op == .lock) 0 else 1, .monotonic);
                    if (op != .lock) act.ext_wallet_exists = true;
                    self.logf("{s}: {s} succeeded", .{ act.coin.coinName(), op.verb() });
                } else if (detail.len > 0) {
                    // The daemon told us why — log its raw message alongside the
                    // mapped error name so the cause isn't lost.
                    self.logf("{s}: {s} failed ({s}: {s})", .{ act.coin.coinName(), op.verb(), act.wallet_setup_err, detail });
                } else {
                    self.logf("{s}: {s} failed ({s})", .{ act.coin.coinName(), op.verb(), act.wallet_setup_err });
                }
                // Re-poll promptly so the balance lines appear.
                self.last_poll_ns = 0;

                if (self.modal) |*m| {
                    if (m.coin_idx == i and m.stage == .working) {
                        if (ok and op == .create) {
                            // Hand the modal its own copy of the seed to display,
                            // then clear the worker's copy.
                            m.seed = act.wallet_setup_seed;
                            m.stage = .setup_seed_show;
                        } else if (ok) {
                            m.setMsg(true, switch (op) {
                                .restore_seed => "Wallet restored — your balance will appear after it rescans.",
                                .restore_file => "Wallet imported — your balance will appear shortly.",
                                .open => "Wallet unlocked.",
                                .lock => "Wallet locked.",
                                .create => unreachable,
                            });
                        } else {
                            m.setMsg(false, extwallet.friendlyWalletError(act.wallet_setup_err, detail));
                        }
                    }
                }
                // Clear the worker's seed copy now the modal holds its own.
                act.wallet_setup_seed = .{};
            }

            // Start the next poll for an installed, idle coin when the cadence is
            // due and none is in flight. Only the selected coin is polled — its
            // dashboard is the only one on screen, so polling a coin we're not
            // viewing buys nothing. Skipped while an install or daemon-start
            // worker is touching this activity, so `coin` isn't written under it.
            if (i == self.selected and poll_due and act.installed and
                act.poll_thread == null and !act.busy() and act.daemon_thread == null and
                act.wallet_thread == null and act.wallet_setup_thread == null)
            {
                if (self.coinAt(i)) |coin| {
                    act.coin = coin;
                    act.has_header_presync = coin.hasHeaderPresync();
                    act.home_dir = self.home_dir;
                    // The poll worker reads the install root (the version marker and
                    // the `--version` probe both live under it). Every other worker
                    // stages it before spawning; polling never did, because until
                    // now nothing on this path needed it — so it was still `""`.
                    act.install_root = self.install_root;
                    act.poll_ok = false;
                    act.poll_alive = false;
                    act.poll_done.store(false, .monotonic);
                    // Consume a pending "New address" request (set by the 'n' key
                    // handler) — only ever written here, at the single pre-spawn
                    // staging point, so there's no race with the poll worker
                    // reading it (no poll is in flight while this runs).
                    act.want_new_receive_address = self.pending_new_receive_address;
                    self.pending_new_receive_address = false;
                    // Same staging rule for a stablecoin "New address" request.
                    act.want_new_sc_address = self.pending_new_sc_address;
                    self.pending_new_sc_address = false;
                    // Announce the first status check for this selection; the
                    // matching "received" line follows when the poll is reaped.
                    if (!act.status_logged)
                        self.logf("{s}: checking status", .{coin.coinName()});
                    act.poll_thread = std.Thread.spawn(.{}, Activity.runPoll, .{act}) catch null;
                }
            }

            if ((p == .done or p == .failed) and !act.acked) {
                act.acked = true;
                if (act.thread) |th| {
                    th.join();
                    act.thread = null;
                }
                act.installed = act.coin.isInstalled(self.allocator, self.install_root);
                act.refreshUpdateState(self.allocator, act.coin, self.install_root);
                const verb: []const u8 = if (act.updating) "update" else "install";
                if (p == .done) {
                    self.logf("{s}: {s} complete", .{ act.coin.coinName(), verb });
                } else {
                    self.logf("{s}: {s} failed ({s})", .{ act.coin.coinName(), verb, act.err_name });
                }

                // One-click update: the reinstall just finished. If the daemon was
                // up when the update began, restart it on the new binary. On a
                // failed reinstall, drop the restart so we don't relaunch a daemon
                // the user expected to be updated.
                if (act.update_restart) {
                    act.update_restart = false;
                    if (p == .done) {
                        if (self.coinAt(i)) |c| self.beginDaemonStart(c, act);
                    }
                }
            }

            // Mirror the selected coin's Status line into the live log, but only
            // when it changes — so each state the coin passes through (Starting →
            // Syncing headers → Syncing blocks → Synced, …) lands once instead of
            // on every ~2s tick. All the state it reads has been folded in above.
            // Restricted to the selected coin: it's the only one polling, so it's
            // the only one whose status moves, and it avoids dumping a line per
            // coin on the first tick. `text` is static, so storing the slice is
            // safe and the compare is a cheap content check.
            if (i == self.selected) {
                if (self.coinAt(i)) |coin| {
                    const status = statusReadout(act).text;
                    if (!std.mem.eql(u8, status, act.last_status)) {
                        act.last_status = status;
                        self.logf("{s}: {s}", .{ coin.coinName(), status });
                    }
                }
            }
        }
        if (poll_due) self.last_poll_ns = t.timestamp;
    }

    /// Sample the disk usage of the volume holding the install root (where the
    /// blockchains grow) into `disk_used`/`disk_total`. `statfs` reads the
    /// filesystem's in-memory block accounting — one cheap syscall, no disk scan
    /// — so it's safe to call synchronously on the UI thread. Probes the install
    /// root, falling back to the home dir before the root exists (its first
    /// install hasn't run yet); both resolve to the same filesystem. A failed or
    /// unsupported query leaves the last figure in place.
    fn refreshDisk(self: *App) void {
        const target = if (self.install_root.len > 0) self.install_root else self.home_dir;
        if (disk.usage(target) orelse disk.usage(self.home_dir)) |u| {
            self.disk_used = u.used;
            self.disk_total = u.total;
        }
    }

    /// Sample system memory usage into `mem_used`/`mem_total`. Like
    /// `refreshDisk`, the read is a single cheap, non-blocking query, so it runs
    /// inline on the UI thread. A failed/unsupported query leaves the last
    /// figures in place.
    fn refreshMemory(self: *App) void {
        if (memory.usage()) |u| {
            self.mem_used = u.used;
            self.mem_total = u.total;
        }
    }

    /// One-shot self-update worker. Runs on its own arena and blocking io, off
    /// the UI thread, since it reaches the network. Asks GitHub for the latest
    /// release and, if newer, downloads + checksum-verifies it and stages it for
    /// next launch. Publishes its outcome through `update_done` (release), which
    /// `onTick` reaps. Memory stays flat — the binary is streamed to disk by the
    /// updater, never buffered here.
    fn runUpdateCheck(self: *App) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var threaded: std.Io.Threaded = .init(a, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const result = updater.checkAndStage(a, io, self.install_root, app_version, .{
            .ctx = self,
            .on_download_start = onUpdateDownloadStart,
        });
        self.update_status = result.status;
        self.update_version = result.version;
        self.update_blocked = result.blocked;
        self.update_done.store(true, .release);
    }

    /// `updater.Notify` hook, called on the update worker thread just before the
    /// new binary is streamed down. Hands the version to the UI thread (publish
    /// the buffer, then flip `update_downloading` with release) so `onTick` can
    /// log "downloading vX" before the download finishes.
    fn onUpdateDownloadStart(ctx: *anyopaque, version: []const u8) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.update_dl_version.set(version);
        self.update_downloading.store(true, .release);
    }

    fn move(self: *App, delta: i32) void {
        const n: i32 = @intCast(entries.len);
        var idx: i32 = @intCast(self.selected);
        idx = @max(0, @min(n - 1, idx + delta));
        const moved = idx != @as(i32, @intCast(self.selected));
        self.selected = @intCast(idx);
        self.refreshSelectedInstalled();
        // Only the selected coin is polled, so a switch should refresh the new
        // coin promptly rather than wait out the shared cadence. Resetting the
        // poll clock makes the next tick due immediately. Clearing the new coin's
        // status-log flag emits a fresh "checking/received" pair for this
        // selection.
        if (moved) {
            self.last_poll_ns = 0;
            self.activities[self.selected].status_logged = false;
            // A different coin's pane always opens on its Home tab.
            self.active_tab = .home;
        }
    }

    /// Append a formatted line to the action log, prefixed with a UTC timestamp.
    /// Formats straight into the ring slot's fixed buffer (no allocation); an
    /// over-long line is truncated to the buffer rather than dropped.
    /// Read the persisted `hide_balances` setting from `boxwallet.conf` under the
    /// install root. Absent file/key (first run) reads as off. Best-effort — a read
    /// error just falls back to off rather than failing startup.
    fn loadHideBalances(self: *App) bool {
        const raw = conf.readValue(self.allocator, self.io, self.install_root, settings_file, "hide_balances") catch return false;
        const val = raw orelse return false;
        defer self.allocator.free(val);
        return std.mem.eql(u8, val, "1") or std.ascii.eqlIgnoreCase(val, "true");
    }

    /// Flip the USD-price display and persist it so it survives a restart.
    /// Bound to `p`. Turning it off stops the background fetch entirely (no
    /// further network requests), and drops the cached quotes so nothing stale
    /// is left behind if it's turned back on. The write is best-effort: if the
    /// conf can't be written the toggle still applies for this session.
    fn togglePrices(self: *App) void {
        self.show_prices = !self.show_prices;
        if (!self.show_prices) {
            for (&self.prices) |*q| q.* = .{};
            self.price_fetched_at = 0;
            self.price_failures = 0;
        } else {
            // Re-enabled: fetch on the next tick rather than waiting out the
            // interval, so a price appears straight away.
            self.price_last_try_ns = 0;
        }
        const value: []const u8 = if (self.show_prices) "1" else "0";
        conf.setValue(self.allocator, self.io, self.install_root, settings_file, "show_prices", value) catch |err| {
            self.logf("USD prices {s} (couldn't save setting: {s})", .{ if (self.show_prices) "on" else "off", @errorName(err) });
            return;
        };
        self.logf("USD prices {s}", .{if (self.show_prices) "on" else "off"});
    }

    /// Read the persisted `show_prices` setting. **Defaults to true** — this is
    /// an opt-*out*, so an absent or unparseable key means on.
    fn loadShowPrices(self: *App) bool {
        const raw = conf.readValue(self.allocator, self.io, self.install_root, settings_file, "show_prices") catch return true;
        const v = raw orelse return true;
        defer self.allocator.free(v);
        const t = std.mem.trim(u8, v, " \t\r\n");
        return !(std.mem.eql(u8, t, "0") or std.ascii.eqlIgnoreCase(t, "false"));
    }

    /// The coin ids to price, written into `ids`/`slots` (parallel), returning
    /// the count. Only coins that declare a `price_id` are included — SpiderByte
    /// isn't listed, so it's simply left out of the request.
    ///
    /// Deliberately **independent of what's installed or selected**: the roster
    /// is fixed, so the outgoing request is byte-identical for every user and
    /// reveals nothing about which coins they hold. Filtering to installed coins
    /// would leak exactly that.
    fn priceRoster(self: *const App, ids: *[entries.len][]const u8, slots: *[entries.len]usize) usize {
        var n: usize = 0;
        for (entries, 0..) |e, i| {
            if (e == .home) continue;
            const c = self.coinAt(i) orelse continue;
            const id = c.priceId() orelse continue;
            ids[n] = id;
            slots[n] = i;
            n += 1;
        }
        return n;
    }

    /// Price-fetch worker. Runs one request for the whole roster on a private
    /// arena and stages the result; the UI reaps it once `price_done` is seen.
    /// Best-effort throughout — a failure just leaves `price_ok` false and the
    /// previous quotes standing until they age out.
    fn runPriceFetch(self: *App) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        for (&self.price_result) |*q| q.* = .{};
        self.price_ok = false;

        var ids: [entries.len][]const u8 = undefined;
        var slots: [entries.len]usize = undefined;
        const n = self.priceRoster(&ids, &slots);

        var threaded: std.Io.Threaded = .init(a, .{});
        defer threaded.deinit();
        const io = threaded.io();

        if (n > 0) {
            var quotes: [entries.len]price.Quote = undefined;
            if (price.fetch(a, io, ids[0..n], quotes[0..n])) {
                // Scatter back into `entries`-indexed slots for the UI.
                for (0..n) |k| self.price_result[slots[k]] = quotes[k];
                self.price_ok = true;
            } else |_| {}
        }

        // Coins the roster host prices badly fetch from their own endpoint
        // (Divi → NonKYC). Unconditional, exactly like the roster above: the
        // request goes out whether or not the coin is installed, so it says
        // nothing about what this user holds. Independently best-effort — one
        // host being down leaves the others' quotes standing.
        for (entries, 0..) |e, i| {
            if (e == .home) continue;
            const c = self.coinAt(i) orelse continue;
            const source = c.priceSource() orelse continue;
            if (price.fetchOne(a, io, source)) |q| {
                self.price_result[i] = q;
                self.price_ok = true;
            } else |_| {}
        }

        self.price_done.store(true, .release);
    }

    /// Kick off a price fetch when one is due (and none is in flight), then reap
    /// a finished one. Called from `onTick`. Silent by design: prices are ambient,
    /// so neither a fetch nor its failure writes to the action log.
    fn servicePrices(self: *App, now_ns: i64) void {
        // Reap first, so a completed fetch is folded in before scheduling next.
        if (self.price_thread != null and self.price_done.load(.acquire)) {
            self.price_thread.?.join();
            self.price_thread = null;
            self.price_done.store(false, .monotonic);
            if (self.price_ok) {
                self.prices = self.price_result;
                self.price_fetched_at = std.Io.Timestamp.now(self.io, .real).toSeconds();
                self.price_failures = 0;
            } else {
                // Saturating, so a long outage can't wrap the backoff back to
                // a fast retry.
                self.price_failures +|= 1;
            }
        }

        if (!self.show_prices or self.price_thread != null) return;

        const due_s = price.backoffSeconds(self.price_failures);
        const first = !self.price_started or self.price_last_try_ns == 0;
        if (!first and now_ns - self.price_last_try_ns < due_s * std.time.ns_per_s) return;

        self.price_started = true;
        self.price_last_try_ns = now_ns;
        self.price_thread = std.Thread.spawn(.{}, runPriceFetch, .{self}) catch null;
    }

    /// The displayable quote for entry `idx`: null when prices are off, none has
    /// been fetched, the coin isn't listed, or the last success is older than
    /// `price.max_age_s` (stale prices are dropped rather than shown as live).
    fn quoteAt(self: *const App, idx: usize) ?price.Quote {
        if (!self.show_prices or self.price_fetched_at == 0) return null;
        const age = std.Io.Timestamp.now(self.io, .real).toSeconds() - self.price_fetched_at;
        if (age > price.max_age_s) return null;
        const q = self.prices[idx];
        return if (q.have) q else null;
    }

    /// Flip the balance-privacy toggle and persist it so it survives a restart.
    /// Bound to `h`. The write is best-effort: if the conf can't be written the
    /// toggle still takes effect for this session, with a note in the log.
    fn toggleHideBalances(self: *App) void {
        self.hide_balances = !self.hide_balances;
        const value: []const u8 = if (self.hide_balances) "1" else "0";
        conf.setValue(self.allocator, self.io, self.install_root, settings_file, "hide_balances", value) catch |err| {
            self.logf("Balances {s} (couldn't save setting: {s})", .{ if (self.hide_balances) "hidden" else "shown", @errorName(err) });
            return;
        };
        self.logf("Balances {s}", .{if (self.hide_balances) "hidden" else "shown"});
    }

    fn logf(self: *App, comptime fmt: []const u8, args: anytype) void {
        const slot = &self.log_lines[self.log_count % log_capacity];
        const n = self.writeTimestamp(&slot.buf);
        if (std.fmt.bufPrint(slot.buf[n..], fmt, args)) |s| {
            slot.len = n + s.len;
        } else |_| {
            slot.len = slot.buf.len;
        }
        self.log_count +%= 1;
    }

    /// Write a "HH:MM:SS  " local-time timestamp into the front of `buf`,
    /// returning the number of bytes written (0 if it somehow doesn't fit). The
    /// wall clock is UTC; `tz_offset_s` shifts it to local time.
    fn writeTimestamp(self: *App, buf: []u8) usize {
        const unix = std.Io.Timestamp.now(self.io, .real).toSeconds() + self.tz_offset_s;
        const secs: u64 = if (unix > 0) @intCast(unix) else 0;
        const ds = (std.time.epoch.EpochSeconds{ .secs = secs }).getDaySeconds();
        const s = std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}  ", .{
            ds.getHoursIntoDay(),
            ds.getMinutesIntoHour(),
            ds.getSecondsIntoMinute(),
        }) catch return 0;
        return s.len;
    }

    /// Resolve the local timezone's UTC offset (in seconds) in effect at `unix`,
    /// read from the system zoneinfo (`/etc/localtime`). Falls back to 0 (UTC)
    /// on any failure — Windows (no zoneinfo file), a missing/unreadable file,
    /// or a malformed TZif. Parses once and retains nothing: the transition
    /// tables are freed before returning, leaving only the resulting `i32`.
    fn localOffsetSeconds(allocator: std.mem.Allocator, io: std.Io, unix: i64) i32 {
        if (@import("builtin").os.tag == .windows) return 0;

        var file = std.Io.Dir.openFileAbsolute(io, "/etc/localtime", .{}) catch return 0;
        defer file.close(io);

        // A modest streaming buffer: the reader refills it from the file as the
        // parser advances, so it needn't hold the whole TZif.
        var buf: [8 * 1024]u8 = undefined;
        var fr = file.reader(io, &buf);
        var tz = std.Tz.parse(allocator, &fr.interface) catch return 0;
        defer tz.deinit();

        // Transitions are sorted ascending by timestamp; the offset in effect at
        // `unix` is the one named by the last transition at or before it. Before
        // the first transition, fall back to the first timetype.
        var offset: i32 = if (tz.timetypes.len > 0) tz.timetypes[0].offset else 0;
        for (tz.transitions) |tr| {
            if (tr.ts > unix) break;
            offset = tr.timetype.offset;
        }
        return offset;
    }

    /// The coin at the current selection, or null on Home.
    ///
    /// Takes `*const App` so the read-only `view`/`renderDetail` path can use it.
    /// The `coin()` builders want a mutable `*Coin`, but the resulting vtable
    /// only ever reads coin metadata here, and the backing `App` is never const
    /// (it lives mutably inside ZigZag's `Program`), so the `@constCast` is sound.
    fn selectedCoin(self: *const App) ?Coin {
        return self.coinAt(self.selected);
    }

    /// The coin backing entry `idx`, or null for Home. The `@constCast` is sound
    /// for the same reason as in `selectedCoin`: the resulting vtable is only
    /// ever used to read coin metadata or drive RPC, and the backing `App` is
    /// never actually const (it lives mutably inside ZigZag's `Program`).
    fn coinAt(self: *const App, idx: usize) ?Coin {
        return switch (entries[idx]) {
            .home => null,
            .nexa => @constCast(&self.nexa).coin(),
            .divi => @constCast(&self.divi).coin(),
            .ergo => @constCast(&self.ergo).coin(),
            .digibyte => @constCast(&self.digibyte).coin(),
            .zano => @constCast(&self.zano).coin(),
            .nerva => @constCast(&self.nerva).coin(),
            .reddcoin => @constCast(&self.reddcoin).coin(),
            .epic => @constCast(&self.epic).coin(),
            .salvium => @constCast(&self.salvium).coin(),
            .monero => @constCast(&self.monero).coin(),
            .litecoin => @constCast(&self.litecoin).coin(),
            .bitcoin => @constCast(&self.bitcoin).coin(),
            .bitcoinz => @constCast(&self.bitcoinz).coin(),
            .spiderbyte => @constCast(&self.spiderbyte).coin(),
        };
    }

    /// The coin a log line's leading `tag` names (the text before the ':', with the
    /// timestamp already stripped), or null for the BoxWallet/Home tag and any
    /// unknown tag. Lets the log pane draw a coin tag in its own branding.
    fn coinForTag(self: *const App, tag: []const u8) ?Coin {
        for (entries[1..], 1..) |e, i|
            if (std.mem.eql(u8, tag, entryLabel(e))) return self.coinAt(i);
        return null;
    }

    /// Refresh the selected coin's cached installed flag from disk. Skipped when
    /// that coin has an active or finished job — its phase already speaks for it,
    /// and we don't want to stomp a fresh result with a stale disk check.
    fn refreshSelectedInstalled(self: *App) void {
        const act = &self.activities[self.selected];
        if (act.phaseOf() != .idle) return;
        if (self.selectedCoin()) |coin| {
            act.installed = coin.isInstalled(self.allocator, self.install_root);
            act.refreshUpdateState(self.allocator, coin, self.install_root);
        }
    }

    /// Refresh `installed` + `update_available` for *every* coin (not just the
    /// selected one), so the left-nav arrows and the Home summary cover all coins.
    /// Coins with an in-flight job are skipped — their phase already speaks for
    /// them and a stale disk check shouldn't stomp a fresh result.
    fn scanAllUpdates(self: *App) void {
        for (entries, 0..) |e, i| {
            if (e == .home) continue;
            const act = &self.activities[i];
            if (act.phaseOf() != .idle) continue;
            if (self.coinAt(i)) |coin| {
                act.installed = coin.isInstalled(self.allocator, self.install_root);
                act.refreshUpdateState(self.allocator, coin, self.install_root);
            }
        }
    }

    /// Kick off a background install/update for the selected coin. Returns
    /// immediately; progress is published into the coin's `Activity` and painted
    /// by `view`. A second press while one is already running for this coin is
    /// ignored, but other coins can be installing concurrently.
    fn tryInstall(self: *App) void {
        const coin = self.selectedCoin() orelse return;
        const act = &self.activities[self.selected];
        // A first-time install is the primary action — do it straight away. But a
        // coin that's *already* installed shouldn't be clobbered by a stray `i`;
        // confirm the reinstall first (it reuses the update prompt + flow).
        if (act.installed) {
            self.openReinstallModal();
            return;
        }
        self.beginInstall(coin, act);
    }

    /// Open the reinstall-confirm prompt for the selected (installed) coin. A
    /// no-op if anything's already in flight for the coin or another modal is
    /// open. On Yes it runs the same stop → install → restart sequence as an
    /// update; on No nothing happens.
    fn openReinstallModal(self: *App) void {
        const act = &self.activities[self.selected];
        if (act.busy()) return;
        if (act.update_await_stop or act.update_restart) return; // already updating
        if (self.modal != null or self.qs_modal != null or self.update_modal != null or self.send_modal != null or self.mining_modal != null or self.sc_modal != null) return;
        // from_len stays 0: the prompt reads "reinstall the bundled version"
        // rather than "X → Y", since this isn't tied to a newer release.
        self.update_modal = .{ .coin_idx = self.selected, .reinstall = true };
    }

    /// Spawn the install/update worker for an explicit coin/activity. Factored out
    /// of `tryInstall` so the one-click update flow can drive it for a coin that may
    /// no longer be the selected one (the user can navigate away mid-update).
    fn beginInstall(self: *App, coin: Coin, act: *Activity) void {
        if (act.busy()) return;

        // Reap a previously finished thread before reusing the slot.
        if (act.thread) |t| {
            t.join();
            act.thread = null;
        }

        act.updating = act.installed;
        act.dl_cur.store(0, .monotonic);
        act.dl_total.store(0, .monotonic);
        act.ex_count.store(0, .monotonic);
        act.err_name = "";
        act.acked = false;
        act.coin = coin;
        act.install_root = self.install_root;
        // The worker needs the home dir too: a coin whose install places support
        // files outside the install root resolves them against it (BitcoinZ's
        // shared Zcash params dir). Left unset, that path would be relative and
        // land in the process's CWD.
        act.home_dir = self.home_dir;
        act.spinner = makeSpinner();
        // Publish the starting phase before the worker exists so the pane shows
        // activity immediately, even before the first download byte arrives.
        act.phase.store(@intFromEnum(Phase.downloading), .release);

        act.thread = std.Thread.spawn(.{}, Activity.run, .{act}) catch |err| {
            act.err_name = @errorName(err);
            act.phase.store(@intFromEnum(Phase.failed), .release);
            return;
        };
        self.logf("{s}: {s}…", .{ coin.coinName(), if (act.updating) "updating" else "installing" });
    }

    /// Open the update-confirm prompt for the selected coin. A no-op unless an
    /// update is actually available, nothing else is in flight for the coin, and no
    /// other modal is open.
    fn tryUpdate(self: *App) void {
        const act = &self.activities[self.selected];
        if (!act.update_available or act.busy()) return;
        if (act.update_await_stop or act.update_restart) return; // already updating
        if (self.modal != null or self.qs_modal != null or self.update_modal != null or self.send_modal != null or self.mining_modal != null or self.sc_modal != null) return;

        var m: UpdateModal = .{ .coin_idx = self.selected };
        const iv = act.installedVersion();
        const n = @min(iv.len, m.from_buf.len);
        @memcpy(m.from_buf[0..n], iv[0..n]);
        m.from_len = n;
        self.update_modal = m;
    }

    /// Handle a keypress while the update prompt is open: walk Yes/No, `enter`/`y`
    /// confirms, `esc`/`n` cancels. Keys are swallowed so nothing reaches the
    /// dashboard.
    fn updateModalKey(self: *App, k: zz.KeyEvent) void {
        if (self.update_modal == null) return;
        const m = &self.update_modal.?;
        switch (k.key) {
            .escape => self.update_modal = null,
            .up => m.sel = 0,
            .down => m.sel = 1,
            .char => |c| switch (c) {
                'k' => m.sel = 0,
                'j' => m.sel = 1,
                'y' => self.confirmUpdate(),
                'n' => self.update_modal = null,
                else => {},
            },
            .enter => if (m.sel == 0) self.confirmUpdate() else {
                self.update_modal = null;
            },
            else => {},
        }
    }

    /// User confirmed: close the prompt and begin the update sequence.
    fn confirmUpdate(self: *App) void {
        const idx = self.update_modal.?.coin_idx;
        self.update_modal = null;
        self.beginUpdate(idx);
    }

    /// Run the one-click update for `coin_idx`. If the daemon is up, stop it first —
    /// the reinstall fires once it's down (in `onTick`), then the daemon restarts on
    /// the new binary. If it's already stopped, reinstall straight away. The confirm
    /// modal locks navigation while open, so `coin_idx` is the selected coin and
    /// `tryStop` (selected-bound) targets the right daemon.
    fn beginUpdate(self: *App, coin_idx: usize) void {
        const act = &self.activities[coin_idx];
        const coin = self.coinAt(coin_idx) orelse return;
        const was_running = act.daemonState() == .running;
        act.update_restart = was_running;
        if (was_running) {
            act.update_await_stop = true;
            self.tryStop();
            self.logf("{s}: updating — stopping daemon…", .{coin.coinName()});
        } else {
            self.beginInstall(coin, act);
        }
    }

    /// Start the selected coin's daemon in the background. Enabled only when the
    /// daemon is installed and currently stopped — otherwise the press is a
    /// no-op (matching the disabled button in the pane). Returns immediately; the
    /// worker flips `daemon` to `.running` once the launcher returns.
    /// `s` toggles the selected coin's daemon: start it when stopped, stop it when
    /// running. Mid-transition (starting/stopping) presses are ignored, mirroring
    /// the dimmed button — the one key always matches the label it shows.
    /// Copy the selected coin's cached receive address to the system
    /// clipboard via OSC 52 (`ctx.setClipboard`). Logs the outcome either way
    /// so pressing `c` always gives visible feedback — including when the
    /// terminal doesn't support/allow OSC 52 clipboard writes, which
    /// `setClipboard` reports as `false` rather than an error.
    fn copyReceiveAddress(self: *App, ctx: *zz.Context) void {
        const coin = self.selectedCoin() orelse return;
        const act = &self.activities[self.selected];
        if (act.receive_addr_len == 0) return;
        const addr = act.receive_addr_buf[0..act.receive_addr_len];
        const copied = ctx.setClipboard(addr) catch false;
        self.logf("{s}: {s}", .{
            coin.coinName(),
            if (copied) "address copied to clipboard" else "clipboard copy not supported by this terminal",
        });
    }

    /// Copy the selected coin's tip/donation address to the system clipboard
    /// via OSC 52 (`ctx.setClipboard`). Logs the outcome either way, mirroring
    /// `copyReceiveAddress`. Reads straight from `coin.tipAddress()` — no
    /// cached-buffer indirection needed since the tip address is a static
    /// per-coin constant, not a live RPC result.
    fn copyTipAddress(self: *App, ctx: *zz.Context) void {
        const coin = self.selectedCoin() orelse return;
        const addr = coin.tipAddress();
        const copied = ctx.setClipboard(addr) catch false;
        self.logf("{s}: {s}", .{
            coin.coinName(),
            if (copied) "tip address copied to clipboard" else "clipboard copy not supported by this terminal",
        });
    }

    /// Request a fresh receive address on the next poll (`getnewaddress`,
    /// which always mints a new key) rather than the stable "current" one
    /// `fetchStatus` otherwise only fetches once. Forces an immediate poll
    /// (`last_poll_ns = 0`, the same trick coin-switching uses, `move` below)
    /// rather than waiting out the shared ~2s cadence, since this is a
    /// deliberate user action expecting prompt feedback.
    fn requestNewReceiveAddress(self: *App) void {
        const act = &self.activities[self.selected];
        if (!act.installed or act.poll_thread != null) return;
        self.pending_new_receive_address = true;
        self.last_poll_ns = 0;
    }

    /// Copy the selected coin's cached stablecoin deposit address to the
    /// clipboard — the stablecoin tab's twin of `copyReceiveAddress`.
    fn copyStablecoinAddress(self: *App, ctx: *zz.Context) void {
        const coin = self.selectedCoin() orelse return;
        const sc = coin.stablecoin() orelse return;
        const act = &self.activities[self.selected];
        if (act.sc_addr_len == 0) return;
        const addr = act.sc_addr_buf[0..act.sc_addr_len];
        const copied = ctx.setClipboard(addr) catch false;
        if (copied)
            self.logf("{s}: {s} address copied to clipboard", .{ coin.coinName(), sc.name })
        else
            self.logf("{s}: clipboard copy not supported by this terminal", .{coin.coinName()});
    }

    /// Request a fresh stablecoin deposit address on the next poll — the
    /// stablecoin tab's twin of `requestNewReceiveAddress`.
    fn requestNewStablecoinAddress(self: *App) void {
        const act = &self.activities[self.selected];
        if (!act.installed or act.poll_thread != null) return;
        self.pending_new_sc_address = true;
        self.last_poll_ns = 0;
    }

    /// Open the stablecoin prompt for the selected coin — a no-op unless the
    /// coin has the capability, its daemon is running, and the feature is
    /// ACTIVE on-chain (the tab explains each of those states in place, so a
    /// dead Enter isn't mysterious). Reachable only via `enter` on the
    /// stablecoin tab, behind the same modal-priority chain as the others.
    fn openStablecoinModal(self: *App) void {
        const coin = self.selectedCoin() orelse return;
        if (!coin.supportsStablecoin()) return;
        const act = &self.activities[self.selected];
        if (act.daemonState() != .running) return;
        if (!act.sc_has_info or !act.sc_info.active) return;
        self.sc_modal = .{ .coin_idx = self.selected };
        self.send_addr_input.setValue("") catch {};
        self.send_amount_input.setValue("") catch {};
        self.send_addr_input.blur();
        self.send_amount_input.blur();
    }

    fn closeStablecoinModal(self: *App) void {
        self.sc_modal = null;
    }

    /// Handle a keypress while the stablecoin prompt is open. The action menu
    /// fans out into the mint (amount → tier → estimate → confirm), send
    /// (address → amount → confirm) and redeem (position → confirm) flows; the
    /// text stages reuse the Send prompt's address/amount inputs (the modal
    /// chain guarantees the two prompts are never open together). `working`/
    /// `estimating` can't be cancelled; `result` closes on any key.
    fn scModalKey(self: *App, k: zz.KeyEvent) void {
        if (self.sc_modal == null) return;
        const m = &self.sc_modal.?;
        switch (m.stage) {
            .menu => switch (k.key) {
                .escape => self.closeStablecoinModal(),
                .up => m.menu_sel -|= 1,
                .down => m.menu_sel = @min(m.menu_sel + 1, 2),
                .char => |c| switch (c) {
                    'k' => m.menu_sel -|= 1,
                    'j' => m.menu_sel = @min(m.menu_sel + 1, 2),
                    else => {},
                },
                .enter => self.scChooseAction(),
                else => {},
            },
            .address => switch (k.key) {
                .escape => self.closeStablecoinModal(),
                .enter => if (self.send_addr_input.getValue().len > 0) {
                    self.send_addr_input.blur();
                    self.send_amount_input.setValue("") catch {};
                    self.send_amount_input.focus();
                    m.stage = .amount;
                },
                else => self.send_addr_input.handleKey(k),
            },
            .amount => switch (k.key) {
                .escape => self.closeStablecoinModal(),
                .enter => self.tryScAmount(),
                // Digits and (one) decimal point only. Typing clears a prior
                // parse error.
                .char => |c| {
                    if (c >= '0' and c <= '9') {
                        m.bad_input = false;
                        self.send_amount_input.handleKey(k);
                    } else if (c == '.' and std.mem.indexOfScalar(u8, self.send_amount_input.getValue(), '.') == null) {
                        m.bad_input = false;
                        self.send_amount_input.handleKey(k);
                    }
                },
                else => self.send_amount_input.handleKey(k),
            },
            .tier => self.scTierKey(k),
            // No cancelling the estimate — it resolves into the confirm.
            .estimating => {},
            .position => self.scPositionKey(k),
            .confirm => switch (k.key) {
                .escape => self.closeStablecoinModal(),
                .up => m.sel = 0,
                .down => m.sel = 1,
                .char => |c| switch (c) {
                    'k' => m.sel = 0,
                    'j' => m.sel = 1,
                    'y' => self.submitScOp(),
                    'n' => self.closeStablecoinModal(),
                    else => {},
                },
                .enter => if (m.sel == 0) self.submitScOp() else self.closeStablecoinModal(),
                else => {},
            },
            // No cancelling an op in flight — let it finish (or fail) and reap.
            .working => {},
            .result => self.closeStablecoinModal(),
        }
    }

    /// The action menu's Enter: set the chosen mode and open its first stage.
    fn scChooseAction(self: *App) void {
        const m = &self.sc_modal.?;
        m.bad_input = false;
        switch (m.menu_sel) {
            0 => {
                m.mode = .mint;
                m.stage = .amount;
                self.send_amount_input.setValue("") catch {};
                self.send_amount_input.focus();
            },
            1 => {
                m.mode = .send;
                m.stage = .address;
                self.send_addr_input.setValue("") catch {};
                self.send_addr_input.focus();
            },
            else => {
                m.mode = .redeem;
                m.stage = .position;
                m.pos_sel = 0;
            },
        }
    }

    /// Keys on the mint flow's tier list: walk the coin's tier table, Enter
    /// kicks the collateral estimate.
    fn scTierKey(self: *App, k: zz.KeyEvent) void {
        const m = &self.sc_modal.?;
        const coin = self.coinAt(m.coin_idx) orelse return;
        const sc = coin.stablecoin() orelse return;
        const last: u8 = @intCast(sc.tiers.len - 1);
        switch (k.key) {
            .escape => self.closeStablecoinModal(),
            .up => m.tier_sel -|= 1,
            .down => m.tier_sel = @min(m.tier_sel + 1, last),
            .char => |c| switch (c) {
                'k' => m.tier_sel -|= 1,
                'j' => m.tier_sel = @min(m.tier_sel + 1, last),
                else => {},
            },
            .enter => self.submitScEstimate(),
            else => {},
        }
    }

    /// Keys on the redeem flow's position picker: walk the redeemable vaults,
    /// Enter locks the chosen one into the modal and advances to the confirm.
    fn scPositionKey(self: *App, k: zz.KeyEvent) void {
        const m = &self.sc_modal.?;
        const act = &self.activities[m.coin_idx];
        const count = redeemableCount(act);
        switch (k.key) {
            .escape => self.closeStablecoinModal(),
            .up => m.pos_sel -|= 1,
            .down => if (count > 0) {
                m.pos_sel = @min(m.pos_sel + 1, @as(u8, @intCast(count - 1)));
            },
            .char => |c| switch (c) {
                'k' => m.pos_sel -|= 1,
                'j' => if (count > 0) {
                    m.pos_sel = @min(m.pos_sel + 1, @as(u8, @intCast(count - 1)));
                },
                else => {},
            },
            .enter => self.scChoosePosition(),
            else => {},
        }
    }

    /// Parse and validate the USD amount, advancing on success. A mint is
    /// checked against the capability's own min/max bounds up front (the
    /// daemon would reject it anyway — failing here saves the round trip); a
    /// send only needs to be positive, with the daemon's live balance check as
    /// the real, always-correct gate.
    fn tryScAmount(self: *App) void {
        const m = &self.sc_modal.?;
        const coin = self.coinAt(m.coin_idx) orelse return;
        const sc = coin.stablecoin() orelse return;
        const cents = parseDollarsToCents(self.send_amount_input.getValue()) orelse {
            m.bad_input = true;
            return;
        };
        if (cents <= 0 or
            (m.mode == .mint and (cents < sc.min_mint_cents or cents > sc.max_mint_cents)))
        {
            m.bad_input = true;
            return;
        }
        m.cents = cents;
        m.bad_input = false;
        self.send_amount_input.blur();
        if (m.mode == .mint) {
            m.tier_sel = 0;
            m.stage = .tier;
        } else {
            m.sel = 0;
            m.stage = .confirm;
        }
    }

    /// The position picker's Enter: copy the chosen vault's handle/amount into
    /// the modal (so a mid-flow poll refresh can't swap the target under the
    /// confirm) and advance.
    fn scChoosePosition(self: *App) void {
        const m = &self.sc_modal.?;
        const act = &self.activities[m.coin_idx];
        const p = redeemablePositionAt(act, m.pos_sel) orelse return;
        const id = p.id();
        const n = @min(id.len, m.pos_id_buf.len);
        @memcpy(m.pos_id_buf[0..n], id[0..n]);
        m.pos_id_len = n;
        m.cents = p.amount_cents;
        m.sel = 0;
        m.stage = .confirm;
    }

    /// Reap any in-flight poll / prior stablecoin worker so a new spawn doesn't
    /// race them on `act.coin`/`home_dir` — mirrors `submitSend`'s reaps.
    fn reapForScSpawn(act: *Activity) void {
        if (act.poll_thread) |t| {
            t.join();
            act.poll_thread = null;
        }
        if (act.sc_thread) |t| {
            t.join();
            act.sc_thread = null;
        }
    }

    /// Tier chosen: kick the collateral-estimate worker so the mint confirm can
    /// spell out roughly how much DGB will be locked. If the worker can't even
    /// spawn, fall through to the confirm without a figure — the estimate is a
    /// courtesy; the daemon computes (and enforces) the real requirement at
    /// mint time.
    fn submitScEstimate(self: *App) void {
        if (self.sc_modal == null) return;
        const m = &self.sc_modal.?;
        const coin = self.coinAt(m.coin_idx) orelse return;
        const act = &self.activities[m.coin_idx];
        reapForScSpawn(act);

        act.coin = coin;
        act.home_dir = self.home_dir;
        act.sc_op = .estimate;
        act.sc_cents = m.cents;
        act.sc_tier = m.tier_sel;
        act.sc_ok = false;
        act.sc_done.store(false, .monotonic);
        act.sc_thread = std.Thread.spawn(.{}, Activity.runStablecoin, .{act}) catch {
            m.estimate = -1;
            m.sel = 0;
            m.stage = .confirm;
            return;
        };
        m.stage = .estimating;
    }

    /// User confirmed: copy the payload onto the target Activity and spawn the
    /// worker. Mirrors `submitSend`'s shape.
    fn submitScOp(self: *App) void {
        if (self.sc_modal == null) return;
        const m = &self.sc_modal.?;
        const coin = self.coinAt(m.coin_idx) orelse return;
        const sc = coin.stablecoin() orelse return;
        const act = &self.activities[m.coin_idx];
        reapForScSpawn(act);

        act.coin = coin;
        act.home_dir = self.home_dir;
        act.sc_cents = m.cents;
        act.sc_tier = m.tier_sel;
        switch (m.mode) {
            .mint => act.sc_op = .mint,
            .send => {
                act.sc_op = .send;
                const addr = self.send_addr_input.getValue();
                const n = @min(addr.len, act.sc_send_addr_buf.len);
                @memcpy(act.sc_send_addr_buf[0..n], addr[0..n]);
                act.sc_send_addr_len = n;
            },
            .redeem => {
                act.sc_op = .redeem;
                const id = m.posId();
                const n = @min(id.len, act.sc_position_buf.len);
                @memcpy(act.sc_position_buf[0..n], id[0..n]);
                act.sc_position_len = n;
            },
        }
        act.sc_ok = false;
        act.sc_done.store(false, .monotonic);
        act.sc_thread = std.Thread.spawn(.{}, Activity.runStablecoin, .{act}) catch {
            m.setMsg(false, "couldn't start the worker");
            return;
        };
        m.stage = .working;
        const verb: []const u8 = switch (m.mode) {
            .mint => "minting",
            .send => "sending",
            .redeem => "redeeming",
        };
        self.logf("{s}: {s} {s}…", .{ coin.coinName(), verb, sc.name });
    }

    fn tryToggleDaemon(self: *App) void {
        const act = &self.activities[self.selected];
        switch (act.daemonState()) {
            .stopped => self.tryStart(),
            .running => self.tryStop(),
            .starting, .stopping => {},
        }
    }

    fn tryStart(self: *App) void {
        const coin = self.selectedCoin() orelse return;
        const act = &self.activities[self.selected];
        if (!act.installed) {
            self.logf("{s}: not installed — press i to install", .{coin.coinName()});
            return;
        }
        if (act.daemonState() != .stopped) return;

        // Reap a previously finished daemon worker before reusing the slot.
        if (act.daemon_thread) |t| {
            t.join();
            act.daemon_thread = null;
        }

        // First-start prune prompt (Bitcoin/Litecoin/Monero): ask how the chain
        // should be stored before the daemon ever runs. Offered only once — once a
        // prune value is in the conf, this is false. The choice writes the conf,
        // then `startAfterPrune` carries on with the rest of the preflight.
        if (coin.offersPrunePrompt(self.allocator, self.home_dir)) {
            self.openPruneModal(coin);
            return;
        }
        self.startAfterPrune(coin, act);
    }

    /// The rest of the daemon-start preflight, after any prune prompt: offer the
    /// coin's sync accelerator (Nerva's QuickSync) before the first synced start —
    /// a yes/no prompt that, on yes, downloads the helper then starts. On a synced
    /// chain — or a coin with no accelerator — start straight away. Factored out so
    /// it can run both directly from `tryStart` and after the prune choice.
    fn startAfterPrune(self: *App, coin: Coin, act: *Activity) void {
        if (coin.offersSyncAccelerator(self.allocator, self.install_root, self.home_dir)) {
            self.openQuickSyncModal(coin);
            return;
        }
        self.beginDaemonStart(coin, act);
    }

    /// Spawn the selected coin's daemon-start worker. The actual launch, factored
    /// out of `tryStart` so it can also run after a QuickSync download completes.
    fn beginDaemonStart(self: *App, coin: Coin, act: *Activity) void {
        act.coin = coin;
        act.install_root = self.install_root;
        act.home_dir = self.home_dir;
        act.environ_map = self.environ_map;
        act.daemon_action = .start;
        act.daemon_spinner = makeSpinner();
        act.daemon_err = "";
        // Release the "we stopped it" latch — an explicit start means a poll may
        // legitimately promote the daemon to running again.
        act.stopped_by_us = false;
        // A freshly (re)started daemon won't have our named wallet loaded (Core
        // only auto-loads the unnamed default), so re-run ensureWallet on the next
        // poll for coins that need it.
        act.wallet_ensured = false;
        // A fresh run reports its own heights from scratch (it may even have been
        // reindexed), so the last run's high-water marks must not floor them.
        act.tip_marks.clear();
        // Re-attempt the external wallet service for this daemon run (e.g. after a
        // reinstall added the wallet-rpc binary).
        act.wallet_rpc.attempted = false;
        // Clean slate for the block-index-load timer — discard any value left
        // dangling by a previous run that ended without a clean finish (e.g. a
        // crash mid-load), so this run times from scratch.
        act.load_timer_start_ns = 0;
        act.load_eta_pct = 0;
        act.daemon.store(@intFromEnum(DaemonState.starting), .release);

        act.daemon_thread = std.Thread.spawn(.{}, Activity.runDaemon, .{act}) catch {
            act.daemon.store(@intFromEnum(DaemonState.stopped), .release);
            return;
        };
        self.logf("{s}: starting daemon…", .{coin.coinName()});
    }

    /// Open the QuickSync prompt for `coin` (its sync accelerator is on offer).
    fn openQuickSyncModal(self: *App, coin: Coin) void {
        const sa = coin.syncAccelerator() orelse return;
        const resume_from = coin.syncAcceleratorPartialBytes(self.allocator, self.install_root, self.home_dir);
        self.qs_modal = .{
            .stage = .confirm,
            .coin_idx = self.selected,
            // Start on the safe answer when this means trusting someone else's
            // chain data and nothing has been downloaded yet — the accelerator is
            // the convenient choice, so it shouldn't also be the effortless one.
            // Not once there's a partial: the user already weighed this, and
            // defaulting a part-finished multi-GB resume to "No" would be
            // obnoxious rather than careful.
            .sel = if (sa.trusts_publisher and resume_from == 0) 1 else 0,
            .name = sa.name,
            .detail = sa.prompt_detail,
            .trust_note = if (sa.trusts_publisher) Coin.accel_trust_note else "",
            .resume_from = resume_from,
            .resumable = sa.resumable,
        };
    }

    /// Handle a keypress while the QuickSync prompt is open. `confirm` walks the
    /// Yes/No choice (enter fires it; esc cancels the start). `downloading`
    /// swallows keys. `failed` lets the user start without the accelerator (enter)
    /// or cancel (esc).
    fn qsModalKey(self: *App, k: zz.KeyEvent) void {
        if (self.qs_modal == null) return;
        const m = &self.qs_modal.?;
        switch (m.stage) {
            .confirm => switch (k.key) {
                .escape => self.qs_modal = null,
                .up => m.sel = 0,
                .down => m.sel = 1,
                .char => |c| switch (c) {
                    'k' => m.sel = 0,
                    'j' => m.sel = 1,
                    'y' => self.startQuickSyncDownload(),
                    'n' => self.declineQuickSync(),
                    else => {},
                },
                .enter => if (m.sel == 0) self.startQuickSyncDownload() else self.declineQuickSync(),
                else => {},
            },
            // A resumable transfer can be paused (`p`/esc): the bytes on disk are
            // kept and picked up later. One that can't resume has nothing to pause
            // into, so its keys are still swallowed — stopping it would only throw
            // the work away.
            .downloading => switch (k.key) {
                .escape => self.pauseQuickSync(),
                .char => |c| if (c == 'p') self.pauseQuickSync(),
                else => {},
            },
            .paused => switch (k.key) {
                .enter => self.startQuickSyncDownload(),
                .escape => self.declineQuickSync(),
                else => {},
            },
            .failed => switch (k.key) {
                .enter => self.declineQuickSync(),
                .escape => self.qs_modal = null,
                else => {},
            },
        }
    }

    /// User accepted QuickSync: kick off the accelerator download on a worker, then
    /// the daemon starts when it finishes (reaped in `onTick`).
    fn startQuickSyncDownload(self: *App) void {
        const m = &self.qs_modal.?;
        const coin = self.coinAt(m.coin_idx) orelse {
            self.qs_modal = null;
            return;
        };
        const act = &self.activities[m.coin_idx];
        // Reap any earlier accelerator worker before reusing the slot.
        if (act.qs_thread) |t| {
            t.join();
            act.qs_thread = null;
        }
        act.coin = coin;
        act.install_root = self.install_root;
        // A snapshot accelerator unpacks into the coin's data dir, so the worker
        // needs the home dir to resolve it.
        act.home_dir = self.home_dir;
        act.dl_cur.store(0, .monotonic);
        act.dl_total.store(0, .monotonic);
        act.qs_phase.store(@intFromEnum(install_mod.Phase.download), .monotonic);
        act.qs_pause.store(false, .monotonic);
        act.qs_ok = false;
        act.qs_err = "";
        act.qs_done.store(false, .release);
        m.stage = .downloading;

        act.qs_thread = std.Thread.spawn(.{}, Activity.runQuicksyncDownload, .{act}) catch {
            m.setMsg("couldn't start the download");
            return;
        };
        self.logf("{s}: downloading {s}…", .{ coin.coinName(), m.name });
    }

    /// User paused a resumable transfer. Only raises the flag — the worker
    /// notices between chunks and unwinds with `error.Paused`, which the reap in
    /// `onTick` turns into the prompt's `paused` stage. Doing it this way means
    /// the partial is always flushed and consistent before we call it stopped.
    fn pauseQuickSync(self: *App) void {
        const m = &self.qs_modal.?;
        if (!m.resumable) return;
        self.activities[m.coin_idx].qs_pause.store(true, .monotonic);
    }

    /// User declined QuickSync (or chose to start anyway after a failure): close the
    /// prompt and start the daemon without the accelerator.
    fn declineQuickSync(self: *App) void {
        const m = &self.qs_modal.?;
        const coin = self.coinAt(m.coin_idx);
        const act = &self.activities[m.coin_idx];
        self.qs_modal = null;
        if (coin) |c| self.beginDaemonStart(c, act);
    }

    /// Open the Send prompt for the selected coin. Resets both inputs and
    /// starts focus on the address field. Reachable only via `enter` on the
    /// Send tab, which is itself gated behind the same modal-priority chain
    /// every other modal-opening key already is (`update`'s `.key` switch),
    /// so no other modal can be open when this runs.
    fn openSendModal(self: *App) void {
        self.send_modal = .{ .coin_idx = self.selected };
        self.send_addr_input.setValue("") catch {};
        self.send_amount_input.setValue("") catch {};
        self.send_addr_input.focus();
        self.send_amount_input.blur();
    }

    /// Open the Stake prompt — the Send modal in `stake` mode. A stake pays the
    /// wallet's own address (the coin supplies it), so the flow skips the
    /// address stage and starts at the amount. No-op for coins without a stake
    /// action.
    fn openStakeModal(self: *App) void {
        const coin = self.selectedCoin() orelse return;
        if (!coin.supportsStakeAction()) return;
        self.send_modal = .{ .coin_idx = self.selected, .mode = .stake, .stage = .amount };
        self.send_addr_input.setValue("") catch {};
        self.send_amount_input.setValue("") catch {};
        self.send_addr_input.blur();
        self.send_amount_input.focus();
    }

    fn closeSendModal(self: *App) void {
        self.send_modal = null;
    }

    /// Handle a keypress while the Send prompt is open. `address` collects
    /// the destination (unrestricted characters — paste included, for free,
    /// via `TextInput.handleKey`'s own `.paste` handling); `amount` collects
    /// a decimal number (digits + one `.`); `confirm` is a plain Yes/No
    /// (mirrors `qsModalKey`'s `.confirm` exactly); `working` can't be
    /// cancelled (matches "no cancelling a download in flight"); `result`
    /// closes on any key (matches the wallet modal's own result stage).
    fn sendModalKey(self: *App, k: zz.KeyEvent) void {
        if (self.send_modal == null) return;
        const m = &self.send_modal.?;
        switch (m.stage) {
            .address => switch (k.key) {
                .escape => self.closeSendModal(),
                .enter => if (self.send_addr_input.getValue().len > 0) {
                    self.send_addr_input.blur();
                    self.send_amount_input.focus();
                    m.stage = .amount;
                },
                else => self.send_addr_input.handleKey(k),
            },
            .amount => switch (k.key) {
                .escape => self.closeSendModal(),
                .enter => self.trySendAmount(),
                // Digits and (one) decimal point only. Typing clears a prior
                // parse error.
                .char => |c| {
                    if (c >= '0' and c <= '9') {
                        m.bad_input = false;
                        self.send_amount_input.handleKey(k);
                    } else if (c == '.' and std.mem.indexOfScalar(u8, self.send_amount_input.getValue(), '.') == null) {
                        m.bad_input = false;
                        self.send_amount_input.handleKey(k);
                    }
                },
                // Backspace/paste/cursor moves edit the field.
                else => self.send_amount_input.handleKey(k),
            },
            .confirm => switch (k.key) {
                .escape => self.closeSendModal(),
                .up => m.sel = 0,
                .down => m.sel = 1,
                .char => |c| switch (c) {
                    'k' => m.sel = 0,
                    'j' => m.sel = 1,
                    'y' => self.submitSend(),
                    'n' => self.closeSendModal(),
                    else => {},
                },
                .enter => if (m.sel == 0) self.submitSend() else self.closeSendModal(),
                else => {},
            },
            // No cancelling a send in flight — let it finish (or fail) and reap.
            .working => {},
            .result => self.closeSendModal(),
        }
    }

    /// Parse and validate the amount field, advancing to `.confirm` on
    /// success. Only checks "is this a valid positive number" — deliberately
    /// *not* "does it exceed the cached balance", since that figure can be
    /// stale in either direction; the daemon's own live check
    /// ("Insufficient funds") is the real, always-correct gate.
    fn trySendAmount(self: *App) void {
        const m = &self.send_modal.?;
        const text = std.mem.trim(u8, self.send_amount_input.getValue(), " \t");
        const amount = std.fmt.parseFloat(f64, text) catch {
            m.bad_input = true;
            return;
        };
        if (amount <= 0) {
            m.bad_input = true;
            return;
        }
        m.bad_input = false;
        m.sel = 0;
        m.stage = .confirm;
    }

    /// User confirmed: copy the address/amount into the target Activity and
    /// spawn the send worker. Mirrors `submitWalletAction`/
    /// `startQuickSyncDownload`'s shape.
    fn submitSend(self: *App) void {
        if (self.send_modal == null) return;
        const m = &self.send_modal.?;
        const coin = self.coinAt(m.coin_idx) orelse return;
        const act = &self.activities[m.coin_idx];

        // Reap any in-flight poll / prior send worker so this one doesn't race
        // them on `act.coin`/`home_dir`.
        if (act.poll_thread) |t| {
            t.join();
            act.poll_thread = null;
        }
        if (act.send_thread) |t| {
            t.join();
            act.send_thread = null;
        }

        const addr = self.send_addr_input.getValue();
        const n = @min(addr.len, act.send_addr_buf.len);
        @memcpy(act.send_addr_buf[0..n], addr[0..n]);
        act.send_addr_len = n;

        const amount_text = std.mem.trim(u8, self.send_amount_input.getValue(), " \t");
        act.send_amount = std.fmt.parseFloat(f64, amount_text) catch 0;
        // Stake mode: no destination was collected (the coin pays the wallet's
        // own address itself) — the flag routes the worker to `walletStake`.
        act.send_is_stake = m.mode == .stake;

        act.coin = coin;
        act.home_dir = self.home_dir;
        act.send_ok = false;
        act.send_done.store(false, .monotonic);

        act.send_thread = std.Thread.spawn(.{}, Activity.runSend, .{act}) catch {
            m.setMsg(false, "couldn't start the send worker");
            return;
        };
        m.stage = .working;
        self.logf("{s}: {s}…", .{ coin.coinName(), if (m.mode == .stake) "staking" else "sending" });
    }

    /// Open the Mining prompt for the selected coin — thread-count entry when
    /// the miner is idle, a stop confirm when it's running. A no-op for coins
    /// without mining, while the daemon isn't running, or (for a start) before
    /// the wallet's payout address is cached — the Mining tab explains each of
    /// those states in place, so a dead Enter isn't mysterious. Reachable only
    /// via `enter` on the Mining tab, which sits behind the same
    /// modal-priority chain every other modal-opening key does.
    fn openMiningModal(self: *App) void {
        const coin = self.selectedCoin() orelse return;
        if (!coin.supportsMining()) return;
        const act = &self.activities[self.selected];
        if (act.daemonState() != .running) return;
        if (act.mining_active) {
            self.mining_modal = .{ .coin_idx = self.selected, .stage = .confirm_stop, .starting = false };
            return;
        }
        // A start pays block rewards to the wallet's own receive address,
        // cached once the wallet has been opened this session.
        if (act.receive_addr_len == 0) return;
        self.mining_modal = .{ .coin_idx = self.selected, .stage = .threads, .starting = true };
        self.mining_input.setValue("") catch {};
        self.mining_input.focus();
    }

    fn closeMiningModal(self: *App) void {
        self.mining_modal = null;
    }

    /// Handle a keypress while the Mining prompt is open. `threads` collects
    /// a small integer (digits only); `confirm_stop` is a plain Yes/No
    /// (mirrors the Send prompt's `.confirm`); `working` can't be cancelled;
    /// `result` closes on any key.
    fn miningModalKey(self: *App, k: zz.KeyEvent) void {
        if (self.mining_modal == null) return;
        const m = &self.mining_modal.?;
        switch (m.stage) {
            .threads => switch (k.key) {
                .escape => self.closeMiningModal(),
                .enter => self.tryMiningThreads(),
                // Digits only. Typing clears a prior parse error.
                .char => |c| if (c >= '0' and c <= '9') {
                    m.bad_input = false;
                    self.mining_input.handleKey(k);
                },
                // Backspace/paste/cursor moves edit the field.
                else => self.mining_input.handleKey(k),
            },
            .confirm_stop => switch (k.key) {
                .escape => self.closeMiningModal(),
                .up => m.sel = 0,
                .down => m.sel = 1,
                .char => |c| switch (c) {
                    'k' => m.sel = 0,
                    'j' => m.sel = 1,
                    'y' => self.submitMining(0),
                    'n' => self.closeMiningModal(),
                    else => {},
                },
                .enter => if (m.sel == 0) self.submitMining(0) else self.closeMiningModal(),
                else => {},
            },
            // No cancelling an op in flight — let it finish (or fail) and reap.
            .working => {},
            .result => self.closeMiningModal(),
        }
    }

    /// Parse and validate the thread-count field: an integer from 1 to the
    /// machine's own CPU thread count. More threads than the machine has only
    /// adds scheduler thrash for no hashrate, so it's rejected with the range
    /// shown rather than clamped silently.
    fn tryMiningThreads(self: *App) void {
        const m = &self.mining_modal.?;
        const threads = mining.parseThreads(self.mining_input.getValue()) orelse {
            m.bad_input = true;
            return;
        };
        m.bad_input = false;
        self.submitMining(threads);
    }

    /// User committed: copy the payout address/thread count into the target
    /// Activity and spawn the mining worker. Mirrors `submitSend`'s shape.
    /// `threads` is ignored for a stop (`m.starting` false).
    fn submitMining(self: *App, threads: u32) void {
        if (self.mining_modal == null) return;
        const m = &self.mining_modal.?;
        const coin = self.coinAt(m.coin_idx) orelse return;
        const act = &self.activities[m.coin_idx];

        // Reap any in-flight poll / prior mining worker so this one doesn't
        // race them on `act.coin`/`home_dir`.
        if (act.poll_thread) |t| {
            t.join();
            act.poll_thread = null;
        }
        if (act.mining_thread) |t| {
            t.join();
            act.mining_thread = null;
        }

        // A start pays the wallet's cached receive address — copied out of the
        // poll-rewritten cache into the worker's own stable buffer.
        const addr = act.receive_addr_buf[0..act.receive_addr_len];
        const n = @min(addr.len, act.mining_addr_buf.len);
        @memcpy(act.mining_addr_buf[0..n], addr[0..n]);
        act.mining_addr_len = n;
        act.mining_threads_req = threads;
        act.mining_starting = m.starting;

        act.coin = coin;
        act.home_dir = self.home_dir;
        act.mining_ok = false;
        act.mining_done.store(false, .monotonic);

        act.mining_thread = std.Thread.spawn(.{}, Activity.runMining, .{act}) catch {
            m.setMsg(false, "couldn't start the mining worker");
            return;
        };
        m.stage = .working;
        self.logf("{s}: {s}…", .{ coin.coinName(), if (m.starting) "starting miner" else "stopping miner" });
    }

    /// Open the first-start prune prompt for `coin`, with that coin's own menu.
    /// Resets the cursor to row 0 — by convention the choice that discards nothing
    /// (full node) — and clears the custom field.
    fn openPruneModal(self: *App, coin: Coin) void {
        const pr = coin.pruning() orelse return;
        self.prune_modal = .{
            .coin_idx = self.selected,
            .sel = 0,
            .presets = pr.presets,
            .allow_custom = pr.mode == .size_mib,
        };
        self.prune_input.setValue("") catch {};
    }

    /// Handle a keypress while the prune prompt is open. `menu` walks the presets +
    /// "Custom…" (enter fires the choice or opens the custom field; esc cancels the
    /// start). `custom` collects a GB number (enter applies; esc returns to the
    /// menu; digits edit the field).
    fn pruneModalKey(self: *App, k: zz.KeyEvent) void {
        if (self.prune_modal == null) return;
        const m = &self.prune_modal.?;
        switch (m.stage) {
            .menu => switch (k.key) {
                .escape => self.prune_modal = null,
                .up => if (m.sel > 0) {
                    m.sel -= 1;
                },
                .down => if (m.sel < m.lastRow()) {
                    m.sel += 1;
                },
                .enter => self.choosePrune(),
                .char => |c| switch (c) {
                    'k' => if (m.sel > 0) {
                        m.sel -= 1;
                    },
                    'j' => if (m.sel < m.lastRow()) {
                        m.sel += 1;
                    },
                    else => {},
                },
                else => {},
            },
            .custom => switch (k.key) {
                // esc backs out to the menu rather than cancelling the whole start.
                .escape => {
                    m.stage = .menu;
                    m.bad_input = false;
                },
                .enter => self.applyCustomPrune(),
                // Digits only — a GB count. Typing clears a prior parse error.
                .char => |c| if (c >= '0' and c <= '9') {
                    m.bad_input = false;
                    self.prune_input.handleKey(k);
                },
                // Backspace/paste/cursor moves edit the field.
                else => self.prune_input.handleKey(k),
            },
        }
    }

    /// Act on the highlighted menu row: a preset applies its target straight away;
    /// the trailing "Custom…" row opens the GB entry field.
    fn choosePrune(self: *App) void {
        const m = &self.prune_modal.?;
        if (m.allow_custom and m.sel == m.customRow()) {
            m.stage = .custom;
            m.bad_input = false;
            self.prune_input.setValue("") catch {};
            self.prune_input.focus();
            return;
        }
        self.applyPruneAndStart(m.presets[m.sel].value);
    }

    /// Parse the custom GB entry and apply it. A blank or unparseable value (or 0,
    /// which is the "No pruning" preset's job) flags the field and waits.
    fn applyCustomPrune(self: *App) void {
        const m = &self.prune_modal.?;
        const text = std.mem.trim(u8, self.prune_input.getValue(), " \t");
        const gb = std.fmt.parseInt(i64, text, 10) catch {
            m.bad_input = true;
            return;
        };
        if (gb <= 0) {
            m.bad_input = true;
            return;
        }
        self.applyPruneAndStart(gb * 1000);
    }

    /// Persist the chosen prune value to the coin's conf, then carry on with the
    /// daemon start. Writing the conf is a tiny synchronous op (like the wallet
    /// flows); a failure is logged and the start proceeds (the daemon just runs
    /// unpruned, and the prompt re-offers next time). Caches the value on the
    /// Activity so the Settings tab reflects it immediately.
    fn applyPruneAndStart(self: *App, prune_value: i64) void {
        const m = &self.prune_modal.?;
        const idx = m.coin_idx;
        const coin = self.coinAt(idx) orelse {
            self.prune_modal = null;
            return;
        };
        const act = &self.activities[idx];
        const mode = if (coin.pruning()) |pr| pr.mode else .size_mib;
        self.prune_modal = null;

        if (coin.applyPrune(self.allocator, self.home_dir, prune_value)) {
            act.prune_mib = prune_value;
            act.prune_read = true;
            if (prune_value == 0)
                self.logf("{s}: pruning disabled (full node)", .{coin.coinName()})
            else switch (mode) {
                .size_mib => self.logf("{s}: pruning to {d} MiB", .{ coin.coinName(), prune_value }),
                .on_off => self.logf("{s}: blockchain pruning enabled", .{coin.coinName()}),
            }
        } else |err| {
            self.logf("{s}: couldn't write prune setting ({s}) — starting unpruned", .{ coin.coinName(), @errorName(err) });
        }
        self.startAfterPrune(coin, act);
    }

    /// Stop the selected coin's running daemon in the background (via the JSON-RPC
    /// `stop`). Enabled only when installed and currently running — otherwise the
    /// press is a no-op (matching the disabled button in the pane). Returns
    /// immediately; the worker flips `daemon` to `.stopped` once it's down.
    fn tryStop(self: *App) void {
        const coin = self.selectedCoin() orelse return;
        const act = &self.activities[self.selected];
        if (!act.installed) return;
        if (act.daemonState() != .running) return;

        act.coin = coin;
        act.home_dir = self.home_dir;
        act.daemon_spinner = makeSpinner();
        // Show "stopping" immediately so the press registers, even if we have to
        // wait for an in-flight poll to be reaped before the worker can start.
        act.daemon.store(@intFromEnum(DaemonState.stopping), .release);

        // A status poll for this coin may be in flight (only the selected coin is
        // polled). Reaping it on the UI thread would block the event loop — its
        // RPC has no timeout, so against a busy/shutting-down daemon it can stall
        // for seconds and freeze the whole UI. Defer the stop instead: `onTick`
        // reaps the poll asynchronously and then spawns the worker (which still
        // mustn't race the poll on `coin`).
        if (act.poll_thread != null) {
            act.stop_pending = true;
            return;
        }
        self.beginDaemonStop(act);
    }

    /// Spawn the daemon-stop worker. Assumes `coin`/`home_dir` are already set and
    /// no status poll is in flight (so it can't race the poll on `coin`). Called
    /// straight from `tryStop` when no poll is outstanding, or from `onTick` once
    /// a deferred poll has been reaped.
    fn beginDaemonStop(self: *App, act: *Activity) void {
        act.daemon_action = .stop;
        act.daemon_err = "";
        act.tip_marks.clear();
        act.daemon.store(@intFromEnum(DaemonState.stopping), .release);
        act.daemon_thread = std.Thread.spawn(.{}, Activity.runStopDaemon, .{act}) catch {
            act.daemon.store(@intFromEnum(DaemonState.running), .release);
            act.stop_pending = false;
            return;
        };
        self.logf("{s}: stopping daemon…", .{act.coin.coinName()});
    }

    /// Spawn the coin's external wallet process (`nerva-wallet-rpc`) alongside its
    /// running daemon, if it isn't up already, and report the outcome in the action
    /// log. The spawn itself lives in `extwallet.ensure` (the GUI drives the same
    /// one); this wraps it in the TUI's voice. Best-effort — a spawn failure just
    /// leaves the wallet unavailable until the daemon is restarted.
    fn ensureWalletRpc(self: *App, act: *Activity, coin: Coin) void {
        // The spawn itself is shared with the GUI; only the wording is ours.
        switch (extwallet.ensure(&act.wallet_rpc, coin, self.install_root, self.home_dir, self.environ_map)) {
            .not_applicable, .already_running, .already_attempted => {},
            .started => self.logf("{s}: wallet service started", .{coin.coinName()}),
            .port_busy => self.logf("{s}: a wallet service is already using port {s} — close any other BoxWallet using this coin", .{ coin.coinName(), coin.externalWallet().?.rpc_port.?() }),
            .argv_failed => |err| self.logf("{s}: couldn't build the wallet service command ({s})", .{ coin.coinName(), @errorName(err) }),
            // Most likely the wallet-rpc binary isn't on disk (an install from
            // before it was bundled) — tell the user how to fix it, once.
            .spawn_failed => |err| self.logf("{s}: wallet service failed to start ({s}) — press i to reinstall and add the wallet service", .{ coin.coinName(), @errorName(err) }),
        }
    }

    /// Kill the coin's external wallet process and mark its wallet closed.
    /// Idempotent.
    fn killWalletRpc(self: *App, act: *Activity) void {
        _ = self;
        act.ext_wallet_open.store(0, .monotonic);
        extwallet.kill(&act.wallet_rpc);
    }

    /// Refresh whether the coin's external wallet file exists on disk (drives the
    /// pane hint and which `w` flow opens). A cheap stat; no-op for non-external
    /// coins.
    fn refreshExtWalletExists(self: *App, coin: Coin, act: *Activity) void {
        if (!coin.hasExternalWallet()) return;
        const ew = coin.externalWallet().?;
        act.ext_wallet_exists = ew.exists(self.allocator, self.home_dir);
    }

    /// Cache the coin's configured prune target for the Settings tab — a cheap conf
    /// read done once per selection (latched by `prune_read`), so the render path
    /// never touches disk. No-op for coins without the pruning capability. Runs on
    /// the UI thread, like `refreshExtWalletExists`. `prune_mib` is left -1 when the
    /// conf carries no `prune` value yet (the prompt hasn't been answered).
    fn refreshPruneState(self: *App, coin: Coin, act: *Activity) void {
        if (act.prune_read or coin.pruning() == null) return;
        act.prune_mib = (coin.pruningState(self.allocator, self.home_dir) catch null) orelse -1;
        act.prune_read = true;
    }

    /// `w` for an external-wallet coin (Monero-style process or Ergo-style
    /// in-daemon): open the setup menu when no wallet exists yet, the unlock prompt
    /// when one exists but isn't open this session, or (for a coin that supports it)
    /// the lock action when it's already open. Requires the daemon and, for a
    /// process-backed coin, the wallet service to be up.
    fn openExternalWalletModal(self: *App, coin: Coin, act: *Activity) void {
        if (!act.installed or act.daemonState() != .running) {
            self.logf("{s}: start the daemon first to set up the wallet", .{coin.coinName()});
            return;
        }
        // Process-backed coins also need their wallet service up; in-daemon coins
        // are ready as soon as the daemon is (checked above). Launch-with-password
        // coins (Zano) have no service until a wallet is opened — the setup op
        // launches it — so they're exempt from this gate.
        if (coin.hasExternalWalletProcess() and !coin.walletLaunchesWithPassword() and act.wallet_rpc.child == null) {
            if (act.wallet_rpc.attempted)
                self.logf("{s}: wallet service didn't start — press i to reinstall (adds the wallet service), then restart the daemon", .{coin.coinName()})
            else
                self.logf("{s}: wallet service still starting — try again in a moment", .{coin.coinName()});
            return;
        }
        const ew = coin.externalWallet().?;
        var m: Modal = .{ .coin_idx = self.selected };
        if (!act.ext_wallet_exists) {
            m.stage = .setup_menu;
            m.setup_sel = 0;
            m.setup_option_count = menuChoicesFor(coin, &m.setup_options);
        } else if (act.ext_wallet_open.load(.monotonic) == 0) {
            // A wallet exists but isn't open this session. With no replace option
            // it's a straight unlock (quickest path); with one, show a menu so the
            // user can choose unlock vs. replacing it with a different seed.
            if (!coin.supportsWalletReplace()) {
                m.stage = .setup_password;
                m.setup_op = .open;
            } else {
                m.stage = .setup_menu;
                m.setup_sel = 0;
                m.setup_options[0] = .unlock;
                m.setup_options[1] = .replace;
                m.setup_option_count = 2;
            }
        } else {
            // Already open: offer lock and/or replace; nothing to do if neither.
            var n: usize = 0;
            if (ew.lock != null) {
                m.setup_options[n] = .lock;
                n += 1;
            }
            if (coin.supportsWalletReplace()) {
                m.setup_options[n] = .replace;
                n += 1;
            }
            if (n == 0) {
                self.logf("{s}: wallet already unlocked", .{coin.coinName()});
                return;
            }
            m.stage = .setup_menu;
            m.setup_sel = 0;
            m.setup_option_count = n;
        }
        self.pw_input.setValue("") catch {};
        self.seed_input.setValue("") catch {};
        self.modal = m;
    }

    /// Begin a confirmed "Replace wallet", clearing the old wallet so the normal
    /// create/restore menu becomes available again. Called only after the user typed
    /// the confirmation word.
    ///
    /// Two shapes, depending on where the wallet lives:
    ///   * **External wallet process** (Epic/Zano/Nerva — `hasExternalWalletProcess`):
    ///     the *node* doesn't hold the wallet, so the daemon is left running. Bouncing
    ///     it here would needlessly reset the node's sync and drop its peers (the bug
    ///     this avoids). We just kill the wallet process and delete its artifacts.
    ///   * **In-daemon wallet** (Ergo): the node *does* hold the wallet (and caches its
    ///     secret), so we stop the daemon, delete the wallet once it's down, then
    ///     restart — the stop→act→restart sequence driven from the tick reap loop.
    fn beginWalletReplace(self: *App) void {
        const m = self.modal orelse return;
        const act = &self.activities[m.coin_idx];
        const coin = self.coinAt(m.coin_idx) orelse return;
        self.closeWalletModal();
        act.coin = coin;
        act.home_dir = self.home_dir;
        act.install_root = self.install_root;

        if (coin.hasExternalWalletProcess()) {
            // Tear down the separate wallet process (frees the wallet files), then
            // delete the wallet — leaving the daemon (and its sync) untouched.
            self.killWalletRpc(act);
            if (coin.externalWallet()) |ew| if (ew.remove) |remove| {
                if (remove(self.allocator, self.home_dir)) {
                    self.logf("{s}: previous wallet removed", .{coin.coinName()});
                } else |err| {
                    self.logf("{s}: couldn't remove wallet ({s})", .{ coin.coinName(), @errorName(err) });
                }
            };
            act.ext_wallet_exists = false;
            return;
        }

        act.wallet_replace_await_stop = true;
        self.logf("{s}: replacing wallet — stopping daemon…", .{coin.coinName()});
        self.tryStop();
    }

    /// Begin a confirmed offline wallet-file restore: the picked backup path is
    /// already in the activity's `wallet_file_buf`. The daemon holds `wallet.dat`
    /// open while running, so we stop it, and once it's down the tick reap loop
    /// swaps the file in and restarts (mirrors `beginWalletReplace`'s stop→act→
    /// restart, but replacing the wallet file rather than deleting it).
    fn beginWalletFileRestore(self: *App) void {
        const m = self.modal orelse return;
        const act = &self.activities[m.coin_idx];
        const coin = self.coinAt(m.coin_idx) orelse return;
        self.closeWalletModal();
        act.coin = coin;
        act.home_dir = self.home_dir;
        act.install_root = self.install_root;

        act.wallet_restore_await_stop = true;
        // Only bounce a daemon that's actually up. With it already down there's
        // nothing to stop and nothing to restart — the swap just happens on the
        // next tick, and the node stays as the user left it.
        if (act.daemonState() == .running) {
            act.wallet_restore_restart = true;
            self.logf("{s}: restoring wallet — stopping daemon…", .{coin.coinName()});
            self.tryStop();
        } else {
            act.wallet_restore_restart = false;
            self.logf("{s}: restoring wallet…", .{coin.coinName()});
        }
    }

    /// Point the file picker at a start directory and focus it, for the
    /// restore-from-file flow. Re-opens the directory the last restore browsed to
    /// (remembered in-session) if one is set and still navigable, otherwise the
    /// user's home dir, otherwise the cwd.
    fn startFilePicker(self: *App) void {
        self.file_picker.focus();
        if (self.last_file_dir_len > 0) {
            if (self.file_picker.navigate(self.io, self.last_file_dir_buf[0..self.last_file_dir_len])) |_| {
                return;
            } else |_| {
                // The remembered dir is gone (unmounted/deleted) — fall through to
                // home, and drop it so we don't keep retrying a dead path.
                self.last_file_dir_len = 0;
            }
        }
        self.file_picker.navigateHome(self.io, self.environ_map) catch {
            self.file_picker.navigate(self.io, ".") catch {};
        };
    }

    /// Remember the directory a picked restore file lives in, so the next
    /// restore-from-file re-opens there. In-memory only; silently skipped if the
    /// path has no directory component or is too long for the buffer.
    fn rememberFileDir(self: *App, file_path: []const u8) void {
        const dir = std.fs.path.dirname(file_path) orelse return;
        if (dir.len == 0 or dir.len > self.last_file_dir_buf.len) return;
        @memcpy(self.last_file_dir_buf[0..dir.len], dir);
        self.last_file_dir_len = dir.len;
    }

    /// Open the `w` wallet menu for the selected coin. Gated: the coin must
    /// expose a manageable wallet, be installed, and have a wallet state offering
    /// at least one action. When it can't open, the reason is logged rather than
    /// popping an empty modal.
    ///
    /// A *running* daemon is deliberately not required. Almost every action needs
    /// one, and with the daemon down the wallet state reads `.unknown`, for which
    /// the menu holds only the offline `wallet.dat` restore — the one action that
    /// requires the daemon **stopped**. Demanding a running daemon here refused it
    /// exactly when it was usable.
    fn openWalletModal(self: *App) void {
        const coin = self.selectedCoin() orelse return;
        const act = &self.activities[self.selected];
        // Monero-style coins manage an external wallet process instead of the
        // in-daemon wallet hooks — route to its create/restore/unlock flow.
        if (coin.hasExternalWallet()) return self.openExternalWalletModal(coin, act);
        if (!coin.supportsWallet()) {
            self.logf("{s}: wallet management isn't supported", .{coin.coinName()});
            return;
        }
        if (!act.installed) {
            self.logf("{s}: install the coin first to manage the wallet", .{coin.coinName()});
            return;
        }
        var opts: [walletmenu.max_options]WalletAction = undefined;
        const n = walletmenu.optionsFor(act.wallet, .of(coin), &opts);
        if (n == 0) {
            // Nothing this state permits: either the daemon hasn't reported the
            // wallet yet, or it's down and this coin has no offline restore.
            self.logf("{s}: wallet state not known yet — start the daemon, or try again in a moment", .{coin.coinName()});
            return;
        }

        var m: Modal = .{ .coin_idx = self.selected };
        m.options = opts;
        m.option_count = n;
        self.pw_input.setValue("") catch {};
        self.modal = m;
    }

    /// Dismiss the wallet modal, clearing the passphrase and seed input fields.
    fn closeWalletModal(self: *App) void {
        self.pw_input.setValue("") catch {};
        self.seed_input.setValue("") catch {};
        if (self.modal) |*m| {
            @memset(&m.pw_first_buf, 0);
            m.pw_first_len = 0;
            m.pw_mismatch = false;
        }
        self.file_picker.blur();
        self.modal = null;
    }

    /// Fire the chosen wallet action on a worker thread. Copies the passphrase
    /// into the activity's bounded buffer (clearing the input field), then spawns
    /// `runWalletAction`; the modal advances to `working` and the reap in `onTick`
    /// settles it to `result`.
    fn submitWalletAction(self: *App) void {
        if (self.modal == null) return;
        const m = &self.modal.?;
        const coin = self.coinAt(m.coin_idx) orelse return;
        const act = &self.activities[m.coin_idx];

        // Reap any in-flight poll / prior wallet worker so this one doesn't race
        // them on `act.coin`/`home_dir`.
        if (act.poll_thread) |t| {
            t.join();
            act.poll_thread = null;
        }
        if (act.wallet_thread) |t| {
            t.join();
            act.wallet_thread = null;
        }

        // Copy the passphrase into the worker's buffer, then clear the field so
        // the secret isn't held in two places. (Empty for the passwordless
        // backup/restore actions — harmless.)
        const pw = self.pw_input.getValue();
        const n = @min(pw.len, wallet_pw_max);
        @memcpy(act.wallet_pw_buf[0..n], pw[0..n]);
        act.wallet_pw_len = n;
        self.pw_input.setValue("") catch {};

        // Backup/restore act on a file path rather than a passphrase, carried in
        // `wallet_file_buf` (the slot the external restore also uses). Backup
        // writes a fresh timestamped dump under the install root — the timestamp
        // dodges the daemon's refusal to overwrite an existing file; restore reads
        // the file just chosen in the picker.
        act.install_root = self.install_root;
        if (m.action == .backup) {
            const written = std.fmt.bufPrint(&act.wallet_file_buf, "{s}{c}{s}-wallet-backup-{d}.txt", .{
                self.install_root, std.fs.path.sep, coin.coinNameAbbrev(), std.Io.Timestamp.now(self.io, .real).toSeconds(),
            }) catch "";
            act.wallet_file_len = written.len;
        } else if (m.action == .restore) {
            const fp = self.file_picker.getSelected() orelse "";
            const fl = @min(fp.len, act.wallet_file_buf.len);
            @memcpy(act.wallet_file_buf[0..fl], fp[0..fl]);
            act.wallet_file_len = fl;
        }

        act.coin = coin;
        act.home_dir = self.home_dir;
        act.wallet_action = m.action;
        act.wallet_err = "";
        act.wallet_ok = false;
        act.wallet_done.store(false, .monotonic);

        act.wallet_thread = std.Thread.spawn(.{}, Activity.runWalletAction, .{act}) catch {
            @memset(&act.wallet_pw_buf, 0);
            act.wallet_pw_len = 0;
            m.setMsg(false, "couldn't start the wallet worker");
            return;
        };
        m.stage = .working;
        self.logf("{s}: {s}…", .{ coin.coinName(), m.action.label() });
    }

    /// Fire the chosen external-wallet setup op on a worker thread. Copies the
    /// password (and, for restore, the seed words / file path) into the activity's
    /// bounded buffers, clearing the inputs, then spawns `runWalletSetup`; the
    /// modal advances to `working` and the reap in `onTick` settles it.
    fn submitWalletSetup(self: *App) void {
        if (self.modal == null) return;
        const m = &self.modal.?;
        const coin = self.coinAt(m.coin_idx) orelse return;
        const act = &self.activities[m.coin_idx];

        // Reap any in-flight poll / prior setup worker first.
        if (act.poll_thread) |t| {
            t.join();
            act.poll_thread = null;
        }
        if (act.wallet_setup_thread) |t| {
            t.join();
            act.wallet_setup_thread = null;
        }

        // Password (cleared from the input once copied). The confirm copy is no
        // longer needed, so wipe it too.
        const pw = self.pw_input.getValue();
        const pn = @min(pw.len, wallet_pw_max);
        @memcpy(act.wallet_pw_buf[0..pn], pw[0..pn]);
        act.wallet_pw_len = pn;
        self.pw_input.setValue("") catch {};
        @memset(&m.pw_first_buf, 0);
        m.pw_first_len = 0;
        m.pw_mismatch = false;

        // Restore inputs, only for the ops that use them.
        if (m.setup_op == .restore_seed) {
            const sv = self.seed_input.getValue();
            const sn = @min(sv.len, act.wallet_seed_buf.len);
            @memcpy(act.wallet_seed_buf[0..sn], sv[0..sn]);
            act.wallet_seed_len = sn;
            self.seed_input.setValue("") catch {};
        } else {
            act.wallet_seed_len = 0;
        }
        if (m.setup_op == .restore_file) {
            const fp = self.file_picker.getSelected() orelse "";
            const fl = @min(fp.len, act.wallet_file_buf.len);
            @memcpy(act.wallet_file_buf[0..fl], fp[0..fl]);
            act.wallet_file_len = fl;
        } else {
            act.wallet_file_len = 0;
        }

        act.coin = coin;
        act.home_dir = self.home_dir;
        act.install_root = self.install_root;
        act.wallet_setup_op = m.setup_op;
        act.wallet_setup_err = "";
        act.wallet_setup_sink.len = 0;
        act.wallet_setup_ok = false;
        act.wallet_setup_done.store(false, .monotonic);

        act.wallet_setup_thread = std.Thread.spawn(.{}, Activity.runWalletSetup, .{act}) catch {
            @memset(&act.wallet_pw_buf, 0);
            act.wallet_pw_len = 0;
            @memset(&act.wallet_seed_buf, 0);
            act.wallet_seed_len = 0;
            m.setMsg(false, "couldn't start the wallet worker");
            return;
        };
        m.stage = .working;
        self.logf("{s}: {s}…", .{ coin.coinName(), m.setup_op.verb() });
    }

    pub fn view(self: *const App, ctx: *const zz.Context) []const u8 {
        const a = ctx.allocator;

        const right = self.renderDetail(a);
        // Per-entry "has an update" flags for the left-nav arrows (Home is never an
        // update target; `update_available` is only set for installed coins).
        var updates: [entries.len]bool = undefined;
        for (&updates, 0..) |*u, i| u.* = entries[i] != .home and self.activities[i].update_available;
        // The two-pane block gets whatever the log pane doesn't: windowing the
        // nav and clipping the detail pane to that budget keeps the whole frame
        // within the terminal, so the top row (Home) can never scroll off on a
        // short terminal.
        const nav_rows = self.navRowBudget(ctx.height);
        const top_full = renderTwoPane(a, self.selected, &updates, right, nav_rows) catch "render error";
        const top = clipToHeight(top_full, nav_rows);
        const screen = if (!self.log_visible)
            top
        else
            (self.renderWithLog(a, ctx.width, ctx.height, top) catch top);
        // The QuickSync prompt and the wallet modal are mutually exclusive; both
        // are centred over the dashboard by the same compositor.
        const composed = blk: {
            if (self.update_modal != null) {
                const box = self.renderUpdateModal(a) catch break :blk screen;
                break :blk overlayBox(a, screen, box, ctx.width, ctx.height) catch screen;
            }
            if (self.qs_modal != null) {
                const box = self.renderQuickSyncModal(a) catch break :blk screen;
                break :blk overlayBox(a, screen, box, ctx.width, ctx.height) catch screen;
            }
            if (self.prune_modal != null) {
                const box = self.renderPruneModal(a) catch break :blk screen;
                break :blk overlayBox(a, screen, box, ctx.width, ctx.height) catch screen;
            }
            if (self.send_modal != null) {
                const box = self.renderSendModal(a) catch break :blk screen;
                break :blk overlayBox(a, screen, box, ctx.width, ctx.height) catch screen;
            }
            if (self.mining_modal != null) {
                const box = self.renderMiningModal(a) catch break :blk screen;
                break :blk overlayBox(a, screen, box, ctx.width, ctx.height) catch screen;
            }
            if (self.sc_modal != null) {
                const box = self.renderStablecoinModal(a) catch break :blk screen;
                break :blk overlayBox(a, screen, box, ctx.width, ctx.height) catch screen;
            }
            if (self.modal == null) break :blk screen;
            break :blk self.renderModalOver(a, screen, ctx.width, ctx.height) catch screen;
        };
        // Clip every line to the terminal width before handing it back: ZigZag's
        // renderer writes each line verbatim with no clipping, so a line wider than
        // the terminal wraps onto a second physical row — shoving everything below
        // it down and scrolling the header/nav off the top. A long sync annotation
        // (the Blocks line's "<block date>  N years … behind") is the usual culprit.
        return clipToWidth(a, composed, ctx.width);
    }

    /// The bottom log pane is a separator bar plus `log_visible_lines` rows.
    const log_pane_rows = log_visible_lines + 1;

    /// Append the bottom log pane below the main two-pane area: a full-width
    /// brand-coloured separator (the "bar") followed by the most recent
    /// `log_visible_lines` action lines, newest at the bottom. The lines are
    /// padded out to that count so the pane keeps a steady footprint even when
    /// sparse, and the area above it is padded so the pane is pinned to the
    /// bottom of the terminal rather than floating up under a short detail pane.
    fn renderWithLog(self: *const App, a: std.mem.Allocator, term_width: u16, term_height: u16, top: []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(a);
        errdefer out.deinit();

        try out.writer.writeAll(top);
        if (top.len == 0 or top[top.len - 1] != '\n') try out.writer.writeByte('\n');

        // Pin the pane to the bottom: count the rows the top block occupies and
        // fill the gap up to the terminal's last `log_pane_rows` rows with blank
        // lines. Saturating, so a top block taller than the screen just scrolls.
        var top_rows = std.mem.count(u8, top, "\n");
        if (top.len == 0 or top[top.len - 1] != '\n') top_rows += 1;
        const filler = @as(usize, term_height) -| log_pane_rows -| top_rows;
        try out.writer.splatByteAll('\n', filler);

        // Separator bar: a heading, then box-drawing dashes out to the terminal
        // width, tinted in the app's brand colour.
        const width: usize = @max(@as(usize, term_width), 1);
        const heading = "── Log  (l: hide) ";
        var sep: std.Io.Writer.Allocating = .init(a);
        defer sep.deinit();
        try sep.writer.writeAll(heading);
        var col = zz.width(heading);
        while (col < width) : (col += 1) try sep.writer.writeAll("─");
        const sep_styled = (zz.Style{}).fg(zz.Color.hex(app_color)).render(a, sep.written()) catch sep.written();
        try out.writer.print("{s}\n", .{sep_styled});

        // The last `log_visible_lines` messages, oldest first so the newest sits
        // on the pane's bottom row; blank lines fill the top when there aren't
        // yet enough messages, so the live line always lands at the bottom.
        const available = @min(self.log_count, log_capacity);
        const show = @min(available, @as(usize, log_visible_lines));
        const start = self.log_count - show;
        try out.writer.splatByteAll('\n', log_visible_lines - show);
        var i: usize = 0;
        while (i < show) : (i += 1) {
            const slot = &self.log_lines[(start + i) % log_capacity];
            const line = slot.buf[0..slot.len];
            // Tint the leading "<coin>:"/"BoxWallet:" tag in its brand colour,
            // the rest plain. The tag begins at the first letter, just past the
            // "HH:MM:SS  " timestamp (split it off first — it has colons too).
            var ts: usize = 0;
            while (ts < line.len and !std.ascii.isAlphabetic(line[ts])) : (ts += 1) {}
            const msg = line[ts..];
            if (logTagColor(msg)) |hit| {
                const tag_txt = msg[0..hit.len];
                // A coin tag wears its full branding (two-tone wordmark or single
                // brand colour), matching the detail-pane header; BoxWallet/Home has
                // no coin, so it falls back to `hit.col` (the app brand colour).
                const tag = if (self.coinForTag(tag_txt)) |coin|
                    brandLogTag(a, coin, tag_txt)
                else
                    (zz.Style{}).fg(hit.col).render(a, tag_txt) catch tag_txt;
                try out.writer.print("{s}{s}{s}\n", .{ line[0..ts], tag, msg[hit.len..] });
            } else {
                try out.writer.print("{s}\n", .{line});
            }
        }

        // The renderer paints one terminal row per '\n'-separated segment from
        // cursor-home, so the view must be *exactly* `term_height` rows. We just
        // filled the screen and ended on a newline — that trailing newline would
        // emit one row too many and scroll the top line (Home) off-screen. Drop
        // it so the segment count matches the height.
        const result = try out.toOwnedSlice();
        return if (result.len > 0 and result[result.len - 1] == '\n')
            result[0 .. result.len - 1]
        else
            result;
    }

    /// A one-line-ish summary of coins with an available update, for the Home
    /// pane: "⬆ Coin updates available: DigiByte, Epic" plus a how-to line. Returns
    /// "" when nothing's pending, so the line simply vanishes. The names are pulled
    /// from `update_available` (only ever set for installed coins).
    fn coinUpdateSummary(self: *const App, a: std.mem.Allocator) []const u8 {
        var names: std.Io.Writer.Allocating = .init(a);
        defer names.deinit();
        var count: usize = 0;
        for (entries, 0..) |e, i| {
            if (e == .home or !self.activities[i].update_available) continue;
            if (count > 0) names.writer.writeAll(", ") catch return "";
            names.writer.writeAll(entryLabel(e)) catch return "";
            count += 1;
        }
        if (count == 0) return "";
        const styled = (zz.Style{}).bold(true).fg(.yellow).render(a, names.written()) catch names.written();
        return std.fmt.allocPrint(
            a,
            "\n\n⬆ Coin updates available: {s}\n  Select the coin on the left and press u to update.",
            .{styled},
        ) catch "";
    }

    /// Builds the right-hand detail block for the current selection. The coin
    /// pane is rendered generically through the `Coin` interface, so no per-coin
    /// code lives here — a newly registered coin renders for free.
    fn renderDetail(self: *const App, a: std.mem.Allocator) []const u8 {
        const coin = self.selectedCoin() orelse {
            // The "BoxWallet" wording wears the brand colour; the version rides
            // alongside it in the terminal default.
            const brand = (zz.Style{}).bold(true).fg(zz.Color.hex(app_color));
            const head = brand.render(a, app_name) catch app_name;
            // Once a newer build is staged, sit a notice under the title: the
            // normal "restart to apply", or — when the program's own folder
            // isn't writable — a heads-up that a restart wouldn't take.
            const notice = if (!self.update_available)
                ""
            else if (self.update_blocked)
                std.fmt.allocPrint(a, "\n⚠ Update v{s} downloaded, but BoxWallet's folder isn't writable.\n  Move BoxWallet to a writable location, then restart.", .{self.update_version.slice()}) catch ""
            else
                std.fmt.allocPrint(a, "\n⬆ Update v{s} downloaded — restart to apply", .{self.update_version.slice()}) catch "";
            // Coin-update roll-up: the coins whose installed daemon trails their
            // bundled version, so the user sees them from Home without clicking
            // into each. Empty (line vanishes) when everything's current.
            const coin_updates = self.coinUpdateSummary(a);
            return std.fmt.allocPrint(a,
                \\{s} v{s}{s}{s}
                \\
                \\Select a coin on the left — click it, or:
                \\
                \\  up/down  navigate
                \\  i        install selected coin
                \\  s        start/stop selected coin's daemon
                \\  w        wallet (encrypt / unlock / stake)
                \\  l        toggle the log pane
                \\  h        hide/show balance figures
                \\  p        USD prices on/off (off = no price lookups)
                \\  m        toggle the mouse (off = select text to copy)
                \\  q        quit
            , .{ head, app_version, notice, coin_updates }) catch "alloc error";
        };

        return self.renderCoin(a, coin, &self.activities[self.selected]) catch "alloc error";
    }

    /// Renders a single coin's pane: its metadata plus a middle block that
    /// reflects the coin's own install activity (idle button, live progress,
    /// or a completed/failed result). All activity stays inside this pane, so
    /// the surrounding two-pane layout — and the coin list on the left — is
    /// never disturbed.
    fn renderCoin(self: *const App, a: std.mem.Allocator, coin: Coin, act: *const Activity) ![]const u8 {
        const name_str = coin.coinName();
        const head_color = zz.Color.hex(coin.coinColor());
        // The coin name wears its brand colour — or, for a two-tone wordmark
        // (ReddCoin: "Redd" red, "Coin" near-white; SpiderByte: "Spider" white,
        // "Byte" brand), the head in `coin_color` (or the wordmark's `head_color`
        // override) and the tail in its alt colour, matching the left-nav label.
        const name = if (coin.wordmark()) |wm| blk: {
            const hc = if (wm.head_color) |c| zz.Color.hex(c) else head_color;
            const h = (zz.Style{}).bold(true).fg(hc).render(a, name_str[0..wm.split]) catch name_str[0..wm.split];
            const t = (zz.Style{}).bold(true).fg(zz.Color.hex(wm.alt_color)).render(a, name_str[wm.split..]) catch name_str[wm.split..];
            break :blk std.fmt.allocPrint(a, "{s}{s}", .{ h, t }) catch name_str;
        } else (zz.Style{}).bold(true).fg(head_color).render(a, name_str) catch name_str;
        // Header shows the installed version when known; falls back to the bundled
        // (target) version when no marker exists.
        const iv = act.installedVersion();
        const displayed_version = if (act.update_available and iv.len > 0) iv else coin.coreVersion();
        const head_base = std.fmt.allocPrint(a, "{s} v{s}", .{ name, displayed_version }) catch name;
        // When the on-disk daemon trails the bundled version (or is unmarked), tack
        // on a yellow badge naming the version that will be installed on `u`.
        const head = if (act.update_available) blk: {
            const badge_text = if (iv.len > 0)
                std.fmt.allocPrint(a, "   ⬆ v{s} available — press u to update", .{coin.coreVersion()}) catch "   ⬆ update — press u"
            else
                "   ⬆ update available — press u";
            const badge = (zz.Style{}).bold(true).fg(.yellow).render(a, badge_text) catch badge_text;
            break :blk std.fmt.allocPrint(a, "{s}{s}", .{ head_base, badge }) catch head_base;
        } else head_base;

        const p = act.phaseOf();
        // Status labels wear the coin's brand colour only while their status is
        // "live" — animating or positive (see `statusLabel`); otherwise they go
        // grey.
        const brand = zz.Color.hex(coin.coinColor());

        const is_installed = p == .done or act.installed;
        const installed_label = statusLabel(a, brand, "Installed", is_installed);
        const installed_mark = statusMark(a, is_installed);

        // While the first poll is still pending, the daemon/staking status isn't
        // known yet — animate rather than flash a misleading ✘.
        const awaiting = act.awaitingStatus();

        // The daemon line is a tick/cross when stopped or up, or a spinner while
        // it's starting or while the first status poll is still in flight. The
        // label is grey only when stopped and not awaiting (the red ✘ state).
        const daemon_label = statusLabel(a, brand, "Running", act.daemonState() != .stopped or awaiting);
        const daemon_mark: []const u8 = switch (act.daemonState()) {
            // When up, show the tick plus the version actually running — the daemon's
            // own reported one, or the marker for the coins whose RPC reports none.
            //
            // When that disagrees with the version BoxWallet pins, say so loudly
            // instead of dimming it: a daemon quietly running a release behind the pin
            // is how a v0.2.2.0 nervad sat through Nerva's hard-fork release. The
            // compare is `updater.differs`, not string equality, so a coin whose
            // version merely *spells* differently (Nexa's "2.0.0" vs its pinned
            // "2.0.0.0") doesn't raise a false alarm.
            .running => blk: {
                const tick = statusMark(a, true);
                const rv = act.effectiveVersion();
                if (rv.len == 0) break :blk tick;
                const pinned = coin.coreVersion();
                if (act.versionMismatch(pinned)) {
                    const text = std.fmt.allocPrint(
                        a,
                        "v{s}  ⚠ not the bundled v{s} — press u to update",
                        .{ rv, pinned },
                    ) catch rv;
                    const warn = (zz.Style{}).bold(true).fg(.yellow).render(a, text) catch text;
                    break :blk std.fmt.allocPrint(a, "{s} {s}", .{ tick, warn }) catch tick;
                }
                const ver = (zz.Style{}).dim(true).render(a, std.fmt.allocPrint(a, "v{s}", .{rv}) catch rv) catch rv;
                break :blk std.fmt.allocPrint(a, "{s} {s}", .{ tick, ver }) catch tick;
            },
            .stopped => if (awaiting) act.daemon_spinner.view(a) catch "…" else statusMark(a, false),
            .starting, .stopping => act.daemon_spinner.view(a) catch "…",
        };

        // Peers: a dimmed dash while the daemon is down, an animating spinner
        // while it's up but no peer has connected yet, and the green count once
        // peers arrive. The label is live whenever the daemon is up (spinner or
        // count), grey only for the dash.
        const peers_label = statusLabel(a, brand, "Peers", act.daemonState() == .running);
        const peers_value: []const u8 = if (act.daemonState() != .running)
            (zz.Style{}).dim(true).render(a, "-") catch "-"
        else if (act.peers == 0)
            act.daemon_spinner.view(a) catch "…"
        else blk: {
            const peers_count = std.fmt.allocPrint(a, "{d}", .{act.peers}) catch "?";
            break :blk (zz.Style{}).bold(true).fg(.green).render(a, peers_count) catch peers_count;
        };

        // Sync line: red cross when idle, spinner while syncing, green tick once
        // synced. The label itself reads "Synced" only when fully synced, and is
        // grey only in the idle (red ✘) state. When the daemon is not running
        // (stopping or stopped) treat it the same as idle — stale poll values
        // must not leak a green ✓ while the daemon is on its way down.
        const daemon_up = act.daemonState() == .running;
        const sync_text = if (daemon_up and act.sync == .synced) "Synced" else "Syncing";
        const sync_label = statusLabel(a, brand, sync_text, awaiting or (daemon_up and act.sync != .idle));
        const sync_mark: []const u8 = if (awaiting)
            act.daemon_spinner.view(a) catch "…"
        else if (!daemon_up)
            statusMark(a, false)
        else switch (act.sync) {
            .synced => statusMark(a, true),
            .idle => statusMark(a, false),
            .syncing => act.sync_spinner.view(a) catch "…",
        };

        // Staking only applies to proof-of-stake coins; PoW coins omit it
        // entirely (empty string folds out of the status line). Grey unless
        // animating (awaiting) or staking (green tick). Same daemon-up guard as
        // sync: stale `staking = true` must not show while the daemon is stopping.
        const staking_part: []const u8 = if (coin.isProofOfStake()) blk: {
            const staking_label = statusLabel(a, brand, "Staking", awaiting or (daemon_up and act.staking));
            const staking_mark = if (awaiting)
                act.daemon_spinner.view(a) catch "…"
            else
                statusMark(a, daemon_up and act.staking);
            break :blk std.fmt.allocPrint(a, "    {s}: {s}", .{ staking_label, staking_mark }) catch "";
        } else "";

        // Wallet status. Two shapes:
        //   * In-daemon (bitcoin) coins: text + colour come from the polled
        //     security state; the label greys until it's known.
        //   * External-wallet (Monero-style) coins: the daemon RPC has no wallet,
        //     so the line reflects the external wallet's setup state — "No wallet"
        //     (with a set-up hint), "Locked" (with an unlock hint), or "Unlocked".
        const ext = coin.hasExternalWallet();
        const ext_open = ext and act.ext_wallet_open.load(.monotonic) != 0;

        const wallet_label = statusLabel(a, brand, "Wallet", if (ext) daemon_up else act.wallet != .unknown);
        const wallet_value: []const u8 = if (ext) blk: {
            if (!daemon_up) break :blk (zz.Style{}).fg(.brightBlack).render(a, "Unknown") catch "Unknown";
            if (!act.ext_wallet_exists) break :blk (zz.Style{}).bold(true).fg(.yellow).render(a, "No wallet") catch "No wallet";
            if (!ext_open) break :blk (zz.Style{}).bold(true).fg(.yellow).render(a, "Locked") catch "Locked";
            // An open wallet that's mid-rescan (Ergo, or a Monero-family wallet like
            // Salvium/Nerva after a restore) reports its progress instead of a bare
            // "Unlocked" — the scan can take many minutes on a low-spec box, so the
            // user needs to see it's working.
            if (act.rescanning) {
                const pct = models.RescanProgress.fraction(.{
                    .scanned = @intCast(act.rescan_scanned),
                    .target = @intCast(act.rescan_target),
                }) * 100;
                const text = std.fmt.allocPrint(a, "Rescanning… {d:.1}%", .{pct}) catch "Rescanning…";
                break :blk (zz.Style{}).bold(true).fg(.yellow).render(a, text) catch text;
            }
            break :blk (zz.Style{}).bold(true).fg(.green).render(a, "Unlocked") catch "Unlocked";
        } else (zz.Style{}).bold(true).fg(walletColor(act.wallet)).render(a, walletText(act.wallet)) catch walletText(act.wallet);

        // Advertise the `w` key the way the daemon button advertises `s` — but
        // only when a press would actually open the menu. Dimmed so it reads as a
        // hint, not part of the status. External coins spell out the action ("set
        // up" / "unlock"); in-daemon coins use the generic "(press w)".
        const wallet_hint: []const u8 = if (ext and daemon_up) blk: {
            // An open wallet only advertises `w` when the coin can re-lock it.
            const can_lock = if (coin.externalWallet()) |ew| ew.lock != null else false;
            const text = if (!act.ext_wallet_exists)
                "   (press w to set up)"
            else if (!ext_open)
                "   (press w to unlock)"
            else if (can_lock)
                "   (press w to lock)"
            else
                "";
            break :blk if (text.len == 0) "" else (zz.Style{}).dim(true).render(a, text) catch text;
        } else if (!ext and coin.supportsWallet() and daemon_up and act.wallet != .unknown)
            (zz.Style{}).dim(true).render(a, "   (press w)") catch "   (press w)"
        else
            "";

        // Balance — shown top-right of the pane header for any balance-capable coin,
        // always (regardless of amount or whether one's been polled yet — 0 until
        // then). The "Total"/"Available" labels and the coin abbrev wear the brand
        // colour; only the figure is tinted by state. "Total" (confirmed + mempool +
        // immature) is always shown with a green figure. "Available" (confirmed
        // spendable) is appended *only* while it trails Total — funds still settling
        // — with a yellow figure as a "not all spendable yet" caveat. Empty for coins
        // that report no balance.
        const corner: []const u8 = if (coin.supportsBalance() or coin.hasExternalWallet()) blk: {
            const abbrev = coin.coinNameAbbrev();
            const dp = coin.balanceDecimals();
            const bal: models.WalletBalance = .{ .total = act.balance_total, .available = act.balance_avail };
            const total = balanceCorner(a, brand, "Total", act.balance_total, abbrev, .green, dp, self.hide_balances);
            // While hidden, drop Available entirely: it's shown only when funds are
            // still settling, so keeping it would leak that pending funds exist.
            if (self.hide_balances or !bal.hasPending()) break :blk total;
            const avail = balanceCorner(a, brand, "Available", act.balance_avail, abbrev, .yellow, dp, self.hide_balances);
            break :blk std.fmt.allocPrint(a, "{s}   {s}", .{ total, avail }) catch total;
        } else "";

        // USD price + 24h move, tucked in beside the balance. Absent for an
        // unlisted coin, while prices are off, or when the last fetch is stale
        // (see `quoteAt`) — the line simply isn't drawn, never a "$0.00".
        const price_str: []const u8 = if (corner.len == 0)
            ""
        else if (self.quoteAt(self.selected)) |q|
            priceCorner(a, q, act.balance_total, self.hide_balances)
        else
            "";

        // Sit the balance just to the right of the coin/version on the header row,
        // with a clear gap, and the USD figure after it. Just the title when the
        // coin reports no balance.
        const head_line: []const u8 = if (corner.len == 0)
            head
        else if (price_str.len == 0)
            std.fmt.allocPrint(a, "{s}     {s}", .{ head, corner }) catch head
        else
            std.fmt.allocPrint(a, "{s}     {s}   {s}", .{ head, corner, price_str }) catch head;

        // Sync progress bars. Labels are padded to a common width before styling
        // (ANSI codes are zero-width) so the two bars line up. Like the status
        // labels above, they go grey unless the daemon is running.
        const bars_active = act.daemonState() == .running;
        const headers_label = statusLabel(a, brand, "Headers", bars_active);
        const blocks_label = statusLabel(a, brand, "Blocks ", bars_active);
        const headers_bar = try bar(a, act.headers_cur, act.headers_total);
        const blocks_bar = try bar(a, act.blocks_cur, act.blocks_total);

        // Sync annotation beside the Blocks bar: the tip block's own date/time
        // (UTC — the moment the block being synced was mined), then how far behind
        // in wall-clock time that puts us. Both come from the tip timestamp at poll
        // time; either folds out to "" when unavailable, and the whole thing is
        // empty unless syncing. Dimmed so it reads as a hint next to the bar rather
        // than competing with it.
        const behind_text: []const u8 = if (act.sync == .syncing) blk: {
            const when = formatBlockTime(a, act.tip_time) catch "";
            const behind = if (act.behind_secs > 0) (formatBehind(a, act.behind_secs) catch "") else "";
            if (when.len == 0 and behind.len == 0) break :blk "";
            const joined = if (when.len > 0 and behind.len > 0)
                std.fmt.allocPrint(a, "{s}  {s}", .{ when, behind }) catch when
            else if (when.len > 0) when else behind;
            const styled = (zz.Style{}).dim(true).render(a, joined) catch joined;
            break :blk std.fmt.allocPrint(a, "  {s}", .{styled}) catch "";
        } else "";

        // Storage line: how much disk this coin's data directory occupies — the
        // "Size" a file manager's Properties dialog reports. Sits directly under
        // the Blocks bar; its label greys with the daemon like the sync bars it
        // groups with, though the figure itself is disk-derived and shown even
        // when the daemon is down. A dim "—" stands in until the first sample
        // lands (or when the coin has no data dir yet, e.g. not installed).
        const storage_label = statusLabel(a, brand, "Storage", bars_active);
        const storage_value: []const u8 = if (act.storage_sampled)
            formatStorageGB(a, act.storage_bytes)
        else
            (zz.Style{}).dim(true).render(a, "—") catch "—";

        // Disk-usage bar: how full the volume holding the blockchains is. Sits
        // apart from the sync bars (separated by a blank line) because it's a
        // machine-level figure, not a coin's sync state — so it stays in the
        // brand colour regardless of whether this coin's daemon is running. The
        // label is space-padded to the sync labels' width so all three align.
        const disk_label = statusLabel(a, brand, "Disk   ", true);
        const disk_bar = try usageBar(a, self.disk_used, self.disk_total);

        // Memory bar: system RAM used, drawn exactly like the Disk bar. Like
        // Disk it's a machine-level reading, so it stays in the brand colour
        // regardless of this coin's daemon state.
        const mem_label = statusLabel(a, brand, "Memory ", true);
        const mem_bar = try usageBar(a, self.mem_used, self.mem_total);

        const middle = try renderActivity(a, act, p);
        const daemon_button = renderDaemonButton(a, act);
        // The action area below the bars: the optional install/update button
        // (absent when an installed coin is already up to date) sitting above the
        // always-present daemon control. Folding them together here keeps the
        // spacing tidy whether or not the button is shown.
        const controls = if (middle.len == 0)
            daemon_button
        else
            try std.fmt.allocPrint(a, "{s}\n\n{s}", .{ middle, daemon_button });

        // Headline live status — what the daemon is doing right now.
        const status_line = renderStatus(a, act, brand);

        // Everything below the header is the Home tab's content; the other tabs
        // are scaffolded placeholders for now. The coin/balance header and the
        // tab strip stay pinned above whichever tab is active.
        // A short one-line description under the coin name, in the default colour
        // to match the `v<version>` text in the header. Sits a blank line below
        // the name/version row.
        const description = coin.coinDescription();

        const tab_strip = try renderTabStrip(a, brand, self.active_tab, coin);
        const body: []const u8 = switch (self.active_tab) {
            .home => try std.fmt.allocPrint(a,
                \\{s}
                \\{s}: {s}    {s}: {s}    {s}: {s}    {s}: {s}{s}
                \\{s}: {s}{s}
                \\
                \\{s}  {s}
                \\{s}  {s}{s}
                \\{s}  {s}
                \\
                \\{s}  {s}
                \\{s}  {s}
                \\
                \\{s}
            , .{
                status_line,
                installed_label,
                installed_mark,
                daemon_label,
                daemon_mark,
                peers_label,
                peers_value,
                sync_label,
                sync_mark,
                staking_part,
                wallet_label,
                wallet_value,
                wallet_hint,
                headers_label,
                headers_bar,
                blocks_label,
                blocks_bar,
                behind_text,
                storage_label,
                storage_value,
                disk_label,
                disk_bar,
                mem_label,
                mem_bar,
                controls,
            }),
            .settings => try renderSettingsTab(a, coin, brand, self.home_dir, act),
            .transactions => if (coin.supportsTransactions())
                try renderTransactionsTab(a, act, coin.balanceDecimals())
            else
                try renderPlaceholderTab(a, self.active_tab),
            .receive => if (coin.supportsReceiveAddress())
                try renderReceiveTab(a, act)
            else
                try renderPlaceholderTab(a, self.active_tab),
            .send => if (coin.supportsSend())
                try renderSendTab(a, coin, act, self.hide_balances, self.quoteAt(self.selected))
            else
                try renderPlaceholderTab(a, self.active_tab),
            .mining => if (coin.supportsMining())
                try renderMiningTab(a, act)
            else
                try renderPlaceholderTab(a, self.active_tab),
            .digidollar => if (coin.stablecoin()) |sc|
                try renderStablecoinTab(a, sc, act, self.hide_balances)
            else
                try renderPlaceholderTab(a, self.active_tab),
            .staking => if (coin.supportsStakeAction())
                try renderStakingTab(a, coin, act, self.hide_balances)
            else
                try renderPlaceholderTab(a, self.active_tab),
        };

        // TIP line: persists across every tab (mirrors description/tab_strip),
        // inviting a small donation in the coin's own currency to fund
        // BoxWallet development. `t` copies the address, mirroring the
        // Receive tab's `c`.
        const tip_hint = (zz.Style{}).dim(true).render(a, "  (t: copy)") catch "  (t: copy)";
        const tip_text = try std.fmt.allocPrint(
            a,
            "Enjoying BoxWallet? Tip {s}: {s}{s}",
            .{ coin.coinNameAbbrev(), coin.tipAddress(), tip_hint },
        );

        return std.fmt.allocPrint(a, "{s}\n\n{s}\n\n{s}\n\n{s}\n\n{s}", .{ head_line, description, tab_strip, body, tip_text });
    }

    /// One-line tab strip for the coin detail pane: the active tab in the coin's
    /// brand colour (bold), the others dimmed, with a dim hint on how to switch.
    /// The capability tabs (Mining, DigiDollar) only exist for coins wiring the
    /// capability, so they — and the hint's key range — are gated per coin. The
    /// stablecoin tab is labelled with the capability's own name.
    fn renderTabStrip(a: std.mem.Allocator, brand: zz.Color, active: DetailTab, coin: Coin) ![]const u8 {
        const caps = TabCaps.of(coin);
        var strip: []const u8 = "";
        inline for (std.meta.tags(DetailTab), 0..) |t, i| {
            if (tabVisible(t, caps)) {
                const lbl = if (t == .digidollar) coin.stablecoin().?.name else t.label();
                const styled = if (t == active)
                    try (zz.Style{}).bold(true).fg(brand).render(a, lbl)
                else
                    try (zz.Style{}).dim(true).render(a, lbl);
                const sep = try (zz.Style{}).fg(zz.Color.hex("ffffff")).render(a, "|");
                strip = if (i == 0) styled else try std.fmt.allocPrint(a, "{s}  {s}  {s}", .{ strip, sep, styled });
            }
        }
        const hint_text = try std.fmt.allocPrint(a, "   (←/→ or 1-{d} to switch tabs)", .{visibleTabCount(caps)});
        const hint = try (zz.Style{}).dim(true).render(a, hint_text);
        return std.fmt.allocPrint(a, "{s}{s}", .{ strip, hint });
    }

    /// The Settings tab body: the on-disk location of the coin's managed wallet
    /// file (so the user can find/back it up) and — for prune-capable coins
    /// (Bitcoin/Litecoin/Monero) — the configured prune setting, read-only. Coins BoxWallet manages
    /// no discrete wallet file for (Ergo's node-internal wallet, Epic, Zano) show an
    /// em-dash. Monero-style coins list the `.keys` companion on its own line. All
    /// values come from the per-frame arena `a` and the cached `act` (no disk IO in
    /// the render path). Labels are padded to a common width so the colons align.
    fn renderSettingsTab(a: std.mem.Allocator, coin: Coin, brand: zz.Color, home_dir: []const u8, act: *const Activity) ![]const u8 {
        const wallet_label = statusLabel(a, brand, "Wallet file", true);
        const wf = coin.walletPath(a, home_dir) catch null;
        const wallet_value: []const u8 = if (wf) |w|
            (zz.Style{}).dim(true).render(a, w.path) catch w.path
        else
            (zz.Style{}).fg(.brightBlack).render(a, "—  (managed by the node)") catch "—";
        // A Monero wallet is a file pair — show its `.keys` companion on its own
        // aligned row ("Wallet keys" is the same width as "Wallet file") so the
        // user knows to back up both. Empty (folds out) for single-file coins.
        const keys_row: []const u8 = if (wf) |w| blk: {
            const k = w.keys orelse break :blk "";
            const keys_label = statusLabel(a, brand, "Wallet keys", true);
            const keys_value = (zz.Style{}).dim(true).render(a, k) catch k;
            break :blk std.fmt.allocPrint(a, "\n{s}: {s}", .{ keys_label, keys_value }) catch "";
        } else "";
        // Pruning row, only for coins with the capability (Litecoin). Read-only —
        // the value is chosen once at first start. "Pruning" is padded to the
        // wallet labels' width so the colon lines up.
        const prune_row: []const u8 = if (coin.pruning()) |pr| blk: {
            const prune_label = statusLabel(a, brand, "Pruning    ", true);
            const prune_value = formatPruneValue(a, pr.mode, act.prune_mib);
            break :blk std.fmt.allocPrint(a, "\n{s}: {s}", .{ prune_label, prune_value }) catch "";
        } else "";
        return std.fmt.allocPrint(a,
            \\Settings
            \\
            \\{s}: {s}{s}{s}
        , .{ wallet_label, wallet_value, keys_row, prune_row });
    }

    /// Format a cached prune value (0 = full node, <0 = not configured yet) for the
    /// Settings tab, in the coin's own terms. A `.size_mib` target reads as "N GB"
    /// when it's whole GB (matching how it was chosen) and "N MiB" otherwise; an
    /// `.on_off` coin has no size to show, so it just says pruning is on.
    fn formatPruneValue(a: std.mem.Allocator, mode: Coin.Pruning.Mode, prune_mib: i64) []const u8 {
        // The wording is `money.pruneValueText`'s so both front-ends describe a
        // prune setting identically; only the styling is ours. "not set" is
        // greyed rather than dimmed because it's an absence, not a value —
        // and it is a meaningfully different thing from "disabled (full node)",
        // which is a choice someone made.
        var buf: [48]u8 = undefined;
        // Copied onto the arena before styling: `pruneValueText` returns a slice
        // into `buf` for the size cases, and the `catch text` fallbacks below
        // would otherwise hand back a pointer into this dead stack frame.
        const text = a.dupe(u8, money.pruneValueText(&buf, mode, prune_mib)) catch "?";
        if (prune_mib < 0) return (zz.Style{}).fg(.brightBlack).render(a, text) catch text;
        return (zz.Style{}).dim(true).render(a, text) catch text;
    }

    /// Placeholder body for a not-yet-built tab (Transactions/Receive/Send) — its
    /// title plus a "coming soon" note.
    fn renderPlaceholderTab(a: std.mem.Allocator, tab: DetailTab) ![]const u8 {
        return std.fmt.allocPrint(a,
            \\{s}
            \\
            \\Coming soon.
        , .{tab.label()});
    }

    /// The Transactions tab body: the coin's cached recent transactions
    /// (`act.tx_buf`/`act.tx_count`, populated by the poll worker), newest-first,
    /// one per line — a direction glyph, the date, the amount, and a
    /// confirmation status. Only reached for a coin whose
    /// `supportsTransactions()` is true; every other coin's `.transactions` case
    /// still falls through to `renderPlaceholderTab`. Reads only the cached
    /// `act` fields — no RPC/disk IO in the render path.
    fn renderTransactionsTab(a: std.mem.Allocator, act: *const Activity, decimals: u8) ![]const u8 {
        if (act.tx_count == 0) {
            return "Transactions\n\nNo transactions yet.";
        }

        // Fixed-width, aligned columns so the rows read as a table rather than a
        // ragged list. The date is always "YYYY-MM-DD HH:MM" (16 cells); the
        // amount column right-aligns to the widest figure so decimal points line
        // up. Cells are ASCII here, so byte length equals display width — we can
        // pad the plain text *before* applying colour (padding a pre-styled string
        // would count the ANSI escape bytes and misalign the grid).
        const date_w: usize = 16;
        var amount_w: usize = "Amount".len;
        for (act.tx_buf[0..act.tx_count]) |tx| {
            var buf: [64]u8 = undefined;
            amount_w = @max(amount_w, trimTrailingZeros(formatAmount(&buf, tx.amount, decimals)).len);
        }

        // Header row (dim), indented past the direction glyph so its labels sit
        // over their columns.
        const header_plain = try std.fmt.allocPrint(a, "    {s}   {s}   Status", .{
            try padCell(a, "Date", date_w, false),
            try padCell(a, "Amount", amount_w, true),
        });
        var body: []const u8 = (zz.Style{}).dim(true).render(a, header_plain) catch header_plain;

        for (act.tx_buf[0..act.tx_count]) |tx| {
            const glyph = txDirectionGlyph(a, tx.direction);
            const date = try formatBlockTime(a, tx.time);
            var buf: [64]u8 = undefined;
            const amount = trimTrailingZeros(formatAmount(&buf, tx.amount, decimals));
            const conf_text = txConfirmationText(a, tx.confirmations);
            const line = try std.fmt.allocPrint(a, "  {s} {s}   {s}   {s}", .{
                glyph,
                try padCell(a, date, date_w, false),
                try padCell(a, amount, amount_w, true),
                conf_text,
            });
            body = try std.fmt.allocPrint(a, "{s}\n{s}", .{ body, line });
        }
        return std.fmt.allocPrint(a, "Transactions\n\n{s}", .{body});
    }

    /// The Staking tab body: what staking does on this coin, the key that starts
    /// one, and the wallet's stakes (`act.stake_buf`/`act.stake_count`) newest
    /// first — each with the principal, the date it was staked, and either how
    /// long its term has left or when it paid out and what it earned.
    ///
    /// Only reached for a coin with a stake action; a coin that has the action
    /// but can't enumerate stakes (`supportsStakeList` false) simply gets the
    /// prompt with no table. Reads only cached `act` fields — no RPC in render.
    fn renderStakingTab(
        a: std.mem.Allocator,
        coin: Coin,
        act: *const Activity,
        hide_balances: bool,
    ) ![]const u8 {
        const decimals = coin.balanceDecimals();
        const abbrev = coin.coinNameAbbrev();

        const hint_text = coin.stakeHint();
        const hint = if (hint_text.len == 0)
            ""
        else
            (zz.Style{}).dim(true).render(a, hint_text) catch hint_text;
        const key_hint = (zz.Style{}).dim(true).render(a, "(S: stake)") catch "(S: stake)";
        const head = if (hint.len == 0)
            try std.fmt.allocPrint(a, "Staking\n\n{s}", .{key_hint})
        else
            try std.fmt.allocPrint(a, "Staking\n\n{s}\n\n{s}", .{ hint, key_hint });

        if (!coin.supportsStakeList()) return head;
        // A wallet that has never staked, and one whose stakes haven't loaded
        // yet, both read as empty — the prompt above still says what to do.
        if (act.stake_count == 0)
            return std.fmt.allocPrint(a, "{s}\n\nNo stakes yet.", .{head});

        // Same column discipline as the Transactions table: pad the plain text to
        // a common width *before* styling, since ANSI bytes aren't display cells.
        const date_w: usize = 16;
        var amount_w: usize = "Amount".len;
        for (act.stake_buf[0..act.stake_count]) |s| {
            var buf: [64]u8 = undefined;
            const text = if (hide_balances) balance_mask else trimTrailingZeros(formatAmount(&buf, s.amount, decimals));
            amount_w = @max(amount_w, text.len);
        }

        const header_plain = try std.fmt.allocPrint(a, "  {s}   {s}   Status", .{
            try padCell(a, "Staked", date_w, false),
            try padCell(a, "Amount", amount_w, true),
        });
        var body: []const u8 = (zz.Style{}).dim(true).render(a, header_plain) catch header_plain;

        for (act.stake_buf[0..act.stake_count]) |s| {
            var buf: [64]u8 = undefined;
            const amount = if (hide_balances)
                balance_mask
            else
                trimTrailingZeros(formatAmount(&buf, s.amount, decimals));
            const line = try std.fmt.allocPrint(a, "  {s}   {s}   {s}", .{
                try padCell(a, try formatBlockTime(a, s.staked_time), date_w, false),
                try padCell(a, amount, amount_w, true),
                try stakeStatusText(a, s, abbrev, decimals, hide_balances),
            });
            body = try std.fmt.allocPrint(a, "{s}\n{s}", .{ body, line });
        }
        return std.fmt.allocPrint(a, "{s}\n\n{s}", .{ head, body });
    }

    /// One stake's Status cell. A locked stake counts down in yellow (the same
    /// "not yours to spend yet" colour the Available balance wears); a matured
    /// one reads green with the date it unlocked and, where the payout could be
    /// attributed to it, what it earned. `models.Stake` uses 0 for "not known",
    /// so an unattributable payout simply loses the extra detail rather than
    /// showing a zero.
    fn stakeStatusText(
        a: std.mem.Allocator,
        s: models.Stake,
        abbrev: []const u8,
        decimals: u8,
        hide_balances: bool,
    ) ![]const u8 {
        if (!s.isMatured()) {
            var tbuf: [timefmt.max_len]u8 = undefined;
            const eta = timefmt.duration(&tbuf, s.unlock_eta_seconds);
            const text = if (eta.len == 0)
                try std.fmt.allocPrint(a, "Locked, {d} blocks to go", .{s.blocks_remaining})
            else
                try std.fmt.allocPrint(a, "Locked, unlocks in {s}", .{eta});
            return (zz.Style{}).bold(true).fg(.yellow).render(a, text) catch text;
        }

        const when = if (s.unlocked_time > 0)
            try std.fmt.allocPrint(a, "Unlocked {s}", .{try formatBlockTime(a, s.unlocked_time)})
        else
            try a.dupe(u8, "Unlocked");
        // The yield is the whole point of having staked, so it rides in the same
        // cell — but only when this stake's own payout could be told apart from
        // another's (see `pairStakeReturns`), and never while balances are hidden.
        const text = if (hide_balances) when else blk: {
            const earned = s.yield() orelse break :blk when;
            var buf: [64]u8 = undefined;
            break :blk try std.fmt.allocPrint(a, "{s}  (+{s} {s})", .{
                when,
                trimTrailingZeros(formatAmount(&buf, earned, decimals)),
                abbrev,
            });
        };
        return (zz.Style{}).bold(true).fg(.green).render(a, text) catch text;
    }

    /// Pad an ASCII cell to `width` display cells with spaces, on the left when
    /// `right` (right-aligned, e.g. amounts) or on the right otherwise. Returns
    /// `text` unchanged when it already meets/exceeds the width. Caller-owned
    /// arena memory; only used on ASCII cells so byte length is display width.
    fn padCell(a: std.mem.Allocator, text: []const u8, width: usize, right: bool) ![]const u8 {
        if (text.len >= width) return text;
        const spaces = try a.alloc(u8, width - text.len);
        @memset(spaces, ' ');
        return if (right)
            std.fmt.allocPrint(a, "{s}{s}", .{ spaces, text })
        else
            std.fmt.allocPrint(a, "{s}{s}", .{ text, spaces });
    }

    /// A transaction counts as settled once it has more than this many
    /// confirmations; at or below it, the raw count is shown instead so the user
    /// can watch it climb. Shared with the GUI (`bw_tx_confirmed_threshold`) so
    /// the two front-ends draw the same line.
    const tx_confirmed_threshold: i64 = models.tx_confirmed_threshold;

    /// The confirmation status for one Transactions row: a bold green
    /// "Confirmed" once `confirmations` exceeds `tx_confirmed_threshold`,
    /// otherwise a bold yellow "N confirmation(s)" (still settling — the same
    /// yellow the pending/Available balance figure uses elsewhere).
    fn txConfirmationText(a: std.mem.Allocator, confirmations: i64) []const u8 {
        if (confirmations > tx_confirmed_threshold) {
            return (zz.Style{}).bold(true).fg(.green).render(a, "Confirmed") catch "Confirmed";
        }
        const n = @max(confirmations, 0);
        const text = std.fmt.allocPrint(a, "{d} confirmation{s}", .{ n, if (n == 1) "" else "s" }) catch "?";
        return (zz.Style{}).bold(true).fg(.yellow).render(a, text) catch text;
    }

    /// The direction glyph for one Transactions row: bold green ▼ (received),
    /// bold red ▲ (sent), a bold yellow ★ for a stake reward, or a bold yellow
    /// ▲ for an outgoing stake — heavy filled shapes so the direction reads at a
    /// glance. This daemon reports a stake credit the same way a mined block
    /// reward would be (see `SpiderByte.directionFromCategory`), so it's neither
    /// "received from" nor "sent to" anyone; the coins were minted by the wallet
    /// itself. A `.staked` row is the other half of that: the wallet locking its
    /// own principal for a term, so it takes the *sent* arrow (the coins did
    /// leave) in the stake colour rather than the reward star.
    fn txDirectionGlyph(a: std.mem.Allocator, direction: models.TxDirection) []const u8 {
        return switch (direction) {
            .received => (zz.Style{}).bold(true).fg(.green).render(a, "▼") catch "▼",
            .sent => (zz.Style{}).bold(true).fg(.red).render(a, "▲") catch "▲",
            .stake => (zz.Style{}).bold(true).fg(.yellow).render(a, "★") catch "★",
            .staked => (zz.Style{}).bold(true).fg(.yellow).render(a, "▲") catch "▲",
        };
    }

    /// The Receive tab body: the coin's cached receive address
    /// (`act.receive_addr_buf`/`receive_addr_len`, populated by the poll
    /// worker) plus a QR code of it. Only reached for a coin whose
    /// `supportsReceiveAddress()` is true; every other coin's `.receive` case
    /// still falls through to `renderPlaceholderTab`. Reads only the cached
    /// `act` fields — no RPC/disk IO in the render path (the QR encode itself
    /// is pure computation on the already-cached address string).
    fn renderReceiveTab(a: std.mem.Allocator, act: *const Activity) ![]const u8 {
        if (act.receive_addr_len == 0) return "Receive\n\nNo address yet.";
        const addr = act.receive_addr_buf[0..act.receive_addr_len];
        const hint = (zz.Style{}).dim(true).render(a, "  (c: copy   n: new address)") catch "";
        const qr = qrcode.encodeText(a, addr, .medium) catch return std.fmt.allocPrint(
            a,
            "Receive\n\nAddress: {s}{s}\n\n(QR code unavailable)",
            .{ addr, hint },
        );
        defer qr.deinit();
        const qr_block = try renderQrHalfBlock(a, qr);
        return std.fmt.allocPrint(a, "Receive\n\nAddress: {s}{s}\n\n{s}", .{ addr, hint, qr_block });
    }

    /// The Send tab body: the coin's cached available balance and a hint to
    /// open the Send prompt. Only reached for a coin whose `supportsSend()`
    /// is true; every other coin's `.send` case still falls through to
    /// `renderPlaceholderTab`. The actual address/amount entry happens in
    /// `SendModal` (opened by `enter`), not here — see the Context note on
    /// why free-text entry needs a modal's exclusive keyboard ownership.
    fn renderSendTab(a: std.mem.Allocator, coin: Coin, act: *const Activity, hide: bool, quote: ?price.Quote) ![]const u8 {
        const bal_str = if (hide)
            try std.fmt.allocPrint(a, "{s} {s}", .{ balance_mask, coin.coinNameAbbrev() })
        else
            formatBalance(a, act.balance_avail, coin.coinNameAbbrev(), coin.balanceDecimals());
        // What the spendable balance is worth, so the figure you're deciding an
        // amount against has a familiar scale. Suppressed while balances are
        // hidden (it's derived from the balance) and when there's no live quote.
        const balance = if (hide) bal_str else blk: {
            const q = quote orelse break :blk bal_str;
            var vbuf: [64]u8 = undefined;
            const worth = price.formatValue(&vbuf, act.balance_avail, q.usd);
            const worth_sty = (zz.Style{}).fg(.brightBlack).render(a, worth) catch worth;
            break :blk try std.fmt.allocPrint(a, "{s}  ≈ {s}", .{ bal_str, worth_sty });
        };
        // Staking has its own tab on the coins that offer it, so Send is only
        // ever about paying someone else.
        const hint_text = "(press Enter to send)";
        const hint = (zz.Style{}).dim(true).render(a, hint_text) catch hint_text;
        return std.fmt.allocPrint(a, "Send\n\nAvailable: {s}\n\n{s}", .{ balance, hint });
    }

    /// The Mining tab body: the daemon's live CPU-miner state (active/idle,
    /// thread count, hashrate) with the Enter action's hint — or, when Enter
    /// would be a no-op (daemon down, status unknown, no payout address yet),
    /// a line saying what to do instead, so a dead key isn't mysterious. Only
    /// reached for a coin whose `supportsMining()` is true; every other
    /// coin's `.mining` case still falls through to `renderPlaceholderTab`.
    /// Reads only the cached `act` fields — no RPC/disk IO in the render path.
    fn renderMiningTab(a: std.mem.Allocator, act: *const Activity) ![]const u8 {
        if (act.daemonState() != .running) {
            const note = "Mining runs inside the daemon — start it (s) first.";
            return std.fmt.allocPrint(a, "Mining\n\n{s}", .{note});
        }
        if (!act.has_mining) {
            return std.fmt.allocPrint(a, "Mining\n\nChecking miner status…", .{});
        }
        if (act.mining_active) {
            var rate_buf: [32]u8 = undefined;
            const rate = mining.formatHashrate(&rate_buf, act.mining_speed);
            const status = (zz.Style{}).bold(true).fg(.green).render(a, "Mining") catch "Mining";
            const line = try std.fmt.allocPrint(a, "Status: {s} — {d} thread{s} at {s}", .{
                status, act.mining_threads, if (act.mining_threads == 1) "" else "s", rate,
            });
            const hint_text = "(Enter: stop mining)";
            const hint = (zz.Style{}).dim(true).render(a, hint_text) catch hint_text;
            return std.fmt.allocPrint(a, "Mining\n\n{s}\n\n{s}", .{ line, hint });
        }
        const status = (zz.Style{}).dim(true).render(a, "Not mining") catch "Not mining";
        const cpus = try std.fmt.allocPrint(a, "CPU threads available: {d}", .{mining.cpuThreadCount()});
        // Starting needs the wallet's receive address (rewards have to go
        // somewhere) — until the wallet has been opened this session, say so
        // instead of offering a dead Enter.
        const hint_text: []const u8 = if (act.receive_addr_len == 0)
            "Open your wallet (w) first — mining pays block rewards to its address."
        else
            "(Enter: start mining)";
        const hint = (zz.Style{}).dim(true).render(a, hint_text) catch hint_text;
        return std.fmt.allocPrint(a, "Mining\n\nStatus: {s}\n{s}\n\n{s}", .{ status, cpus, hint });
    }

    /// The stablecoin (DigiDollar) tab body: activation status (pre-mainnet
    /// aware — the whole feature is gated behind a BIP9 deployment), the
    /// oracle price and system stats, the wallet's DD balance and deposit
    /// address, its collateral positions (vaults), and its recent DD
    /// transactions, with the action hints. Only reached for a coin whose
    /// `supportsStablecoin()` is true; every other coin's `.digidollar` case
    /// still falls through to `renderPlaceholderTab`. Reads only the cached
    /// `act` fields — no RPC/disk IO in the render path.
    fn renderStablecoinTab(a: std.mem.Allocator, sc: *const Coin.Stablecoin, act: *const Activity, hide: bool) ![]const u8 {
        if (act.daemonState() != .running) {
            return std.fmt.allocPrint(a, "{s}\n\n{s} lives on the coin's own chain — start the daemon (s) first.", .{ sc.name, sc.name });
        }
        if (!act.sc_has_info) {
            return std.fmt.allocPrint(a, "{s}\n\nChecking {s} status…", .{ sc.name, sc.name });
        }
        const info = &act.sc_info;
        if (std.mem.eql(u8, info.status(), "unsupported")) {
            return std.fmt.allocPrint(a, "{s}\n\nThis daemon doesn't support {s} — update the coin (u) to a newer core.", .{ sc.name, sc.name });
        }

        var out: std.Io.Writer.Allocating = .init(a);
        errdefer out.deinit();
        try out.writer.print("{s}\n", .{sc.name});

        // Activation status. Everything below still renders pre-activation
        // (the user can watch the oracle come alive), but the actions stay
        // gated until the network flips to "active".
        if (info.active) {
            const on = (zz.Style{}).bold(true).fg(.green).render(a, "Active") catch "Active";
            try out.writer.print("\nStatus: {s}\n", .{on});
        } else {
            const off = (zz.Style{}).bold(true).fg(.yellow).render(a, "Not active yet") catch "Not active yet";
            const st = if (info.status_len > 0) info.status() else "unknown";
            const detail = (zz.Style{}).dim(true).render(
                a,
                try std.fmt.allocPrint(a, "(deployment status: {s})", .{st}),
            ) catch "";
            try out.writer.print("\nStatus: {s}  {s}\n", .{ off, detail });
            // DigiDollar shipped in the mainnet release with a scheduled
            // activation height — count down to it, with a wall-clock ETA once
            // the local chain height and block interval are known.
            if (info.activation_height > 0) {
                var line = try std.fmt.allocPrint(a, "Activates at block {d}", .{info.activation_height});
                const remaining = info.activation_height - @as(i64, @intCast(act.blocks_cur));
                if (act.blocks_cur > 0 and remaining > 0) {
                    line = try std.fmt.allocPrint(a, "{s} — {d} blocks to go", .{ line, remaining });
                    if (sc.block_seconds > 0) {
                        const eta = try formatDurationApprox(a, remaining * @as(i64, sc.block_seconds));
                        if (eta.len > 0)
                            line = try std.fmt.allocPrint(a, "{s} (≈ {s})", .{ line, eta });
                    }
                }
                const line_dim = (zz.Style{}).dim(true).render(a, line) catch line;
                try out.writer.print("{s}\n", .{line_dim});
            }
        }

        // Oracle price (micro-USD per coin) and system-wide stats, when known.
        if (info.price_micro_usd > 0) {
            var pbuf: [32]u8 = undefined;
            const oracle_price = formatMicroUsd(&pbuf, info.price_micro_usd);
            const stale: []const u8 = if (info.price_stale)
                (zz.Style{}).bold(true).fg(.red).render(a, "  (stale)") catch "  (stale)"
            else
                "";
            try out.writer.print("Oracle price: {s} / coin{s}\n", .{ oracle_price, stale });
        } else {
            const unknown = (zz.Style{}).dim(true).render(a, "Oracle price: unknown") catch "Oracle price: unknown";
            try out.writer.print("{s}\n", .{unknown});
        }
        if (info.total_supply_cents > 0 or info.total_collateral > 0) {
            var sbuf: [32]u8 = undefined;
            const stats = try std.fmt.allocPrint(a, "Supply: {s}   Locked collateral: {d:.0}   Health: {d:.1}%", .{
                formatCents(&sbuf, info.total_supply_cents), info.total_collateral, info.health_ratio,
            });
            const stats_dim = (zz.Style{}).dim(true).render(a, stats) catch stats;
            try out.writer.print("{s}\n", .{stats_dim});
        }
        if (info.minting_blocked) {
            const warn = "Minting is temporarily blocked by the protocol's volatility protection.";
            const warn_s = (zz.Style{}).fg(.yellow).render(a, warn) catch warn;
            try out.writer.print("{s}\n", .{warn_s});
        }

        // Wallet balance ($), pending shown the moment it's seen. Masked (and its
        // pending note suppressed, so pending funds aren't leaked) while hidden.
        if (act.sc_has_balance) {
            var bbuf: [32]u8 = undefined;
            const bal_plain = if (hide) balance_mask else formatCents(&bbuf, act.sc_balance.confirmed_cents);
            const bal = (zz.Style{}).bold(true).render(a, bal_plain) catch bal_plain;
            var pend: []const u8 = "";
            if (!hide and act.sc_balance.pending_cents != 0) {
                var pbuf2: [32]u8 = undefined;
                const p = try std.fmt.allocPrint(a, "  (+{s} pending)", .{formatCents(&pbuf2, act.sc_balance.pending_cents)});
                pend = (zz.Style{}).bold(true).fg(.yellow).render(a, p) catch p;
            }
            try out.writer.print("\nBalance: {s} {s}{s}\n", .{ bal, sc.symbol, pend });
        }

        // Deposit address (fetched once by the poll; `n` mints a new one).
        // Address RPCs refuse pre-activation, so the row only appears once the
        // feature is live (or an address is already cached).
        if (act.sc_addr_len > 0) {
            const hint = (zz.Style{}).dim(true).render(a, "  (c: copy   n: new address)") catch "";
            try out.writer.print("Address: {s}{s}\n", .{ act.sc_addr_buf[0..act.sc_addr_len], hint });
        } else if (info.active) {
            const fetching = (zz.Style{}).dim(true).render(a, "Address: fetching…") catch "Address: fetching…";
            try out.writer.print("{s}\n", .{fetching});
        }

        // Collateral positions (vaults): amount, tier terms, unlock height, and
        // whether the daemon says it's redeemable now.
        if (act.sc_pos_count > 0) {
            try out.writer.print("\nVaults:\n", .{});
            for (act.sc_pos_buf[0..act.sc_pos_count]) |*p| {
                var abuf: [32]u8 = undefined;
                const amount = formatCents(&abuf, p.amount_cents);
                const terms = if (p.tier < sc.tiers.len)
                    try std.fmt.allocPrint(a, "{s}, {d}% collateral", .{ sc.tiers[p.tier].duration, sc.tiers[p.tier].ratio_pct })
                else
                    try std.fmt.allocPrint(a, "tier {d}", .{p.tier});
                const state = if (p.can_redeem)
                    (zz.Style{}).bold(true).fg(.green).render(a, "redeemable") catch "redeemable"
                else
                    (zz.Style{}).dim(true).render(a, try std.fmt.allocPrint(a, "locked until block {d}", .{p.unlock_height})) catch "locked";
                try out.writer.print("  {s}  ({s})  {s}\n", .{ amount, terms, state });
            }
        }

        // Recent stablecoin transactions, newest-first (cached by the poll).
        if (act.sc_tx_count > 0) {
            try out.writer.print("\nRecent {s} transactions:\n", .{sc.name});
            for (act.sc_tx_buf[0..act.sc_tx_count]) |tx| {
                const glyph = scTxGlyph(a, tx.kind);
                const word = try padCell(a, scTxWord(tx.kind), 8, false);
                const date = try formatBlockTime(a, tx.time);
                var abuf: [32]u8 = undefined;
                const amount = try padCell(a, formatCents(&abuf, tx.amount_cents), 12, true);
                const conf_text = txConfirmationText(a, tx.confirmations);
                try out.writer.print("  {s} {s} {s}   {s}   {s}\n", .{ glyph, word, date, amount, conf_text });
            }
        }

        // Action hint — or why the actions aren't live yet.
        const hint_text: []const u8 = if (info.active)
            "(Enter: mint / send / redeem)"
        else
            "Mint, send and redeem unlock once the feature activates on this network.";
        const hint = (zz.Style{}).dim(true).render(a, hint_text) catch hint_text;
        try out.writer.print("\n{s}", .{hint});

        return out.toOwnedSlice();
    }

    /// The direction glyph for a stablecoin transaction row: ▼/▲ mirror the
    /// coin Transactions tab; a mint is ★ (the wallet created the DD itself,
    /// like a stake/mined reward) and a redeem ◆ (the DD was burned to unlock
    /// collateral — neither sent nor received).
    fn scTxGlyph(a: std.mem.Allocator, kind: models.StablecoinTxKind) []const u8 {
        return switch (kind) {
            .received => (zz.Style{}).bold(true).fg(.green).render(a, "▼") catch "▼",
            .sent => (zz.Style{}).bold(true).fg(.red).render(a, "▲") catch "▲",
            .mint => (zz.Style{}).bold(true).fg(.yellow).render(a, "★") catch "★",
            .redeem => (zz.Style{}).bold(true).fg(.cyan).render(a, "◆") catch "◆",
        };
    }

    /// The category word beside the glyph — spelled out because mint/redeem
    /// aren't obvious from an arrow alone.
    fn scTxWord(kind: models.StablecoinTxKind) []const u8 {
        return switch (kind) {
            .received => "received",
            .sent => "sent",
            .mint => "mint",
            .redeem => "redeem",
        };
    }

    /// True black/white for the QR render — ZigZag's *named* `.black`/
    /// `.white` are `Color.ansi` presets ((0,0,0)/(192,192,192), not pure
    /// white), which would hurt scan contrast.
    const qr_black = zz.Color.hex("#000000");
    const qr_white = zz.Color.hex("#ffffff");
    /// Modules of light border required on all sides by the QR spec — a code
    /// without one often fails to scan at all. This is a correctness
    /// requirement, not polish.
    const qr_quiet_zone: i32 = 4;

    /// Render a `Qr` as ANSI-styled half-block Unicode (`▀`), the standard
    /// "reliable in any terminal" technique (what `qrencode -t ANSIUTF8`/most
    /// terminal QR tools do): pack 2 module-rows per printed row —
    /// foreground = top module's color, background = bottom module's color —
    /// so each character cell reads as one roughly-square QR pixel despite
    /// terminal cells being about 2:1 tall. Includes the mandatory quiet
    /// zone; `Qr.get` already reads out-of-bounds coordinates as light, which
    /// is exactly the quiet zone's color, so no special-casing is needed at
    /// the padded edges (including a trailing unpaired row, since QR sizes
    /// are always odd and the quiet zone is even).
    fn renderQrHalfBlock(a: std.mem.Allocator, qr: qrcode.Qr) ![]const u8 {
        const sz: i32 = qr.size();
        const padded: i32 = sz + qr_quiet_zone * 2;
        var body: []const u8 = "";
        var vy: i32 = 0;
        var first = true;
        while (vy < padded) : (vy += 2) {
            var line: []const u8 = "";
            var vx: i32 = 0;
            while (vx < padded) : (vx += 1) {
                const top_dark = qr.get(vx - qr_quiet_zone, vy - qr_quiet_zone);
                const bottom_dark = qr.get(vx - qr_quiet_zone, vy + 1 - qr_quiet_zone);
                const fg = if (top_dark) qr_black else qr_white;
                const bg = if (bottom_dark) qr_black else qr_white;
                const cell = (zz.Style{}).fg(fg).bg(bg).render(a, "▀") catch "▀";
                line = if (vx == 0) cell else try std.fmt.allocPrint(a, "{s}{s}", .{ line, cell });
            }
            body = if (first) line else try std.fmt.allocPrint(a, "{s}\n{s}", .{ body, line });
            first = false;
        }
        return body;
    }

    /// A loading spinner that matches the sync line: the same braille "puck"
    /// orbiting the `sync_track_cells`-wide track, bold, at the default 10fps.
    /// Used for the Running/Staking/Peers "loading" marks and the install
    /// progress so every animation in the UI reads as the same travelling puck.
    /// Clockwise only — the direction-signals-connectivity trick is the sync
    /// line's alone; here it's just motion. Frames are a comptime constant, so
    /// `setFrames` once at construction is enough (`update` advances the index).
    fn makeSpinner() zz.Spinner {
        var s = zz.Spinner.init();
        s.setFrames(sync_frames_cw);
        s.setStyle((zz.Style{}).bold(true).fg(.cyan).inline_style(true));
        return s;
    }

    /// Renders a status label in the coin's brand colour when its status is
    /// "live" — animating (a spinner) or positive (a green tick / count) — and
    /// in grey (the same `brightBlack` as a wallet's "Unknown") otherwise, so a
    /// stopped/idle/absent status reads as dimmed rather than fully coloured.
    fn statusLabel(a: std.mem.Allocator, brand: zz.Color, text: []const u8, active: bool) []const u8 {
        const c: zz.Color = if (active) brand else .brightBlack;
        return (zz.Style{}).fg(c).render(a, text) catch text;
    }

    // Amount/balance text comes from `money.zig`, so the TUI and the GUI cannot
    // round, group or pad the same figure differently. `formatAmount` keeps a
    // coin's full precision (trailing zeros included) so a zero balance reads as
    // a balance; `trimTrailingZeros` is for the Transactions column, where a
    // stack of full-width figures is noise.
    const formatAmount = money.formatAmount;
    const trimTrailingZeros = money.trimTrailingZeros;

    /// `money.formatBalance` on the caller's arena, so the render paths that
    /// splice it into a larger `allocPrint` keep working unchanged.
    fn formatBalance(a: std.mem.Allocator, value: f64, abbrev: []const u8, decimals: u8) []const u8 {
        var buf: [96]u8 = undefined;
        return a.dupe(u8, money.formatBalance(&buf, value, abbrev, decimals)) catch abbrev;
    }

    /// One styled balance figure for the header corner: `<label>: <amount> <abbrev>`
    /// with the label and abbrev in the coin's brand colour and the amount tinted
    /// by `num_color` (green for Total, yellow for a still-settling Available).
    /// `hide` masks the figure with `balance_mask` (privacy toggle) instead of the
    /// amount, keeping the label and abbrev.
    fn balanceCorner(a: std.mem.Allocator, brand: zz.Color, label: []const u8, value: f64, abbrev: []const u8, num_color: zz.Color, decimals: u8, hide: bool) []const u8 {
        var buf: [64]u8 = undefined;
        const brand_sty = (zz.Style{}).bold(true).fg(brand);
        const lbl = brand_sty.render(a, std.fmt.allocPrint(a, "{s}:", .{label}) catch label) catch label;
        const fig: []const u8 = if (hide) balance_mask else formatAmount(&buf, value, decimals);
        const num = (zz.Style{}).bold(true).fg(num_color).render(a, fig) catch "?";
        const abbr = brand_sty.render(a, abbrev) catch abbrev;
        return std.fmt.allocPrint(a, "{s} {s} {s}", .{ lbl, num, abbr }) catch lbl;
    }

    /// The USD readout beside the balance: the coin's unit price, its 24h move
    /// (green ▲ / red ▼, unsigned percentage — the arrow carries the sign), and
    /// what the holding is worth.
    ///
    /// `hide` (the balance-privacy toggle) masks **only the holding's value**,
    /// not the unit price: the value is derived from the balance, so leaving it
    /// visible would hand back the very figure `hide_balances` conceals (value ÷
    /// price = balance). The unit price is public market data and stays.
    ///
    /// A coin the host lists without a 24h change (Nexa) simply gets no arrow —
    /// `formatChange` returns empty and the segment is skipped.
    fn priceCorner(a: std.mem.Allocator, q: price.Quote, amount: f64, hide: bool) []const u8 {
        var price_buf: [64]u8 = undefined;
        var change_buf: [32]u8 = undefined;
        var value_buf: [64]u8 = undefined;

        const unit = price.formatUsd(&price_buf, q.usd);
        const unit_sty = (zz.Style{}).fg(.brightBlack).render(a, unit) catch unit;

        const change = price.formatChange(&change_buf, q.change_24h);
        const change_sty: []const u8 = if (change.len == 0) "" else blk: {
            const col: zz.Color = switch (price.direction(q.change_24h)) {
                .up => .green,
                .down => .red,
                .flat => .brightBlack,
            };
            break :blk (zz.Style{}).bold(true).fg(col).render(a, change) catch change;
        };

        // Worth of the holding — masked with the balance it's derived from.
        const value: []const u8 = if (hide)
            balance_mask
        else
            price.formatValue(&value_buf, amount, q.usd);
        const value_sty = (zz.Style{}).bold(true).fg(.brightWhite).render(a, value) catch value;

        if (change_sty.len == 0)
            return std.fmt.allocPrint(a, "{s}  ({s})", .{ value_sty, unit_sty }) catch value_sty;
        return std.fmt.allocPrint(a, "{s}  ({s} {s})", .{ value_sty, unit_sty, change_sty }) catch value_sty;
    }

    /// A bold tick (✔, green) or cross (✘, red). The heavy glyphs read bolder
    /// than the thin ✓/✗ at the terminal's fixed cell size.
    fn statusMark(a: std.mem.Allocator, ok: bool) []const u8 {
        const style = (zz.Style{}).bold(true).fg(if (ok) .green else .red);
        const glyph: []const u8 = if (ok) "✔" else "✘";
        return style.render(a, glyph) catch glyph;
    }

    /// The daemon toggle button line, bound to `s`. It reads "[ Start ]" when the
    /// daemon is stopped and "[ Stop ]" when it's running, so the single key always
    /// matches the label. Dimmed with a reason until the coin is installed, and
    /// shows the in-progress label while starting/stopping.
    fn renderDaemonButton(a: std.mem.Allocator, act: *const Activity) []const u8 {
        if (!act.installed) {
            const b = (zz.Style{}).dim(true).render(a, "[ Start ]") catch "[ Start ]";
            return std.fmt.allocPrint(a, "{s}   (install first)", .{b}) catch "[ Start ]";
        }
        return switch (act.daemonState()) {
            .stopped => "[ Start ]   (press s)",
            .starting => "[ Starting… ]",
            .running => "[ Stop ]   (press s)",
            .stopping => "[ Stopping… ]",
        };
    }

    /// The phase-dependent middle of a coin pane. Each coin keeps its own copy,
    /// so navigating away and back shows exactly the stage that coin reached.
    fn renderActivity(a: std.mem.Allocator, act: *const Activity, p: Phase) ![]const u8 {
        switch (p) {
            .idle => {
                // Not yet installed: offer the first-time install on `i`.
                if (!act.installed)
                    return std.fmt.allocPrint(a, "[ Install ]   (press i)\n\nstatus: press i to install", .{});
                // Installed and a newer core is bundled: offer the one-click
                // update on `u` (the confirming stop → reinstall → restart flow).
                // Up to date: no button — the header carries the version and the
                // daemon control sits below; there's nothing to update.
                if (act.update_available)
                    return std.fmt.allocPrint(a, "[ Update ]   (press u)", .{});
                return "";
            },
            .downloading, .extracting => {
                const verb: []const u8 = if (act.updating) "updating" else "installing";
                // Once extraction begins the download is done — peg its bar full.
                const dl = if (p == .extracting)
                    try bar(a, 1, 1)
                else
                    try bar(a, act.dl_cur.load(.monotonic), act.dl_total.load(.monotonic));
                // Extraction streams in one pass with no percentage, so it's a
                // spinner once it starts; a dim placeholder before then.
                const ex: []const u8 = if (p == .extracting) try act.spinner.view(a) else "·";
                return std.fmt.allocPrint(a,
                    \\  Downloading  {s}
                    \\  Extracting   {s}
                    \\
                    \\status: {s}…
                , .{ dl, ex, verb });
            },
            .done => {
                const what: []const u8 = if (act.updating) "update complete" else "install complete";
                return std.fmt.allocPrint(a, "status: ✓ {s}", .{what});
            },
            .failed => return std.fmt.allocPrint(a, "status: ✗ {s}", .{act.err_name}),
        }
    }

    /// Composite the wallet modal box centered over the already-rendered
    /// dashboard `screen`. The box replaces whole rows of its vertical band
    /// (padded left to centre it) — full-row replacement so we never have to
    /// slice the styled background mid-row by visible column. Rows outside the
    /// band pass through unchanged, and the overall row count is preserved (or
    /// extended only if the box is taller than the screen).
    fn renderModalOver(self: *const App, a: std.mem.Allocator, screen: []const u8, width: u16, height: u16) ![]const u8 {
        const box = try self.renderModal(a);
        return overlayBox(a, screen, box, width, height);
    }

    /// Composite a pre-rendered `box` centred over `screen` (full-row replacement,
    /// so the styled background never needs slicing mid-row). Shared by the wallet
    /// modal and the QuickSync prompt.
    fn overlayBox(a: std.mem.Allocator, screen: []const u8, box_in: []const u8, width: u16, height: u16) ![]const u8 {
        var box_raw = box_in;
        if (box_raw.len > 0 and box_raw[box_raw.len - 1] == '\n') box_raw = box_raw[0 .. box_raw.len - 1];

        var box_lines = std.array_list.Managed([]const u8).init(a);
        defer box_lines.deinit();
        var box_w: usize = 0;
        {
            var it = std.mem.splitScalar(u8, box_raw, '\n');
            while (it.next()) |line| {
                try box_lines.append(line);
                box_w = @max(box_w, zz.width(line));
            }
        }
        const box_h = box_lines.items.len;

        var screen_lines = std.array_list.Managed([]const u8).init(a);
        defer screen_lines.deinit();
        {
            var it = std.mem.splitScalar(u8, screen, '\n');
            while (it.next()) |line| try screen_lines.append(line);
        }
        const rows = screen_lines.items.len;

        const w: usize = @max(@as(usize, width), 1);
        const h: usize = @max(@as(usize, height), 1);
        const top: usize = if (h > box_h) (h - box_h) / 2 else 0;
        const left: usize = if (w > box_w) (w - box_w) / 2 else 0;
        const total_rows = @max(rows, top + box_h);

        var out: std.Io.Writer.Allocating = .init(a);
        errdefer out.deinit();
        var r: usize = 0;
        while (r < total_rows) : (r += 1) {
            if (r > 0) try out.writer.writeByte('\n');
            if (r >= top and r < top + box_h) {
                if (left > 0) try out.writer.splatByteAll(' ', left);
                try out.writer.writeAll(box_lines.items[r - top]);
            } else if (r < rows) {
                try out.writer.writeAll(screen_lines.items[r]);
            }
        }
        return out.toOwnedSlice();
    }

    /// Render the wallet modal box (border + title + the current stage's body +
    /// footer hint) as a multi-line string, each row exactly `modal_inner_w + 4`
    /// columns wide. The border wears the coin's brand colour.
    fn renderModal(self: *const App, a: std.mem.Allocator) ![]const u8 {
        const m = self.modal.?;
        const coin = self.coinAt(m.coin_idx) orelse return error.NoCoin;
        const brand = zz.Color.hex(coin.coinColor());
        const inner_w = modal_inner_w;
        const vbar = (zz.Style{}).fg(brand).render(a, "│") catch "│";

        // The file picker brings its own (wider, multi-line) layout that doesn't
        // fit the narrow bordered box, so this stage renders as its own titled
        // block — `renderModalOver` centers whatever we return.
        if (m.stage == .setup_file) {
            var fout: std.Io.Writer.Allocating = .init(a);
            errdefer fout.deinit();
            const heading_txt = if (m.action == .restore_file_offline) "Select your backup wallet.dat to restore" else "Select the key-dump file to import";
            const heading = (zz.Style{}).bold(true).fg(brand).render(a, heading_txt) catch heading_txt;
            try fout.writer.print("{s}\n\n", .{heading});
            const picker = try self.file_picker.view(a);
            try fout.writer.writeAll(picker);
            const fhint = (zz.Style{}).dim(true).render(a, "enter: open/select   backspace: up   ~: home   esc: cancel") catch "";
            try fout.writer.print("\n{s}", .{fhint});
            return fout.toOwnedSlice();
        }

        var out: std.Io.Writer.Allocating = .init(a);
        errdefer out.deinit();

        const title = try std.fmt.allocPrint(a, "{s} Wallet", .{coin.coinName()});
        try modalRule(a, &out.writer, brand, inner_w, "┌", "┐", title);
        try modalRow(&out.writer, vbar, inner_w, "", 0);

        switch (m.stage) {
            .menu, .password => {
                var i: usize = 0;
                while (i < m.option_count) : (i += 1) {
                    const opt = m.options[i];
                    const sel = i == m.sel;
                    const plain = try std.fmt.allocPrint(a, "{s}{s}", .{ if (sel) "❯ " else "  ", opt.label() });
                    const text = if (sel)
                        ((zz.Style{}).bold(true).fg(brand).render(a, plain) catch plain)
                    else
                        plain;
                    try modalRow(&out.writer, vbar, inner_w, text, zz.width(plain));
                }
                if (m.stage == .password) {
                    try modalRow(&out.writer, vbar, inner_w, "", 0);
                    const masked = try self.pw_input.view(a);
                    const text = try std.fmt.allocPrint(a, "Passphrase: {s}", .{masked});
                    try modalRow(&out.writer, vbar, inner_w, text, zz.width("Passphrase: ") + zz.width(masked));
                }
            },
            // External-wallet menu: the create / restore choices, or lock.
            .setup_menu => {
                var i: usize = 0;
                while (i < m.setup_option_count) : (i += 1) {
                    const sel = i == m.setup_sel;
                    const plain = try std.fmt.allocPrint(a, "{s}{s}", .{ if (sel) "❯ " else "  ", m.setup_options[i].label() });
                    const text = if (sel)
                        ((zz.Style{}).bold(true).fg(brand).render(a, plain) catch plain)
                    else
                        plain;
                    try modalRow(&out.writer, vbar, inner_w, text, zz.width(plain));
                }
            },
            // External-wallet password entry (masked). The prompt names the action.
            .setup_password => {
                const prompt = if (m.setup_op == .open or m.setup_op == .restore_file) "Password: " else "New password: ";
                const masked = try self.pw_input.view(a);
                const text = try std.fmt.allocPrint(a, "{s}{s}", .{ prompt, masked });
                try modalRow(&out.writer, vbar, inner_w, text, zz.width(prompt) + zz.width(masked));
                // Opening/restoring an existing wallet accepts a blank password (the
                // wallet may be unencrypted) — say so, since an empty submit is
                // otherwise indistinguishable from "not entered yet".
                if (m.setup_op.allowsEmptyPassword()) {
                    const hint = "Leave blank if the wallet has no password.";
                    const styled = (zz.Style{}).dim(true).render(a, hint) catch hint;
                    try modalRow(&out.writer, vbar, inner_w, styled, zz.width(hint));
                }
                if (m.pw_mismatch) {
                    const warn = "Passwords didn't match — please re-enter.";
                    const styled = (zz.Style{}).fg(.red).render(a, warn) catch warn;
                    try modalRow(&out.writer, vbar, inner_w, styled, zz.width(warn));
                }
            },
            // Re-entry of a new password to confirm it matches before it's set.
            .setup_password_confirm => {
                const prompt = "Confirm password: ";
                const masked = try self.pw_input.view(a);
                const text = try std.fmt.allocPrint(a, "{s}{s}", .{ prompt, masked });
                try modalRow(&out.writer, vbar, inner_w, text, zz.width(prompt) + zz.width(masked));
            },
            // External-wallet seed entry (visible — you're transcribing a phrase).
            // The words are word-wrapped across rows with a live count so a long
            // mnemonic stays inside the box instead of overrunning its right edge.
            .setup_seed_input => {
                // The accepted word counts are per-coin (Monero coins: 25; Ergo's
                // BIP39 mnemonics: 15/12/24), so the prompt and counter reflect what
                // this wallet takes rather than a hard-coded length.
                const counts = if (self.coinAt(m.coin_idx)) |c| c.seedWordCounts() else &[_]usize{25};
                const prompt = if (counts.len == 1)
                    try std.fmt.allocPrint(a, "Enter your {d}-word recovery seed (type or paste):", .{counts[0]})
                else
                    blk: {
                        var cbuf: [64]u8 = undefined;
                        break :blk try std.fmt.allocPrint(a, "Enter your recovery seed — {s} words (type or paste):", .{seed_mod.joinCounts(&cbuf, counts)});
                    };
                try wrapIntoRows(a, &out.writer, vbar, inner_w, prompt, (zz.Style{}));
                try modalRow(&out.writer, vbar, inner_w, "", 0);

                const val = self.seed_input.getValue();
                if (val.len == 0) {
                    const ph = (zz.Style{}).dim(true).render(a, "your words appear here as you type") catch "your words appear here as you type";
                    try modalRow(&out.writer, vbar, inner_w, ph, zz.width("your words appear here as you type"));
                } else {
                    // A trailing block reads as the cursor; it rides along with the
                    // word wrap so it sits right after the last character typed.
                    const with_cursor = try std.fmt.allocPrint(a, "{s}\u{2588}", .{val});
                    try wrapIntoRows(a, &out.writer, vbar, inner_w, with_cursor, (zz.Style{}).fg(brand));
                }

                try modalRow(&out.writer, vbar, inner_w, "", 0);
                const n = countWords(val);
                // "/ C" against the single target when there's one; just the live
                // count when several lengths are valid. Green once it's a valid count.
                const counter = if (counts.len == 1)
                    try std.fmt.allocPrint(a, "{d} / {d} words", .{ n, counts[0] })
                else
                    try std.fmt.allocPrint(a, "{d} words", .{n});
                const cstyle = if (seedCountAccepted(counts, n)) (zz.Style{}).fg(.green) else (zz.Style{}).dim(true);
                const counter_styled = cstyle.render(a, counter) catch counter;
                try modalRow(&out.writer, vbar, inner_w, counter_styled, zz.width(counter));
            },
            // Show the freshly-created mnemonic for the user to write down.
            .setup_seed_show => {
                const wc = countWords(m.seed.slice());
                var hdrbuf: [64]u8 = undefined;
                const hdr = std.fmt.bufPrint(&hdrbuf, "Write down all {d} words, in order:", .{wc}) catch "Write down your recovery words, in order:";
                const hdr_styled = (zz.Style{}).bold(true).fg(.yellow).render(a, hdr) catch hdr;
                try modalRow(&out.writer, vbar, inner_w, hdr_styled, zz.width(hdr));
                try modalRow(&out.writer, vbar, inner_w, "", 0);
                // One numbered word per row so the order (and count) is unambiguous.
                var i: usize = 1;
                while (i <= wc) : (i += 1) {
                    const row = std.fmt.allocPrint(a, "{d:>2}. {s}", .{ i, nthWord(m.seed.slice(), i) }) catch continue;
                    const styled = (zz.Style{}).fg(brand).render(a, row) catch row;
                    try modalRow(&out.writer, vbar, inner_w, styled, zz.width(row));
                }
                try modalRow(&out.writer, vbar, inner_w, "", 0);
                const warn = "Anyone with these words can spend your funds. Lose them and your coins are gone forever — store them offline and never share them.";
                try wrapIntoRows(a, &out.writer, vbar, inner_w, warn, (zz.Style{}).bold(true).fg(.red));
            },
            // Quiz a few words to confirm the user actually wrote the seed down.
            .setup_seed_verify => {
                var introbuf: [48]u8 = undefined;
                const intro = std.fmt.bufPrint(&introbuf, "Confirm your backup ({d} of 3):", .{m.verify_step + 1}) catch "Confirm your backup:";
                try modalRow(&out.writer, vbar, inner_w, intro, zz.width(intro));
                try modalRow(&out.writer, vbar, inner_w, "", 0);
                const val = self.seed_input.getValue();
                const line = std.fmt.allocPrint(a, "Enter word #{d}: {s}\u{2588}", .{ m.verify_pos[m.verify_step], val }) catch "Enter the requested word:";
                try modalRow(&out.writer, vbar, inner_w, (zz.Style{}).fg(brand).render(a, line) catch line, zz.width(line));
                if (m.verify_bad) {
                    const note = "That word doesn't match — check your written copy.";
                    try modalRow(&out.writer, vbar, inner_w, (zz.Style{}).fg(.red).render(a, note) catch note, zz.width(note));
                }
            },
            // Typed confirmation before destroying the existing wallet.
            .setup_replace_confirm => {
                const warn = "This permanently removes the wallet on this node. If its seed isn't backed up, its funds are lost forever.";
                try wrapIntoRows(a, &out.writer, vbar, inner_w, warn, (zz.Style{}).bold(true).fg(.red));
                try modalRow(&out.writer, vbar, inner_w, "", 0);
                const val = self.seed_input.getValue();
                const line = std.fmt.allocPrint(a, "Type {s} to confirm: {s}\u{2588}", .{ replace_confirm_word, val }) catch "Type REPLACE to confirm:";
                try modalRow(&out.writer, vbar, inner_w, line, zz.width(line));
                if (m.replace_bad) {
                    const note = "Didn't match — type it exactly, or esc to cancel.";
                    try modalRow(&out.writer, vbar, inner_w, (zz.Style{}).fg(.red).render(a, note) catch note, zz.width(note));
                }
            },
            // Confirm the offline file restore (wallet.dat swapped with the daemon
            // down). It only bounces a daemon that's actually running — started
            // from a stopped one, the node is left stopped, so don't promise a
            // restart that isn't coming.
            .restore_file_confirm => {
                const running = self.activities[m.coin_idx].daemonState() == .running;
                const warn = if (running)
                    "This replaces the current wallet.dat with the selected backup and restarts the daemon. The existing wallet.dat is kept as a timestamped .bak."
                else
                    "This replaces the current wallet.dat with the selected backup. The existing wallet.dat is kept as a timestamped .bak. Start the daemon afterwards to load it.";
                try wrapIntoRows(a, &out.writer, vbar, inner_w, warn, (zz.Style{}).bold(true).fg(brand));
            },
            .setup_file => unreachable, // handled by the early return above
            .working => try modalRow(&out.writer, vbar, inner_w, "Working…", zz.width("Working…")),
            .result => {
                const sty = (zz.Style{}).fg(if (m.ok) .green else .red);
                try wrapIntoRows(a, &out.writer, vbar, inner_w, m.msg_buf[0..m.msg_len], sty);
            },
        }

        try modalRow(&out.writer, vbar, inner_w, "", 0);
        const hint = switch (m.stage) {
            .menu, .setup_menu => "enter: select   esc: close",
            .password => "enter: confirm   esc: cancel",
            .setup_password => "enter: next   esc: cancel",
            .setup_password_confirm => "enter: confirm   esc: cancel",
            .setup_seed_input => "enter: next   esc: cancel",
            .setup_seed_show => "press any key once you've written them down",
            .setup_seed_verify => "enter: check   esc: cancel",
            .setup_replace_confirm => "enter: confirm   esc: cancel",
            .restore_file_confirm => "enter: restore   esc: cancel",
            .setup_file => unreachable,
            .working => "please wait…",
            .result => "press any key to close",
        };
        const hint_styled = (zz.Style{}).dim(true).render(a, hint) catch hint;
        try modalRow(&out.writer, vbar, inner_w, hint_styled, zz.width(hint));
        try modalRule(a, &out.writer, brand, inner_w, "└", "┘", "");

        return out.toOwnedSlice();
    }

    /// Render the QuickSync prompt box (border + title + the current stage's body +
    /// footer hint), each row `modal_inner_w + 4` columns wide, bordered in the
    /// coin's brand colour — matching the wallet modal's look.
    fn renderQuickSyncModal(self: *const App, a: std.mem.Allocator) ![]const u8 {
        const m = self.qs_modal.?;
        const coin = self.coinAt(m.coin_idx) orelse return error.NoCoin;
        const act = &self.activities[m.coin_idx];
        const brand = zz.Color.hex(coin.coinColor());
        const inner_w = modal_inner_w;
        const vbar = (zz.Style{}).fg(brand).render(a, "│") catch "│";

        var out: std.Io.Writer.Allocating = .init(a);
        errdefer out.deinit();

        const title = try std.fmt.allocPrint(a, "{s} — {s}", .{ coin.coinName(), m.name });
        try modalRule(a, &out.writer, brand, inner_w, "┌", "┐", title);
        try modalRow(&out.writer, vbar, inner_w, "", 0);

        switch (m.stage) {
            .confirm => {
                try wrapIntoRows(a, &out.writer, vbar, inner_w, m.detail, (zz.Style{}));
                // What the speed costs, for an accelerator that hands over work
                // the node would otherwise do itself. Amber rather than dim: it's
                // a caution the user is meant to weigh, not fine print. (The GUI
                // sets it apart with an accent bar; in a terminal the colour is
                // the whole vocabulary.)
                if (m.trust_note.len != 0) {
                    try modalRow(&out.writer, vbar, inner_w, "", 0);
                    try wrapIntoRows(a, &out.writer, vbar, inner_w, m.trust_note, (zz.Style{}).fg(.yellow));
                }
                // A resumable accelerator may already have bytes on disk from an
                // interrupted attempt — say so, so "Yes" doesn't read as
                // committing to the whole download again.
                if (m.resume_from > 0) {
                    const note = try std.fmt.allocPrint(a, "{d} MB already downloaded — this will continue from there.", .{m.resume_from / (1000 * 1000)});
                    try modalRow(&out.writer, vbar, inner_w, "", 0);
                    try wrapIntoRows(a, &out.writer, vbar, inner_w, note, (zz.Style{}).dim(true));
                }
                try modalRow(&out.writer, vbar, inner_w, "", 0);
                const yes = if (m.resume_from > 0) "Yes — resume the download" else "Yes — use it";
                const labels = [_][]const u8{ yes, "No — sync normally" };
                for (labels, 0..) |lbl, i| {
                    const sel = i == m.sel;
                    const plain = try std.fmt.allocPrint(a, "{s}{s}", .{ if (sel) "❯ " else "  ", lbl });
                    const text = if (sel)
                        ((zz.Style{}).bold(true).fg(brand).render(a, plain) catch plain)
                    else
                        plain;
                    try modalRow(&out.writer, vbar, inner_w, text, zz.width(plain));
                }
            },
            .downloading => {
                // A snapshot runs two long phases back to back; naming the one in
                // flight stops the bar looking like it restarted at zero.
                const step = if (act.qs_phase.load(.monotonic) == @intFromEnum(install_mod.Phase.extract))
                    "Unpacking…"
                else
                    "Downloading…";
                try modalRow(&out.writer, vbar, inner_w, step, zz.width(step));
                try modalRow(&out.writer, vbar, inner_w, "", 0);
                const dlbar = try bar(a, act.dl_cur.load(.monotonic), act.dl_total.load(.monotonic));
                try modalRow(&out.writer, vbar, inner_w, dlbar, zz.width(dlbar));
            },
            .paused => {
                const lead = "Paused";
                try modalRow(&out.writer, vbar, inner_w, lead, zz.width(lead));
                try modalRow(&out.writer, vbar, inner_w, "", 0);
                const dlbar = try bar(a, act.dl_cur.load(.monotonic), act.dl_total.load(.monotonic));
                try modalRow(&out.writer, vbar, inner_w, dlbar, zz.width(dlbar));
                try modalRow(&out.writer, vbar, inner_w, "", 0);
                try wrapIntoRows(a, &out.writer, vbar, inner_w, "What's downloaded is kept — resuming continues from here, now or on a later run.", (zz.Style{}).dim(true));
            },
            .failed => {
                const plain = try std.fmt.allocPrint(a, "{s} failed:", .{m.name});
                const lead = (zz.Style{}).fg(.red).render(a, plain) catch plain;
                try modalRow(&out.writer, vbar, inner_w, lead, zz.width(plain));
                try wrapIntoRows(a, &out.writer, vbar, inner_w, m.msg_buf[0..m.msg_len], (zz.Style{}).dim(true));
            },
        }

        try modalRow(&out.writer, vbar, inner_w, "", 0);
        const hint = switch (m.stage) {
            .confirm => "enter: select   esc: cancel",
            // A chain snapshot can run for an hour, so a resumable transfer says
            // how to stop it; one that can't resume has nothing to pause into.
            .downloading => if (m.resumable) "p / esc: pause   (quitting is safe too — this resumes)" else "please wait…",
            .paused => "enter: resume   esc: start without it",
            .failed => "enter: start without it   esc: cancel",
        };
        const hint_styled = (zz.Style{}).dim(true).render(a, hint) catch hint;
        try modalRow(&out.writer, vbar, inner_w, hint_styled, zz.width(hint));
        try modalRule(a, &out.writer, brand, inner_w, "└", "┘", "");

        return out.toOwnedSlice();
    }

    /// Render the first-start prune prompt box. Mirrors `renderQuickSyncModal`'s
    /// chrome: a brand-coloured rule + rows. `menu` lists the presets plus a
    /// "Custom…" row; `custom` shows a GB entry field.
    fn renderPruneModal(self: *const App, a: std.mem.Allocator) ![]const u8 {
        const m = self.prune_modal.?;
        const coin = self.coinAt(m.coin_idx) orelse return error.NoCoin;
        const brand = zz.Color.hex(coin.coinColor());
        const inner_w = modal_inner_w;
        const vbar = (zz.Style{}).fg(brand).render(a, "│") catch "│";

        var out: std.Io.Writer.Allocating = .init(a);
        errdefer out.deinit();

        const title = try std.fmt.allocPrint(a, "{s} — blockchain storage", .{coin.coinName()});
        try modalRule(a, &out.writer, brand, inner_w, "┌", "┐", title);
        try modalRow(&out.writer, vbar, inner_w, "", 0);

        switch (m.stage) {
            .menu => {
                const prompt = if (coin.pruning()) |pr| pr.prompt else "";
                try wrapIntoRows(a, &out.writer, vbar, inner_w, prompt, (zz.Style{}));
                try modalRow(&out.writer, vbar, inner_w, "", 0);
                // The coin's own presets, then a trailing "Custom…" row where the
                // coin takes a free-form size (`.size_mib`).
                for (m.presets, 0..) |preset, i| {
                    try pruneMenuRow(a, &out.writer, vbar, inner_w, brand, preset.label, i == m.sel);
                }
                if (m.allow_custom)
                    try pruneMenuRow(a, &out.writer, vbar, inner_w, brand, "Custom…", m.sel == m.customRow());
            },
            .custom => {
                const field = try self.prune_input.view(a);
                const text = try std.fmt.allocPrint(a, "Prune to: {s} GB", .{field});
                try modalRow(&out.writer, vbar, inner_w, text, zz.width("Prune to: ") + zz.width(field) + zz.width(" GB"));
                if (m.bad_input) {
                    const warn = "Enter a whole number of GB (1 or more).";
                    const styled = (zz.Style{}).fg(.red).render(a, warn) catch warn;
                    try modalRow(&out.writer, vbar, inner_w, styled, zz.width(warn));
                }
            },
        }

        try modalRow(&out.writer, vbar, inner_w, "", 0);
        const hint = switch (m.stage) {
            .menu => "enter: select   esc: cancel",
            .custom => "enter: confirm   esc: back",
        };
        const hint_styled = (zz.Style{}).dim(true).render(a, hint) catch hint;
        try modalRow(&out.writer, vbar, inner_w, hint_styled, zz.width(hint));
        try modalRule(a, &out.writer, brand, inner_w, "└", "┘", "");

        return out.toOwnedSlice();
    }

    /// One selectable row of the prune menu: a `❯` marker + brand-bold label when
    /// highlighted, plain otherwise. Mirrors the QuickSync/wallet menu rows.
    fn pruneMenuRow(a: std.mem.Allocator, w: *std.Io.Writer, vbar: []const u8, inner_w: usize, brand: zz.Color, label: []const u8, sel: bool) !void {
        const plain = try std.fmt.allocPrint(a, "{s}{s}", .{ if (sel) "❯ " else "  ", label });
        const text = if (sel)
            ((zz.Style{}).bold(true).fg(brand).render(a, plain) catch plain)
        else
            plain;
        try modalRow(w, vbar, inner_w, text, zz.width(plain));
    }

    /// Render the Send prompt box. Mirrors `renderPruneModal`'s chrome
    /// (brand-coloured rule + rows) and its text-input-stage shape
    /// (`self.xxx_input.view(a)` embedded in a row); the confirm stage shows
    /// the **full, untruncated address** — the one typo safety net a machine
    /// can't provide.
    fn renderSendModal(self: *const App, a: std.mem.Allocator) ![]const u8 {
        const m = self.send_modal.?;
        const coin = self.coinAt(m.coin_idx) orelse return error.NoCoin;
        const act = &self.activities[m.coin_idx];
        const brand = zz.Color.hex(coin.coinColor());
        const inner_w = modal_inner_w;
        const vbar = (zz.Style{}).fg(brand).render(a, "│") catch "│";

        var out: std.Io.Writer.Allocating = .init(a);
        errdefer out.deinit();

        const staking = m.mode == .stake;
        const title = try std.fmt.allocPrint(a, "{s} — {s}", .{ coin.coinName(), if (staking) "stake" else "send" });
        try modalRule(a, &out.writer, brand, inner_w, "┌", "┐", title);
        try modalRow(&out.writer, vbar, inner_w, "", 0);

        switch (m.stage) {
            .address => {
                const field = try self.send_addr_input.view(a);
                const text = try std.fmt.allocPrint(a, "To: {s}", .{field});
                try modalRow(&out.writer, vbar, inner_w, text, zz.width("To: ") + zz.width(field));
            },
            .amount => {
                const field = try self.send_amount_input.view(a);
                const text = try std.fmt.allocPrint(a, "Amount: {s}", .{field});
                try modalRow(&out.writer, vbar, inner_w, text, zz.width("Amount: ") + zz.width(field));
                try modalRow(&out.writer, vbar, inner_w, "", 0);
                const balance = if (self.hide_balances)
                    try std.fmt.allocPrint(a, "{s} {s}", .{ balance_mask, coin.coinNameAbbrev() })
                else
                    formatBalance(a, act.balance_avail, coin.coinNameAbbrev(), coin.balanceDecimals());
                const avail = try std.fmt.allocPrint(a, "Available: {s}", .{balance});
                const avail_styled = (zz.Style{}).dim(true).render(a, avail) catch avail;
                try modalRow(&out.writer, vbar, inner_w, avail_styled, zz.width(avail));
                // Staking locks funds for a term — say so before an amount is
                // committed, with the coin's own description of the deal.
                if (staking and coin.stakeHint().len > 0) {
                    try modalRow(&out.writer, vbar, inner_w, "", 0);
                    try wrapIntoRows(a, &out.writer, vbar, inner_w, coin.stakeHint(), (zz.Style{}).dim(true));
                }
                if (m.bad_input) {
                    const warn = "Enter a positive amount.";
                    const styled = (zz.Style{}).fg(.red).render(a, warn) catch warn;
                    try modalRow(&out.writer, vbar, inner_w, styled, zz.width(warn));
                }
            },
            .confirm => {
                const amount_text = std.mem.trim(u8, self.send_amount_input.getValue(), " \t");
                const amount = std.fmt.parseFloat(f64, amount_text) catch 0;
                var buf: [64]u8 = undefined;
                const detail = if (staking)
                    try std.fmt.allocPrint(a, "Stake {s} {s}? {s}", .{
                        formatAmount(&buf, amount, coin.balanceDecimals()), coin.coinNameAbbrev(), coin.stakeHint(),
                    })
                else blk: {
                    // The full, untruncated address — deliberately not shortened.
                    const addr = self.send_addr_input.getValue();
                    break :blk try std.fmt.allocPrint(a, "Send {s} {s} to {s}? This cannot be undone.", .{
                        formatAmount(&buf, amount, coin.balanceDecimals()), coin.coinNameAbbrev(), addr,
                    });
                };
                try wrapIntoRows(a, &out.writer, vbar, inner_w, detail, (zz.Style{}));
                try modalRow(&out.writer, vbar, inner_w, "", 0);
                const labels = if (staking)
                    [_][]const u8{ "Yes — stake it", "No — cancel" }
                else
                    [_][]const u8{ "Yes — send it", "No — cancel" };
                for (labels, 0..) |lbl, i| {
                    const sel = i == m.sel;
                    const plain = try std.fmt.allocPrint(a, "{s}{s}", .{ if (sel) "❯ " else "  ", lbl });
                    const text = if (sel)
                        ((zz.Style{}).bold(true).fg(brand).render(a, plain) catch plain)
                    else
                        plain;
                    try modalRow(&out.writer, vbar, inner_w, text, zz.width(plain));
                }
            },
            .working => {
                const busy = if (staking) "Staking…" else "Sending…";
                try modalRow(&out.writer, vbar, inner_w, busy, zz.width(busy));
            },
            .result => {
                const lead_plain = if (m.ok)
                    (if (staking) "Staked. Txid:" else "Sent. Txid:")
                else
                    (if (staking) "Stake failed:" else "Send failed:");
                const lead = if (m.ok)
                    ((zz.Style{}).fg(.green).render(a, lead_plain) catch lead_plain)
                else
                    ((zz.Style{}).fg(.red).render(a, lead_plain) catch lead_plain);
                try modalRow(&out.writer, vbar, inner_w, lead, zz.width(lead_plain));
                try wrapIntoRows(a, &out.writer, vbar, inner_w, m.msg_buf[0..m.msg_len], (zz.Style{}).dim(true));
            },
        }

        try modalRow(&out.writer, vbar, inner_w, "", 0);
        const hint = switch (m.stage) {
            .address => "enter: next   esc: cancel",
            .amount => "enter: next   esc: cancel",
            .confirm => "enter: select   esc: cancel",
            .working => "please wait…",
            .result => "press any key to close",
        };
        const hint_styled = (zz.Style{}).dim(true).render(a, hint) catch hint;
        try modalRow(&out.writer, vbar, inner_w, hint_styled, zz.width(hint));
        try modalRule(a, &out.writer, brand, inner_w, "└", "┘", "");

        return out.toOwnedSlice();
    }

    /// Render the Mining prompt box. Mirrors `renderSendModal`'s chrome
    /// (brand-coloured rule + rows); the entry stage collects a CPU thread
    /// count instead of an address/amount.
    fn renderMiningModal(self: *const App, a: std.mem.Allocator) ![]const u8 {
        const m = self.mining_modal.?;
        const coin = self.coinAt(m.coin_idx) orelse return error.NoCoin;
        const brand = zz.Color.hex(coin.coinColor());
        const inner_w = modal_inner_w;
        const vbar = (zz.Style{}).fg(brand).render(a, "│") catch "│";

        var out: std.Io.Writer.Allocating = .init(a);
        errdefer out.deinit();

        const title = try std.fmt.allocPrint(a, "{s} — mining", .{coin.coinName()});
        try modalRule(a, &out.writer, brand, inner_w, "┌", "┐", title);
        try modalRow(&out.writer, vbar, inner_w, "", 0);

        switch (m.stage) {
            .threads => {
                const field = try self.mining_input.view(a);
                const text = try std.fmt.allocPrint(a, "CPU threads: {s}", .{field});
                try modalRow(&out.writer, vbar, inner_w, text, zz.width("CPU threads: ") + zz.width(field));
                try modalRow(&out.writer, vbar, inner_w, "", 0);
                const cpus = try std.fmt.allocPrint(a, "This machine has {d} CPU threads. Mining uses real CPU and power; leave some threads free for other work.", .{mining.cpuThreadCount()});
                try wrapIntoRows(a, &out.writer, vbar, inner_w, cpus, (zz.Style{}).dim(true));
                if (m.bad_input) {
                    const warn = try std.fmt.allocPrint(a, "Enter a number from 1 to {d}.", .{mining.cpuThreadCount()});
                    const styled = (zz.Style{}).fg(.red).render(a, warn) catch warn;
                    try modalRow(&out.writer, vbar, inner_w, styled, zz.width(warn));
                }
            },
            .confirm_stop => {
                try wrapIntoRows(a, &out.writer, vbar, inner_w, "Stop mining?", (zz.Style{}));
                try modalRow(&out.writer, vbar, inner_w, "", 0);
                const labels = [_][]const u8{ "Yes — stop it", "No — keep mining" };
                for (labels, 0..) |lbl, i| {
                    const sel = i == m.sel;
                    const plain = try std.fmt.allocPrint(a, "{s}{s}", .{ if (sel) "❯ " else "  ", lbl });
                    const text = if (sel)
                        ((zz.Style{}).bold(true).fg(brand).render(a, plain) catch plain)
                    else
                        plain;
                    try modalRow(&out.writer, vbar, inner_w, text, zz.width(plain));
                }
            },
            .working => {
                const busy = if (m.starting) "Starting the miner…" else "Stopping the miner…";
                try modalRow(&out.writer, vbar, inner_w, busy, zz.width(busy));
            },
            .result => {
                // Success closes the prompt from the reap, so only failures land
                // here — but keep both tints in case that ever changes.
                const lead_plain = if (m.ok)
                    "Done."
                else
                    (if (m.starting) "Couldn't start mining:" else "Couldn't stop mining:");
                const lead = if (m.ok)
                    ((zz.Style{}).fg(.green).render(a, lead_plain) catch lead_plain)
                else
                    ((zz.Style{}).fg(.red).render(a, lead_plain) catch lead_plain);
                try modalRow(&out.writer, vbar, inner_w, lead, zz.width(lead_plain));
                try wrapIntoRows(a, &out.writer, vbar, inner_w, m.msg_buf[0..m.msg_len], (zz.Style{}).dim(true));
            },
        }

        try modalRow(&out.writer, vbar, inner_w, "", 0);
        const hint = switch (m.stage) {
            .threads => "enter: start   esc: cancel",
            .confirm_stop => "enter: select   esc: cancel",
            .working => "please wait…",
            .result => "press any key to close",
        };
        const hint_styled = (zz.Style{}).dim(true).render(a, hint) catch hint;
        try modalRow(&out.writer, vbar, inner_w, hint_styled, zz.width(hint));
        try modalRule(a, &out.writer, brand, inner_w, "└", "┘", "");

        return out.toOwnedSlice();
    }

    /// Render the stablecoin (DigiDollar) prompt box. Mirrors
    /// `renderSendModal`'s chrome; the action menu fans out into the mint /
    /// send / redeem flows. Every confirm spells the full details out — the
    /// mint one includes the estimated DGB collateral, since locking
    /// collateral for months or years is exactly the choice that must never
    /// ride on a typo.
    fn renderStablecoinModal(self: *const App, a: std.mem.Allocator) ![]const u8 {
        const m = self.sc_modal.?;
        const coin = self.coinAt(m.coin_idx) orelse return error.NoCoin;
        const sc = coin.stablecoin() orelse return error.NoCoin;
        const act = &self.activities[m.coin_idx];
        const brand = zz.Color.hex(coin.coinColor());
        const inner_w = modal_inner_w;
        const vbar = (zz.Style{}).fg(brand).render(a, "│") catch "│";

        var out: std.Io.Writer.Allocating = .init(a);
        errdefer out.deinit();

        const title = try std.fmt.allocPrint(a, "{s} — {s}", .{ coin.coinName(), sc.name });
        try modalRule(a, &out.writer, brand, inner_w, "┌", "┐", title);
        try modalRow(&out.writer, vbar, inner_w, "", 0);

        switch (m.stage) {
            .menu => {
                const labels = [_][]const u8{
                    "Mint — lock collateral, create new DD",
                    "Send — pay DD to an address",
                    "Redeem — burn DD, unlock collateral",
                };
                for (labels, 0..) |lbl, i| {
                    const sel = i == m.menu_sel;
                    const plain = try std.fmt.allocPrint(a, "{s}{s}", .{ if (sel) "❯ " else "  ", lbl });
                    const text = if (sel)
                        ((zz.Style{}).bold(true).fg(brand).render(a, plain) catch plain)
                    else
                        plain;
                    try modalRow(&out.writer, vbar, inner_w, text, zz.width(plain));
                }
            },
            .address => {
                const field = try self.send_addr_input.view(a);
                const text = try std.fmt.allocPrint(a, "To: {s}", .{field});
                try modalRow(&out.writer, vbar, inner_w, text, zz.width("To: ") + zz.width(field));
            },
            .amount => {
                const field = try self.send_amount_input.view(a);
                const text = try std.fmt.allocPrint(a, "Amount (USD): {s}", .{field});
                try modalRow(&out.writer, vbar, inner_w, text, zz.width("Amount (USD): ") + zz.width(field));
                try modalRow(&out.writer, vbar, inner_w, "", 0);
                if (m.mode == .mint) {
                    var lo: [32]u8 = undefined;
                    var hi: [32]u8 = undefined;
                    const bounds = try std.fmt.allocPrint(a, "Mint between {s} and {s}. The fee is paid in {s}.", .{
                        formatCents(&lo, sc.min_mint_cents), formatCents(&hi, sc.max_mint_cents), coin.coinNameAbbrev(),
                    });
                    try wrapIntoRows(a, &out.writer, vbar, inner_w, bounds, (zz.Style{}).dim(true));
                } else {
                    var bbuf: [32]u8 = undefined;
                    const bal_fig: []const u8 = if (self.hide_balances) balance_mask else formatCents(&bbuf, act.sc_balance.confirmed_cents);
                    const avail = try std.fmt.allocPrint(a, "Available: {s} {s}. The fee is paid in {s}.", .{
                        bal_fig, sc.symbol, coin.coinNameAbbrev(),
                    });
                    try wrapIntoRows(a, &out.writer, vbar, inner_w, avail, (zz.Style{}).dim(true));
                }
                if (m.bad_input) {
                    const warn = "Enter a valid USD amount (up to 2 decimals, within the bounds).";
                    const styled = (zz.Style{}).fg(.red).render(a, warn) catch warn;
                    try wrapIntoRows(a, &out.writer, vbar, inner_w, styled, (zz.Style{}));
                }
            },
            .tier => {
                const head = "Lock tier — longer locks need less collateral:";
                try wrapIntoRows(a, &out.writer, vbar, inner_w, head, (zz.Style{}).dim(true));
                try modalRow(&out.writer, vbar, inner_w, "", 0);
                for (sc.tiers) |t| {
                    const sel = t.tier == m.tier_sel;
                    const plain = try std.fmt.allocPrint(a, "{s}{s} — {d}% collateral", .{
                        if (sel) "❯ " else "  ",
                        t.duration,
                        t.ratio_pct,
                    });
                    const text = if (sel)
                        ((zz.Style{}).bold(true).fg(brand).render(a, plain) catch plain)
                    else
                        plain;
                    try modalRow(&out.writer, vbar, inner_w, text, zz.width(plain));
                }
            },
            .estimating => {
                const busy = "Estimating the collateral required…";
                try modalRow(&out.writer, vbar, inner_w, busy, zz.width(busy));
            },
            .position => {
                const count = redeemableCount(act);
                if (count == 0) {
                    const none = "No redeemable vaults yet — a vault can be redeemed once its timelock expires.";
                    try wrapIntoRows(a, &out.writer, vbar, inner_w, none, (zz.Style{}).dim(true));
                } else {
                    const head = "Redeem which vault? (the full amount is redeemed)";
                    try wrapIntoRows(a, &out.writer, vbar, inner_w, head, (zz.Style{}).dim(true));
                    try modalRow(&out.writer, vbar, inner_w, "", 0);
                    var i: usize = 0;
                    while (redeemablePositionAt(act, i)) |p| : (i += 1) {
                        const sel = i == m.pos_sel;
                        var abuf: [32]u8 = undefined;
                        const terms = if (p.tier < sc.tiers.len) sc.tiers[p.tier].duration else "?";
                        const plain = try std.fmt.allocPrint(a, "{s}{s}  ({s} lock)", .{
                            if (sel) "❯ " else "  ",
                            formatCents(&abuf, p.amount_cents),
                            terms,
                        });
                        const text = if (sel)
                            ((zz.Style{}).bold(true).fg(brand).render(a, plain) catch plain)
                        else
                            plain;
                        try modalRow(&out.writer, vbar, inner_w, text, zz.width(plain));
                    }
                }
            },
            .confirm => {
                var abuf: [32]u8 = undefined;
                const amount = formatCents(&abuf, m.cents);
                const detail: []const u8 = switch (m.mode) {
                    .mint => blk: {
                        const terms = if (m.tier_sel < sc.tiers.len) sc.tiers[m.tier_sel].duration else "?";
                        if (m.estimate >= 0) {
                            break :blk try std.fmt.allocPrint(a, "Mint {s} of {s}, locking about {d:.2} {s} as collateral for {s}? The collateral cannot be unlocked before the timelock expires. This cannot be undone.", .{
                                amount, sc.name, m.estimate, coin.coinNameAbbrev(), terms,
                            });
                        }
                        break :blk try std.fmt.allocPrint(a, "Mint {s} of {s}, locking {s} as collateral for {s}? (The exact collateral couldn't be estimated — the daemon computes and enforces it.) This cannot be undone.", .{
                            amount, sc.name, coin.coinNameAbbrev(), terms,
                        });
                    },
                    // The full, untruncated address — deliberately not shortened.
                    .send => try std.fmt.allocPrint(a, "Send {s} of {s} to {s}? This cannot be undone.", .{
                        amount, sc.name, self.send_addr_input.getValue(),
                    }),
                    .redeem => try std.fmt.allocPrint(a, "Redeem {s} from this vault? The {s} is burned and its {s} collateral returns to your wallet.", .{
                        amount, sc.name, coin.coinNameAbbrev(),
                    }),
                };
                try wrapIntoRows(a, &out.writer, vbar, inner_w, detail, (zz.Style{}));
                try modalRow(&out.writer, vbar, inner_w, "", 0);
                const yes: []const u8 = switch (m.mode) {
                    .mint => "Yes — mint it",
                    .send => "Yes — send it",
                    .redeem => "Yes — redeem it",
                };
                const labels = [_][]const u8{ yes, "No — cancel" };
                for (labels, 0..) |lbl, i| {
                    const sel = i == m.sel;
                    const plain = try std.fmt.allocPrint(a, "{s}{s}", .{ if (sel) "❯ " else "  ", lbl });
                    const text = if (sel)
                        ((zz.Style{}).bold(true).fg(brand).render(a, plain) catch plain)
                    else
                        plain;
                    try modalRow(&out.writer, vbar, inner_w, text, zz.width(plain));
                }
            },
            .working => {
                const busy: []const u8 = switch (m.mode) {
                    .mint => "Minting…",
                    .send => "Sending…",
                    .redeem => "Redeeming…",
                };
                try modalRow(&out.writer, vbar, inner_w, busy, zz.width(busy));
            },
            .result => {
                const lead_plain: []const u8 = if (m.ok) switch (m.mode) {
                    .mint => "Minted. Txid:",
                    .send => "Sent. Txid:",
                    .redeem => "Redeemed. Txid:",
                } else switch (m.mode) {
                    .mint => "Mint failed:",
                    .send => "Send failed:",
                    .redeem => "Redeem failed:",
                };
                const lead = if (m.ok)
                    ((zz.Style{}).fg(.green).render(a, lead_plain) catch lead_plain)
                else
                    ((zz.Style{}).fg(.red).render(a, lead_plain) catch lead_plain);
                try modalRow(&out.writer, vbar, inner_w, lead, zz.width(lead_plain));
                try wrapIntoRows(a, &out.writer, vbar, inner_w, m.msg_buf[0..m.msg_len], (zz.Style{}).dim(true));
            },
        }

        try modalRow(&out.writer, vbar, inner_w, "", 0);
        const hint = switch (m.stage) {
            .menu, .tier, .position => "enter: select   esc: cancel",
            .address, .amount => "enter: next   esc: cancel",
            .confirm => "enter: select   esc: cancel",
            .estimating, .working => "please wait…",
            .result => "press any key to close",
        };
        const hint_styled = (zz.Style{}).dim(true).render(a, hint) catch hint;
        try modalRow(&out.writer, vbar, inner_w, hint_styled, zz.width(hint));
        try modalRule(a, &out.writer, brand, inner_w, "└", "┘", "");

        return out.toOwnedSlice();
    }

    /// Render the update-confirm prompt box. Mirrors `renderQuickSyncModal`'s
    /// chrome (brand-coloured rule + rows), but it's confirm-only — the actual
    /// stop/install/restart progress shows in the main pane afterwards.
    fn renderUpdateModal(self: *const App, a: std.mem.Allocator) ![]const u8 {
        const m = self.update_modal.?;
        const coin = self.coinAt(m.coin_idx) orelse return error.NoCoin;
        const brand = zz.Color.hex(coin.coinColor());
        const inner_w = modal_inner_w;
        const vbar = (zz.Style{}).fg(brand).render(a, "│") catch "│";

        var out: std.Io.Writer.Allocating = .init(a);
        errdefer out.deinit();

        const title = try std.fmt.allocPrint(a, "{s} — {s}", .{ coin.coinName(), if (m.reinstall) "Reinstall" else "Update" });
        try modalRule(a, &out.writer, brand, inner_w, "┌", "┐", title);
        try modalRow(&out.writer, vbar, inner_w, "", 0);

        const from = m.from();
        const detail = if (from.len > 0)
            try std.fmt.allocPrint(a, "A newer version is available: {s} → {s}. Updating stops the daemon, installs the new version, and restarts it.", .{ from, coin.coreVersion() })
        else
            try std.fmt.allocPrint(a, "Reinstall the bundled version {s}? This stops the daemon, installs it, and restarts it.", .{coin.coreVersion()});
        try wrapIntoRows(a, &out.writer, vbar, inner_w, detail, (zz.Style{}));
        try modalRow(&out.writer, vbar, inner_w, "", 0);

        const labels = if (m.reinstall)
            [_][]const u8{ "Yes — reinstall now", "No — cancel" }
        else
            [_][]const u8{ "Yes — update now", "No — not now" };
        for (labels, 0..) |lbl, i| {
            const sel = i == m.sel;
            const plain = try std.fmt.allocPrint(a, "{s}{s}", .{ if (sel) "❯ " else "  ", lbl });
            const text = if (sel)
                ((zz.Style{}).bold(true).fg(brand).render(a, plain) catch plain)
            else
                plain;
            try modalRow(&out.writer, vbar, inner_w, text, zz.width(plain));
        }

        try modalRow(&out.writer, vbar, inner_w, "", 0);
        const hint_text = "enter: select   esc: cancel";
        const hint = (zz.Style{}).dim(true).render(a, hint_text) catch hint_text;
        try modalRow(&out.writer, vbar, inner_w, hint, zz.width(hint_text));
        try modalRule(a, &out.writer, brand, inner_w, "└", "┘", "");

        return out.toOwnedSlice();
    }

    /// Joins the left nav column and the right detail block side by side. Home
    /// is pinned to the top row; the coins below it are windowed to `nav_rows`
    /// total nav rows (0 = unlimited) via `navWindow`, so the selected coin is
    /// always on screen even when the terminal is shorter than the coin list.
    /// When everything fits the output is identical to the unwindowed render.
    fn renderTwoPane(a: std.mem.Allocator, selected: usize, updates: []const bool, right: []const u8, nav_rows: usize) ![]const u8 {
        // Marker (2 cells) + the label column. Empty rows pad to this full width.
        const col_w = nav_col_w;
        var out: std.Io.Writer.Allocating = .init(a);
        errdefer out.deinit();

        // Lay the nav rows out first: Home, an optional "more above" indicator,
        // the visible slice of coins, and an optional "more below" indicator.
        var desc: [entries.len + 2]NavRow = undefined;
        const desc_n = navRows(selected, nav_rows, &desc);

        var rit = std.mem.splitScalar(u8, right, '\n');
        var i: usize = 0;
        while (true) {
            const have_left = i < desc_n;
            const r = rit.next();
            if (!have_left and r == null) break;

            if (have_left) switch (desc[i]) {
                // Scroll indicators: a dim arrow row where the coin list
                // continues past the window, in the blank marker column's
                // alignment. The glyphs are multi-byte, so padding measures
                // their visible width rather than byte length.
                .more_above, .more_below => {
                    const text: []const u8 = if (desc[i] == .more_above) "↑ ···" else "↓ ···";
                    const hint = (zz.Style{}).fg(zz.Color.hex(nav_dim_color)).render(a, text) catch text;
                    try out.writer.print("  {s}", .{hint});
                    const used = zz.width(text);
                    if (nav_label_w > used) try out.writer.splatByteAll(' ', nav_label_w - used);
                    try out.writer.splatByteAll(' ', nav_trail_w);
                },
                .entry => |ei| {
                    const e = entries[ei];
                    const is_sel = ei == selected;
                    // The selection marker is a bold, brand-coloured arrow so the
                    // current coin stands out at a glance; unselected rows get blank
                    // padding of the same visible width (2 cells) to keep alignment.
                    const marker: []const u8 = if (is_sel)
                        (zz.Style{}).bold(true).fg(entryColor(e)).render(a, "❯ ") catch "❯ "
                    else if (ei < updates.len and updates[ei])
                        // A coin with an available update gets a yellow ⬆ in the marker
                        // column (the selected coin shows its arrow + the detail badge
                        // instead, so it isn't doubled up).
                        (zz.Style{}).bold(true).fg(.yellow).render(a, "⬆ ") catch "⬆ "
                    else
                        "  ";
                    // Write the label, then pad to the fixed label width with trailing
                    // spaces so the `│` separator stays aligned regardless of label
                    // length (the colour ANSI codes are zero-width). Home is special:
                    // "BoxWallet" in the brand colour, the version in the default
                    // colour. Coins are one styled label (brand when selected, else
                    // grey).
                    var used: usize = undefined;
                    if (e == .home) {
                        const brand = (zz.Style{}).bold(is_sel).fg(entryColor(.home)).render(a, home_brand_text) catch home_brand_text;
                        try out.writer.print("{s}{s}{s}", .{ marker, brand, home_version_text });
                        used = home_brand_text.len + home_version_text.len;
                    } else if (e == .reddcoin and is_sel) {
                        // ReddCoin's two-tone wordmark when selected: "Redd" in the
                        // brand red, "Coin" in near-white. Unselected, it greys out
                        // like every other coin (handled by the generic branch below).
                        const name = ReddCoin.coin_name;
                        const head = name[0..ReddCoin.wordmark_split];
                        const tail = name[ReddCoin.wordmark_split..];
                        const redd = (zz.Style{}).bold(true).fg(zz.Color.hex(ReddCoin.coin_color)).render(a, head) catch head;
                        const cn = (zz.Style{}).bold(true).fg(zz.Color.hex(ReddCoin.coin_color_alt)).render(a, tail) catch tail;
                        try out.writer.print("{s}{s}{s}", .{ marker, redd, cn });
                        used = name.len;
                    } else if (e == .bitcoinz and is_sel) {
                        // BitcoinZ's two-tone wordmark when selected: "Bitcoin" in
                        // white, "Z" in the brand gold. Unselected, it greys out
                        // like every other coin (handled by the generic branch below).
                        const name = BitcoinZ.coin_name;
                        const head = name[0..BitcoinZ.wordmark_split];
                        const tail = name[BitcoinZ.wordmark_split..];
                        const bc = (zz.Style{}).bold(true).fg(zz.Color.hex(BitcoinZ.wordmark_head_color)).render(a, head) catch head;
                        const z = (zz.Style{}).bold(true).fg(zz.Color.hex(BitcoinZ.coin_color)).render(a, tail) catch tail;
                        try out.writer.print("{s}{s}{s}", .{ marker, bc, z });
                        used = name.len;
                    } else if (e == .spiderbyte and is_sel) {
                        // SpiderByte's two-tone wordmark when selected: "Spider" in
                        // white, "Byte" in the brand colour. Unselected, it greys out
                        // like every other coin (handled by the generic branch below).
                        const name = SpiderByte.coin_name;
                        const head = name[0..SpiderByte.wordmark_split];
                        const tail = name[SpiderByte.wordmark_split..];
                        const sp = (zz.Style{}).bold(true).fg(zz.Color.hex(SpiderByte.wordmark_head_color)).render(a, head) catch head;
                        const bt = (zz.Style{}).bold(true).fg(zz.Color.hex(SpiderByte.coin_color)).render(a, tail) catch tail;
                        try out.writer.print("{s}{s}{s}", .{ marker, sp, bt });
                        used = name.len;
                    } else {
                        const text = entryLabel(e);
                        const label = (zz.Style{}).bold(is_sel).fg(navColor(e, is_sel)).render(a, text) catch text;
                        try out.writer.print("{s}{s}", .{ marker, label });
                        used = text.len;
                    }
                    // Closing marker: the current row is bracketed `❯ Bitcoin ❮`, the
                    // `❮` one space past the end of the *label* so it mirrors the
                    // opening arrow instead of floating at the far edge of the
                    // column. The row is then padded out to the same total width
                    // (label column + trailing column) so the `│` stays aligned.
                    if (is_sel) {
                        const close = (zz.Style{}).bold(true).fg(entryColor(e)).render(a, " ❮") catch " ❮";
                        try out.writer.print("{s}", .{close});
                        if (nav_label_w > used) try out.writer.splatByteAll(' ', nav_label_w - used);
                    } else {
                        if (nav_label_w > used) try out.writer.splatByteAll(' ', nav_label_w - used);
                        try out.writer.splatByteAll(' ', nav_trail_w);
                    }
                },
            } else {
                try out.writer.splatByteAll(' ', col_w);
            }
            try out.writer.print(" │ {s}\n", .{r orelse ""});
            i += 1;
        }

        return out.toOwnedSlice();
    }
};

/// Keep at most `max_h` newline-terminated rows of `screen`. ZigZag's renderer
/// never clips vertically either: a frame taller than the terminal scrolls the
/// top rows (Home + nav) off-screen. Trimming the tall detail pane here keeps
/// the whole frame within the terminal instead. Rows count `\n`s, matching
/// `renderWithLog`'s accounting. `max_h == 0` (height unknown) is a no-op, and
/// a screen that already fits comes back untouched — no copy either way.
fn clipToHeight(screen: []const u8, max_h: usize) []const u8 {
    if (max_h == 0) return screen;
    var rows: usize = 0;
    for (screen, 0..) |c, idx| {
        if (c == '\n') {
            rows += 1;
            if (rows == max_h) return screen[0 .. idx + 1];
        }
    }
    return screen;
}

/// Clip every logical line of `screen` to `max_w` visible columns. ZigZag's
/// renderer (`program.zig`) prints each line verbatim and never clips, so a line
/// wider than the terminal wraps onto a second physical row — pushing everything
/// below it down and scrolling the top (header + nav) off-screen. Clipping here
/// keeps the invariant the renderer relies on: one logical line == one physical
/// row. ANSI escapes are zero-width and pass through untouched; a line that's
/// actually truncated gets a reset appended so a cut mid-colour doesn't bleed.
/// `max_w == 0` (width unknown) is a no-op. The common case (nothing overflows)
/// returns `screen` without copying.
fn clipToWidth(a: std.mem.Allocator, screen: []const u8, max_w: u16) []const u8 {
    if (max_w == 0) return screen;

    var overflows = false;
    var probe = std.mem.splitScalar(u8, screen, '\n');
    while (probe.next()) |line| {
        if (zz.width(line) > max_w) {
            overflows = true;
            break;
        }
    }
    if (!overflows) return screen;

    var out: std.Io.Writer.Allocating = .init(a);
    var lines = std.mem.splitScalar(u8, screen, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) out.writer.writeByte('\n') catch return screen;
        first = false;
        clipLineInto(&out.writer, line, max_w) catch return screen;
    }
    return out.toOwnedSlice() catch screen;
}

/// Write `line` to `w`, stopping once `max_w` visible columns have been emitted.
/// CSI escape sequences (`ESC[ … final`) copy through verbatim (they cost no
/// columns); other bytes advance the visible count by their display width. A
/// truncated line is closed with an ANSI reset so styling doesn't leak past it.
fn clipLineInto(w: *std.Io.Writer, line: []const u8, max_w: u16) !void {
    if (zz.width(line) <= max_w) {
        try w.writeAll(line);
        return;
    }
    var i: usize = 0;
    var vis: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b) {
            // Copy the escape sequence whole. CSI is `ESC [ params… final`, where
            // the final byte is 0x40–0x7E; non-CSI escapes just carry the ESC.
            const start = i;
            i += 1;
            if (i < line.len and line[i] == '[') {
                i += 1;
                while (i < line.len and (line[i] < 0x40 or line[i] > 0x7e)) : (i += 1) {}
                if (i < line.len) i += 1;
            }
            try w.writeAll(line[start..i]);
            continue;
        }
        const blen = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        const end = @min(i + blen, line.len);
        const cw = zz.width(line[i..end]);
        if (vis + cw > max_w) break;
        try w.writeAll(line[i..end]);
        vis += cw;
        i = end;
    }
    try w.writeAll("\x1b[0m");
}

/// Write one content row of the wallet modal: `│ <text><pad> │`, where `text`
/// occupies `vis` visible columns (it may carry zero-width ANSI styling) and is
/// padded with spaces to `inner_w`. `vbar` is the pre-styled side bar.
fn modalRow(w: *std.Io.Writer, vbar: []const u8, inner_w: usize, text: []const u8, vis: usize) !void {
    try w.writeAll(vbar);
    try w.writeByte(' ');
    try w.writeAll(text);
    if (inner_w > vis) try w.splatByteAll(' ', inner_w - vis);
    try w.writeByte(' ');
    try w.writeAll(vbar);
    try w.writeByte('\n');
}

/// Greedy word-wrap `msg` into modal content rows of `inner_w` columns, each
/// styled with `sty`. Used for the result message and the freshly-generated seed
/// — both are plain text that may run past one row. No-op for an empty `msg`.
fn wrapIntoRows(a: std.mem.Allocator, w: *std.Io.Writer, vbar: []const u8, inner_w: usize, msg: []const u8, sty: zz.Style) !void {
    var start: usize = 0;
    while (start < msg.len) {
        var end = @min(start + inner_w, msg.len);
        if (end < msg.len) {
            // Back up to the last space so words aren't split mid-token.
            var b = end;
            while (b > start and msg[b] != ' ') b -= 1;
            if (b > start) end = b;
        }
        const seg = std.mem.trim(u8, msg[start..end], " ");
        const styled = sty.render(a, seg) catch seg;
        try modalRow(w, vbar, inner_w, styled, zz.width(seg));
        start = end;
        while (start < msg.len and msg[start] == ' ') start += 1;
    }
}

const countWords = seed_mod.countWords;
const nthWord = seed_mod.nthWord;
const pickVerifyPositions = seed_mod.pickVerifyPositions;

/// The word the user must type to confirm the destructive "Replace wallet" action.
const replace_confirm_word = "REPLACE";

/// Write a top/bottom border row of the modal in the brand colour: the corner
/// glyphs `left`/`right` with `inner_w + 2` box-drawing dashes between them. A
/// non-empty `title` is inlined into the top rule (`┌─ Title ───┐`).
fn modalRule(a: std.mem.Allocator, w: *std.Io.Writer, brand: zz.Color, inner_w: usize, left: []const u8, right: []const u8, title: []const u8) !void {
    const total = inner_w + 2;
    var line: std.Io.Writer.Allocating = .init(a);
    defer line.deinit();
    try line.writer.writeAll(left);
    var used: usize = 0;
    if (title.len > 0) {
        try line.writer.print("─ {s} ", .{title});
        used = 3 + zz.width(title);
    }
    while (used < total) : (used += 1) try line.writer.writeAll("─");
    try line.writer.writeAll(right);

    const styled = (zz.Style{}).fg(brand).render(a, line.written()) catch line.written();
    try w.writeAll(styled);
    try w.writeByte('\n');
}

/// Disk/memory "warning" threshold: at or above this used %, the capacity bar
/// turns amber. `usage_red` is the more urgent step, turning it red.
const usage_amber = 75.0;
const usage_red = 90.0;

/// The fill colour for a capacity bar at `current`/`total`: brand-green while
/// there's comfortable headroom, amber from `usage_amber`%, red from
/// `usage_red`%. An unknown total (0) reads as empty/0%, so it stays green.
fn usageColor(current: u64, total: u64) zz.Color {
    if (total == 0) return zz.Color.hex(app_color);
    const pct = @as(f64, @floatFromInt(current)) / @as(f64, @floatFromInt(total)) * 100.0;
    if (pct >= usage_red) return .red;
    if (pct >= usage_amber) return .yellow;
    return zz.Color.hex(app_color);
}

/// A progress bar in the app's brand colour — for "fuller is better" axes (the
/// download progress and the headers/blocks sync).
fn bar(a: std.mem.Allocator, current: u64, total: u64) ![]const u8 {
    return coloredBar(a, current, total, zz.Color.hex(app_color));
}

// Duration / block-date / storage text lives in `timefmt.zig`, formatting into a
// caller buffer rather than allocating — these run once per frame per readout,
// and CLAUDE.md prefers a bounded buffer to an allocation on that path. The
// wrappers keep the allocator shape the render sites already use.
fn formatDurationApprox(a: std.mem.Allocator, secs: i64) ![]const u8 {
    var buf: [timefmt.max_len]u8 = undefined;
    return a.dupe(u8, timefmt.duration(&buf, secs));
}

fn formatBehind(a: std.mem.Allocator, secs: i64) ![]const u8 {
    var buf: [timefmt.max_len]u8 = undefined;
    return a.dupe(u8, timefmt.behind(&buf, secs));
}

fn formatBlockTime(a: std.mem.Allocator, unix_secs: i64) ![]const u8 {
    var buf: [timefmt.max_len]u8 = undefined;
    return a.dupe(u8, timefmt.blockTime(&buf, unix_secs));
}

fn formatStorageGB(a: std.mem.Allocator, bytes: u64) []const u8 {
    var buf: [timefmt.max_len]u8 = undefined;
    return a.dupe(u8, timefmt.storageGB(&buf, bytes)) catch "0.00 GB";
}

/// A capacity bar whose fill warns as it fills — for "fuller is worse" axes
/// (disk and memory). Green with headroom, amber past 75%, red past 90%, so a
/// nearly-full disk or stressed machine reads at a glance.
fn usageBar(a: std.mem.Allocator, current: u64, total: u64) ![]const u8 {
    return coloredBar(a, current, total, usageColor(current, total));
}

/// Render a single ZigZag progress bar for `current`/`total`, tinting the
/// filled portion `fill`. Shared by `bar` (brand colour) and `usageBar`
/// (threshold colour).
fn coloredBar(a: std.mem.Allocator, current: u64, total: u64, fill: zz.Color) ![]const u8 {
    var p = zz.Progress.init();
    p.setWidth(30);
    // Tint the filled portion as requested (ZigZag defaults the fill to cyan).
    p.full_style = p.full_style.fg(fill);
    // Guard against a zero total (unknown length): clamp the denominator off zero
    // to avoid a divide, and force the value to 0 so the bar sits empty at 0%.
    // (Without zeroing the value, a non-zero `current` over the clamped-to-1
    // denominator reads as a huge percentage and renders a false 100%.)
    p.setTotal(@floatFromInt(@max(total, 1)));
    p.setValue(@floatFromInt(if (total == 0) 0 else current));
    // Render our own percentage instead of ZigZag's whole-number "{d:.0}%": we
    // want one decimal place (e.g. "42.4%") for in-progress values, but plain
    // "0%"/"100%" at the endpoints so the common cases stay tidy.
    p.show_percent = false;
    const bar_str = try p.view(a);
    const pct = p.percent();
    const pct_str = if (pct <= 0)
        try std.fmt.allocPrint(a, " 0%", .{})
    else if (pct >= 100)
        try std.fmt.allocPrint(a, " 100%", .{})
    else
        try std.fmt.allocPrint(a, " {d:.1}%", .{pct});
    const pct_styled = try p.percent_style.render(a, pct_str);
    return std.mem.concat(a, u8, &.{ bar_str, pct_styled });
}

test "cycleTab steps through the detail tabs and wraps at both ends" {
    // Forward from each tab (a coin with neither capability tab — Mining and
    // DigiDollar don't exist for it, so the cycle skips straight over both).
    try std.testing.expectEqual(DetailTab.transactions, cycleTab(.home, 1, .{}));
    try std.testing.expectEqual(DetailTab.receive, cycleTab(.transactions, 1, .{}));
    try std.testing.expectEqual(DetailTab.send, cycleTab(.receive, 1, .{}));
    try std.testing.expectEqual(DetailTab.settings, cycleTab(.send, 1, .{}));
    // Forward off the last tab wraps to the first, past the absent capability tabs.
    try std.testing.expectEqual(DetailTab.home, cycleTab(.settings, 1, .{}));
    // Backward off the first tab wraps to the last, past the absent capability tabs.
    try std.testing.expectEqual(DetailTab.settings, cycleTab(.home, -1, .{}));
    try std.testing.expectEqual(DetailTab.send, cycleTab(.settings, -1, .{}));
}

test "cycleTab includes the Mining tab only for coins that mine" {
    // A mining coin (Nerva) cycles settings → mining → home in both directions.
    try std.testing.expectEqual(DetailTab.mining, cycleTab(.settings, 1, .{ .mining = true }));
    try std.testing.expectEqual(DetailTab.home, cycleTab(.mining, 1, .{ .mining = true }));
    try std.testing.expectEqual(DetailTab.mining, cycleTab(.home, -1, .{ .mining = true }));
    try std.testing.expectEqual(DetailTab.settings, cycleTab(.mining, -1, .{ .mining = true }));
}

test "cycleTab includes the DigiDollar tab only for stablecoin coins" {
    // A stablecoin coin (DigiByte) cycles settings → digidollar → home, skipping
    // the absent Mining tab in both directions.
    try std.testing.expectEqual(DetailTab.digidollar, cycleTab(.settings, 1, .{ .stablecoin = true }));
    try std.testing.expectEqual(DetailTab.home, cycleTab(.digidollar, 1, .{ .stablecoin = true }));
    try std.testing.expectEqual(DetailTab.digidollar, cycleTab(.home, -1, .{ .stablecoin = true }));
    try std.testing.expectEqual(DetailTab.settings, cycleTab(.digidollar, -1, .{ .stablecoin = true }));
}

test "numbered tab jumps are positional over the visible strip" {
    // Plain coin: 1-5, nothing on 6.
    try std.testing.expectEqual(DetailTab.home, visibleTabAt(0, .{}).?);
    try std.testing.expectEqual(DetailTab.settings, visibleTabAt(4, .{}).?);
    try std.testing.expect(visibleTabAt(5, .{}) == null);
    // Mining coin: 6 = Mining.
    try std.testing.expectEqual(DetailTab.mining, visibleTabAt(5, .{ .mining = true }).?);
    // Stablecoin coin: 6 = DigiDollar (contiguous — no dead 6 where Mining
    // would sit).
    try std.testing.expectEqual(DetailTab.digidollar, visibleTabAt(5, .{ .stablecoin = true }).?);
    try std.testing.expect(visibleTabAt(6, .{ .stablecoin = true }) == null);
    // Hint ranges follow the same counts.
    try std.testing.expectEqual(@as(usize, 5), visibleTabCount(.{}));
    try std.testing.expectEqual(@as(usize, 6), visibleTabCount(.{ .stablecoin = true }));
    try std.testing.expectEqual(@as(usize, 6), visibleTabCount(.{ .mining = true }));
}

test "redeemablePositionAt walks only the redeemable vaults, in cache order" {
    var act: Activity = .{};
    act.sc_pos_count = 3;
    act.sc_pos_buf[0] = .{ .amount_cents = 100, .can_redeem = false };
    act.sc_pos_buf[1] = .{ .amount_cents = 200, .can_redeem = true };
    act.sc_pos_buf[2] = .{ .amount_cents = 300, .can_redeem = true };
    act.sc_pos_buf[1].setId("aa");
    act.sc_pos_buf[2].setId("bb");

    try std.testing.expectEqual(@as(usize, 2), redeemableCount(&act));
    try std.testing.expectEqual(@as(i64, 200), redeemablePositionAt(&act, 0).?.amount_cents);
    try std.testing.expectEqualStrings("bb", redeemablePositionAt(&act, 1).?.id());
    try std.testing.expect(redeemablePositionAt(&act, 2) == null);
}

test "usageColor steps green → amber → red at the 75/90 thresholds" {
    const green = zz.Color.hex(app_color);
    // Comfortable headroom and the boundary just below warning stay brand-green.
    try std.testing.expectEqual(green, usageColor(0, 100));
    try std.testing.expectEqual(green, usageColor(74, 100));
    // 75% and up (but below 90%) is amber; 90% and up is red.
    try std.testing.expectEqual(zz.Color.yellow, usageColor(75, 100));
    try std.testing.expectEqual(zz.Color.yellow, usageColor(89, 100));
    try std.testing.expectEqual(zz.Color.red, usageColor(90, 100));
    try std.testing.expectEqual(zz.Color.red, usageColor(100, 100));
    // An unknown total (empty bar) is treated as 0% → green, never a false red.
    try std.testing.expectEqual(green, usageColor(500, 0));
}

test "bar with an unknown total (0) renders empty, not a false 100%" {
    // `bar` allocates intermediate strings and is called against an arena in the
    // UI, so use one here too rather than leak-checking the throwaway pieces.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A large `current` over an unknown (zero) total must read 0%, not 100%: a
    // node loads its local headers from disk before the network tip is known, and
    // the denominator is clamped off zero to avoid a divide — so the value has to
    // be forced to 0 or the clamp would read as a huge (≥100%) percentage.
    const out = try bar(a, 500_000, 0);
    try std.testing.expect(std.mem.indexOf(u8, out, " 0%") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "100%") == null);
}

test "action log renders in the bottom pane, sized to log_visible_lines" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    app.logf("Nexa: {s}", .{"installing…"});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const term_height: u16 = 24;
    const out = try app.renderWithLog(arena.allocator(), 80, term_height, "TOP\n");

    // The separator bar and the logged line both appear below the top content.
    try std.testing.expect(std.mem.indexOf(u8, out, "Log") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "installing…") != null);
    // The "Nexa" tag is tinted in its brand colour, so it no longer sits bare
    // against the colon — the same styled span appears verbatim in the output.
    const nexa_tag = (zz.Style{}).fg(zz.Color.hex(Nexa.coin_color)).render(arena.allocator(), "Nexa") catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, out, nexa_tag) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Nexa: installing…") == null);

    // The whole view is exactly `term_height` rows (no trailing newline, so the
    // renderer doesn't scroll the top line off-screen): `term_height` segments
    // means `term_height - 1` separators. The log pane (separator plus
    // `log_visible_lines` rows) is pinned to the bottom.
    try std.testing.expectEqual(@as(usize, term_height - 1), std.mem.count(u8, out, "\n"));
    try std.testing.expect(out[out.len - 1] != '\n');
    var lines = std.mem.splitScalar(u8, out, '\n');
    var bar_idx: ?usize = null;
    var idx: usize = 0;
    while (lines.next()) |line| : (idx += 1) {
        if (std.mem.indexOf(u8, line, "Log") != null) bar_idx = idx;
    }
    // The bar is the first of the pane's `log_pane_rows` rows, so it lands that
    // many rows up from the terminal's last row.
    try std.testing.expectEqual(@as(usize, term_height - App.log_pane_rows), bar_idx.?);

    // `l` toggles the pane: while hidden, `view` returns the top content alone.
    app.log_visible = false;
    try std.testing.expect(!app.log_visible);
}

test "logTagColor matches the leading coin/BoxWallet tag, nothing else" {
    // A coin tag is the coin name up to (not including) the colon.
    const coin_hit = logTagColor("Divi: starting daemon…").?;
    try std.testing.expectEqual(@as(usize, "Divi".len), coin_hit.len);
    try std.testing.expectEqual(entryColor(.divi), coin_hit.col);

    // The app tag is "BoxWallet", tinted in the brand colour.
    const app_hit = logTagColor("BoxWallet: up to date (v0.0.0)").?;
    try std.testing.expectEqual(@as(usize, home_brand_text.len), app_hit.len);
    try std.testing.expectEqual(zz.Color.hex(app_color), app_hit.col);

    // No tag (no colon, or an unknown word) leaves the line plain.
    try std.testing.expect(logTagColor("no tag here") == null);
    try std.testing.expect(logTagColor("Dogecoin: not a registered coin") == null);
}

test "refreshUpdateState flags an update when the marker trails the bundled version" {
    const allocator = std.testing.allocator;
    var epic: Epic = .{};
    const c = epic.coin(); // bundled core_version is "4.0.3"
    const root = "test-update-detect-root";

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().deleteTree(threaded.io(), root) catch {};
    defer std.Io.Dir.cwd().deleteTree(threaded.io(), root) catch {};

    var act: Activity = .{};

    // Not installed → no update prompt, regardless of any marker.
    act.installed = false;
    act.refreshUpdateState(allocator, c, root);
    try std.testing.expect(!act.update_available);

    // Installed but no marker (legacy/manual install) → treated as up to date, not
    // a nag: we don't know its version yet (learned when the daemon next runs).
    act.installed = true;
    act.refreshUpdateState(allocator, c, root);
    try std.testing.expect(!act.update_available);
    try std.testing.expectEqualStrings("", act.installedVersion());

    // Marker older than the bundled 4.0.3 → update available, version surfaced.
    try install_mod.writeVersionMarker(allocator, root, c.daemonFile(), "4.0.2");
    act.refreshUpdateState(allocator, c, root);
    try std.testing.expect(act.update_available);
    try std.testing.expectEqualStrings("4.0.2", act.installedVersion());

    // Marker equal to the bundled version → up to date.
    try install_mod.writeVersionMarker(allocator, root, c.daemonFile(), "4.0.3");
    act.refreshUpdateState(allocator, c, root);
    try std.testing.expect(!act.update_available);

    // Marker newer than the bundle (e.g. after a downgrade of BoxWallet) → not an
    // update; we never offer to install an older version.
    try install_mod.writeVersionMarker(allocator, root, c.daemonFile(), "4.1.0");
    act.refreshUpdateState(allocator, c, root);
    try std.testing.expect(!act.update_available);
}

test "versionMismatch warns when the running daemon isn't the bundled version" {
    const set = struct {
        fn marker(x: *Activity, v: []const u8) void {
            @memcpy(x.installed_version_buf[0..v.len], v);
            x.installed_version_len = v.len;
        }
        fn reported(x: *Activity, v: []const u8) void {
            @memcpy(x.version_buf[0..v.len], v);
            x.version_len = v.len;
        }
    };

    var act: Activity = .{};

    // Nothing known → nothing to assert (no warning on a coin we've never polled).
    try std.testing.expect(!act.versionMismatch("0.3.0.0"));

    // The case this exists for: the daemon reports no version over RPC (Nerva), so
    // the marker — stamped by probing the binary — stands in for it. v0.2.2.0 against
    // a pinned v0.3.0.0 must warn, which is what silently didn't happen before.
    set.marker(&act, "0.2.2.0");
    try std.testing.expectEqualStrings("0.2.2.0", act.effectiveVersion());
    try std.testing.expect(act.versionMismatch("0.3.0.0"));

    // A daemon that *does* report its version over RPC takes precedence over the
    // marker — it's the ground truth for what's actually running.
    set.reported(&act, "0.3.0.0");
    try std.testing.expectEqualStrings("0.3.0.0", act.effectiveVersion());
    try std.testing.expect(!act.versionMismatch("0.3.0.0"));

    // A version that merely spells differently is not a mismatch: Nexa's
    // CLIENT_VERSION decodes to "2.0.0" while the coin pins "2.0.0.0". Warning here
    // would put a permanent false alarm on every Nexa install.
    set.reported(&act, "2.0.0");
    try std.testing.expect(!act.versionMismatch("2.0.0.0"));

    // Salvium's letter suffix likewise agrees with its pinned "1.1.3c".
    set.reported(&act, "1.1.3c");
    try std.testing.expect(!act.versionMismatch("1.1.3c"));
}

test "awaitingStatus animates only before the first poll of an installed coin" {
    var act: Activity = .{};

    // Not installed → nothing to wait for (the daemon can't be running).
    act.installed = false;
    try std.testing.expect(!act.awaitingStatus());

    // Installed, stopped, no poll yet → animate ("loading").
    act.installed = true;
    try std.testing.expect(act.awaitingStatus());

    // First poll reaped → status resolved, animation stops.
    act.poll_completed = true;
    try std.testing.expect(!act.awaitingStatus());

    // A daemon known to be running is never "awaiting", poll flag aside.
    act.poll_completed = false;
    act.daemon.store(@intFromEnum(DaemonState.running), .release);
    try std.testing.expect(!act.awaitingStatus());
}

test "setDaemonErr keeps the first non-empty stderr line, trimmed and bounded" {
    var act: Activity = .{};

    // A leading blank line is skipped; the actionable line is kept whole (it must
    // survive intact, since assertion/lock messages carry their detail at the end).
    act.setDaemonErr("\n  divid: chainparamsbase.cpp:91: BaseParams(): Assertion `globalChainBaseParams' failed.\nAborted\n");
    try std.testing.expectEqualStrings(
        "divid: chainparamsbase.cpp:91: BaseParams(): Assertion `globalChainBaseParams' failed.",
        act.daemon_err,
    );

    // Blank stderr leaves the reason empty so runDaemon can fall back to the
    // launcher error name.
    var blank: Activity = .{};
    blank.setDaemonErr("   \n\t\n");
    try std.testing.expectEqual(@as(usize, 0), blank.daemon_err.len);

    // An over-long line is truncated to the buffer, never overruns it.
    var long: Activity = .{};
    const huge = "x" ** (long.daemon_err_buf.len + 50);
    long.setDaemonErr(huge);
    try std.testing.expectEqual(long.daemon_err_buf.len, long.daemon_err.len);
}

test "pickWalletError surfaces the wallet process's failure line" {
    // A wrong password: the error-like line wins over routine startup chatter, with
    // any leading epee timestamp stripped.
    try std.testing.expectEqualStrings(
        "Error: invalid password",
        pickWalletError("Loading wallet...\n2026-07-21 09:10:11.512 Error: invalid password\n"),
    );

    // A corrupt / unreadable wallet file: the last error-like line is chosen even
    // when it lands after other output.
    try std.testing.expectEqualStrings(
        "failed to load wallet: file I/O error",
        pickWalletError("opening wallet\nsome note\nfailed to load wallet: file I/O error\n"),
    );

    // No obvious marker: fall back to the last non-empty line rather than nothing.
    try std.testing.expectEqualStrings(
        "wallet closed",
        pickWalletError("starting\nwallet closed\n\n"),
    );

    // Empty capture yields an empty pick, so the caller keeps the generic message.
    try std.testing.expectEqual(@as(usize, 0), pickWalletError("   \n\t\n").len);

    // Zano simplewallet dumps its options help after the real failure on a bad
    // open; the `--seed-doctor` description ("…doing back up(typo, wrong words
    // order, missing word)…") matches "wrong" and lands last, but must not mask
    // the actual "failed to load wallet" reason above it.
    try std.testing.expectEqualStrings(
        "failed to load wallet: invalid password",
        pickWalletError(
            "loading wallet\n" ++
                "failed to load wallet: invalid password\n" ++
                "  --seed-doctor            Experimental: if your seed is not working for recovery this is\n" ++
                "                           likely because you've made a mistake whene you were doing back\n" ++
                "                           up(typo, wrong words order, missing word).\n",
        ),
    );
}

test "debug.log helpers strip the timestamp and pick the root-cause line" {
    // A real bitcoin-style timestamp prefix is stripped to the bare message.
    try std.testing.expectEqualStrings(
        ": Incorrect or no genesis block found. Wrong datadir for network?.",
        stripLogTimestamp("2026-06-08 14:55:44 : Incorrect or no genesis block found. Wrong datadir for network?."),
    );
    // A line without the prefix is returned untouched.
    try std.testing.expectEqualStrings("plain line", stripLogTimestamp("plain line"));

    // An epee-style timestamp's fractional seconds are consumed too, so the
    // reason doesn't lead with an orphaned ".165".
    try std.testing.expectEqualStrings(
        "ERROR\tException in main! Failed to initialize p2p server.",
        stripLogTimestamp("2026-07-13 19:07:04.165\tERROR\tException in main! Failed to initialize p2p server."),
    );

    try std.testing.expect(containsIgnoreCase("the ABORTED run", "aborted"));
    try std.testing.expect(!containsIgnoreCase("all good", "aborted"));

    // The exact shape of nexad's failure tail: a benign electrum warning early,
    // the genuine root cause mid-way, then the consequence + shutdown noise. The
    // picker must skip the benign warning and the generic "Aborted… Exiting."
    // line in favour of the datadir root cause.
    const tail =
        \\2026-06-08 14:55:44 Opened LevelDB successfully
        \\2026-06-08 14:55:44 Electrum NOT STARTED: Error Cannot find electrum executable at /home/x/.boxwallet/rostrum.  On platforms unsupported by Rostrum this may be benign.
        \\2026-06-08 14:55:44 init message: Loading block index...
        \\2026-06-08 14:55:44 : Incorrect or no genesis block found. Wrong datadir for network?.
        \\
        \\Do you want to rebuild the block database now?
        \\2026-06-08 14:55:44 Aborted block database rebuild. Exiting.
        \\2026-06-08 14:55:44 Shutdown: In progress...
        \\2026-06-08 14:55:44 Shutdown: done
    ;
    try std.testing.expectEqualStrings(
        ": Incorrect or no genesis block found. Wrong datadir for network?.",
        pickDebugLogError(tail),
    );

    // With no root-cause line, a generic error/abort line is picked over noise.
    try std.testing.expectEqualStrings(
        "Aborted. Exiting.",
        pickDebugLogError("loading\nAborted. Exiting.\nShutdown: done\n"),
    );

    // Nothing error-like → last non-empty line as a fallback.
    try std.testing.expectEqualStrings("all done", pickDebugLogError("starting\nall done\n"));
}

test "termMessage renders every Term variant as a short reason" {
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("exited with code 1", termMessage(&buf, .{ .exited = 1 }));
    try std.testing.expectEqualStrings("exited during startup", termMessage(&buf, .{ .unknown = 7 }));
    // POSIX only. `std.posix.SIG` is non-void on Windows too (libc defines a
    // cut-down set), so the old `!= void` guard compiled the branch there and then
    // failed on `SIG.KILL`, which Windows has no member for — the whole offline
    // test binary wouldn't build on Windows because of it.
    if (@import("builtin").os.tag != .windows) {
        try std.testing.expectEqualStrings(
            "killed by signal 9",
            termMessage(&buf, .{ .signal = std.posix.SIG.KILL }),
        );
        try std.testing.expectEqualStrings(
            "stopped by signal 19",
            termMessage(&buf, .{ .stopped = std.posix.SIG.STOP }),
        );
    }
}

test "parsePresyncPercentBp extracts the latest presync percentage as basis points" {
    // A single presync line → its percentage in basis points (7.44% → 744).
    try std.testing.expectEqual(
        @as(?u32, 744),
        parsePresyncPercentBp("2026-06-30 07:30:43 Pre-synchronizing blockheaders, height: 1759996 (~7.44%)\n"),
    );

    // The freshest line wins when several are present (presync climbs over time).
    const tail =
        \\2026-06-30 07:29:10 Pre-synchronizing blockheaders, height: 1219996 (~5.11%)
        \\2026-06-30 07:29:49 New outbound-full-relay v1 peer connected: version: 70019
        \\2026-06-30 07:30:43 Pre-synchronizing blockheaders, height: 1759996 (~7.44%)
        \\2026-06-30 07:30:50 Sent Dandelion discovery hash to peer=18
    ;
    try std.testing.expectEqual(@as(?u32, 744), parsePresyncPercentBp(tail));

    // The *redownload* pass ("Synchronizing blockheaders", no "Pre-") is NOT
    // presync — the committed header height climbs on its own then, so it must not
    // be matched.
    try std.testing.expectEqual(
        @as(?u32, null),
        parsePresyncPercentBp("2026-06-30 08:00:00 Synchronizing blockheaders, height: 5000000 (~21.10%)\n"),
    );

    // No presync line at all → null.
    try std.testing.expectEqual(
        @as(?u32, null),
        parsePresyncPercentBp("2026-06-30 08:00:00 UpdateTip: new best=deadbeef height=28817\n"),
    );

    // Endpoints map cleanly to 0 / 10000 basis points.
    try std.testing.expectEqual(
        @as(?u32, 0),
        parsePresyncPercentBp("Pre-synchronizing blockheaders, height: 1 (~0.00%)\n"),
    );
    try std.testing.expectEqual(
        @as(?u32, 10000),
        parsePresyncPercentBp("Pre-synchronizing blockheaders, height: 23700000 (~100.00%)\n"),
    );
}

test "renderStatus appends the presync percentage only on the presync line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const brand = zz.Color.hex(app_color);

    // Presync line with a known percentage → the rendered status carries it.
    var act: Activity = .{};
    act.installed = true;
    act.daemon = .init(@intFromEnum(DaemonState.running));
    act.peers = 7;
    act.sync = .syncing;
    act.headers_cur = 419_996;
    act.headers_total = 23_700_000;
    act.presync = true;
    act.presync_bp = 744;
    const with_pct = renderStatus(a, &act, brand);
    try std.testing.expect(std.mem.indexOf(u8, with_pct, "Pre-synching headers… 7.4%") != null);

    // Same presync state but no scraped percentage (log line not in the tail) →
    // the base line shows, with no trailing percentage.
    act.presync_bp = 0;
    const no_pct = renderStatus(a, &act, brand);
    try std.testing.expect(std.mem.indexOf(u8, no_pct, "Pre-synching headers…") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_pct, "%") == null);
}

test "renderStatus shows the daemon's own stage wording on the Status line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const brand = zz.Color.hex(app_color);

    var act: Activity = .{};
    act.installed = true;
    act.daemon = .init(@intFromEnum(DaemonState.running));
    act.loading_phase = .loading;

    // The stage the poll worker staged, folded into `stage_buf` on the reap. This
    // is the whole point of the buffer: the phase enum can only say "Loading…".
    const stage = "Loading masternode cache…";
    @memcpy(act.stage_buf[0..stage.len], stage);
    act.stage_len = stage.len;
    const named = renderStatus(a, &act, brand);
    try std.testing.expect(std.mem.indexOf(u8, named, stage) != null);

    // Cleared (daemon answered normally, or stopped) → back to the coarse text.
    act.stage_len = 0;
    const plain = renderStatus(a, &act, brand);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Loading…") != null);
}

test "renderStatus shows the block-loading sub-stage and percentage during .loading" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const brand = zz.Color.hex(app_color);

    var act: Activity = .{};
    act.installed = true;
    act.daemon = .init(@intFromEnum(DaemonState.running));
    act.loading_phase = .loading;

    // "Loading blocks…" sub-stage, with its live percentage.
    act.load_stage = .loading_blocks;
    act.load_pct_bp = 1000;
    const loading = renderStatus(a, &act, brand);
    try std.testing.expect(std.mem.indexOf(u8, loading, "Loading blocks… 10.0%") != null);

    // "Processing blocks…" sub-stage.
    act.load_stage = .processing_blocks;
    act.load_pct_bp = 1234;
    const processing = renderStatus(a, &act, brand);
    try std.testing.expect(std.mem.indexOf(u8, processing, "Processing blocks… 12.3%") != null);

    // No sub-stage found in the log (yet) → falls back to the plain generic
    // label, no percentage.
    act.load_stage = .none;
    act.load_pct_bp = 0;
    const plain = renderStatus(a, &act, brand);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Loading…") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "%") == null);

    // A different warm-up phase ignores `load_stage` entirely, even if it's
    // stale from a moment ago — always renders via `loadingPhaseText`.
    act.loading_phase = .verifying;
    act.load_stage = .processing_blocks;
    act.load_pct_bp = 1234;
    const verifying = renderStatus(a, &act, brand);
    try std.testing.expect(std.mem.indexOf(u8, verifying, "Verifying…") != null);
    try std.testing.expect(std.mem.indexOf(u8, verifying, "%") == null);
}

test "renderStatus shows a NovaCoin daemon's block-index load with no percentage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const brand = zz.Color.hex(app_color);

    // SpiderByte-style warm-up: the phase is detected from debug.log (not a `-28`
    // reply), and outranks "Waiting for peers…" even though no peer has been seen
    // yet (peers == 0).
    var act: Activity = .{};
    act.installed = true;
    act.daemon = .init(@intFromEnum(DaemonState.running));
    act.loading_phase = .loading_block_index;

    // First-ever load: no prior duration → the bare label, no estimate.
    const out = renderStatus(a, &act, brand);
    try std.testing.expect(std.mem.indexOf(u8, out, "Loading block index…") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "%") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Waiting for peers") == null);

    // With an estimate available (computed on the tick), a rough ~NN% is appended.
    act.load_eta_pct = 20;
    const with_eta = renderStatus(a, &act, brand);
    try std.testing.expect(std.mem.indexOf(u8, with_eta, "Loading block index… ~20%") != null);

    // An overrunning load holds at ~99% (the tick clamps it), never claiming 100%.
    act.load_eta_pct = 99;
    const overrun = renderStatus(a, &act, brand);
    try std.testing.expect(std.mem.indexOf(u8, overrun, "Loading block index… ~99%") != null);
}

test "loadEtaPercent estimates elapsed vs last load, clamped to 1..99" {
    const ms = std.time.ns_per_ms;
    // A non-zero monotonic base — 0 is the "not timing" sentinel for the start.
    const base: i64 = 1_000_000 * ms;
    // Unknown inputs → 0 (no estimate): start unset, or no prior duration.
    try std.testing.expectEqual(@as(u8, 0), loadEtaPercent(0, base, 10_000));
    try std.testing.expectEqual(@as(u8, 0), loadEtaPercent(base, base + 5_000 * ms, 0));
    // Clock ran backwards → 0.
    try std.testing.expectEqual(@as(u8, 0), loadEtaPercent(base + 10_000 * ms, base + 5_000 * ms, 10_000));

    // Half-way through (by time) → ~50%.
    try std.testing.expectEqual(@as(u8, 50), loadEtaPercent(base, base + 5_000 * ms, 10_000));

    // Just begun → floored at 1% (never 0 — it's already underway).
    try std.testing.expectEqual(@as(u8, 1), loadEtaPercent(base, base, 10_000));

    // Overrun → capped at 99% (never 100 until the daemon answers).
    try std.testing.expectEqual(@as(u8, 99), loadEtaPercent(base, base + 20_000 * ms, 10_000));
}

test "txDirectionGlyph colors received/sent/stake/staked distinctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const received = App.txDirectionGlyph(a, .received);
    try std.testing.expect(std.mem.indexOf(u8, received, "▼") != null);

    const sent = App.txDirectionGlyph(a, .sent);
    try std.testing.expect(std.mem.indexOf(u8, sent, "▲") != null);

    // Stake is a ★, not an arrow — this daemon reports a stake credit the
    // same way a mined block reward would be, so it's neither received-from
    // nor sent-to anyone.
    const stake = App.txDirectionGlyph(a, .stake);
    try std.testing.expect(std.mem.indexOf(u8, stake, "★") != null);
    try std.testing.expect(std.mem.indexOf(u8, stake, "▼") == null);
    try std.testing.expect(std.mem.indexOf(u8, stake, "▲") == null);

    // An outgoing stake takes the sent arrow, not the reward star and not the
    // received arrow — the principal did leave the wallet for its term.
    const staked = App.txDirectionGlyph(a, .staked);
    try std.testing.expect(std.mem.indexOf(u8, staked, "▲") != null);
    try std.testing.expect(std.mem.indexOf(u8, staked, "★") == null);
    try std.testing.expect(std.mem.indexOf(u8, staked, "▼") == null);
    // …but in the stake colour, so it doesn't read as a payment to someone.
    try std.testing.expect(!std.mem.eql(u8, staked, sent));
}

test "txConfirmationText shows the raw count at/below the threshold, 'Confirmed' above it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Right at the threshold (6): not yet "Confirmed".
    const at_threshold = App.txConfirmationText(a, 6);
    try std.testing.expect(std.mem.indexOf(u8, at_threshold, "6 confirmations") != null);
    try std.testing.expect(std.mem.indexOf(u8, at_threshold, "Confirmed") == null);

    // One past the threshold: "Confirmed".
    const past_threshold = App.txConfirmationText(a, 7);
    try std.testing.expect(std.mem.indexOf(u8, past_threshold, "Confirmed") != null);

    // Singular vs plural wording.
    const one = App.txConfirmationText(a, 1);
    try std.testing.expect(std.mem.indexOf(u8, one, "1 confirmation") != null);
    try std.testing.expect(std.mem.indexOf(u8, one, "1 confirmations") == null);

    const zero = App.txConfirmationText(a, 0);
    try std.testing.expect(std.mem.indexOf(u8, zero, "0 confirmations") != null);
}

test "renderTransactionsTab lists cached transactions newest-first with date and amount" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Empty cache: an explicit empty state rather than a bare blank list.
    var act: Activity = .{};
    {
        const empty = try App.renderTransactionsTab(a, &act, 8);
        try std.testing.expect(std.mem.indexOf(u8, empty, "No transactions yet.") != null);
    }

    // Row 0 (7 confirmations, just over the threshold) is settled; row 1 (0,
    // still unconfirmed) and row 2 (6, at the threshold but not past it) are
    // both still shown with their raw counts.
    act.tx_buf[0] = .{ .direction = .received, .amount = 2.5, .time = 1893456000, .confirmations = 7 };
    act.tx_buf[1] = .{ .direction = .sent, .amount = 1.25, .time = 1893456060, .confirmations = 0 };
    act.tx_buf[2] = .{ .direction = .stake, .amount = 5.0, .time = 1893456120, .confirmations = 6 };
    act.tx_count = 3;

    const body = try App.renderTransactionsTab(a, &act, 8);
    try std.testing.expect(std.mem.indexOf(u8, body, "Transactions") != null);
    // A column header sits above the rows.
    try std.testing.expect(std.mem.indexOf(u8, body, "Date") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Amount") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Status") != null);
    // Each row carries its glyph, the formatted date, the formatted amount, and
    // a confirmation status.
    try std.testing.expect(std.mem.indexOf(u8, body, "▼") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "2.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Confirmed") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "▲") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "1.25") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "0 confirmations") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "★") != null);
    // A round-number amount (5.0) trims to a bare "5", padded to the amount
    // column width — right-aligned with leading spaces, so "     5" (not a
    // bare "5", which would also match spurious digits elsewhere in the body).
    try std.testing.expect(std.mem.indexOf(u8, body, "     5") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "6 confirmations") != null);

    // Row order in the rendered text follows `tx_buf`'s order (newest-first is
    // `mapTransactions`'s job on the SpiderByte side; this just proves the
    // renderer preserves whatever order the cache holds) — the received row
    // (index 0) appears before the stake row (index 2).
    const recv_pos = std.mem.indexOf(u8, body, "▼").?;
    const stake_pos = std.mem.indexOf(u8, body, "★").?;
    try std.testing.expect(recv_pos < stake_pos);
}

/// Test-only stub: a minimal coin wiring only the *required* vtable hooks and
/// none of the optional wallet features. It stands in for "a coin that hasn't
/// adopted transactions/receive/send" in the placeholder tests below, now that
/// every live coin has — those tabs must keep showing the generic placeholder
/// for such a coin. The live-call hooks are never reached by the render path
/// under test, so they just error.
const BareCoin = struct {
    fn coin(self: *BareCoin) Coin {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: Coin.VTable = .{
        .coin_name = vtStr("BareCoin"),
        .coin_name_abbrev = vtStr("BARE"),
        .coin_description = vtStr("A coin with no optional features wired."),
        .coin_color = vtStr("#808080"),
        .tip_address = vtStr("BARE-TIP"),
        .core_version = vtStr("0.0.0"),
        .proof_of_stake = vtPos,
        .conf_file = vtStr("bare.conf"),
        .daemon_file = vtStr("bared"),
        .rpc_default_port = vtStr("0"),
        .rpc_default_username = vtStr("barerpc"),
        .blockchain_state = vtState,
        .daemon_info = vtInfo,
        .data_dir = vtDataDir,
        .is_installed = vtInstalled,
        .install = vtInstall,
        .prepare_conf = vtPrepare,
        .launch_mode = vtLaunch,
        .daemon_argv = vtArgv,
    };
    /// Comptime helper: a vtable fn returning the given static string.
    fn vtStr(comptime s: []const u8) *const fn (*anyopaque) []const u8 {
        return struct {
            fn f(_: *anyopaque) []const u8 {
                return s;
            }
        }.f;
    }
    fn vtPos(_: *anyopaque) bool {
        return false;
    }
    fn vtState(_: *anyopaque, _: std.mem.Allocator, _: models.CoinAuth) anyerror!models.BlockchainState {
        return error.Unsupported;
    }
    fn vtInfo(_: *anyopaque, _: std.mem.Allocator, _: models.CoinAuth) anyerror!models.DaemonInfo {
        return error.Unsupported;
    }
    fn vtDataDir(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror![]const u8 {
        return error.Unsupported;
    }
    fn vtInstalled(_: *anyopaque, _: std.mem.Allocator, _: []const u8) bool {
        return true;
    }
    fn vtInstall(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8, _: ?install_mod.Progress) anyerror!void {
        return error.Unsupported;
    }
    fn vtPrepare(_: *anyopaque, _: std.mem.Allocator, _: std.Io, _: []const u8, _: []const u8) anyerror!void {}
    fn vtLaunch(_: *anyopaque) Coin.LaunchMode {
        return .fork;
    }
    fn vtArgv(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) anyerror![]const []const u8 {
        return error.Unsupported;
    }
};

test "the Transactions tab only shows live data for a coin that supports it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var app: App = undefined;
    app.hide_balances = false;
    app.disk_used = 0;
    app.disk_total = 0;
    app.mem_used = 0;
    app.mem_total = 0;
    app.active_tab = .transactions;

    // A coin with no `wallet_transactions` wired must keep showing the generic
    // placeholder, unaffected by the feature (per-coin rule: don't break other
    // coins). Every live coin wires it now, so the stub stands in.
    {
        var bare: BareCoin = .{};
        const coin = bare.coin();
        try std.testing.expect(!coin.supportsTransactions());

        var act: Activity = .{
            .coin = coin,
            .home_dir = "",
            .spinner = App.makeSpinner(),
            .daemon_spinner = App.makeSpinner(),
            .sync_spinner = zz.Spinner.init(),
        };
        act.installed = true;
        act.daemon.store(@intFromEnum(DaemonState.running), .release);
        act.poll_completed = true;

        const pane = try App.renderCoin(&app, a, coin, &act);
        try std.testing.expect(std.mem.indexOf(u8, pane, "Coming soon.") != null);
    }

    // SpiderByte supports it — a cached transaction shows up live instead.
    {
        var spb: SpiderByte = .{};
        const coin = spb.coin();
        try std.testing.expect(coin.supportsTransactions());

        var act: Activity = .{
            .coin = coin,
            .home_dir = "",
            .spinner = App.makeSpinner(),
            .daemon_spinner = App.makeSpinner(),
            .sync_spinner = zz.Spinner.init(),
        };
        act.installed = true;
        act.daemon.store(@intFromEnum(DaemonState.running), .release);
        act.poll_completed = true;
        act.tx_buf[0] = .{ .direction = .received, .amount = 3.0, .time = 1893456000, .confirmations = 12 };
        act.tx_count = 1;

        const pane = try App.renderCoin(&app, a, coin, &act);
        try std.testing.expect(std.mem.indexOf(u8, pane, "Coming soon.") == null);
        // 3.0 trims to a bare "3", right-aligned to the "Amount" header's width.
        try std.testing.expect(std.mem.indexOf(u8, pane, "     3") != null);
    }
}

test "the Staking tab exists only for a coin that stakes, and lists its stakes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var app: App = undefined;
    app.hide_balances = false;
    app.disk_used = 0;
    app.disk_total = 0;
    app.mem_used = 0;
    app.mem_total = 0;
    app.active_tab = .staking;

    // A coin with no stake action never grows the tab — the strip is built from
    // `tabVisible`, so Staking simply isn't on it (per-coin rule: adding this
    // must not change any other coin's pane). Checked on its Home tab, which is
    // where a coin switch always lands.
    {
        var nexa: Nexa = .{};
        const coin = nexa.coin();
        try std.testing.expect(!coin.supportsStakeAction());
        try std.testing.expect(!tabVisible(.staking, TabCaps.of(coin)));

        var act: Activity = .{
            .coin = coin,
            .home_dir = "",
            .spinner = App.makeSpinner(),
            .daemon_spinner = App.makeSpinner(),
            .sync_spinner = zz.Spinner.init(),
        };
        act.installed = true;
        act.daemon.store(@intFromEnum(DaemonState.running), .release);
        act.poll_completed = true;

        app.active_tab = .home;
        defer app.active_tab = .staking;
        const pane = try App.renderCoin(&app, a, coin, &act);
        try std.testing.expect(std.mem.indexOf(u8, pane, "Staking") == null);
    }

    var sal: Salvium = .{};
    const coin = sal.coin();
    try std.testing.expect(tabVisible(.staking, TabCaps.of(coin)));

    var act: Activity = .{
        .coin = coin,
        .home_dir = "",
        .spinner = App.makeSpinner(),
        .daemon_spinner = App.makeSpinner(),
        .sync_spinner = zz.Spinner.init(),
    };
    act.installed = true;
    act.daemon.store(@intFromEnum(DaemonState.running), .release);
    act.poll_completed = true;

    // Nothing staked yet: the term description and the key to start one still
    // stand, so the tab tells you what it's for before there's any history.
    {
        const pane = try App.renderCoin(&app, a, coin, &act);
        try std.testing.expect(std.mem.indexOf(u8, pane, "No stakes yet.") != null);
        try std.testing.expect(std.mem.indexOf(u8, pane, "S: stake") != null);
        try std.testing.expect(std.mem.indexOf(u8, pane, "30 days") != null);
    }

    // One locked and one matured stake, the shapes the live wallet produced.
    act.stake_buf[0] = .{
        .amount = 1000,
        .staked_time = 1786963395,
        .unlock_height = 576_643,
        .blocks_remaining = 21_592,
        .unlock_eta_seconds = 21_592 * 120,
        .unlocked_time = 0,
        .returned = 0,
    };
    act.stake_buf[1] = .{
        .amount = 1000,
        .staked_time = 1783463334,
        .unlock_height = 547_550,
        .blocks_remaining = 0,
        .unlock_eta_seconds = 0,
        .unlocked_time = 1786065414,
        .returned = 1006.20821166,
    };
    act.stake_count = 2;
    {
        const pane = try App.renderCoin(&app, a, coin, &act);
        // The locked one counts down; the matured one says when it paid out and
        // what the term earned.
        try std.testing.expect(std.mem.indexOf(u8, pane, "Locked, unlocks in") != null);
        try std.testing.expect(std.mem.indexOf(u8, pane, "Unlocked 2026-") != null);
        try std.testing.expect(std.mem.indexOf(u8, pane, "+6.2") != null);
    }

    // Hidden balances mask the principal and drop the yield with it — a figure
    // derived from the amount would leak what the mask is there to cover.
    {
        app.hide_balances = true;
        defer app.hide_balances = false;
        const pane = try App.renderCoin(&app, a, coin, &act);
        try std.testing.expect(std.mem.indexOf(u8, pane, "+6.2") == null);
        try std.testing.expect(std.mem.indexOf(u8, pane, "Unlocked 2026-") != null);
    }
}

test "stakeStatusText counts down while locked and reports the payout after" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A term with under a minute to run has no duration text to show, so the
    // block count carries it rather than the cell going blank.
    const nearly: models.Stake = .{
        .amount = 10,
        .staked_time = 100,
        .unlock_height = 200,
        .blocks_remaining = 1,
        .unlock_eta_seconds = 0,
        .unlocked_time = 0,
        .returned = 0,
    };
    try std.testing.expect(std.mem.indexOf(u8, try App.stakeStatusText(a, nearly, "SAL", 8, false), "1 blocks to go") != null);

    // Matured but unattributable (two stakes shared one payout): the date still
    // shows, the yield doesn't — no invented figure.
    const shared: models.Stake = .{
        .amount = 100,
        .staked_time = 100,
        .unlock_height = 200,
        .blocks_remaining = 0,
        .unlock_eta_seconds = 0,
        .unlocked_time = 1786065414,
        .returned = 0,
    };
    const text = try App.stakeStatusText(a, shared, "SAL", 8, false);
    try std.testing.expect(std.mem.indexOf(u8, text, "Unlocked 2026-") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "+") == null);

    // Matured with no payout found at all: still honestly "Unlocked", no date.
    const undated: models.Stake = .{
        .amount = 25,
        .staked_time = 100,
        .unlock_height = 200,
        .blocks_remaining = 0,
        .unlock_eta_seconds = 0,
        .unlocked_time = 0,
        .returned = 0,
    };
    try std.testing.expect(std.mem.indexOf(u8, try App.stakeStatusText(a, undated, "SAL", 8, false), "Unlocked") != null);
}

test "renderReceiveTab shows an empty state with no cached address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const act: Activity = .{};
    const body = try App.renderReceiveTab(a, &act);
    try std.testing.expect(std.mem.indexOf(u8, body, "No address yet.") != null);
}

test "renderReceiveTab shows the cached address, the key hint, and a QR block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var act: Activity = .{};
    const addr = "XmM8G6mfvJvqfxLnf78EE7oGDwtvfxKz9y";
    @memcpy(act.receive_addr_buf[0..addr.len], addr);
    act.receive_addr_len = addr.len;

    const body = try App.renderReceiveTab(a, &act);
    try std.testing.expect(std.mem.indexOf(u8, body, "Receive") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, addr) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "c: copy") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "n: new address") != null);
    // The QR block is present (half-block glyphs), not the "unavailable"
    // fallback.
    try std.testing.expect(std.mem.indexOf(u8, body, "▀") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "QR code unavailable") == null);
}

test "renderQrHalfBlock pads with the mandatory quiet zone on every side" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const qr = try qrcode.encodeText(a, "sp1der", .medium);
    defer qr.deinit();
    const block = try App.renderQrHalfBlock(a, qr);

    // 2 module-rows per printed row, size + 2*quiet_zone rows/cols total.
    const expected_rows = @divTrunc(qr.size() + App.qr_quiet_zone * 2 + 1, 2);
    var lines = std.mem.splitScalar(u8, block, '\n');
    var row_count: usize = 0;
    var first_line_width: usize = 0;
    while (lines.next()) |line| {
        if (row_count == 0) first_line_width = zz.width(line);
        row_count += 1;
    }
    try std.testing.expectEqual(@as(usize, @intCast(expected_rows)), row_count);
    try std.testing.expectEqual(@as(usize, @intCast(qr.size() + App.qr_quiet_zone * 2)), first_line_width);
}

test "the Receive tab only shows a live address for a coin that supports it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var app: App = undefined;
    app.hide_balances = false;
    app.disk_used = 0;
    app.disk_total = 0;
    app.mem_used = 0;
    app.mem_total = 0;
    app.active_tab = .receive;

    // A coin with no `wallet_receive_address` wired must keep showing the
    // generic placeholder (per-coin rule: don't break other coins). Every live
    // coin wires it now, so the stub stands in.
    {
        var bare: BareCoin = .{};
        const coin = bare.coin();
        try std.testing.expect(!coin.supportsReceiveAddress());

        var act: Activity = .{
            .coin = coin,
            .home_dir = "",
            .spinner = App.makeSpinner(),
            .daemon_spinner = App.makeSpinner(),
            .sync_spinner = zz.Spinner.init(),
        };
        act.installed = true;
        act.daemon.store(@intFromEnum(DaemonState.running), .release);
        act.poll_completed = true;

        const pane = try App.renderCoin(&app, a, coin, &act);
        try std.testing.expect(std.mem.indexOf(u8, pane, "Coming soon.") != null);
    }

    // SpiderByte supports it — a cached address shows up live instead.
    {
        var spb: SpiderByte = .{};
        const coin = spb.coin();
        try std.testing.expect(coin.supportsReceiveAddress());

        var act: Activity = .{
            .coin = coin,
            .home_dir = "",
            .spinner = App.makeSpinner(),
            .daemon_spinner = App.makeSpinner(),
            .sync_spinner = zz.Spinner.init(),
        };
        act.installed = true;
        act.daemon.store(@intFromEnum(DaemonState.running), .release);
        act.poll_completed = true;
        const addr = "XmM8G6mfvJvqfxLnf78EE7oGDwtvfxKz9y";
        @memcpy(act.receive_addr_buf[0..addr.len], addr);
        act.receive_addr_len = addr.len;

        const pane = try App.renderCoin(&app, a, coin, &act);
        try std.testing.expect(std.mem.indexOf(u8, pane, "Coming soon.") == null);
        try std.testing.expect(std.mem.indexOf(u8, pane, addr) != null);
    }
}

test "requestNewReceiveAddress stages a pending request and forces an immediate poll" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    // Index 0 is Home (unused); pick a real coin slot.
    app.selected = 1;
    app.activities[1].installed = true;
    app.last_poll_ns = 123_456_789;

    app.requestNewReceiveAddress();
    try std.testing.expect(app.pending_new_receive_address);
    try std.testing.expectEqual(@as(i64, 0), app.last_poll_ns);

    // No-op when the coin isn't installed — nothing to poll yet.
    app.pending_new_receive_address = false;
    app.last_poll_ns = 123_456_789;
    app.activities[1].installed = false;
    app.requestNewReceiveAddress();
    try std.testing.expect(!app.pending_new_receive_address);
    try std.testing.expectEqual(@as(i64, 123_456_789), app.last_poll_ns);
}

test "copyReceiveAddress no-ops without a cached address, logs otherwise" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    app.selected = 1;
    app.activities[1].installed = true;

    // No cached address yet: no-op, nothing logged.
    const before = app.log_count;
    app.copyReceiveAddress(&ctx);
    try std.testing.expectEqual(before, app.log_count);

    // With a cached address, pressing copy always logs an outcome — the test
    // harness's io isn't a real TTY, so `ctx.setClipboard` deterministically
    // reports unsupported rather than actually writing OSC 52.
    const addr = "XmM8G6mfvJvqfxLnf78EE7oGDwtvfxKz9y";
    @memcpy(app.activities[1].receive_addr_buf[0..addr.len], addr);
    app.activities[1].receive_addr_len = addr.len;
    app.copyReceiveAddress(&ctx);
    try std.testing.expectEqual(before + 1, app.log_count);
    const last = app.log_lines[(app.log_count - 1) % log_capacity].buf[0..app.log_lines[(app.log_count - 1) % log_capacity].len];
    try std.testing.expect(std.mem.indexOf(u8, last, "clipboard") != null);
}

test "trySendAmount rejects non-numeric/zero/negative, accepts a valid positive amount" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    app.send_modal = .{ .coin_idx = 1, .stage = .amount };

    // Non-numeric.
    try app.send_amount_input.setValue("abc");
    app.trySendAmount();
    try std.testing.expect(app.send_modal.?.bad_input);
    try std.testing.expectEqual(SendModal.Stage.amount, app.send_modal.?.stage);

    // Zero and negative are both rejected too.
    try app.send_amount_input.setValue("0");
    app.trySendAmount();
    try std.testing.expect(app.send_modal.?.bad_input);
    try std.testing.expectEqual(SendModal.Stage.amount, app.send_modal.?.stage);

    // A cached balance of 0 does NOT block a positive amount client-side —
    // that check is deliberately left to the daemon's own live "Insufficient
    // funds" response (see the plan's rationale: the cached balance can be
    // stale in either direction).
    app.activities[1].balance_avail = 0;
    try app.send_amount_input.setValue("1.5");
    app.trySendAmount();
    try std.testing.expect(!app.send_modal.?.bad_input);
    try std.testing.expectEqual(SendModal.Stage.confirm, app.send_modal.?.stage);
}

test "renderSendModal shows the untruncated address and formatted amount at confirm" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    // Find whichever coin slot actually supports Send (currently SpiderByte
    // only), rather than hardcoding its index in `entries`.
    var send_idx: usize = 0;
    for (0..app.activities.len) |i| {
        if (app.coinAt(i)) |c| {
            if (c.supportsSend()) {
                send_idx = i;
                break;
            }
        }
    }
    try std.testing.expect(send_idx != 0);

    const addr = "XmM8G6mfvJvqfxLnf78EE7oGDwtvfxKz9y";
    try app.send_addr_input.setValue(addr);
    try app.send_amount_input.setValue("1.5");
    app.send_modal = .{ .coin_idx = send_idx, .stage = .confirm };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const box = try app.renderSendModal(arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, box, addr) != null);
    try std.testing.expect(std.mem.indexOf(u8, box, "1.50000000") != null);
}

test "the Stake prompt refuses to open for a coin without the stake action" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    // A send-capable coin *without* the stake action (only Salvium wires it,
    // and it's not in the nav while its `live` flag is false): 'S' must be a
    // no-op — no modal opens.
    var plain_idx: usize = 0;
    for (0..app.activities.len) |i| {
        if (app.coinAt(i)) |c| {
            if (c.supportsSend() and !c.supportsStakeAction()) {
                plain_idx = i;
                break;
            }
        }
    }
    try std.testing.expect(plain_idx != 0);
    app.selected = plain_idx;
    app.openStakeModal();
    try std.testing.expect(app.send_modal == null);
}

test "renderSendModal in stake mode shows stake wording, no destination" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    // Any send-capable coin can render the stake-mode chrome (Salvium itself
    // isn't in a nav slot while its `live` flag is false; its own lock-term
    // hint text is covered by the salvium.zig tests).
    var send_idx: usize = 0;
    for (0..app.activities.len) |i| {
        if (app.coinAt(i)) |c| {
            if (c.supportsSend()) {
                send_idx = i;
                break;
            }
        }
    }
    try std.testing.expect(send_idx != 0);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Confirm stage: stake wording (with the amount), not send-to-address —
    // a stake pays the wallet's own address, so no destination is shown.
    try app.send_amount_input.setValue("2.5");
    app.send_modal = .{ .coin_idx = send_idx, .mode = .stake, .stage = .confirm };
    {
        const box = try app.renderSendModal(a);
        try std.testing.expect(std.mem.indexOf(u8, box, "Stake 2.50000000") != null);
        try std.testing.expect(std.mem.indexOf(u8, box, "Yes — stake it") != null);
        try std.testing.expect(std.mem.indexOf(u8, box, "Send ") == null);
    }

    // Working/result stages carry the stake wording too.
    app.send_modal = .{ .coin_idx = send_idx, .mode = .stake, .stage = .working };
    {
        const box = try app.renderSendModal(a);
        try std.testing.expect(std.mem.indexOf(u8, box, "Staking…") != null);
    }
    app.send_modal = .{ .coin_idx = send_idx, .mode = .stake, .stage = .result };
    app.send_modal.?.setMsg(true, "a1b2c3");
    {
        const box = try app.renderSendModal(a);
        try std.testing.expect(std.mem.indexOf(u8, box, "Staked. Txid:") != null);
        try std.testing.expect(std.mem.indexOf(u8, box, "a1b2c3") != null);
    }
}

test "the Send tab only shows the balance/hint for a coin that supports it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var app: App = undefined;
    app.hide_balances = false;
    app.disk_used = 0;
    app.disk_total = 0;
    app.mem_used = 0;
    app.mem_total = 0;
    app.active_tab = .send;

    // A coin with no `wallet_send` wired must keep showing the generic
    // placeholder (per-coin rule: don't break other coins). Every live coin
    // wires it now, so the stub stands in.
    {
        var bare: BareCoin = .{};
        const coin = bare.coin();
        try std.testing.expect(!coin.supportsSend());

        var act: Activity = .{
            .coin = coin,
            .home_dir = "",
            .spinner = App.makeSpinner(),
            .daemon_spinner = App.makeSpinner(),
            .sync_spinner = zz.Spinner.init(),
        };
        act.installed = true;
        act.daemon.store(@intFromEnum(DaemonState.running), .release);
        act.poll_completed = true;

        const pane = try App.renderCoin(&app, a, coin, &act);
        try std.testing.expect(std.mem.indexOf(u8, pane, "Coming soon.") != null);
    }

    // SpiderByte supports it — the balance/hint show up live instead.
    {
        var spb: SpiderByte = .{};
        const coin = spb.coin();
        try std.testing.expect(coin.supportsSend());

        var act: Activity = .{
            .coin = coin,
            .home_dir = "",
            .spinner = App.makeSpinner(),
            .daemon_spinner = App.makeSpinner(),
            .sync_spinner = zz.Spinner.init(),
        };
        act.installed = true;
        act.daemon.store(@intFromEnum(DaemonState.running), .release);
        act.poll_completed = true;
        act.has_balance = true;
        act.balance_avail = 3.0;

        const pane = try App.renderCoin(&app, a, coin, &act);
        try std.testing.expect(std.mem.indexOf(u8, pane, "Coming soon.") == null);
        try std.testing.expect(std.mem.indexOf(u8, pane, "3.00000000") != null);
        try std.testing.expect(std.mem.indexOf(u8, pane, "press Enter to send") != null);
    }
}

test "the Mining tab only exists for coins that mine, and walks its states" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var app: App = undefined;
    app.hide_balances = false;
    app.disk_used = 0;
    app.disk_total = 0;
    app.mem_used = 0;
    app.mem_total = 0;
    app.active_tab = .mining;

    // A coin without mining: no Mining tab in the strip (the hint stays 1-5),
    // and the body — were it somehow reached — is the generic placeholder.
    {
        var bare: BareCoin = .{};
        const coin = bare.coin();
        try std.testing.expect(!coin.supportsMining());

        var act: Activity = .{
            .coin = coin,
            .home_dir = "",
            .spinner = App.makeSpinner(),
            .daemon_spinner = App.makeSpinner(),
            .sync_spinner = zz.Spinner.init(),
        };
        act.installed = true;
        act.daemon.store(@intFromEnum(DaemonState.running), .release);
        act.poll_completed = true;

        const pane = try App.renderCoin(&app, a, coin, &act);
        try std.testing.expect(std.mem.indexOf(u8, pane, "Coming soon.") != null);
        // The strip omits the tab — its jump-key hint stays 1-5. (The
        // placeholder body is titled "Mining", so the label itself can't
        // distinguish strip from body here.)
        try std.testing.expect(std.mem.indexOf(u8, pane, "1-5 to switch tabs") != null);
    }

    // Nerva mines: the strip gains the tab (and the 6 key), and the body
    // reflects daemon state → status fetch → idle (with/without a payout
    // address) → active.
    {
        var n: Nerva = .{};
        const coin = n.coin();
        try std.testing.expect(coin.supportsMining());

        var act: Activity = .{
            .coin = coin,
            .home_dir = "",
            .spinner = App.makeSpinner(),
            .daemon_spinner = App.makeSpinner(),
            .sync_spinner = zz.Spinner.init(),
        };
        act.installed = true;
        act.poll_completed = true;

        // Daemon down → say how to get mining (it lives in the daemon).
        const down = try App.renderCoin(&app, a, coin, &act);
        try std.testing.expect(std.mem.indexOf(u8, down, "start it (s) first") != null);
        try std.testing.expect(std.mem.indexOf(u8, down, "1-6 to switch tabs") != null);

        // Running, no status fetched yet → checking, not a false "not mining".
        act.daemon.store(@intFromEnum(DaemonState.running), .release);
        const checking = try App.renderCoin(&app, a, coin, &act);
        try std.testing.expect(std.mem.indexOf(u8, checking, "Checking miner status…") != null);

        // Idle without the wallet opened → the payout-address hint, not a dead
        // Enter.
        act.has_mining = true;
        const idle = try App.renderCoin(&app, a, coin, &act);
        try std.testing.expect(std.mem.indexOf(u8, idle, "Not mining") != null);
        try std.testing.expect(std.mem.indexOf(u8, idle, "Open your wallet (w) first") != null);

        // Idle with a cached address → ready to start.
        @memcpy(act.receive_addr_buf[0..4], "NV1x");
        act.receive_addr_len = 4;
        const ready = try App.renderCoin(&app, a, coin, &act);
        try std.testing.expect(std.mem.indexOf(u8, ready, "Enter: start mining") != null);

        // Actively mining → thread count + hashrate + the stop hint.
        act.mining_active = true;
        act.mining_threads = 3;
        act.mining_speed = 1250;
        const active = try App.renderCoin(&app, a, coin, &act);
        try std.testing.expect(std.mem.indexOf(u8, active, "3 threads at 1.25 kH/s") != null);
        try std.testing.expect(std.mem.indexOf(u8, active, "Enter: stop mining") != null);
    }
}

test "the Mining prompt only opens on a mining coin with a running daemon" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    var plain_idx: ?usize = null;
    var mining_idx: ?usize = null;
    for (0..app.activities.len) |i| {
        if (app.coinAt(i)) |c| {
            if (c.supportsMining()) {
                if (mining_idx == null) mining_idx = i;
            } else if (plain_idx == null) plain_idx = i;
        }
    }
    try std.testing.expect(plain_idx != null);
    try std.testing.expect(mining_idx != null);

    // A coin without mining: Enter never opens the prompt.
    app.selected = plain_idx.?;
    app.openMiningModal();
    try std.testing.expect(app.mining_modal == null);

    // A mining coin with its daemon down: still refused (the tab says why).
    app.selected = mining_idx.?;
    app.openMiningModal();
    try std.testing.expect(app.mining_modal == null);

    // Daemon up but no payout address cached yet (wallet never opened this
    // session): a start would have nowhere to send rewards, so refused.
    const act = &app.activities[mining_idx.?];
    act.daemon.store(@intFromEnum(DaemonState.running), .release);
    app.openMiningModal();
    try std.testing.expect(app.mining_modal == null);

    // Address cached → opens at the thread-count stage.
    @memcpy(act.receive_addr_buf[0..4], "NV1x");
    act.receive_addr_len = 4;
    app.openMiningModal();
    try std.testing.expect(app.mining_modal != null);
    try std.testing.expectEqual(MiningModal.Stage.threads, app.mining_modal.?.stage);

    // With the miner already running it opens at the stop confirm instead.
    app.mining_modal = null;
    act.mining_active = true;
    app.openMiningModal();
    try std.testing.expect(app.mining_modal != null);
    try std.testing.expectEqual(MiningModal.Stage.confirm_stop, app.mining_modal.?.stage);
    try std.testing.expect(!app.mining_modal.?.starting);
}

test "renderStablecoinTab walks the daemon-down, checking, pre-activation, and live states" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dgb: DigiByte = .{};
    const sc = dgb.coin().stablecoin().?;
    var act: Activity = .{};

    // Daemon down → the tab says to start it rather than showing a dead pane.
    const down = try App.renderStablecoinTab(a, sc, &act, false);
    try std.testing.expect(std.mem.indexOf(u8, down, "start the daemon") != null);

    // Daemon up, no info fetched yet → "checking".
    act.daemon.store(@intFromEnum(DaemonState.running), .release);
    const checking = try App.renderStablecoinTab(a, sc, &act, false);
    try std.testing.expect(std.mem.indexOf(u8, checking, "Checking") != null);

    // Pre-activation (live on mainnet, waiting for the activation height):
    // status shown, countdown to the activation block, actions locked. No
    // "Address: fetching…" — the address RPC refuses until activation.
    act.sc_has_info = true;
    act.sc_info.setStatus("locked_in");
    act.sc_info.activation_height = 23_627_520;
    act.blocks_cur = 23_600_000;
    const pre = try App.renderStablecoinTab(a, sc, &act, false);
    try std.testing.expect(std.mem.indexOf(u8, pre, "Not active yet") != null);
    try std.testing.expect(std.mem.indexOf(u8, pre, "locked_in") != null);
    try std.testing.expect(std.mem.indexOf(u8, pre, "Activates at block 23627520") != null);
    try std.testing.expect(std.mem.indexOf(u8, pre, "27520 blocks to go") != null);
    // 27,520 blocks × 15 s ≈ 4.8 days → the ETA leads with days.
    try std.testing.expect(std.mem.indexOf(u8, pre, "4 days") != null);
    try std.testing.expect(std.mem.indexOf(u8, pre, "unlock once the feature activates") != null);
    try std.testing.expect(std.mem.indexOf(u8, pre, "fetching") == null);

    // Live: balance, oracle price, address, a redeemable vault, a mint row.
    act.sc_info.active = true;
    act.sc_info.price_micro_usd = 14_230;
    act.sc_has_balance = true;
    act.sc_balance = .{ .confirmed_cents = 12550, .pending_cents = 500 };
    const addr = "DD1exampleaddress";
    @memcpy(act.sc_addr_buf[0..addr.len], addr);
    act.sc_addr_len = addr.len;
    act.sc_pos_count = 1;
    act.sc_pos_buf[0] = .{ .amount_cents = 10000, .tier = 4, .unlock_height = 19_000_000, .can_redeem = true };
    act.sc_pos_buf[0].setId("aa11");
    act.sc_tx_count = 1;
    act.sc_tx_buf[0] = .{ .kind = .mint, .amount_cents = 10000, .time = 1_780_410_720, .confirmations = 12 };
    const live = try App.renderStablecoinTab(a, sc, &act, false);
    try std.testing.expect(std.mem.indexOf(u8, live, "$125.50") != null);
    try std.testing.expect(std.mem.indexOf(u8, live, "$5.00 pending") != null);
    try std.testing.expect(std.mem.indexOf(u8, live, addr) != null);
    try std.testing.expect(std.mem.indexOf(u8, live, "$0.014230") != null);
    try std.testing.expect(std.mem.indexOf(u8, live, "redeemable") != null);
    try std.testing.expect(std.mem.indexOf(u8, live, "1 year") != null);
    try std.testing.expect(std.mem.indexOf(u8, live, "mint") != null);
    try std.testing.expect(std.mem.indexOf(u8, live, "Enter: mint / send / redeem") != null);
}

test "openStablecoinModal gates on capability, daemon state, and on-chain activation" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    var plain_idx: ?usize = null;
    var sc_idx: ?usize = null;
    for (0..app.activities.len) |i| {
        if (app.coinAt(i)) |c| {
            if (c.supportsStablecoin()) {
                if (sc_idx == null) sc_idx = i;
            } else if (plain_idx == null) plain_idx = i;
        }
    }
    try std.testing.expect(plain_idx != null);
    // DigiByte is registered, so a stablecoin coin exists.
    try std.testing.expect(sc_idx != null);

    // A coin without the capability: Enter never opens the prompt.
    app.selected = plain_idx.?;
    app.openStablecoinModal();
    try std.testing.expect(app.sc_modal == null);

    // The stablecoin coin with its daemon down: refused (the tab says why).
    app.selected = sc_idx.?;
    app.openStablecoinModal();
    try std.testing.expect(app.sc_modal == null);

    // Daemon up but the feature not yet ACTIVE on-chain (the pre-mainnet
    // state): still refused — the actions unlock only once the BIP9
    // deployment flips to "active".
    const act = &app.activities[sc_idx.?];
    act.daemon.store(@intFromEnum(DaemonState.running), .release);
    act.sc_has_info = true;
    act.sc_info.active = false;
    app.openStablecoinModal();
    try std.testing.expect(app.sc_modal == null);

    // Active → opens at the action menu.
    act.sc_info.active = true;
    app.openStablecoinModal();
    try std.testing.expect(app.sc_modal != null);
    try std.testing.expectEqual(StablecoinModal.Stage.menu, app.sc_modal.?.stage);

    // Choose "Mint": an amount below the $100 minimum is rejected in place;
    // a valid one advances to the tier picker with the exact cents parsed.
    app.scChooseAction();
    try std.testing.expectEqual(StablecoinModal.Stage.amount, app.sc_modal.?.stage);
    try app.send_amount_input.setValue("50");
    app.tryScAmount();
    try std.testing.expect(app.sc_modal.?.bad_input);
    try std.testing.expectEqual(StablecoinModal.Stage.amount, app.sc_modal.?.stage);
    try app.send_amount_input.setValue("250.75");
    app.tryScAmount();
    try std.testing.expectEqual(StablecoinModal.Stage.tier, app.sc_modal.?.stage);
    try std.testing.expectEqual(@as(i64, 25075), app.sc_modal.?.cents);
}

test "renderMiningModal shows the thread prompt, stop confirm, and a failure" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    var mining_idx: usize = 0;
    for (0..app.activities.len) |i| {
        if (app.coinAt(i)) |c| {
            if (c.supportsMining()) {
                mining_idx = i;
                break;
            }
        }
    }
    try std.testing.expect(mining_idx != 0);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Thread-count stage: the field plus the machine's own CPU count.
    try app.mining_input.setValue("4");
    app.mining_modal = .{ .coin_idx = mining_idx, .stage = .threads };
    {
        const box = try app.renderMiningModal(a);
        try std.testing.expect(std.mem.indexOf(u8, box, "CPU threads:") != null);
        try std.testing.expect(std.mem.indexOf(u8, box, "This machine has") != null);
    }

    // Stop confirm.
    app.mining_modal = .{ .coin_idx = mining_idx, .stage = .confirm_stop, .starting = false };
    {
        const box = try app.renderMiningModal(a);
        try std.testing.expect(std.mem.indexOf(u8, box, "Stop mining?") != null);
        try std.testing.expect(std.mem.indexOf(u8, box, "Yes — stop it") != null);
    }

    // A failed start surfaces the mapped reason, not a generic "failed".
    app.mining_modal = .{ .coin_idx = mining_idx, .stage = .working };
    app.mining_modal.?.setMsg(false, mining.failureText("DaemonStillSyncing"));
    {
        const box = try app.renderMiningModal(a);
        try std.testing.expect(std.mem.indexOf(u8, box, "Couldn't start mining:") != null);
        try std.testing.expect(std.mem.indexOf(u8, box, "still syncing") != null);
    }
}

test "a successful poll folds peers, staking, heights and sync into the display" {
    // A finished poll publishes its result into the atomics; applyPoll copies it
    // into the plain fields the pane renders. A failed poll is a no-op so a
    // transient RPC blip doesn't zero a previously-good reading.
    var act: Activity = .{};
    act.poll_ok = true;
    act.poll_peers.store(29, .monotonic);
    act.poll_staking.store(1, .monotonic);
    act.poll_synced.store(1, .monotonic);
    act.poll_headers.store(4_071_165, .monotonic);
    act.poll_blocks.store(4_071_165, .monotonic);
    act.poll_network.store(4_071_165, .monotonic);
    try std.testing.expect(act.applyPoll());
    try std.testing.expectEqual(@as(u32, 29), act.peers);
    try std.testing.expect(act.staking);
    try std.testing.expectEqual(SyncState.synced, act.sync);
    // Synced: headers == network tip and blocks == headers → both bars full.
    try std.testing.expectEqual(act.headers_total, act.headers_cur);
    try std.testing.expectEqual(act.blocks_total, act.blocks_cur);

    // Header-download phase: headers climbing toward the network tip while blocks
    // lag far behind. Headers bar partial (headers/network), blocks bar tiny
    // (blocks/headers).
    var headers_phase: Activity = .{};
    headers_phase.poll_ok = true;
    headers_phase.poll_peers.store(8, .monotonic);
    headers_phase.poll_synced.store(0, .monotonic);
    headers_phase.poll_network.store(4_071_165, .monotonic);
    headers_phase.poll_headers.store(3_000_000, .monotonic);
    headers_phase.poll_blocks.store(10_000, .monotonic);
    try std.testing.expect(headers_phase.applyPoll());
    try std.testing.expectEqual(SyncState.syncing, headers_phase.sync);
    try std.testing.expectEqual(@as(u64, 4_071_165), headers_phase.headers_total);
    try std.testing.expectEqual(@as(u64, 3_000_000), headers_phase.headers_cur);
    try std.testing.expectEqual(@as(u64, 3_000_000), headers_phase.blocks_total);
    try std.testing.expectEqual(@as(u64, 10_000), headers_phase.blocks_cur);

    // Block-validation phase: headers complete (== network tip), blocks catching
    // up to headers. Headers bar full, blocks bar partial and independent.
    var blocks_phase: Activity = .{};
    blocks_phase.poll_ok = true;
    blocks_phase.poll_peers.store(8, .monotonic);
    blocks_phase.poll_synced.store(0, .monotonic);
    blocks_phase.poll_network.store(4_071_165, .monotonic);
    blocks_phase.poll_headers.store(4_071_165, .monotonic);
    blocks_phase.poll_blocks.store(2_000_000, .monotonic);
    try std.testing.expect(blocks_phase.applyPoll());
    try std.testing.expectEqual(blocks_phase.headers_total, blocks_phase.headers_cur);
    try std.testing.expectEqual(@as(u64, 4_071_165), blocks_phase.blocks_total);
    try std.testing.expectEqual(@as(u64, 2_000_000), blocks_phase.blocks_cur);

    // We're ahead of every peer (stale peer heights): headers bar still pegs
    // full rather than overflowing.
    var ahead: Activity = .{};
    ahead.poll_ok = true;
    ahead.poll_peers.store(8, .monotonic);
    ahead.poll_network.store(4_071_160, .monotonic);
    ahead.poll_headers.store(4_071_165, .monotonic);
    ahead.poll_blocks.store(4_071_165, .monotonic);
    try std.testing.expect(ahead.applyPoll());
    try std.testing.expectEqual(@as(u64, 4_071_165), ahead.headers_total);
    try std.testing.expectEqual(ahead.headers_total, ahead.headers_cur);

    // Tip unknown (no peer has reported a height yet): a node loads its local
    // headers from disk before any peer connects, so without this guard the bar
    // would read a false 100% (headers/headers) that collapses once a real tip
    // arrives. An unknown tip means an unknown total — an empty bar, not full.
    var no_tip: Activity = .{};
    no_tip.poll_ok = true;
    no_tip.poll_network.store(0, .monotonic);
    no_tip.poll_headers.store(500_000, .monotonic);
    no_tip.poll_blocks.store(500_000, .monotonic);
    try std.testing.expect(no_tip.applyPoll());
    try std.testing.expectEqual(@as(u64, 0), no_tip.headers_total);
    try std.testing.expectEqual(@as(u64, 500_000), no_tip.headers_cur);

    // No peers connected, yet the daemon still reports a tip (e.g. Ergo echoes a
    // stale/self `maxPeerHeight` with zero peers). Without a peer to compare
    // against the tip is untrustworthy, so the bar stays empty rather than
    // reading a false 100% (headers >= the stale tip).
    var no_peers: Activity = .{};
    no_peers.poll_ok = true;
    no_peers.poll_peers.store(0, .monotonic);
    no_peers.poll_network.store(500_000, .monotonic);
    no_peers.poll_headers.store(500_000, .monotonic);
    no_peers.poll_blocks.store(500_000, .monotonic);
    try std.testing.expect(no_peers.applyPoll());
    try std.testing.expectEqual(@as(u64, 0), no_peers.headers_total);
    try std.testing.expectEqual(@as(u64, 500_000), no_peers.headers_cur);

    var stale: Activity = .{};
    stale.peers = 7;
    stale.staking = true;
    stale.sync = .synced;
    stale.poll_ok = false;
    try std.testing.expect(!stale.applyPoll());
    try std.testing.expectEqual(@as(u32, 7), stale.peers);
    try std.testing.expect(stale.staking);
    try std.testing.expectEqual(SyncState.synced, stale.sync);
}

test "a stalled committed-header height in the headers phase reads as presync" {
    // Bitcoin Core 24+ runs a throwaway headers presync pass whose progress it
    // doesn't expose via RPC, so the committed `headers` height sits still while
    // the node is busy. A header height that fails to advance for
    // `presync_stall_threshold` *consecutive* polls (in the headers phase, with
    // peers) is read as presync and surfaces a distinct line — one stalled poll
    // alone isn't enough (see the flip-flop regression test below).
    const running = @intFromEnum(DaemonState.running);

    var act: Activity = .{};
    act.installed = true;
    act.daemon = .init(running);
    act.poll_ok = true;
    act.poll_peers.store(7, .monotonic);
    act.poll_synced.store(0, .monotonic);
    act.poll_network.store(23_700_000, .monotonic); // real tip from peers
    act.poll_headers.store(419_996, .monotonic); // committed headers, stuck
    act.poll_blocks.store(28_817, .monotonic);

    // First poll: prev_headers_cur is still 0, so the height counts as "advanced"
    // and we don't yet claim presync — one poll of evidence isn't enough.
    try std.testing.expect(act.applyPoll());
    try std.testing.expectEqual(SyncState.syncing, act.sync);
    try std.testing.expect(!act.presync);
    try std.testing.expectEqualStrings("Syncing headers…", statusReadout(&act).text);

    // Second poll: same committed-header height → first stalled poll → still not
    // enough evidence on its own (debounced).
    try std.testing.expect(act.applyPoll());
    try std.testing.expect(!act.presync);
    try std.testing.expectEqualStrings("Syncing headers…", statusReadout(&act).text);

    // Third poll: second consecutive stalled poll → threshold reached → presync.
    try std.testing.expect(act.applyPoll());
    try std.testing.expect(act.presync);
    try std.testing.expectEqualStrings("Pre-synching headers…", statusReadout(&act).text);

    // Once committed headers start climbing again, it's a normal header download.
    act.poll_headers.store(1_500_000, .monotonic);
    try std.testing.expect(act.applyPoll());
    try std.testing.expect(!act.presync);
    try std.testing.expectEqualStrings("Syncing headers…", statusReadout(&act).text);

    // Block-validation phase (headers complete): never presync, even if a poll's
    // block height happens not to move — presync is a headers-phase concept.
    act.poll_network.store(23_700_000, .monotonic);
    act.poll_headers.store(23_700_000, .monotonic);
    act.poll_blocks.store(2_000_000, .monotonic);
    try std.testing.expect(act.applyPoll()); // headers now climbed → not presync
    try std.testing.expect(act.applyPoll()); // headers static but phase is blocks
    try std.testing.expect(!act.presync);
    try std.testing.expectEqualStrings("Syncing blocks…", statusReadout(&act).text);
}

test "a coin with no presync pass never reads as presync, however long its headers sit" {
    // Regression test: a node whose headers are already at the tip while its
    // blocks are far behind (a fresh Ergo install — headers commit as they
    // arrive, blocks then take hours) has a committed-header height that barely
    // moves for the whole block download. The Core-only stall inference read
    // that as a presync freeze and pinned "Pre-synching headers…" on for the
    // duration. Coins that wire `has_header_presync = false` opt out entirely.
    const running = @intFromEnum(DaemonState.running);

    var act: Activity = .{};
    act.installed = true;
    act.has_header_presync = false; // as Ergo's vtable reports
    act.daemon = .init(running);
    act.poll_ok = true;
    act.poll_peers.store(30, .monotonic);
    act.poll_synced.store(0, .monotonic);
    // Live heights from a syncing mainnet node: headers at the tip (the 50-block
    // gap is just peers announcing ahead of us), full blocks a million behind.
    act.poll_network.store(1_830_324, .monotonic);
    act.poll_headers.store(1_830_274, .monotonic);
    act.poll_blocks.store(24_019, .monotonic);

    // However many polls the header height sits still for, it stays block sync.
    for (0..5) |_| {
        try std.testing.expect(act.applyPoll());
        try std.testing.expect(!act.presync);
        try std.testing.expectEqualStrings("Syncing blocks…", statusReadout(&act).text);
    }

    // The log-confirmed signal is gated too: a coin with no presync pass can't
    // be in one, whatever a scraped log line claims.
    act.poll_presync_found.store(1, .monotonic);
    try std.testing.expect(act.applyPoll());
    try std.testing.expect(!act.presync);
}

test "headers within the tip slack count as complete, not a headers phase" {
    // The local header height sits a few blocks short of the best peer height
    // even when caught up — the chain moves and peers announce before we commit.
    // That permanent gap must not read as "still downloading headers".
    var act: Activity = .{};
    act.headers_total = 1_830_324;

    act.headers_cur = act.headers_total - header_tip_slack + 1; // inside the slack
    try std.testing.expect(!act.inHeadersPhase());

    act.headers_cur = act.headers_total - header_tip_slack; // exactly at the edge
    try std.testing.expect(!act.inHeadersPhase());

    act.headers_cur = act.headers_total - header_tip_slack - 1; // just outside
    try std.testing.expect(act.inHeadersPhase());

    // A real header download is orders of magnitude further behind — unaffected.
    act.headers_cur = 3_000;
    try std.testing.expect(act.inHeadersPhase());

    // An unknown tip isn't a headers phase we can measure.
    act.headers_total = 0;
    try std.testing.expect(!act.inHeadersPhase());
}

test "a single momentary header stall during a real download doesn't flip to presync" {
    // Regression test: the old one-poll heuristic flagged presync (and flipped
    // the Status line/log back and forth) on any single tick where the header
    // count happened not to move, even mid-download. Debouncing over
    // `presync_stall_threshold` consecutive polls means one blip, surrounded by
    // real advances, must never trip it.
    const running = @intFromEnum(DaemonState.running);

    var act: Activity = .{};
    act.installed = true;
    act.daemon = .init(running);
    act.poll_ok = true;
    act.poll_peers.store(7, .monotonic);
    act.poll_synced.store(0, .monotonic);
    act.poll_network.store(23_700_000, .monotonic);

    act.poll_headers.store(100_000, .monotonic);
    try std.testing.expect(act.applyPoll());
    try std.testing.expect(!act.presync);

    act.poll_headers.store(200_000, .monotonic); // advancing
    try std.testing.expect(act.applyPoll());
    try std.testing.expect(!act.presync);

    // One momentary stall — a blip, not a real freeze.
    try std.testing.expect(act.applyPoll());
    try std.testing.expect(!act.presync);
    try std.testing.expectEqualStrings("Syncing headers…", statusReadout(&act).text);

    act.poll_headers.store(300_000, .monotonic); // resumes advancing
    try std.testing.expect(act.applyPoll());
    try std.testing.expect(!act.presync);
    try std.testing.expectEqualStrings("Syncing headers…", statusReadout(&act).text);
}

test "a debug.log-confirmed presync line is authoritative, no debounce needed" {
    // When the daemon actually logs "Pre-synchronizing blockheaders…",
    // `poll_presync_found` carries that ground truth straight through —
    // presync shows immediately (no waiting for consecutive stalled polls) and
    // clears the instant the log stops confirming it, even if the header
    // height still hasn't moved.
    const running = @intFromEnum(DaemonState.running);

    var act: Activity = .{};
    act.installed = true;
    act.daemon = .init(running);
    act.poll_ok = true;
    act.poll_peers.store(7, .monotonic);
    act.poll_synced.store(0, .monotonic);
    act.poll_network.store(23_700_000, .monotonic);
    act.poll_headers.store(419_996, .monotonic);
    act.poll_presync_found.store(1, .monotonic);

    // First poll ever (prev_headers_cur == 0, so the debounced path sees an
    // "advance") — the log confirmation alone is enough.
    try std.testing.expect(act.applyPoll());
    try std.testing.expect(act.presync);
    try std.testing.expectEqualStrings("Pre-synching headers…", statusReadout(&act).text);

    // Log stops confirming it (pass ended, or log rotated) but the header
    // height genuinely hasn't moved yet — falls back to the debounced signal,
    // which isn't tripped yet on just one stalled poll.
    act.poll_presync_found.store(0, .monotonic);
    try std.testing.expect(act.applyPoll());
    try std.testing.expect(!act.presync);
    try std.testing.expectEqualStrings("Syncing headers…", statusReadout(&act).text);
}

test "daemon toggle button reflects install and daemon state" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var act: Activity = .{};

    // Disabled until installed.
    act.installed = false;
    try std.testing.expect(std.mem.indexOf(u8, App.renderDaemonButton(a, &act), "install first") != null);

    // Installed + stopped → "Start", bound to `s`.
    act.installed = true;
    {
        const b = App.renderDaemonButton(a, &act);
        try std.testing.expect(std.mem.indexOf(u8, b, "Start") != null);
        try std.testing.expect(std.mem.indexOf(u8, b, "press s") != null);
    }

    // Running → flips to "Stop", still bound to `s`.
    act.daemon.store(@intFromEnum(DaemonState.running), .release);
    {
        const b = App.renderDaemonButton(a, &act);
        try std.testing.expect(std.mem.indexOf(u8, b, "Stop") != null);
        try std.testing.expect(std.mem.indexOf(u8, b, "press s") != null);
    }

    // Mid-transition shows the in-progress labels.
    act.daemon.store(@intFromEnum(DaemonState.starting), .release);
    try std.testing.expect(std.mem.indexOf(u8, App.renderDaemonButton(a, &act), "Starting") != null);
    act.daemon.store(@intFromEnum(DaemonState.stopping), .release);
    try std.testing.expect(std.mem.indexOf(u8, App.renderDaemonButton(a, &act), "Stopping") != null);
}

test "start is a no-op until the coin is installed" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    app.selected = std.mem.indexOfScalar(Entry, &entries, .divi).?;
    const act = &app.activities[app.selected];

    // Not installed: pressing start spawns nothing and the daemon stays stopped.
    act.installed = false;
    app.tryStart();
    try std.testing.expectEqual(DaemonState.stopped, act.daemonState());
    try std.testing.expect(act.daemon_thread == null);
}

test "stop is a no-op unless the daemon is running" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    app.selected = std.mem.indexOfScalar(Entry, &entries, .divi).?;
    const act = &app.activities[app.selected];

    // Installed but stopped: pressing stop spawns nothing and the state is left
    // alone (it doesn't slip into `.stopping`).
    act.installed = true;
    act.daemon.store(@intFromEnum(DaemonState.stopped), .release);
    app.tryStop();
    try std.testing.expectEqual(DaemonState.stopped, act.daemonState());
    try std.testing.expect(act.daemon_thread == null);
}

test "stop defers the worker while a status poll is in flight" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    app.selected = std.mem.indexOfScalar(Entry, &entries, .divi).?;
    const act = &app.activities[app.selected];
    act.installed = true;
    act.daemon.store(@intFromEnum(DaemonState.running), .release);

    // Simulate a status poll mid-flight with a real (immediately-returning)
    // thread handle, so `tryStop` takes the "poll in flight" branch.
    act.poll_thread = try std.Thread.spawn(.{}, struct {
        fn run() void {}
    }.run, .{});

    app.tryStop();

    // The UI thread must not have blocked joining the poll (the freeze bug), nor
    // spawned the stop worker yet — that's deferred to `onTick` once the poll is
    // reaped. The daemon still reads `.stopping` so the press gives immediate
    // feedback while we wait.
    try std.testing.expect(act.stop_pending);
    try std.testing.expect(act.daemon_thread == null);
    try std.testing.expectEqual(DaemonState.stopping, act.daemonState());

    // Reap the simulated poll so the test leaks no thread.
    act.poll_thread.?.join();
    act.poll_thread = null;
}

test "a poll does not resurrect a daemon we deliberately stopped" {
    // After BoxWallet stops a daemon, the node can keep answering for a moment as
    // it shuts down. A status poll landing in that window must NOT flip the daemon
    // back to running (which rendered as a stuck "Waiting for peers…"). The
    // `stopped_by_us` latch suppresses that; an unlatched stopped daemon (startup /
    // started outside BoxWallet) is still promoted to running.
    const reply = struct {
        fn mark(act: *Activity) void {
            act.poll_ok = true;
            act.poll_alive = true;
            act.poll_peers.store(0, .monotonic); // shutting down: peers dropped
        }
    };

    // Latched stop: a successful poll is folded in but the state stays stopped.
    var stopped: Activity = .{};
    stopped.daemon.store(@intFromEnum(DaemonState.stopped), .release);
    stopped.stopped_by_us = true;
    reply.mark(&stopped);
    try std.testing.expect(!stopped.shouldAdoptRunning());
    try std.testing.expectEqual(DaemonState.stopped, stopped.daemonState());

    // Same reply, but not stopped by us (e.g. a daemon already running at app
    // start) — it's correctly adopted as running.
    var external: Activity = .{};
    external.daemon.store(@intFromEnum(DaemonState.stopped), .release);
    reply.mark(&external);
    try std.testing.expect(external.shouldAdoptRunning());
}

test "an explicit start clears the stopped-by-us latch" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    app.selected = std.mem.indexOfScalar(Entry, &entries, .divi).?;
    const act = &app.activities[app.selected];
    act.installed = true;
    act.stopped_by_us = true;

    app.beginDaemonStart(app.coinAt(app.selected).?, act);
    // The latch is released so a later poll can promote the daemon again.
    try std.testing.expect(!act.stopped_by_us);

    // Reap the start worker so the test leaks no thread.
    if (act.daemon_thread) |t| {
        t.join();
        act.daemon_thread = null;
    }
}

test "App.init resolves install_root from home dir and deinit frees it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Minimal context: the home dir drives install_root and the persistent
    // allocator owns it. std.testing.allocator fails the test if `deinit`
    // doesn't free what `init` allocated.
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    try std.testing.expectEqualStrings("/home/tester/.boxwallet", app.install_root);
    try std.testing.expect(app.install_root_owned);
}

test "renderDetail renders the selected coin generically through the Coin interface" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    // Select Divi and render its detail pane. Nothing in renderDetail is Divi-
    // specific — the coin's name comes through the Coin vtable.
    app.selected = std.mem.indexOfScalar(Entry, &entries, .divi).?;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const out = app.renderDetail(arena.allocator());

    try std.testing.expect(std.mem.indexOf(u8, out, Divi.coin_name) != null);
}

test "coin pane renders a Disk bar from the app's disk-usage figure" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    // A quarter-full volume renders the Disk label and its 25% figure in the
    // pane, independent of any coin's sync/daemon state.
    app.selected = std.mem.indexOfScalar(Entry, &entries, .divi).?;
    app.disk_used = 1;
    app.disk_total = 4;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const out = app.renderDetail(arena.allocator());

    try std.testing.expect(std.mem.indexOf(u8, out, "Disk") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "25.0%") != null);
}

test "coin pane renders a Memory line with the current used figure" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    // Override the live reading with a half-used figure: the pane shows the
    // Memory label and that 50% figure alongside the sparkline graph.
    app.selected = std.mem.indexOfScalar(Entry, &entries, .divi).?;
    app.mem_used = 2;
    app.mem_total = 4;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const out = app.renderDetail(arena.allocator());

    try std.testing.expect(std.mem.indexOf(u8, out, "Memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "50.0%") != null);
}

test "coin pane renders a Storage line with the coin's on-disk size" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    // A sampled size of 1.5 GB (decimal) renders the Storage label and its
    // "1.50 GB" figure, independent of the coin's sync/daemon state.
    app.selected = std.mem.indexOfScalar(Entry, &entries, .divi).?;
    const act = &app.activities[app.selected];
    act.storage_bytes = 1_500_000_000;
    act.storage_sampled = true;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const out = app.renderDetail(arena.allocator());

    try std.testing.expect(std.mem.indexOf(u8, out, "Storage") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1.50 GB") != null);
}

test "dirSizeBytes sums apparent file sizes recursively; null for a missing dir" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "test-storage-out";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var d = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
    defer d.close(io);
    try d.writeFile(io, .{ .sub_path = "a.dat", .data = "x" ** 100 });
    try d.writeFile(io, .{ .sub_path = "b.dat", .data = "y" ** 250 });
    // A nested file, to prove the walk recurses into subdirectories.
    var sub = try d.createDirPathOpen(io, "blocks", .{});
    sub.close(io);
    try d.writeFile(io, .{ .sub_path = "blocks/c.dat", .data = "z" ** 400 });

    const total = dirSizeBytes(io, allocator, dir) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 750), total);

    // A path that doesn't resolve yields null (not a bogus 0), so the UI can
    // show "—" rather than "0.00 GB" for a coin with no data dir yet.
    try std.testing.expect(dirSizeBytes(io, allocator, "test-storage-out-missing") == null);
}

test "the Status line reflects the daemon's live activity" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    app.selected = std.mem.indexOfScalar(Entry, &entries, .divi).?;
    const act = &app.activities[app.selected];

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // An install in flight outranks the daemon state: download then extract.
    act.phase.store(@intFromEnum(Phase.downloading), .release);
    try std.testing.expect(std.mem.indexOf(u8, app.renderDetail(a), "Downloading…") != null);
    act.phase.store(@intFromEnum(Phase.extracting), .release);
    try std.testing.expect(std.mem.indexOf(u8, app.renderDetail(a), "Extracting…") != null);
    act.phase.store(@intFromEnum(Phase.idle), .release);

    // Installed but stopped → Idle.
    act.installed = true;
    act.daemon.store(@intFromEnum(DaemonState.stopped), .release);
    act.poll_completed = true; // not awaiting first poll
    try std.testing.expect(std.mem.indexOf(u8, app.renderDetail(a), "Idle") != null);

    // Running, still warming up (a phase was probed) → the phase is the status.
    act.daemon.store(@intFromEnum(DaemonState.running), .release);
    act.loading_phase = .verifying;
    try std.testing.expect(std.mem.indexOf(u8, app.renderDetail(a), "Verifying…") != null);

    // Warm-up done, no peers yet → waiting for peers.
    act.loading_phase = .none;
    act.peers = 0;
    try std.testing.expect(std.mem.indexOf(u8, app.renderDetail(a), "Waiting for peers…") != null);

    // Peers connected and caught up → Synced.
    act.peers = 8;
    act.sync = .synced;
    const out = app.renderDetail(a);
    try std.testing.expect(std.mem.indexOf(u8, out, "Synced") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Verifying") == null);
}

test "the Wallet line advertises the w key once the wallet is manageable" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    app.selected = std.mem.indexOfScalar(Entry, &entries, .divi).?;
    const act = &app.activities[app.selected];

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Daemon down / wallet unknown → no hint (a `w` press would be a no-op).
    act.daemon.store(@intFromEnum(DaemonState.stopped), .release);
    act.wallet = .unknown;
    try std.testing.expect(std.mem.indexOf(u8, app.renderDetail(a), "press w") == null);

    // Daemon up with a known wallet state → the hint appears beside the Wallet line.
    act.daemon.store(@intFromEnum(DaemonState.running), .release);
    act.wallet = .locked;
    try std.testing.expect(std.mem.indexOf(u8, app.renderDetail(a), "press w") != null);
}

test "the wallet modal renders its menu centered over the dashboard" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    // Open a Divi (proof-of-stake) wallet modal on a locked wallet by hand — the
    // open gate needs a running daemon, so set the modal up directly here.
    app.selected = std.mem.indexOfScalar(Entry, &entries, .divi).?;
    var m: Modal = .{ .coin_idx = app.selected };
    m.option_count = walletmenu.optionsFor(.locked, .{ .proof_of_stake = true, .encrypt = true }, &m.options);
    app.modal = m;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const screen = try App.renderTwoPane(a, app.selected, &.{}, "right pane\n", 0);
    const out = try app.renderModalOver(a, screen, 80, 24);

    // The modal's title and both locked-state actions appear in the composited
    // screen, framed by the box border.
    try std.testing.expect(std.mem.indexOf(u8, out, "Divi Wallet") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Unlock") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Unlock for staking") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "┘") != null);
}

test "Ergo's wallet menu offers unlock+replace when locked and lock+replace when open" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    app.selected = std.mem.indexOfScalar(Entry, &entries, .ergo).?;
    const act = &app.activities[app.selected];
    act.installed = true;
    act.daemon.store(@intFromEnum(DaemonState.running), .release);
    act.ext_wallet_exists = true;

    const coin = app.coinAt(app.selected).?;
    try std.testing.expect(coin.supportsWalletReplace());

    // Locked (not open this session) → Unlock + Replace.
    act.ext_wallet_open.store(0, .monotonic);
    app.openExternalWalletModal(coin, act);
    {
        const m = app.modal.?;
        try std.testing.expectEqual(Modal.Stage.setup_menu, m.stage);
        try std.testing.expectEqual(@as(usize, 2), m.setup_option_count);
        try std.testing.expectEqual(SetupChoice.unlock, m.setup_options[0]);
        try std.testing.expectEqual(SetupChoice.replace, m.setup_options[1]);
    }
    app.closeWalletModal();

    // Open → Lock + Replace.
    act.ext_wallet_open.store(1, .monotonic);
    app.openExternalWalletModal(coin, act);
    {
        const m = app.modal.?;
        try std.testing.expectEqual(@as(usize, 2), m.setup_option_count);
        try std.testing.expectEqual(SetupChoice.lock, m.setup_options[0]);
        try std.testing.expectEqual(SetupChoice.replace, m.setup_options[1]);
    }
    app.closeWalletModal();
}

test "the external-wallet setup menu renders its create/restore choices" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    // Open Nerva's setup menu directly (the real gate needs a running daemon +
    // wallet service). Populate the choice list the way `openExternalWalletModal`
    // would — Nerva wires `restore_file`, so all three appear.
    app.selected = std.mem.indexOfScalar(Entry, &entries, .nerva).?;
    var m: Modal = .{ .coin_idx = app.selected, .stage = .setup_menu };
    m.setup_option_count = menuChoicesFor(app.coinAt(app.selected).?, &m.setup_options);
    app.modal = m;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const screen = try App.renderTwoPane(a, app.selected, &.{}, "right pane\n", 0);
    const out = try app.renderModalOver(a, screen, 80, 24);

    try std.testing.expect(std.mem.indexOf(u8, out, "Nerva Wallet") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Create a new wallet") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Restore from seed words") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Restore from a wallet file") != null);
}

test "clipToWidth caps each line to the terminal width without wrapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Nothing over width → returned untouched (and no copy).
    const fits = "abc\ndef";
    try std.testing.expectEqual(fits.ptr, clipToWidth(a, fits, 10).ptr);

    // width 0 (unknown terminal) is a no-op.
    try std.testing.expectEqual(fits.ptr, clipToWidth(a, fits, 0).ptr);

    // A line past the cap is trimmed to exactly `max_w` visible columns; short
    // lines on either side are preserved verbatim.
    const clipped = clipToWidth(a, "hi\nABCDEFGHIJ\nyo", 5);
    var it = std.mem.splitScalar(u8, clipped, '\n');
    try std.testing.expectEqualStrings("hi", it.next().?);
    const mid = it.next().?;
    try std.testing.expect(zz.width(mid) <= 5);
    try std.testing.expect(std.mem.startsWith(u8, mid, "ABCDE"));
    try std.testing.expectEqualStrings("yo", it.next().?);

    // ANSI styling is zero-width: a styled-but-short line is left intact, escapes
    // and all (here a red "hi" well under the cap).
    const styled = (zz.Style{}).fg(.red).render(a, "hi") catch "hi";
    try std.testing.expect(zz.width(styled) <= 4);
    try std.testing.expectEqualStrings(styled, clipToWidth(a, styled, 4));
}

test "left bar pins Home on top and lists coins alphabetically" {
    // Home is always first; everything after it is sorted by label, regardless
    // of the order coins are registered in `coin_entries`.
    try std.testing.expectEqual(Entry.home, entries[0]);

    var prev: ?[]const u8 = null;
    for (entries[1..]) |e| {
        try std.testing.expect(e != .home);
        const label = entryLabel(e);
        if (prev) |p| try std.testing.expect(std.mem.lessThan(u8, p, label));
        prev = label;
    }
}

test "only live coins appear in the nav" {
    // Home is always present; every other registered coin appears iff its `live`
    // flag is set. Holds regardless of which coins are currently live.
    try std.testing.expect(std.mem.indexOfScalar(Entry, &entries, .home) != null);
    inline for (coin_entries) |e| {
        const present = std.mem.indexOfScalar(Entry, &entries, e) != null;
        try std.testing.expectEqual(entryLive(e), present);
    }
}

test "left bar paints only the selected coin in its brand colour, the rest grey" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Locate two coins' rows in the sorted nav column so we can select one and
    // leave the other unselected.
    const nexa_idx = std.mem.indexOfScalar(Entry, &entries, .nexa).?;
    const divi_idx = std.mem.indexOfScalar(Entry, &entries, .divi).?;

    // True-colour SGR codes (38;2;r;g;b) the nav emits for each relevant colour.
    const seq = struct {
        fn of(al: std.mem.Allocator, color: zz.Color) ![]const u8 {
            const rgb = color.toRgb().?;
            return std.fmt.allocPrint(al, "38;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b });
        }
    }.of;
    const nexa_seq = try seq(a, zz.Color.hex(Nexa.coin_color));
    const divi_seq = try seq(a, zz.Color.hex(Divi.coin_color));
    const grey_seq = try seq(a, zz.Color.hex(nav_dim_color));

    // Select Nexa: its brand colour shows, Divi (unselected) is greyed instead.
    const screen = try App.renderTwoPane(a, nexa_idx, &.{}, "", 0);
    try std.testing.expect(std.mem.indexOf(u8, screen, nexa_seq) != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, grey_seq) != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, divi_seq) == null);

    // Switching the selection to Divi flips which one carries its brand colour.
    const screen2 = try App.renderTwoPane(a, divi_idx, &.{}, "", 0);
    try std.testing.expect(std.mem.indexOf(u8, screen2, divi_seq) != null);
    try std.testing.expect(std.mem.indexOf(u8, screen2, nexa_seq) == null);
}

test "left-nav brackets the selected row with a closing marker, keeping the separator aligned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Exactly one row carries the closing `❮`, and it is the same row as the
    // opening `❯` — the pair brackets the selection rather than floating apart.
    const screen = try App.renderTwoPane(a, 1, &.{}, "", 0);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, screen, "❮"));
    var it = std.mem.splitScalar(u8, screen, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "❮") == null) continue;
        try std.testing.expect(std.mem.indexOf(u8, line, "❯") != null);
    }

    // The trailing marker column is padded on every row, so `│` still lands on
    // the same visible column throughout the frame.
    var it2 = std.mem.splitScalar(u8, screen, '\n');
    while (it2.next()) |line| {
        if (line.len == 0) continue;
        const sep = std.mem.indexOf(u8, line, "│") orelse continue;
        try std.testing.expectEqual(nav_col_w + 1, zz.width(line[0..sep]));
    }
}

test "left-nav shows an update arrow only for non-selected coins with a pending update" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nexa_idx = std.mem.indexOfScalar(Entry, &entries, .nexa).?;
    const home_idx = std.mem.indexOfScalar(Entry, &entries, .home).?;

    var updates = [_]bool{false} ** entries.len;
    updates[nexa_idx] = true;

    // Home selected → Nexa is non-selected → it carries the ⬆ marker.
    const screen = try App.renderTwoPane(a, home_idx, &updates, "", 0);
    try std.testing.expect(std.mem.indexOf(u8, screen, "⬆") != null);

    // No pending updates → no arrow anywhere.
    const none = [_]bool{false} ** entries.len;
    const screen2 = try App.renderTwoPane(a, home_idx, &none, "", 0);
    try std.testing.expect(std.mem.indexOf(u8, screen2, "⬆") == null);

    // When the updating coin is selected, its selection arrow takes the marker
    // slot — no ⬆ doubled up (the detail badge covers it there).
    const screen3 = try App.renderTwoPane(a, nexa_idx, &updates, "", 0);
    try std.testing.expect(std.mem.indexOf(u8, screen3, "⬆") == null);
}

test "navWindow keeps the selection visible and flags the hidden sides" {
    // Everything fits (or the height is unbounded) → the whole list, no
    // indicators — the large-terminal fast path.
    var w = navWindow(3, 10, 10);
    try std.testing.expectEqual(NavWindow{ .start = 0, .len = 10, .more_above = false, .more_below = false }, w);
    w = navWindow(3, 10, 99);
    try std.testing.expectEqual(NavWindow{ .start = 0, .len = 10, .more_above = false, .more_below = false }, w);

    // Overflow, selection at the top: window anchors at 0, only "below" flagged,
    // and the indicator eats the bottom row of a 5-row viewport (4 coins shown).
    w = navWindow(0, 10, 5);
    try std.testing.expectEqual(NavWindow{ .start = 0, .len = 4, .more_above = false, .more_below = true }, w);

    // Selection in the middle: both sides flagged, both edge rows become
    // indicators, and the selection sits inside the visible slice.
    w = navWindow(5, 10, 5);
    try std.testing.expect(w.more_above and w.more_below);
    try std.testing.expectEqual(@as(usize, 3), w.len);
    try std.testing.expect(5 >= w.start and 5 < w.start + w.len);

    // Selection at the end: window clamps to the tail, only "above" flagged.
    w = navWindow(9, 10, 5);
    try std.testing.expect(w.more_above and !w.more_below);
    try std.testing.expect(9 >= w.start and 9 < w.start + w.len);

    // 1–2 rows are too tight for indicators: the selection is still shown.
    w = navWindow(5, 10, 1);
    try std.testing.expectEqual(NavWindow{ .start = 5, .len = 1, .more_above = false, .more_below = false }, w);
    w = navWindow(5, 10, 2);
    try std.testing.expect(5 >= w.start and 5 < w.start + w.len);
    try std.testing.expect(!w.more_above and !w.more_below);

    // Zero rows: nothing visible, nothing flagged (Home-only nav).
    w = navWindow(5, 10, 0);
    try std.testing.expectEqual(@as(usize, 0), w.len);
    try std.testing.expect(!w.more_above and !w.more_below);
}

test "navRows maps a clicked screen row to the entry drawn on it" {
    var rows: [entries.len + 2]NavRow = undefined;

    // Unbounded height (0): Home on row 0, then every coin in order — so row N
    // is entry N, which is what a click on an uncrowded terminal must resolve to.
    var n = navRows(0, 0, &rows);
    try std.testing.expectEqual(entries.len, n);
    for (0..entries.len) |i| try std.testing.expectEqual(NavRow{ .entry = i }, rows[i]);

    // Home stays pinned on row 0 whatever is selected, and clicking it must land
    // on Home rather than on whatever the coin window scrolled to that row.
    n = navRows(entries.len - 1, 6, &rows);
    try std.testing.expectEqual(NavRow{ .entry = 0 }, rows[0]);

    // Scrolled window: the indicator rows are not entries, so a click on one
    // selects nothing (rather than silently picking the coin behind the arrow).
    // With the last coin selected in a 6-row nav, row 1 is the "more above" arrow.
    try std.testing.expectEqual(NavRow.more_above, rows[1]);

    // Every entry row still points at a real, in-range entry, and the selected
    // coin is always on one of them — a click can never resolve out of bounds.
    var saw_selected = false;
    for (rows[0..n]) |r| switch (r) {
        .entry => |ei| {
            try std.testing.expect(ei < entries.len);
            if (ei == entries.len - 1) saw_selected = true;
        },
        .more_above, .more_below => {},
    };
    try std.testing.expect(saw_selected);

    // The rows never overrun the buffer, at any height.
    for (0..entries.len + 4) |h| {
        n = navRows(0, h, &rows);
        try std.testing.expect(n <= rows.len);
    }
}

test "left bar windows the coins to the nav height with Home pinned on top" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Needs enough coins that a 5-row nav actually overflows.
    if (entries.len <= 5) return error.SkipZigTest;

    // Select the last coin with only 5 nav rows: Home stays on the first row,
    // the selection marker is drawn (the selected coin is in the window — its
    // label may be a two-tone wordmark, so the marker is the reliable probe),
    // the alphabetically-first coin has scrolled out, and the "more above"
    // indicator marks the hidden stretch. Exactly 5 rows come back.
    const last_idx = entries.len - 1;
    const screen = try App.renderTwoPane(a, last_idx, &.{}, "", 5);
    var it = std.mem.splitScalar(u8, screen, '\n');
    try std.testing.expect(std.mem.indexOf(u8, it.next().?, home_brand_text) != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "❯") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, entryLabel(entries[1])) == null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "↑ ···") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "↓ ···") == null);
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, screen, "\n"));

    // Selecting the first coin flips the picture: the window sits at the top,
    // the last coin is the one hidden, and the hidden stretch is below.
    const screen2 = try App.renderTwoPane(a, 1, &.{}, "", 5);
    try std.testing.expect(std.mem.indexOf(u8, screen2, "❯") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen2, entryLabel(entries[last_idx])) == null);
    try std.testing.expect(std.mem.indexOf(u8, screen2, "↓ ···") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen2, "↑ ···") == null);

    // A viewport that fits everything renders byte-identically to the
    // unbounded call — the large-terminal regression guard.
    const bounded = try App.renderTwoPane(a, 1, &.{}, "right\n", entries.len + 2);
    const unbounded = try App.renderTwoPane(a, 1, &.{}, "right\n", 0);
    try std.testing.expectEqualStrings(unbounded, bounded);
}

test "clipToHeight keeps at most max_h rows and the top intact" {
    // Fits → returned untouched (same pointer, no copy); 0 (unknown) is a no-op.
    const fits = "a\nb\n";
    try std.testing.expectEqual(fits.ptr, clipToHeight(fits, 5).ptr);
    try std.testing.expectEqual(fits.ptr, clipToHeight(fits, 0).ptr);

    // Overflow → exactly max_h newline-terminated rows, first row intact.
    const clipped = clipToHeight("one\ntwo\nthree\nfour\n", 2);
    try std.testing.expectEqualStrings("one\ntwo\n", clipped);
}

test "Home summary lists coins with a pending update" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Nothing pending → empty summary (the Home line vanishes).
    try std.testing.expectEqualStrings("", app.coinUpdateSummary(a));

    // Flag Nexa as having an update → it's named in the summary.
    const nexa_idx = std.mem.indexOfScalar(Entry, &entries, .nexa).?;
    app.activities[nexa_idx].update_available = true;
    const s = app.coinUpdateSummary(a);
    try std.testing.expect(std.mem.indexOf(u8, s, "Coin updates available") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, entryLabel(.nexa)) != null);
}

test "coins installing into one root use distinct download scratch files" {
    // The two-coin concurrency this UI enables means several installs can target
    // the same `~/.boxwallet` root at once. Each coin streams its download to a
    // scratch file derived from its own daemon name, so the temp files never
    // collide. (Anchors the contract `downloadAndExtract`'s `scratch_name` relies
    // on; both names are non-empty and unique per coin.)
    try std.testing.expect(Nexa.scratch_file.len > 0);
    try std.testing.expect(Divi.scratch_file.len > 0);
    try std.testing.expect(!std.mem.eql(u8, Nexa.scratch_file, Divi.scratch_file));
}

test "per-coin activity is independent and stays inside the right pane" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    app.hide_balances = false;
    _ = app.init(&ctx);
    defer app.deinit();

    const ni = std.mem.indexOfScalar(Entry, &entries, .nexa).?;
    const di = std.mem.indexOfScalar(Entry, &entries, .divi).?;

    // Drive two coins into different stages at once — no threads needed: feed
    // the progress sink directly. Nexa mid-download, Divi mid-extract.
    Activity.onProgress(&app.activities[ni], .download, 50, 100);
    Activity.onProgress(&app.activities[di], .extract, 1, 0);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Each coin's pane shows its own stage, and nothing of the other coin's.
    app.selected = ni;
    const nexa_pane = app.renderDetail(a);
    try std.testing.expect(std.mem.indexOf(u8, nexa_pane, "Downloading") != null);
    try std.testing.expect(std.mem.indexOf(u8, nexa_pane, "installing") != null);

    app.selected = di;
    const divi_pane = app.renderDetail(a);
    try std.testing.expect(std.mem.indexOf(u8, divi_pane, "Extracting") != null);

    // The two-pane layout still lists every coin on the left, whatever each is
    // doing — the activity is confined to the right of the separator.
    const screen = try App.renderTwoPane(a, app.selected, &.{}, divi_pane, 0);
    try std.testing.expect(std.mem.indexOf(u8, screen, Nexa.coin_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, Divi.coin_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "│") != null);
}

test "the header balance shows Total always and Available only while funds settle" {
    // renderCoin allocates many short-lived styled strings; like the other pane
    // tests, run it on an arena rather than the testing allocator.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nexa: Nexa = .{};
    const coin = nexa.coin();

    var act: Activity = .{
        .coin = coin,
        .home_dir = "",
        .spinner = App.makeSpinner(),
        .daemon_spinner = App.makeSpinner(),
        .sync_spinner = zz.Spinner.init(),
    };
    act.installed = true;
    act.daemon.store(@intFromEnum(DaemonState.running), .release);
    act.poll_completed = true;

    // renderCoin only touches the disk/memory gauge fields and the active tab off
    // `self`; the rest of the App is unused, so a minimal stand-in is enough.
    var app: App = undefined;
    app.hide_balances = false;
    app.disk_used = 0;
    app.disk_total = 0;
    app.mem_used = 0;
    app.mem_total = 0;
    app.active_tab = .home;

    // The label, figure and abbrev are independently styled, so they aren't a
    // single contiguous substring — assert on each piece.

    // Always shown for a balance-capable coin, even before a poll: Total label +
    // abbrev present, no Available (nothing pending).
    {
        const pane = try App.renderCoin(&app, a, coin, &act);
        try std.testing.expect(std.mem.indexOf(u8, pane, "Total:") != null);
        try std.testing.expect(std.mem.indexOf(u8, pane, "NEXA") != null);
        try std.testing.expect(std.mem.indexOf(u8, pane, "Available") == null);
    }

    // Funds in the mempool: Total is ahead of Available, so both show — with
    // thousands separators on the figures.
    act.has_balance = true;
    act.balance_total = 1234.5;
    act.balance_avail = 1000.0;
    {
        const pane = try App.renderCoin(&app, a, coin, &act);
        try std.testing.expect(std.mem.indexOf(u8, pane, "Total:") != null);
        try std.testing.expect(std.mem.indexOf(u8, pane, "1,234.5") != null);
        try std.testing.expect(std.mem.indexOf(u8, pane, "Available:") != null);
        try std.testing.expect(std.mem.indexOf(u8, pane, "1,000") != null);
    }

    // Settled (Available caught up to Total): only the Total remains.
    act.balance_avail = 1234.5;
    {
        const pane = try App.renderCoin(&app, a, coin, &act);
        try std.testing.expect(std.mem.indexOf(u8, pane, "1,234.5") != null);
        try std.testing.expect(std.mem.indexOf(u8, pane, "Available") == null);
    }
}

test "hide_balances masks the header figure and drops Available" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nexa: Nexa = .{};
    const coin = nexa.coin();

    var act: Activity = .{
        .coin = coin,
        .home_dir = "",
        .spinner = App.makeSpinner(),
        .daemon_spinner = App.makeSpinner(),
        .sync_spinner = zz.Spinner.init(),
    };
    act.installed = true;
    act.daemon.store(@intFromEnum(DaemonState.running), .release);
    act.poll_completed = true;
    // Pending funds: without hiding this would surface a second "Available" figure.
    act.has_balance = true;
    act.balance_total = 1234.5;
    act.balance_avail = 1000.0;

    var app: App = undefined;
    app.disk_used = 0;
    app.disk_total = 0;
    app.mem_used = 0;
    app.mem_total = 0;
    app.active_tab = .home;
    app.hide_balances = true;

    const pane = try App.renderCoin(&app, a, coin, &act);
    // The label and abbrev stay; the amount is masked and no digits leak.
    try std.testing.expect(std.mem.indexOf(u8, pane, "Total:") != null);
    try std.testing.expect(std.mem.indexOf(u8, pane, balance_mask) != null);
    try std.testing.expect(std.mem.indexOf(u8, pane, "1,234.5") == null);
    try std.testing.expect(std.mem.indexOf(u8, pane, "1,000") == null);
    // Available is suppressed while hidden so pending funds aren't implied.
    try std.testing.expect(std.mem.indexOf(u8, pane, "Available") == null);
}

/// The process state letter from `/proc/<pid>/stat` ('Z' for a zombie), or null
/// if the pid is gone. Parsed from the field after the `comm` column, which is
/// parenthesised and may itself contain spaces — so scan from the *last* ')'.
fn procState(io: std.Io, pid: std.posix.pid_t) ?u8 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return null;
    var buf: [512]u8 = undefined;
    var f = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer f.close(io);
    const n = f.readPositionalAll(io, &buf, 0) catch return null;
    const close = std.mem.lastIndexOfScalar(u8, buf[0..n], ')') orelse return null;
    // "…) S …" — skip the ')' and the single space before the state letter.
    if (close + 2 >= n) return null;
    return buf[close + 2];
}

test "a foreground daemon that exits on its own is reaped, not left a zombie" {
    // Regression test for real zombies observed in the wild: three defunct Ergo
    // JVMs parented to a long-running BoxWallet. A foreground daemon is spawned
    // detached and deliberately not waited on (it must outlive `launchDaemon`),
    // but we stay its parent — so when it exits by any route other than the kill
    // path (an RPC shutdown, or a crash), someone still has to wait on it. Before
    // the fix nobody did, and it sat defunct for the life of the app.
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest; // needs /proc

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Stands in for a foreground daemon that exits behind our back.
    const child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const pid = child.id.?;

    var act: Activity = .{};
    act.daemon_child = child;

    // Let it exit. Unreaped, it must go defunct — that's the bug this guards.
    var waited: u8 = 0;
    while (waited < 100) : (waited += 1) {
        if (procState(io, pid) == 'Z') break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(?u8, 'Z'), procState(io, pid));

    // The tick reap collects it: the pid leaves the table and the handle is
    // marked reaped so nothing waits on it twice.
    act.reapDaemonChild();
    try std.testing.expect(procState(io, pid) != 'Z');
    try std.testing.expectEqual(@as(?std.posix.pid_t, null), act.daemon_child.?.id);

    // Idempotent — the tick calls this on every frame.
    act.reapDaemonChild();
    try std.testing.expectEqual(@as(?std.posix.pid_t, null), act.daemon_child.?.id);
}

test "reaping is a no-op for a live child and when no daemon was launched here" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest; // needs /proc

    // No handle (a daemon left by a prior session, or none started) — must not
    // touch anything.
    var none: Activity = .{};
    none.reapDaemonChild();
    try std.testing.expectEqual(@as(?std.process.Child, null), none.daemon_child);

    // A *running* daemon must survive the tick reap — WNOHANG means "collect it
    // if it's dead", never "wait for it".
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const pid = child.id.?;
    defer child.kill(io); // reaps as it kills

    var live: Activity = .{};
    live.daemon_child = child;
    live.reapDaemonChild();
    try std.testing.expectEqual(@as(?std.posix.pid_t, pid), live.daemon_child.?.id);
    try std.testing.expect(procState(io, pid) != 'Z');
}

test "every prune menu row fits the modal box" {
    // `modalRow` pads a short row out to `inner_w` but never truncates a long one,
    // so a label wider than the box pushes the right-hand border out and the modal
    // renders ragged. The menu marker ("❯ ") costs two columns on top of the label,
    // as does the "Custom…" row's — so that's the budget every label has to fit.
    const budget = modal_inner_w - zz.width("❯ ");
    try std.testing.expect(zz.width("Custom…") <= budget);

    inline for (.{ Bitcoin, Litecoin, Monero }) |C| {
        for (C.pruning_caps.presets) |preset| {
            std.testing.expect(zz.width(preset.label) <= budget) catch |err| {
                std.debug.print(
                    "prune label overruns the modal ({d} > {d}): \"{s}\"\n",
                    .{ zz.width(preset.label), budget, preset.label },
                );
                return err;
            };
        }
    }
}

test "price display is gated on the toggle, listing, and staleness" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    _ = app.init(&ctx);
    defer app.deinit();

    // Pick any coin slot (index 0 is Home, so 1 is a coin).
    const idx: usize = 1;
    app.show_prices = true;
    app.prices[idx] = .{ .usd = 64435, .change_24h = 0.31, .have = true };
    app.price_fetched_at = std.Io.Timestamp.now(io, .real).toSeconds();

    // Fresh + listed + enabled → shown.
    try std.testing.expect(app.quoteAt(idx) != null);

    // Switched off → nothing, whatever is cached.
    app.show_prices = false;
    try std.testing.expect(app.quoteAt(idx) == null);
    app.show_prices = true;

    // An unlisted coin (SpiderByte's shape: no quote ever filled in) → nothing,
    // rather than a misleading $0.00.
    app.prices[idx] = .{};
    try std.testing.expect(app.quoteAt(idx) == null);
    app.prices[idx] = .{ .usd = 64435, .change_24h = 0.31, .have = true };
    try std.testing.expect(app.quoteAt(idx) != null);

    // Stale beyond the max age → dropped, so a dead feed never keeps
    // misrepresenting what a balance is worth.
    app.price_fetched_at = std.Io.Timestamp.now(io, .real).toSeconds() - (price.max_age_s + 1);
    try std.testing.expect(app.quoteAt(idx) == null);

    // Never fetched at all → nothing.
    app.price_fetched_at = 0;
    try std.testing.expect(app.quoteAt(idx) == null);
}

test "priceCorner masks the holding's value but keeps the public unit price" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const q: price.Quote = .{ .usd = 2.114e-05, .change_24h = -5.52, .have = true };

    // Visible: both the worth of the holding and the unit price.
    const shown = App.priceCorner(a, q, 1_000_000, false);
    try std.testing.expect(std.mem.indexOf(u8, shown, "$21.14") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "$0.00002114") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "▼ 5.52%") != null);

    // Hidden: the value is masked (it's derived from the balance), but the unit
    // price — public market data — stays.
    const hidden = App.priceCorner(a, q, 1_000_000, true);
    try std.testing.expect(std.mem.indexOf(u8, hidden, balance_mask) != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden, "$21.14") == null);
    try std.testing.expect(std.mem.indexOf(u8, hidden, "$0.00002114") != null);

    // A coin priced without a 24h figure (Nexa) draws no arrow at all.
    const no_change: price.Quote = .{ .usd = 0.00120172, .change_24h = null, .have = true };
    const plain = App.priceCorner(a, no_change, 100, false);
    try std.testing.expect(std.mem.indexOf(u8, plain, "▲") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "▼") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "$0.001202") != null);
}

test "the price roster covers every listed coin and omits unlisted ones" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    _ = app.init(&ctx);
    defer app.deinit();

    var ids: [entries.len][]const u8 = undefined;
    var slots: [entries.len]usize = undefined;
    const n = app.priceRoster(&ids, &slots);

    // Every id is non-empty, and each maps back to the coin that declared it.
    try std.testing.expect(n > 0);
    for (0..n) |k| {
        try std.testing.expect(ids[k].len > 0);
        const c = app.coinAt(slots[k]).?;
        try std.testing.expectEqualStrings(c.priceId().?, ids[k]);
    }

    // SpiderByte declares no price id, so it must not be in the request.
    for (0..n) |k| {
        try std.testing.expect(!std.mem.eql(u8, ids[k], "spiderbyte"));
    }

    // The roster is exactly the coins declaring an id — count them independently.
    var expected: usize = 0;
    for (entries, 0..) |e, i| {
        if (e == .home) continue;
        if (app.coinAt(i).?.priceId() != null) expected += 1;
    }
    try std.testing.expectEqual(expected, n);
}

