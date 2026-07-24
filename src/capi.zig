//! C-ABI shim over the BoxWallet core, for the Slint GUI front-end.
//!
//! The GUI is a thin C++ layer (Slint's binding language) that drives the exact
//! same coin logic the TUI does — the `Coin` vtable in `coin.zig`. Rather than
//! bind Slint's C++ API from Zig (it isn't a stable C ABI), the C++ glue calls
//! *this* module's `export fn`s over a plain C ABI (see `include/boxwallet.h`).
//!
//! This is the entire Zig surface the GUI needs for the proof-of-concept:
//! **read-only status** for one coin (Divi) — daemon info + chain sync. It
//! deliberately touches **no secrets** (no wallet/password), so the risky
//! secret-over-FFI path is designed (in the header/comments) but not yet wired.
//!
//! Memory: the context holds only a couple of tiny long-lived strings on the
//! page allocator; every live RPC call runs on its own `ArenaAllocator` that is
//! freed when the call returns, so the working set stays bounded and nothing
//! leaks across the boundary (honoring the repo's low-RAM rule). No libc is
//! required — the GUI links libc, but `zig build test` need not.

const std = @import("std");
const builtin = @import("builtin");
const coinmod = @import("coin.zig");
const models = @import("models.zig");
const conf = @import("conf.zig");
const install = @import("install.zig");

// Every coin backend, so the GUI can list them all in the nav (like the TUI).
const nexa = @import("coins/nexa.zig");
const divi = @import("coins/divi.zig");
const ergo = @import("coins/ergo.zig");
const digibyte = @import("coins/digibyte.zig");
const zano = @import("coins/zano.zig");
const nerva = @import("coins/nerva.zig");
const reddcoin = @import("coins/reddcoin.zig");
const epic = @import("coins/epic.zig");
const salvium = @import("coins/salvium.zig");
const litecoin = @import("coins/litecoin.zig");
const bitcoin = @import("coins/bitcoin.zig");
const bitcoinz = @import("coins/bitcoinz.zig");
const spiderbyte = @import("coins/spiderbyte.zig");
const monero = @import("coins/monero.zig");

const Coin = coinmod.Coin;

/// Opaque per-process context handed back to the C++ side by `bw_init`. Owns the
/// resolved home/install-root strings and a bounded last-error buffer. Single
/// worker thread drives it in the POC, so the last-error slot needs no lock yet.
const Ctx = struct {
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    install_root: []const u8,
    err_buf: [256]u8 = undefined,
    err_len: usize = 0,
    // Retained handle for a foreground/no-RPC daemon we launched, so a coin with
    // no shutdown RPC can be killed on stop (mirrors the TUI's `daemon_child`).
    daemon_child: ?std.process.Child = null,
    // Install progress. Unlike the rest of Ctx these are genuinely cross-thread —
    // the install worker writes them while the UI poll thread reads them every
    // frame — so they're atomic rather than plain fields. `install_phase` holds a
    // `bw_install_phase_*` code; the byte counters are only meaningful while it
    // is `downloading` (see `bw_install_progress`).
    install_phase: std.atomic.Value(u8) = .init(bw_install_phase_idle),
    install_cur: std.atomic.Value(u64) = .init(0),
    install_total: std.atomic.Value(u64) = .init(0),

    fn setError(self: *Ctx, msg: []const u8) void {
        const n = @min(msg.len, self.err_buf.len);
        @memcpy(self.err_buf[0..n], msg[0..n]);
        self.err_len = n;
    }
};

// The registered coins, in a stable index order the C++ side addresses by
// `size_t` (the same set/order as the TUI's `coin_entries`; the GUI sorts them
// alphabetically for display). Static instances: each coin is a zero-field
// struct (the TUI default-inits them the same way), and `coin()` wants a pointer.
var g_nexa: nexa.Nexa = .{};
var g_divi: divi.Divi = .{};
var g_ergo: ergo.Ergo = .{};
var g_digibyte: digibyte.DigiByte = .{};
var g_zano: zano.Zano = .{};
var g_nerva: nerva.Nerva = .{};
var g_reddcoin: reddcoin.ReddCoin = .{};
var g_epic: epic.Epic = .{};
var g_salvium: salvium.Salvium = .{};
var g_litecoin: litecoin.Litecoin = .{};
var g_bitcoin: bitcoin.Bitcoin = .{};
var g_bitcoinz: bitcoinz.BitcoinZ = .{};
var g_spiderbyte: spiderbyte.SpiderByte = .{};
var g_monero: monero.Monero = .{};

