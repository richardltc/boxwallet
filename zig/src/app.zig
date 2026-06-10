const std = @import("std");
const zz = @import("zigzag");
const models = @import("models.zig");
const install_mod = @import("install.zig");
const disk = @import("disk.zig");
const memory = @import("memory.zig");
const conf = @import("conf.zig");
const rpc = @import("rpc.zig");
const Coin = @import("coin.zig").Coin;
const Nexa = @import("coins/nexa.zig").Nexa;
const Divi = @import("coins/divi.zig").Divi;
const Ergo = @import("coins/ergo.zig").Ergo;
const DigiByte = @import("coins/digibyte.zig").DigiByte;
const Zano = @import("coins/zano.zig").Zano;
const Nerva = @import("coins/nerva.zig").Nerva;
const ReddCoin = @import("coins/reddcoin.zig").ReddCoin;

/// The application's display name, version, and brand colour — the one place to
/// change how BoxWallet identifies itself in the UI. `app_color` is the brand
/// hex used for the "BoxWallet" wording on the Home pane.
pub const app_name = "BoxWallet TUI";
pub const app_version = "0.0.3";
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
const Entry = enum { home, nexa, divi, ergo, digibyte, zano, nerva, reddcoin };
const coin_entries = [_]Entry{ .nexa, .divi, .ergo, .digibyte, .zano, .nerva, .reddcoin };

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
    };
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

/// Whether a coin's daemon is up. `starting`/`stopping` are the in-flight states
/// while a start/stop worker runs (both animate a spinner in the pane), settling
/// to `running` or `stopped` when the worker publishes its outcome.
const DaemonState = enum { stopped, starting, running, stopping };

/// Chain sync progress. `syncing` shows a spinner ("Syncing"), `synced` a green
/// tick ("Synced"), `idle` a red cross. Live sync polling lands later — for now
/// this defaults to `idle`.
const SyncState = enum { idle, syncing, synced };

/// Sync spinner frame orders. The default braille `dots` orbit one way
/// ("clockwise"); the reversed list orbits the other. The sync line spins
/// clockwise while connected (peers > 0) and anti-clockwise while it has no
/// peers, so the direction signals connectivity at a glance.
const sync_frames_cw = zz.Spinner.Styles.dots;
const sync_frames_ccw = &[_][]const u8{ "⠏", "⠇", "⠧", "⠦", "⠴", "⠼", "⠸", "⠹", "⠙", "⠋" };

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

    /// Map a coin's normalized `models.WalletSecurity` onto the UI's
    /// `WalletState`. The two enums are intentionally parallel — the coin layer
    /// owns the normalized state; this side owns its display text/colour.
    fn fromSecurity(s: models.WalletSecurity) WalletState {
        return switch (s) {
            .unknown => .unknown,
            .unencrypted => .unencrypted,
            .locked => .locked,
            .unlocked => .unlocked,
            .unlocked_for_staking => .unlocked_for_staking,
        };
    }
};

/// Display text for a daemon warm-up phase. `none` has no text (the daemon is
/// either responsive or down, so the phase isn't shown).
fn loadingPhaseText(p: models.LoadingPhase) []const u8 {
    return switch (p) {
        .none => "",
        .loading => "Loading…",
        .rescanning => "Rescanning…",
        .rewinding => "Rewinding…",
        .verifying => "Verifying…",
        .calculating => "Calculating money supply…",
    };
}

/// Render the coin's one-line **Status** — a live readout of what the daemon is
/// doing right now, distinct from the per-axis ticks below it. Priority, highest
/// first: installing (downloading/extracting) → not installed → starting/stopping
/// → checking (first poll pending) → warm-up phase (Loading/Verifying/…) →
/// waiting for peers → syncing → synced; "Idle" when the daemon is installed but
/// off. The wording alone carries the state — no spinner icon — and refreshes
/// each poll/tick.
fn renderStatus(a: std.mem.Allocator, act: *const Activity, brand: zz.Color) []const u8 {
    const r = statusReadout(act);
    const label = App.statusLabel(a, brand, "Status", r.active);
    const value = (zz.Style{}).bold(true).fg(r.col).render(a, r.text) catch r.text;
    return std.fmt.allocPrint(a, "{s}: {s}", .{ label, value }) catch value;
}

/// A coin's live status as plain data: the word(s) shown on the Status line, the
/// colour they're painted, and whether the state counts as "active" (so the
/// label brightens). `text` is a static, program-lifetime string — `renderStatus`
/// styles it and the live log records it verbatim on change, so the two can't
/// drift apart.
const StatusReadout = struct { text: []const u8, col: zz.Color, active: bool };

/// Resolve a coin's current status. Priority, highest first: installing
/// (downloading/extracting) → not installed → starting/stopping → checking
/// (first poll pending) → warm-up phase (Loading/Verifying/…) → waiting for peers
/// → syncing → synced; "Idle" when the daemon is installed but off.
fn statusReadout(act: *const Activity) StatusReadout {
    // An install/update in flight outranks everything: it runs before the daemon
    // exists (and before `installed` flips), so check it first.
    switch (act.phaseOf()) {
        .downloading => return .{ .text = "Downloading…", .col = .cyan, .active = true },
        .extracting => return .{ .text = "Extracting…", .col = .cyan, .active = true },
        else => {},
    }

    if (!act.installed) return .{ .text = "Not installed", .col = .brightBlack, .active = false };

    return switch (act.daemonState()) {
        .starting => .{ .text = "Starting…", .col = .cyan, .active = true },
        .stopping => .{ .text = "Stopping…", .col = .cyan, .active = true },
        .stopped => if (act.awaitingStatus())
            .{ .text = "Checking…", .col = .cyan, .active = true }
        else
            .{ .text = "Idle", .col = .brightBlack, .active = false },
        .running => if (act.loading_phase != .none)
            .{ .text = loadingPhaseText(act.loading_phase), .col = .yellow, .active = true }
        else if (act.peers == 0)
            .{ .text = "Waiting for peers…", .col = .yellow, .active = true }
        else if (act.sync == .syncing)
            // Headers stream in first, then blocks validate against them. While
            // the Headers bar is still filling we're downloading headers;
            // otherwise we're catching the blocks up. (A 0 header total means the
            // tip isn't known yet — treat that as block catch-up rather than
            // claiming a headers phase we can't measure.)
            .{
                .text = if (act.headers_total > 0 and act.headers_cur < act.headers_total)
                    "Syncing headers…"
                else
                    "Syncing blocks…",
                .col = .cyan,
                .active = true,
            }
        else if (act.sync == .synced)
            .{ .text = "Synced", .col = .green, .active = true }
        else
            .{ .text = "Running", .col = .green, .active = true },
    };
}

