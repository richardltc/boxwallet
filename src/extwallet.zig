//! The external wallet-rpc **process lifecycle**, shared by both front-ends.
//!
//! For a `coin.hasExternalWallet()` coin the wallet is a *second* process
//! (`nerva-wallet-rpc`) BoxWallet spawns alongside the daemon and tears down
//! with it. Spawning it, locking it to per-session credentials, killing it, and
//! addressing its RPC are all front-end-agnostic mechanics — so they live here
//! rather than in `app.zig` (TUI) or `capi.zig` (GUI), the same way `proc.zig`
//! and `warmup.zig` do.
//!
//! What stays with the front-end: whether the *wallet* is open, whether a wallet
//! file exists on disk, and how any of this is worded on screen. `ensure`
//! returns a tagged outcome rather than logging, so each front-end phrases the
//! result in its own voice.

const std = @import("std");
const builtin = @import("builtin");
const coinmod = @import("coin.zig");
const models = @import("models.zig");
const conf = @import("conf.zig");
const proc = @import("proc.zig");
const rpc = @import("rpc.zig");
const walletmenu = @import("walletmenu.zig");

const Coin = coinmod.Coin;

/// Length of each randomly generated wallet-rpc credential (`--rpc-login`). 24
/// alphanumeric chars from the CSPRNG is ~143 bits — far beyond brute force by a
/// local attacker, while staying a small fixed buffer.
pub const cred_len = 24;

/// Everything BoxWallet holds for one coin's managed wallet-rpc process: the
/// child handle and the credentials that process was locked to. One per coin —
/// a shared slot would let one coin's teardown kill another coin's service.
///
/// Whether the *wallet* is open is deliberately not here: that's front-end
/// state (the TUI's `Activity.ext_wallet_open`, the GUI's `Ctx.wallet_open`).
pub const Session = struct {
    /// Handle to the spawned wallet-rpc child, so it can be killed when the
    /// daemon stops (Monero wallet-rpc has no shutdown RPC). Null when not
    /// running.
    child: ?std.process.Child = null,
    /// Per-session credentials the wallet-rpc is launched with (`--rpc-login`)
    /// and that `authFor` answers its HTTP digest challenge with. Generated from
    /// the OS CSPRNG when the process is spawned and wiped when it's killed, so
    /// the wallet RPC (which exposes the spend key + `sweep_all`) can't be driven
    /// by another local process. Always full-length when `creds_set`.
    user_buf: [cred_len]u8 = undefined,
    pass_buf: [cred_len]u8 = undefined,
    creds_set: bool = false,
    /// Whether we've tried to spawn the wallet-rpc this daemon run. Stops a
    /// missing or broken binary from being retried (and re-reported) every tick;
    /// the failure is surfaced once. Reset when the daemon is (re)started or the
    /// process killed.
    attempted: bool = false,
    /// The coin's payment listener (`Coin.ExternalWallet.listener_argv`), when
    /// it has one and the wallet is unlocked. Started after a successful open,
    /// killed with `child`.
    listener: ?std.process.Child = null,
    /// The listener was started this unlock and has since exited (or never
    /// came up). Nothing restarts it — that would need the password, which
    /// isn't kept — so it reads as stopped until the next unlock. Cleared by
    /// `kill`.
    listener_down: bool = false,

    pub fn isRunning(self: *const Session) bool {
        return self.child != null;
    }
};

/// Whether a coin's payment listener is doing its job, for the front-ends to
/// show beside the receive address.
pub const ListenerState = enum(u8) {
    /// The coin has no listener, or its wallet isn't unlocked.
    none = 0,
    running = 1,
    /// Started for this unlock but exited since: payments wait at the relay
    /// until the wallet is unlocked again.
    stopped = 2,
};

/// Why an `ensure` call did or didn't leave a wallet process running. The caller
/// turns this into its own user-visible message — this module knows nothing
/// about the TUI's action log or the GUI's status line.
pub const Ensure = union(enum) {
    /// Nothing to do: not an external-wallet coin, it has no separate process,
    /// or it's the launch-with-password shape (spawned per-open, not eagerly).
    not_applicable,
    already_running,
    /// A previous attempt this daemon run already failed and was reported.
    already_attempted,
    started,
    /// Something is already serving this coin's wallet port: a second BoxWallet,
    /// or a service orphaned by one that didn't shut down cleanly. Deliberately
    /// **not** latched by `attempted`, so the moment the squatter goes away the
    /// next call spawns normally instead of staying broken for the whole run.
    port_busy,
    /// Couldn't build the spawn command.
    argv_failed: anyerror,
    /// The spawn itself failed — most likely the wallet-rpc binary isn't on disk
    /// (an install from before it was bundled), so the caller should say how to
    /// fix that.
    spawn_failed: anyerror,
};