fn coinCount() usize {
    return 14;
}

fn coinByIndex(idx: usize) ?Coin {
    return switch (idx) {
        0 => g_nexa.coin(),
        1 => g_divi.coin(),
        2 => g_ergo.coin(),
        3 => g_digibyte.coin(),
        4 => g_zano.coin(),
        5 => g_nerva.coin(),
        6 => g_reddcoin.coin(),
        7 => g_epic.coin(),
        8 => g_salvium.coin(),
        9 => g_litecoin.coin(),
        10 => g_bitcoin.coin(),
        11 => g_bitcoinz.coin(),
        12 => g_spiderbyte.coin(),
        13 => g_monero.coin(),
        else => null,
    };
}

// ---- C structs (mirror `include/boxwallet.h` exactly) -----------------------

/// Mirror of `models.DaemonInfo`, flattened for C. `version` is a fixed,
/// NUL-terminated buffer (no ownership crosses the boundary).
pub const BwDaemonInfo = extern struct {
    blocks: i64,
    connections: i64,
    staking_active: c_int,
    version: [64]u8,
};

/// Mirror of `models.BlockchainState`. `chain` is copied into a fixed buffer and
/// the Zig-owned source string is freed before returning (the arena handles it).
pub const BwBlockchainState = extern struct {
    blocks: i64,
    headers: i64,
    verification_progress: f64,
    synced: c_int,
    network_height: i64,
    tip_time: i64,
    seconds_behind: i64,
    chain: [32]u8,
};

// ---- small helpers ----------------------------------------------------------