/// A wallet operation the `w` menu can run against the daemon.
const WalletAction = enum {
    encrypt,
    unlock,
    stake,
    lock,

    /// The menu label for the action.
    fn label(self: WalletAction) []const u8 {
        return switch (self) {
            .encrypt => "Encrypt wallet",
            .unlock => "Unlock",
            .stake => "Unlock for staking",
            .lock => "Lock wallet",
        };
    }

    /// Whether the action needs a passphrase entered first (`lock` doesn't).
    fn needsPassword(self: WalletAction) bool {
        return self != .lock;
    }
};

/// Which actions the `w` menu offers for a given wallet state, written into
/// `buf` and returned by count. Unencrypted → encrypt; locked → unlock (plus
/// unlock-for-staking on proof-of-stake coins); unlocked → lock; unknown → none.
fn walletOptions(wallet: WalletState, pos: bool, buf: *[3]WalletAction) usize {
    var n: usize = 0;
    switch (wallet) {
        .unencrypted => {
            buf[n] = .encrypt;
            n += 1;
        },
        .locked => {
            buf[n] = .unlock;
            n += 1;
            if (pos) {
                buf[n] = .stake;
                n += 1;
            }
        },
        .unlocked, .unlocked_for_staking => {
            buf[n] = .lock;
            n += 1;
        },
        .unknown => {},
    }
    return n;
}