/// Spawn the coin's wallet-rpc process if it isn't already up. Idempotent and
/// cheap once running or once an attempt has failed.
///
/// `environ_map` is passed through to the spawn so the child inherits the
/// caller's environment.
pub fn ensure(
    sess: *Session,
    coin: Coin,
    install_root: []const u8,
    home_dir: []const u8,
    environ_map: ?*const std.process.Environ.Map,
) Ensure {
    if (!coin.hasExternalWalletProcess() or coin.walletLaunchesWithPassword()) return .not_applicable;
    if (sess.child != null) return .already_running;
    if (sess.attempted) return .already_attempted;

    const ew = coin.externalWallet().?;
    // Process-backed and not launch-with-password (guarded above), so both are
    // present.
    const argv_fn = ew.process_argv.?;
    const port = ew.rpc_port.?();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Is someone already on this coin's wallet port? The port is a fixed
    // constant and the wallet dir is one directory, so a second process simply
    // can't bind — it starts, fails, and lingers doing nothing, while every
    // wallet op talks to the *other* process and fails its digest challenge.
    // That surfaces as "the wallet service is still starting", which sends the
    // user looking in entirely the wrong place.
    //
    // We can't adopt the squatter either: its credentials were generated by the
    // run that spawned it and died with it. So refuse, and say so. Checked
    // *before* the `attempted` latch is set, so this recovers by itself once the
    // squatter exits rather than staying broken for the rest of the session.
    if (rpc.daemonReachable(a, .{
        .rpc_user = "",
        .rpc_password = "",
        .ip_address = "127.0.0.1",
        .port = port,
    })) return .port_busy;

    sess.attempted = true;

    // Fresh per-session wallet-rpc credentials from the OS CSPRNG, so the RPC
    // (which exposes the spend key + `sweep_all`) is locked to this BoxWallet
    // run and not reachable by another local process. `authFor` answers the
    // digest challenge with the same buffers.
    _ = conf.randomPassword(io, &sess.user_buf);
    _ = conf.randomPassword(io, &sess.pass_buf);
    sess.creds_set = true;

    // argv is consumed by spawn (fork/exec copies it), so the local arena can
    // be freed right after — the returned `Child` holds only the pid/handle.
    const argv = argv_fn(a, install_root, home_dir, port, sess.user_buf[0..], sess.pass_buf[0..]) catch |err| {
        return .{ .argv_failed = err };
    };
    const child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = environ_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = builtin.os.tag == .windows,
    }) catch |err| {
        return .{ .spawn_failed = err };
    };
    sess.child = child;
    return .started;
}

/// Kill the coin's wallet-rpc process and wipe the credentials it was locked to.
/// Uses a fresh `Io` (the `Child` holds only the pid/handle, independent of the
/// io it was spawned under). Idempotent.
pub fn kill(sess: *Session) void {
    sess.attempted = false;
    // Wipe the wallet-rpc credentials — the process they unlocked is going away.
    @memset(&sess.user_buf, 0);
    @memset(&sess.pass_buf, 0);
    sess.creds_set = false;
    // The listener holds the same wallet open; it goes with it.
    killListener(sess);
    sess.listener_down = false;
    if (sess.child) |*child| {
        stopChild(child);
        sess.child = null;
    }
}

/// Stop a wallet-side child and reap it. Uses a fresh `Io` (the `Child` holds
/// only the pid/handle, independent of the io it was spawned under).
fn stopChild(child: *std.process.Child) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(arena.allocator(), .{});
    defer threaded.deinit();
    const io = threaded.io();

    // nerva-wallet-rpc has no shutdown RPC, so we signal it. std's
    // `child.kill()` sends SIGTERM then *blocks* until the process exits, and
    // a Monero wallet-rpc saves the wallet on SIGTERM, which can take a
    // moment. So on POSIX we drive it ourselves: SIGTERM, reap over a short
    // grace, then SIGKILL if it overstays — so a clean shutdown returns the
    // instant it finishes and a stuck one is bounded. Windows' `child.kill`
    // is an immediate TerminateProcess, so it keeps using that.
    if (builtin.os.tag == .windows) {
        child.kill(io);
    } else if (child.id) |pid| {
        proc.terminateAndReap(io, pid, 1500);
    }
}

/// Stop the payment listener, if one is running. Leaves `listener_down` alone:
/// a caller replacing it or tearing the whole session down decides that.
fn killListener(sess: *Session) void {
    if (sess.listener) |*l| {
        stopChild(l);
        sess.listener = null;
    }
}