/// Copy `src` into a caller buffer, returning the byte count written (never more
/// than `dst.len`). Not NUL-terminated — the caller has the returned length.
fn copyOut(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

/// Fill a fixed NUL-terminated C char array field, truncating if needed.
fn setField(field: []u8, src: []const u8) void {
    const n = @min(field.len -| 1, src.len);
    @memcpy(field[0..n], src[0..n]);
    field[n] = 0;
}

// ---- context lifecycle ------------------------------------------------------

export fn bw_init(home_dir: ?[*:0]const u8) ?*Ctx {
    const hd_z = home_dir orelse return null;
    const hd = std.mem.span(hd_z);
    const a = std.heap.page_allocator;

    const ctx = a.create(Ctx) catch return null;
    ctx.* = .{ .allocator = a, .home_dir = undefined, .install_root = undefined };

    ctx.home_dir = a.dupe(u8, hd) catch {
        a.destroy(ctx);
        return null;
    };
    ctx.install_root = install.installRoot(a, hd) catch {
        a.free(ctx.home_dir);
        a.destroy(ctx);
        return null;
    };
    return ctx;
}

export fn bw_deinit(ctx: ?*Ctx) void {
    const c = ctx orelse return;
    const a = c.allocator;
    a.free(c.install_root);
    a.free(c.home_dir);
    a.destroy(c);
}

/// Length of the last error recorded on `ctx`, copied into the caller buffer.
export fn bw_last_error(ctx: ?*Ctx, buf: ?[*]u8, cap: usize) usize {
    const c = ctx orelse return 0;
    const b = buf orelse return 0;
    return copyOut(b[0..cap], c.err_buf[0..c.err_len]);
}

// ---- coin registry / metadata (no ctx, no allocation) -----------------------

export fn bw_coin_count() usize {
    return coinCount();
}

export fn bw_coin_name(idx: usize, buf: ?[*]u8, cap: usize) usize {
    const c = coinByIndex(idx) orelse return 0;
    const b = buf orelse return 0;
    return copyOut(b[0..cap], c.coinName());
}

export fn bw_coin_abbrev(idx: usize, buf: ?[*]u8, cap: usize) usize {
    const c = coinByIndex(idx) orelse return 0;
    const b = buf orelse return 0;
    return copyOut(b[0..cap], c.coinNameAbbrev());
}

export fn bw_coin_color(idx: usize, buf: ?[*]u8, cap: usize) usize {
    const c = coinByIndex(idx) orelse return 0;
    const b = buf orelse return 0;
    return copyOut(b[0..cap], c.coinColor());
}

export fn bw_coin_description(idx: usize, buf: ?[*]u8, cap: usize) usize {
    const c = coinByIndex(idx) orelse return 0;
    const b = buf orelse return 0;
    return copyOut(b[0..cap], c.coinDescription());
}

/// The bundled core version this coin installs (e.g. "3.0.0.0").
export fn bw_coin_version(idx: usize, buf: ?[*]u8, cap: usize) usize {
    const c = coinByIndex(idx) orelse return 0;
    const b = buf orelse return 0;
    return copyOut(b[0..cap], c.coreVersion());
}

/// Whether this coin lights up the Mining tab (its daemon mines in-process).
export fn bw_coin_supports_mining(idx: usize) c_int {
    const c = coinByIndex(idx) orelse return 0;
    return if (c.supportsMining()) 1 else 0;
}

/// Whether this coin lights up the DigiDollar tab (a chain-native stablecoin).
export fn bw_coin_supports_stablecoin(idx: usize) c_int {
    const c = coinByIndex(idx) orelse return 0;
    return if (c.supportsStablecoin()) 1 else 0;
}

// ---- installed / data dir (need ctx for install root & home) ----------------

export fn bw_is_installed(ctx: ?*Ctx, idx: usize) c_int {
    const c = ctx orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;
    return if (coin.isInstalled(c.allocator, c.install_root)) 1 else 0;
}

export fn bw_data_dir(ctx: ?*Ctx, idx: usize, buf: ?[*]u8, cap: usize) usize {
    const c = ctx orelse return 0;
    const b = buf orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const dir = coin.dataDir(arena.allocator(), c.home_dir) catch return 0;
    return copyOut(b[0..cap], dir);
}

// ---- live read-only RPC calls (the POC core) --------------------------------

/// Resolve creds and read `getinfo`. Mirrors the TUI's worker pattern in
/// `app.zig` (`std.Io.Threaded` per call, `conf.readAuth`, then the vtable call).
/// Everything allocates into a per-call arena freed on return.
fn fetchDaemonInfo(ctx: *Ctx, idx: usize, out: *BwDaemonInfo) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const coin = coinByIndex(idx) orelse return error.NoSuchCoin;
    const data_dir = try coin.dataDir(a, ctx.home_dir);
    const auth = try conf.readAuth(a, io, data_dir, coin.confFile(), coin.rpcDefaultUsername(), coin.rpcDefaultPort());

    const di = try coin.daemonInfo(a, auth);
    out.blocks = di.blocks;
    out.connections = di.connections;
    out.staking_active = if (di.staking_active) 1 else 0;
    setField(out.version[0..], di.version);
}

fn fetchBlockchainState(ctx: *Ctx, idx: usize, out: *BwBlockchainState) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const coin = coinByIndex(idx) orelse return error.NoSuchCoin;
    const data_dir = try coin.dataDir(a, ctx.home_dir);
    const auth = try conf.readAuth(a, io, data_dir, coin.confFile(), coin.rpcDefaultUsername(), coin.rpcDefaultPort());

    // `bs` owns its `chain` string on the arena; the arena frees it on return,
    // so we copy the name into the fixed field before that happens.
    const bs = try coin.blockchainState(a, auth);
    out.blocks = bs.blocks;
    out.headers = bs.headers;
    out.verification_progress = bs.verification_progress;
    out.synced = if (bs.synced) 1 else 0;
    out.network_height = bs.network_height;
    out.tip_time = bs.tip_time;
    out.seconds_behind = bs.seconds_behind;
    setField(out.chain[0..], bs.chain);
}

export fn bw_daemon_info(ctx: ?*Ctx, idx: usize, out: ?*BwDaemonInfo) c_int {
    const c = ctx orelse return -1;
    const o = out orelse return -1;
    fetchDaemonInfo(c, idx, o) catch |err| {
        c.setError(@errorName(err));
        return -1;
    };
    return 0;
}

export fn bw_blockchain_state(ctx: ?*Ctx, idx: usize, out: ?*BwBlockchainState) c_int {
    const c = ctx orelse return -1;
    const o = out orelse return -1;
    fetchBlockchainState(c, idx, o) catch |err| {
        c.setError(@errorName(err));
        return -1;
    };
    return 0;
}

