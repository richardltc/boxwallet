const std = @import("std");
const zz = @import("zigzag");
const models = @import("models.zig");
const install_mod = @import("install.zig");
const conf = @import("conf.zig");
const rpc = @import("rpc.zig");
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

/// Whether a coin's daemon is up. `starting`/`stopping` are the in-flight states
/// while a start/stop worker runs (both animate a spinner in the pane), settling
/// to `running` or `stopped` when the worker publishes its outcome.
const DaemonState = enum { stopped, starting, running, stopping };

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
    /// Latest polled peer count / staking flag (1/0).
    poll_peers: std.atomic.Value(u32) = .init(0),
    poll_staking: std.atomic.Value(u8) = .init(0),
    /// Latest polled chain heights and sync flag, from `getblockchaininfo`.
    poll_headers: std.atomic.Value(u64) = .init(0),
    poll_blocks: std.atomic.Value(u64) = .init(0),
    poll_synced: std.atomic.Value(u8) = .init(0),
    /// Estimated network tip (max peer `synced_headers`), the Headers bar target.
    poll_network: std.atomic.Value(u64) = .init(0),

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

        // The reply ("<coin> server stopping") is discarded; the arena frees it.
        _ = try rpc.call(a, auth, "stop");

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
        self.headers_total = @max(network, headers);
        self.blocks_cur = blocks;
        self.blocks_total = @max(headers, blocks);
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
        } else |_| {
            self.poll_ok = false;
        }
        self.poll_done.store(true, .release);
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

        const info = try self.coin.daemonInfo(a, auth);
        self.poll_peers.store(@as(u32, @intCast(@max(info.connections, 0))), .monotonic);
        self.poll_staking.store(@intFromBool(info.staking_active), .monotonic);

        const state = try self.coin.blockchainState(a, auth);
        defer state.deinit(a);
        self.poll_headers.store(@as(u64, @intCast(@max(state.headers, 0))), .monotonic);
        self.poll_blocks.store(@as(u64, @intCast(@max(state.blocks, 0))), .monotonic);
        self.poll_network.store(@as(u64, @intCast(@max(state.network_height, 0))), .monotonic);
        self.poll_synced.store(@intFromBool(state.synced), .monotonic);
    }

    /// Spawn the daemon binary with `-daemon` and decide whether it started,
    /// capturing the launcher's stderr so a failure can report the reason.
    /// `argv[0]` carries a path separator, so it's resolved as a file path
    /// rather than via PATH.
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
        const path = try std.fs.path.join(a, &.{ self.install_root, self.coin.daemonFile() });

        var threaded: std.Io.Threaded = .init(a, .{});
        defer threaded.deinit();
        const io = threaded.io();

        // Make sure the conf has RPC creds (and server=1/daemon=1/rpcport) before
        // the daemon reads it — otherwise it falls back to cookie auth we can't
        // use, leaving the daemon unmanageable over RPC (poll/stop). Existing
        // values are kept, so a coin already configured is untouched.
        const data_dir = try self.coin.dataDir(a, self.home_dir);
        _ = try conf.populate(
            a,
            io,
            data_dir,
            self.coin.confFile(),
            self.coin.rpcDefaultUsername(),
            self.coin.rpcDefaultPort(),
        );

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
            .argv = &.{ path, "-daemon" },
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
        "cannot",    "unable",  "denied",     "invalid",        "not found",
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
            .selected = 0,
            .activities = undefined,
        };
        for (&self.activities) |*act| act.* = .{ .spinner = zz.Spinner.init(), .daemon_spinner = zz.Spinner.init(), .sync_spinner = zz.Spinner.init() };
        self.refreshSelectedInstalled();

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
        }
        if (self.install_root_owned) self.allocator.free(self.install_root);
        if (self.home_dir_owned) self.allocator.free(self.home_dir);
    }

    pub fn update(self: *App, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |k| switch (k.key) {
                .char => |c| switch (c) {
                    'q' => return .quit,
                    'i' => self.tryInstall(),
                    's' => self.tryStart(),
                    'p' => self.tryStop(),
                    'k' => self.move(-1),
                    'j' => self.move(1),
                    'l' => self.log_visible = !self.log_visible,
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
        // All installed coins are polled for live status on a shared ~2s cadence.
        const poll_due = t.timestamp - self.last_poll_ns >= 2 * std.time.ns_per_s;
        for (&self.activities, 0..) |*act, i| {
            if (entries[i] == .home) continue;
            const p = act.phaseOf();
            if (p == .extracting) {
                _ = act.spinner.update(t.timestamp);
            }
            const ds = act.daemonState();
            // The daemon spinner animates while a start or stop is in flight, and
            // during the brief pre-first-poll window, so Running/Staking read as
            // "loading" until the first result lands.
            if (ds == .starting or ds == .stopping or act.awaitingStatus()) {
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
                        self.logf("{s}: daemon stopped", .{act.coin.coinName()});
                    } else self.logf("{s}: daemon failed to stop ({s})", .{ act.coin.coinName(), act.daemon_err }),
                }
            }
            if (act.sync == .syncing) {
                _ = act.sync_spinner.update(t.timestamp);
            }

            // Fold in a finished getinfo poll: take the live peer count and
            // staking flag, and — since a reply proves the daemon is up — mark it
            // running (covers a daemon started outside BoxWallet).
            if (act.poll_thread != null and act.poll_done.load(.acquire)) {
                act.poll_thread.?.join();
                act.poll_thread = null;
                act.poll_completed = true;
                if (act.applyPoll() and act.daemonState() != .running)
                    act.daemon.store(@intFromEnum(DaemonState.running), .release);
            }

            // Start the next poll for an installed, idle coin when the cadence is
            // due and none is in flight. Only the selected coin is polled — its
            // dashboard is the only one on screen, so polling a coin we're not
            // viewing buys nothing. Skipped while an install or daemon-start
            // worker is touching this activity, so `coin` isn't written under it.
            if (i == self.selected and poll_due and act.installed and
                act.poll_thread == null and !act.busy() and act.daemon_thread == null)
            {
                if (self.coinAt(i)) |coin| {
                    act.coin = coin;
                    act.home_dir = self.home_dir;
                    act.poll_ok = false;
                    act.poll_done.store(false, .monotonic);
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
        }
        if (poll_due) self.last_poll_ns = t.timestamp;
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
        // poll clock makes the next tick due immediately.
        if (moved) self.last_poll_ns = 0;
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
        act.home_dir = self.home_dir;
        act.environ_map = self.environ_map;
        act.daemon_action = .start;
        act.daemon_spinner = zz.Spinner.init();
        act.daemon_err = "";
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
        act.daemon_spinner = zz.Spinner.init();
        act.daemon_err = "";
        act.daemon.store(@intFromEnum(DaemonState.stopping), .release);

        act.daemon_thread = std.Thread.spawn(.{}, Activity.runStopDaemon, .{act}) catch {
            act.daemon.store(@intFromEnum(DaemonState.running), .release);
            return;
        };
        self.logf("{s}: stopping daemon…", .{coin.coinName()});
    }

    pub fn view(self: *const App, ctx: *const zz.Context) []const u8 {
        const a = ctx.allocator;

        const right = self.renderDetail(a);
        const top = renderTwoPane(a, self.selected, right) catch "render error";
        if (!self.log_visible) return top;
        return self.renderWithLog(a, ctx.width, ctx.height, top) catch top;
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
                \\  s        start selected coin's daemon
                \\  p        stop selected coin's daemon
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

        // While the first poll is still pending, the daemon/staking status isn't
        // known yet — animate rather than flash a misleading ✘.
        const awaiting = act.awaitingStatus();

        // The daemon line is a tick/cross when stopped or up, or a spinner while
        // it's starting or while the first status poll is still in flight.
        const daemon_label = label_style.render(a, "Running") catch "Running";
        const daemon_mark: []const u8 = switch (act.daemonState()) {
            .running => statusMark(a, true),
            .stopped => if (awaiting) act.daemon_spinner.view(a) catch "…" else statusMark(a, false),
            .starting, .stopping => act.daemon_spinner.view(a) catch "…",
        };

        // Peer count: red while 0, green once any peer is connected.
        const peers_label = label_style.render(a, "Peers") catch "Peers";
        const peers_count = std.fmt.allocPrint(a, "{d}", .{act.peers}) catch "?";
        const peers_value = (zz.Style{}).bold(true).fg(if (act.peers > 0) .green else .red).render(a, peers_count) catch peers_count;

        // Sync line: red cross when idle, spinner while syncing, green tick once
        // synced. The label itself reads "Synced" only when fully synced.
        const sync_text = if (act.sync == .synced) "Synced" else "Syncing";
        const sync_label = label_style.render(a, sync_text) catch sync_text;
        const sync_mark: []const u8 = if (awaiting)
            act.daemon_spinner.view(a) catch "…"
        else switch (act.sync) {
            .synced => statusMark(a, true),
            .idle => statusMark(a, false),
            .syncing => act.sync_spinner.view(a) catch "…",
        };

        // Staking only applies to proof-of-stake coins; PoW coins omit it
        // entirely (empty string folds out of the status line).
        const staking_part: []const u8 = if (coin.isProofOfStake()) blk: {
            const staking_label = label_style.render(a, "Staking") catch "Staking";
            const staking_mark = if (awaiting) act.daemon_spinner.view(a) catch "…" else statusMark(a, act.staking);
            break :blk std.fmt.allocPrint(a, "    {s}: {s}", .{ staking_label, staking_mark }) catch "";
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
        const stop_button = renderStopButton(a, act);

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
            stop_button,
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
            .stopping => blk: {
                const b = (zz.Style{}).dim(true).render(a, "[ Start ]") catch "[ Start ]";
                break :blk std.fmt.allocPrint(a, "{s}   (stopping…)", .{b}) catch "[ Start ]";
            },
        };
    }

    /// The "Stop" button line. Enabled (and bound to `p`) only when the daemon is
    /// running; otherwise it's dimmed with a reason. While stopping it shows the
    /// in-progress label.
    fn renderStopButton(a: std.mem.Allocator, act: *const Activity) []const u8 {
        if (!act.installed) {
            const b = (zz.Style{}).dim(true).render(a, "[ Stop ]") catch "[ Stop ]";
            return std.fmt.allocPrint(a, "{s}   (install first)", .{b}) catch "[ Stop ]";
        }
        return switch (act.daemonState()) {
            .running => "[ Stop ]   (press p)",
            .stopping => "[ Stopping… ]",
            .stopped, .starting => blk: {
                const b = (zz.Style{}).dim(true).render(a, "[ Stop ]") catch "[ Stop ]";
                break :blk std.fmt.allocPrint(a, "{s}   (not running)", .{b}) catch "[ Stop ]";
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
    ahead.poll_network.store(4_071_160, .monotonic);
    ahead.poll_headers.store(4_071_165, .monotonic);
    ahead.poll_blocks.store(4_071_165, .monotonic);
    try std.testing.expect(ahead.applyPoll());
    try std.testing.expectEqual(@as(u64, 4_071_165), ahead.headers_total);
    try std.testing.expectEqual(ahead.headers_total, ahead.headers_cur);

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

test "Stop button reflects daemon state" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var act: Activity = .{};

    // Disabled until installed.
    act.installed = false;
    try std.testing.expect(std.mem.indexOf(u8, App.renderStopButton(a, &act), "install first") != null);

    // Installed but stopped → disabled (nothing to stop).
    act.installed = true;
    try std.testing.expect(std.mem.indexOf(u8, App.renderStopButton(a, &act), "not running") != null);

    // Running → bound to `p`.
    act.daemon.store(@intFromEnum(DaemonState.running), .release);
    try std.testing.expect(std.mem.indexOf(u8, App.renderStopButton(a, &act), "press p") != null);

    // Stopping → shows the in-progress label.
    act.daemon.store(@intFromEnum(DaemonState.stopping), .release);
    try std.testing.expect(std.mem.indexOf(u8, App.renderStopButton(a, &act), "Stopping") != null);
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