/// The `w` wallet menu — a small modal drawn over the dashboard for managing the
/// selected coin's wallet. It walks menu → passphrase entry → working → result;
/// the chosen action runs against the daemon on a worker thread (so the UI never
/// blocks), with the passphrase held only in the `App`'s `pw_input` and the
/// worker's bounded buffer, both cleared once the action is sent.
const Modal = struct {
    const Stage = enum { menu, password, working, result };

    stage: Stage = .menu,
    /// Index into `options[0..option_count]`.
    sel: usize = 0,
    options: [3]WalletAction = undefined,
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

    fn setMsg(self: *Modal, ok: bool, text: []const u8) void {
        self.ok = ok;
        const n = @min(text.len, self.msg_buf.len);
        @memcpy(self.msg_buf[0..n], text[0..n]);
        self.msg_len = n;
        self.stage = .result;
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
    /// Set true (release) by the worker when the poll finishes; the UI folds the
    /// result in and joins the thread on its next tick.
    poll_done: std.atomic.Value(bool) = .init(false),
    /// Whether the finished poll reached the daemon. Plain field, published by
    /// the `poll_done` release/acquire pairing.
    poll_ok: bool = false,
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
    /// Latest polled wallet security state (`@intFromEnum(WalletState)`), from
    /// `getwalletinfo`. Only set for coins that expose a manageable wallet;
    /// otherwise stays at `unknown`. Published by the `poll_done` edge.
    poll_wallet: std.atomic.Value(u8) = .init(@intFromEnum(WalletState.unknown)),
    /// Latest probed daemon warm-up phase (`@intFromEnum(models.LoadingPhase)`).
    /// Set on every poll: `none` when the daemon answered normally, otherwise the
    /// phase parsed from its "-28 in warm-up" reply. Published by the `poll_done`
    /// edge.
    poll_phase: std.atomic.Value(u8) = .init(@intFromEnum(models.LoadingPhase.none)),
    /// Latest polled chain heights and sync flag, from `getblockchaininfo`.
    poll_headers: std.atomic.Value(u64) = .init(0),
    poll_blocks: std.atomic.Value(u64) = .init(0),
    poll_synced: std.atomic.Value(u8) = .init(0),
    /// Estimated network tip (max peer `synced_headers`), the Headers bar target.
    poll_network: std.atomic.Value(u64) = .init(0),
    /// Seconds behind the chain tip (wall clock now − tip block timestamp),
    /// computed in the poll worker where the real-time clock is reachable.
    /// -1 means unknown (the daemon reports no tip timestamp). Drives the
    /// "behind by …" estimate on the Blocks line.
    poll_behind: std.atomic.Value(i64) = .init(-1),
    /// Tip block's own timestamp (unix seconds), for showing the date/time of
    /// the block being synced beside the Blocks bar. 0 when the daemon reports
    /// no usable tip timestamp.
    poll_tip_time: std.atomic.Value(i64) = .init(0),

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

    // --- UI-thread-only ----------------------------------------------------
    thread: ?std.Thread = null,
    /// Joins the daemon start/stop worker once it has published its result.
    daemon_thread: ?std.Thread = null,
    /// Which daemon worker is in flight on `daemon_thread`, so the reap can log
    /// the right outcome (started/failed-to-start vs stopped/failed-to-stop).
    daemon_action: enum { start, stop } = .start,
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
    wallet: WalletState = .unknown,
    /// Whether the wallet is actively staking. Only shown for proof-of-stake
    /// coins; live staking polling lands later — for now this stays false.
    staking: bool = false,
    /// The daemon's warm-up phase while it's coming up (Loading/Verifying/…), or
    /// `none` once it's responsive. Folded in from `poll_phase` on each poll reap;
    /// drives the Wallet line's "loading" readout.
    loading_phase: models.LoadingPhase = .none,
    /// Headers/blocks sync progress (current vs total). Populated by the live
    /// sync poll later; 0/0 renders an empty bar.
    headers_cur: u64 = 0,
    headers_total: u64 = 0,
    blocks_cur: u64 = 0,
    blocks_total: u64 = 0,
    /// Seconds behind the chain tip, or -1 when unknown. How far behind in
    /// wall-clock time the chain is while syncing.
    behind_secs: i64 = -1,
    /// Tip block's own timestamp (unix seconds), or 0 when unknown. Drives the
    /// "date/time of the block being synced" hint beside the Blocks bar.
    tip_time: i64 = 0,
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
    fn requestStop(self: *Activity, a: std.mem.Allocator) !void {
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

        // Ask the daemon to shut down. Bitcoin coins issue the JSON-RPC `stop`;
        // Ergo POSTs its REST `/node/shutdown`. The coin owns the request; the
        // probe loop below confirms it actually went down.
        try self.coin.requestStop(a, auth);

        // Probe on a small arena reset each round so the wait stays flat in
        // memory. The daemon drops its RPC port early in shutdown, so the first
        // failed probe means it's on its way down; cap the wait so a wedged
        // daemon doesn't pin the worker forever.
        var probe = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer probe.deinit();
        var attempts: u8 = 0;
        while (attempts < 40) : (attempts += 1) {
            io.sleep(.fromMilliseconds(250), .awake) catch {};
            _ = probe.reset(.retain_capacity);
            _ = self.coin.daemonInfo(probe.allocator(), auth) catch return;
        }
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
        switch (self.wallet_action) {
            .encrypt => try self.coin.walletEncrypt(a, auth, pw),
            .unlock => try self.coin.walletUnlock(a, auth, pw, false),
            .stake => try self.coin.walletUnlock(a, auth, pw, true),
            .lock => try self.coin.walletLock(a, auth),
        }
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
        self.behind_secs = self.poll_behind.load(.monotonic);
        self.tip_time = self.poll_tip_time.load(.monotonic);
        self.sync = if (self.poll_synced.load(.monotonic) != 0) .synced else .syncing;
        return true;
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
            // The daemon answered normally, so it isn't warming up.
            self.poll_phase.store(@intFromEnum(models.LoadingPhase.none), .monotonic);
        } else |_| {
            self.poll_ok = false;
            // The daemon may be up but still warming up — probe its phase so the
            // UI can show *what* it's doing (Loading/Verifying/…) rather than a
            // bare spinner. Best-effort; a failure leaves it `none`.
            self.probeLoadingPhase(a);
        }
        self.poll_done.store(true, .release);
    }

    /// Probe the daemon's warm-up phase after a failed status fetch. Only worth
    /// doing while we believe the daemon is up (a stopped daemon would just refuse
    /// the connection); coins with no bitcoin-style warm-up (`warmupProbeMethod`
    /// null) always read `none`. Runs on the caller's poll arena.
    fn probeLoadingPhase(self: *Activity, a: std.mem.Allocator) void {
        const method = self.coin.warmupProbeMethod() orelse {
            self.poll_phase.store(@intFromEnum(models.LoadingPhase.none), .monotonic);
            return;
        };
        if (self.daemonState() == .stopped) {
            self.poll_phase.store(@intFromEnum(models.LoadingPhase.none), .monotonic);
            return;
        }

        var threaded: std.Io.Threaded = .init(a, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const phase: models.LoadingPhase = blk: {
            const data_dir = self.coin.dataDir(a, self.home_dir) catch break :blk .none;
            const auth = conf.readAuth(
                a,
                io,
                data_dir,
                self.coin.confFile(),
                self.coin.rpcDefaultUsername(),
                self.coin.rpcDefaultPort(),
            ) catch break :blk .none;
            break :blk rpc.loadingPhase(a, auth, method) catch .none;
        };
        self.poll_phase.store(@intFromEnum(phase), .monotonic);
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

        // Wallet security state, for coins whose wallet BoxWallet can manage —
        // lights up the Wallet line and drives which `w` menu options apply.
        // Best-effort: a hiccup (e.g. no wallet loaded yet) just leaves the last
        // value, so a transient blip doesn't blank the line.
        if (self.coin.supportsWallet()) {
            if (self.coin.walletSecurityState(a, auth)) |sec| {
                self.poll_wallet.store(@intFromEnum(WalletState.fromSecurity(sec)), .monotonic);
            } else |_| {}
        }

        const state = try self.coin.blockchainState(a, auth);
        defer state.deinit(a);
        self.poll_headers.store(@as(u64, @intCast(@max(state.headers, 0))), .monotonic);
        self.poll_blocks.store(@as(u64, @intCast(@max(state.blocks, 0))), .monotonic);
        self.poll_network.store(@as(u64, @intCast(@max(state.network_height, 0))), .monotonic);
        // Seconds behind the tip. A coin that can't report a tip timestamp gives
        // the figure directly (`seconds_behind` >= 0; e.g. Nerva from its block
        // gap); otherwise it's wall-clock now − tip block timestamp. The real-time
        // clock is reachable here (in the poll worker) but not in the render path,
        // so derive it now; -1 when neither is available.
        const now_secs = std.Io.Clock.real.now(io).toSeconds();
        self.poll_behind.store(
            if (state.seconds_behind >= 0)
                state.seconds_behind
            else if (state.tip_time > 0)
                now_secs - state.tip_time
            else
                -1,
            .monotonic,
        );
        // Tip block's own timestamp, for the "date/time of the block being synced"
        // hint. Reported directly by most daemons; for a coin that only gives a
        // `seconds_behind` gap (no tip timestamp), reconstruct it from now − gap.
        // 0 when neither is available.
        self.poll_tip_time.store(
            if (state.tip_time > 0)
                state.tip_time
            else if (state.seconds_behind >= 0)
                now_secs - state.seconds_behind
            else
                0,
            .monotonic,
        );
        self.poll_synced.store(@intFromBool(state.synced), .monotonic);
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
        try self.coin.prepareConf(a, io, self.home_dir);

        // The command to spawn — the bare daemon binary for fork coins, or a full
        // command line (e.g. `java -jar … -c <conf>`) for foreground coins.
        const argv = try self.coin.daemonArgv(a, self.install_root, self.home_dir);

        // Foreground daemons run in their own process rather than forking and
        // exiting — Windows `*coind` (no `-daemon` support) and JVM apps like
        // Ergo's node. The POSIX "wait for the launcher to daemonize" model below
        // would block forever on them, so mirror Go's `cmd /C start /b`: spawn
        // detached and return without waiting. The process stays up on its own,
        // and the status poll flips the UI to "running" once it answers. A
        // pre-start failure can't be surfaced here (no launcher exit/stderr).
        if (self.coin.launchMode() == .foreground) {
            var child = try std.process.spawn(io, .{
                .argv = argv,
                .environ_map = self.environ_map,
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
                // Don't pop a console window for the background daemon (Windows).
                .create_no_window = @import("builtin").os.tag == .windows,
            });
            // Detached: deliberately not waited on, so it outlives this call.
            _ = &child;
            return;
        }

        // Fork path (bitcoin-derived, POSIX): append `-daemon` so the daemon forks
        // itself into the background and the launcher exits, then wait on that
        // brief launcher.
        const forked = try std.mem.concat(a, []const u8, &.{ argv, &.{"-daemon"} });

        // Per-daemon name so coins starting at once don't share the scratch file.
        const err_name = try std.fmt.allocPrint(a, ".{s}.startup", .{self.coin.daemonFile()});
        const err_path = try std.fs.path.join(a, &.{ self.install_root, err_name });
        var err_file = try std.Io.Dir.createFileAbsolute(io, err_path, .{ .read = true });
        defer {
            err_file.close(io);
            // Unlink once read: the daemon still holds its own fd to the now
            // anonymous inode, so its later writes are harmless rather than fatal.
            std.Io.Dir.deleteFileAbsolute(io, err_path) catch {};
        }

        var child = try std.process.spawn(io, .{
            .argv = forked,
            .environ_map = self.environ_map,
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
                self.setDaemonErrFromDebugLog(a, io);
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
    /// RPC and works before the daemon opens its RPC port. On platforms without
    /// `/proc` the check can't run, so it conservatively reports alive (we fall
    /// back to trusting the launcher's exit code, the prior behaviour).
    fn confirmAlive(self: *Activity, io: std.Io) bool {
        const name = self.coin.daemonFile();
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            io.sleep(.fromMilliseconds(250), .awake) catch {};
            if (!processAlive(io, name)) return false;
        }
        return true;
    }

    /// Surface a failed start's reason from the coin's `<datadir>/debug.log` —
    /// the daemonized child logs there, not to the stderr we captured. Reads only
    /// the tail (bounded, the file grows unboundedly) and picks the most
    /// error-like line. Best-effort: leaves `daemon_err` empty on any IO hiccup,
    /// so the caller falls back to the generic launcher error name.
    fn setDaemonErrFromDebugLog(self: *Activity, a: std.mem.Allocator, io: std.Io) void {
        const data_dir = self.coin.dataDir(a, self.home_dir) catch return;
        var dir = std.Io.Dir.cwd().openDir(io, data_dir, .{}) catch return;
        defer dir.close(io);
        var file = dir.openFile(io, "debug.log", .{}) catch return;
        defer file.close(io);
        const stat = file.stat(io) catch return;
        // A modest tail keeps the read flat and biases toward the latest start
        // attempt (the death burst is the last handful of lines), so an older
        // session's errors further back don't get picked.
        var buf: [4 * 1024]u8 = undefined;
        const off = if (stat.size > buf.len) stat.size - buf.len else 0;
        const n = file.readPositionalAll(io, &buf, off) catch return;

        const pick = pickDebugLogError(buf[0..n]);
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

/// Strip a bitcoin-style "YYYY-MM-DD HH:MM:SS " log prefix from `line` so the
/// surfaced reason is just the message. Returns `line` unchanged if the prefix
/// isn't there.
fn stripLogTimestamp(line: []const u8) []const u8 {
    if (line.len > 20 and line[4] == '-' and line[7] == '-' and
        line[10] == ' ' and line[13] == ':' and line[16] == ':')
        return std.mem.trim(u8, line[19..], " \t");
    return line;
}

/// Choose the most informative line from a debug.log tail. A daemon's failure
/// burst mixes the root cause with benign warnings and shutdown bookkeeping, so
/// two tiers are used: a "root cause" line (a datadir/block-index/permission
/// problem) wins over a generic error/abort line, which in turn wins over the
/// last non-empty line. Within a tier the *last* match wins, since the fatal
/// line lands late, just before the shutdown. Leading log timestamps are
/// stripped. Returns a slice into `tail` (empty only if `tail` has no content).
fn pickDebugLogError(tail: []const u8) []const u8 {
    // Deliberately omits bare "lock" ("block" contains it) — the datadir-lock
    // message carries "cannot" anyway.
    const root_cause = [_][]const u8{
        "incorrect", "corrupt", "no genesis", "wrong datadir",
        "cannot",    "unable",  "denied",     "invalid",
        "not found",
    };
    const generic = [_][]const u8{ "error", "abort", "fail", "exiting" };

    var root_hit: []const u8 = "";
    var generic_hit: []const u8 = "";
    var fallback: []const u8 = "";
    var it = std.mem.splitScalar(u8, tail, '\n');
    while (it.next()) |raw| {
        const line = stripLogTimestamp(std.mem.trim(u8, raw, " \t\r"));
        if (line.len == 0) continue;
        fallback = line;
        if (matchesAny(line, &root_cause)) {
            root_hit = line;
        } else if (matchesAny(line, &generic)) {
            generic_hit = line;
        }
    }
    return if (root_hit.len != 0) root_hit else if (generic_hit.len != 0) generic_hit else fallback;
}

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

/// True if a process named `name` (matched against `/proc/<pid>/comm`, which is
/// truncated to 15 bytes) is currently running. Linux-only; returns true where
/// `/proc` isn't available so callers don't treat "can't check" as "dead".
fn processAlive(io: std.Io, name: []const u8) bool {
    var proc = std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch return true;
    defer proc.close(io);

    // comm is truncated to TASK_COMM_LEN-1 (15) bytes.
    const want = if (name.len > 15) name[0..15] else name;

    var it = proc.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory or entry.name.len == 0 or !std.ascii.isDigit(entry.name[0])) continue;
        var path_buf: [32]u8 = undefined;
        const comm_path = std.fmt.bufPrint(&path_buf, "{s}/comm", .{entry.name}) catch continue;
        var f = proc.openFile(io, comm_path, .{}) catch continue;
        defer f.close(io);
        var cbuf: [64]u8 = undefined;
        const n = f.readPositionalAll(io, &cbuf, 0) catch continue;
        if (std.mem.eql(u8, std.mem.trim(u8, cbuf[0..n], " \t\r\n"), want)) return true;
    }
    return false;
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
    selected: usize,
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
    /// The open `w` wallet modal, or null when no modal is up. While set, the
    /// modal owns keyboard input and is composited over the dashboard.
    modal: ?Modal = null,
    /// Masked passphrase entry for the wallet modal. Persistent (its backing
    /// buffer outlives a single modal), created in `init` and freed in `deinit`;
    /// its value is cleared whenever the modal closes or an action is sent.
    pw_input: zz.TextInput,

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
            .selected = 0,
            .activities = undefined,
            .pw_input = zz.TextInput.init(ctx.persistent_allocator),
        };
        // The wallet passphrase field masks its input and stays a fixed width.
        self.pw_input.setEchoMode(.password);
        self.pw_input.setWidth(24);
        self.pw_input.setCharLimit(wallet_pw_max);
        // Sync keeps the default braille dots; Running/Staking/Peers and the
        // install progress use the heavier pulsing spinner (`makeSpinner`).
        for (&self.activities) |*act| act.* = .{ .spinner = makeSpinner(), .daemon_spinner = makeSpinner(), .sync_spinner = zz.Spinner.init() };
        self.refreshSelectedInstalled();

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
        self.logf("{s} v{s} started", .{ app_name, app_version });

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
            if (act.poll_thread) |t| {
                t.join();
                act.poll_thread = null;
            }
            if (act.wallet_thread) |t| {
                t.join();
                act.wallet_thread = null;
            }
            // The passphrase copy may still be resident if a worker was in flight
            // at shutdown — clear it rather than leave the secret in freed memory.
            @memset(&act.wallet_pw_buf, 0);
        }
        self.pw_input.deinit();
        if (self.install_root_owned) self.allocator.free(self.install_root);
        if (self.home_dir_owned) self.allocator.free(self.home_dir);
    }

    pub fn update(self: *App, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            // While the wallet modal is open it owns the keyboard — global keys
            // (quit/install/navigate) are suppressed so typing a passphrase or
            // walking the menu doesn't also drive the dashboard.
            .key => |k| {
                if (self.modal != null) {
                    self.modalKey(k);
                    return .none;
                }
                switch (k.key) {
                    .char => |c| switch (c) {
                        'q' => return .quit,
                        'i' => self.tryInstall(),
                        's' => self.tryToggleDaemon(),
                        'w' => self.openWalletModal(),
                        'k' => self.move(-1),
                        'j' => self.move(1),
                        'l' => self.log_visible = !self.log_visible,
                        else => {},
                    },
                    .up => self.move(-1),
                    .down => self.move(1),
                    else => {},
                }
            },
            .tick => |t| self.onTick(t),
        }
        return .none;
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
                    if (m.action.needsPassword()) {
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

        // All installed coins are polled for live status on a shared ~2s cadence.
        const poll_due = t.timestamp - self.last_poll_ns >= 2 * std.time.ns_per_s;
        for (&self.activities, 0..) |*act, i| {
            if (entries[i] == .home) continue;
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
                _ = act.daemon_spinner.update(t.timestamp);
            }
            if ((ds == .running or ds == .stopped) and act.daemon_thread != null) {
                // The worker has settled on a terminal state; reap it. The
                // store/return are back to back, so this never blocks.
                act.daemon_thread.?.join();
                act.daemon_thread = null;
                switch (act.daemon_action) {
                    .start => if (ds == .running)
                        self.logf("{s}: daemon running", .{act.coin.coinName()})
                    else
                        self.logf("{s}: daemon failed to start ({s})", .{ act.coin.coinName(), act.daemon_err }),
                    .stop => if (ds == .stopped) {
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
                        act.poll_wallet.store(@intFromEnum(WalletState.unknown), .monotonic);
                        act.loading_phase = .none;
                        act.poll_phase.store(@intFromEnum(models.LoadingPhase.none), .monotonic);
                        self.logf("{s}: daemon stopped", .{act.coin.coinName()});
                    } else self.logf("{s}: daemon failed to stop ({s})", .{ act.coin.coinName(), act.daemon_err }),
                }
            }
            if (act.sync == .syncing) {
                // Spin clockwise when connected, anti-clockwise with no peers.
                // Assign `frames` directly (not `setFrames`, which would reset
                // the index every tick and freeze the animation).
                act.sync_spinner.frames = if (act.peers > 0) sync_frames_cw else sync_frames_ccw;
                _ = act.sync_spinner.update(t.timestamp);
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
                if (act.applyPoll() and act.daemonState() != .running)
                    act.daemon.store(@intFromEnum(DaemonState.running), .release);
                // Mark the just-reaped poll as received once per selection; the
                // matching "checking" line was logged when this poll started.
                if (i == self.selected and !act.status_logged) {
                    act.status_logged = true;
                    self.logf("{s}: status received", .{act.coin.coinName()});
                }
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
                        act.poll_wallet.store(@intFromEnum(WalletState.unknown), .monotonic);
                    }
                    self.logf("{s}: {s} succeeded", .{ act.coin.coinName(), action.label() });
                } else {
                    self.logf("{s}: {s} failed ({s})", .{ act.coin.coinName(), action.label(), act.wallet_err });
                }
                // Re-poll promptly so the Wallet line reflects the change.
                self.last_poll_ns = 0;

                if (self.modal) |*m| {
                    if (m.coin_idx == i and m.stage == .working) {
                        if (ok) {
                            m.setMsg(true, switch (action) {
                                .encrypt => "Wallet encrypted. Restart the daemon (s), then unlock.",
                                .unlock => "Wallet unlocked.",
                                .stake => "Wallet unlocked for staking.",
                                .lock => "Wallet locked.",
                            });
                        } else {
                            var buf: [200]u8 = undefined;
                            const text = std.fmt.bufPrint(&buf, "Failed: {s}", .{act.wallet_err}) catch action.label();
                            m.setMsg(false, text);
                        }
                    }
                }
            }

            // Start the next poll for an installed, idle coin when the cadence is
            // due and none is in flight. Only the selected coin is polled — its
            // dashboard is the only one on screen, so polling a coin we're not
            // viewing buys nothing. Skipped while an install or daemon-start
            // worker is touching this activity, so `coin` isn't written under it.
            if (i == self.selected and poll_due and act.installed and
                act.poll_thread == null and !act.busy() and act.daemon_thread == null and
                act.wallet_thread == null)
            {
                if (self.coinAt(i)) |coin| {
                    act.coin = coin;
                    act.home_dir = self.home_dir;
                    act.poll_ok = false;
                    act.poll_done.store(false, .monotonic);
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
                const verb: []const u8 = if (act.updating) "update" else "install";
                if (p == .done) {
                    self.logf("{s}: {s} complete", .{ act.coin.coinName(), verb });
                } else {
                    self.logf("{s}: {s} failed ({s})", .{ act.coin.coinName(), verb, act.err_name });
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
        }
    }

    /// Append a formatted line to the action log, prefixed with a UTC timestamp.
    /// Formats straight into the ring slot's fixed buffer (no allocation); an
    /// over-long line is truncated to the buffer rather than dropped.
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

    /// Start the selected coin's daemon in the background. Enabled only when the
    /// daemon is installed and currently stopped — otherwise the press is a
    /// no-op (matching the disabled button in the pane). Returns immediately; the
    /// worker flips `daemon` to `.running` once the launcher returns.
    /// `s` toggles the selected coin's daemon: start it when stopped, stop it when
    /// running. Mid-transition (starting/stopping) presses are ignored, mirroring
    /// the dimmed button — the one key always matches the label it shows.
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
        if (!act.installed) return;
        if (act.daemonState() != .stopped) return;

        // Reap a previously finished daemon worker before reusing the slot.
        if (act.daemon_thread) |t| {
            t.join();
            act.daemon_thread = null;
        }

        act.coin = coin;
        act.install_root = self.install_root;
        act.home_dir = self.home_dir;
        act.environ_map = self.environ_map;
        act.daemon_action = .start;
        act.daemon_spinner = makeSpinner();
        act.daemon_err = "";
        // A freshly (re)started daemon won't have our named wallet loaded (Core
        // only auto-loads the unnamed default), so re-run ensureWallet on the next
        // poll for coins that need it.
        act.wallet_ensured = false;
        act.daemon.store(@intFromEnum(DaemonState.starting), .release);

        act.daemon_thread = std.Thread.spawn(.{}, Activity.runDaemon, .{act}) catch {
            act.daemon.store(@intFromEnum(DaemonState.stopped), .release);
            return;
        };
        self.logf("{s}: starting daemon…", .{coin.coinName()});
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

        // A status poll for this coin may be in flight (only the selected coin is
        // polled); reap it first so the stop worker doesn't race it on `coin`.
        if (act.poll_thread) |t| {
            t.join();
            act.poll_thread = null;
        }

        act.coin = coin;
        act.home_dir = self.home_dir;
        act.daemon_action = .stop;
        act.daemon_spinner = makeSpinner();
        act.daemon_err = "";
        act.daemon.store(@intFromEnum(DaemonState.stopping), .release);

        act.daemon_thread = std.Thread.spawn(.{}, Activity.runStopDaemon, .{act}) catch {
            act.daemon.store(@intFromEnum(DaemonState.running), .release);
            return;
        };
        self.logf("{s}: stopping daemon…", .{coin.coinName()});
    }

    /// Open the `w` wallet menu for the selected coin. Gated: the coin must
    /// expose a manageable wallet, be installed with a running daemon, and have a
    /// resolved wallet state offering at least one action. When it can't open, the
    /// reason is logged rather than popping an empty modal.
    fn openWalletModal(self: *App) void {
        const coin = self.selectedCoin() orelse return;
        const act = &self.activities[self.selected];
        if (!coin.supportsWallet()) {
            self.logf("{s}: wallet management isn't supported", .{coin.coinName()});
            return;
        }
        if (!act.installed or act.daemonState() != .running) {
            self.logf("{s}: start the daemon first to manage the wallet", .{coin.coinName()});
            return;
        }
        var opts: [3]WalletAction = undefined;
        const n = walletOptions(act.wallet, coin.isProofOfStake(), &opts);
        if (act.wallet == .unknown or n == 0) {
            self.logf("{s}: wallet state not known yet — try again in a moment", .{coin.coinName()});
            return;
        }

        var m: Modal = .{ .coin_idx = self.selected };
        m.options = opts;
        m.option_count = n;
        self.pw_input.setValue("") catch {};
        self.modal = m;
    }

    /// Dismiss the wallet modal, clearing the passphrase field.
    fn closeWalletModal(self: *App) void {
        self.pw_input.setValue("") catch {};
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
        // the secret isn't held in two places.
        const pw = self.pw_input.getValue();
        const n = @min(pw.len, wallet_pw_max);
        @memcpy(act.wallet_pw_buf[0..n], pw[0..n]);
        act.wallet_pw_len = n;
        self.pw_input.setValue("") catch {};

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

    pub fn view(self: *const App, ctx: *const zz.Context) []const u8 {
        const a = ctx.allocator;

        const right = self.renderDetail(a);
        const top = renderTwoPane(a, self.selected, right) catch "render error";
        const screen = if (!self.log_visible)
            top
        else
            (self.renderWithLog(a, ctx.width, ctx.height, top) catch top);
        if (self.modal == null) return screen;
        return self.renderModalOver(a, screen, ctx.width, ctx.height) catch screen;
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
            try out.writer.print("{s}\n", .{slot.buf[0..slot.len]});
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
                \\  s        start/stop selected coin's daemon
                \\  w        wallet (encrypt / unlock / stake)
                \\  l        toggle the log pane
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
    fn renderCoin(self: *const App, a: std.mem.Allocator, coin: Coin, act: *const Activity) ![]const u8 {
        const title = (zz.Style{}).bold(true).fg(zz.Color.hex(coin.coinColor()));
        const name = title.render(a, coin.coinName()) catch coin.coinName();
        // The coin name wears its brand colour; its bundled core version rides
        // alongside in the terminal default, mirroring "BoxWallet TUI v0.0.3" on
        // the Home pane.
        const head = std.fmt.allocPrint(a, "{s} v{s}", .{ name, coin.coreVersion() }) catch name;

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
            .running => statusMark(a, true),
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
        // grey only in the idle (red ✘) state.
        const sync_text = if (act.sync == .synced) "Synced" else "Syncing";
        const sync_label = statusLabel(a, brand, sync_text, awaiting or act.sync != .idle);
        const sync_mark: []const u8 = if (awaiting)
            act.daemon_spinner.view(a) catch "…"
        else switch (act.sync) {
            .synced => statusMark(a, true),
            .idle => statusMark(a, false),
            .syncing => act.sync_spinner.view(a) catch "…",
        };

        // Staking only applies to proof-of-stake coins; PoW coins omit it
        // entirely (empty string folds out of the status line). Grey unless
        // animating (awaiting) or staking (green tick).
        const staking_part: []const u8 = if (coin.isProofOfStake()) blk: {
            const staking_label = statusLabel(a, brand, "Staking", awaiting or act.staking);
            const staking_mark = if (awaiting) act.daemon_spinner.view(a) catch "…" else statusMark(a, act.staking);
            break :blk std.fmt.allocPrint(a, "    {s}: {s}", .{ staking_label, staking_mark }) catch "";
        } else "";

        // Wallet status: text + colour come from the state itself; the label is
        // grey until the state is known (matching the "Unknown" value's grey).
        const wallet_label = statusLabel(a, brand, "Wallet", act.wallet != .unknown);
        const wallet_value = (zz.Style{}).bold(true).fg(act.wallet.color()).render(a, act.wallet.text()) catch act.wallet.text();
        // Advertise the `w` key the way the daemon button advertises `s` — but
        // only when a press would actually open the menu (the coin has a
        // manageable wallet, its daemon is up, and a state has been polled).
        // Dimmed so it reads as a hint, not part of the status.
        const wallet_hint: []const u8 = if (coin.supportsWallet() and act.daemonState() == .running and act.wallet != .unknown)
            (zz.Style{}).dim(true).render(a, "   (press w)") catch "   (press w)"
        else
            "";

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

        // Headline live status — what the daemon is doing right now.
        const status_line = renderStatus(a, act, brand);

        return std.fmt.allocPrint(a,
            \\{s}
            \\
            \\{s}
            \\{s}: {s}    {s}: {s}    {s}: {s}    {s}: {s}{s}
            \\{s}: {s}{s}
            \\
            \\{s}  {s}
            \\{s}  {s}{s}
            \\
            \\{s}  {s}
            \\{s}  {s}
            \\
            \\{s}
            \\
            \\{s}
        , .{
            head,
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
            disk_label,
            disk_bar,
            mem_label,
            mem_bar,
            middle,
            daemon_button,
        });
    }

    /// A loading spinner tuned to read boldly at a status mark's size: heavy
    /// pulsing block frames (█▓▒░), bold, and a touch faster than the default.
    /// Used for the Running/Staking/Peers/Sync "loading" states and the install
    /// progress so the motion is obvious rather than the faint braille default.
    fn makeSpinner() zz.Spinner {
        var s = zz.Spinner.init();
        s.setFrames(zz.Spinner.Styles.pulse);
        s.setFps(12);
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
                // When the daemon is already present, the action updates in
                // place rather than doing a first-time install. A status line
                // only adds anything in the not-yet-installed case; once
                // installed the "[ Update ]   (press i)" button already says it.
                const button = if (act.installed) "[ Update ]" else "[ Install ]";
                if (act.installed)
                    return std.fmt.allocPrint(a, "{s}   (press i)", .{button});
                return std.fmt.allocPrint(a, "{s}   (press i)\n\nstatus: press i to install", .{button});
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
        var box_raw = try self.renderModal(a);
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
            .working => try modalRow(&out.writer, vbar, inner_w, "Working…", zz.width("Working…")),
            .result => {
                const sty = (zz.Style{}).fg(if (m.ok) .green else .red);
                // Greedy word-wrap the outcome message into the inner width.
                const msg = m.msg_buf[0..m.msg_len];
                var start: usize = 0;
                while (start < msg.len) {
                    var end = @min(start + inner_w, msg.len);
                    if (end < msg.len) {
                        var b = end;
                        while (b > start and msg[b] != ' ') b -= 1;
                        if (b > start) end = b;
                    }
                    const seg = std.mem.trim(u8, msg[start..end], " ");
                    const styled = sty.render(a, seg) catch seg;
                    try modalRow(&out.writer, vbar, inner_w, styled, zz.width(seg));
                    start = end;
                    while (start < msg.len and msg[start] == ' ') start += 1;
                }
            },
        }

        try modalRow(&out.writer, vbar, inner_w, "", 0);
        const hint = switch (m.stage) {
            .menu => "enter: select   esc: close",
            .password => "enter: confirm   esc: cancel",
            .working => "please wait…",
            .result => "press any key to close",
        };
        const hint_styled = (zz.Style{}).dim(true).render(a, hint) catch hint;
        try modalRow(&out.writer, vbar, inner_w, hint_styled, zz.width(hint));
        try modalRule(a, &out.writer, brand, inner_w, "└", "┘", "");

        return out.toOwnedSlice();
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
                // The selection marker is a bold, brand-coloured arrow so the
                // current coin stands out at a glance; unselected rows get blank
                // padding of the same visible width (2 cells) to keep alignment.
                const marker: []const u8 = if (i == selected)
                    (zz.Style{}).bold(true).fg(entryColor(e)).render(a, "❯ ") catch "❯ "
                else
                    "  ";
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

/// Human "behind by …" text from `secs` seconds behind the chain tip: the most
/// significant non-zero unit among years/months/weeks/days/hours/minutes, plus
/// the next unit down when it's also non-zero (e.g. "2 years 3 months behind",
/// "5 days behind", "1 hour 30 minutes behind"). Returns "" when under a minute
/// behind (effectively caught up) or when `secs <= 0`. The day-and-up units are
/// calendar approximations (year = 365d, month = 30d, week = 7d); hours and
/// minutes are exact — a "roughly how far back" readout, not a precise duration.
fn formatBehind(a: std.mem.Allocator, secs: i64) ![]const u8 {
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

    const primary = try std.fmt.allocPrint(a, "{d} {s}", .{
        counts[i], if (counts[i] == 1) singular[i] else plural[i],
    });
    // Append the next unit down only when it's non-zero, so the readout stays
    // contiguous ("3 months 1 week", never "2 years 1 day").
    if (i + 1 < counts.len and counts[i + 1] != 0) {
        const j = i + 1;
        return std.fmt.allocPrint(a, "{s} {d} {s} behind", .{
            primary, counts[j], if (counts[j] == 1) singular[j] else plural[j],
        });
    }
    return std.fmt.allocPrint(a, "{s} behind", .{primary});
}

/// Human date/time of the block at unix timestamp `unix_secs`, as
/// "YYYY-MM-DD HH:MM UTC". Returns "" when the timestamp is unknown
/// (`<= 0`). UTC, not local time: a block timestamp is a UTC moment and the
/// stdlib has no timezone database, so a fixed, unambiguous zone is correct
/// and portable across Linux/Windows/macOS.
fn formatBlockTime(a: std.mem.Allocator, unix_secs: i64) ![]const u8 {
    if (unix_secs <= 0) return "";
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(unix_secs) };
    const day = epoch.getEpochDay();
    const day_secs = epoch.getDaySeconds();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
    });
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
    // want two decimal places (e.g. "42.37%") for in-progress values, but plain
    // "0%"/"100%" at the endpoints so the common cases stay tidy.
    p.show_percent = false;
    const bar_str = try p.view(a);
    const pct = p.percent();
    const pct_str = if (pct <= 0)
        try std.fmt.allocPrint(a, " 0%", .{})
    else if (pct >= 100)
        try std.fmt.allocPrint(a, " 100%", .{})
    else
        try std.fmt.allocPrint(a, " {d:.2}%", .{pct});
    const pct_styled = try p.percent_style.render(a, pct_str);
    return std.mem.concat(a, u8, &.{ bar_str, pct_styled });
}