// ---- daemon control + wallet lock/unlock (the action buttons) ---------------
//
// These mirror the TUI's launch/stop/lock paths, driven through the same `Coin`
// vtable (prepareConf/daemonArgv/launchMode, requestStop, walletLock/Unlock).
// They block (spawn / RPC), so the C++ side runs them off the UI thread.

fn ctxAuth(a: std.mem.Allocator, io: std.Io, coin: Coin, ctx: *Ctx) !models.CoinAuth {
    const data_dir = try coin.dataDir(a, ctx.home_dir);
    return conf.readAuth(a, io, data_dir, coin.confFile(), coin.rpcDefaultUsername(), coin.rpcDefaultPort());
}

/// Poll `getinfo` for a few seconds; true once the daemon answers.
fn confirmAlive(ctx: *Ctx, coin: Coin) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const auth = ctxAuth(a, io, coin, ctx) catch return false;
    var i: u8 = 0;
    while (i < 20) : (i += 1) {
        io.sleep(.fromMilliseconds(250), .awake) catch {};
        var probe = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer probe.deinit();
        if (coin.daemonInfo(probe.allocator(), auth)) |_| return true else |_| {}
    }
    return false;
}

/// Non-blocking check of a spawned child: null while still running, else its
/// exit term (and reaps it). POSIX (the GUI is Linux); a no-op elsewhere.
/// Reconstruct the current process's environment as an `Environ.Map`, so a
/// daemon we spawn inherits `$HOME`/`$PATH`/etc. `std.process.spawn` with a null
/// `environ_map` gives the child an *empty* environment (verified: the child sees
/// `HOME=[]` even though we have it set) — which left foreground daemons like
/// Nerva unable to locate their `~/.<coin>` data dir, so they died during init and
/// the GUI's Start silently failed. The TUI dodges this by passing the environ
/// `std.process.Init` captured for it; the C++-entry GUI has no such capture, so
/// we rebuild it from libc's `environ`.
fn currentEnvMap(a: std.mem.Allocator) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(a);
    errdefer map.deinit();
    // libc-linked only (the GUI always links libc). The Zig-entry offline-test
    // binary doesn't link libc and never calls this — comptime-gating on
    // `link_libc` prunes the `std.c` reference so that build stays libc-free.
    if (builtin.os.tag != .windows and builtin.link_libc) {
        const env = std.c.environ;
        var count: usize = 0;
        while (env[count] != null) : (count += 1) {}
        const slice: []const [*:0]const u8 = @ptrCast(env[0..count]);
        try map.putPosixBlock(.{ .slice = slice });
    }
    return map;
}

fn probeChild(child: *std.process.Child) ?std.process.Child.Term {
    if (builtin.os.tag == .windows) return null;
    const posix = std.posix;
    const pid = child.id orelse return .{ .unknown = 0 };
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    const rc = posix.system.wait4(pid, &status, posix.W.NOHANG, null);
    return switch (posix.errno(rc)) {
        .SUCCESS => if (rc == 0) null else blk: {
            child.id = null; // reaped here; nothing left to wait/kill
            break :blk std.Io.Threaded.statusToTerm(@bitCast(status));
        },
        .INTR => null,
        else => .{ .unknown = 0 },
    };
}

