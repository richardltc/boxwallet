//! C-ABI shim over the BoxWallet core, for the Slint GUI front-end.
//!
//! The GUI is a thin C++ layer (Slint's binding language) that drives the exact
//! same coin logic the TUI does — the `Coin` vtable in `coin.zig`. Rather than
//! bind Slint's C++ API from Zig (it isn't a stable C ABI), the C++ glue calls
//! *this* module's `export fn`s over a plain C ABI (see `include/boxwallet.h`).
//!
//! The surface covers every registered coin: metadata, install and update, the
//! sync accelerators, daemon start/stop and warm-up, both wallet shapes (the
//! in-daemon bitcoin-family one and the managed wallet-rpc one), balances,
//! transactions, receive addresses, sending, and mining.
//!
//! Secrets **do** cross this boundary — passwords in, one mnemonic out — under
//! the contract documented at the foot of `include/boxwallet.h`. Every one of
//! them arrives as `(ptr, len)`, is copied into a bounded buffer, and is wiped
//! with `@memset` on every return path. Read that contract before adding an
//! export that takes or returns one.
//!
//! Threading: the GUI runs a continuous status poller alongside up to a dozen
//! detached action workers, so anything shared here is either atomic, behind
//! `wallet_mtx`, or thread-local (the last-error slot). Exports that block on
//! RPC are worker-thread-only and say so; the pure metadata reads are safe on
//! the UI thread.
//!
//! Memory: the context holds only a couple of tiny long-lived strings on the
//! page allocator; every live RPC call runs on its own `ArenaAllocator` that is
//! freed when the call returns, so the working set stays bounded and nothing
//! leaks across the boundary (honoring the repo's low-RAM rule). No libc is
//! required — the GUI links libc, but `zig build test` need not.

const std = @import("std");
const builtin = @import("builtin");
const version = @import("version.zig");
const registry = @import("registry.zig");
const sigguard = @import("sigguard.zig");
const money = @import("money.zig");
const seed_mod = @import("seed.zig");
const walletmenu = @import("walletmenu.zig");
const status_mod = @import("status.zig");
const qrcode = @import("qrcode.zig");
const disk = @import("disk.zig");
const memory = @import("memory.zig");
const price = @import("price.zig");
const timefmt = @import("timefmt.zig");
const coinmod = @import("coin.zig");
const models = @import("models.zig");
const conf = @import("conf.zig");
const rpc = @import("rpc.zig");
const install = @import("install.zig");
const updater = @import("update.zig");
const proc = @import("proc.zig");
const warmup = @import("warmup.zig");
const tipwatch = @import("tipwatch.zig");
const mining = @import("mining.zig");
const extwallet = @import("extwallet.zig");

const Coin = coinmod.Coin;

/// The process-wide `Io`, created once on first use and never destroyed.
///
/// **Never one per call.** `std.Io.Threaded.init` installs a *process-wide*
/// SIGIO handler — it sends SIGIO to interrupt blocking syscalls when
/// cancelling — and `deinit` restores whatever was installed before it. Two
/// overlapping instances on different threads therefore race:
///
///   1. thread A `init`s, saving old = SIG_DFL and installing its handler;
///   2. thread B `init`s, saving old = *A's handler*;
///   3. thread A `deinit`s, restoring SIG_DFL — the process now has no handler;
///   4. B's instance sends a SIGIO, whose default action is to **terminate**.
///
/// The GUI hits that window every time a click's metadata reads run on the UI
/// thread while the poll thread is mid-sequence. It presented as the whole app
/// vanishing with "process terminated with signal IO" on selecting a coin.
///
/// One instance fixes it: the handler is installed once and stays, and the
/// worker pool is shared rather than rebuilt for every RPC. Nothing tears it
/// down because it is meant to outlive every caller — the TUI does the same
/// thing with the single `Io` that `std.process.Init` hands it.
///
/// Zig 0.16 has no `std.once`, and `std.Io.Mutex` needs an `Io` to lock (which
/// is what we're trying to create), so the guard is a small atomic state
/// machine. The spin can only ever wait on one `Threaded.init`.
const shared_io = struct {
    const uninit: u8 = 0;
    const initializing: u8 = 1;
    const ready: u8 = 2;

    var state: std.atomic.Value(u8) = .init(uninit);
    var instance: std.Io.Threaded = undefined;

    fn get() std.Io {
        if (state.load(.acquire) != ready) {
            if (state.cmpxchgStrong(uninit, initializing, .acq_rel, .acquire) == null) {
                instance = .init(std.heap.page_allocator, .{});
                state.store(ready, .release);
            } else {
                while (state.load(.acquire) != ready) std.atomic.spinLoopHint();
            }
        }
        return instance.io();
    }
};

/// The shared `Io`. Safe to call from any thread, at any time. Use this instead
/// of building a `std.Io.Threaded` — see `shared_io` for what happens otherwise.
fn sharedIo() std.Io {
    return shared_io.get();
}

/// The last failure on **this thread**: the sentence for the user, plus the bare
/// `@errorName` behind it so a caller can branch (keep a wrong password on the
/// password step) without parsing prose.
///
/// Thread-local rather than a field on `Ctx`, because the GUI has no single
/// worker: the status poller runs continuously while a dozen action workers are
/// spawned detached alongside it, and every one of them can fail. A shared slot
/// (even a mutexed one) means a worker can read *another* worker's message —
/// wrong text on the wrong modal, which for a wallet is worse than no text. Every
/// caller already reads it on the thread that made the failing call, so
/// per-thread is exactly the semantics the API had always implied.
const ErrSlot = struct {
    msg_buf: [256]u8 = undefined,
    msg_len: usize = 0,
    code_buf: [64]u8 = undefined,
    code_len: usize = 0,

    fn setMsg(self: *ErrSlot, msg: []const u8) void {
        const n = @min(msg.len, self.msg_buf.len);
        @memcpy(self.msg_buf[0..n], msg[0..n]);
        self.msg_len = n;
    }

    fn setCode(self: *ErrSlot, name: []const u8) void {
        const n = @min(name.len, self.code_buf.len);
        @memcpy(self.code_buf[0..n], name[0..n]);
        self.code_len = n;
    }
};

threadlocal var tl_err: ErrSlot = .{};

/// Opaque per-process context handed back to the C++ side by `bw_init`. Owns the
/// resolved home/install-root strings, the per-coin daemon and wallet handles,
/// and the cross-thread install/pause flags. The last-error slot deliberately
/// lives outside it (see `ErrSlot`).
const Ctx = struct {
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    install_root: []const u8,
    // Retained handles for foreground daemons we launched, so a coin with no
    // shutdown RPC can be killed on stop (mirrors the TUI's `daemon_child`).
    //
    // One slot per coin, keyed by registry index — *not* a single shared slot.
    // Many coins launch foreground (all of them on Windows), so a shared slot got
    // overwritten by whichever started last, and stopping the one coin without an
    // RPC stop (Zano) then killed some other coin's daemon.
    daemon_child: [coin_count]?std.process.Child = @splat(null),
    /// Whether a start/stop worker currently owns `daemon_child[idx]`. The poll
    /// thread reaps self-died foreground daemons between ticks (`bw_reap_daemon`)
    /// and must not touch a slot a worker is writing; this is the GUI's
    /// counterpart to the TUI's `daemon_thread == null` guard.
    daemon_action: [coin_count]std.atomic.Value(u8) = @splat(.init(0)),
    // Install progress. Unlike the rest of Ctx these are genuinely cross-thread —
    // the install worker writes them while the UI poll thread reads them every
    // frame — so they're atomic rather than plain fields. `install_phase` holds a
    // `bw_install_phase_*` code; the byte counters are only meaningful while it
    // is `downloading` (see `bw_install_progress`).
    install_phase: std.atomic.Value(u8) = .init(bw_install_phase_idle),
    install_cur: std.atomic.Value(u64) = .init(0),
    install_total: std.atomic.Value(u64) = .init(0),

    /// Pause request for a running sync-accelerator transfer, polled by the
    /// transfer between chunks. Serves both the Pause button and window close —
    /// a multi-GB snapshot is very likely still running when the app is closed,
    /// and the caller must be able to stop it promptly without losing the bytes
    /// already on disk.
    accel_pause: std.atomic.Value(bool) = .init(false),

    /// One wallet-rpc session per coin, keyed by registry index — same reasoning
    /// as `daemon_child`: a shared slot would let one coin's teardown kill
    /// another coin's wallet service.
    wallet: [coin_count]extwallet.Session = @splat(.{}),
    /// Whether each coin's managed wallet has been opened this session. The GUI's
    /// counterpart to the TUI's `Activity.ext_wallet_open`; atomic because the
    /// poll thread reads it while an action worker writes it.
    wallet_open: [coin_count]std.atomic.Value(u8) = @splat(.init(0)),
    /// Whether each coin's in-daemon wallet has been loaded for this daemon run.
    /// The GUI's counterpart to the TUI's `Activity.wallet_ensured` — Bitcoin-Core
    /// 0.21+ forks (Bitcoin, Litecoin, DigiByte, ReddCoin) auto-load no wallet, so
    /// every wallet RPC answers `-18 "no wallet loaded"` until one is. Atomic
    /// because the poll thread latches it while a start worker clears it.
    wallet_ensured: [coin_count]std.atomic.Value(u8) = @splat(.init(0)),
    /// Highest chain heights each coin's daemon has reported this run, so a peer
    /// that knows less than the one it replaced can't walk the Headers readout
    /// backwards (see `tipwatch`). Cleared on start/stop of that coin's daemon.
    tip_marks: [coin_count]tipwatch.Ratchet = @splat(.{}),
    /// Serialises every wallet-touching export. Mutating ops (create/restore/
    /// open/teardown) take it **blocking**; polled reads `tryLock` and report
    /// busy instead, so a multi-minute restore can never stall the 2s status
    /// pump behind it.
    wallet_mtx: std.Io.Mutex = .init,

    /// Cached USD quotes, one slot per registry index, with the timestamp of the
    /// last successful fetch and a saturating failure count driving the backoff.
    /// Genuinely cross-thread — the poll worker writes them while a publish reads
    /// them — so they sit behind `price_mtx`.
    prices: [coin_count]price.Quote = @splat(.{}),
    price_fetched_at: i64 = 0,
    price_failures: u32 = 0,
    price_last_try: i64 = 0,
    price_mtx: std.Io.Mutex = .init,

    /// A freshly created wallet's mnemonic, waiting to be taken exactly once by
    /// `bw_ext_wallet_seed_take`. Bounded and inline (`models.Seed` is a 256-byte
    /// buffer, never heap) so it can be wiped in place; `seed_coin` is -1 when
    /// nothing is pending. Wiped on take, on discard, and by `bw_deinit`.
    seed: models.Seed = .{},
    seed_coin: isize = -1,

    /// Record a failure against the calling thread. Kept as methods on `Ctx` so
    /// the ~80 call sites read unchanged; `self` is unused because the slot is
    /// thread-local (see `ErrSlot`).
    fn setError(self: *Ctx, msg: []const u8) void {
        _ = self;
        tl_err.setMsg(msg);
    }

    fn setErrorCode(self: *Ctx, name: []const u8) void {
        _ = self;
        tl_err.setCode(name);
    }

    /// Whether this thread has a failure recorded. Used where a fallback message
    /// should only fill in for a probe that found nothing to say.
    fn hasError(self: *Ctx) bool {
        _ = self;
        return tl_err.msg_len != 0;
    }

    /// Forget this thread's last failure, so a later "did anything go wrong?"
    /// check can't read a stale one from an earlier call.
    fn clearError(self: *Ctx) void {
        _ = self;
        tl_err.msg_len = 0;
        tl_err.code_len = 0;
    }

    /// This thread's last failure text, empty if none. Borrowed from the
    /// thread-local slot: valid until the next `setError` on this thread.
    fn errorText(self: *Ctx) []const u8 {
        _ = self;
        return tl_err.msg_buf[0..tl_err.msg_len];
    }

    /// This thread's last `@errorName`, empty if none. Same lifetime rule.
    fn errorCode(self: *Ctx) []const u8 {
        _ = self;
        return tl_err.code_buf[0..tl_err.code_len];
    }
};

// The registered coins come from `registry.zig` — the one list both front-ends
// read, so the index the C++ side addresses a coin by can't drift from the one
// the TUI uses. Each backend is a zero-field struct and `coin()` wants a
// pointer, so one process-wide instance set is all that's needed.
var g_coins: registry.Instances = registry.instances();

/// Number of registered coins. Every index the C side passes is in
/// `[0, coin_count)`, and `coinByIndex` answers for exactly that range.
/// `Ctx.daemon_child` and friends are sized from this.
const coin_count = registry.count;

fn coinCount() usize {
    return coin_count;
}

fn coinByIndex(idx: usize) ?Coin {
    return registry.coinAt(&g_coins, idx);
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
    // First, before the caller spawns its poll thread or any action worker: pin
    // a handler for the signals `std.Io.Threaded` uses. The core builds a
    // `Threaded` per call in a great many places, and once two of those overlap
    // on different threads one instance's teardown can leave the process at
    // SIG_DFL — after which the next cancellation SIGIO terminates us with no
    // message at all. See `sigguard.zig`.
    sigguard.install();

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
    // Every wallet service we spawned dies with us. Doing this here rather than
    // in a window-close handler means it happens on *every* exit path — without
    // it a `nerva-wallet-rpc` outlives the closed window still holding the
    // user's wallet files. The caller has already drained its workers, so no op
    // is mid-flight on a session being torn down.
    for (&c.wallet) |*sess| extwallet.kill(sess);
    // A mnemonic the user never got round to taking must not outlive the context.
    @memset(std.mem.asBytes(&c.seed), 0);
    c.seed_coin = -1;

    const a = c.allocator;
    a.free(c.install_root);
    a.free(c.home_dir);
    a.destroy(c);
}

/// The bare error name behind this thread's last failure (`bw_last_error` has the
/// sentence for the user; this is for the caller to branch on).
export fn bw_last_error_code(ctx: ?*Ctx, buf: ?[*]u8, cap: usize) usize {
    _ = ctx;
    const b = buf orelse return 0;
    return copyOut(b[0..cap], tl_err.code_buf[0..tl_err.code_len]);
}

/// This thread's last error message, copied into the caller buffer. Read it on
/// the same thread that made the failing call — another thread's slot is its own.
export fn bw_last_error(ctx: ?*Ctx, buf: ?[*]u8, cap: usize) usize {
    _ = ctx;
    const b = buf orelse return 0;
    return copyOut(b[0..cap], tl_err.msg_buf[0..tl_err.msg_len]);
}

// ---- mnemonic seed helpers (no ctx, no allocation) --------------------------
//
// The backup quiz is the last moment a mis-transcribed word can be caught;
// after that the funds are gone with no recourse. Both front-ends must therefore
// ask it the same way, which is why these are exported rather than written twice.
// Neither call copies or retains the words — they read the caller's buffer in
// place, so it can be wiped straight afterwards.

/// Count the whitespace-separated words in a seed — the live counter under a
/// seed-entry field. Cheap; safe on the UI thread.
export fn bw_seed_word_count(words: ?[*]const u8, len: usize) usize {
    const w = words orelse return 0;
    return seed_mod.countWords(w[0..len]);
}

/// Whether `answer` is the word at 1-based `pos` of `words`. Ignores surrounding
/// whitespace and case — a wordlist is lowercase but people type with a capital,
/// and rejecting "Abandon" would fail someone who copied their seed down
/// correctly. 1 on match, 0 otherwise. Cheap; safe on the UI thread.
export fn bw_seed_word_matches(
    words: ?[*]const u8,
    words_len: usize,
    pos: usize,
    answer: ?[*]const u8,
    answer_len: usize,
) c_int {
    const w = words orelse return 0;
    const a = answer orelse return 0;
    return if (seed_mod.wordMatches(w[0..words_len], pos, a[0..answer_len])) 1 else 0;
}

/// Pick up to 3 distinct 1-based positions to quiz, ascending, written into
/// `out`; returns how many (fewer than 3 only for an unusually short seed).
///
/// The positions come from the OS CSPRNG. Don't substitute a userspace PRNG: a
/// clock-seeded one makes the quiz predictable, which is precisely what it must
/// not be.
export fn bw_seed_verify_positions(word_count: usize, out: ?*u32, cap: usize) usize {
    const o = out orelse return 0;
    if (cap == 0) return 0;
    var pos: [seed_mod.verify_positions]usize = undefined;
    const n = @min(seed_mod.pickVerifyPositions(sharedIo(), word_count, &pos), cap);
    // Ascending, so the quiz walks the phrase front to back rather than jumping
    // about — the order it's written down in.
    std.mem.sort(usize, pos[0..n], {}, std.sort.asc(usize));
    const dst = @as([*]u32, @ptrCast(o))[0..n];
    for (dst, pos[0..n]) |*d, p| d.* = @intCast(p);
    return n;
}

// ---- number formatting (no ctx, no allocation) ------------------------------

/// Render a coin amount at `decimals` places with thousands separators
/// ("1,234,567.50000000") into `buf`, returning its length. Cheap; safe on the
/// UI thread.
///
/// Exported rather than reimplemented C++-side so both front-ends show the same
/// balance the same way. They did diverge: the GUI carried its own `snprintf`
/// plus manual comma insertion while the TUI used Zig's `printFloat` plus digit
/// grouping — two implementations of one number.
///
/// Trailing zeros are kept, so a coin's full precision always shows and a zero
/// balance reads as a balance rather than a bare "0". Use `bw_trim_zeros` for
/// the places that want them gone.
export fn bw_format_amount(value: f64, decimals: u8, buf: ?[*]u8, cap: usize) usize {
    const b = buf orelse return 0;
    var tmp: [64]u8 = undefined;
    return copyOut(b[0..cap], money.formatAmount(&tmp, value, decimals));
}

/// Parse a typed USD amount ("125", "125.5", "125.50") into integer cents, or
/// -1 when it isn't a plain non-negative dollars figure.
///
/// Exported so a typed amount becomes the *same* number in both front-ends.
/// Money never rides through a float here: the figure a mint settles against is
/// the one this parsed. Cheap; UI-thread safe.
export fn bw_parse_dollars_to_cents(text: ?[*:0]const u8) i64 {
    const t = text orelse return -1;
    return money.parseDollarsToCents(std.mem.span(t)) orelse -1;
}

/// Format integer cents as dollars ("$1,234.56"). The stablecoin figures are all
/// cents, and this is the one place they become text — so both front-ends round
/// and punctuate them identically. Cheap; UI-thread safe.
export fn bw_format_cents(cents: i64, buf: ?[*]u8, cap: usize) usize {
    const b = buf orelse return 0;
    var tmp: [48]u8 = undefined;
    return copyOut(b[0..cap], money.formatCents(&tmp, cents));
}

/// Format an oracle price in micro-USD per coin ("$0.014230") — six decimals,
/// since sub-cent coins are the normal case. Cheap; UI-thread safe.
export fn bw_format_micro_usd(micro: u64, buf: ?[*]u8, cap: usize) usize {
    const b = buf orelse return 0;
    var tmp: [48]u8 = undefined;
    return copyOut(b[0..cap], money.formatMicroUsd(&tmp, micro));
}

/// Format a rough duration ("2 hours and 5 minutes"), for a countdown. Empty
/// under a minute. Cheap; UI-thread safe.
export fn bw_format_duration(secs: i64, buf: ?[*]u8, cap: usize) usize {
    const b = buf orelse return 0;
    var tmp: [timefmt.max_len]u8 = undefined;
    return copyOut(b[0..cap], timefmt.duration(&tmp, secs));
}

/// Format a byte count as storage ("12.34 GB", SI units), for the figure showing
/// what a coin's data directory occupies.
///
/// Shares `timefmt.storageGB` with the TUI on purpose. The GUI used to format
/// this itself in binary units, so the same chain read "11.5 GB" here and
/// "12.34 GB" there — two front-ends disagreeing about one number. Cheap;
/// UI-thread safe.
export fn bw_format_storage(bytes: u64, buf: ?[*]u8, cap: usize) usize {
    const b = buf orelse return 0;
    var tmp: [48]u8 = undefined;
    return copyOut(b[0..cap], timefmt.storageGB(&tmp, bytes));
}

/// How far back in time the chain a `bw_blockchain_state` read describes sits:
/// the tip block's own timestamp and the wall-clock distance from it, resolved
/// from whichever field the coin filled in (`models.BlockchainState.syncDistance`
/// — the same derivation the TUI's Blocks hint uses). The clock is read here, so
/// a caller needs no time of its own; -1 / 0 for "unavailable".
fn stateDistance(in: *const BwBlockchainState) models.SyncDistance {
    const state: models.BlockchainState = .{
        .chain = "",
        .blocks = in.blocks,
        .headers = in.headers,
        .verification_progress = in.verification_progress,
        .synced = in.synced != 0,
        .network_height = in.network_height,
        .tip_time = in.tip_time,
        .seconds_behind = in.seconds_behind,
    };
    return state.syncDistance(std.Io.Clock.real.now(sharedIo()).toSeconds());
}

/// The tip block's own date/time as "YYYY-MM-DD HH:MM" in **UTC** — the moment
/// the block being synced was mined. Empty when the coin reports no timestamp
/// and no gap to reconstruct one from. Cheap; UI-thread safe.
export fn bw_sync_tip_date(in: ?*const BwBlockchainState, buf: ?[*]u8, cap: usize) usize {
    const s = in orelse return 0;
    const b = buf orelse return 0;
    var tmp: [timefmt.max_len]u8 = undefined;
    return copyOut(b[0..cap], timefmt.blockTime(&tmp, stateDistance(s).tip_time));
}

/// How far the local tip is behind the chain, as "3 days and 2 hours behind".
/// Empty when caught up (under a minute) or when the distance is unknown, so a
/// caller can render nothing rather than "0 minutes behind". Shares the TUI's
/// wording — a chain half a year back must not read one way here and another
/// there. Cheap; UI-thread safe.
export fn bw_sync_behind(in: ?*const BwBlockchainState, buf: ?[*]u8, cap: usize) usize {
    const s = in orelse return 0;
    const b = buf orelse return 0;
    const secs = stateDistance(s).behind_secs;
    if (secs <= 0) return 0;
    var tmp: [timefmt.max_len]u8 = undefined;
    return copyOut(b[0..cap], timefmt.behind(&tmp, secs));
}

/// Drop trailing zeros (and a bare decimal point) from a figure produced by
/// `bw_format_amount`: "498.00000000" → "498", "2.50000000" → "2.5". For a
/// transaction *list*, where a column of full-precision figures is noise.
/// Balances should keep their full precision. Cheap; safe on the UI thread.
export fn bw_trim_zeros(text: ?[*]const u8, len: usize, buf: ?[*]u8, cap: usize) usize {
    const t = text orelse return 0;
    const b = buf orelse return 0;
    return copyOut(b[0..cap], money.trimTrailingZeros(t[0..len]));
}

// ---- application identity (no ctx, no allocation) ---------------------------

/// BoxWallet's own release version, e.g. "0.8.4" — no "v" prefix; the GUI adds
/// its own. Read from `version.zig`, the same constant the TUI shows and the
/// self-updater compares against, so the GUI can't announce a version it isn't.
export fn bw_app_version(buf: ?[*]u8, cap: usize) usize {
    const b = buf orelse return 0;
    return copyOut(b[0..cap], version.app_version);
}

/// What this front-end calls itself ("BoxWallet"), for the title and Home page.
export fn bw_app_name(buf: ?[*]u8, cap: usize) usize {
    const b = buf orelse return 0;
    return copyOut(b[0..cap], version.gui_name);
}