test "formatBehind picks the top two contiguous units, pluralizing correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const minute = std.time.s_per_min;
    const hour = std.time.s_per_hour;
    const day = std.time.s_per_day;

    // Under a minute behind reads as caught up (empty) — including non-positive.
    try std.testing.expectEqualStrings("", try formatBehind(a, 0));
    try std.testing.expectEqualStrings("", try formatBehind(a, -100));
    try std.testing.expectEqualStrings("", try formatBehind(a, minute - 1));

    // Minutes and hours, singular vs plural and contiguous pairs.
    try std.testing.expectEqualStrings("1 minute behind", try formatBehind(a, minute));
    try std.testing.expectEqualStrings("45 minutes behind", try formatBehind(a, 45 * minute));
    try std.testing.expectEqualStrings("1 hour behind", try formatBehind(a, hour));
    try std.testing.expectEqualStrings("1 hour 30 minutes behind", try formatBehind(a, hour + 30 * minute));
    try std.testing.expectEqualStrings("2 days 3 hours behind", try formatBehind(a, 2 * day + 3 * hour));

    // Single unit, singular vs plural.
    try std.testing.expectEqualStrings("1 day behind", try formatBehind(a, day));
    try std.testing.expectEqualStrings("5 days behind", try formatBehind(a, 5 * day));
    try std.testing.expectEqualStrings("1 week behind", try formatBehind(a, 7 * day));

    // Two contiguous units (year = 365d, month = 30d, week = 7d).
    try std.testing.expectEqualStrings("1 week 2 days behind", try formatBehind(a, 9 * day));
    try std.testing.expectEqualStrings("3 months 1 week behind", try formatBehind(a, (90 + 7) * day));
    try std.testing.expectEqualStrings("2 years 3 months behind", try formatBehind(a, (2 * 365 + 90) * day));

    // The second unit is shown only when non-zero, never skipping a zero unit:
    // exactly two years has no months, so it stays a single unit. Likewise a
    // day with zero hours drops the trailing minutes rather than skipping hours.
    try std.testing.expectEqualStrings("2 years behind", try formatBehind(a, 2 * 365 * day));
    try std.testing.expectEqualStrings("1 day behind", try formatBehind(a, day + 5 * minute));
}