fn startDaemon(ctx: *Ctx, idx: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const coin = coinByIndex(idx) orelse return error.NoSuchCoin;

    // Conf must carry RPC creds / API key before the daemon reads it, or it's
    // unmanageable over RPC. Idempotent; keeps existing values.
    try coin.prepareConf(a, io, ctx.install_root, ctx.home_dir);
    const argv = try coin.daemonArgv(a, ctx.install_root, ctx.home_dir);

    // The spawned daemon must inherit our environment (esp. `$HOME`, used to
    // resolve `~/.<coin>`); a null environ_map would hand it an empty one.
    var env_map = try currentEnvMap(a);
    defer env_map.deinit();

    // Capture the process's stderr so a failed start can report the real reason.
    const err_name = try std.fmt.allocPrint(a, ".{s}.startup", .{coin.daemonFile()});
    const err_path = try std.fs.path.join(a, &.{ ctx.install_root, err_name });
    var err_file = try std.Io.Dir.createFileAbsolute(io, err_path, .{ .read = true });
    defer {
        err_file.close(io);
        std.Io.Dir.deleteFileAbsolute(io, err_path) catch {};
    }

    if (coin.launchMode() == .foreground) {
        // Foreground daemons (Ergo/Nerva/Salvium/Zano/…) run in their own process;
        // spawn detached and retain the handle for a kill-based stop.
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .{ .file = err_file },
            .environ_map = &env_map,
            .pgid = if (builtin.os.tag == .windows) null else 0,
            .create_no_window = builtin.os.tag == .windows,
        }) catch |err| {
            ctx.setError(@errorName(err));
            return err;
        };

        // Watch briefly for an early death — a foreground daemon that fails init
        // dies within a few seconds. If it survives, it has started. We do NOT
        // require it to answer RPC here: the epee daemons (Nerva/Salvium/Zano)
        // take a while to bring their RPC up, and demanding it (as `confirmAlive`
        // did) wrongly reports a healthy start as a failure. The status poll flips
        // the UI to "running" once it answers.
        var i: u8 = 0;
        while (i < 12) : (i += 1) {
            io.sleep(.fromMilliseconds(250), .awake) catch {};
            if (probeChild(&child)) |_| {
                var buf: [8 * 1024]u8 = undefined;
                const n = err_file.readPositionalAll(io, &buf, 0) catch 0;
                ctx.setError(if (n > 0) buf[0..n] else "daemon exited during startup (check its log)");
                return error.DaemonStartFailed;
            }
        }
        ctx.daemon_child = child;
        return;
    }

    // Fork path (bitcoin-derived, POSIX): append `-daemon` so the daemon forks
    // into the background and the launcher exits; wait on the launcher.
    const forked = try std.mem.concat(a, []const u8, &.{ argv, &.{"-daemon"} });
    var child = try std.process.spawn(io, .{
        .argv = forked,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .{ .file = err_file },
        .environ_map = &env_map,
    });
    switch (try child.wait(io)) {
        .exited => |code| if (code == 0) {
            // Launcher daemonized; confirm the daemon actually stuck around.
            if (confirmAlive(ctx, coin)) return;
            ctx.setError("daemon did not stay up (check its debug.log)");
            return error.DaemonStartFailed;
        },
        else => {},
    }
    var buf: [8 * 1024]u8 = undefined;
    const n = err_file.readPositionalAll(io, &buf, 0) catch 0;
    ctx.setError(if (n > 0) buf[0..n] else "daemon launcher failed");
    return error.DaemonStartFailed;
}

fn stopDaemon(ctx: *Ctx, idx: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const coin = coinByIndex(idx) orelse return error.NoSuchCoin;

    if (coin.hasRpcStop()) {
        const auth = try ctxAuth(a, io, coin, ctx);
        coin.requestStop(a, auth) catch |err| {
            ctx.setError(@errorName(err));
            return err;
        };
        // Wait (bounded) for it to actually go down.
        var i: u8 = 0;
        while (i < 40) : (i += 1) {
            io.sleep(.fromMilliseconds(250), .awake) catch {};
            var probe = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer probe.deinit();
            _ = coin.daemonInfo(probe.allocator(), auth) catch break;
        }
    } else if (ctx.daemon_child) |*child| {
        // No shutdown RPC (Zano): terminate the process we launched.
        child.kill(io);
        ctx.daemon_child = null;
    } else {
        return error.CannotStop;
    }
}

// ---- install ----------------------------------------------------------------

/// Phase codes reported by `bw_install_progress`, mirroring `install.Phase` plus
/// an idle state for "no install running". Kept in sync with `boxwallet.h`.
pub const bw_install_phase_idle: u8 = 0;
pub const bw_install_phase_downloading: u8 = 1;
pub const bw_install_phase_extracting: u8 = 2;

/// `install.Progress` sink: publishes the worker's byte counts into the Ctx for
/// the UI thread to poll. Monotonic ordering is enough — these drive a progress
/// readout, so a frame reading a slightly stale count is harmless, and nothing
/// else is ordered against them.
fn onInstallProgress(ctx_ptr: *anyopaque, phase: install.Phase, current: u64, total: u64) void {
    const c: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    c.install_phase.store(switch (phase) {
        .download => bw_install_phase_downloading,
        .extract => bw_install_phase_extracting,
    }, .monotonic);
    c.install_cur.store(current, .monotonic);
    c.install_total.store(total, .monotonic);
}