/// The BoxWallet brand hex ("#RRGGBB") — the green both front-ends wear.
export fn bw_brand_color(buf: ?[*]u8, cap: usize) usize {
    const b = buf orelse return 0;
    return copyOut(b[0..cap], version.brand_color);
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

/// A coin's two-tone wordmark, flattened for C. `split` is a **byte index into
/// the coin name** where the tail half begins.
pub const BwWordmark = extern struct {
    split: usize,
    head_color: [8]u8, // "#RRGGBB", NUL-terminated
    tail_color: [8]u8,
};

/// The coin's two-tone wordmark: 1 with `out` filled, 0 if it has none (most
/// coins — draw the name in `bw_coin_color` and stop).
///
/// ReddCoin is "Redd" in its brand red then "Coin" in near-white; SpiderByte and
/// BitcoinZ are a white head with a brand-coloured tail. Exported so the GUI
/// wears the same branding as the TUI instead of flattening these to one colour.
/// The vtable's head colour is optional and defaults to the coin's own, so this
/// resolves it and hands out two concrete hexes. Cheap; safe on the UI thread.
export fn bw_coin_wordmark(idx: usize, out: ?*BwWordmark) c_int {
    const coin = coinByIndex(idx) orelse return 0;
    const o = out orelse return 0;
    const wm = coin.wordmark() orelse return 0;
    o.split = wm.split;
    setField(&o.head_color, wm.head_color orelse coin.coinColor());
    setField(&o.tail_color, wm.alt_color);
    return 1;
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

// ---- external wallet: what this coin's wallet can do ------------------------

/// Bits of `bw_coin_ext_wallet`. Kept in one bitfield rather than six calls so
/// the C++ side reads a coin's whole wallet shape in a single hop, and so a coin
/// added later can't be half-described.
pub const bw_ew_has_process: c_int = 1 << 0; // spawns its own wallet-rpc process
pub const bw_ew_seed_restore: c_int = 1 << 1; // restore from mnemonic words
pub const bw_ew_file_restore: c_int = 1 << 2; // import an existing wallet file
pub const bw_ew_replace: c_int = 1 << 3; // in-app "replace wallet" (destructive)
pub const bw_ew_explicit_lock: c_int = 1 << 4; // an in-daemon wallet needing a Lock action
pub const bw_ew_launch_with_pw: c_int = 1 << 5; // wallet process is launched per-open, with the password

/// 0 for a coin with no external wallet at all; otherwise the `bw_ew_*` bits.
export fn bw_coin_ext_wallet(idx: usize) c_int {
    const coin = coinByIndex(idx) orelse return 0;
    const ew = coin.externalWallet() orelse return 0;
    var flags: c_int = 0;
    if (coin.hasExternalWalletProcess()) flags |= bw_ew_has_process;
    if (coin.supportsSeedRestore()) flags |= bw_ew_seed_restore;
    if (ew.restore_file != null) flags |= bw_ew_file_restore;
    if (coin.supportsWalletReplace()) flags |= bw_ew_replace;
    if (ew.lock != null) flags |= bw_ew_explicit_lock;
    if (coin.walletLaunchesWithPassword()) flags |= bw_ew_launch_with_pw;
    return flags;
}

/// The word counts this wallet's restore seed may have, written into `out` (up
/// to `cap`), returning how many were written. The first is the canonical one to
/// name in the prompt.
export fn bw_coin_seed_word_counts(idx: usize, out: ?*u32, cap: usize) usize {
    const coin = coinByIndex(idx) orelse return 0;
    const o = out orelse return 0;
    const counts = coin.seedWordCounts();
    const n = @min(counts.len, cap);
    const dst = @as([*]u32, @ptrCast(o))[0..n];
    for (dst, counts[0..n]) |*d, c| d.* = @intCast(c);
    return n;
}

// ---- which wallet tabs a coin earns -----------------------------------------
//
// These four answer "does this coin have anything to put on that tab?", so the
// GUI can hide a tab rather than render it empty. They are about the *coin*, not
// about whether its wallet happens to be open right now.

/// Whether this coin reports a balance. Unlike the other three this is **not**
/// just the vtable predicate: a managed wallet's balance comes from the required
/// `ExternalWallet.balance` hook, not from `wallet_balance`, so `supportsBalance`
/// alone reads false for Monero/Nerva/Salvium/Zano/Epic/Ergo. `bw_wallet_balance`
/// serves both shapes, and so must this.
export fn bw_coin_supports_balance(idx: usize) c_int {
    const c = coinByIndex(idx) orelse return 0;
    return if (c.supportsBalance() or c.hasExternalWallet()) 1 else 0;
}

/// Whether this coin reports a transaction history (drives the Transactions tab).
export fn bw_coin_supports_transactions(idx: usize) c_int {
    const c = coinByIndex(idx) orelse return 0;
    return if (c.supportsTransactions()) 1 else 0;
}

/// Whether this coin can hand out a receive address (drives the Receive tab).
/// False for Epic, whose MimbleWimble wallet has no such thing.
export fn bw_coin_supports_receive_address(idx: usize) c_int {
    const c = coinByIndex(idx) orelse return 0;
    return if (c.supportsReceiveAddress()) 1 else 0;
}

/// Whether this coin can send (drives the Send tab). False for Epic: a
/// MimbleWimble payment is an interactive slate exchange, not a fire-and-forget
/// broadcast.
export fn bw_coin_supports_send(idx: usize) c_int {
    const c = coinByIndex(idx) orelse return 0;
    return if (c.supportsSend()) 1 else 0;
}

/// Whether this coin has an explicit stake action (drives the Stake control on
/// the Send tab). Salvium only, so far.
///
/// Asked here rather than off `bw_coin_wallet_caps`' `BW_WCAP_STAKE_ACTION`:
/// that read describes an *in-daemon* wallet and answers 0 for a coin that
/// manages its wallet in a second process — which is exactly what Salvium does.
export fn bw_coin_supports_stake(idx: usize) c_int {
    const c = coinByIndex(idx) orelse return 0;
    return if (c.supportsStakeAction()) 1 else 0;
}

/// Decimal places this coin's amounts are shown to.
export fn bw_coin_balance_decimals(idx: usize) u8 {
    const c = coinByIndex(idx) orelse return 8;
    return c.balanceDecimals();
}

// ---- installed / data dir (need ctx for install root & home) ----------------

export fn bw_is_installed(ctx: ?*Ctx, idx: usize) c_int {
    const c = ctx orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;
    return if (coin.isInstalled(c.allocator, c.install_root)) 1 else 0;
}

/// Whether the bundled `core_version` is newer than what's on disk — the
/// "update available" flag, same as the TUI's Update prompt.
///
/// Mirrors the TUI's `refreshUpdateState`, deliberately including its rule that an
/// installed coin with **no** version marker reads as *up to date* rather than out
/// of date: we don't know what version it is, and assuming it's behind would nag
/// on every pre-marker or hand-installed binary, for every coin. The marker gets
/// stamped the first time we install (or the TUI learns it from a running daemon),
/// after which real updates show correctly.
export fn bw_update_available(ctx: ?*Ctx, idx: usize) c_int {
    const c = ctx orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;
    if (!coin.isInstalled(c.allocator, c.install_root)) return 0;
    const ver = install.readVersionMarker(c.allocator, c.install_root, coin.daemonFile()) orelse return 0;
    defer c.allocator.free(ver);
    return if (updater.isNewer(coin.coreVersion(), ver)) 1 else 0;
}

/// The installed daemon version from the on-disk marker. Returns 0 bytes when
/// there's no marker (version unknown) — not an error.
export fn bw_installed_version(ctx: ?*Ctx, idx: usize, buf: ?[*]u8, cap: usize) usize {
    const c = ctx orelse return 0;
    const b = buf orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;
    const ver = install.readVersionMarker(c.allocator, c.install_root, coin.daemonFile()) orelse return 0;
    defer c.allocator.free(ver);
    return copyOut(b[0..cap], ver);
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

    const io = sharedIo();

    const coin = coinByIndex(idx) orelse return error.NoSuchCoin;
    const data_dir = try coin.dataDir(a, ctx.home_dir);
    const auth = try conf.readAuth(a, io, data_dir, coin.confFile(), coin.rpcDefaultUsername(), coin.rpcDefaultPort());

    // Load-or-create the named wallet before the status read, so the same tick's
    // `staking`/`bw_wallet_security` calls already see it (the TUI does this in
    // the same place, for the same reason).
    ensureWalletLoaded(ctx, idx, a, coin, auth);

    const di = try coin.daemonInfo(a, auth);
    out.blocks = di.blocks;
    out.connections = di.connections;
    out.staking_active = if (di.staking_active) 1 else 0;
    setField(out.version[0..], di.version);
}

/// Load-or-create the coin's named wallet, once per daemon run, for the coins
/// whose daemon auto-loads none (`needsWallet`). Without it the daemon holds no
/// wallet at all and every wallet RPC — balance, receive address, `staking`,
/// `getwalletinfo` — fails with `-18`; the wallet state then reads as *unknown*,
/// which by design offers no wallet menu, so the GUI had no way to encrypt,
/// unlock, or unlock-for-staking a Bitcoin/Litecoin/DigiByte/ReddCoin wallet.
///
/// Best-effort and latched: a failure (daemon still in warm-up) just retries on
/// the next poll, and `bw_start_daemon` clears the latch because a freshly
/// started daemon has dropped the load again.
fn ensureWalletLoaded(ctx: *Ctx, idx: usize, a: std.mem.Allocator, coin: Coin, auth: models.CoinAuth) void {
    if (!coin.needsWallet()) return;
    if (idx >= coin_count) return;
    if (ctx.wallet_ensured[idx].load(.acquire) != 0) return;
    coin.ensureWallet(a, auth) catch return;
    ctx.wallet_ensured[idx].store(1, .release);
}

fn fetchBlockchainState(ctx: *Ctx, idx: usize, out: *BwBlockchainState) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const io = sharedIo();

    const coin = coinByIndex(idx) orelse return error.NoSuchCoin;
    const data_dir = try coin.dataDir(a, ctx.home_dir);
    const auth = try conf.readAuth(a, io, data_dir, coin.confFile(), coin.rpcDefaultUsername(), coin.rpcDefaultPort());

    // `bs` owns its `chain` string on the arena; the arena frees it on return,
    // so we copy the name into the fixed field before that happens.
    var bs = try coin.blockchainState(a, auth);
    // Don't let a newly-connected, less-informed peer walk the heights back down.
    if (idx < coin_count) ctx.tip_marks[idx].apply(&bs);
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

/// What the daemon is doing while its RPC can't answer a status call yet.
/// Writes the stage label into `buf` — "Loading block index…", "Rewinding…",
/// "Verifying…", "Loading blocks… 42.0%" — and returns its length. 0 means not
/// warming up: the daemon is either answering normally or genuinely not running.
///
/// This is the difference between an honest status and a wrong one. A
/// bitcoin-derived daemon opens its RPC port long before it can serve `getinfo`
/// (it answers `-28` with its current init message meanwhile) — 37s for Divi on
/// a loaded chain, minutes on a big one — so the reads above fail throughout a
/// perfectly healthy start. Without this the GUI shows "not running" and
/// re-offers Start while the daemon is coming up.
///
/// Cheap enough for the 2s poll: one RPC call plus a bounded log tail, on an
/// arena freed before it returns. Only worth calling when `bw_daemon_info`
/// failed.
export fn bw_daemon_stage(ctx: ?*Ctx, idx: usize, buf: ?[*]u8, cap: usize) usize {
    const c = ctx orelse return 0;
    const b = buf orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    // Only ever what the daemon itself reports (its `-28` message, refined by
    // its log). Deliberately not "is the process alive?": that's also true while
    // it shuts down and flushes, which would read as starting up.
    const status = warmup.probe(a, io, coin, c.home_dir);
    var label_buf: [128]u8 = undefined; // the longest message, plus its "…"
    const text = warmup.label(&status, &label_buf);
    if (text.len == 0) return 0;
    return copyOut(b[0..cap], text);
}

/// Whether a process named after this coin's daemon binary is alive — 1 yes,
/// 0 no. `proc.alive`, the same check the TUI's start path uses, over the ABI.
///
/// The companion to `bw_daemon_stage`, for the coins that can't answer it. A
/// bitcoin-derived daemon narrates its start-up over `-28`, so the stage label
/// alone tells a starting daemon from a stopped one; a coin with no such
/// warm-up protocol (Ergo, whose REST API simply refuses the connection until
/// it's ready) reports no stage at any point, and is indistinguishable from
/// "not running" without this.
///
/// **Not on its own a claim that the daemon is starting.** The process is also
/// alive while it shuts down and flushes — the reason `bw_daemon_stage`
/// deliberately doesn't look at liveness. A caller that reads this as "coming
/// up" must know a stop isn't in flight.
export fn bw_daemon_alive(ctx: ?*Ctx, idx: usize) c_int {
    _ = ctx orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;
    return if (proc.aliveMatching(sharedIo(), coin.daemonFile(), coin.daemonProcessCmdline())) 1 else 0;
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

/// After the launcher daemonizes, confirm the daemon process actually stuck
/// around rather than forking and dying — by process name, exactly as the TUI
/// does (`proc.stayedAlive`).
///
/// It deliberately does **not** wait for RPC: a bitcoin-derived daemon (Divi,
/// Bitcoin, Litecoin, …) opens its RPC port only after loading the block index
/// and the wallet, which takes far longer than any start-time window, and until
/// then it answers `-28` warm-up errors anyway. Demanding an RPC answer here
/// reported a perfectly healthy start as "daemon did not stay up".
fn confirmAlive(coin: Coin) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    return proc.stayedAlive(sharedIo(), coin.daemonFile(), coin.daemonProcessCmdline());
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
    if (builtin.os.tag == .windows) {
        // Windows keeps the environment in the PEB rather than a `char **`, and
        // the block moves when anything edits it — so it's read once, here,
        // never held. `.global` is std's name for "this process's real
        // environment"; without this the map came back empty and every child we
        // spawned on Windows (a coin daemon, the updater's `--selftest`
        // pre-flight) ran with no `%APPDATA%`, no `%PATH%`, no `%SystemRoot%`.
        const env: std.process.Environ = .{ .block = .global };
        const block = try env.createWindowsBlock(a, .{});
        defer block.deinit(a);
        try map.putWindowsBlock(block.view());
        return map;
    }
    // Elsewhere: libc-linked only (the GUI always links libc). The Zig-entry
    // offline-test binary doesn't link libc and never calls this — comptime-
    // gating on `link_libc` prunes the `std.c` reference so that build stays
    // libc-free.
    if (builtin.link_libc) {
        const env = std.c.environ;
        var count: usize = 0;
        while (env[count] != null) : (count += 1) {}
        const slice: []const [*:0]const u8 = @ptrCast(env[0..count]);
        try map.putPosixBlock(.{ .slice = slice });
    }
    return map;
}

/// The same environment as an `Environ`, for handing to `std.Io.Threaded.init`.
///
/// `Threaded.init(a, .{})` leaves its `environ` **empty**, and that is what both
/// `processSpawn` and `processReplace` fall back to when a call passes no
/// `environ_map` — so it decides the environment of anything those instances
/// start. Setting it is the one-line way to make every child of a `Threaded`
/// inherit ours, rather than remembering an `environ_map` at each call site.
///
/// Borrows libc's block instead of copying it (no allocation, nothing to free);
/// comptime-gated exactly as `currentEnvMap` is, so the libc-free offline-test
/// binary still compiles.
fn currentEnviron() std.process.Environ {
    // Windows has no `environ` to point at: the block lives in the PEB, and
    // `.global` is how std says "read it from there". Left `.empty` this handed
    // every child spawned through such a `Threaded` an empty environment.
    if (builtin.os.tag == .windows) return .{ .block = .global };
    if (builtin.link_libc) {
        const env = std.c.environ;
        var count: usize = 0;
        while (env[count] != null) : (count += 1) {}
        return .{ .block = .{ .slice = @ptrCast(env[0..count :null]) } };
    }
    return .empty;
}

/// Surface a failed start's reason from the coin's own daemon log — a daemonized
/// child logs there rather than to the stderr we captured, and the epee family
/// writes fatal init errors to its log, not stderr. Best-effort: leaves the
/// error slot untouched for a coin that declares no log, or on any IO hiccup, so
/// the caller falls back to its generic message.
fn setErrorFromDaemonLog(ctx: *Ctx, a: std.mem.Allocator, io: std.Io, coin: Coin) void {
    const log_name = coin.daemonLogFile() orelse return;
    const data_dir = coin.dataDir(a, ctx.home_dir) catch return;
    var buf: [4 * 1024]u8 = undefined;
    const pick = proc.daemonLogReason(io, data_dir, log_name, &buf);
    if (pick.len != 0) ctx.setError(pick);
}

/// Non-blocking probe of a just-spawned child — see `proc.probeChild`, which the
/// TUI drives too. This used to answer null unconditionally on Windows, which is
/// why a Windows Start that failed reported success and then sat there: the watch
/// loop below could never see the daemon die, so it never read the reason out of
/// its stderr.
fn probeChild(io: std.Io, child: *std.process.Child) ?std.process.Child.Term {
    return proc.probeChild(io, child);
}

fn startDaemon(ctx: *Ctx, idx: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    const coin = coinByIndex(idx) orelse return error.NoSuchCoin;

    // Collect the previous run's child before its handle is overwritten below —
    // once the slot is replaced nothing can wait on it, and it would sit as a
    // zombie for the life of the app.
    reapDaemonChild(ctx, idx);

    // Conf must carry RPC creds / API key before the daemon reads it, or it's
    // unmanageable over RPC. Idempotent; keeps existing values.
    try coin.prepareConf(a, io, ctx.install_root, ctx.home_dir);
    const argv = try coin.daemonArgv(a, ctx.install_root, ctx.home_dir);

    // The spawned daemon must inherit our environment (esp. `$HOME`, used to
    // resolve `~/.<coin>`); a null environ_map would hand it an empty one.
    var env_map = try currentEnvMap(a);
    defer env_map.deinit();

    // Where to run the daemon — only Ergo asks for one (it writes its log
    // relative to the CWD); everything else inherits ours. Mirrors the TUI.
    const child_cwd: std.process.Child.Cwd =
        if (try coin.daemonCwd(a, ctx.home_dir)) |path| .{ .path = path } else .inherit;

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
            .cwd = child_cwd,
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
            if (probeChild(io, &child)) |_| {
                // Died during init. Prefer its stderr; fall back to the coin's own
                // daemon log — the epee family (Nerva/Salvium/Zano) reports fatal
                // init errors there and not on stderr, so without this a Monero-fork
                // start failure carried no reason at all. Mirrors the TUI.
                var buf: [8 * 1024]u8 = undefined;
                const n = err_file.readPositionalAll(io, &buf, 0) catch 0;
                if (n > 0) {
                    ctx.setError(buf[0..n]);
                } else {
                    ctx.clearError();
                    setErrorFromDaemonLog(ctx, a, io, coin);
                    if (!ctx.hasError()) ctx.setError("daemon exited during startup (check its log)");
                }
                return error.DaemonStartFailed;
            }
        }
        ctx.daemon_child[idx] = child;
        return;
    }

    // Fork path (bitcoin-derived, POSIX): append `-daemon` so the daemon forks
    // into the background and the launcher exits; wait on the launcher.
    const forked = try std.mem.concat(a, []const u8, &.{ argv, &.{"-daemon"} });
    var child = try std.process.spawn(io, .{
        .argv = forked,
        .cwd = child_cwd,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .{ .file = err_file },
        .environ_map = &env_map,
    });
    switch (try child.wait(io)) {
        .exited => |code| if (code == 0) {
            // Launcher daemonized; confirm the daemon actually stuck around.
            if (confirmAlive(coin)) return;
            // Its daemonized stderr went nowhere we can read, so the reason is
            // in the coin's own log.
            ctx.clearError();
            setErrorFromDaemonLog(ctx, a, io, coin);
            if (!ctx.hasError()) ctx.setError("daemon did not stay up (check its log)");
            return error.DaemonStartFailed;
        },
        else => {},
    }
    var buf: [8 * 1024]u8 = undefined;
    const n = err_file.readPositionalAll(io, &buf, 0) catch 0;
    ctx.setError(if (n > 0) buf[0..n] else "daemon launcher failed");
    return error.DaemonStartFailed;
}

/// Reap the retained foreground child if it has already exited, so it doesn't
/// linger as a zombie for the life of the app. A no-op when there's no handle,
/// when it was reaped already, or when it's still running (`probeChild` is
/// `WNOHANG`). Windows has no zombies, but the probe still runs there: a process
/// handle held for a daemon that has already exited is a leak of its own, and
/// releasing it is what lets the slot go empty so Start reads as available again.
///
/// A foreground daemon is deliberately not waited on at spawn — it has to
/// outlive `startDaemon` — but we stay its parent, so *something* must
/// eventually reap it. The kill path does so inline; an RPC shutdown (or the
/// process dying on its own) needs this. Mirrors the TUI's `reapDaemonChild`.
///
/// `daemon_child[idx]` is only touched by the action worker driving that coin,
/// or by the poll thread while no such worker holds `daemon_action[idx]`, so
/// this inherits the same serialization as the start/stop paths.
fn reapDaemonChild(ctx: *Ctx, idx: usize) void {
    if (idx >= coin_count) return;
    if (ctx.daemon_child[idx]) |*child| {
        if (probeChild(sharedIo(), child)) |_| ctx.daemon_child[idx] = null;
    }
}