test "formatBlockTime renders the tip block timestamp as UTC date/time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Unknown timestamp folds out to empty.
    try std.testing.expectEqualStrings("", try formatBlockTime(a, 0));
    try std.testing.expectEqualStrings("", try formatBlockTime(a, -1));

    // A known later instant.
    try std.testing.expectEqualStrings("2026-06-02 14:32 UTC", try formatBlockTime(a, 1_780_410_720));
    // Zero-padding on every field (Bitcoin's genesis block, single-digit
    // month/day).
    try std.testing.expectEqualStrings("2009-01-03 18:15 UTC", try formatBlockTime(a, 1_231_006_505));
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
    _ = app.init(&ctx);
    defer app.deinit();

    app.logf("NEXA: {s}", .{"installing…"});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const term_height: u16 = 24;
    const out = try app.renderWithLog(arena.allocator(), 80, term_height, "TOP\n");

    // The separator bar and the logged line both appear below the top content.
    try std.testing.expect(std.mem.indexOf(u8, out, "Log") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "NEXA: installing…") != null);

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

test "debug.log helpers strip the timestamp and pick the root-cause line" {
    // A real bitcoin-style timestamp prefix is stripped to the bare message.
    try std.testing.expectEqualStrings(
        ": Incorrect or no genesis block found. Wrong datadir for network?.",
        stripLogTimestamp("2026-06-08 14:55:44 : Incorrect or no genesis block found. Wrong datadir for network?."),
    );
    // A line without the prefix is returned untouched.
    try std.testing.expectEqualStrings("plain line", stripLogTimestamp("plain line"));

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
    try std.testing.expect(std.mem.indexOf(u8, out, "25.00%") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, out, "50.00%") != null);
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