/// Launch the coin's payment listener for a wallet that `password` has just
/// been confirmed to open. Best-effort: the wallet is open either way, so a
/// listener that can't be built or spawned is recorded as down (and shown as
/// stopped) rather than failing the open. No-op for coins without one.
fn startListener(
    sess: *Session,
    coin: Coin,
    install_root: []const u8,
    home_dir: []const u8,
    password: []const u8,
) void {
    const ew = coin.externalWallet() orelse return;
    const argv_fn = ew.listener_argv orelse return;
    killListener(sess);
    sess.listener_down = false;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // argv (password included) is copied by the spawn and freed with the arena
    // — the password rides argv only, as it does for the wallet server.
    const argv = argv_fn(a, install_root, home_dir, password) catch {
        sess.listener_down = true;
        return;
    };
    // The listener writes to the wallet's own log file, so its console output
    // has nothing to add.
    sess.listener = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = builtin.os.tag == .windows,
    }) catch {
        sess.listener_down = true;
        return;
    };
}

/// Check on the payment listener: reaps it if it has exited, so a dead one
/// reads as `stopped` from then on. Cheap (a non-blocking wait); the caller
/// must hold the session the way it does for `kill` — not while a setup op is
/// mid-flight on it.
pub fn probeListener(sess: *Session) ListenerState {
    if (sess.listener) |*l| {
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        if (proc.probeChild(threaded.io(), l) == null) return .running;
        sess.listener = null;
        sess.listener_down = true;
    }
    return if (sess.listener_down) .stopped else .none;
}

/// The wallet *process*'s own RPC endpoint (127.0.0.1 + the capability's bound
/// port), with the per-session `--rpc-login` credentials so the HTTP digest
/// handshake succeeds — distinct from the daemon's `CoinAuth`. Only valid for
/// `coin.hasExternalWallet()` coins, and only once the wallet-rpc has been
/// spawned (`creds_set`); before that the empty creds just fail.
pub fn authFor(coin: Coin, sess: *const Session) models.CoinAuth {
    const ew = coin.externalWallet().?;
    // In-daemon wallet (no separate process / per-session creds): point at the
    // daemon's own RPC endpoint. A coin whose in-daemon wallet RPC needs real
    // auth resolves it inside its hooks (Ergo uses a fixed api_key), so empty
    // creds here are correct.
    const port = if (ew.rpc_port) |f| f() else coin.rpcDefaultPort();
    if (ew.process_argv == null or !sess.creds_set)
        return .{ .rpc_user = "", .rpc_password = "", .ip_address = "127.0.0.1", .port = port };
    return .{
        .rpc_user = sess.user_buf[0..],
        .rpc_password = sess.pass_buf[0..],
        .ip_address = "127.0.0.1",
        .port = port,
    };
}

/// Turn a wallet-op error name (`@errorName`, e.g. from nerva's `walletRpcError`)
/// into a sentence the user can act on. For errors we don't specifically map, show
/// the daemon's own `detail` message when present (the real reason), falling back
/// to the raw error name so nothing is silently swallowed.
pub fn friendlyWalletError(name: []const u8, detail: []const u8) []const u8 {
    const eql = std.mem.eql;
    if (eql(u8, name, "WalletAlreadyExists"))
        return "A wallet already exists for this coin — remove it before restoring, or open it instead.";
    if (eql(u8, name, "SeedWordsInvalid") or eql(u8, name, "InvalidSeed"))
        return "Those seed words weren't accepted. Check the spelling and that all 25 words are correct.";
    if (eql(u8, name, "WrongPassword"))
        return "That password didn't match this wallet.";
    if (detail.len > 0) return detail;
    // Fallbacks (only when the backend gave no specific reason) for the
    // launch-with-password flow, where a wrong password makes the wallet service
    // exit without a message rather than returning a daemon error.
    if (eql(u8, name, "WalletOpenFailed"))
        return "Couldn't open the wallet — check the password, and that the daemon is running and synced.";
    if (eql(u8, name, "WalletServiceFailed"))
        return "The wallet service didn't start. Press i to reinstall it, then try again.";
    // Hit when a wallet op is attempted in the seconds between the daemon coming
    // up and its wallet service answering — a wait, not a fault.
    if (eql(u8, name, "WalletServiceNotReady"))
        return "The wallet service is still starting — try again in a moment.";
    if (eql(u8, name, "WalletCreateFailed"))
        return "Couldn't create the wallet. Check the daemon is running, then try again.";
    if (eql(u8, name, "WalletRescanFailed"))
        return "Wallet restored, but the rescan to find existing funds didn't start. Replace the wallet and restore again to retry.";
    return name;
}

// ---- the launch-with-password wallet shape ----------------------------------
//
// Nerva's wallet-rpc is spawned once, password-less, and told which wallet to
// open over RPC. Zano's `simplewallet` and Epic's `epic-wallet owner_api` can't
// do that: the server serves only the wallet file it was handed on its command
// line, with the password, so BoxWallet (re)launches it per operation instead of
// eagerly alongside the daemon (`ensure` answers `.not_applicable` for them).
//
// That sequence — materialize the wallet if the op creates one, launch the
// server against it, confirm the password opens it — is process mechanics, not
// presentation, so it lives here and both front-ends call `setupWithPassword`.
// It used to live in `app.zig` alone, which is why the GUI could only tell the
// user to go and use the TUI.