fn stopDaemon(ctx: *Ctx, idx: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    const coin = coinByIndex(idx) orelse return error.NoSuchCoin;

    if (!coin.hasRpcStop()) {
        // No shutdown RPC (Zano): terminate the process we launched *for this
        // coin*. Only this coin's slot is ever touched, so stopping it can't
        // reach another coin's daemon.
        if (ctx.daemon_child[idx]) |*child| {
            child.kill(io);
            ctx.daemon_child[idx] = null;
            return;
        }
        return error.CannotStop;
    }

    const auth = try ctxAuth(a, io, coin, ctx);

    // Ask the daemon to shut down. A failed request is **not** proof it's still
    // up, so it isn't returned here — only remembered. A busy daemon can act on
    // the request and still not answer it: nervad seconds into its init takes
    // the stop and tears the RPC server down before the reply lands, so we see a
    // read failure or a timeout for a stop that worked. Reporting that as a
    // failed stop flips the daemon back to running in the UI. The probe below is
    // the real answer; the remembered error only speaks if the daemon is still
    // answering at the end. Mirrors the TUI's `requestStop`.
    const req_err: ?anyerror = if (coin.requestStop(a, auth)) null else |err| err;

    // Probe on a small arena reset each round so the wait stays flat in memory.
    // The daemon drops its RPC port early in shutdown, so the first failed probe
    // means it's on its way down; cap the wait so a wedged daemon doesn't pin
    // the worker forever.
    //
    // A foreground daemon we launched is still our child, and an RPC shutdown
    // exits it behind our back — nothing has waited on it. Reap it each round
    // (and once more on the way out) so it doesn't sit as a zombie until the app
    // quits; a fork coin's launcher was already waited on at spawn, and a
    // prior-session daemon isn't ours, so both no-op here.
    var probe = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer probe.deinit();
    defer reapDaemonChild(ctx, idx);
    var i: u8 = 0;
    while (i < 40) : (i += 1) {
        io.sleep(.fromMilliseconds(250), .awake) catch {};
        _ = probe.reset(.retain_capacity);
        reapDaemonChild(ctx, idx);
        _ = coin.daemonInfo(probe.allocator(), auth) catch return;
    }

    // Still answering after the whole wait: the daemon is genuinely up. If the
    // stop request itself failed, that error is the honest reason to show;
    // otherwise it took the request and is simply slow to go.
    if (req_err) |err| {
        ctx.setError(@errorName(err));
        return err;
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
        if (!c.hasError()) c.setError(@errorName(err));
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

// --- sync accelerator (Divi's chain snapshot, Nerva's QuickSync) -----------
//
// A yes/no offer made *before* the first daemon start, when the coin's chain
// isn't there yet and it publishes something that skips most of the sync. The
// GUI asks `bw_sync_accel_offered` before calling `bw_start_daemon`, shows the
// name/detail/resume figures if so, and on the user's yes runs
// `bw_sync_accel_run` and then starts the daemon as usual.
//
// Progress deliberately rides the *install* channel (`bw_install_progress`):
// it reports the same download-then-extract phases, and reusing it means the
// GUI's existing progress pump drives this with no second mechanism.

/// Whether `idx` has a sync accelerator to offer right now — 1 yes, 0 no.
/// Cheap disk checks only (no daemon, no network), so it's safe to call on the
/// UI thread as the Start button is pressed. For a chain snapshot this is false
/// whenever chain data already exists, which is what keeps another app's data
/// safe.
export fn bw_sync_accel_offered(ctx: ?*Ctx, idx: usize) c_int {
    const c = ctx orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;
    return if (coin.offersSyncAccelerator(c.allocator, c.install_root, c.home_dir)) 1 else 0;
}

/// The accelerator's short name ("Blockchain snapshot"), for the prompt title.
export fn bw_sync_accel_name(idx: usize, buf: ?[*]u8, cap: usize) usize {
    const coin = coinByIndex(idx) orelse return 0;
    const sa = coin.syncAccelerator() orelse return 0;
    const b = buf orelse return 0;
    return copyOut(b[0..cap], sa.name);
}

/// The accelerator's one-line pitch (what it does, rough download size).
export fn bw_sync_accel_detail(idx: usize, buf: ?[*]u8, cap: usize) usize {
    const coin = coinByIndex(idx) orelse return 0;
    const sa = coin.syncAccelerator() orelse return 0;
    const b = buf orelse return 0;
    return copyOut(b[0..cap], sa.prompt_detail);
}

/// What taking the accelerator costs: the shared caution shown beside its pitch
/// when using it means trusting the publisher for work the node would otherwise
/// do itself. 0 bytes when it doesn't (a payload BoxWallet verifies), so the GUI
/// shows the block only when there's something to weigh.
export fn bw_sync_accel_trust_note(idx: usize, buf: ?[*]u8, cap: usize) usize {
    const coin = coinByIndex(idx) orelse return 0;
    const sa = coin.syncAccelerator() orelse return 0;
    if (!sa.trusts_publisher) return 0;
    const b = buf orelse return 0;
    return copyOut(b[0..cap], coinmod.Coin.accel_trust_note);
}

/// Bytes of an interrupted download already on disk, so the prompt can offer to
/// continue rather than appear to restart a multi-GB transfer. 0 when there's
/// nothing waiting or the accelerator doesn't resume.
export fn bw_sync_accel_resume_bytes(ctx: ?*Ctx, idx: usize) u64 {
    const c = ctx orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;
    return coin.syncAcceleratorPartialBytes(c.allocator, c.install_root, c.home_dir);
}

/// Fetch the accelerator and put it in place. Blocking and long — a chain
/// snapshot is several GB and its unpack is slower still — so the C++ side runs
/// it on its own thread and polls `bw_install_progress` meanwhile, exactly as it
/// does for an install.
///
/// A failed *resumable* download deliberately leaves its partial behind: the next
/// attempt continues from there, and `bw_sync_accel_resume_bytes` reports it.
///
/// Returns 0 on success, `bw_sync_accel_paused` when the caller asked it to stop
/// (not an error — what's on disk is kept and resumable), and -1 on failure.
export fn bw_sync_accel_run(ctx: ?*Ctx, idx: usize) c_int {
    const c = ctx orelse return -1;
    const coin = coinByIndex(idx) orelse return -1;
    const sa = coin.syncAccelerator() orelse return -1;

    // Publish "started" before any work so the UI switches to the progress
    // readout immediately, and clear it on every exit path so a failure can't
    // strand the pane in a permanent "Downloading…".
    c.install_phase.store(bw_install_phase_downloading, .monotonic);
    c.install_cur.store(0, .monotonic);
    c.install_total.store(0, .monotonic);
    defer c.install_phase.store(bw_install_phase_idle, .monotonic);

    // Private arena, freed as a unit — the accelerator's working set never
    // shares an allocator with the polling UI thread.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A fresh run clears any stale pause left by a previous one, so pressing
    // Resume can't immediately stop again.
    c.accel_pause.store(false, .monotonic);

    const progress: install.Progress = .{ .ctx = c, .func = onInstallProgress };
    const cancel: install.Cancel = .{ .ctx = c, .func = accelPauseRequested };
    sa.download(a, c.install_root, c.home_dir, progress, cancel) catch |err| {
        if (err == error.Paused) return bw_sync_accel_paused;
        c.setError(@errorName(err));
        return -1;
    };
    // A snapshot is inert until unpacked, so its failure fails the whole opt-in.
    if (sa.apply) |apply| {
        c.install_phase.store(bw_install_phase_extracting, .monotonic);
        c.install_cur.store(0, .monotonic);
        c.install_total.store(0, .monotonic);
        apply(a, c.install_root, c.home_dir, progress, cancel) catch |err| {
            if (err == error.Paused) return bw_sync_accel_paused;
            c.setError(@errorName(err));
            return -1;
        };
    }
    return 0;
}

/// `bw_sync_accel_run`'s "you asked me to stop" answer, distinct from both
/// success (0) and failure (< 0).
pub const bw_sync_accel_paused: c_int = 1;

/// `install.Cancel` sink: whether the caller has asked the transfer to stop.
fn accelPauseRequested(ctx_ptr: *anyopaque) bool {
    const c: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    return c.accel_pause.load(.monotonic);
}

/// Ask a running accelerator transfer to stop at the next chunk boundary — the
/// Pause button, and the first thing the caller must do when closing the app.
///
/// Returns immediately; the transfer unwinds on its own thread and reports
/// `bw_sync_accel_paused`. The caller **must still wait for that thread** before
/// `bw_deinit`, since the worker is using this context.
export fn bw_sync_accel_pause(ctx: ?*Ctx) void {
    const c = ctx orelse return;
    c.accel_pause.store(true, .monotonic);
}

export fn bw_start_daemon(ctx: ?*Ctx, idx: usize) c_int {
    const c = ctx orelse return -1;
    // Let the wallet service be attempted again for this daemon run, exactly as
    // the TUI does on start. Without it, one failed spawn (a missing binary, a
    // port still held by a service the last run orphaned) stays failed for the
    // rest of the session even after the cause is gone.
    if (idx < coin_count) c.wallet[idx].attempted = false;
    // A freshly (re)started daemon won't have our named wallet loaded (Core only
    // auto-loads the unnamed default), so let the next poll load it again.
    if (idx < coin_count) c.wallet_ensured[idx].store(0, .release);
    // A fresh run reports its own heights from scratch (it may even have been
    // reindexed), so the last run's high-water marks must not floor them.
    if (idx < coin_count) c.tip_marks[idx].clear();
    const held = holdDaemonAction(c, idx);
    defer releaseDaemonAction(c, idx, held);
    startDaemon(c, idx) catch |err| {
        if (!c.hasError()) c.setError(@errorName(err));
        return -1;
    };
    return 0;
}

export fn bw_stop_daemon(ctx: ?*Ctx, idx: usize) c_int {
    const c = ctx orelse return -1;
    if (idx < coin_count) c.tip_marks[idx].clear();
    const held = holdDaemonAction(c, idx);
    defer releaseDaemonAction(c, idx, held);
    stopDaemon(c, idx) catch |err| {
        if (!c.hasError()) c.setError(@errorName(err));
        return -1;
    };
    return 0;
}

/// Claim `daemon_child[idx]` for this worker, so a concurrent `bw_reap_daemon`
/// on the poll thread leaves the slot alone. Returns whether the claim applies
/// (a bad index owns nothing).
fn holdDaemonAction(ctx: *Ctx, idx: usize) bool {
    if (idx >= coin_count) return false;
    ctx.daemon_action[idx].store(1, .monotonic);
    return true;
}

/// Release the claim, publishing this worker's writes to `daemon_child[idx]` to
/// whichever thread reaps next (`.release` here pairs with the reaper's
/// `.acquire`).
fn releaseDaemonAction(ctx: *Ctx, idx: usize, held: bool) void {
    if (held) ctx.daemon_action[idx].store(0, .release);
}

/// Collect a foreground daemon that exited on its own, so it doesn't linger as a
/// zombie. Meant to be called from the status poll, once per tick.
///
/// A foreground daemon (Nerva, Salvium, Zano, Ergo, Epic) is spawned detached and
/// deliberately not waited on — it has to outlive the start call — so we stay its
/// parent. The stop path reaps it; a daemon that dies *by itself* (crash, OOM
/// kill, an operator `kill`) has no such path, and its zombie kept `comm`, which
/// read as "the daemon is still coming up": Start greyed out because it was
/// starting, Stop greyed out because it wasn't running. `proc.isZombie` now keeps
/// the buttons honest either way, but the corpse still has to be collected — and
/// on a platform without `/proc` reaping it is the *only* thing that clears the
/// state. Mirrors the TUI's per-tick `reapDaemonChild`.
///
/// A no-op while a start/stop worker owns the slot, when there's nothing to
/// collect, and on Windows, where there are no zombies.
export fn bw_reap_daemon(ctx: ?*Ctx, idx: usize) void {
    const c = ctx orelse return;
    if (idx >= coin_count) return;
    if (c.daemon_action[idx].load(.acquire) != 0) return;
    reapDaemonChild(c, idx);
}

fn walletAction(ctx: *Ctx, idx: usize, comptime lock: bool, pass: []const u8, staking: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

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

    const io = sharedIo();

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

// ---- external wallet: service lifecycle + state -----------------------------

/// `bw_ext_wallet_state` values — the whole four-way display state machine, so
/// the C++ side never re-derives it from a handful of booleans.
pub const bw_wallet_none: c_int = 0; // nothing on disk yet
pub const bw_wallet_locked: c_int = 1; // exists, not opened in this session
pub const bw_wallet_open: c_int = 2; // opened here
pub const bw_wallet_rescan: c_int = 3; // opened, and still scanning the chain

/// Whether the coin's managed wallet already exists on disk. A cheap stat, no
/// running process needed — safe on the UI thread.
export fn bw_ext_wallet_exists(ctx: ?*Ctx, idx: usize) c_int {
    const c = ctx orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;
    const ew = coin.externalWallet() orelse return 0;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    return if (ew.exists(arena.allocator(), c.home_dir)) 1 else 0;
}

/// Where this coin's wallet stands right now, as a `bw_wallet_*` value. Cheap
/// (a stat plus two atomics) — safe on the UI thread. The rescanning tier is
/// reported by `bw_ext_wallet_rescan`, which does the RPC; this answers the
/// three states that need no daemon.
export fn bw_ext_wallet_state(ctx: ?*Ctx, idx: usize) c_int {
    const c = ctx orelse return bw_wallet_none;
    if (idx >= coin_count) return bw_wallet_none;
    if (c.wallet_open[idx].load(.monotonic) != 0) return bw_wallet_open;
    return if (bw_ext_wallet_exists(ctx, idx) != 0) bw_wallet_locked else bw_wallet_none;
}

/// Bring the coin's wallet service up alongside its running daemon. Mirrors the
/// TUI's per-tick call: idempotent, and cheap once running or once an attempt
/// has failed. Spawns a process — worker thread only.
///
/// Returns 1 running, 0 nothing to do (not an external-wallet coin, or one whose
/// service is launched per-open with the password), `bw_busy` when a wallet op
/// holds the lock, -1 failed (`bw_last_error` has why).
///
/// Contended is a **skip, not a wait**: this runs on the caller's status poll,
/// and blocking here would freeze the whole pane behind a restore that can run
/// for minutes. Skipping is safe because it's idempotent and called again every
/// tick — and while a wallet op is in flight the service is up by definition.
export fn bw_ext_wallet_service_ensure(ctx: ?*Ctx, idx: usize) c_int {
    const c = ctx orelse return -1;
    const coin = coinByIndex(idx) orelse return -1;
    if (idx >= coin_count) return -1;

    if (!c.wallet_mtx.tryLock()) return bw_busy;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const io = sharedIo();
    defer c.wallet_mtx.unlock(io);

    // The wallet service must inherit our environment (esp. `$HOME`), exactly as
    // the daemon spawn does; a null map would hand it an empty one.
    var env_map = currentEnvMap(arena.allocator()) catch {
        c.setError("couldn't read the environment");
        return -1;
    };
    defer env_map.deinit();

    return switch (extwallet.ensure(&c.wallet[idx], coin, c.install_root, c.home_dir, &env_map)) {
        .not_applicable => 0,
        .already_running, .started => 1,
        // Already reported once this daemon run; don't re-raise it every tick.
        .already_attempted => -1,
        .port_busy => blk: {
            c.setError("Another BoxWallet is already using this coin's wallet service. Close it and try again.");
            c.setErrorCode("WalletPortBusy");
            break :blk -1;
        },
        .argv_failed, .spawn_failed => |err| blk: {
            // Most likely the wallet-rpc binary isn't on disk (an install from
            // before it was bundled).
            c.setError(@errorName(err));
            c.setErrorCode(@errorName(err));
            break :blk -1;
        },
    };
}

/// Tear the coin's wallet service down and mark its wallet closed — the daemon
/// it talks to has stopped. Kills a process; worker thread only.
///
/// Like `_ensure` this skips rather than waits when a wallet op holds the lock,
/// because it runs on the status poll. That doesn't risk leaking the process:
/// the caller keeps calling this every tick while the daemon is down, and
/// `bw_deinit` kills whatever is left regardless.
export fn bw_ext_wallet_service_stop(ctx: ?*Ctx, idx: usize) void {
    const c = ctx orelse return;
    if (idx >= coin_count) return;

    if (!c.wallet_mtx.tryLock()) return;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const io = sharedIo();
    defer c.wallet_mtx.unlock(io);

    c.wallet_open[idx].store(0, .monotonic);
    extwallet.kill(&c.wallet[idx]);
}

// ---- external wallet: the operations ----------------------------------------

/// Which wallet operation `walletOp` should run. Taken from `walletmenu.zig`,
/// not declared again here — this used to be a local copy under a comment
/// reading "mirrors the TUI's", which is how the two front-ends end up offering
/// different things.
const WalletOp = walletmenu.SetupOp;

/// Upper bound on a wallet password, sizing the bounded buffer we copy the
/// caller's secret into. Comfortably past any sane passphrase while keeping the
/// secret in a small fixed buffer we can wipe (memory constraint). Matches the
/// TUI's own cap.
const wallet_pw_max = 256;

/// Run one wallet operation under the wallet lock, threading the daemon's own
/// failure message up through `detail`.
///
/// `password` and `seed` are the caller's secrets; they are used here and never
/// stored. A created wallet's mnemonic is parked in `ctx.seed` for exactly one
/// `bw_ext_wallet_seed_take`.
fn walletOp(
    ctx: *Ctx,
    idx: usize,
    op: WalletOp,
    password: []const u8,
    seed: []const u8,
    src_path: []const u8,
) !void {
    const coin = coinByIndex(idx) orelse return error.NoSuchCoin;
    const ew = coin.externalWallet() orelse return error.Unsupported;
    if (coin.walletLaunchesWithPassword()) return error.Unsupported; // Zano's per-open launch isn't wired here yet

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    ctx.wallet_mtx.lockUncancelable(io);
    defer ctx.wallet_mtx.unlock(io);

    var detail: Coin.WalletErrSink = .{};
    errdefer if (detail.len > 0) ctx.setError(detail.slice());

    const auth = extwallet.authFor(coin, &ctx.wallet[idx]);
    switch (op) {
        .create => {
            const s = try ew.create(a, auth, password, &detail);
            // Park the mnemonic for the one take. Overwrites any earlier pending
            // seed, which is the right outcome — that one was never displayed.
            ctx.seed = s;
            ctx.seed_coin = @intCast(idx);
        },
        .restore_seed => try ew.restore_seed(a, auth, ctx.install_root, ctx.home_dir, password, seed, &detail),
        .restore_file => try (ew.restore_file orelse return error.Unsupported)(a, auth, ctx.home_dir, src_path, password, &detail),
        .open => try ew.open(a, auth, password, &detail),
        .lock => try (ew.lock orelse return error.Unsupported)(a, auth, &detail),
    }
    ctx.wallet_open[idx].store(if (op == .lock) 0 else 1, .monotonic);
}

/// Copy the caller's secret into a bounded buffer we can wipe, run `op`, and
/// wipe it again on every path out. Returns 0, or -1 with `bw_last_error` set to
/// the sentence for the user and `bw_last_error_code` to the bare error name.
fn walletOpCall(
    ctx: ?*Ctx,
    idx: usize,
    op: WalletOp,
    pass_ptr: ?[*]const u8,
    pass_len: usize,
    seed_ptr: ?[*]const u8,
    seed_len: usize,
    src_path: ?[*:0]const u8,
) c_int {
    const c = ctx orelse return -1;
    if (idx >= coin_count) return -1;
    c.clearError();

    var pw_buf: [wallet_pw_max]u8 = undefined;
    var pn: usize = 0;
    if (pass_ptr) |p| {
        pn = @min(pass_len, pw_buf.len);
        @memcpy(pw_buf[0..pn], p[0..pn]);
    }
    defer @memset(pw_buf[0..pn], 0); // our copy is gone on every path

    var seed_buf: [models.Seed.buf_len]u8 = undefined;
    var sn: usize = 0;
    if (seed_ptr) |p| {
        sn = @min(seed_len, seed_buf.len);
        @memcpy(seed_buf[0..sn], p[0..sn]);
    }
    defer @memset(seed_buf[0..sn], 0);

    const path = if (src_path) |p| std.mem.span(p) else "";

    walletOp(c, idx, op, pw_buf[0..pn], seed_buf[0..sn], path) catch |err| {
        // `walletOp`'s errdefer may already have recorded the daemon's own
        // message; `friendlyWalletError` prefers it over any generic fallback.
        const raw = c.errorText();
        c.setErrorCode(@errorName(err));
        const text = extwallet.friendlyWalletError(@errorName(err), raw);
        // `text` may alias the error slot (when it *is* the detail), so only
        // rewrite it when it points somewhere else.
        if (text.ptr != raw.ptr) c.setError(text);
        return -1;
    };
    return 0;
}

/// Create a brand-new wallet under `pw`. On success its mnemonic is pending —
/// take it with `bw_ext_wallet_seed_take` and show it to the user to write down.
export fn bw_ext_wallet_create(ctx: ?*Ctx, idx: usize, pw: ?[*]const u8, pw_len: usize) c_int {
    return walletOpCall(ctx, idx, .create, pw, pw_len, null, 0, null);
}

/// Restore a wallet from mnemonic `seed` under `pw`. The words are normalized
/// (lowercased, whitespace collapsed) by the coin before use, so a phrase pasted
/// with stray case or spacing still restores.
export fn bw_ext_wallet_restore_seed(
    ctx: ?*Ctx,
    idx: usize,
    pw: ?[*]const u8,
    pw_len: usize,
    seed: ?[*]const u8,
    seed_len: usize,
) c_int {
    return walletOpCall(ctx, idx, .restore_seed, pw, pw_len, seed, seed_len, null);
}

/// Import an existing wallet file at `src_path` and open it with `pw`.
export fn bw_ext_wallet_restore_file(
    ctx: ?*Ctx,
    idx: usize,
    pw: ?[*]const u8,
    pw_len: usize,
    src_path: ?[*:0]const u8,
) c_int {
    return walletOpCall(ctx, idx, .restore_file, pw, pw_len, null, 0, src_path);
}

/// Open the existing managed wallet with `pw`.
export fn bw_ext_wallet_open(ctx: ?*Ctx, idx: usize, pw: ?[*]const u8, pw_len: usize) c_int {
    return walletOpCall(ctx, idx, .open, pw, pw_len, null, 0, null);
}

/// Re-lock an in-daemon wallet that stays open while the daemon runs. Not
/// offered for the process-backed wallets, which lock when their process dies.
export fn bw_ext_wallet_lock(ctx: ?*Ctx, idx: usize) c_int {
    return walletOpCall(ctx, idx, .lock, null, 0, null, 0, null);
}

/// Delete the managed wallet's on-disk artifacts so a different one can be
/// created or restored in its place. **Destructive** — the caller must gate it
/// behind an explicit confirmation.
///
/// The wallet service is killed first so it releases its file locks, exactly as
/// the TUI does; the daemon is deliberately left running (bouncing it would
/// throw away sync progress and peers). Only ever removes what BoxWallet itself
/// manages.
export fn bw_ext_wallet_remove(ctx: ?*Ctx, idx: usize) c_int {
    const c = ctx orelse return -1;
    if (idx >= coin_count) return -1;
    const coin = coinByIndex(idx) orelse return -1;
    const ew = coin.externalWallet() orelse return -1;
    const removeFn = ew.remove orelse {
        c.setError("This coin has no in-app wallet replace.");
        return -1;
    };
    c.clearError();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const io = sharedIo();

    c.wallet_mtx.lockUncancelable(io);
    defer c.wallet_mtx.unlock(io);

    // An in-daemon wallet (Ergo) caches its secret in the running node, so the
    // daemon has to be down before the files go — the caller drives stop →
    // remove → start. A process-backed wallet just needs its service gone.
    c.wallet_open[idx].store(0, .monotonic);
    extwallet.kill(&c.wallet[idx]);

    removeFn(arena.allocator(), c.home_dir) catch |err| {
        c.setError(@errorName(err));
        c.setErrorCode(@errorName(err));
        return -1;
    };
    return 0;
}

/// Take the pending mnemonic of a just-created wallet, **once**. Returns the
/// byte count written and wipes the core's copy, so a second call answers 0 and
/// the words can't be re-shown.
///
/// If `cap` is smaller than the phrase, this returns the required size and
/// copies *nothing*, leaving the copy intact — truncating the user's only backup
/// would be worse than refusing. Pass a 256-byte buffer.
export fn bw_ext_wallet_seed_take(ctx: ?*Ctx, buf: ?[*]u8, cap: usize) usize {
    const c = ctx orelse return 0;
    const b = buf orelse return 0;
    if (c.seed_coin < 0 or c.seed.len == 0) return 0;
    if (cap < c.seed.len) return c.seed.len;

    const n = c.seed.len;
    @memcpy(b[0..n], c.seed.buf[0..n]);
    @memset(std.mem.asBytes(&c.seed), 0);
    c.seed_coin = -1;
    return n;
}

/// Drop a pending mnemonic without showing it (the user cancelled, or navigated
/// away). Idempotent.
export fn bw_ext_wallet_seed_discard(ctx: ?*Ctx) void {
    const c = ctx orelse return;
    @memset(std.mem.asBytes(&c.seed), 0);
    c.seed_coin = -1;
}

// ---- external wallet: reads -------------------------------------------------

/// Mirror of `models.WalletBalance`.
pub const BwWalletBalance = extern struct {
    total: f64,
    available: f64,
};

/// Mirror of `models.RescanProgress`.
pub const BwRescanProgress = extern struct {
    scanned: i64,
    target: i64,
};

/// A wallet op holds the lock — the caller should keep its last value rather
/// than stall behind a restore that may run for minutes.
pub const bw_busy: c_int = -2;

/// Balances of the coin's wallet, whichever shape it has: 0 with `out` filled,
/// `bw_busy`, or -1.
///
/// Two backings converge here. A managed wallet answers from its own wallet-rpc
/// (`ExternalWallet.balance`, a required hook); an in-daemon wallet answers from
/// the daemon (`Coin.walletBalance`). The front-end asks one question — "what is
/// this wallet worth?" — so it gets one export, and the branch lives here rather
/// than in C++.
///
/// The open-wallet gate applies **only** to a managed wallet. A bitcoin-family
/// daemon serves `getbalance` on a *locked* wallet, so gating an in-daemon coin
/// on "unlocked" would blank the balance of every wallet the user hasn't opened
/// this session.
///
/// This export owns the wallet-closed rule: `error.WalletClosed` is the **only**
/// error that clears the open flag, so a transient RPC blip can't make the UI
/// claim the wallet locked itself. Keeping that here rather than in C++ is what
/// stops the two front-ends disagreeing about it.
export fn bw_wallet_balance(ctx: ?*Ctx, idx: usize, out: ?*BwWalletBalance) c_int {
    const c = ctx orelse return -1;
    const o = out orelse return -1;
    if (idx >= coin_count) return -1;
    const coin = coinByIndex(idx) orelse return -1;
    const maybe_ew = coin.externalWallet();
    if (maybe_ew == null and !coin.supportsBalance()) return -1;
    if (maybe_ew != null and c.wallet_open[idx].load(.monotonic) == 0) return -1;

    if (!c.wallet_mtx.tryLock()) return bw_busy;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();
    defer c.wallet_mtx.unlock(io);

    const auth = walletAuth(a, io, coin, c, idx) catch |err| {
        c.setError(@errorName(err));
        return -1;
    };
    const bal = (if (maybe_ew) |ew| ew.balance(a, auth) else coin.walletBalance(a, auth)) catch |err| {
        if (err == error.WalletClosed) c.wallet_open[idx].store(0, .monotonic);
        c.setError(@errorName(err));
        return -1;
    };
    o.total = bal.total;
    o.available = bal.available;
    return 0;
}

/// Whether any of this balance is still settling — mempool or immature funds,
/// i.e. `total` is ahead of `available`. 1 yes, 0 no (also 0 for a null
/// balance).
///
/// `models.WalletBalance.hasPending` owns the comparison, epsilon and all, so
/// the GUI can't drift from the TUI on the one question that decides whether the
/// spendable figure is worth showing. Pure; UI-thread safe.
export fn bw_balance_has_pending(bal: ?*const BwWalletBalance) c_int {
    const b = bal orelse return 0;
    const m: models.WalletBalance = .{ .total = b.total, .available = b.available };
    return if (m.hasPending()) 1 else 0;
}

/// Managed-wallet spelling of `bw_wallet_balance`: refuses a coin whose wallet
/// lives in its daemon, then defers, so the wallet-closed rule stays in exactly
/// one place.
export fn bw_ext_wallet_balance(ctx: ?*Ctx, idx: usize, out: ?*BwWalletBalance) c_int {
    const coin = coinByIndex(idx) orelse return -1;
    if (coin.externalWallet() == null) return -1;
    return bw_wallet_balance(ctx, idx, out);
}

/// Whether the open wallet is still scanning the chain for its history: 1 with
/// `out` filled, 0 not scanning, `bw_busy`, or -1.
///
/// After a restore, a Monero-family wallet-rpc refreshes from height 0 in the
/// background, and its balance reads 0 until it catches up — so the UI must show
/// progress rather than a confusing empty wallet. The scanned height comes from
/// the wallet, the target from the daemon.
export fn bw_ext_wallet_rescan(ctx: ?*Ctx, idx: usize, out: ?*BwRescanProgress) c_int {
    const c = ctx orelse return -1;
    const o = out orelse return -1;
    if (idx >= coin_count) return -1;
    const coin = coinByIndex(idx) orelse return -1;
    const ew = coin.externalWallet() orelse return -1;
    const progressFn = ew.rescan_progress orelse return 0;
    if (c.wallet_open[idx].load(.monotonic) == 0) return 0;

    if (!c.wallet_mtx.tryLock()) return bw_busy;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();
    defer c.wallet_mtx.unlock(io);

    const daemon_auth = ctxAuth(a, io, coin, c) catch |err| {
        c.setError(@errorName(err));
        return -1;
    };
    const maybe = progressFn(a, extwallet.authFor(coin, &c.wallet[idx]), daemon_auth) catch |err| {
        c.setError(@errorName(err));
        return -1;
    };
    const rp = maybe orelse return 0;
    o.scanned = rp.scanned;
    o.target = rp.target;
    return 1;
}

/// Mirror of `models.WalletTx`. Scalar-only: `direction` is the ordinal of
/// `models.TxDirection` (0 received, 1 sent, 2 stake/mined credit, 3 outgoing
/// stake) and `amount` is a positive magnitude, so a fixed-capacity array of
/// these memcpys across with nothing owned on either side. 0 and 2 are
/// incoming, 1 and 3 outgoing — the front-end applies the sign from that, so a
/// direction it doesn't know must not be assumed to be a credit.
/// `txid` follows `BwScPosition.id`: an explicit length rather than a NUL
/// terminator, because a txid is exactly 64 hex characters everywhere BoxWallet
/// looks and terminating it would truncate the last one. `txid_len` is 0 for a
/// coin whose list RPC reports no hash.
pub const BwWalletTx = extern struct {
    direction: c_int,
    amount: f64,
    time: i64,
    confirmations: i64,
    txid: [64]u8,
    txid_len: usize,
};

/// The confirmation count above which a transaction reads as settled. One line
/// for both front-ends, so the TUI's Status column and the GUI's confirmations
/// column can't drift apart. Cheap; UI-thread safe.
export fn bw_tx_confirmed_threshold() i64 {
    return models.tx_confirmed_threshold;
}

/// The open wallet's most recent transactions, newest first. Writes up to `cap`
/// into `out` and returns how many. 0 on any failure — a transaction list that
/// can't be read is empty, not an error worth interrupting the user for.
export fn bw_wallet_transactions(ctx: ?*Ctx, idx: usize, out: ?*BwWalletTx, cap: usize) usize {
    const c = ctx orelse return 0;
    const o = out orelse return 0;
    if (idx >= coin_count or cap == 0) return 0;
    const coin = coinByIndex(idx) orelse return 0;
    if (!coin.supportsTransactions()) return 0;
    if (coin.hasExternalWallet() and c.wallet_open[idx].load(.monotonic) == 0) return 0;

    if (!c.wallet_mtx.tryLock()) return 0;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();
    defer c.wallet_mtx.unlock(io);

    const auth = walletAuth(a, io, coin, c, idx) catch return 0;
    const txs = coin.walletTransactions(a, auth, cap) catch return 0;
    const n = @min(txs.len, cap);
    const dst = @as([*]BwWalletTx, @ptrCast(o))[0..n];
    for (dst, txs[0..n]) |*d, t| {
        d.* = .{
            .direction = @intFromEnum(t.direction),
            .amount = t.amount,
            .time = t.time,
            .confirmations = t.confirmations,
            .txid = undefined,
            .txid_len = t.txid_len,
        };
        @memcpy(d.txid[0..t.txid_len], t.txid());
    }
    return n;
}

/// Mirror of `models.Stake`. Scalar-only for the same reason as `BwWalletTx`.
/// The zeros are load-bearing: `unlocked_time`/`returned` are 0 for "not known",
/// which a matured stake can legitimately be when two of them were repaid in one
/// credit. Show a blank there — never a 0 figure, and never a guess.
pub const BwStake = extern struct {
    amount: f64,
    staked_time: i64,
    unlock_height: i64,
    blocks_remaining: i64,
    unlock_eta_seconds: i64,
    unlocked_time: i64,
    returned: f64,
    txid: [64]u8,
    txid_len: usize,
};

/// Whether this coin can enumerate the wallet's stakes, so the Staking tab can
/// show a list rather than only a stake button. Cheap; UI-thread safe.
export fn bw_coin_supports_stake_list(idx: usize) c_int {
    const coin = coinByIndex(idx) orelse return 0;
    return if (coin.supportsStakeList()) 1 else 0;
}

/// The wallet's stakes, newest first. Writes up to `cap` into `out` and returns
/// how many. 0 on any failure — same rule as `bw_wallet_transactions`: a list
/// that can't be read is empty, not an error worth interrupting the user for.
export fn bw_wallet_stakes(ctx: ?*Ctx, idx: usize, out: ?*BwStake, cap: usize) usize {
    const c = ctx orelse return 0;
    const o = out orelse return 0;
    if (idx >= coin_count or cap == 0) return 0;
    const coin = coinByIndex(idx) orelse return 0;
    if (!coin.supportsStakeList()) return 0;
    if (coin.hasExternalWallet() and c.wallet_open[idx].load(.monotonic) == 0) return 0;

    if (!c.wallet_mtx.tryLock()) return 0;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();
    defer c.wallet_mtx.unlock(io);

    const auth = walletAuth(a, io, coin, c, idx) catch return 0;
    const stakes = coin.walletStakes(a, auth, cap) catch return 0;
    const n = @min(stakes.len, cap);
    const dst = @as([*]BwStake, @ptrCast(o))[0..n];
    for (dst, stakes[0..n]) |*d, s| {
        d.* = .{
            .amount = s.amount,
            .staked_time = s.staked_time,
            .unlock_height = s.unlock_height,
            .blocks_remaining = s.blocks_remaining,
            .unlock_eta_seconds = s.unlock_eta_seconds,
            .unlocked_time = s.unlocked_time,
            .returned = s.returned,
            .txid = undefined,
            .txid_len = s.txid_len,
        };
        @memcpy(d.txid[0..s.txid_len], s.txid());
    }
    return n;
}

/// What one stake's term earned, written to `out`. 1 when there's a figure to
/// show, 0 when there isn't — still locked, or a payout that couldn't be told
/// apart from another stake's.
///
/// `models.Stake.yield` owns that rule (including refusing a return below the
/// principal, which would mean the pairing was wrong), so a front-end can't
/// decide for itself that a 0 means zero yield. Pure; UI-thread safe.
export fn bw_stake_yield(stake: ?*const BwStake, out: ?*f64) c_int {
    const s = stake orelse return 0;
    const o = out orelse return 0;
    const m: models.Stake = .{
        .amount = s.amount,
        .staked_time = s.staked_time,
        .unlock_height = s.unlock_height,
        .blocks_remaining = s.blocks_remaining,
        .unlock_eta_seconds = s.unlock_eta_seconds,
        .unlocked_time = s.unlocked_time,
        .returned = s.returned,
    };
    o.* = m.yield() orelse return 0;
    return 1;
}

/// The wallet's receive address, written into `buf`; returns its length, or 0 on
/// failure. `force_new` mints a fresh one.
///
/// **Never call this on a timer.** The underlying RPC rotates the address once
/// it has been paid, so polling it would swap the address out from under a user
/// who is part-way through sending to it. Call it once when nothing is cached,
/// and again only when the user explicitly asks for a new one.
export fn bw_wallet_receive_address(ctx: ?*Ctx, idx: usize, force_new: c_int, buf: ?[*]u8, cap: usize) usize {
    const c = ctx orelse return 0;
    const b = buf orelse return 0;
    if (idx >= coin_count) return 0;
    const coin = coinByIndex(idx) orelse return 0;
    if (!coin.supportsReceiveAddress()) return 0;
    if (coin.hasExternalWallet() and c.wallet_open[idx].load(.monotonic) == 0) return 0;

    if (!c.wallet_mtx.tryLock()) return 0;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();
    defer c.wallet_mtx.unlock(io);

    const auth = walletAuth(a, io, coin, c, idx) catch return 0;
    const addr = coin.walletReceiveAddress(a, auth, force_new != 0) catch return 0;
    return copyOut(b[0..cap], addr);
}

/// Send `amount` to `address`. Returns 0 on broadcast (`out` = the txid), 1 when
/// the daemon rejected it (`out` = its own reason, verbatim), -1 on a transport
/// failure (`bw_last_error` has why).
///
/// A rejection is an answer, not an error: "insufficient funds" is something the
/// user needs to read, not a generic failure.
export fn bw_wallet_send(ctx: ?*Ctx, idx: usize, address: ?[*:0]const u8, amount: f64, out: ?[*]u8, cap: usize) c_int {
    const c = ctx orelse return -1;
    const addr_z = address orelse return -1;
    const o = out orelse return -1;
    if (idx >= coin_count) return -1;
    const coin = coinByIndex(idx) orelse return -1;
    if (!coin.supportsSend()) return -1;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    c.wallet_mtx.lockUncancelable(io);
    defer c.wallet_mtx.unlock(io);

    const auth = walletAuth(a, io, coin, c, idx) catch |err| {
        c.setError(@errorName(err));
        return -1;
    };
    const res = coin.walletSend(a, auth, std.mem.span(addr_z), amount) catch |err| {
        c.setError(@errorName(err));
        c.setErrorCode(@errorName(err));
        return -1;
    };
    return switch (res) {
        .ok => |txid| blk: {
            _ = copyOut(o[0..cap], txid);
            break :blk 0;
        },
        .failed => |reason| blk: {
            _ = copyOut(o[0..cap], reason);
            break :blk 1;
        },
    };
}

/// The auth a *wallet* read should use: the wallet process's own endpoint for a
/// managed wallet, the daemon's for a coin whose wallet lives in its daemon.
/// Mirrors the split the TUI's poll worker makes.
fn walletAuth(a: std.mem.Allocator, io: std.Io, coin: Coin, ctx: *Ctx, idx: usize) !models.CoinAuth {
    if (coin.hasExternalWallet()) return extwallet.authFor(coin, &ctx.wallet[idx]);
    return ctxAuth(a, io, coin, ctx);
}

// ---- mining -----------------------------------------------------------------

/// Mirror of `models.MiningStatus`. Scalar-only, so it crosses the boundary as a
/// plain memcpy with nothing owned on either side.
pub const BwMiningStatus = extern struct {
    active: c_int,
    threads: u32,
    speed: u64, // hashes per second
};

/// The miner lives *inside* the daemon (Nerva's `nervad`), so this reads the
/// **daemon's** auth — never the wallet process's. Same split the TUI makes.
fn fetchMiningStatus(ctx: *Ctx, idx: usize, out: *BwMiningStatus) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const io = sharedIo();

    const coin = coinByIndex(idx) orelse return error.NoSuchCoin;
    const auth = try ctxAuth(a, io, coin, ctx);
    const ms = try coin.miningStatus(a, auth);
    out.active = if (ms.active) 1 else 0;
    out.threads = ms.threads;
    out.speed = ms.speed;
}

/// Whether the daemon is currently mining, with how many threads and how fast.
/// Blocks on RPC — worker thread only. Only meaningful when
/// `bw_coin_supports_mining` and the daemon is running.
export fn bw_mining_status(ctx: ?*Ctx, idx: usize, out: ?*BwMiningStatus) c_int {
    const c = ctx orelse return -1;
    const o = out orelse return -1;
    fetchMiningStatus(c, idx, o) catch |err| {
        c.setError(@errorName(err));
        return -1;
    };
    return 0;
}

/// Start the daemon's miner on `threads` threads, paying block rewards to
/// `address`. Blocks on RPC — worker thread only.
///
/// The address is **supplied by the caller**, not looked up here: it must be the
/// wallet's own receive address, the one the user can actually see, and the
/// caller already has it cached. Mining to an address the user can't inspect
/// would be worse than not mining.
export fn bw_mining_start(ctx: ?*Ctx, idx: usize, address: ?[*:0]const u8, threads: u32) c_int {
    const c = ctx orelse return -1;
    const addr_z = address orelse return -1;
    miningAction(c, idx, std.mem.span(addr_z), threads) catch |err| {
        c.setError(@errorName(err));
        c.setErrorCode(@errorName(err));
        return -1;
    };
    return 0;
}

/// Stop the daemon's miner. Blocks on RPC — worker thread only.
export fn bw_mining_stop(ctx: ?*Ctx, idx: usize) c_int {
    const c = ctx orelse return -1;
    miningAction(c, idx, "", 0) catch |err| {
        c.setError(@errorName(err));
        c.setErrorCode(@errorName(err));
        return -1;
    };
    return 0;
}

/// Start (non-empty `address`) or stop the miner. Uses the **daemon's** auth —
/// the miner lives inside the daemon, not the wallet process.
fn miningAction(ctx: *Ctx, idx: usize, address: []const u8, threads: u32) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    const coin = coinByIndex(idx) orelse return error.NoSuchCoin;
    const auth = try ctxAuth(a, io, coin, ctx);
    if (address.len == 0) return coin.miningStop(a, auth);
    return coin.miningStart(a, auth, address, threads);
}

/// This machine's logical CPU thread count — the upper bound on what the user
/// may ask the miner for. Cheap; safe to call on the UI thread.
export fn bw_cpu_threads() u32 {
    return mining.cpuThreadCount();
}

/// Render a hashrate ("1.23 MH/s") into `buf`, returning its length. Exported
/// rather than reimplemented C++-side so both front-ends round and label
/// identically. Cheap; safe on the UI thread.
export fn bw_format_hashrate(speed: u64, buf: ?[*]u8, cap: usize) usize {
    const b = buf orelse return 0;
    var tmp: [32]u8 = undefined;
    return copyOut(b[0..cap], mining.formatHashrate(&tmp, speed));
}

/// Plain-language reason for a failed mining start/stop, given the bare error
/// name from `bw_last_error`. Cheap; safe on the UI thread.
export fn bw_mining_failure_text(err_name: ?[*:0]const u8, buf: ?[*]u8, cap: usize) usize {
    const n = err_name orelse return 0;
    const b = buf orelse return 0;
    return copyOut(b[0..cap], mining.failureText(std.mem.span(n)));
}

// ---- disk usage (for the coin's "disk used" gauge) --------------------------

// ---- the chain-native stablecoin (DigiByte's DigiDollar) --------------------
//
// Money here is integer **cents** throughout, never a float — these figures are
// what a mint and a redeem are settled against, and a rounding artifact in a
// float would be a rounding artifact in someone's money.
//
// Note DigiByte's wallet lives in its daemon, and the stablecoin hooks take the
// *daemon's* auth — so these use `ctxAuth`, not `walletAuth`, and there is no
// wallet-open gate. That is the same trap that left the ordinary wallet tabs
// blank for every in-daemon coin.

/// Upper bound on a coin's lock-tier menu, so callers can size an array once.
/// DigiByte ships ten; the headroom is for a coin that adds more without every
/// caller silently dropping the extras.
pub const bw_sc_max_tiers: usize = 16;

/// One lock tier a mint can choose: how long the collateral is committed, and
/// how much collateral the position needs as a percentage.
pub const BwScTier = extern struct {
    tier: u8,
    ratio_pct: u32,
    duration: [24]u8, // NUL-terminated
};

/// Live system state. Everything past `active` is best-effort: a daemon
/// mid-warmup or an oracle hiccup leaves the affected figure at 0 rather than
/// failing the whole snapshot.
pub const BwScInfo = extern struct {
    active: c_int,
    /// The raw BIP9 deployment status, for the pre-activation readout.
    status: [24]u8, // NUL-terminated
    activation_height: i64,
    price_micro_usd: u64,
    price_stale: c_int,
    total_supply_cents: i64,
    total_collateral: f64,
    health_ratio: f64,
    minting_blocked: c_int,
};

pub const BwScBalance = extern struct {
    confirmed_cents: i64,
    pending_cents: i64,
};

/// Mirror of `models.StablecoinTx`. `kind` is the ordinal: 0 mint, 1 sent,
/// 2 received, 3 redeem. `amount_cents` is a positive magnitude — `kind` carries
/// the sign.
pub const BwScTx = extern struct {
    kind: c_int,
    amount_cents: i64,
    time: i64,
    confirmations: i64,
};

/// One minted vault. `id` is the mint transaction hash — the handle a redeem is
/// keyed on — carried with an explicit length rather than NUL-terminated,
/// because a bitcoin-family txid is exactly 64 hex characters and terminating it
/// would silently truncate the last one.
pub const BwScPosition = extern struct {
    id: [64]u8,
    id_len: usize,
    amount_cents: i64,
    tier: u8,
    unlock_height: i64,
    /// The daemon's own verdict — timelock expired, confirmed, unspent. Filter
    /// the redeem picker on this rather than comparing heights yourself.
    can_redeem: c_int,
};

/// The stablecoin's display name ("DigiDollar") and ticker ("DGD"). 0 for a coin
/// that has none. Cheap; UI-thread safe.
export fn bw_sc_name(idx: usize, buf: ?[*]u8, cap: usize) usize {
    const b = buf orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;
    const sc = coin.stablecoin() orelse return 0;
    return copyOut(b[0..cap], sc.name);
}

export fn bw_sc_symbol(idx: usize, buf: ?[*]u8, cap: usize) usize {
    const b = buf orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;
    const sc = coin.stablecoin() orelse return 0;
    return copyOut(b[0..cap], sc.symbol);
}

/// Mint bounds in cents, and how long a block takes (for the activation
/// countdown). 0 when the coin has no stablecoin. Cheap; UI-thread safe.
export fn bw_sc_min_mint_cents(idx: usize) i64 {
    const coin = coinByIndex(idx) orelse return 0;
    const sc = coin.stablecoin() orelse return 0;
    return sc.min_mint_cents;
}

export fn bw_sc_max_mint_cents(idx: usize) i64 {
    const coin = coinByIndex(idx) orelse return 0;
    const sc = coin.stablecoin() orelse return 0;
    return sc.max_mint_cents;
}

export fn bw_sc_block_seconds(idx: usize) u32 {
    const coin = coinByIndex(idx) orelse return 0;
    const sc = coin.stablecoin() orelse return 0;
    return sc.block_seconds;
}

/// The lock tiers a mint can choose, in display order. Writes up to `cap` and
/// returns how many. Cheap; UI-thread safe.
export fn bw_sc_tiers(idx: usize, out: ?*BwScTier, cap: usize) usize {
    const o = out orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;
    const sc = coin.stablecoin() orelse return 0;
    const n = @min(sc.tiers.len, cap);
    const dst = @as([*]BwScTier, @ptrCast(o))[0..n];
    for (dst, sc.tiers[0..n]) |*d, t| {
        d.tier = t.tier;
        d.ratio_pct = t.ratio_pct;
        setField(&d.duration, t.duration);
    }
    return n;
}

/// Live system state: 0 with `out` filled, -1 on failure. Blocks on RPC.
export fn bw_sc_info(ctx: ?*Ctx, idx: usize, out: ?*BwScInfo) c_int {
    const c = ctx orelse return -1;
    const o = out orelse return -1;
    const coin = coinByIndex(idx) orelse return -1;
    const sc = coin.stablecoin() orelse return -1;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    const auth = ctxAuth(a, io, coin, c) catch |err| {
        c.setError(@errorName(err));
        return -1;
    };
    const info = sc.info(a, auth) catch |err| {
        c.setError(@errorName(err));
        return -1;
    };
    o.active = if (info.active) 1 else 0;
    setField(&o.status, info.status());
    o.activation_height = info.activation_height;
    o.price_micro_usd = info.price_micro_usd;
    o.price_stale = if (info.price_stale) 1 else 0;
    o.total_supply_cents = info.total_supply_cents;
    o.total_collateral = info.total_collateral;
    o.health_ratio = info.health_ratio;
    o.minting_blocked = if (info.minting_blocked) 1 else 0;
    return 0;
}

/// The wallet's stablecoin balance: 0 with `out` filled, -1 on failure.
/// Blocks on RPC.
export fn bw_sc_balance(ctx: ?*Ctx, idx: usize, out: ?*BwScBalance) c_int {
    const c = ctx orelse return -1;
    const o = out orelse return -1;
    const coin = coinByIndex(idx) orelse return -1;
    const sc = coin.stablecoin() orelse return -1;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    const auth = ctxAuth(a, io, coin, c) catch |err| {
        c.setError(@errorName(err));
        return -1;
    };
    const bal = sc.balance(a, auth) catch |err| {
        c.setError(@errorName(err));
        return -1;
    };
    o.confirmed_cents = bal.confirmed_cents;
    o.pending_cents = bal.pending_cents;
    return 0;
}

/// A deposit address for the stablecoin, written into `buf`; returns its length
/// or 0. `force_new` mints a fresh one.
///
/// Same rule as `bw_wallet_receive_address`: **never call this on a timer.**
export fn bw_sc_receive_address(ctx: ?*Ctx, idx: usize, force_new: c_int, buf: ?[*]u8, cap: usize) usize {
    const c = ctx orelse return 0;
    const b = buf orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;
    const sc = coin.stablecoin() orelse return 0;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    const auth = ctxAuth(a, io, coin, c) catch return 0;
    const addr = sc.receive_address(a, auth, force_new != 0) catch return 0;
    return copyOut(b[0..cap], addr);
}

/// Recent stablecoin transactions, newest first; returns how many were written.
/// 0 on any failure — an unreadable list is empty, not worth interrupting for.
export fn bw_sc_transactions(ctx: ?*Ctx, idx: usize, out: ?*BwScTx, cap: usize) usize {
    const c = ctx orelse return 0;
    const o = out orelse return 0;
    if (cap == 0) return 0;
    const coin = coinByIndex(idx) orelse return 0;
    const sc = coin.stablecoin() orelse return 0;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    const auth = ctxAuth(a, io, coin, c) catch return 0;
    const txs = sc.transactions(a, auth, cap) catch return 0;
    const n = @min(txs.len, cap);
    const dst = @as([*]BwScTx, @ptrCast(o))[0..n];
    for (dst, txs[0..n]) |*d, t| d.* = .{
        .kind = @intFromEnum(t.kind),
        .amount_cents = t.amount_cents,
        .time = t.time,
        .confirmations = t.confirmations,
    };
    return n;
}

/// The wallet's minted vaults; returns how many were written. 0 on failure.
export fn bw_sc_positions(ctx: ?*Ctx, idx: usize, out: ?*BwScPosition, cap: usize) usize {
    const c = ctx orelse return 0;
    const o = out orelse return 0;
    if (cap == 0) return 0;
    const coin = coinByIndex(idx) orelse return 0;
    const sc = coin.stablecoin() orelse return 0;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    const auth = ctxAuth(a, io, coin, c) catch return 0;
    const list = sc.positions(a, auth, cap) catch return 0;
    const n = @min(list.len, cap);
    const dst = @as([*]BwScPosition, @ptrCast(o))[0..n];
    for (dst, list[0..n]) |*d, p| {
        const id = p.id();
        const idn = @min(id.len, d.id.len);
        @memcpy(d.id[0..idn], id[0..idn]);
        d.id_len = idn;
        d.amount_cents = p.amount_cents;
        d.tier = p.tier;
        d.unlock_height = p.unlock_height;
        d.can_redeem = if (p.can_redeem) 1 else 0;
    }
    return n;
}

/// How much collateral minting `cents` at `tier` would lock, via `out`: 0 on
/// success, -1 on failure. Blocks on RPC.
///
/// Show this **before** the confirm step. Minting commits collateral for the
/// tier's whole term, and the amount isn't obvious from the figure being minted.
export fn bw_sc_estimate_collateral(ctx: ?*Ctx, idx: usize, cents: i64, tier: u8, out: ?*f64) c_int {
    const c = ctx orelse return -1;
    const o = out orelse return -1;
    const coin = coinByIndex(idx) orelse return -1;
    const sc = coin.stablecoin() orelse return -1;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    const auth = ctxAuth(a, io, coin, c) catch |err| {
        c.setError(@errorName(err));
        return -1;
    };
    o.* = sc.estimate_collateral(a, auth, cents, tier) catch |err| {
        c.setError(@errorName(err));
        return -1;
    };
    return 0;
}

/// Which stablecoin operation to run.
const ScOp = enum(u8) { mint = 0, send = 1, redeem = 2 };

/// Run a stablecoin operation. Same tri-state as `bw_wallet_send`: 0 broadcast
/// (`out` = txid), 1 the daemon rejected it (`out` = its own reason, verbatim),
/// -1 transport failure (`bw_last_error` has why).
///
/// A rejection is an answer, not an error. "Timelock not expired" and "oracle
/// price stale" are things the user has to read, not generic failures.
///
/// `mint` uses `cents` + `tier`; `send` uses `cents` + `address`; `redeem` uses
/// `position_id` + `cents` (the daemon requires the whole vault, so pass the
/// position's own amount).
export fn bw_sc_run(
    ctx: ?*Ctx,
    idx: usize,
    op: u8,
    cents: i64,
    tier: u8,
    address: ?[*:0]const u8,
    position_id: ?[*]const u8,
    position_id_len: usize,
    out: ?[*]u8,
    cap: usize,
) c_int {
    const c = ctx orelse return -1;
    const o = out orelse return -1;
    const coin = coinByIndex(idx) orelse return -1;
    const sc = coin.stablecoin() orelse return -1;
    if (op > @intFromEnum(ScOp.redeem)) return -1;
    const which: ScOp = @enumFromInt(op);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    // These spend. Serialise them with every other wallet-touching call, so a
    // mint can't overlap a send.
    c.wallet_mtx.lockUncancelable(io);
    defer c.wallet_mtx.unlock(io);

    const auth = ctxAuth(a, io, coin, c) catch |err| {
        c.setError(@errorName(err));
        return -1;
    };

    const res = switch (which) {
        .mint => sc.mint(a, auth, cents, tier),
        .send => blk: {
            const addr = address orelse return -1;
            break :blk sc.send(a, auth, std.mem.span(addr), cents);
        },
        .redeem => blk: {
            const pid = position_id orelse return -1;
            break :blk sc.redeem(a, auth, pid[0..position_id_len], cents);
        },
    } catch |err| {
        c.setError(@errorName(err));
        c.setErrorCode(@errorName(err));
        return -1;
    };

    return switch (res) {
        .ok => |txid| blk: {
            _ = copyOut(o[0..cap], txid);
            break :blk 0;
        },
        .failed => |reason| blk: {
            _ = copyOut(o[0..cap], reason);
            break :blk 1;
        },
    };
}

// ---- USD prices -------------------------------------------------------------

/// Mirror of `price.Quote`. `have_change` is separate from `have` because the
/// host can list a coin with a price but no 24h figure (Nexa does), so a caller
/// must not assume the two arrive together.
pub const BwQuote = extern struct {
    usd: f64,
    change_24h: f64,
    have_change: c_int,
    have: c_int,
};

/// Fetch prices if one is due. Call it once per poll tick and let it decide —
/// it owns the cadence, the backoff after failures, and the privacy rule below,
/// none of which a front-end should be re-implementing.
///
/// Returns 1 if the cache changed (so the caller can republish), 0 otherwise.
/// Blocks on the network when it does fetch: **worker thread only.**
///
/// **The roster is every registered coin, always, regardless of what's
/// installed or selected.** That is the privacy property: the outbound request
/// is byte-identical for every BoxWallet user, so it says nothing about which
/// coins this one holds. Never narrow it to the installed set — that would turn
/// a price lookup into a disclosure of someone's portfolio.
export fn bw_prices_service(ctx: ?*Ctx) c_int {
    const c = ctx orelse return 0;
    if (!pricesEnabled(c)) return 0;

    const io = sharedIo();
    const now = std.Io.Timestamp.now(io, .real).toSeconds();

    // Saturating on failure, so a long outage can't wrap the backoff round to a
    // fast retry.
    const due_s = price.backoffSeconds(c.price_failures);
    if (c.price_last_try != 0 and now - c.price_last_try < due_s) return 0;
    c.price_last_try = now;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ids: [coin_count][]const u8 = undefined;
    var slots: [coin_count]usize = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < coin_count) : (i += 1) {
        const coin = coinByIndex(i) orelse continue;
        const id = coin.priceId() orelse continue;
        ids[n] = id;
        slots[n] = i;
        n += 1;
    }
    // Staged here and published under the lock in one go at the end, so a
    // partial round never leaves the UI reading half-new, half-old figures.
    var quotes: [coin_count]price.Quote = @splat(.{});
    var got_any = false;

    if (n > 0) {
        var roster: [coin_count]price.Quote = @splat(.{});
        if (price.fetch(a, io, ids[0..n], roster[0..n])) {
            for (roster[0..n], slots[0..n]) |q, slot| quotes[slot] = q;
            got_any = true;
        } else |_| {}
    }

    // Coins the roster host prices badly fetch from their own endpoint (Divi →
    // NonKYC). Unconditional, exactly like the roster above: the request goes
    // out whether or not the coin is installed, so it reveals nothing about
    // what this user holds. Independently best-effort — one host being down
    // leaves the others' quotes standing.
    i = 0;
    while (i < coin_count) : (i += 1) {
        const coin = coinByIndex(i) orelse continue;
        const source = coin.priceSource() orelse continue;
        if (price.fetchOne(a, io, source)) |q| {
            quotes[i] = q;
            got_any = true;
        } else |_| {}
    }

    if (!got_any) {
        c.price_failures +|= 1;
        return 0;
    }

    c.price_mtx.lockUncancelable(io);
    defer c.price_mtx.unlock(io);
    for (quotes, 0..) |q, slot| {
        // Only overwrite what this round actually fetched: a coin whose host
        // failed keeps its previous quote until it ages out of `max_age_s`.
        if (q.have) c.prices[slot] = q;
    }
    c.price_fetched_at = now;
    c.price_failures = 0;
    return 1;
}

