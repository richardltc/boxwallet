const std = @import("std");
const zz = @import("zigzag");
const models = @import("models.zig");
const install_mod = @import("install.zig");
const Coin = @import("coin.zig").Coin;
const Nexa = @import("coins/nexa.zig").Nexa;
const Divi = @import("coins/divi.zig").Divi;

/// The application's display name, version, and brand colour — the one place to
/// change how BoxWallet identifies itself in the UI. `app_color` is the brand
/// hex used for the "BoxWallet" wording on the Home pane.
pub const app_name = "BoxWallet TUI";
pub const app_version = "0.0.1";
const app_color = "#7ca071";

/// Fallback install root used only if the home-dir-based path can't be built
/// (e.g. allocation failure at startup). Normally `App.install_root` is the
/// per-platform `~/.boxwallet` dir resolved in `init`.
const fallback_install_root = "boxwallet-coins";

/// Every coin registered in the left bar. Order here is irrelevant — `entries`
/// sorts them alphabetically below — so a newly ported coin can be added in any
/// position. Adding a coin is a matter of extending this list, the `App` field +
/// `init`, and the dispatch in `selectedCoin`; the detail pane renders
/// generically through the `Coin` interface, so it needs no per-coin code.
const Entry = enum { home, nexa, divi };
const coin_entries = [_]Entry{ .nexa, .divi };

fn entryLabel(e: Entry) []const u8 {
    return switch (e) {
        .home => "Home",
        .nexa => Nexa.coin_name,
        .divi => Divi.coin_name,
    };
}

/// The colour each entry is drawn in on the left nav. Coins use their own brand
/// colour (parsed from the per-coin `coin_color` hex); Home has none and renders
/// in the terminal default.
fn entryColor(e: Entry) zz.Color {
    return switch (e) {
        .home => .none,
        .nexa => zz.Color.hex(Nexa.coin_color),
        .divi => zz.Color.hex(Divi.coin_color),
    };
}

/// The left-column order: Home pinned to the top, then the coins alphabetically
/// by label. The sort runs at comptime, so registering a coin keeps the list
/// ordered without anyone placing it by hand. Index 0 is always Home; the rest
/// are coins, and `activities` is indexed parallel to this.
const entries = blk: {
    var coins = coin_entries;
    std.mem.sort(Entry, &coins, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, entryLabel(a), entryLabel(b));
        }
    }.lessThan);
    break :blk [_]Entry{.home} ++ coins;
};

/// Where a coin's background install has got to. The UI reads this every frame
/// to paint the coin's pane; the worker thread advances it.
const Phase = enum(u8) { idle, downloading, extracting, done, failed };

/// Whether a coin's daemon is up. `starting` shows a spinner in the pane; the
/// actual start/stop wiring lands later — for now this is UI scaffolding that
/// defaults to `stopped`.
const DaemonState = enum { stopped, starting, running };

/// Chain sync progress. `syncing` shows a spinner ("Syncing"), `synced` a green
/// tick ("Synced"), `idle` a red cross. Live sync polling lands later — for now
/// this defaults to `idle`.
const SyncState = enum { idle, syncing, synced };