/// Choose the most informative line from a wallet process's captured
/// stdout/stderr tail. `simplewallet` (and the epee family generally) prints a
/// clear reason on a failed open — a wrong password, an unreadable / corrupt or
/// version-incompatible wallet file, a refused daemon connection — usually right
/// before it exits, so the *last* error-like line wins, falling back to the last
/// non-empty line. Leading log timestamps are stripped. Returns a slice into
/// `tail` (empty only if `tail` has no content).
pub fn pickWalletError(tail: []const u8) []const u8 {
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
        const line = proc.stripLogTimestamp(std.mem.trim(u8, raw, " \t\r"));
        if (line.len == 0) continue;
        if (proc.matchesAny(line, &noise)) continue;
        fallback = line;
        if (proc.matchesAny(line, &markers)) hit = line;
    }
    return if (hit.len != 0) hit else fallback;
}

/// Read the wallet process's captured stdout/stderr and stash the most
/// error-like line in `detail`, so a failed launch reports why (surfaced by
/// `friendlyWalletError`). Best-effort: leaves the sink untouched on any IO
/// hiccup or when nothing was printed, so the caller falls back to the generic
/// message.
fn setErrFromCapture(detail: *Coin.WalletErrSink, io: std.Io, file: *std.Io.File) void {
    const stat = file.stat(io) catch return;
    var buf: [8 * 1024]u8 = undefined;
    // Bias to the tail: the fatal line lands last, just before the process exits.
    const off = if (stat.size > buf.len) stat.size - buf.len else 0;
    const n = file.readPositionalAll(io, &buf, off) catch return;
    const pick = pickWalletError(buf[0..n]);
    if (pick.len != 0) detail.set(pick);
}

/// Launch the coin's wallet RPC server against the managed wallet file, opened
/// with `wallet_password`, and wait until it answers — the open path for
/// launch-with-password external wallets, whose RPC can only serve the wallet it
/// was started on. Any wallet process still serving a previous wallet is torn
/// down first. On a wrong password the server exits without ever binding its
/// port, so a bounded reachability wait that elapses is reported as a failed
/// open.
///
/// The caller owns the session for the duration (its own poll loop must not reap
/// the child meanwhile) and is responsible for its own "wallet is open" flag —
/// that stays front-end state, as it does for `ensure`.
pub fn launchWithPassword(
    sess: *Session,
    coin: Coin,
    install_root: []const u8,
    home_dir: []const u8,
    wallet_password: []const u8,
    detail: *Coin.WalletErrSink,
) !void {
    const ew = coin.externalWallet() orelse return error.NoExternalWallet;
    const argv_fn = ew.launch_server_argv orelse return error.Unsupported;
    const port = ew.rpc_port.?();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Tear down any wallet process still serving a previous wallet, and the
    // listener that was receiving for it.
    killListener(sess);
    sess.listener_down = false;
    if (sess.child) |*child| {
        child.kill(io);
        sess.child = null;
    }

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
    const cap_path = try std.fs.path.join(a, &.{ install_root, cap_name });
    var cap_file: ?std.Io.File = std.Io.Dir.createFileAbsolute(io, cap_path, .{ .read = true }) catch null;
    defer if (cap_file) |*f| {
        f.close(io);
        std.Io.Dir.deleteFileAbsolute(io, cap_path) catch {};
    };
    const capture: std.process.SpawnOptions.StdIo = if (cap_file) |f| .{ .file = f } else .ignore;

    // argv is consumed by spawn (fork/exec copies it), so the local arena can be
    // freed right after. The wallet password rides argv only — never disk.
    const argv = try argv_fn(a, install_root, home_dir, port, wallet_password);
    const child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = capture,
        .stderr = capture,
        .create_no_window = builtin.os.tag == .windows,
    }) catch return error.WalletServiceFailed;
    sess.child = child;

    // Wait for the wallet RPC to bind its port (or the process to die on a bad
    // password / unreadable wallet). Bounded so a never-answering server can't
    // wedge the caller.
    const auth = authFor(coin, sess);
    var waited: u32 = 0;
    const step: u32 = 250;
    const limit: u32 = 25_000;
    while (waited < limit) : (waited += step) {
        if (rpc.daemonReachable(a, auth)) return;
        // Fast failure path: simplewallet refuses a bad password / can't read the
        // wallet and exits before ever binding its port, so reap-on-exit lets us
        // fail at once — with the reason it printed — rather than waiting out the
        // whole timeout. (POSIX; Windows times out then reads the same capture.)
        if (builtin.os.tag != .windows) {
            if (sess.child) |ch| if (ch.id) |pid| {
                if (proc.reapNoHang(pid)) {
                    sess.child = null;
                    if (cap_file) |*f| setErrFromCapture(detail, io, f);
                    return error.WalletOpenFailed;
                }
            };
        }
        io.sleep(.fromMilliseconds(step), .awake) catch {};
    }
    if (cap_file) |*f| setErrFromCapture(detail, io, f);
    return error.WalletOpenFailed;
}