test "wallet menu offers the actions that fit the wallet state" {
    var buf: [3]WalletAction = undefined;

    // Unencrypted → only Encrypt.
    {
        const n = walletOptions(.unencrypted, false, &buf);
        try std.testing.expectEqual(@as(usize, 1), n);
        try std.testing.expectEqual(WalletAction.encrypt, buf[0]);
    }
    // Locked on a proof-of-work coin → just Unlock.
    {
        const n = walletOptions(.locked, false, &buf);
        try std.testing.expectEqual(@as(usize, 1), n);
        try std.testing.expectEqual(WalletAction.unlock, buf[0]);
    }
    // Locked on a proof-of-stake coin → Unlock + Unlock-for-staking.
    {
        const n = walletOptions(.locked, true, &buf);
        try std.testing.expectEqual(@as(usize, 2), n);
        try std.testing.expectEqual(WalletAction.unlock, buf[0]);
        try std.testing.expectEqual(WalletAction.stake, buf[1]);
    }
    // Unlocked (either flavour) → Lock.
    {
        try std.testing.expectEqual(@as(usize, 1), walletOptions(.unlocked, true, &buf));
        try std.testing.expectEqual(WalletAction.lock, buf[0]);
        try std.testing.expectEqual(@as(usize, 1), walletOptions(.unlocked_for_staking, true, &buf));
        try std.testing.expectEqual(WalletAction.lock, buf[0]);
    }
    // Unknown → no actions (the menu won't open).
    try std.testing.expectEqual(@as(usize, 0), walletOptions(.unknown, true, &buf));

    // Only lock skips the passphrase prompt.
    try std.testing.expect(WalletAction.encrypt.needsPassword());
    try std.testing.expect(WalletAction.unlock.needsPassword());
    try std.testing.expect(WalletAction.stake.needsPassword());
    try std.testing.expect(!WalletAction.lock.needsPassword());
}