/// Download + install the coin. Blocking (streams hundreds of MB), so the C++
/// side runs it on its own thread and polls `bw_install_progress` meanwhile.
export fn bw_install(ctx: ?*Ctx, idx: usize) c_int {
    const c = ctx orelse return -1;
    const coin = coinByIndex(idx) orelse return -1;

    // Publish "started" before any work, so the UI switches to the progress
    // readout immediately rather than after the first byte lands, and clear it on
    // every exit path (success, failure, unsupported platform) so a failed
    // install can't strand the UI in a permanent "Downloading…".
    c.install_phase.store(bw_install_phase_downloading, .monotonic);
    c.install_cur.store(0, .monotonic);
    c.install_total.store(0, .monotonic);
    defer c.install_phase.store(bw_install_phase_idle, .monotonic);

    // Private arena: the install's working set is bounded and freed as a unit,
    // and never shares an allocator with the polling UI thread.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const progress: install.Progress = .{ .ctx = c, .func = onInstallProgress };
    coin.install(a, c.install_root, c.home_dir, progress) catch |err| {
        if (c.err_len == 0) c.setError(@errorName(err));
        return -1;
    };
    // Record what we just installed so update detection works with the daemon
    // stopped. Best-effort, exactly as the TUI does it: a marker hiccup must not
    // fail an otherwise-good install.
    install.writeVersionMarker(a, c.install_root, coin.daemonFile(), coin.coreVersion()) catch {};
    return 0;
}

/// Sample the running install's progress. Writes through any non-null out-param
/// and returns the phase code (`bw_install_phase_idle` when nothing is running).
/// `total` is 0 when the server sent no length, so the caller must treat the
/// fraction as unknown rather than dividing by zero.
export fn bw_install_progress(ctx: ?*Ctx, cur: ?*u64, total: ?*u64) u8 {
    const c = ctx orelse return bw_install_phase_idle;
    if (cur) |p| p.* = c.install_cur.load(.monotonic);
    if (total) |p| p.* = c.install_total.load(.monotonic);
    return c.install_phase.load(.monotonic);
}

export fn bw_start_daemon(ctx: ?*Ctx, idx: usize) c_int {
    const c = ctx orelse return -1;
    startDaemon(c, idx) catch |err| {
        if (c.err_len == 0) c.setError(@errorName(err));
        return -1;
    };
    return 0;
}

export fn bw_stop_daemon(ctx: ?*Ctx, idx: usize) c_int {
    const c = ctx orelse return -1;
    stopDaemon(c, idx) catch |err| {
        if (c.err_len == 0) c.setError(@errorName(err));
        return -1;
    };
    return 0;
}

fn walletAction(ctx: *Ctx, idx: usize, comptime lock: bool, pass: []const u8, staking: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const coin = coinByIndex(idx) orelse return error.NoSuchCoin;
    const auth = try ctxAuth(a, io, coin, ctx);
    if (lock) {
        try coin.walletLock(a, auth);
    } else {
        try coin.walletUnlock(a, auth, pass, staking);
    }
}

export fn bw_wallet_lock(ctx: ?*Ctx, idx: usize) c_int {
    const c = ctx orelse return -1;
    walletAction(c, idx, true, "", false) catch |err| {
        c.setError(@errorName(err));
        return -1;
    };
    return 0;
}

/// Unlock with `passphrase` (a secret). We copy it into a bounded stack buffer,
/// use it, and wipe that copy before returning — the caller wipes its own copy.
export fn bw_wallet_unlock(ctx: ?*Ctx, idx: usize, pass_ptr: ?[*]const u8, pass_len: usize, staking: c_int) c_int {
    const c = ctx orelse return -1;
    const p = pass_ptr orelse return -1;

    var buf: [512]u8 = undefined;
    const n = @min(pass_len, buf.len);
    @memcpy(buf[0..n], p[0..n]);
    defer @memset(buf[0..n], 0); // wipe our copy on every path

    walletAction(c, idx, false, buf[0..n], staking != 0) catch |err| {
        c.setError(@errorName(err));
        return -1;
    };
    return 0;
}