/// Run one managed-wallet operation for the launch-with-password shape, on
/// behalf of either front-end. Returns the generated mnemonic for `.create` (the
/// caller shows it to be written down) and null for every other op.
///
/// The order is the whole point and is the same for all three "there is no
/// wallet yet" ops: put the wallet on disk first (a one-shot CLI run — Zano's
/// `--generate-new-wallet`, Epic's `init -r`, or a copied-in wallet file),
/// *then* launch the server against it, *then* confirm the password opens it. A
/// wrong password makes the server exit instead of binding, which
/// `launchWithPassword` reports with the reason the process printed.
///
/// `password`, `seed_words` and `file_path` are the caller's inputs, used here
/// and never stored; the secrets stay in the caller's bounded buffers.
pub fn setupWithPassword(
    sess: *Session,
    coin: Coin,
    a: std.mem.Allocator,
    install_root: []const u8,
    home_dir: []const u8,
    op: walletmenu.SetupOp,
    password: []const u8,
    seed_words: []const u8,
    file_path: []const u8,
    detail: *Coin.WalletErrSink,
) !?models.Seed {
    const ew = coin.externalWallet() orelse return error.NoExternalWallet;
    switch (op) {
        .create => {
            try (ew.cli_create orelse return error.Unsupported)(a, install_root, home_dir, password, detail);
            try launchWithPassword(sess, coin, install_root, home_dir, password, detail);
            // The seed is read back over the now-running server's RPC.
            const seed = try ew.create(a, authFor(coin, sess), password, detail);
            startListener(sess, coin, install_root, home_dir, password);
            return seed;
        },
        .restore_seed => {
            // The coin's CLI materializes the wallet from the phrase (Epic's
            // `init -r`); the server then opens what it wrote.
            try ew.restore_seed(a, authFor(coin, sess), install_root, home_dir, password, seed_words, detail);
            try launchWithPassword(sess, coin, install_root, home_dir, password, detail);
            try ew.open(a, authFor(coin, sess), password, detail);
        },
        .restore_file => {
            // Import the wallet file onto disk, then launch the server against it
            // and confirm the password opens it — same shape as the seed restore.
            try (ew.restore_file orelse return error.Unsupported)(a, authFor(coin, sess), home_dir, file_path, password, detail);
            try launchWithPassword(sess, coin, install_root, home_dir, password, detail);
            try ew.open(a, authFor(coin, sess), password, detail);
        },
        .open => {
            try launchWithPassword(sess, coin, install_root, home_dir, password, detail);
            try ew.open(a, authFor(coin, sess), password, detail);
        },
        // Locking this shape means ending the processes that hold the wallet
        // open: the server was launched with the password and keeps the wallet
        // open for as long as it runs, and the listener likewise. Ask the server
        // to close it first so it lets go cleanly, but the kill is what makes it
        // locked — so it happens whether or not that ask succeeded.
        .lock => {
            if (ew.lock) |close| close(a, authFor(coin, sess), detail) catch {};
            detail.len = 0; // a refused close isn't the outcome — the kill is
            kill(sess);
            return null;
        },
        // Not setup ops: they use the wallet as it stands, and running them
        // through here would relaunch — and so re-lock — the process serving it.
        // Front-ends call `showSeed` / `backupFile` directly.
        .show_seed, .backup_file => return error.Unsupported,
    }
    startListener(sess, coin, install_root, home_dir, password);
    return null;
}

// ---- backing up a managed wallet --------------------------------------------

/// Read the wallet's recovery phrase for the user to write down, checking
/// `password` again (see `ExternalWallet.show_seed`). Uses the wallet process
/// already running for `sess`, or the wallet file under `home_dir`, as the coin
/// needs — nothing is relaunched here, so this neither opens nor closes
/// anything. The result is the secret: the caller shows it and wipes it.
pub fn showSeed(
    sess: *const Session,
    coin: Coin,
    a: std.mem.Allocator,
    home_dir: []const u8,
    password: []const u8,
    detail: *Coin.WalletErrSink,
) !models.Seed {
    const ew = coin.externalWallet() orelse return error.NoExternalWallet;
    const f = ew.show_seed orelse return error.Unsupported;
    return f(a, authFor(coin, sess), home_dir, password, detail);
}

/// Longest path `backupFile` writes into its caller's buffer.
pub const backup_path_max = 512;

