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

    pub fn isRunning(self: *const Session) bool {
        return self.child != null;
    }
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
    sess.attempted = true;

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
    if (sess.child) |*child| {
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
        sess.child = null;
    }
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

// ---- tests ------------------------------------------------------------------

const nerva = @import("coins/nerva.zig");
const ergo = @import("coins/ergo.zig");
const bitcoin = @import("coins/bitcoin.zig");
const zano = @import("coins/zano.zig");

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

test "ensure: a missing wallet-rpc binary is reported once, not every tick" {
    var c: nerva.Nerva = .{};
    const coin = c.coin();
    var sess: Session = .{};

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