// ---- wallet security (for the lock/unlock status glyph) ---------------------

/// The wallet's lock state, as the ordinal of `models.WalletSecurity`:
/// 0 unknown, 1 unencrypted, 2 locked, 3 unlocked, 4 unlocked-for-staking.
/// Returns 0 (unknown) on any failure — e.g. the daemon isn't running yet, or
/// the coin exposes no wallet security state — so the glyph greys out until the
/// daemon has loaded and answered.
fn walletSecurity(ctx: *Ctx, idx: usize) !models.WalletSecurity {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const coin = coinByIndex(idx) orelse return error.NoSuchCoin;
    const data_dir = try coin.dataDir(a, ctx.home_dir);
    const auth = try conf.readAuth(a, io, data_dir, coin.confFile(), coin.rpcDefaultUsername(), coin.rpcDefaultPort());
    return coin.walletSecurityState(a, auth);
}

export fn bw_wallet_security(ctx: ?*Ctx, idx: usize) c_int {
    const c = ctx orelse return 0;
    const sec = walletSecurity(c, idx) catch return 0;
    return @intCast(@intFromEnum(sec));
}

// ---- disk usage (for the coin's "disk used" gauge) --------------------------

/// Bytes used / total on the filesystem holding the coin's data dir.
pub const BwDiskUsage = extern struct {
    used_bytes: u64,
    total_bytes: u64,
};

// Linux `struct statfs` (x86-64). std doesn't expose one, so we make the raw
// syscall; the GUI is Linux-only, and this is guarded to that target.
const LinuxStatfs = extern struct {
    f_type: i64,
    f_bsize: i64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_namelen: i64,
    f_frsize: i64,
    f_flags: i64,
    f_spare: [4]i64,
};

fn statfsAt(path_z: [:0]const u8, out: *BwDiskUsage) bool {
    if (builtin.os.tag != .linux) return false;
    var st: LinuxStatfs = undefined;
    const rc = std.os.linux.syscall2(.statfs, @intFromPtr(path_z.ptr), @intFromPtr(&st));
    if (@as(isize, @bitCast(rc)) < 0) return false;
    if (st.f_blocks == 0 or st.f_bsize <= 0) return false;
    const bsize: u64 = @intCast(st.f_bsize);
    out.total_bytes = st.f_blocks * bsize;
    out.used_bytes = (st.f_blocks - st.f_bfree) * bsize;
    return true;
}

fn diskUsage(ctx: *Ctx, idx: usize, out: *BwDiskUsage) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Prefer the coin's data dir; if it doesn't exist yet, the home dir sits on
    // the same filesystem the chain would grow into, so it's the right gauge.
    const coin = coinByIndex(idx) orelse return error.NoSuchCoin;
    const data_dir = coin.dataDir(a, ctx.home_dir) catch ctx.home_dir;
    const data_z = try a.dupeZ(u8, data_dir);
    if (statfsAt(data_z, out)) return;

    const home_z = try a.dupeZ(u8, ctx.home_dir);
    if (statfsAt(home_z, out)) return;
    return error.StatfsFailed;
}

export fn bw_disk_usage(ctx: ?*Ctx, idx: usize, out: ?*BwDiskUsage) c_int {
    const c = ctx orelse return -1;
    const o = out orelse return -1;
    diskUsage(c, idx, o) catch return -1;
    return 0;
}

// ---- file browsing (for the GUI's file-picker, backed by the core) ----------
//
// A native OS file dialog isn't portable without a heavy dependency, so the GUI
// browses the filesystem in-app and lists directories through here — the same
// std.fs the rest of the core uses, so it works identically on all three OSes.

/// The process home directory (a good starting point for the browser).
export fn bw_home_dir(ctx: ?*Ctx, buf: ?[*]u8, cap: usize) usize {
    const c = ctx orelse return 0;
    const b = buf orelse return 0;
    return copyOut(b[0..cap], c.home_dir);
}