/// Where a wallet-file backup goes: `<install_root>/<abbrev>-wallet-backup-<unix
/// seconds><ext>`. The same shape the in-daemon key-dump backup uses, for the
/// same reason — a fresh name per backup, so an earlier one is never
/// overwritten. Written into `buf`; errors `error.NoSpaceLeft` if it won't fit.
pub fn backupPath(buf: []u8, install_root: []const u8, abbrev: []const u8, ts: i64, ext: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}{c}{s}-wallet-backup-{d}{s}", .{ install_root, std.fs.path.sep, abbrev, ts, ext });
}

/// Copy `coin`'s managed wallet file to a fresh timestamped path under
/// `install_root` (see `backupPath`) and return that path, written into
/// `out`, so the front-end can say where it went. A file copy — works on a
/// locked wallet too, and touches nothing of the wallet's own.
pub fn backupFile(
    coin: Coin,
    a: std.mem.Allocator,
    io: std.Io,
    install_root: []const u8,
    home_dir: []const u8,
    out: []u8,
    detail: *Coin.WalletErrSink,
) ![]const u8 {
    const ew = coin.externalWallet() orelse return error.NoExternalWallet;
    const f = ew.backup_file orelse return error.Unsupported;
    const path = try backupPath(out, install_root, coin.coinNameAbbrev(), std.Io.Timestamp.now(io, .real).toSeconds(), ew.backup_file_ext);
    try f(a, home_dir, path, detail);
    return path;
}

// ---- tests ------------------------------------------------------------------

const nerva = @import("coins/nerva.zig");
const ergo = @import("coins/ergo.zig");
const bitcoin = @import("coins/bitcoin.zig");
const zano = @import("coins/zano.zig");
const epic = @import("coins/epic.zig");
const registry = @import("registry.zig");

test "authFor: before the wallet-rpc is spawned the creds are empty" {
    var c: nerva.Nerva = .{};
    const sess: Session = .{};
    const auth = authFor(c.coin(), &sess);
    // The wallet process's own port, not the daemon's — the endpoint is known
    // before the process exists; only the credentials aren't.
    try std.testing.expectEqualStrings(nerva.Nerva.wallet_rpc_port, auth.port);
    try std.testing.expectEqualStrings("127.0.0.1", auth.ip_address);
    try std.testing.expectEqualStrings("", auth.rpc_user);
    try std.testing.expectEqualStrings("", auth.rpc_password);
}

test "authFor: once spawned it carries the per-session credentials" {
    var c: nerva.Nerva = .{};
    var sess: Session = .{};
    @memset(&sess.user_buf, 'u');
    @memset(&sess.pass_buf, 'p');
    sess.creds_set = true;

    const auth = authFor(c.coin(), &sess);
    try std.testing.expectEqualStrings(nerva.Nerva.wallet_rpc_port, auth.port);
    try std.testing.expectEqual(@as(usize, cred_len), auth.rpc_user.len);
    try std.testing.expectEqual(@as(usize, cred_len), auth.rpc_password.len);
    try std.testing.expectEqual(@as(u8, 'u'), auth.rpc_user[0]);
    try std.testing.expectEqual(@as(u8, 'p'), auth.rpc_password[0]);
}

test "authFor: an in-daemon wallet points at the daemon's port with no creds" {
    var c: ergo.Ergo = .{};
    const coin = c.coin();
    var sess: Session = .{};
    // Even with creds set, an in-daemon wallet (no `process_argv`) must not send
    // them — its hooks authenticate their own way.
    @memset(&sess.user_buf, 'u');
    @memset(&sess.pass_buf, 'p');
    sess.creds_set = true;

    const auth = authFor(coin, &sess);
    try std.testing.expectEqualStrings(coin.rpcDefaultPort(), auth.port);
    try std.testing.expectEqualStrings("", auth.rpc_user);
    try std.testing.expectEqualStrings("", auth.rpc_password);
}

test "ensure: a coin with no external wallet process is left alone" {
    var b: bitcoin.Bitcoin = .{};
    var sess: Session = .{};
    try std.testing.expectEqual(Ensure.not_applicable, ensure(&sess, b.coin(), "/nope", "/nope", null));
    try std.testing.expect(sess.child == null);
    // The latch must stay clear, or a later capability change would be masked.
    try std.testing.expect(!sess.attempted);
    try std.testing.expect(!sess.creds_set);
}

test "ensure: a launch-with-password wallet is not spawned eagerly" {
    // Zano's simplewallet can only serve the one wallet file it was launched
    // with, so it's started per-open (with the password), never up-front.
    var z: zano.Zano = .{};
    var sess: Session = .{};
    try std.testing.expectEqual(Ensure.not_applicable, ensure(&sess, z.coin(), "/nope", "/nope", null));
    try std.testing.expect(sess.child == null);
    try std.testing.expect(!sess.attempted);
}