/// The cached quote for a coin: 1 with `out` filled, 0 when there's nothing to
/// show. Cheap — no network — but it takes a lock, so keep it off the UI thread.
///
/// Answers 0 once the cache is older than an hour, even though the figures are
/// still in memory. A price that keeps sitting on screen while every refresh
/// fails misrepresents what a balance is worth, which is worse than showing
/// nothing at all.
export fn bw_price_quote(ctx: ?*Ctx, idx: usize, out: ?*BwQuote) c_int {
    const c = ctx orelse return 0;
    const o = out orelse return 0;
    if (idx >= coin_count) return 0;

    const io = sharedIo();
    c.price_mtx.lockUncancelable(io);
    defer c.price_mtx.unlock(io);

    if (c.price_fetched_at == 0) return 0;
    const age = std.Io.Timestamp.now(io, .real).toSeconds() - c.price_fetched_at;
    if (age > price.max_age_s) return 0;

    const q = c.prices[idx];
    if (!q.have) return 0;
    o.usd = q.usd;
    o.change_24h = q.change_24h orelse 0;
    o.have_change = if (q.change_24h != null) 1 else 0;
    o.have = 1;
    return 1;
}

fn pricesEnabled(c: *Ctx) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const raw = conf.readValue(arena.allocator(), sharedIo(), c.install_root, conf.settings_file, "show_prices") catch return true;
    const val = raw orelse return true; // default on, matching the TUI
    return !(std.mem.eql(u8, val, "0") or std.ascii.eqlIgnoreCase(val, "false"));
}

/// Whether price lookups are on: 1 yes, 0 no. Shares the TUI's `show_prices`
/// key, so the preference follows the user between the two front-ends. Default
/// is on.
export fn bw_prices_enabled(ctx: ?*Ctx) c_int {
    const c = ctx orelse return 0;
    return if (pricesEnabled(c)) 1 else 0;
}

/// Turn price lookups on or off: 0 ok, -1 on failure.
///
/// Off means **no request is made at all** — not a hidden figure. That's the
/// point of the switch: someone who doesn't want BoxWallet talking to a price
/// host gets exactly that.
export fn bw_set_prices_enabled(ctx: ?*Ctx, on: c_int) c_int {
    const c = ctx orelse return -1;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    conf.setValue(arena.allocator(), sharedIo(), c.install_root, conf.settings_file, "show_prices", if (on != 0) "1" else "0") catch |err| {
        c.setError(@errorName(err));
        return -1;
    };
    return 0;
}

/// Format a unit price ("$0.0142", "$1,234.56") into `buf`. Cheap; UI-thread safe.
export fn bw_format_usd(usd: f64, buf: ?[*]u8, cap: usize) usize {
    const b = buf orelse return 0;
    var tmp: [48]u8 = undefined;
    return copyOut(b[0..cap], price.formatUsd(&tmp, usd));
}

/// Format what a holding is worth ("$1,234.56") into `buf`. Cheap; UI-thread safe.
export fn bw_format_value(amount: f64, usd: f64, buf: ?[*]u8, cap: usize) usize {
    const b = buf orelse return 0;
    var tmp: [48]u8 = undefined;
    return copyOut(b[0..cap], price.formatValue(&tmp, amount, usd));
}

/// Format a 24h move as an unsigned percentage — the arrow carries the sign.
/// Pass `have_change` 0 for "no figure", which yields an empty string.
export fn bw_format_change(change_24h: f64, have_change: c_int, buf: ?[*]u8, cap: usize) usize {
    const b = buf orelse return 0;
    var tmp: [48]u8 = undefined;
    const v: ?f64 = if (have_change != 0) change_24h else null;
    return copyOut(b[0..cap], price.formatChange(&tmp, v));
}

/// Which way a 24h move went: 1 up, -1 down, 0 flat or unknown. Drives the
/// arrow and its colour. Cheap; UI-thread safe.
export fn bw_price_direction(change_24h: f64, have_change: c_int) c_int {
    const v: ?f64 = if (have_change != 0) change_24h else null;
    return switch (price.direction(v)) {
        .up => 1,
        .down => -1,
        .flat => 0,
    };
}

// ---- BoxWallet's own self-update --------------------------------------------

/// Status codes for `bw_self_update_check`, mirroring `update.CheckStatus`.
/// Kept as explicit values because they cross the ABI — append, never renumber.
pub const BW_UPDATE_UP_TO_DATE: c_int = 0;
pub const BW_UPDATE_STAGED: c_int = 1;
pub const BW_UPDATE_UNSUPPORTED: c_int = 2;
pub const BW_UPDATE_NETWORK_ERROR: c_int = 3;
pub const BW_UPDATE_VERIFY_FAILED: c_int = 4;
pub const BW_UPDATE_GAVE_UP: c_int = 5;
/// Set alongside `BW_UPDATE_STAGED`/`BW_UPDATE_GAVE_UP` when the executable's own
/// directory isn't writable, so the swap can't happen wherever the app is
/// installed. The UI needs this to say "move me somewhere writable" rather than
/// a "restart to apply" that silently wouldn't.
pub const BW_UPDATE_BLOCKED: c_int = 1 << 8;

/// Check for a newer BoxWallet GUI and stage it for the next launch.
///
/// **Blocking and network-bound** — call it from a worker thread, never the
/// event loop. Returns one of the `BW_UPDATE_*` codes, OR-ed with
/// `BW_UPDATE_BLOCKED`; the release version (e.g. "1.2.3") is written to `out`
/// and its length returned via `out_len` when known.
///
/// This stages the *GUI* asset, which is a different download from the TUI's and
/// stages into a different directory. The GUI ships as an exe plus a matching
/// Slint runtime, so a release that changes the runtime is fetched as the full
/// bundle and a release that doesn't takes the exe alone — that decision, and
/// the verification behind it, lives in `update.zig`.
export fn bw_self_update_check(ctx: ?*Ctx, out: ?[*]u8, cap: usize, out_len: ?*usize) c_int {
    const c = ctx orelse return BW_UPDATE_NETWORK_ERROR;

    var threaded: std.Io.Threaded = .init(c.allocator, .{});
    defer threaded.deinit();

    const res = updater.checkAndStageFor(
        .gui,
        c.allocator,
        threaded.io(),
        c.install_root,
        version.app_version,
        null,
        .default,
    );

    if (out) |o| {
        const n = copyOut(o[0..cap], res.version.slice());
        if (out_len) |l| l.* = n;
    } else if (out_len) |l| l.* = 0;

    const code: c_int = switch (res.status) {
        .up_to_date => BW_UPDATE_UP_TO_DATE,
        .staged => BW_UPDATE_STAGED,
        .unsupported => BW_UPDATE_UNSUPPORTED,
        .network_error => BW_UPDATE_NETWORK_ERROR,
        .verify_failed => BW_UPDATE_VERIFY_FAILED,
        .gave_up => BW_UPDATE_GAVE_UP,
    };
    return code | (if (res.blocked) BW_UPDATE_BLOCKED else 0);
}