fn lessName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Append a `"<t> name\n"` line to `out` at `at` if it fits; returns the new
/// length, or `at` unchanged when there's no room (the caller then stops).
fn writeEntryLine(out: []u8, at: usize, t: u8, name: []const u8) usize {
    const need = 2 + name.len + 1; // "<t> " + name + "\n"
    if (at + need > out.len) return at;
    out[at] = t;
    out[at + 1] = ' ';
    @memcpy(out[at + 2 .. at + 2 + name.len], name);
    out[at + 2 + name.len] = '\n';
    return at + need;
}

/// List `dir_path` into `out` as newline-separated `"<t> name"` lines, `t` being
/// `d` for a directory or `f` otherwise, directories first and each group sorted.
/// Returns the number of bytes written (0 on any error — the caller keeps its
/// current listing). Truncates cleanly at a line boundary if `out` fills.
fn listDir(dir_path: []const u8, out: []u8) usize {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var dirs: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.name.len == 0) continue;
        const name = a.dupe(u8, entry.name) catch continue;
        if (entry.kind == .directory) {
            dirs.append(a, name) catch continue;
        } else {
            files.append(a, name) catch continue;
        }
    }
    std.mem.sort([]const u8, dirs.items, {}, lessName);
    std.mem.sort([]const u8, files.items, {}, lessName);

    var w: usize = 0;
    for (dirs.items) |name| {
        const nw = writeEntryLine(out, w, 'd', name);
        if (nw == w) return w;
        w = nw;
    }
    for (files.items) |name| {
        const nw = writeEntryLine(out, w, 'f', name);
        if (nw == w) return w;
        w = nw;
    }
    return w;
}

export fn bw_list_dir(path: ?[*:0]const u8, buf: ?[*]u8, cap: usize) usize {
    const p = path orelse return 0;
    const b = buf orelse return 0;
    return listDir(std.mem.span(p), b[0..cap]);
}

// ---- offline tests (no daemon, no network, no libc) -------------------------

test "coin registry exposes all coins and rejects out-of-range" {
    try std.testing.expectEqual(@as(usize, 14), coinCount());
    try std.testing.expect(coinByIndex(0) != null);
    try std.testing.expect(coinByIndex(13) != null);
    try std.testing.expect(coinByIndex(14) == null);

    // Every registered index yields a coin with a non-empty name/abbrev, and
    // Divi is present somewhere in the registry.
    var found_divi = false;
    var i: usize = 0;
    while (i < coinCount()) : (i += 1) {
        const c = coinByIndex(i) orelse return error.Unexpected;
        try std.testing.expect(c.coinName().len > 0);
        try std.testing.expect(c.coinNameAbbrev().len > 0);
        if (std.mem.eql(u8, c.coinName(), "Divi")) found_divi = true;
    }
    try std.testing.expect(found_divi);
}

test "bw_coin_name copies into a caller buffer and reports its length" {
    var buf: [16]u8 = undefined;
    const n = bw_coin_name(1, &buf, buf.len);
    try std.testing.expectEqualStrings("Divi", buf[0..n]);
    // Out-of-range index writes nothing.
    try std.testing.expectEqual(@as(usize, 0), bw_coin_name(99, &buf, buf.len));
}

test "setField truncates and NUL-terminates" {
    var field: [4]u8 = undefined;
    setField(field[0..], "abcdefg");
    try std.testing.expectEqualStrings("abc", field[0..3]);
    try std.testing.expectEqual(@as(u8, 0), field[3]);
}

test "copyOut respects the destination bound" {
    var small: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), copyOut(small[0..], "hello"));
    try std.testing.expectEqualStrings("he", small[0..2]);
}

test "statfsAt reports a non-empty filesystem for the root path" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var out: BwDiskUsage = undefined;
    try std.testing.expect(statfsAt("/", &out));
    try std.testing.expect(out.total_bytes > 0);
    try std.testing.expect(out.used_bytes <= out.total_bytes);
}

test "writeEntryLine formats a typed line and stops when it can't fit" {
    var buf: [16]u8 = undefined;
    const w = writeEntryLine(buf[0..], 0, 'd', "abc");
    try std.testing.expectEqualStrings("d abc\n", buf[0..w]);
    // Only 2 bytes free after `w`: a longer line doesn't fit, so `at` is returned.
    try std.testing.expectEqual(w, writeEntryLine(buf[0 .. w + 2], w, 'f', "toolong"));
}