/// Is something already listening on 127.0.0.1:`port_text`? Test-only, and
/// deliberately probed by *binding*: a successful bind is proof nothing else
/// holds the port, where a connect attempt only tells us about this instant.
fn portServed(comptime port_text: []const u8) bool {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const port = std.fmt.parseInt(u16, port_text, 10) catch unreachable;
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
    var server = addr.listen(io, .{}) catch return true;
    server.deinit(io);
    return false;
}

test "ensure: a missing wallet-rpc binary is reported once, not every tick" {
    var c: nerva.Nerva = .{};
    const coin = c.coin();
    var sess: Session = .{};

    // `ensure` refuses a busy port before it ever tries to spawn, so this test's
    // premise only holds while nothing is serving that port. A developer running
    // BoxWallet against a real Nerva wallet on the same machine would otherwise
    // see a green suite turn red for a reason that has nothing to do with their
    // change — the sibling test below skips for the same reason, from the other
    // side of the same check.
    if (portServed(nerva.Nerva.wallet_rpc_port)) return error.SkipZigTest;

    // No install under this root, so the spawn can't find the wallet-rpc binary —
    // exactly what an install from before it was bundled looks like.
    const empty_root = "/nonexistent/boxwallet-extwallet-test";

    switch (ensure(&sess, coin, empty_root, empty_root, null)) {
        .spawn_failed => {},
        else => |o| {
            std.debug.print("expected spawn_failed, got {s}\n", .{@tagName(o)});
            return error.TestUnexpectedResult;
        },
    }
    try std.testing.expect(sess.child == null);
    try std.testing.expect(sess.attempted);

    // Second call must not retry (and so must not re-report) — that latch is the
    // only thing stopping a broken install from spamming the log every tick.
    try std.testing.expectEqual(Ensure.already_attempted, ensure(&sess, coin, empty_root, empty_root, null));
}

test "ensure: a port already served is refused, and doesn't latch the retry" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var c: nerva.Nerva = .{};
    const coin = c.coin();
    var sess: Session = .{};

    // Stand in for a squatter — another BoxWallet, or a service orphaned by one
    // that was killed without shutting down — by listening on the wallet port.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const port = std.fmt.parseInt(u16, nerva.Nerva.wallet_rpc_port, 10) catch unreachable;
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
    var server = addr.listen(io, .{}) catch return error.SkipZigTest; // port in real use
    defer server.deinit(io);

    try std.testing.expectEqual(Ensure.port_busy, ensure(&sess, coin, "/nonexistent", "/nonexistent", null));
    try std.testing.expect(sess.child == null);
    // Crucially NOT latched: the moment the squatter goes away this must be able
    // to spawn, rather than staying broken for the rest of the run.
    try std.testing.expect(!sess.attempted);
    try std.testing.expect(!sess.creds_set);
}