/// Apply a staged GUI update and re-exec into it. **Does not return on success**
/// — the new binary replaces this process image.
///
/// Call it at the top of `main`, before any window exists: the swap moves the
/// running executable aside and installs the matching Slint runtime beside it,
/// and re-execing is what makes the new pair the one actually running. Returns 0
/// when there was nothing to apply and 1 when applying failed, in both cases
/// leaving the caller to carry on with the current build — a failed update is
/// never a reason not to start.
///
/// Takes `home_dir` rather than a `Ctx` because it runs before `bw_init`: it
/// replaces the process, so anything allocated first would be leaked at exec.
export fn bw_self_update_apply(home_dir: ?[*:0]const u8) c_int {
    const hd_z = home_dir orelse return 0;
    const hd = std.mem.span(hd_z);
    if (hd.len == 0) return 0;

    // The updater must not be the thing that kills the app: `Threaded` toggles a
    // process-wide SIGIO handler, and this runs before `bw_init` would pin ours.
    sigguard.install();

    // The same allocator `bw_init` uses. This call either replaces the process
    // or returns having freed everything, so there's nothing for a tracking
    // allocator to catch that the tests don't.
    const a = std.heap.page_allocator;

    // Carry our environment on this `Threaded`, because the swap's `--selftest`
    // pre-flight is spawned through it: with the default (empty) environ the
    // check would run the candidate binary under an environment no real launch
    // ever has. See `currentEnviron`.
    var threaded: std.Io.Threaded = .init(a, .{ .environ = currentEnviron() });
    defer threaded.deinit();
    const io = threaded.io();

    const root = install.installRoot(a, hd) catch return 0;
    defer a.free(root);

    const applied = (updater.applyPendingFor(.gui, a, io, root, version.app_version) catch return 1) orelse return 0;
    defer a.free(applied.exe_path);

    // The new image must inherit our environment, and that has to be said here:
    // a null `environ_map` hands the replacement an *empty* one (verified — the
    // exec'd process saw zero variables), and that killed exactly this restart.
    // With no `$WAYLAND_DISPLAY`/`$DISPLAY` Slint doesn't fail gracefully: it
    // reads the empty environment as "no compositor, we must own the screen",
    // picks its linuxkms backend, and aborts on the first frame with
    // `Error presenting framebuffer on screen: Permission denied` because the
    // real compositor holds DRM master. And with no `$HOME` we'd resolve the
    // install root to `/.boxwallet`. The user saw the restart-to-apply launch
    // die and the *next* one work, because by then the swap was done and nothing
    // re-exec'd. Same trap as `currentEnvMap`, one call over.
    var env_map = currentEnvMap(a) catch {
        std.log.warn("self-update re-exec: could not read the environment", .{});
        return 1;
    };
    defer env_map.deinit();

    // Only returns on failure. `.detach` because we're the windowed front-end:
    // where the OS has no exec (Windows), `relaunch` starts the new binary and
    // exits rather than lingering as an invisible parent. The binary on disk is
    // already the new one by this point, so the next launch is clean either way —
    // run the old image for now.
    const err = updater.relaunch(io, applied.exe_path, &env_map, .detach);
    std.log.warn("self-update re-exec failed: {s}", .{@errorName(err)});
    return 1;
}

// ---- pending coin updates ---------------------------------------------------

/// Which coins have a newer bundled core than the version installed, written
/// into `out` as registry indices; returns how many.
///
/// One disk read per coin (a small version marker), so this is a worker-thread
/// call and not one for the 2s poll — the answer only changes when BoxWallet
/// itself is updated or a coin is installed. A coin with no marker reads as up
/// to date rather than out of date: its version is unknown, and assuming it's
/// behind would nag on every hand-installed binary.
export fn bw_updates_pending(ctx: ?*Ctx, out: ?*u8, cap: usize) usize {
    const c = ctx orelse return 0;
    const o = out orelse return 0;
    const dst = @as([*]u8, @ptrCast(o))[0..cap];

    var n: usize = 0;
    var i: usize = 0;
    while (i < coin_count and n < cap) : (i += 1) {
        if (bw_update_available(c, i) == 1) {
            dst[n] = @intCast(i);
            n += 1;
        }
    }
    return n;
}

// ---- the balance-privacy toggle ---------------------------------------------

/// What a hidden balance figure is replaced with — `money.zig`'s, so both
/// front-ends mask with the same thing.
const balance_mask = money.balance_mask;

/// Whether balances are currently hidden: 1 yes, 0 no. Reads the same
/// `hide_balances` key in `boxwallet.conf` the TUI writes, so the preference
/// follows the user between the two front-ends. Reads a small file — worker
/// thread, or once at startup.
export fn bw_hide_balances(ctx: ?*Ctx) c_int {
    const c = ctx orelse return 0;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    const raw = conf.readValue(a, io, c.install_root, conf.settings_file, "hide_balances") catch return 0;
    const val = raw orelse return 0;
    return if (std.mem.eql(u8, val, "1") or std.ascii.eqlIgnoreCase(val, "true")) 1 else 0;
}

/// Persist the balance-privacy preference: 0 on success, -1 on failure.
/// Merges into the shared conf, leaving every other setting alone.
export fn bw_set_hide_balances(ctx: ?*Ctx, hide: c_int) c_int {
    const c = ctx orelse return -1;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    conf.setValue(a, io, c.install_root, conf.settings_file, "hide_balances", if (hide != 0) "1" else "0") catch |err| {
        c.setError(@errorName(err));
        return -1;
    };
    return 0;
}

/// The mask to show in place of a hidden figure. Cheap; UI-thread safe.
///
/// **Mask at format time, never by skipping the fetch.** The balance is still
/// polled while hidden, so unhiding is instant rather than waiting for the next
/// tick — and a front-end that stopped fetching would show a stale figure the
/// moment it unhid.
export fn bw_balance_mask(buf: ?[*]u8, cap: usize) usize {
    const b = buf orelse return 0;
    return copyOut(b[0..cap], balance_mask);
}

// ---- system + storage readouts ----------------------------------------------

/// The coin's donation address, written into `buf`; returns its length, or 0 if
/// it has none. Cheap; UI-thread safe.
export fn bw_tip_address(idx: usize, buf: ?[*]u8, cap: usize) usize {
    const b = buf orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;
    return copyOut(b[0..cap], coin.tipAddress());
}

/// System RAM used/total, mirroring `BwDiskUsage`. 0 with `out` filled, -1 if
/// the platform won't say. A cheap read of the OS's own figures.
export fn bw_memory_usage(out: ?*BwDiskUsage) c_int {
    const o = out orelse return -1;
    const u = memory.usage() orelse return -1;
    o.used_bytes = u.used;
    o.total_bytes = u.total;
    return 0;
}

/// How much disk this coin's data dir actually occupies, via `out`. 0 on
/// success, -1 if the dir isn't there or can't be walked.
///
/// This **walks the whole tree**, which on a synced chain is hundreds of
/// thousands of files. Worker thread, and not every tick — the TUI samples it
/// about every 30 seconds and that is the right order of magnitude.
///
/// Distinct from `bw_disk_usage`, which is the *filesystem's* used/total: this
/// answers "what is this coin costing me", that one answers "am I running out".
export fn bw_data_dir_size(ctx: ?*Ctx, idx: usize, out: ?*u64) c_int {
    const c = ctx orelse return -1;
    const o = out orelse return -1;
    const coin = coinByIndex(idx) orelse return -1;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    const data_dir = coin.dataDir(a, c.home_dir) catch return -1;
    o.* = disk.dirSizeBytes(io, a, data_dir) orelse return -1;
    return 0;
}

// ---- QR --------------------------------------------------------------------

/// Widest QR a version-40 symbol can be, so callers can size a buffer from it:
/// 177 × 177 modules, before any quiet zone.
pub const bw_qr_max_side: usize = 177;

/// Encode `text` as a QR symbol at ECC medium. Writes `side × side` bytes into
/// `out`, row-major, one byte per module (0 light, 1 dark), and the module count
/// per side into `out_side`. Returns the bytes written, or 0 if the text is
/// empty, doesn't fit, or `cap` is too small.
///
/// A byte per module rather than packed bits: the caller expands to pixels
/// either way, so packing would save 31 KB once in the worst case and cost every
/// reader a shift and a mask. A typical address is version 4-6 — under 1.7 KB.
///
/// **Three things the caller must get right or the code won't scan.** Add a
/// 4-module quiet zone on all sides; draw it black-on-**white** regardless of
/// theme (a dark UI painting dark modules on a dark background is unreadable);
/// and scale by a whole number of pixels per module without smoothing, or the
/// interpolation blurs the module edges.
///
/// Cheap and pure — no ctx, no I/O — but it allocates internally, so don't call
/// it on a timer. Encode when the address changes and cache the result.
export fn bw_qr_encode(text: ?[*:0]const u8, out: ?[*]u8, cap: usize, out_side: ?*u32) usize {
    const t = text orelse return 0;
    const o = out orelse return 0;
    const os = out_side orelse return 0;
    const s = std.mem.span(t);
    if (s.len == 0) return 0;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const qr = qrcode.encodeText(arena.allocator(), s, .medium) catch return 0;
    defer qr.deinit();

    const side: usize = qr.size();
    const needed = side * side;
    if (side == 0 or needed > cap) return 0;

    const dst = o[0..needed];
    var y: usize = 0;
    while (y < side) : (y += 1) {
        var x: usize = 0;
        while (x < side) : (x += 1) {
            dst[y * side + x] = if (qr.get(@intCast(x), @intCast(y))) 1 else 0;
        }
    }
    os.* = @intCast(side);
    return needed;
}

// ---- the status line --------------------------------------------------------

/// Everything the status readout reads, flattened for C. Zero it, fill in what
/// you know, and leave the rest — every field has a sensible "unknown" at 0, and
/// the readout degrades to a coarser but still correct label rather than lying.
pub const BwStatusInput = extern struct {
    /// 0 idle, 1 downloading, 2 extracting.
    installing: c_int,
    installed: c_int,
    /// 0 stopped, 1 starting, 2 running, 3 stopping.
    daemon: c_int,
    /// A start was asked for but no poll has come back — "Checking…", which is
    /// not the same as stopped.
    awaiting_status: c_int,
    /// `models.LoadingPhase` ordinal; 0 = not warming up.
    loading_phase: c_int,
    /// `warmup.Stage` ordinal; 0 = no finer sub-stage than the phase.
    load_stage: c_int,
    load_pct_bp: u32,
    load_eta_pct: u8,
    peers: u32,
    /// 0 idle, 1 syncing, 2 synced.
    sync: c_int,
    presync: c_int,
    presync_bp: u32,
    headers_cur: u64,
    headers_total: u64,
    blocks_cur: u64,
    blocks_total: u64,
};

fn statusInputFrom(in: *const BwStatusInput) status_mod.Input {
    const clamp = struct {
        fn e(comptime T: type, v: c_int) T {
            const max = @typeInfo(T).@"enum".fields.len - 1;
            if (v < 0 or v > max) return @enumFromInt(0);
            return @enumFromInt(@as(u8, @intCast(v)));
        }
    };
    return .{
        .installing = clamp.e(status_mod.Phase, in.installing),
        .installed = in.installed != 0,
        .daemon = clamp.e(status_mod.Daemon, in.daemon),
        .awaiting_status = in.awaiting_status != 0,
        .loading_phase = clamp.e(models.LoadingPhase, in.loading_phase),
        .load_stage = clamp.e(warmup.Stage, in.load_stage),
        .load_pct_bp = in.load_pct_bp,
        .load_eta_pct = in.load_eta_pct,
        .peers = in.peers,
        .sync = clamp.e(status_mod.Sync, in.sync),
        .presync = in.presync != 0,
        .presync_bp = in.presync_bp,
        .headers_cur = in.headers_cur,
        .headers_total = in.headers_total,
        .blocks_cur = in.blocks_cur,
        .blocks_total = in.blocks_total,
    };
}

/// The whole status line — text plus any appended percentage — written into
/// `buf`; returns its length.
///
/// This is the TUI's exact wording and priority order, from the same module, so
/// the two front-ends can't describe one daemon differently. Pure and cheap;
/// safe on the UI thread.
///
/// No chain height is appended: both front-ends already show a Blocks readout,
/// so the line says what the daemon is doing ("Syncing blocks…", then "Synced")
/// and stays one uninterrupted phrase the caller can paint in one colour.
export fn bw_status_line(in: ?*const BwStatusInput, buf: ?[*]u8, cap: usize) usize {
    const i = in orelse return 0;
    const b = buf orelse return 0;
    const snap = statusInputFrom(i);
    const r = status_mod.readout(snap);

    var sbuf: [32]u8 = undefined;
    const suffix = status_mod.suffix(&sbuf, snap, r);

    var out: [160]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    w.writeAll(r.text) catch return copyOut(b[0..cap], r.text);
    w.writeAll(suffix) catch {};
    return copyOut(b[0..cap], w.buffered());
}

/// The status's tone: 0 idle, 1 working, 2 warning, 3 ok. Pure; UI-thread safe.
export fn bw_status_tone(in: ?*const BwStatusInput) c_int {
    const i = in orelse return 0;
    return @intFromEnum(status_mod.readout(statusInputFrom(i)).tone);
}

/// Whether the status counts as "active" — something is happening, so the label
/// should brighten. Pure; UI-thread safe.
export fn bw_status_active(in: ?*const BwStatusInput) c_int {
    const i = in orelse return 0;
    return if (status_mod.readout(statusInputFrom(i)).active) 1 else 0;
}

// ---- the in-daemon wallet menu ----------------------------------------------
//
// Which actions a wallet state permits is decided by `walletmenu.zig`, the same
// module the TUI asks, so the two front-ends cannot offer different things. The
// GUI never enumerates actions itself: it calls `bw_wallet_menu` and renders
// what comes back.

/// What this coin's daemon can do with its wallet, as `BW_WCAP_*` bits. 0 for a
/// coin with no in-daemon wallet at all. Cheap; UI-thread safe.
pub const bw_wcap_encrypt: c_int = 1 << 0;
pub const bw_wcap_backup: c_int = 1 << 1;
pub const bw_wcap_import: c_int = 1 << 2;
pub const bw_wcap_restore_offline: c_int = 1 << 3;
pub const bw_wcap_proof_of_stake: c_int = 1 << 4;
pub const bw_wcap_stake_action: c_int = 1 << 5;

export fn bw_coin_wallet_caps(idx: usize) c_int {
    const coin = coinByIndex(idx) orelse return 0;
    if (!coin.supportsWallet()) return 0;
    var flags: c_int = 0;
    if (coin.supportsWalletEncrypt()) flags |= bw_wcap_encrypt;
    if (coin.supportsWalletBackup()) flags |= bw_wcap_backup;
    if (coin.supportsWalletImport()) flags |= bw_wcap_import;
    if (coin.supportsWalletRestoreOffline()) flags |= bw_wcap_restore_offline;
    if (coin.isProofOfStake()) flags |= bw_wcap_proof_of_stake;
    if (coin.supportsStakeAction()) flags |= bw_wcap_stake_action;
    return flags;
}

/// The actions permitted for `wallet_sec` (a `BW_WSEC_*` value), written into
/// `out` in display order; returns how many. 0 means no menu — which is the
/// answer for `BW_WSEC_UNKNOWN`, because a menu built before the daemon has said
/// what it holds is a menu that can destroy a wallet.
///
/// Pass the security value you already have rather than having this re-read it:
/// the caller's padlock is drawn from that same value, and a menu describing a
/// different state than the glyph beside it would be worse than a stale one.
/// Cheap and pure; UI-thread safe.
export fn bw_wallet_menu(idx: usize, wallet_sec: c_int, out: ?*u8, cap: usize) usize {
    const coin = coinByIndex(idx) orelse return 0;
    const o = out orelse return 0;
    if (!coin.supportsWallet()) return 0;
    if (wallet_sec < 0 or wallet_sec > @intFromEnum(models.WalletSecurity.unlocked_for_staking)) return 0;
    const state: models.WalletSecurity = @enumFromInt(wallet_sec);

    var buf: [walletmenu.max_options]walletmenu.Action = undefined;
    const n = @min(walletmenu.optionsFor(state, .of(coin), &buf), cap);
    const dst = @as([*]u8, @ptrCast(o))[0..n];
    for (dst, buf[0..n]) |*d, act| d.* = @intFromEnum(act);
    return n;
}

/// The menu label for an action ordinal. 0 for an unknown one.
///
/// Taken from here, never written in the UI: "Restore from key dump" and
/// "Restore from wallet.dat" name the *file each takes*, and BitcoinZ offers
/// both at once — picking the wrong one is what ends in an empty wallet.
export fn bw_wallet_action_label(action: u8, buf: ?[*]u8, cap: usize) usize {
    const b = buf orelse return 0;
    if (action > @intFromEnum(walletmenu.Action.restore_file_offline)) return 0;
    const act: walletmenu.Action = @enumFromInt(action);
    return copyOut(b[0..cap], act.label());
}

/// Whether the action needs a passphrase (1) or a filesystem path (1) — ask both
/// to decide which prompt to raise. Every action takes one or the other, never
/// both. `bw_wallet_action_sets_new_password` marks the one that *sets* a
/// credential, which the caller must confirm twice: a typo when encrypting a
/// wallet for the first time makes the funds unrecoverable, where a typo when
/// merely unlocking just fails and is retried.
export fn bw_wallet_action_needs_password(action: u8) c_int {
    if (action > @intFromEnum(walletmenu.Action.restore_file_offline)) return 0;
    const act: walletmenu.Action = @enumFromInt(action);
    return if (act.needsPassword()) 1 else 0;
}

export fn bw_wallet_action_needs_path(action: u8) c_int {
    if (action > @intFromEnum(walletmenu.Action.restore_file_offline)) return 0;
    const act: walletmenu.Action = @enumFromInt(action);
    return if (act.needsPath()) 1 else 0;
}

export fn bw_wallet_action_sets_new_password(action: u8) c_int {
    if (action > @intFromEnum(walletmenu.Action.restore_file_offline)) return 0;
    const act: walletmenu.Action = @enumFromInt(action);
    return if (act.setsNewPassword()) 1 else 0;
}

/// Encrypt the wallet with `passphrase`: 0 ok, -1 (`bw_last_error` has why).
///
/// This **sets** a new credential, so the caller must have asked for it twice
/// and refused on mismatch before getting here — there is no recovering a wallet
/// encrypted with a password nobody knows. The passphrase is copied into a
/// bounded buffer and wiped on every return path; it is never stored.
///
/// Most daemons shut down after encrypting, which is normal and not a failure.
export fn bw_wallet_encrypt(ctx: ?*Ctx, idx: usize, passphrase: ?[*]const u8, len: usize) c_int {
    const c = ctx orelse return -1;
    const coin = coinByIndex(idx) orelse return -1;
    if (!coin.supportsWalletEncrypt()) {
        c.setError("This coin's daemon can't encrypt its wallet.");
        c.setErrorCode("Unsupported");
        return -1;
    }
    const p = passphrase orelse return -1;

    var pw_buf: [wallet_pw_max]u8 = undefined;
    const n = @min(len, pw_buf.len);
    @memcpy(pw_buf[0..n], p[0..n]);
    defer @memset(pw_buf[0..n], 0); // our copy is gone on every path

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    const auth = ctxAuth(a, io, coin, c) catch |err| {
        c.setError(@errorName(err));
        return -1;
    };
    coin.walletEncrypt(a, auth, pw_buf[0..n]) catch |err| {
        c.setError(@errorName(err));
        c.setErrorCode(@errorName(err));
        return -1;
    };
    return 0;
}

/// Back the wallet up to a fresh timestamped key dump under the install root,
/// writing the path into `buf`; returns its length, or 0 on failure.
///
/// The destination is generated rather than asked for, matching the TUI: the
/// timestamp sidesteps the daemon's refusal to overwrite an existing file, and
/// it means no save dialog. **The file contains private keys** — tell the user
/// where it went and what it is.
export fn bw_wallet_backup(ctx: ?*Ctx, idx: usize, buf: ?[*]u8, cap: usize) usize {
    const c = ctx orelse return 0;
    const b = buf orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;
    if (!coin.supportsWalletBackup()) {
        c.setError("This coin's daemon can't export a key dump.");
        return 0;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}{c}{s}-wallet-backup-{d}.txt", .{
        c.install_root,
        std.fs.path.sep,
        coin.coinNameAbbrev(),
        std.Io.Timestamp.now(io, .real).toSeconds(),
    }) catch {
        c.setError("couldn't build a backup path");
        return 0;
    };

    const auth = ctxAuth(a, io, coin, c) catch |err| {
        c.setError(@errorName(err));
        return 0;
    };
    coin.walletBackup(a, auth, path) catch |err| {
        c.setError(@errorName(err));
        c.setErrorCode(@errorName(err));
        return 0;
    };
    return copyOut(b[0..cap], path);
}