/// Wallet encryption/lock status. Live wallet polling lands later — for now this
/// defaults to `unknown`. Each state carries its own display text and colour.
const WalletState = enum {
    unknown,
    unencrypted,
    locked,
    unlocked,
    unlocked_for_staking,

    fn text(self: WalletState) []const u8 {
        return switch (self) {
            .unknown => "Unknown",
            .unencrypted => "Unencrypted",
            .locked => "Locked",
            .unlocked => "Unlocked",
            .unlocked_for_staking => "Unlocked for staking",
        };
    }

    fn color(self: WalletState) zz.Color {
        return switch (self) {
            .unknown => .brightBlack,
            .unencrypted => .red,
            .locked => .yellow,
            .unlocked => .cyan,
            .unlocked_for_staking => .green,
        };
    }
};

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

    // --- worker inputs: set by the UI before spawn, read by the worker -----
    coin: Coin = undefined,
    install_root: []const u8 = "",

    // --- UI-thread-only ----------------------------------------------------
    thread: ?std.Thread = null,
    /// Joins the daemon-start worker once it has published its result.
    daemon_thread: ?std.Thread = null,
    /// True when this run updates an existing daemon (heading reads "updating").
    updating: bool = false,
    /// Cleared when a run starts, set once its completion has been folded back
    /// into `installed` — so we re-check the daemon on disk exactly once.
    acked: bool = true,
    /// Cached "is the daemon on disk?", for the idle view + button label.
    installed: bool = false,
    /// Whether this coin's daemon is up. Drives the "daemon running" line.
    /// Written by the daemon-start worker (release) and read by the UI
    /// (acquire), so it's atomic like `phase`.
    daemon: std.atomic.Value(u8) = .init(@intFromEnum(DaemonState.stopped)),
    /// Connected peer count. Red at 0, green once any peer is connected.
    /// (Live peer polling lands later — for now this stays 0.)
    peers: u32 = 0,
    /// Chain sync state. Drives the "Syncing"/"Synced" line.
    sync: SyncState = .idle,
    /// Wallet encryption/lock status. Drives the "Wallet" line.
    wallet: WalletState = .unknown,
    /// Whether the wallet is actively staking. Only shown for proof-of-stake
    /// coins; live staking polling lands later — for now this stays false.
    staking: bool = false,
    /// Headers/blocks sync progress (current vs total). Populated by the live
    /// sync poll later; 0/0 renders an empty bar.
    headers_cur: u64 = 0,
    headers_total: u64 = 0,
    blocks_cur: u64 = 0,
    blocks_total: u64 = 0,
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

    /// Worker thread body. Installs the coin on a private arena (so memory is
    /// bounded and isolated from the other coins' workers and the UI), then
    /// publishes the outcome.
    fn run(self: *Activity) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const progress: install_mod.Progress = .{ .ctx = self, .func = onProgress };
        if (self.coin.install(a, self.install_root, progress)) {
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
        } else |_| {
            self.daemon.store(@intFromEnum(DaemonState.stopped), .release);
        }
    }

    /// Spawn the daemon binary with `-daemon` and wait for the launcher to
    /// return (it daemonizes, so the wait is brief). Errors on a missing binary
    /// or a non-zero exit. `argv[0]` carries a path separator, so it's resolved
    /// as a file path rather than via PATH.
    fn launchDaemon(self: *Activity, a: std.mem.Allocator) !void {
        const path = try std.fs.path.join(a, &.{ self.install_root, self.coin.daemonFile() });

        var threaded: std.Io.Threaded = .init(a, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var child = try std.process.spawn(io, .{
            .argv = &.{ path, "-daemon" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        switch (try child.wait(io)) {
            .exited => |code| if (code != 0) return error.DaemonStartFailed,
            else => return error.DaemonStartFailed,
        }
    }
};

/// Bounded action log. One fixed-capacity line per entry, kept in a ring so the
/// log's memory is flat regardless of how long the session runs (per the
/// project's memory constraint — no growing buffer).
const log_capacity = 128;
const log_line_max = 120;
const LogLine = struct {
    buf: [log_line_max]u8 = undefined,
    len: usize = 0,
};

/// Default / clamp bounds for the resizable log pane height (in rows).
const log_height_default = 6;
const log_height_min = 1;
const log_height_max = 30;

/// Outlook-style master/detail TUI: a navigation column on the left (Home +
/// coins) is always visible, a detail pane on the right shows the selected
/// coin. `up`/`down` move the selection, `i` installs/updates the selected
/// coin's daemon (in the background — you can navigate away while it runs), `q`
/// quits. A resizable action log runs along the bottom (`+`/`-` resize it).
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
    nexa: Nexa,
    divi: Divi,
    selected: usize,
    /// One per `entries` slot (index 0 / Home is unused), holding that coin's
    /// independent install state. Parallel to `entries` so the selected coin's
    /// activity is `activities[selected]`.
    activities: [entries.len]Activity,
    /// Ring buffer of recent action messages, painted in the bottom log pane.
    log_lines: [log_capacity]LogLine = [_]LogLine{.{}} ** log_capacity,
    /// Total messages ever logged; the live slot is `log_count % log_capacity`.
    log_count: usize = 0,
    /// Current height (rows) of the bottom log pane; `+`/`-` adjust it.
    log_height: u16 = log_height_default,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
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

        self.* = .{
            .allocator = ctx.persistent_allocator,
            .install_root = install_root,
            .install_root_owned = install_root_owned,
            .nexa = .{},
            .divi = .{},
            .selected = 0,
            .activities = undefined,
        };
        for (&self.activities) |*act| act.* = .{ .spinner = zz.Spinner.init(), .daemon_spinner = zz.Spinner.init(), .sync_spinner = zz.Spinner.init() };
        self.refreshSelectedInstalled();

        // A modest repeating tick so background installs animate and their
        // completions are noticed without waiting on a keypress. Idle ticks are
        // cheap — the renderer only repaints when the view actually changes.
        return .{ .every = 100 * std.time.ns_per_ms };
    }

    /// Called by ZigZag's `Program.deinit` at shutdown. Joins any in-flight
    /// install workers (so they don't outlive the state they write into), then
    /// frees the model's owned allocations.
    pub fn deinit(self: *App) void {
        for (&self.activities) |*act| {
            if (act.thread) |t| {
                t.join();
                act.thread = null;
            }
            if (act.daemon_thread) |t| {
                t.join();
                act.daemon_thread = null;
            }
        }
        if (self.install_root_owned) self.allocator.free(self.install_root);
    }

    pub fn update(self: *App, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |k| switch (k.key) {
                .char => |c| switch (c) {
                    'q' => return .quit,
                    'i' => self.tryInstall(),
                    's' => self.tryStart(),
                    'k' => self.move(-1),
                    'j' => self.move(1),
                    '+', '=' => self.resizeLog(1),
                    '-', '_' => self.resizeLog(-1),
                    else => {},
                },
                .up => self.move(-1),
                .down => self.move(1),
                else => {},
            },
            .tick => |t| self.onTick(t),
        }
        return .none;
    }

    /// Per-tick housekeeping for every coin's activity: animate the extract
    /// spinner while extracting, and — once — reap a finished worker and refresh
    /// the cached installed flag from disk.
    fn onTick(self: *App, t: zz.msg.Tick) void {
        for (&self.activities, 0..) |*act, i| {
            if (entries[i] == .home) continue;
            const p = act.phaseOf();
            if (p == .extracting) {
                _ = act.spinner.update(t.timestamp);
            }
            const ds = act.daemonState();
            if (ds == .starting) {
                _ = act.daemon_spinner.update(t.timestamp);
            } else if (act.daemon_thread != null) {
                // The worker has finished (state is no longer `.starting`); reap
                // it. The store/return are back to back, so this never blocks.
                act.daemon_thread.?.join();
                act.daemon_thread = null;
                if (ds == .running) {
                    self.logf("{s}: daemon running", .{act.coin.coinName()});
                } else {
                    self.logf("{s}: daemon failed to start", .{act.coin.coinName()});
                }
            }
            if (act.sync == .syncing) {
                _ = act.sync_spinner.update(t.timestamp);
            }
            if ((p == .done or p == .failed) and !act.acked) {
                act.acked = true;
                if (act.thread) |th| {
                    th.join();
                    act.thread = null;
                }
                act.installed = act.coin.isInstalled(self.allocator, self.install_root);
                const verb: []const u8 = if (act.updating) "update" else "install";
                if (p == .done) {
                    self.logf("{s}: {s} complete", .{ act.coin.coinName(), verb });
                } else {
                    self.logf("{s}: {s} failed ({s})", .{ act.coin.coinName(), verb, act.err_name });
                }
            }
        }
    }

    fn move(self: *App, delta: i32) void {
        const n: i32 = @intCast(entries.len);
        var idx: i32 = @intCast(self.selected);
        idx = @max(0, @min(n - 1, idx + delta));
        self.selected = @intCast(idx);
        self.refreshSelectedInstalled();
    }

    /// Append a formatted line to the action log. Formats straight into the ring
    /// slot's fixed buffer (no allocation); an over-long line is truncated to the
    /// buffer rather than dropped.
    fn logf(self: *App, comptime fmt: []const u8, args: anytype) void {
        const slot = &self.log_lines[self.log_count % log_capacity];
        if (std.fmt.bufPrint(&slot.buf, fmt, args)) |s| {
            slot.len = s.len;
        } else |_| {
            slot.len = slot.buf.len;
        }
        self.log_count +%= 1;
    }

    /// Grow/shrink the bottom log pane by `delta` rows, clamped to sane bounds.
    fn resizeLog(self: *App, delta: i32) void {
        const v = @as(i32, self.log_height) + delta;
        self.log_height = @intCast(std.math.clamp(v, log_height_min, log_height_max));
    }

    /// The coin at the current selection, or null on Home.
    ///
    /// Takes `*const App` so the read-only `view`/`renderDetail` path can use it.
    /// The `coin()` builders want a mutable `*Coin`, but the resulting vtable
    /// only ever reads coin metadata here, and the backing `App` is never const
    /// (it lives mutably inside ZigZag's `Program`), so the `@constCast` is sound.
    fn selectedCoin(self: *const App) ?Coin {
        return switch (entries[self.selected]) {
            .home => null,
            .nexa => @constCast(&self.nexa).coin(),
            .divi => @constCast(&self.divi).coin(),
        };
    }

    /// Refresh the selected coin's cached installed flag from disk. Skipped when
    /// that coin has an active or finished job — its phase already speaks for it,
    /// and we don't want to stomp a fresh result with a stale disk check.
    fn refreshSelectedInstalled(self: *App) void {
        const act = &self.activities[self.selected];
        if (act.phaseOf() != .idle) return;
        if (self.selectedCoin()) |coin| {
            act.installed = coin.isInstalled(self.allocator, self.install_root);
        }
    }

    /// Kick off a background install/update for the selected coin. Returns
    /// immediately; progress is published into the coin's `Activity` and painted
    /// by `view`. A second press while one is already running for this coin is
    /// ignored, but other coins can be installing concurrently.
    fn tryInstall(self: *App) void {
        const coin = self.selectedCoin() orelse return;
        const act = &self.activities[self.selected];
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
        act.spinner = zz.Spinner.init();
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

    /// Start the selected coin's daemon in the background. Enabled only when the
    /// daemon is installed and currently stopped — otherwise the press is a
    /// no-op (matching the disabled button in the pane). Returns immediately; the
    /// worker flips `daemon` to `.running` once the launcher returns.
    fn tryStart(self: *App) void {
        const coin = self.selectedCoin() orelse return;
        const act = &self.activities[self.selected];
        if (!act.installed) return;
        if (act.daemonState() != .stopped) return;

        // Reap a previously finished daemon worker before reusing the slot.
        if (act.daemon_thread) |t| {
            t.join();
            act.daemon_thread = null;
        }

        act.coin = coin;
        act.install_root = self.install_root;
        act.daemon_spinner = zz.Spinner.init();
        act.daemon.store(@intFromEnum(DaemonState.starting), .release);

        act.daemon_thread = std.Thread.spawn(.{}, Activity.runDaemon, .{act}) catch {
            act.daemon.store(@intFromEnum(DaemonState.stopped), .release);
            return;
        };
        self.logf("{s}: starting daemon…", .{coin.coinName()});
    }

    pub fn view(self: *const App, ctx: *const zz.Context) []const u8 {
        const a = ctx.allocator;

        const right = self.renderDetail(a);
        const top = renderTwoPane(a, self.selected, right) catch "render error";
        return self.renderWithLog(a, ctx.width, top) catch top;
    }

    /// Append the bottom log pane below the main two-pane area: a full-width
    /// brand-coloured separator (the "bar") followed by the last `log_height`
    /// action lines, newest at the bottom. The section is padded to a fixed
    /// height so growing/shrinking it via `+`/`-` is visible even when sparse.
    fn renderWithLog(self: *const App, a: std.mem.Allocator, term_width: u16, top: []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(a);
        errdefer out.deinit();

        try out.writer.writeAll(top);
        if (top.len == 0 or top[top.len - 1] != '\n') try out.writer.writeByte('\n');

        // Separator bar: a heading, then box-drawing dashes out to the terminal
        // width, tinted in the app's brand colour.
        const width: usize = @max(@as(usize, term_width), 1);
        const heading = "── Log  (+/- resize) ";
        var sep: std.Io.Writer.Allocating = .init(a);
        defer sep.deinit();
        try sep.writer.writeAll(heading);
        var col = zz.width(heading);
        while (col < width) : (col += 1) try sep.writer.writeAll("─");
        const sep_styled = (zz.Style{}).fg(zz.Color.hex(app_color)).render(a, sep.written()) catch sep.written();
        try out.writer.print("{s}\n", .{sep_styled});

        // The last `log_height` messages, oldest first so the newest sits at the
        // bottom; then blank lines to fill the pane to its fixed height.
        const available = @min(self.log_count, log_capacity);
        const show = @min(available, @as(usize, self.log_height));
        const start = self.log_count - show;
        var i: usize = 0;
        while (i < show) : (i += 1) {
            const slot = &self.log_lines[(start + i) % log_capacity];
            try out.writer.print("{s}\n", .{slot.buf[0..slot.len]});
        }
        while (i < self.log_height) : (i += 1) try out.writer.writeByte('\n');

        return out.toOwnedSlice();
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
            return std.fmt.allocPrint(a,
                \\{s} v{s}
                \\
                \\Select a coin on the left to manage it.
                \\
                \\  up/down  navigate
                \\  i        install selected coin
                \\  s        start selected coin's daemon
                \\  +/-      resize the log pane
                \\  q        quit
            , .{ head, app_version }) catch "alloc error";
        };

        return self.renderCoin(a, coin, &self.activities[self.selected]) catch "alloc error";
    }

    /// Renders a single coin's pane: its metadata plus a middle block that
    /// reflects the coin's own install activity (idle button, live progress,
    /// or a completed/failed result). All activity stays inside this pane, so
    /// the surrounding two-pane layout — and the coin list on the left — is
    /// never disturbed.
    fn renderCoin(_: *const App, a: std.mem.Allocator, coin: Coin, act: *const Activity) ![]const u8 {
        const title = (zz.Style{}).bold(true).fg(zz.Color.hex(coin.coinColor()));
        const head = title.render(a, coin.coinName()) catch coin.coinName();

        const p = act.phaseOf();
        // Labels wear the coin's brand colour; their status marks are bold
        // green/red ticks (✔/✘) — the heavy glyphs read bolder than ✓/✗.
        const label_style = (zz.Style{}).fg(zz.Color.hex(coin.coinColor()));

        const is_installed = p == .done or act.installed;
        const installed_label = label_style.render(a, "Installed") catch "Installed";
        const installed_mark = statusMark(a, is_installed);

        // The daemon line is a tick/cross when stopped or up, or a spinner while
        // it's starting.
        const daemon_label = label_style.render(a, "Running") catch "Running";
        const daemon_mark: []const u8 = switch (act.daemonState()) {
            .running => statusMark(a, true),
            .stopped => statusMark(a, false),
            .starting => act.daemon_spinner.view(a) catch "…",
        };

        // Peer count: red while 0, green once any peer is connected.
        const peers_label = label_style.render(a, "Peers") catch "Peers";
        const peers_count = std.fmt.allocPrint(a, "{d}", .{act.peers}) catch "?";
        const peers_value = (zz.Style{}).bold(true).fg(if (act.peers > 0) .green else .red).render(a, peers_count) catch peers_count;

        // Sync line: red cross when idle, spinner while syncing, green tick once
        // synced. The label itself reads "Synced" only when fully synced.
        const sync_text = if (act.sync == .synced) "Synced" else "Syncing";
        const sync_label = label_style.render(a, sync_text) catch sync_text;
        const sync_mark: []const u8 = switch (act.sync) {
            .synced => statusMark(a, true),
            .idle => statusMark(a, false),
            .syncing => act.sync_spinner.view(a) catch "…",
        };

        // Staking only applies to proof-of-stake coins; PoW coins omit it
        // entirely (empty string folds out of the status line).
        const staking_part: []const u8 = if (coin.isProofOfStake()) blk: {
            const staking_label = label_style.render(a, "Staking") catch "Staking";
            break :blk std.fmt.allocPrint(a, "    {s}: {s}", .{ staking_label, statusMark(a, act.staking) }) catch "";
        } else "";

        // Wallet status: text + colour come from the state itself.
        const wallet_label = label_style.render(a, "Wallet") catch "Wallet";
        const wallet_value = (zz.Style{}).bold(true).fg(act.wallet.color()).render(a, act.wallet.text()) catch act.wallet.text();

        // Sync progress bars. Labels are padded to a common width before styling
        // (ANSI codes are zero-width) so the two bars line up.
        const headers_label = label_style.render(a, "Headers") catch "Headers";
        const blocks_label = label_style.render(a, "Blocks ") catch "Blocks ";
        const headers_bar = try bar(a, act.headers_cur, act.headers_total);
        const blocks_bar = try bar(a, act.blocks_cur, act.blocks_total);

        const middle = try renderActivity(a, act, p);
        const start_button = renderStartButton(a, act);

        return std.fmt.allocPrint(a,
            \\{s}
            \\
            \\{s}: {s}    {s}: {s}    {s}: {s}    {s}: {s}{s}
            \\{s}: {s}
            \\
            \\{s}  {s}
            \\{s}  {s}
            \\
            \\{s}
            \\
            \\{s}
        , .{
            head,
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
            headers_label,
            headers_bar,
            blocks_label,
            blocks_bar,
            middle,
            start_button,
        });
    }

    /// A bold tick (✔, green) or cross (✘, red). The heavy glyphs read bolder
    /// than the thin ✓/✗ at the terminal's fixed cell size.
    fn statusMark(a: std.mem.Allocator, ok: bool) []const u8 {
        const style = (zz.Style{}).bold(true).fg(if (ok) .green else .red);
        const glyph: []const u8 = if (ok) "✔" else "✘";
        return style.render(a, glyph) catch glyph;
    }

    /// The "Start" button line. Enabled (and bound to `s`) only when the daemon
    /// is installed and stopped; otherwise it's dimmed with a reason. While the
    /// daemon is starting it shows the in-progress label, and once up it reads as
    /// running.
    fn renderStartButton(a: std.mem.Allocator, act: *const Activity) []const u8 {
        if (!act.installed) {
            const b = (zz.Style{}).dim(true).render(a, "[ Start ]") catch "[ Start ]";
            return std.fmt.allocPrint(a, "{s}   (install first)", .{b}) catch "[ Start ]";
        }
        return switch (act.daemonState()) {
            .stopped => "[ Start ]   (press s)",
            .starting => "[ Starting… ]",
            .running => blk: {
                const b = (zz.Style{}).dim(true).render(a, "[ Start ]") catch "[ Start ]";
                break :blk std.fmt.allocPrint(a, "{s}   (running)", .{b}) catch "[ Start ]";
            },
        };
    }

    /// The phase-dependent middle of a coin pane. Each coin keeps its own copy,
    /// so navigating away and back shows exactly the stage that coin reached.
    fn renderActivity(a: std.mem.Allocator, act: *const Activity, p: Phase) ![]const u8 {
        switch (p) {
            .idle => {
                // When the daemon is already present, the action updates in
                // place rather than doing a first-time install.
                const button = if (act.installed) "[ Update ]" else "[ Install ]";
                const status = if (act.installed)
                    "installed — press i to update"
                else
                    "press i to install";
                return std.fmt.allocPrint(a, "{s}   (press i)\n\nstatus: {s}", .{ button, status });
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

    /// Joins the left nav column and the right detail block side by side. The
    /// left column lists every entry on every frame, so the coin list is always
    /// on screen regardless of what any coin is doing.
    fn renderTwoPane(a: std.mem.Allocator, selected: usize, right: []const u8) ![]const u8 {
        const col_w = 14;
        var out: std.Io.Writer.Allocating = .init(a);
        errdefer out.deinit();

        var rit = std.mem.splitScalar(u8, right, '\n');
        var i: usize = 0;
        while (true) {
            const have_left = i < entries.len;
            const r = rit.next();
            if (!have_left and r == null) break;

            if (have_left) {
                const e = entries[i];
                const marker: []const u8 = if (i == selected) "> " else "  ";
                // Pad to the column width first, then colour the fixed-width
                // label in the coin's brand colour. Padding before styling keeps
                // the visible width at 12 (the ANSI codes are zero-width), so the
                // `│` separator stays aligned regardless of label length.
                const padded = try std.fmt.allocPrint(a, "{s: <12}", .{entryLabel(e)});
                const label = (zz.Style{}).bold(i == selected).fg(entryColor(e)).render(a, padded) catch padded;
                try out.writer.print("{s}{s}", .{ marker, label });
            } else {
                try out.writer.splatByteAll(' ', col_w);
            }
            try out.writer.print(" │ {s}\n", .{r orelse ""});
            i += 1;
        }

        return out.toOwnedSlice();
    }
};

/// Render a single ZigZag progress bar for `current`/`total` bytes.
fn bar(a: std.mem.Allocator, current: u64, total: u64) ![]const u8 {
    var p = zz.Progress.init();
    p.setWidth(30);
    // Guard against a zero total (unknown length) so the bar sits at 0% rather
    // than dividing by zero.
    p.setTotal(@floatFromInt(@max(total, 1)));
    p.setValue(@floatFromInt(current));
    return p.view(a);
}

test "action log renders in the bottom pane and resizes within bounds" {
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
    _ = app.init(&ctx);
    defer app.deinit();

    app.logf("NEXA: {s}", .{"installing…"});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const out = try app.renderWithLog(arena.allocator(), 80, "TOP\n");

    // The separator bar and the logged line both appear below the top content.
    try std.testing.expect(std.mem.indexOf(u8, out, "Log") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "NEXA: installing…") != null);

    // Resize grows/shrinks the pane, clamped to the configured bounds.
    const h0 = app.log_height;
    app.resizeLog(2);
    try std.testing.expectEqual(@as(u16, h0 + 2), app.log_height);
    app.resizeLog(-1000);
    try std.testing.expectEqual(@as(u16, log_height_min), app.log_height);
    app.resizeLog(1000);
    try std.testing.expectEqual(@as(u16, log_height_max), app.log_height);
}

test "Start button reflects install and daemon state" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var act: Activity = .{};

    // Disabled until installed.
    act.installed = false;
    try std.testing.expect(std.mem.indexOf(u8, App.renderStartButton(a, &act), "install first") != null);

    // Installed + stopped → bound to `s`.
    act.installed = true;
    try std.testing.expect(std.mem.indexOf(u8, App.renderStartButton(a, &act), "press s") != null);

    // Up → reads as running.
    act.daemon.store(@intFromEnum(DaemonState.running), .release);
    try std.testing.expect(std.mem.indexOf(u8, App.renderStartButton(a, &act), "running") != null);
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

test "left bar paints each coin label in its brand colour" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The nav column is rebuilt every frame, so the coins' true-colour SGR
    // sequences (38;2;r;g;b) must appear in the rendered screen. Derive the
    // expected codes from each coin's hex so the test tracks the constant.
    const screen = try App.renderTwoPane(a, 0, "");

    const nexa_rgb = zz.Color.hex(Nexa.coin_color).toRgb().?;
    const divi_rgb = zz.Color.hex(Divi.coin_color).toRgb().?;
    const nexa_seq = try std.fmt.allocPrint(a, "38;2;{d};{d};{d}m", .{ nexa_rgb.r, nexa_rgb.g, nexa_rgb.b });
    const divi_seq = try std.fmt.allocPrint(a, "38;2;{d};{d};{d}m", .{ divi_rgb.r, divi_rgb.g, divi_rgb.b });

    try std.testing.expect(std.mem.indexOf(u8, screen, nexa_seq) != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, divi_seq) != null);
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
    const screen = try App.renderTwoPane(a, app.selected, divi_pane);
    try std.testing.expect(std.mem.indexOf(u8, screen, Nexa.coin_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, Divi.coin_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "│") != null);
}