test "WalletState mirrors the normalized WalletSecurity" {
    try std.testing.expectEqual(WalletState.unknown, WalletState.fromSecurity(.unknown));
    try std.testing.expectEqual(WalletState.unencrypted, WalletState.fromSecurity(.unencrypted));
    try std.testing.expectEqual(WalletState.locked, WalletState.fromSecurity(.locked));
    try std.testing.expectEqual(WalletState.unlocked, WalletState.fromSecurity(.unlocked));
    try std.testing.expectEqual(WalletState.unlocked_for_staking, WalletState.fromSecurity(.unlocked_for_staking));
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
    _ = app.init(&ctx);
    defer app.deinit();

    // Open a Divi (proof-of-stake) wallet modal on a locked wallet by hand — the
    // open gate needs a running daemon, so set the modal up directly here.
    app.selected = std.mem.indexOfScalar(Entry, &entries, .divi).?;
    var m: Modal = .{ .coin_idx = app.selected };
    m.option_count = walletOptions(.locked, true, &m.options);
    app.modal = m;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const screen = try App.renderTwoPane(a, app.selected, "right pane\n");
    const out = try app.renderModalOver(a, screen, 80, 24);

    // The modal's title and both locked-state actions appear in the composited
    // screen, framed by the box border.
    try std.testing.expect(std.mem.indexOf(u8, out, "Divi Wallet") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Unlock") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Unlock for staking") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "┘") != null);
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