test "kill: wipes the credentials and is idempotent" {
    var sess: Session = .{};
    @memset(&sess.user_buf, 'u');
    @memset(&sess.pass_buf, 'p');
    sess.creds_set = true;
    sess.attempted = true;

    kill(&sess);
    try std.testing.expect(!sess.creds_set);
    try std.testing.expect(!sess.attempted);
    // The credentials unlock the spend key, so they must not linger in the buffer.
    for (sess.user_buf) |b| try std.testing.expectEqual(@as(u8, 0), b);
    for (sess.pass_buf) |b| try std.testing.expectEqual(@as(u8, 0), b);

    kill(&sess); // no child, no creds — must still be safe
    try std.testing.expect(sess.child == null);
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

test "setupWithPassword: every launch-with-password coin wires what the flow needs" {
    // The flow is fixed — materialize on disk, launch the server, open it — and
    // each step is a different optional hook. A coin that sets
    // `launch_server_argv` but forgets one of the others would compile and then
    // fail at the user's password prompt, on the front-end that happened to try
    // it first. Assert the shape instead, for every registered coin.
    inline for (registry.coin_types) |T| {
        var impl: T = .{};
        const coin = impl.coin();
        if (coin.walletLaunchesWithPassword()) {
            const ew = coin.externalWallet().?;
            // The server itself, and the port `launchWithPassword` waits on.
            try std.testing.expect(ew.launch_server_argv != null);
            try std.testing.expect(ew.rpc_port != null);
            // Create is a CLI bootstrap first: the server can't make the wallet
            // it would have to be launched against.
            try std.testing.expect(ew.cli_create != null);
            // ...and a wallet that can be made must be removable again, or the
            // front-ends' "replace" offers a dead end.
            try std.testing.expect(ew.remove != null);
        }
    }
}

/// Spawn a stand-in for a wallet-side process: `sleep` for a long-lived one, or
/// `true` for one that exits at once. POSIX only — the callers skip Windows.
fn spawnStandIn(io: std.Io, long_lived: bool) !std.process.Child {
    const argv: []const []const u8 = if (long_lived) &.{ "sleep", "30" } else &.{"true"};
    return std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

test "setupWithPassword: locking this shape ends the server and the listener" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The server keeps the wallet open for as long as it runs, so a lock that
    // left it (or the listener) alive would only look locked. Epic's close ask
    // fails here — no per-session secret, so it never reaches the network — and
    // the lock must happen anyway.
    var e: epic.Epic = .{};
    var sess: Session = .{};
    sess.child = try spawnStandIn(io, true);
    sess.listener = try spawnStandIn(io, true);
    var detail: Coin.WalletErrSink = .{};
    const made = try setupWithPassword(
        &sess,
        e.coin(),
        std.testing.allocator,
        "/nonexistent",
        "/nonexistent",
        .lock,
        "",
        "",
        "",
        &detail,
    );
    try std.testing.expect(made == null);
    try std.testing.expect(sess.child == null);
    try std.testing.expect(sess.listener == null);
    try std.testing.expectEqual(ListenerState.none, probeListener(&sess));
    // The refused close isn't reported as the outcome.
    try std.testing.expectEqual(@as(usize, 0), detail.len);
}

test "probeListener: none without one, running while up, stopped once it exits" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sess: Session = .{};
    try std.testing.expectEqual(ListenerState.none, probeListener(&sess));

    sess.listener = try spawnStandIn(io, true);
    try std.testing.expectEqual(ListenerState.running, probeListener(&sess));
    kill(&sess);
    try std.testing.expectEqual(ListenerState.none, probeListener(&sess));

    // One that exits on its own reads as stopped — and stays stopped: nothing
    // restarts it without the password.
    sess.listener = try spawnStandIn(io, false);
    var state = probeListener(&sess);
    var tries: usize = 0;
    while (state == .running and tries < 200) : (tries += 1) {
        io.sleep(.fromMilliseconds(10), .awake) catch {};
        state = probeListener(&sess);
    }
    try std.testing.expectEqual(ListenerState.stopped, state);
    try std.testing.expect(sess.listener == null);
    try std.testing.expectEqual(ListenerState.stopped, probeListener(&sess));

    // Tearing the wallet down (lock, daemon stop) clears it.
    kill(&sess);
    try std.testing.expectEqual(ListenerState.none, probeListener(&sess));
}

test "startListener: a coin without a listener starts nothing" {
    var z: zano.Zano = .{};
    var sess: Session = .{};
    startListener(&sess, z.coin(), "/nonexistent", "/nonexistent", "pw");
    try std.testing.expect(sess.listener == null);
    try std.testing.expectEqual(ListenerState.none, probeListener(&sess));
}

test "startListener: a listener that can't spawn reads as stopped, not running" {
    // Epic's listener binary isn't under a nonexistent install root, so the
    // spawn fails; the wallet is open regardless, and the state says so.
    var e: epic.Epic = .{};
    var sess: Session = .{};
    startListener(&sess, e.coin(), "/nonexistent-bw-install", "test-epic-listener-home", "pw");
    try std.testing.expect(sess.listener == null);
    try std.testing.expectEqual(ListenerState.stopped, probeListener(&sess));
}

test "friendlyWalletError: mapped reasons win, then the daemon's own message" {
    // The three mapped errors are actionable on their own and must not be
    // replaced by a raw daemon string.
    try std.testing.expectEqualStrings(
        "That password didn't match this wallet.",
        friendlyWalletError("WrongPassword", "failed to read wallet file"),
    );
    try std.testing.expect(std.mem.startsWith(
        u8,
        friendlyWalletError("WalletAlreadyExists", "some detail"),
        "A wallet already exists",
    ));
    try std.testing.expect(std.mem.startsWith(
        u8,
        friendlyWalletError("InvalidSeed", ""),
        "Those seed words weren't accepted",
    ));

    // Unmapped: the daemon's real reason beats every generic fallback.
    try std.testing.expectEqualStrings(
        "daemon is busy",
        friendlyWalletError("WalletOpenFailed", "daemon is busy"),
    );
    // ...and with no detail, the fallback sentence rather than the bare name.
    try std.testing.expect(std.mem.startsWith(
        u8,
        friendlyWalletError("WalletOpenFailed", ""),
        "Couldn't open the wallet",
    ));
    // A wallet op racing the service's start-up is a "wait", not a fault.
    try std.testing.expect(std.mem.startsWith(
        u8,
        friendlyWalletError("WalletServiceNotReady", ""),
        "The wallet service is still starting",
    ));
    // Nothing is silently swallowed: an unknown error still surfaces its name.
    try std.testing.expectEqualStrings("Whatever", friendlyWalletError("Whatever", ""));
}