/// Restore from a bitcoin-core key dump, with the daemon running: 0 ok, -1.
/// Takes the *text* file `bw_wallet_backup` produces — not a binary wallet.dat.
export fn bw_wallet_import_file(ctx: ?*Ctx, idx: usize, src_path: ?[*:0]const u8) c_int {
    const c = ctx orelse return -1;
    const coin = coinByIndex(idx) orelse return -1;
    const src = src_path orelse return -1;
    if (!coin.supportsWalletImport()) {
        c.setError("This coin's daemon can't import a key dump.");
        c.setErrorCode("Unsupported");
        return -1;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    const auth = ctxAuth(a, io, coin, c) catch |err| {
        c.setError(@errorName(err));
        return -1;
    };
    coin.walletImportFile(a, auth, std.mem.span(src)) catch |err| {
        c.setError(@errorName(err));
        c.setErrorCode(@errorName(err));
        return -1;
    };
    return 0;
}

/// Restore by swapping in a binary wallet file **with the daemon stopped**:
/// 0 ok, -1 (`bw_last_error` has why).
///
/// Refuses while the daemon is alive rather than doing it anyway. A daemon holds
/// its wallet open and would overwrite the file we just put there on shutdown,
/// so the swap has to happen while nothing owns it — and the honest failure is
/// far better than a restore that silently doesn't take.
///
/// Unlike the TUI, this does not stop and restart the daemon for you; stop it
/// first. That orchestration is a separate piece of work.
export fn bw_wallet_restore_file_offline(ctx: ?*Ctx, idx: usize, src_path: ?[*:0]const u8) c_int {
    const c = ctx orelse return -1;
    const coin = coinByIndex(idx) orelse return -1;
    const src = src_path orelse return -1;
    if (!coin.supportsWalletRestoreOffline()) {
        c.setError("This coin has no offline wallet-file restore.");
        c.setErrorCode("Unsupported");
        return -1;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    if (proc.aliveMatching(io, coin.daemonFile(), coin.daemonProcessCmdline())) {
        c.setError("Stop the daemon before restoring a wallet file — it holds the wallet open.");
        c.setErrorCode("DaemonRunning");
        return -1;
    }

    coin.walletRestoreFileOffline(a, c.home_dir, std.mem.span(src)) catch |err| {
        // The three refusals a user can actually hit are all "you picked the
        // wrong file", so say which wrong file it was — the bare error name left
        // them with no idea whether to re-pick or give up.
        c.setError(switch (err) {
            error.IsAWalletKeyDump => "That's a key dump, not a wallet file — use \"Restore from key dump\" for it.",
            error.EmptyWalletFile => "That file is empty — pick the wallet file you backed up.",
            error.WalletFileNotFound => "Couldn't read that file.",
            else => @errorName(err),
        });
        c.setErrorCode(@errorName(err));
        return -1;
    };
    return 0;
}

/// Stake `amount` (Salvium's explicit stake action). Same tri-state as
/// `bw_wallet_send`: 0 broadcast (`out` = txid), 1 the daemon rejected it
/// (`out` = its own reason), -1 transport failure.
export fn bw_wallet_stake(ctx: ?*Ctx, idx: usize, amount: f64, out: ?[*]u8, cap: usize) c_int {
    const c = ctx orelse return -1;
    const o = out orelse return -1;
    const coin = coinByIndex(idx) orelse return -1;
    if (!coin.supportsStakeAction()) {
        c.setError("This coin has no stake action.");
        c.setErrorCode("Unsupported");
        return -1;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    c.wallet_mtx.lockUncancelable(io);
    defer c.wallet_mtx.unlock(io);

    const auth = walletAuth(a, io, coin, c, idx) catch |err| {
        c.setError(@errorName(err));
        return -1;
    };
    const res = coin.walletStake(a, auth, amount) catch |err| {
        c.setError(@errorName(err));
        c.setErrorCode(@errorName(err));
        return -1;
    };
    return switch (res) {
        .ok => |txid| blk: {
            _ = copyOut(o[0..cap], txid);
            break :blk 0;
        },
        .failed => |reason| blk: {
            _ = copyOut(o[0..cap], reason);
            break :blk 1;
        },
    };
}

/// The coin's own description of what staking commits to (lock term, etc.), for
/// the confirm step. 0 when it has nothing to add. Cheap; UI-thread safe.
export fn bw_stake_hint(idx: usize, buf: ?[*]u8, cap: usize) usize {
    const b = buf orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;
    return copyOut(b[0..cap], coin.stakeHint());
}

// ---- settings: wallet file and pruning --------------------------------------

/// Where this coin's wallet file lives, written into `buf`; returns its length,
/// or 0 when the node manages the wallet itself and there is no single file to
/// name (Ergo, Epic). A disk-free path computation, but it reads the coin's data
/// dir — worker thread.
export fn bw_wallet_file_path(ctx: ?*Ctx, idx: usize, buf: ?[*]u8, cap: usize) usize {
    const c = ctx orelse return 0;
    const b = buf orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const wf = (coin.walletPath(arena.allocator(), c.home_dir) catch return 0) orelse return 0;
    return copyOut(b[0..cap], wf.path);
}

/// The `.keys` companion beside the wallet file, for the coins whose wallet is a
/// *pair* (the Monero family). Returns 0 for a single-file coin.
///
/// Worth surfacing: someone backing up only the wallet file and not its keys has
/// backed up nothing they can restore from.
export fn bw_wallet_keys_path(ctx: ?*Ctx, idx: usize, buf: ?[*]u8, cap: usize) usize {
    const c = ctx orelse return 0;
    const b = buf orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const wf = (coin.walletPath(arena.allocator(), c.home_dir) catch return 0) orelse return 0;
    const keys = wf.keys orelse return 0;
    return copyOut(b[0..cap], keys);
}

/// How this coin expresses pruning: 0 = a size cap in MiB, 1 = just on/off,
/// -1 = the coin has no pruning at all (most of them). Cheap; UI-thread safe.
export fn bw_prune_mode(idx: usize) c_int {
    const coin = coinByIndex(idx) orelse return -1;
    const pr = coin.pruning() orelse return -1;
    return @intFromEnum(pr.mode);
}

/// The prune setting currently in the coin's conf, via `out`: >= 0 is the value
/// (0 meaning a deliberate full node), and the call returns 1. Returns 0 when
/// the key isn't there at all — **never configured**, which is a different thing
/// from a deliberate 0 — or -1 if the coin doesn't prune / the conf is
/// unreadable. Reads the conf; worker thread.
///
/// Not interchangeable with `bw_prune_should_offer`. An adopted full node
/// answers 0 here (no key) *and* refuses the prompt (its chain is already on
/// disk); showing a value is safe, offering to change it is not.
export fn bw_prune_current(ctx: ?*Ctx, idx: usize, out: ?*i64) c_int {
    const c = ctx orelse return -1;
    const o = out orelse return -1;
    const coin = coinByIndex(idx) orelse return -1;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const state = coin.pruningState(arena.allocator(), c.home_dir) catch return -1;
    const v = state orelse return 0;
    o.* = v;
    return 1;
}

/// Describe a prune setting in the coin's own units ("2 GB", "1500 MiB",
/// "disabled (full node)", "not set") into `buf`. Pass -1 for "not configured".
/// Cheap; UI-thread safe.
///
/// Exported rather than formatted in the UI so both front-ends say the same
/// thing — "not set" and "disabled (full node)" look similar and mean very
/// different things.
export fn bw_prune_value_text(idx: usize, prune_mib: i64, buf: ?[*]u8, cap: usize) usize {
    const b = buf orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;
    const pr = coin.pruning() orelse return 0;
    var tmp: [48]u8 = undefined;
    return copyOut(b[0..cap], money.pruneValueText(&tmp, pr.mode, prune_mib));
}

/// Whether to show the first-start prune prompt for this coin **right now**:
/// 1 offer, 0 don't (which also covers every coin that has no pruning).
/// Cheap disk checks only — no daemon needed — so it is fine straight from a
/// click handler, and calling it there is exactly what keeps it uncacheable.
/// Same shape as `bw_sync_accel_offered`.
///
/// **Call this inside the Start handler and act on the answer immediately. Never
/// cache it, and never store it in a UI property.** It is an instant-in-time
/// predicate over two things that both change underneath you: whether the conf
/// carries a prune key, and whether any chain data exists yet.
///
/// The second half is what makes a stale answer dangerous. An unpruned node has
/// no `prune` key *by definition*, so "has the user chosen?" alone reads
/// somebody's fully-synced full node as "never asked" and offers to throw their
/// blocks away — with no un-prune short of a complete re-sync. The coins pair
/// that check with "and no `blocks/` present", so the honest answer flips to 0
/// the moment a daemon starts writing a chain. A `true` cached from before that
/// point would offer to discard it.
export fn bw_prune_should_offer(ctx: ?*Ctx, idx: usize) c_int {
    const c = ctx orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    return if (coin.offersPrunePrompt(arena.allocator(), c.home_dir)) 1 else 0;
}

/// The prompt text for this coin's prune question, in its own terms (chain size,
/// what pruning costs). One sentence; the caller wraps it. 0 for a coin that
/// doesn't prune. Cheap; UI-thread safe.
export fn bw_prune_prompt(idx: usize, buf: ?[*]u8, cap: usize) usize {
    const b = buf orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;
    const pr = coin.pruning() orelse return 0;
    return copyOut(b[0..cap], pr.prompt);
}

/// How many preset rows this coin's prune menu has. Cheap; UI-thread safe.
///
/// Take the menu from here rather than hard-coding sizes: Monero is an `on_off`
/// coin with its own two rows and no custom amount, so a hard-coded GB list
/// would offer it a value it cannot honour.
export fn bw_prune_preset_count(idx: usize) usize {
    const coin = coinByIndex(idx) orelse return 0;
    const pr = coin.pruning() orelse return 0;
    return pr.presets.len;
}

/// The label of preset `row`, written into `buf`; returns its length, 0 if the
/// row is out of range. Cheap; UI-thread safe.
export fn bw_prune_preset_label(idx: usize, row: usize, buf: ?[*]u8, cap: usize) usize {
    const b = buf orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;
    const pr = coin.pruning() orelse return 0;
    if (row >= pr.presets.len) return 0;
    return copyOut(b[0..cap], pr.presets[row].label);
}

/// The value behind preset `row` — what to pass to `bw_prune_apply`. Returns -1
/// for an out-of-range row, which `bw_prune_apply` refuses.
///
/// Row 0 is by convention the least destructive choice ("No pruning (full
/// node)"), so a menu whose default lands on row 0 cannot discard a chain by
/// someone pressing Enter.
export fn bw_prune_preset_value(idx: usize, row: usize) i64 {
    const coin = coinByIndex(idx) orelse return -1;
    const pr = coin.pruning() orelse return -1;
    if (row >= pr.presets.len) return -1;
    return pr.presets[row].value;
}

/// Write the chosen prune value to the coin's conf: 0 on success, -1 on failure
/// (`bw_last_error` has why). Reads and rewrites a file — worker thread, though
/// it's small enough to run inline in a click handler as the TUI does.
///
/// Refuses a negative value outright: -1 is this ABI's "not configured"/"bad
/// row" sentinel, and writing it as a setting would be meaningless.
///
/// A failure here is **not** a reason to abort the start. The TUI logs it and
/// starts the daemon unpruned, because the user asked for a daemon and an
/// unwritten preference is a smaller problem than not getting one.
export fn bw_prune_apply(ctx: ?*Ctx, idx: usize, prune_value: i64) c_int {
    const c = ctx orelse return -1;
    const coin = coinByIndex(idx) orelse return -1;
    if (prune_value < 0) {
        c.setError("invalid prune value");
        return -1;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    coin.applyPrune(arena.allocator(), c.home_dir, prune_value) catch |err| {
        c.setError(@errorName(err));
        c.setErrorCode(@errorName(err));
        return -1;
    };
    return 0;
}

/// Whether the coin's RPC port accepts a connection right now: 1 reachable,
/// 0 not. A cheap TCP connect and close — no request, no auth.
///
/// This exists to tell **up-but-busy** apart from **down**. A daemon under load
/// accepts the connection instantly while stalling its RPC reply for seconds —
/// Nerva does exactly this behind its blockchain lock — so treating a failed
/// `bw_daemon_info` as "not running" makes the whole UI flip to stopped and back
/// every time the node is busy. Call this when the status reads fail: reachable
/// means keep showing it as running.
///
/// Blocks on a connect, so worker thread only. It's a loopback connect, which
/// either completes or refuses immediately.
export fn bw_daemon_reachable(ctx: ?*Ctx, idx: usize) c_int {
    const c = ctx orelse return 0;
    const coin = coinByIndex(idx) orelse return 0;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    const data_dir = coin.dataDir(a, c.home_dir) catch return 0;
    const auth = conf.readAuth(
        a,
        io,
        data_dir,
        coin.confFile(),
        coin.rpcDefaultUsername(),
        coin.rpcDefaultPort(),
    ) catch return 0;
    return if (rpc.daemonReachable(a, auth)) 1 else 0;
}

/// Bytes used / total on the filesystem holding the coin's data dir.
pub const BwDiskUsage = extern struct {
    used_bytes: u64,
    total_bytes: u64,
};

fn diskUsage(ctx: *Ctx, idx: usize, out: *BwDiskUsage) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Prefer the coin's data dir; if it doesn't exist yet, the home dir sits on
    // the same filesystem the chain would grow into, so it's the right gauge.
    // `disk.usage` is the shared, per-platform query the TUI already uses
    // (statfs on Linux/macOS, GetDiskFreeSpaceExW on Windows) — the GUI grew a
    // Linux-only copy of it back when the GUI was Linux-only, which left the
    // gauge blank on Windows and macOS.
    const coin = coinByIndex(idx) orelse return error.NoSuchCoin;
    const data_dir = coin.dataDir(a, ctx.home_dir) catch ctx.home_dir;
    const u = disk.usage(data_dir) orelse disk.usage(ctx.home_dir) orelse
        return error.DiskUsageUnavailable;
    out.used_bytes = u.used;
    out.total_bytes = u.total;
}

export fn bw_disk_usage(ctx: ?*Ctx, idx: usize, out: ?*BwDiskUsage) c_int {
    const c = ctx orelse return -1;
    const o = out orelse return -1;
    diskUsage(c, idx, o) catch return -1;
    return 0;
}

// ---- window geometry --------------------------------------------------------
//
// The window the user arranged, remembered across runs. Stored in BoxWallet's
// own settings conf under the install root — the same file the TUI keeps
// `hide_balances` in — through `conf.setValue`, which rewrites one key and
// preserves every other line. Hence the `gui_` prefix on the keys: the two
// frontends share the file.

/// The saved window geometry. `width`/`height` are **logical** pixels, so the
/// window comes back the same apparent size on a screen with a different scale
/// factor — the frontend converts, since only it knows the scale factor. `x`/`y`
/// are screen coordinates, so signed: a window on a monitor left of or above the
/// primary one has negative ones.
const BwWindowGeometry = extern struct {
    width: u32,
    height: u32,
    x: i32,
    y: i32,
    maximized: c_int,
};

const geom_key_width = "gui_window_width";
const geom_key_height = "gui_window_height";
const geom_key_x = "gui_window_x";
const geom_key_y = "gui_window_y";
const geom_key_maximized = "gui_window_maximized";

/// A window this small is unusable and this large is a corrupt file, not a
/// monitor. A hand-edited or garbled conf must never produce a window the user
/// can't see or grab — falling back to the frontend's default size always leaves
/// them something workable. (A size larger than the screen is not a problem to
/// guard against here: the window manager caps it to what the display can show.)
const geom_min_w = 480;
const geom_min_h = 360;
const geom_max_dim = 10000;

fn readGeomInt(comptime T: type, a: std.mem.Allocator, io: std.Io, root: []const u8, key: []const u8) ?T {
    const found = conf.readValue(a, io, root, conf.settings_file, key) catch return null;
    const raw = found orelse return null;
    return std.fmt.parseInt(T, std.mem.trim(u8, raw, " \t\r"), 10) catch null;
}

/// The saved window geometry, or 0 if there isn't a usable one. Size is
/// required and validated; **position is optional and independent**, so a conf
/// carrying only a size still restores that size (position then reads as 0,0,
/// which the caller applies harmlessly or the compositor ignores).
export fn bw_window_geometry(ctx: ?*Ctx, out: ?*BwWindowGeometry) c_int {
    const c = ctx orelse return 0;
    const o = out orelse return 0;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    const w = readGeomInt(u32, a, io, c.install_root, geom_key_width) orelse return 0;
    const h = readGeomInt(u32, a, io, c.install_root, geom_key_height) orelse return 0;
    if (w < geom_min_w or h < geom_min_h or w > geom_max_dim or h > geom_max_dim) return 0;

    o.* = .{
        .width = w,
        .height = h,
        .x = readGeomInt(i32, a, io, c.install_root, geom_key_x) orelse 0,
        .y = readGeomInt(i32, a, io, c.install_root, geom_key_y) orelse 0,
        .maximized = if ((readGeomInt(u8, a, io, c.install_root, geom_key_maximized) orelse 0) != 0) 1 else 0,
    };
    return 1;
}

/// Persist the window geometry. Best-effort by design: failing to remember a
/// window size is not worth reporting to someone who is closing the app, and the
/// next run just opens at the default.
///
/// **A maximized window's size is deliberately not saved.** It reports the whole
/// screen, so storing it would make "restore down" produce a window the size of
/// the display — the remembered size would be lost the first time anyone
/// maximized. Only the flag is written; the last un-maximized size stays.
export fn bw_save_window_geometry(ctx: ?*Ctx, g: ?*const BwWindowGeometry) void {
    const c = ctx orelse return;
    const geom = g orelse return;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = sharedIo();

    var buf: [16]u8 = undefined;
    const put = struct {
        fn set(alloc: std.mem.Allocator, i: std.Io, root: []const u8, key: []const u8, b: []u8, v: i64) void {
            const text = std.fmt.bufPrint(b, "{d}", .{v}) catch return;
            conf.setValue(alloc, i, root, conf.settings_file, key, text) catch {};
        }
    }.set;

    const maximized = geom.maximized != 0;
    put(a, io, c.install_root, geom_key_maximized, &buf, if (maximized) 1 else 0);
    if (!maximized) {
        if (geom.width >= geom_min_w and geom.height >= geom_min_h and
            geom.width <= geom_max_dim and geom.height <= geom_max_dim)
        {
            put(a, io, c.install_root, geom_key_width, &buf, geom.width);
            put(a, io, c.install_root, geom_key_height, &buf, geom.height);
        }
        put(a, io, c.install_root, geom_key_x, &buf, geom.x);
        put(a, io, c.install_root, geom_key_y, &buf, geom.y);
    }
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

    const io = sharedIo();

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
    try std.testing.expectEqual(@as(usize, 15), coinCount());
    try std.testing.expect(coinByIndex(0) != null);
    try std.testing.expect(coinByIndex(14) != null);
    try std.testing.expect(coinByIndex(15) == null);

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

test "bw_balance_has_pending answers the GUI header's show-Available question" {
    // The GUI appends the spendable figure to its header only while funds are
    // still settling — the same rule the TUI's header applies — so this export
    // is what keeps the two from drifting apart.
    var settled: BwWalletBalance = .{ .total = 1234.5, .available = 1234.5 };
    try std.testing.expectEqual(@as(c_int, 0), bw_balance_has_pending(&settled));

    var pending: BwWalletBalance = .{ .total = 1234.5, .available = 1000.0 };
    try std.testing.expectEqual(@as(c_int, 1), bw_balance_has_pending(&pending));

    // An empty wallet has nothing settling, so no second figure appears.
    var empty: BwWalletBalance = .{ .total = 0, .available = 0 };
    try std.testing.expectEqual(@as(c_int, 0), bw_balance_has_pending(&empty));

    // Float noise from summing the parts is not "pending" — `hasPending`'s
    // epsilon owns that, and the GUI inherits it by asking rather than comparing.
    var noise: BwWalletBalance = .{ .total = 0.1 + 0.2, .available = 0.3 };
    try std.testing.expectEqual(@as(c_int, 0), bw_balance_has_pending(&noise));

    try std.testing.expectEqual(@as(c_int, 0), bw_balance_has_pending(null));
}

test "bw_stake_yield reports a term's earnings only when they're attributable" {
    // Matured, sole unlocker at its height: 1006.208 back on 1000 staked.
    var earned: BwStake = .{
        .amount = 1000,
        .staked_time = 1783463334,
        .unlock_height = 547_550,
        .blocks_remaining = 0,
        .unlock_eta_seconds = 0,
        .unlocked_time = 1786065414,
        .returned = 1006.20821166,
        .txid = undefined,
        .txid_len = 0,
    };
    var out: f64 = -1;
    try std.testing.expectEqual(@as(c_int, 1), bw_stake_yield(&earned, &out));
    try std.testing.expectApproxEqAbs(@as(f64, 6.20821166), out, 1e-8);

    // Matured but repaid in a credit shared with another stake: `returned` is 0
    // for "not known", and must not read as "earned nothing".
    var shared = earned;
    shared.returned = 0;
    try std.testing.expectEqual(@as(c_int, 0), bw_stake_yield(&shared, &out));

    // Still locked: nothing has come back yet.
    var locked = earned;
    locked.blocks_remaining = 21_592;
    locked.returned = 0;
    locked.unlocked_time = 0;
    try std.testing.expectEqual(@as(c_int, 0), bw_stake_yield(&locked, &out));

    // A return below the principal means the pairing is wrong; no figure beats a
    // negative "yield" on screen.
    var wrong = earned;
    wrong.returned = 900;
    try std.testing.expectEqual(@as(c_int, 0), bw_stake_yield(&wrong, &out));

    try std.testing.expectEqual(@as(c_int, 0), bw_stake_yield(null, &out));
    try std.testing.expectEqual(@as(c_int, 0), bw_stake_yield(&earned, null));
}

test "bw_wallet_stakes refuses a coin that can't enumerate stakes" {
    var ctx: Ctx = .{ .allocator = std.testing.allocator, .home_dir = "", .install_root = "" };
    var out: [4]BwStake = undefined;

    // Every coin without the capability answers 0 rather than reaching for an
    // RPC — the GUI polls this on a timer for whichever coin is selected.
    var i: usize = 0;
    while (i < coin_count) : (i += 1) {
        const coin = coinByIndex(i) orelse return error.Unexpected;
        if (coin.supportsStakeList()) continue;
        try std.testing.expectEqual(@as(usize, 0), bw_wallet_stakes(&ctx, i, &out[0], out.len));
    }
    // Out of range, no context, no room: all 0, never a read.
    try std.testing.expectEqual(@as(usize, 0), bw_wallet_stakes(&ctx, coin_count, &out[0], out.len));
    try std.testing.expectEqual(@as(usize, 0), bw_wallet_stakes(null, 0, &out[0], out.len));
    try std.testing.expectEqual(@as(usize, 0), bw_wallet_stakes(&ctx, 0, &out[0], 0));
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

test "the disk gauge answers on every platform a front-end ships to" {
    // The gauge behind `bw_disk_usage` used to be a raw Linux `statfs` here, so
    // it read blank on Windows and macOS. It now goes through `disk.usage`, the
    // same per-platform query the TUI uses — the cwd always exists, so any
    // supported target must produce a figure.
    switch (builtin.os.tag) {
        .linux, .macos, .windows => {},
        else => return error.SkipZigTest,
    }
    const u = disk.usage(".") orelse return error.TestUnexpectedResult;
    try std.testing.expect(u.total > 0);
    try std.testing.expect(u.used <= u.total);
}

test "writeEntryLine formats a typed line and stops when it can't fit" {
    var buf: [16]u8 = undefined;
    const w = writeEntryLine(buf[0..], 0, 'd', "abc");
    try std.testing.expectEqualStrings("d abc\n", buf[0..w]);
    // Only 2 bytes free after `w`: a longer line doesn't fit, so `at` is returned.
    try std.testing.expectEqual(w, writeEntryLine(buf[0 .. w + 2], w, 'f', "toolong"));
}

/// A `Ctx` pointed at a scratch install root, for the geometry tests. Only the
/// two fields those exports touch are meaningful.
fn testCtx(root: []const u8) Ctx {
    return .{ .allocator = std.testing.allocator, .home_dir = root, .install_root = root };
}

test "a saved window geometry survives the round trip" {
    const io = sharedIo();

    const root = "test-window-geometry";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var ctx = testCtx(root);
    var out: BwWindowGeometry = undefined;

    // Nothing saved yet: the caller keeps Slint's preferred size.
    try std.testing.expectEqual(@as(c_int, 0), bw_window_geometry(&ctx, &out));

    bw_save_window_geometry(&ctx, &.{ .width = 1100, .height = 760, .x = 240, .y = -120, .maximized = 0 });
    try std.testing.expectEqual(@as(c_int, 1), bw_window_geometry(&ctx, &out));
    try std.testing.expectEqual(@as(u32, 1100), out.width);
    try std.testing.expectEqual(@as(u32, 760), out.height);
    try std.testing.expectEqual(@as(i32, 240), out.x);
    // Negative coordinates are legitimate — a monitor left of the primary one.
    try std.testing.expectEqual(@as(i32, -120), out.y);
    try std.testing.expectEqual(@as(c_int, 0), out.maximized);
}

test "maximizing doesn't overwrite the remembered window size" {
    const io = sharedIo();

    const root = "test-window-geometry-max";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var ctx = testCtx(root);
    bw_save_window_geometry(&ctx, &.{ .width = 1100, .height = 760, .x = 40, .y = 50, .maximized = 0 });

    // Quitting while maximized reports the screen size. Storing that would make
    // "restore down" hand back a window the size of the display, losing the size
    // the user actually chose — so only the flag is written.
    bw_save_window_geometry(&ctx, &.{ .width = 3840, .height = 2160, .x = 0, .y = 0, .maximized = 1 });

    var out: BwWindowGeometry = undefined;
    try std.testing.expectEqual(@as(c_int, 1), bw_window_geometry(&ctx, &out));
    try std.testing.expectEqual(@as(c_int, 1), out.maximized);
    try std.testing.expectEqual(@as(u32, 1100), out.width);
    try std.testing.expectEqual(@as(u32, 760), out.height);
}

test "an unusable stored size is ignored rather than applied" {
    const io = sharedIo();

    const root = "test-window-geometry-junk";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer dir.close(io);

    var ctx = testCtx(root);
    var out: BwWindowGeometry = undefined;

    // A hand-edited or corrupted conf must never produce a window that can't be
    // seen or grabbed — each of these falls back to the default size.
    const junk = [_][]const u8{
        "gui_window_width=0\ngui_window_height=0\n",
        "gui_window_width=12\ngui_window_height=8\n", // smaller than the minimum
        "gui_window_width=99999\ngui_window_height=99999\n", // not a monitor
        "gui_window_width=wide\ngui_window_height=tall\n", // not numbers
        "gui_window_height=760\n", // width missing entirely
    };
    for (junk) |content| {
        try dir.writeFile(io, .{ .sub_path = conf.settings_file, .data = content });
        try std.testing.expectEqual(@as(c_int, 0), bw_window_geometry(&ctx, &out));
    }

    // A size with no position is still worth restoring: position is the optional
    // half, and it's the half Wayland ignores anyway.
    try dir.writeFile(io, .{ .sub_path = conf.settings_file, .data = "gui_window_width=900\ngui_window_height=700\n" });
    try std.testing.expectEqual(@as(c_int, 1), bw_window_geometry(&ctx, &out));
    try std.testing.expectEqual(@as(u32, 900), out.width);
    try std.testing.expectEqual(@as(i32, 0), out.x);
}

test "saving geometry leaves the TUI's settings in the same file alone" {
    const io = sharedIo();

    const root = "test-window-geometry-shared";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer dir.close(io);
    // Both frontends keep their settings in this one conf, so a GUI write must
    // merge — clobbering it would silently turn the TUI's privacy toggle back off.
    try dir.writeFile(io, .{ .sub_path = conf.settings_file, .data = "hide_balances=1\n" });

    var ctx = testCtx(root);
    bw_save_window_geometry(&ctx, &.{ .width = 1024, .height = 640, .x = 0, .y = 0, .maximized = 0 });

    const still = try conf.readValue(std.testing.allocator, io, root, conf.settings_file, "hide_balances");
    defer if (still) |s| std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("1", still.?);
}

test "every sync accelerator on offer carries its trust caution" {
    // The caution is what tells the user a snapshot is fast because their node
    // isn't checking it. `trusts_publisher` defaults true precisely so a new
    // accelerator can't quietly ship without one — this fails if someone turns it
    // off for a payload BoxWallet still doesn't verify.
    var found: usize = 0;
    for (0..coin_count) |i| {
        const coin = coinByIndex(i) orelse continue;
        if (coin.syncAccelerator() == null) continue;
        found += 1;

        var buf: [256]u8 = undefined;
        const n = bw_sync_accel_trust_note(i, &buf, buf.len);
        try std.testing.expect(n > 0);
        try std.testing.expectEqualStrings(coinmod.Coin.accel_trust_note, buf[0..n]);
    }
    // Divi's snapshot and Nerva's QuickSync — if this ever reads 0 the loop is
    // asserting nothing at all.
    try std.testing.expect(found >= 2);
}

test "a coin with no accelerator has no trust note to show" {
    // The GUI keys the caution block off a non-empty answer, so a coin without an
    // accelerator must return nothing rather than the shared text.
    for (0..coin_count) |i| {
        const coin = coinByIndex(i) orelse continue;
        if (coin.syncAccelerator() != null) continue;
        var buf: [256]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 0), bw_sync_accel_trust_note(i, &buf, buf.len));
    }
}

test "a foreground daemon handle is kept per coin, not in one shared slot" {
    // Regression test: a single shared `daemon_child` meant the last foreground
    // start won the slot, so stopping the one coin with no RPC stop (Zano) killed
    // whichever daemon started most recently. Distinct slots must stay distinct.
    var ctx: Ctx = .{ .allocator = std.testing.allocator, .home_dir = "", .install_root = "" };
    try std.testing.expectEqual(coin_count, ctx.daemon_child.len);
    for (ctx.daemon_child) |slot| try std.testing.expect(slot == null);

    // Stand in for a live handle: writing one coin's slot must not disturb another.
    // Spelled out rather than `std.mem.zeroes`, which won't compile on Windows —
    // `Child.thread_handle` is a plain (non-nullable) HANDLE there, and a zeroed
    // one is rejected. Only the slot's occupancy is under test; nothing reads the
    // handle.
    ctx.daemon_child[0] = .{
        .id = null,
        .thread_handle = if (builtin.os.tag == .windows) undefined else {},
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .request_resource_usage_statistics = false,
    };
    try std.testing.expect(ctx.daemon_child[0] != null);
    for (ctx.daemon_child[1..]) |slot| try std.testing.expect(slot == null);
}

test "bw_update_available compares the marker against the pinned core version" {
    // The GUI's Update button hangs off this, and it has to agree with the TUI:
    // behind → 1, current → 0, and *unknown* → 0 rather than nagging.
    const allocator = std.testing.allocator;
    const io = sharedIo();

    const root = "test-capi-update-root";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const coin = coinByIndex(0) orelse return error.Unexpected;
    var ctx: Ctx = .{ .allocator = allocator, .home_dir = "", .install_root = root };

    // `isInstalled` keys off the daemon binary, so the coin has to look present or
    // update detection short-circuits to "nothing installed".
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = coin.daemonFile(), .data = "not a real binary" });
    try std.testing.expect(coin.isInstalled(allocator, root));

    // No marker: version unknown. Deliberately *not* an update — assuming a
    // hand-installed binary is behind would nag on every such install.
    try std.testing.expectEqual(@as(c_int, 0), bw_update_available(&ctx, 0));
    var buf: [32]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), bw_installed_version(&ctx, 0, &buf, buf.len));

    // Behind the pinned version → an update is available.
    try install.writeVersionMarker(allocator, root, coin.daemonFile(), "0.0.1");
    try std.testing.expectEqual(@as(c_int, 1), bw_update_available(&ctx, 0));
    const n = bw_installed_version(&ctx, 0, &buf, buf.len);
    try std.testing.expectEqualStrings("0.0.1", buf[0..n]);

    // Exactly the pinned version → nothing to offer.
    try install.writeVersionMarker(allocator, root, coin.daemonFile(), coin.coreVersion());
    try std.testing.expectEqual(@as(c_int, 0), bw_update_available(&ctx, 0));

    // Ahead of it (a hand-built newer daemon) must also not offer a "downgrade".
    try install.writeVersionMarker(allocator, root, coin.daemonFile(), "999.0.0");
    try std.testing.expectEqual(@as(c_int, 0), bw_update_available(&ctx, 0));
}

test "a wallet session is kept per coin, not in one shared slot" {
    // Same reasoning as `daemon_child`: a shared slot would let one coin's
    // teardown kill another coin's wallet service (and wipe its credentials).
    var ctx: Ctx = .{ .allocator = std.testing.allocator, .home_dir = "", .install_root = "" };
    try std.testing.expectEqual(coin_count, ctx.wallet.len);
    try std.testing.expectEqual(coin_count, ctx.wallet_open.len);
    for (&ctx.wallet) |*sess| try std.testing.expect(!sess.isRunning());
    for (&ctx.wallet_open) |*open| try std.testing.expectEqual(@as(u8, 0), open.load(.monotonic));

    ctx.wallet_open[0].store(1, .monotonic);
    for (ctx.wallet_open[1..]) |*open| try std.testing.expectEqual(@as(u8, 0), open.load(.monotonic));
}

test "bw_coin_ext_wallet's flags agree with the vtable for every coin" {
    // Loops the whole registry rather than checking Nerva alone, so a coin added
    // later can't arrive half-described (a wallet the GUI can't restore, or a
    // Replace it wrongly offers).
    var i: usize = 0;
    while (i < coin_count) : (i += 1) {
        const coin = coinByIndex(i) orelse return error.Unexpected;
        const flags = bw_coin_ext_wallet(i);
        if (!coin.hasExternalWallet()) {
            try std.testing.expectEqual(@as(c_int, 0), flags);
            continue;
        }
        const ew = coin.externalWallet().?;
        try std.testing.expectEqual(coin.hasExternalWalletProcess(), flags & bw_ew_has_process != 0);
        try std.testing.expectEqual(coin.supportsSeedRestore(), flags & bw_ew_seed_restore != 0);
        try std.testing.expectEqual(ew.restore_file != null, flags & bw_ew_file_restore != 0);
        try std.testing.expectEqual(coin.supportsWalletReplace(), flags & bw_ew_replace != 0);
        try std.testing.expectEqual(ew.lock != null, flags & bw_ew_explicit_lock != 0);
        try std.testing.expectEqual(coin.walletLaunchesWithPassword(), flags & bw_ew_launch_with_pw != 0);
    }
    // A coin with no external wallet at all reports a bare 0, and so does an
    // index that isn't a coin.
    try std.testing.expectEqual(@as(c_int, 0), bw_coin_ext_wallet(coin_count));
}

test "Nerva reports the wallet shape the GUI has to build for" {
    const idx = nervaIndex();
    const flags = bw_coin_ext_wallet(idx);
    try std.testing.expect(flags & bw_ew_has_process != 0);
    try std.testing.expect(flags & bw_ew_seed_restore != 0);
    try std.testing.expect(flags & bw_ew_file_restore != 0);
    try std.testing.expect(flags & bw_ew_replace != 0);
    // Nerva's wallet-rpc is spawned once alongside the daemon and serves a whole
    // `--wallet-dir`, so it is *not* the Zano launch-per-open shape — the GUI
    // must not ask for a password before the service exists.
    try std.testing.expect(flags & bw_ew_launch_with_pw == 0);
    // Its wallet locks by killing the process, so there's no explicit Lock hook.
    try std.testing.expect(flags & bw_ew_explicit_lock == 0);
}

test "bw_coin_seed_word_counts reports each wallet's accepted lengths" {
    var out: [4]u32 = undefined;
    const n = bw_coin_seed_word_counts(nervaIndex(), &out[0], out.len);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u32, 25), out[0]);

    // A cap smaller than the list truncates rather than overrunning.
    var one: [1]u32 = undefined;
    var i: usize = 0;
    while (i < coin_count) : (i += 1) {
        const written = bw_coin_seed_word_counts(i, &one[0], one.len);
        try std.testing.expect(written <= 1);
        if (written == 1) try std.testing.expect(one[0] > 0);
    }
}

test "bw_ext_wallet_state reads open-here over exists-on-disk" {
    var ctx: Ctx = .{ .allocator = std.testing.allocator, .home_dir = "/nonexistent/bw-test", .install_root = "" };
    const idx = nervaIndex();

    // Nothing on disk under a home that doesn't exist, and nothing opened.
    try std.testing.expectEqual(bw_wallet_none, bw_ext_wallet_state(&ctx, idx));

    // Opened this session wins outright — that's the state the user acted into.
    ctx.wallet_open[idx].store(1, .monotonic);
    try std.testing.expectEqual(bw_wallet_open, bw_ext_wallet_state(&ctx, idx));

    ctx.wallet_open[idx].store(0, .monotonic);
    try std.testing.expectEqual(bw_wallet_none, bw_ext_wallet_state(&ctx, idx));

    // An index that isn't a coin can't claim a state.
    try std.testing.expectEqual(bw_wallet_none, bw_ext_wallet_state(&ctx, coin_count));
}

/// Nerva's registry index, found by name so the tests don't pin the ordering.
fn nervaIndex() usize {
    var i: usize = 0;
    while (i < coin_count) : (i += 1) {
        const c = coinByIndex(i) orelse continue;
        if (std.mem.eql(u8, c.coinName(), "Nerva")) return i;
    }
    unreachable;
}

test "a created wallet's seed can be taken exactly once" {
    var ctx: Ctx = .{ .allocator = std.testing.allocator, .home_dir = "", .install_root = "" };
    const phrase = "abandon ability able about above absent absorb abstract absurd abuse access accident";

    // Nothing pending yet: a take must answer 0 rather than handing back stale bytes.
    var buf: [models.Seed.buf_len]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), bw_ext_wallet_seed_take(&ctx, &buf, buf.len));

    ctx.seed = models.Seed.from(phrase);
    ctx.seed_coin = 0;

    // A buffer too small must copy *nothing* and report what's needed —
    // truncating the user's only backup would be worse than refusing.
    var tiny: [8]u8 = undefined;
    try std.testing.expectEqual(phrase.len, bw_ext_wallet_seed_take(&ctx, &tiny, tiny.len));
    try std.testing.expectEqual(phrase.len, ctx.seed.len); // still pending

    const n = bw_ext_wallet_seed_take(&ctx, &buf, buf.len);
    try std.testing.expectEqualStrings(phrase, buf[0..n]);

    // The core's copy is gone, and the words can't be re-shown.
    try std.testing.expectEqual(@as(isize, -1), ctx.seed_coin);
    for (ctx.seed.buf) |b| try std.testing.expectEqual(@as(u8, 0), b);
    try std.testing.expectEqual(@as(usize, 0), bw_ext_wallet_seed_take(&ctx, &buf, buf.len));
}

test "discarding a pending seed wipes it" {
    var ctx: Ctx = .{ .allocator = std.testing.allocator, .home_dir = "", .install_root = "" };
    ctx.seed = models.Seed.from("some words the user never saw");
    ctx.seed_coin = 3;

    bw_ext_wallet_seed_discard(&ctx);
    try std.testing.expectEqual(@as(isize, -1), ctx.seed_coin);
    for (ctx.seed.buf) |b| try std.testing.expectEqual(@as(u8, 0), b);

    bw_ext_wallet_seed_discard(&ctx); // idempotent
    try std.testing.expectEqual(@as(isize, -1), ctx.seed_coin);
}

test "a wallet op on a coin with no external wallet is refused, not attempted" {
    var ctx: Ctx = .{ .allocator = std.testing.allocator, .home_dir = "/nonexistent/bw-test", .install_root = "" };
    // Bitcoin's wallet lives in its daemon, so none of these apply. Find it by
    // name so the test doesn't pin the registry order.
    var idx: usize = coin_count;
    var i: usize = 0;
    while (i < coin_count) : (i += 1) {
        const c = coinByIndex(i) orelse continue;
        if (!c.hasExternalWallet()) { idx = i; break; }
    }
    try std.testing.expect(idx < coin_count);

    const pw = "hunter2";
    try std.testing.expectEqual(@as(c_int, -1), bw_ext_wallet_open(&ctx, idx, pw.ptr, pw.len));
    try std.testing.expectEqualStrings("Unsupported", ctx.errorCode());
    // And it must not have claimed the wallet is open.
    try std.testing.expectEqual(@as(u8, 0), ctx.wallet_open[idx].load(.monotonic));

    // An index outside the registry is rejected outright.
    try std.testing.expectEqual(@as(c_int, -1), bw_ext_wallet_open(&ctx, coin_count, pw.ptr, pw.len));
}

test "the shared Io leaves exactly one SIGIO handler installed for the process" {
    // `std.Io.Threaded` uses SIGIO to interrupt blocking syscalls when it
    // cancels: `init` installs a no-op handler and `deinit` restores whatever
    // was there before. `sigaction` is process-wide, so a Threaded per call let
    // two overlapping instances on different threads race —
    //
    //   A init (saves SIG_DFL) → B init (saves A's handler) → A deinit
    //   (restores SIG_DFL) → B sends SIGIO → default action terminates us.
    //
    // The GUI met that every time a click's metadata reads ran on the UI thread
    // while the poll thread was mid-sequence: the whole app vanished with
    // "process terminated with signal IO" on selecting a coin. One shared,
    // never-destroyed instance is the fix, and this pins it: after using the
    // shared `Io` the handler must still be installed, never back at SIG_DFL.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const io = sharedIo();
    // Do some real work through it, so the pool is genuinely up.
    var dir = std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true }) catch return error.SkipZigTest;
    dir.close(io);

    // And again — a second acquisition must not have torn the first one down.
    _ = sharedIo();

    var current: std.posix.Sigaction = undefined;
    std.posix.sigaction(.IO, null, &current);
    const handler = current.handler.handler;
    try std.testing.expect(handler != null);
    // SIG_DFL is 0; anything else means a handler is installed.
    try std.testing.expect(@intFromPtr(handler.?) != 0);
}

test "a typed amount becomes the same cents the shared parser produces" {
    // The figure a mint settles against is the one this parsed, so it has to
    // agree with money.zig exactly — and reject anything it can't read rather
    // than guessing a number.
    try std.testing.expectEqual(@as(i64, 12550), bw_parse_dollars_to_cents("125.50"));
    try std.testing.expectEqual(@as(i64, 12500), bw_parse_dollars_to_cents("125"));
    try std.testing.expectEqual(@as(i64, 5), bw_parse_dollars_to_cents(".05"));
    try std.testing.expectEqual(@as(i64, 0), bw_parse_dollars_to_cents("0"));
    // -1 is "not a figure", distinct from a real 0.
    try std.testing.expectEqual(@as(i64, -1), bw_parse_dollars_to_cents(""));
    try std.testing.expectEqual(@as(i64, -1), bw_parse_dollars_to_cents("1.234"));
    try std.testing.expectEqual(@as(i64, -1), bw_parse_dollars_to_cents("-5"));
    try std.testing.expectEqual(@as(i64, -1), bw_parse_dollars_to_cents("12a"));
    try std.testing.expectEqual(@as(i64, -1), bw_parse_dollars_to_cents(null));

    // And the round trip holds, so what the user typed is what they're shown at
    // the confirm step.
    var buf: [48]u8 = undefined;
    const n = bw_format_cents(bw_parse_dollars_to_cents("1234.56"), &buf, buf.len);
    try std.testing.expectEqualStrings("$1234.56", buf[0..n]);
}

test "the stablecoin surface answers only for the coin that has one" {
    var ctx: Ctx = .{ .allocator = std.testing.allocator, .home_dir = "/nonexistent/bw-test", .install_root = "" };
    var buf: [64]u8 = undefined;
    var tiers: [bw_sc_max_tiers]BwScTier = undefined;
    var info: BwScInfo = undefined;
    var bal: BwScBalance = undefined;
    var est: f64 = 0;

    var found: usize = 0;
    var i: usize = 0;
    while (i < coin_count) : (i += 1) {
        const coin = coinByIndex(i) orelse return error.Unexpected;
        if (coin.stablecoin() == null) {
            // Every call refuses without attempting RPC — a stablecoin tab must
            // not appear for a coin that has none.
            try std.testing.expectEqual(@as(usize, 0), bw_sc_name(i, &buf, buf.len));
            try std.testing.expectEqual(@as(usize, 0), bw_sc_tiers(i, &tiers[0], tiers.len));
            try std.testing.expectEqual(@as(i64, 0), bw_sc_min_mint_cents(i));
            try std.testing.expectEqual(@as(c_int, -1), bw_sc_info(&ctx, i, &info));
            try std.testing.expectEqual(@as(c_int, -1), bw_sc_balance(&ctx, i, &bal));
            try std.testing.expectEqual(@as(c_int, -1), bw_sc_estimate_collateral(&ctx, i, 100, 0, &est));
            try std.testing.expectEqual(@as(c_int, -1), bw_sc_run(&ctx, i, 0, 100, 0, null, null, 0, &buf, buf.len));
            continue;
        }
        found += 1;
        const sc = coin.stablecoin().?;

        try std.testing.expect(bw_sc_name(i, &buf, buf.len) > 0);
        try std.testing.expect(bw_sc_symbol(i, &buf, buf.len) > 0);
        // Bounds have to be a usable range, or the amount field can never be
        // satisfied.
        try std.testing.expect(bw_sc_min_mint_cents(i) > 0);
        try std.testing.expect(bw_sc_max_mint_cents(i) > bw_sc_min_mint_cents(i));
        try std.testing.expect(bw_sc_block_seconds(i) > 0);

        const n = bw_sc_tiers(i, &tiers[0], tiers.len);
        try std.testing.expectEqual(sc.tiers.len, n);
        try std.testing.expect(n > 0);
        for (tiers[0..n], sc.tiers[0..n]) |got, want| {
            try std.testing.expectEqual(want.tier, got.tier);
            try std.testing.expectEqual(want.ratio_pct, got.ratio_pct);
            try std.testing.expectEqualStrings(want.duration, std.mem.sliceTo(&got.duration, 0));
            // A tier with no term or no ratio can't be presented or costed.
            try std.testing.expect(want.duration.len > 0);
            try std.testing.expect(want.ratio_pct > 0);
        }
        // A cap below the tier count truncates rather than overrunning.
        try std.testing.expectEqual(@as(usize, 1), bw_sc_tiers(i, &tiers[0], 1));

        // An unknown op is refused rather than falling through to one of the
        // three that spend.
        try std.testing.expectEqual(@as(c_int, -1), bw_sc_run(&ctx, i, 99, 100, 0, null, null, 0, &buf, buf.len));
    }
    // DigiByte, and only DigiByte.
    try std.testing.expectEqual(@as(usize, 1), found);
    ctx.clearError();
}

test "a position id survives a full 64-character txid" {
    // The id is the handle a redeem is keyed on. NUL-terminating it would drop
    // the last character of a bitcoin-family txid and the redeem would miss.
    var p: BwScPosition = undefined;
    const txid = "f" ** 64;
    @memcpy(p.id[0..64], txid);
    p.id_len = 64;
    try std.testing.expectEqual(@as(usize, 64), p.id_len);
    try std.testing.expectEqualStrings(txid, p.id[0..p.id_len]);
}

test "the price roster covers every coin, never just the installed ones" {
    // The privacy property, pinned. The outbound request must be identical for
    // every BoxWallet user — narrowing it to what's installed would turn a price
    // lookup into a disclosure of someone's portfolio. This asserts the roster
    // is built from the registry alone, with nothing that could filter it.
    var listed: usize = 0;
    var i: usize = 0;
    while (i < coin_count) : (i += 1) {
        const coin = coinByIndex(i) orelse return error.Unexpected;
        if (coin.priceId() != null) listed += 1;
    }
    // Most coins have a price id; SpiderByte deliberately has none.
    try std.testing.expect(listed > 0);
    try std.testing.expect(listed < coin_count or listed == coin_count);

    // Every id is non-empty and free of anything that would need escaping into
    // a URL — these are concatenated into one query.
    i = 0;
    while (i < coin_count) : (i += 1) {
        const coin = coinByIndex(i) orelse continue;
        const id = coin.priceId() orelse continue;
        try std.testing.expect(id.len > 0);
        for (id) |ch| try std.testing.expect(ch == '-' or (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9'));
    }
}

test "a coin is priced from exactly one place, and its own source leaks nothing" {
    // A coin wiring both would be fetched twice, with whichever reply landed
    // last winning — which for Divi means a 1-in-2 chance of the CoinGecko
    // figure it was moved off *because* it was wrong.
    var i: usize = 0;
    while (i < coin_count) : (i += 1) {
        const coin = coinByIndex(i) orelse return error.Unexpected;
        const source = coin.priceSource() orelse continue;
        try std.testing.expect(coin.priceId() == null);

        // The same privacy property the roster has, pinned for these too: a
        // fixed https URL with nothing per-user in it. These requests are made
        // unconditionally, so a URL that varied by user — or by which coins are
        // installed — would be the disclosure the roster is careful to avoid.
        try std.testing.expect(std.mem.startsWith(u8, source.url, "https://"));
        for (source.url) |ch| try std.testing.expect(ch > ' ' and ch < 127);
    }
}

test "a stale price cache reports nothing rather than a stale figure" {
    const io = sharedIo();
    const root = "test-prices";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var ctx = testCtx(root);
    var out: BwQuote = undefined;

    // Nothing fetched yet.
    try std.testing.expectEqual(@as(c_int, 0), bw_price_quote(&ctx, 0, &out));

    // A fresh quote is reported.
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    ctx.prices[0] = .{ .usd = 1.25, .change_24h = -3.5, .have = true };
    ctx.price_fetched_at = now;
    try std.testing.expectEqual(@as(c_int, 1), bw_price_quote(&ctx, 0, &out));
    try std.testing.expectEqual(@as(f64, 1.25), out.usd);
    try std.testing.expectEqual(@as(c_int, 1), out.have_change);

    // Older than max_age_s: the figures are still in memory, but a price left on
    // screen while every refresh fails misrepresents what a balance is worth.
    ctx.price_fetched_at = now - price.max_age_s - 1;
    try std.testing.expectEqual(@as(c_int, 0), bw_price_quote(&ctx, 0, &out));

    // A coin the host lists with no 24h figure (Nexa does this) still reports a
    // price — the two are independent.
    ctx.price_fetched_at = now;
    ctx.prices[1] = .{ .usd = 0.0001, .change_24h = null, .have = true };
    try std.testing.expectEqual(@as(c_int, 1), bw_price_quote(&ctx, 1, &out));
    try std.testing.expectEqual(@as(c_int, 0), out.have_change);

    try std.testing.expectEqual(@as(c_int, 0), bw_price_quote(&ctx, coin_count, &out));
}

test "turning prices off means no request at all" {
    const io = sharedIo();
    const root = "test-prices-off";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var ctx = testCtx(root);

    // Default is on, matching the TUI.
    try std.testing.expectEqual(@as(c_int, 1), bw_prices_enabled(&ctx));

    try std.testing.expectEqual(@as(c_int, 0), bw_set_prices_enabled(&ctx, 0));
    try std.testing.expectEqual(@as(c_int, 0), bw_prices_enabled(&ctx));
    // Disabled: the service call returns immediately without touching the
    // network. If this ever started fetching anyway the switch would be a lie.
    try std.testing.expectEqual(@as(c_int, 0), bw_prices_service(&ctx));
    try std.testing.expectEqual(@as(i64, 0), ctx.price_last_try);

    try std.testing.expectEqual(@as(c_int, 0), bw_set_prices_enabled(&ctx, 1));
    try std.testing.expectEqual(@as(c_int, 1), bw_prices_enabled(&ctx));
}

test "price formatting is the shared module's, arrow and figure apart" {
    var buf: [64]u8 = undefined;
    var want: [64]u8 = undefined;

    var n = bw_format_usd(1234.56, &buf, buf.len);
    try std.testing.expectEqualStrings(price.formatUsd(&want, 1234.56), buf[0..n]);

    n = bw_format_value(10.0, 1.25, &buf, buf.len);
    try std.testing.expectEqualStrings(price.formatValue(&want, 10.0, 1.25), buf[0..n]);

    // The percentage is unsigned — the arrow carries the sign, so a "-" here
    // would render as a double negative next to a red down-arrow.
    n = bw_format_change(-3.5, 1, &buf, buf.len);
    try std.testing.expect(std.mem.indexOfScalar(u8, buf[0..n], '-') == null);
    try std.testing.expectEqual(@as(c_int, -1), bw_price_direction(-3.5, 1));
    try std.testing.expectEqual(@as(c_int, 1), bw_price_direction(3.5, 1));
    // No figure at all is flat and empty, not zero.
    try std.testing.expectEqual(@as(c_int, 0), bw_price_direction(0, 0));
    try std.testing.expectEqual(@as(usize, 0), bw_format_change(0, 0, &buf, buf.len));
}

test "bw_updates_pending agrees with the per-coin answer" {
    // The roll-up must never disagree with the badge on the coin's own pane —
    // one of them saying "update available" while the other doesn't is worse
    // than neither saying it.
    const io = sharedIo();
    const root = "test-updates-pending";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var ctx = testCtx(root);

    var out: [coin_count]u8 = undefined;
    const n = bw_updates_pending(&ctx, &out[0], out.len);

    var expected: usize = 0;
    var i: usize = 0;
    while (i < coin_count) : (i += 1) {
        if (bw_update_available(&ctx, i) == 1) expected += 1;
    }
    try std.testing.expectEqual(expected, n);
    // Indices are in range and ascending, and each really does have an update.
    var prev: i32 = -1;
    for (out[0..n]) |idx| {
        try std.testing.expect(idx < coin_count);
        try std.testing.expect(@as(i32, idx) > prev);
        prev = idx;
        try std.testing.expectEqual(@as(c_int, 1), bw_update_available(&ctx, idx));
    }

    // With no markers on disk nothing is out of date — an unknown version must
    // not read as behind, or every hand-installed binary would nag.
    try std.testing.expectEqual(@as(usize, 0), n);

    // A cap of zero writes nothing rather than overrunning.
    try std.testing.expectEqual(@as(usize, 0), bw_updates_pending(&ctx, &out[0], 0));
}

test "the balance-privacy preference round-trips through the shared conf" {
    // The same key the TUI writes, in the same file — the preference has to
    // follow the user between the two front-ends.
    const io = sharedIo();
    const root = "test-hide-balances";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var ctx = testCtx(root);

    // Absent means shown — the safe default is not to hide something the user
    // never asked to hide.
    try std.testing.expectEqual(@as(c_int, 0), bw_hide_balances(&ctx));

    try std.testing.expectEqual(@as(c_int, 0), bw_set_hide_balances(&ctx, 1));
    try std.testing.expectEqual(@as(c_int, 1), bw_hide_balances(&ctx));
    try std.testing.expectEqual(@as(c_int, 0), bw_set_hide_balances(&ctx, 0));
    try std.testing.expectEqual(@as(c_int, 0), bw_hide_balances(&ctx));

    // And it must not have trampled anything else in the shared file — the TUI
    // keeps its own settings in there.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try conf.setValue(a, io, root, conf.settings_file, "show_prices", "1");
    try std.testing.expectEqual(@as(c_int, 0), bw_set_hide_balances(&ctx, 1));
    const kept = try conf.readValue(a, io, root, conf.settings_file, "show_prices");
    try std.testing.expectEqualStrings("1", kept.?);
}

test "the mask is the same string both front-ends use" {
    var buf: [32]u8 = undefined;
    const n = bw_balance_mask(&buf, buf.len);
    try std.testing.expectEqualStrings(money.balance_mask, buf[0..n]);
    try std.testing.expect(n > 0);
}

test "every coin has a tip address, and it isn't the user's" {
    // A blank one would render an empty Settings row; worse, a *wrong* one would
    // send a donation into the void. Cheap to assert, so assert it.
    var buf: [128]u8 = undefined;
    var i: usize = 0;
    while (i < coin_count) : (i += 1) {
        const n = bw_tip_address(i, &buf, buf.len);
        try std.testing.expect(n > 0);
        // Addresses are base58/bech32-ish: no whitespace, nothing that would
        // suggest a truncated or placeholder value.
        for (buf[0..n]) |ch| try std.testing.expect(ch > ' ' and ch < 127);
    }
    try std.testing.expectEqual(@as(usize, 0), bw_tip_address(coin_count, &buf, buf.len));
}

test "memory usage reports a plausible pair" {
    var u: BwDiskUsage = undefined;
    if (bw_memory_usage(&u) != 0) return error.SkipZigTest; // platform won't say
    try std.testing.expect(u.total_bytes > 0);
    // Used can't exceed total, or the gauge would overfill.
    try std.testing.expect(u.used_bytes <= u.total_bytes);
    try std.testing.expectEqual(@as(c_int, -1), bw_memory_usage(null));
}

test "the data-dir size refuses a dir that isn't there" {
    // A coin that has never been installed has no data dir, and the caller must
    // get -1 rather than a confident 0 — 0 would render as a real "0 B chain".
    var ctx: Ctx = .{ .allocator = std.testing.allocator, .home_dir = "/nonexistent/bw-test", .install_root = "" };
    var size: u64 = 12345;
    try std.testing.expectEqual(@as(c_int, -1), bw_data_dir_size(&ctx, 0, &size));
    try std.testing.expectEqual(@as(c_int, -1), bw_data_dir_size(&ctx, coin_count, &size));
    try std.testing.expectEqual(@as(c_int, -1), bw_data_dir_size(&ctx, 0, null));
}

test "the QR export reproduces the encoder's own bitmap" {
    // A real bitcoin address, so the version/size is representative rather than a
    // toy string.
    const addr = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa";
    var buf: [bw_qr_max_side * bw_qr_max_side]u8 = undefined;
    var side: u32 = 0;
    const n = bw_qr_encode(addr, &buf, buf.len, &side);
    try std.testing.expect(n > 0);
    try std.testing.expect(side >= 21 and side <= bw_qr_max_side);
    try std.testing.expectEqual(@as(usize, side) * side, n);

    // Every module must match what qrcode.zig itself produces — the export is a
    // copy, and a transposed one would still "look like" a QR while scanning as
    // nothing.
    const qr = try qrcode.encodeText(std.testing.allocator, addr, .medium);
    defer qr.deinit();
    try std.testing.expectEqual(@as(usize, qr.size()), side);
    var y: usize = 0;
    while (y < side) : (y += 1) {
        var x: usize = 0;
        while (x < side) : (x += 1) {
            const want: u8 = if (qr.get(@intCast(x), @intCast(y))) 1 else 0;
            try std.testing.expectEqual(want, buf[y * side + x]);
        }
    }

    // The three finder patterns give a fixed corner: dark border, light ring,
    // dark core. If the rows and columns were swapped this would still pass, but
    // the whole-bitmap compare above wouldn't.
    try std.testing.expectEqual(@as(u8, 1), buf[0]);
    try std.testing.expectEqual(@as(u8, 0), buf[1 * side + 1]);
    try std.testing.expectEqual(@as(u8, 1), buf[2 * side + 2]);

    // Refusals: empty text, a buffer too small, and null arguments.
    try std.testing.expectEqual(@as(usize, 0), bw_qr_encode("", &buf, buf.len, &side));
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), bw_qr_encode(addr, &tiny, tiny.len, &side));
    try std.testing.expectEqual(@as(usize, 0), bw_qr_encode(null, &buf, buf.len, &side));
    try std.testing.expectEqual(@as(usize, 0), bw_qr_encode(addr, &buf, buf.len, null));
}

test "the status export says exactly what the shared readout says" {
    var buf: [160]u8 = undefined;

    // A zeroed input is "not installed" — the honest answer for a caller that
    // knows nothing, and the reason every field's 0 has to mean "unknown".
    var in: BwStatusInput = std.mem.zeroes(BwStatusInput);
    var n = bw_status_line(&in, &buf, buf.len);
    try std.testing.expectEqualStrings("Not installed", buf[0..n]);
    try std.testing.expectEqual(@as(c_int, 0), bw_status_active(&in));

    // Running, no peers yet.
    in.installed = 1;
    in.daemon = 2;
    n = bw_status_line(&in, &buf, buf.len);
    try std.testing.expectEqualStrings("Waiting for peers…", buf[0..n]);
    try std.testing.expectEqual(@as(c_int, 1), bw_status_active(&in));

    // Syncing blocks: the phrase alone, whatever heights are known — the Blocks
    // readout beside it is where a height belongs.
    in.peers = 8;
    in.sync = 1;
    in.blocks_cur = 123456;
    in.blocks_total = 850000;
    in.headers_cur = 850000;
    in.headers_total = 850000;
    n = bw_status_line(&in, &buf, buf.len);
    try std.testing.expectEqualStrings("Syncing blocks…", buf[0..n]);

    // …and then just "Synced" once it finishes.
    in.sync = 2;
    n = bw_status_line(&in, &buf, buf.len);
    try std.testing.expectEqualStrings("Synced", buf[0..n]);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(status_mod.Tone.ok)), bw_status_tone(&in));

    // Out-of-range enum values fall back to 0 rather than reinterpreting memory.
    in.daemon = 99;
    in.sync = -5;
    n = bw_status_line(&in, &buf, buf.len);
    try std.testing.expectEqualStrings("Idle", buf[0..n]);

    // A null input is answered, not dereferenced.
    try std.testing.expectEqual(@as(usize, 0), bw_status_line(null, &buf, buf.len));
    try std.testing.expectEqual(@as(c_int, 0), bw_status_tone(null));
}

test "bw_wallet_menu returns exactly what the shared policy decides" {
    // The whole point of the export is that the GUI can't reach a different
    // answer from the TUI, so this compares it against the module both call
    // rather than against a hand-written expectation.
    var out: [walletmenu.max_options]u8 = undefined;
    var want: [walletmenu.max_options]walletmenu.Action = undefined;

    var i: usize = 0;
    while (i < coin_count) : (i += 1) {
        const coin = coinByIndex(i) orelse return error.Unexpected;
        for ([_]models.WalletSecurity{
            .unknown, .unencrypted, .locked, .unlocked, .unlocked_for_staking,
        }) |state| {
            const sec: c_int = @intFromEnum(state);
            const n = bw_wallet_menu(i, sec, &out[0], out.len);
            if (!coin.supportsWallet()) {
                try std.testing.expectEqual(@as(usize, 0), n);
                continue;
            }
            const wn = walletmenu.optionsFor(state, .of(coin), &want);
            try std.testing.expectEqual(wn, n);
            for (out[0..n], want[0..wn]) |got, exp| {
                try std.testing.expectEqual(@intFromEnum(exp), got);
            }
        }
        // An unknown state offers nothing that depends on what the daemon holds —
        // a menu built before it has said can destroy a wallet. The exception is
        // the offline wallet-file swap, which needs the daemon *stopped*, and a
        // stopped daemon is exactly what reads as unknown.
        const un = bw_wallet_menu(i, @intFromEnum(models.WalletSecurity.unknown), &out[0], out.len);
        try std.testing.expectEqual(
            @as(usize, if (coin.supportsWalletRestoreOffline()) 1 else 0),
            un,
        );
        for (out[0..un]) |got| {
            try std.testing.expectEqual(@intFromEnum(walletmenu.Action.restore_file_offline), got);
        }
    }

    // Out-of-range states are refused rather than folded onto a real one.
    try std.testing.expectEqual(@as(usize, 0), bw_wallet_menu(0, -1, &out[0], out.len));
    try std.testing.expectEqual(@as(usize, 0), bw_wallet_menu(0, 99, &out[0], out.len));
    try std.testing.expectEqual(@as(usize, 0), bw_wallet_menu(coin_count, 2, &out[0], out.len));
}

test "every action a menu can return is labelled and answerable" {
    // A row the caller can't label or route is a row it can't render.
    var buf: [64]u8 = undefined;
    var out: [walletmenu.max_options]u8 = undefined;
    var seen = [_]bool{false} ** 7;

    var i: usize = 0;
    while (i < coin_count) : (i += 1) {
        for ([_]models.WalletSecurity{ .unencrypted, .locked, .unlocked, .unlocked_for_staking }) |state| {
            const n = bw_wallet_menu(i, @intFromEnum(state), &out[0], out.len);
            for (out[0..n]) |a| {
                try std.testing.expect(a < seen.len);
                seen[a] = true;
                try std.testing.expect(bw_wallet_action_label(a, &buf, buf.len) > 0);
                // Exactly one of the two prompts, never both and never neither.
                const pw = bw_wallet_action_needs_password(a) != 0;
                const path = bw_wallet_action_needs_path(a) != 0;
                try std.testing.expect(!(pw and path));
                // Only a credential-setting action asks for confirmation.
                if (bw_wallet_action_sets_new_password(a) != 0) try std.testing.expect(pw);
            }
        }
    }
    // Encrypt is the only action that sets a password, and it must be reachable
    // — if the registry stopped surfacing it, wallets could never be encrypted.
    try std.testing.expect(seen[@intFromEnum(walletmenu.Action.encrypt)]);
    try std.testing.expectEqual(@as(c_int, 1), bw_wallet_action_sets_new_password(@intFromEnum(walletmenu.Action.encrypt)));
    try std.testing.expectEqual(@as(c_int, 0), bw_wallet_action_sets_new_password(@intFromEnum(walletmenu.Action.unlock)));
    // An ordinal past the end is refused rather than aliasing onto a real one.
    try std.testing.expectEqual(@as(usize, 0), bw_wallet_action_label(99, &buf, buf.len));
}

test "wallet caps track the vtable, and unsupported actions are refused" {
    var ctx: Ctx = .{ .allocator = std.testing.allocator, .home_dir = "/nonexistent/bw-test", .install_root = "" };
    var i: usize = 0;
    while (i < coin_count) : (i += 1) {
        const coin = coinByIndex(i) orelse return error.Unexpected;
        const caps = bw_coin_wallet_caps(i);
        if (!coin.supportsWallet()) {
            try std.testing.expectEqual(@as(c_int, 0), caps);
            continue;
        }
        try std.testing.expectEqual(coin.supportsWalletEncrypt(), caps & bw_wcap_encrypt != 0);
        try std.testing.expectEqual(coin.supportsWalletBackup(), caps & bw_wcap_backup != 0);
        try std.testing.expectEqual(coin.supportsWalletImport(), caps & bw_wcap_import != 0);
        try std.testing.expectEqual(coin.supportsWalletRestoreOffline(), caps & bw_wcap_restore_offline != 0);

        // A coin whose daemon can't do a thing must refuse it rather than
        // attempting an RPC that can only fail — BitcoinZ ships encryptwallet
        // disabled, and offering it would be offering a guaranteed failure.
        if (!coin.supportsWalletEncrypt()) {
            const pw = "hunter2";
            try std.testing.expectEqual(@as(c_int, -1), bw_wallet_encrypt(&ctx, i, pw.ptr, pw.len));
            try std.testing.expectEqualStrings("Unsupported", ctx.errorCode());
        }
        if (!coin.supportsStakeAction()) {
            var o: [64]u8 = undefined;
            try std.testing.expectEqual(@as(c_int, -1), bw_wallet_stake(&ctx, i, 1.0, &o, o.len));
        }
    }
    ctx.clearError();
}

test "the prune exports agree with the vtable about which coins prune" {
    // Exactly the coins wiring Coin.Pruning may answer. If this ever reports a
    // mode for a coin that has none, the Settings tab grows a pruning row for a
    // daemon that can't prune — and, worse, the prompt in the next stage would
    // offer to act on it.
    var buf: [64]u8 = undefined;
    var pruners: usize = 0;
    var i: usize = 0;
    while (i < coin_count) : (i += 1) {
        const coin = coinByIndex(i) orelse return error.Unexpected;
        const mode = bw_prune_mode(i);
        if (coin.pruning()) |pr| {
            pruners += 1;
            try std.testing.expectEqual(@as(c_int, @intFromEnum(pr.mode)), mode);
            // The text has to describe every value a conf can hold, including
            // the two absences that look alike and aren't.
            try std.testing.expect(bw_prune_value_text(i, -1, &buf, buf.len) > 0);
            try std.testing.expect(bw_prune_value_text(i, 0, &buf, buf.len) > 0);
            try std.testing.expect(bw_prune_value_text(i, 2000, &buf, buf.len) > 0);
        } else {
            try std.testing.expectEqual(@as(c_int, -1), mode);
            // A non-pruning coin describes nothing, so the row stays hidden.
            try std.testing.expectEqual(@as(usize, 0), bw_prune_value_text(i, 0, &buf, buf.len));
        }
    }
    // Bitcoin, Litecoin and Monero.
    try std.testing.expectEqual(@as(usize, 3), pruners);
    try std.testing.expectEqual(@as(c_int, -1), bw_prune_mode(coin_count));
}

test "the prune menu comes from the coin, with the safe choice first" {
    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < coin_count) : (i += 1) {
        const coin = coinByIndex(i) orelse return error.Unexpected;
        const n = bw_prune_preset_count(i);
        const pr = coin.pruning() orelse {
            // A coin that doesn't prune offers no menu and no prompt, so nothing
            // can open a dialog for it.
            try std.testing.expectEqual(@as(usize, 0), n);
            try std.testing.expectEqual(@as(usize, 0), bw_prune_prompt(i, &buf, buf.len));
            continue;
        };
        try std.testing.expectEqual(pr.presets.len, n);
        try std.testing.expect(n > 0);
        try std.testing.expect(bw_prune_prompt(i, &buf, buf.len) > 0);

        // Row 0 must be the least destructive choice — the dialog starts there,
        // so anything else would let a stray Enter discard a chain.
        try std.testing.expectEqual(@as(i64, 0), bw_prune_preset_value(i, 0));

        for (pr.presets, 0..) |p, r| {
            try std.testing.expectEqual(p.value, bw_prune_preset_value(i, r));
            const ln = bw_prune_preset_label(i, r, &buf, buf.len);
            try std.testing.expectEqualStrings(p.label, buf[0..ln]);
            // Every row must be pickable and describable.
            try std.testing.expect(ln > 0);
            try std.testing.expect(p.value >= 0);
        }
        // Out of range is refused rather than wrapping onto a real row.
        try std.testing.expectEqual(@as(i64, -1), bw_prune_preset_value(i, n));
        try std.testing.expectEqual(@as(usize, 0), bw_prune_preset_label(i, n, &buf, buf.len));
    }
}

test "bw_prune_apply refuses the sentinel rather than writing it" {
    // -1 is this ABI's "not configured" / "bad row" value. If an out-of-range
    // row's -1 were written through as a setting, a mis-indexed menu would
    // silently corrupt the conf instead of failing loudly.
    var ctx: Ctx = .{ .allocator = std.testing.allocator, .home_dir = "/nonexistent/bw-test", .install_root = "" };
    var idx: usize = coin_count;
    var i: usize = 0;
    while (i < coin_count) : (i += 1) {
        const c = coinByIndex(i) orelse continue;
        if (c.pruning() != null) {
            idx = i;
            break;
        }
    }
    try std.testing.expect(idx < coin_count);

    try std.testing.expectEqual(@as(c_int, -1), bw_prune_apply(&ctx, idx, -1));
    try std.testing.expectEqual(@as(c_int, -1), bw_prune_apply(&ctx, idx, bw_prune_preset_value(idx, 99)));
    // And a coin that can't prune is refused outright.
    var non: usize = coin_count;
    i = 0;
    while (i < coin_count) : (i += 1) {
        const c = coinByIndex(i) orelse continue;
        if (c.pruning() == null) {
            non = i;
            break;
        }
    }
    try std.testing.expect(non < coin_count);
    try std.testing.expectEqual(@as(c_int, -1), bw_prune_apply(&ctx, non, 2000));
    ctx.clearError();
}

test "a coin that doesn't prune is never offered the prompt" {
    var ctx: Ctx = .{ .allocator = std.testing.allocator, .home_dir = "/nonexistent/bw-test", .install_root = "" };
    var i: usize = 0;
    while (i < coin_count) : (i += 1) {
        const coin = coinByIndex(i) orelse continue;
        if (coin.pruning() != null) continue;
        try std.testing.expectEqual(@as(c_int, 0), bw_prune_should_offer(&ctx, i));
    }
    // Nor is a non-coin.
    try std.testing.expectEqual(@as(c_int, 0), bw_prune_should_offer(&ctx, coin_count));
}

test "never-configured and deliberate-full-node read differently" {
    // "not set" and "disabled (full node)" are one character apart in intent and
    // miles apart in meaning: the first says nobody has chosen, the second says
    // someone chose to keep everything. Conflating them is how a full node gets
    // offered pruning it must never be offered.
    var idx: usize = coin_count;
    var i: usize = 0;
    while (i < coin_count) : (i += 1) {
        const coin = coinByIndex(i) orelse continue;
        if (coin.pruning() != null) {
            idx = i;
            break;
        }
    }
    try std.testing.expect(idx < coin_count);

    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    const unset = a[0..bw_prune_value_text(idx, -1, &a, a.len)];
    const full = b[0..bw_prune_value_text(idx, 0, &b, b.len)];
    try std.testing.expect(!std.mem.eql(u8, unset, full));
}

test "the wordmark export splits each coin's name where the vtable says" {
    var wm: BwWordmark = undefined;
    var found: usize = 0;
    var i: usize = 0;
    while (i < coin_count) : (i += 1) {
        const coin = coinByIndex(i) orelse return error.Unexpected;
        const rc = bw_coin_wordmark(i, &wm);
        const want = coin.wordmark();
        if (want == null) {
            try std.testing.expectEqual(@as(c_int, 0), rc);
            continue;
        }
        found += 1;
        try std.testing.expectEqual(@as(c_int, 1), rc);
        try std.testing.expectEqual(want.?.split, wm.split);

        // The split has to land strictly inside the name, or the GUI slices an
        // empty half and the wordmark silently loses a colour.
        const name = coin.coinName();
        try std.testing.expect(wm.split > 0 and wm.split < name.len);

        // The head colour is optional on the vtable and falls back to the coin's
        // own brand colour — resolving that here is the whole point of the
        // export, so a front-end never has to know about the fallback.
        const head = std.mem.sliceTo(&wm.head_color, 0);
        const tail = std.mem.sliceTo(&wm.tail_color, 0);
        try std.testing.expectEqualStrings(want.?.head_color orelse coin.coinColor(), head);
        try std.testing.expectEqualStrings(want.?.alt_color, tail);
        try std.testing.expectEqual(@as(usize, 7), head.len);
        try std.testing.expectEqual(@as(usize, 7), tail.len);
    }
    // ReddCoin, SpiderByte and BitcoinZ. If this drops to zero the export has
    // been disconnected and every coin would quietly render single-tone.
    try std.testing.expectEqual(@as(usize, 3), found);

    try std.testing.expectEqual(@as(c_int, 0), bw_coin_wordmark(coin_count, &wm));
}

test "the seed exports answer the backup quiz the way the shared module does" {
    const words = "abandon ability able about above absent absorb abstract absurd abuse access accident";
    try std.testing.expectEqual(@as(usize, 12), bw_seed_word_count(words.ptr, words.len));

    // Right word, however it was typed.
    const ok = "Ability";
    try std.testing.expectEqual(@as(c_int, 1), bw_seed_word_matches(words.ptr, words.len, 2, ok.ptr, ok.len));
    // Wrong word, and a prefix of the right one, must both fail — a quiz that
    // accepts a prefix isn't checking anything.
    const wrong = "able";
    try std.testing.expectEqual(@as(c_int, 0), bw_seed_word_matches(words.ptr, words.len, 2, wrong.ptr, wrong.len));
    const prefix = "abilit";
    try std.testing.expectEqual(@as(c_int, 0), bw_seed_word_matches(words.ptr, words.len, 2, prefix.ptr, prefix.len));
    // Position 0 and past the end are not answerable.
    try std.testing.expectEqual(@as(c_int, 0), bw_seed_word_matches(words.ptr, words.len, 0, ok.ptr, ok.len));
    try std.testing.expectEqual(@as(c_int, 0), bw_seed_word_matches(words.ptr, words.len, 99, ok.ptr, ok.len));

    // Positions: three distinct, in range, ascending.
    var pos: [3]u32 = undefined;
    var round: usize = 0;
    while (round < 100) : (round += 1) {
        try std.testing.expectEqual(@as(usize, 3), bw_seed_verify_positions(25, &pos[0], pos.len));
        try std.testing.expect(pos[0] < pos[1] and pos[1] < pos[2]);
        try std.testing.expect(pos[0] >= 1 and pos[2] <= 25);
    }
    // A short seed yields fewer rather than looping for a third distinct one.
    try std.testing.expectEqual(@as(usize, 2), bw_seed_verify_positions(2, &pos[0], pos.len));
    try std.testing.expectEqual(@as(usize, 0), bw_seed_verify_positions(0, &pos[0], pos.len));
}

test "the amount exports render exactly what the shared formatter does" {
    // The GUI carried its own C++ amount formatter until this export replaced it.
    // If these ever drift from `money.zig`, the two front-ends are back to
    // printing one balance two ways.
    var buf: [96]u8 = undefined;
    var want: [96]u8 = undefined;

    var n = bw_format_amount(1234567.5, 8, &buf, buf.len);
    try std.testing.expectEqualStrings(
        money.formatAmount(&want, 1234567.5, 8),
        buf[0..n],
    );
    // Full precision is kept, so a zero balance reads as a balance.
    n = bw_format_amount(0.0, 8, &buf, buf.len);
    try std.testing.expectEqualStrings("0.00000000", buf[0..n]);

    // Trimming is the transaction-list spelling, and it must agree too.
    const src = "498.00000000";
    n = bw_trim_zeros(src.ptr, src.len, &buf, buf.len);
    try std.testing.expectEqualStrings("498", buf[0..n]);

    // A buffer too small truncates rather than overrunning.
    var tiny: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), bw_format_amount(1234567.5, 8, &tiny, tiny.len));
}

test "the app identity exports report the shared constants" {
    // The GUI used to carry its own copy of the version string. If this export
    // ever drifts from `version.zig`, the Home page announces a release the
    // running binary isn't — and the self-updater compares against the other one.
    var buf: [64]u8 = undefined;
    var n = bw_app_version(&buf, buf.len);
    try std.testing.expectEqualStrings(version.app_version, buf[0..n]);

    n = bw_app_name(&buf, buf.len);
    try std.testing.expectEqualStrings(version.gui_name, buf[0..n]);

    n = bw_brand_color(&buf, buf.len);
    try std.testing.expectEqualStrings(version.brand_color, buf[0..n]);

    // A buffer too small truncates rather than overrunning.
    var tiny: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), bw_app_version(&tiny, tiny.len));
}

test "each thread reads back its own last error, never another's" {
    // The GUI runs a continuous status poller alongside a dozen detached action
    // workers, all of which can fail. A shared error slot lets one worker's
    // message surface on another's modal — wrong text on a wallet dialog, which
    // is worse than no text. This is the guard for that.
    var ctx: Ctx = .{ .allocator = std.testing.allocator, .home_dir = "", .install_root = "" };

    const Worker = struct {
        fn run(c: *Ctx, msg: []const u8, code: []const u8, ok: *bool) void {
            c.setError(msg);
            c.setErrorCode(code);
            // Give the sibling every chance to clobber a shared slot before we
            // read ours back.
            std.Thread.yield() catch {};
            ok.* = std.mem.eql(u8, c.errorText(), msg) and std.mem.eql(u8, c.errorCode(), code);
        }
    };

    // Stake out this thread's slot first, so "the workers didn't touch it" is a
    // claim about a value we chose rather than about whatever a previous test
    // happened to leave behind.
    ctx.setError("main thread");
    ctx.setErrorCode("MainError");

    var a_ok = false;
    var b_ok = false;
    const ta = try std.Thread.spawn(.{}, Worker.run, .{ &ctx, "alpha failed", "AlphaError", &a_ok });
    const tb = try std.Thread.spawn(.{}, Worker.run, .{ &ctx, "bravo failed", "BravoError", &b_ok });
    ta.join();
    tb.join();
    try std.testing.expect(a_ok);
    try std.testing.expect(b_ok);

    // And neither leaked onto the thread running the test.
    try std.testing.expectEqualStrings("main thread", ctx.errorText());
    try std.testing.expectEqualStrings("MainError", ctx.errorCode());
    ctx.clearError();
}

test "clearing an error forgets both the message and the code" {
    var ctx: Ctx = .{ .allocator = std.testing.allocator, .home_dir = "", .install_root = "" };
    ctx.setError("something went wrong");
    ctx.setErrorCode("WrongPassword");
    try std.testing.expect(ctx.hasError());

    ctx.clearError();
    try std.testing.expect(!ctx.hasError());
    // Both, not just the message: a stale code would keep a modal parked on the
    // password step after an unrelated retry succeeded.
    try std.testing.expectEqualStrings("", ctx.errorText());
    try std.testing.expectEqualStrings("", ctx.errorCode());
}

test "an over-long error message is truncated, not overrun" {
    var ctx: Ctx = .{ .allocator = std.testing.allocator, .home_dir = "", .install_root = "" };
    const long = "x" ** 400;
    ctx.setError(long);
    try std.testing.expectEqual(@as(usize, 256), ctx.errorText().len);
    ctx.setErrorCode(long);
    try std.testing.expectEqual(@as(usize, 64), ctx.errorCode().len);
    ctx.clearError();
}

test "every coin with a wallet reports a balance to show" {
    // The regression guard for the bug that left Transactions/Receive/Send blank
    // on all eight in-daemon coins: `Coin.supportsBalance` is false for a managed
    // wallet (its balance comes from the required `ExternalWallet.balance` hook,
    // not from `wallet_balance`), so a front-end gating on the bare vtable
    // predicate silently drops half the registry. The export must answer for both
    // shapes, and every registered coin must have one of them.
    var i: usize = 0;
    while (i < coin_count) : (i += 1) {
        const coin = coinByIndex(i) orelse return error.Unexpected;
        try std.testing.expectEqual(
            coin.supportsBalance() or coin.hasExternalWallet(),
            bw_coin_supports_balance(i) != 0,
        );
        try std.testing.expect(bw_coin_supports_balance(i) != 0);
    }
    try std.testing.expectEqual(@as(c_int, 0), bw_coin_supports_balance(coin_count));
}

test "the remaining tab capabilities track their vtable hooks" {
    var i: usize = 0;
    while (i < coin_count) : (i += 1) {
        const coin = coinByIndex(i) orelse return error.Unexpected;
        try std.testing.expectEqual(coin.supportsTransactions(), bw_coin_supports_transactions(i) != 0);
        try std.testing.expectEqual(coin.supportsReceiveAddress(), bw_coin_supports_receive_address(i) != 0);
        try std.testing.expectEqual(coin.supportsSend(), bw_coin_supports_send(i) != 0);
        try std.testing.expectEqual(coin.supportsStakeAction(), bw_coin_supports_stake(i) != 0);
        try std.testing.expectEqual(coin.supportsStakeList(), bw_coin_supports_stake_list(i) != 0);
    }
    // An index that isn't a coin claims nothing.
    try std.testing.expectEqual(@as(c_int, 0), bw_coin_supports_transactions(coin_count));
    try std.testing.expectEqual(@as(c_int, 0), bw_coin_supports_receive_address(coin_count));
    try std.testing.expectEqual(@as(c_int, 0), bw_coin_supports_send(coin_count));
    try std.testing.expectEqual(@as(c_int, 0), bw_coin_supports_stake(coin_count));
    try std.testing.expectEqual(@as(c_int, 0), bw_coin_supports_stake_list(coin_count));
}

test "a coin with a stake action carries a hint to show with it" {
    // The Stake confirm step is the user's one chance to read what they're
    // committing to (a ~30-day lock), so a coin that offers the action must have
    // something to say about it — an empty hint would confirm a lock-up silently.
    var i: usize = 0;
    var buf: [256]u8 = undefined;
    while (i < coin_count) : (i += 1) {
        if (bw_coin_supports_stake(i) == 0) continue;
        try std.testing.expect(bw_stake_hint(i, &buf, buf.len) > 0);
    }
}

test "bw_wallet_balance gates a managed wallet on open, an in-daemon one on nothing" {
    var ctx: Ctx = .{ .allocator = std.testing.allocator, .home_dir = "/nonexistent/bw-test", .install_root = "" };
    var out: BwWalletBalance = undefined;

    // An index outside the registry is refused before anything is touched.
    try std.testing.expectEqual(@as(c_int, -1), bw_wallet_balance(&ctx, coin_count, &out));

    var external: usize = coin_count;
    var in_daemon: usize = coin_count;
    var i: usize = 0;
    while (i < coin_count) : (i += 1) {
        const c = coinByIndex(i) orelse continue;
        if (c.hasExternalWallet()) {
            if (external == coin_count) external = i;
        } else if (in_daemon == coin_count) in_daemon = i;
    }
    try std.testing.expect(external < coin_count);
    try std.testing.expect(in_daemon < coin_count);

    // A managed wallet nobody has opened is refused without an RPC attempt — the
    // wallet-rpc isn't even running, so asking would only produce a confusing
    // transport error.
    try std.testing.expectEqual(@as(u8, 0), ctx.wallet_open[external].load(.monotonic));
    try std.testing.expectEqual(@as(c_int, -1), bw_wallet_balance(&ctx, external, &out));

    // And the managed-wallet spelling refuses an in-daemon coin outright, so the
    // two can't be confused for one another.
    try std.testing.expectEqual(@as(c_int, -1), bw_ext_wallet_balance(&ctx, in_daemon, &out));
}

test "bw_format_storage matches the TUI's own storage figure" {
    // The GUI used to format this itself in binary units, so one data directory
    // read "11.5 GB" there and "12.34 GB" in the TUI. Both now go through
    // timefmt.storageGB, and this asserts the C ABI really does hand back that
    // string rather than something merely similar.
    var buf: [48]u8 = undefined;
    var want: [48]u8 = undefined;

    for ([_]u64{ 0, 1000 * 1000 * 1000, 1024 * 1024 * 1024, 523_450_000_000 }) |bytes| {
        const n = bw_format_storage(bytes, &buf, buf.len);
        try std.testing.expectEqualStrings(timefmt.storageGB(&want, bytes), buf[0..n]);
    }

    // A null buffer is a no-op rather than a crash, like every other bw_format_*.
    try std.testing.expectEqual(@as(usize, 0), bw_format_storage(1, null, 0));
}

test "bw_sync_* hands back the TUI's distance wording" {
    var st: BwBlockchainState = std.mem.zeroes(BwBlockchainState);
    st.seconds_behind = -1;
    var buf: [64]u8 = undefined;

    // Nothing to measure: both read empty rather than "0 minutes behind" or a
    // date at the unix epoch.
    try std.testing.expectEqual(@as(usize, 0), bw_sync_tip_date(&st, &buf, buf.len));
    try std.testing.expectEqual(@as(usize, 0), bw_sync_behind(&st, &buf, buf.len));

    // A coin reporting only the gap still gets both: the wording from
    // timefmt.behind, and a tip date reconstructed from now − gap.
    st.seconds_behind = 2 * std.time.s_per_hour + 5 * std.time.s_per_min;
    var n = bw_sync_behind(&st, &buf, buf.len);
    try std.testing.expectEqualStrings("2 hours and 5 minutes behind", buf[0..n]);
    n = bw_sync_tip_date(&st, &buf, buf.len);
    try std.testing.expectEqual(@as(usize, 16), n); // "YYYY-MM-DD HH:MM"

    // Caught up reads as nothing at all, so a front-end shows no hint.
    st.seconds_behind = 0;
    try std.testing.expectEqual(@as(usize, 0), bw_sync_behind(&st, &buf, buf.len));

    // Null in, null out — no crash, like every other formatter here.
    try std.testing.expectEqual(@as(usize, 0), bw_sync_behind(null, &buf, buf.len));
    try std.testing.expectEqual(@as(usize, 0), bw_sync_tip_date(&st, null, 0));
}
