const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const install_mod = @import("../install.zig");
const conf = @import("../conf.zig");
const rpc = @import("../rpc.zig");
const Coin = @import("../coin.zig").Coin;

/// Salvium (SAL) backend. Salvium is a Monero/CryptoNote fork (RandomX PoW), so it
/// follows the same external-wallet shape as Nerva (`salvium.zig`'s sibling
/// reference) — a separate `salvium-wallet-rpc` process — rather than the
/// bitcoin-core coins.
///
/// Two things set Salvium apart from the bitcoin-core coins:
///
///   * **Distribution** — every target ships a single `.zip` whose three binaries
///     (`salviumd`, `salvium-wallet-cli`, `salvium-wallet-rpc`) sit at the archive
///     root — no `bin/` subdir and no versioned wrapper dir — so they extract
///     straight into the install root with no promote step. `std.zip` doesn't
///     restore the unix executable bit, so `install` re-sets it on POSIX.
///   * **RPC** — Monero's daemon RPC, not the bitcoin JSON-RPC. `get_info` is a
///     `POST /json_rpc` method returning a flat result; sync is derived from
///     `height` vs `target_height` (0 once caught up) and the `synchronized` flag,
///     and the peer count from the connection counts. Shutdown is the direct
///     `POST /stop_daemon` endpoint. The daemon is unauthenticated by default, so
///     no basic auth is sent (mirrors Ergo's keyless REST).
pub const Salvium = struct {
    /// Whether the coin is exposed in the nav. False keeps it out of the left
    /// bar entirely (registered but hidden) until it's ready for users.
    pub const live = false;
    pub const coin_name = "Salvium";
    pub const coin_name_abbrev = "SAL";
    /// One-line description shown under the coin name on the detail pane.
    pub const coin_description = "Privacy Layer-1 with private DeFi (Monero-based).";
    /// Salvium brand colour (`#RRGGBB`), for tinting the coin in the frontend.
    /// The green from Salvium's official brand-assets coin icon.
    pub const coin_color = "#0AEB85";
    /// Donation address for BoxWallet development, in Salvium's own
    /// currency.
    /// TODO(richard): replace with the real SAL tip address.
    pub const tip_address = "TODO-SAL-TIP-ADDRESS-NOT-SET";
    /// Salvium is proof-of-work (RandomX, Monero-derived) — no wallet staking.
    pub const proof_of_stake = false;
    pub const conf_file = "salvium.conf";

    // Data dir names. Monero forks use `~/.<name>` on Linux *and* macOS (not the
    // macOS Library convention) and `%APPDATA%\<name>` on Windows — exactly what
    // the shared `conf.dataDir(posix, win)` produces.
    pub const home_dir = ".salvium";
    pub const home_dir_win = "salvium";

    /// Unauthenticated by default; a value is kept only so the shared conf/readAuth
    /// path has a username to write (the daemon ignores it).
    pub const rpc_default_username = "salviumrpc";
    pub const rpc_default_port = "19081";
    pub const core_version = "1.1.1b";

    // Binary names. Windows appends `.exe`. The wallet CLI is `salvium-wallet-cli`;
    // there's no `*-tx` helper. `salvium-wallet-rpc` drives the (external) wallet —
    // BoxWallet launches it alongside the daemon for create/restore/balance (see
    // the external-wallet section below), so it's promoted too.
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    pub const daemon_file = "salviumd" ++ exe_suffix;
    pub const cli_file = "salvium-wallet-cli" ++ exe_suffix;
    pub const wallet_rpc_file = "salvium-wallet-rpc" ++ exe_suffix;

    /// Port BoxWallet binds the managed `salvium-wallet-rpc` to (localhost only).
    /// Must avoid the daemon's reserved ports: P2P 19080, RPC 19081, and — easy to
    /// miss — the **ZMQ-RPC** server at 19082 (Monero/Salvium bind it by default).
    /// Colliding there makes *salviumd* fail to start ("ZMQ RPC Server bind failed:
    /// Address already in use") and die, so the wallet port is moved well clear.
    pub const wallet_rpc_port = "19085";

    /// The single managed wallet's filename, inside the wallet dir. Fixed so
    /// `walletExists` is a pure disk check and every wallet-RPC call targets the
    /// same file by name.
    const wallet_name = "BoxWallet";

    /// Salvium uses an 8-decimal atomic unit (`CRYPTONOTE_DISPLAY_DECIMAL_POINT = 8`,
    /// `COIN = 1e8`, verified against salvium/salvium `cryptonote_config.h` — unlike
    /// Monero/Nerva's 12): the wallet RPC reports balances as integer atomic units,
    /// so divide by this to get whole SAL.
    const atomic_per_sal: f64 = 100_000_000;

    /// A Salvium (Monero) deterministic restore seed is exactly 25 words.
    pub const seed_word_count = 25;

    const release_base = "https://github.com/salvium/salvium/releases/download/v" ++ core_version ++ "/";

    // The per-target release asset name (without the `.zip`). Every Salvium bundle
    // is a `.zip`; the names follow Salvium's own asset naming — Linux carries the
    // build's `ubuntu22.04-linux` tag, macOS/Windows their short tags. No 32-bit
    // Linux, no ARM Windows build is published.
    const asset: ?[]const u8 = switch (builtin.os.tag) {
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => "salvium-v" ++ core_version ++ "-ubuntu22.04-linux-x86_64",
            .aarch64 => "salvium-v" ++ core_version ++ "-ubuntu22.04-linux-aarch64",
            else => null,
        },
        .macos => switch (builtin.cpu.arch) {
            .x86_64 => "salvium-v" ++ core_version ++ "-macos-x86_64",
            .aarch64 => "salvium-v" ++ core_version ++ "-macos-aarch64",
            else => null,
        },
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => "salvium-v" ++ core_version ++ "-win64",
            else => null,
        },
        else => null,
    };

    /// The download URL + format for the build target, or null where Salvium
    /// publishes no matching binary (e.g. Linux i686, ARM Windows).
    const download: ?install_mod.Download = if (asset) |a| .{
        .url = release_base ++ a ++ ".zip",
        .format = .zip,
    } else null;

    // The three binaries sit at the archive root — no wrapper dir, no `bin/` subdir
    // — so they extract straight into the install root and there's nothing to
    // promote or tidy. (`promoteAndTidy` is deliberately not called; see `install`.)
    const promote_files = [_][]const u8{ daemon_file, cli_file, wallet_rpc_file };

    // Scratch file the zip streams to before it's extracted from the seekable copy.
    pub const scratch_file = ".boxwallet-salvium.part";

    /// Build the type-erased `Coin` handle for this instance.
    pub fn coin(self: *Salvium) Coin {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // --- RPC (Monero daemon) ---------------------------------------------

    /// Subset of `get_info`'s result. Monero reports a flat object; `synchronized`
    /// is authoritative for sync state, with `height`/`target_height` as the
    /// fallback (`target_height` is 0 once caught up). Defaults keep the parse
    /// resilient to omitted fields.
    const SalviumInfo = struct {
        status: []const u8 = "",
        height: i64 = 0,
        target_height: i64 = 0,
        outgoing_connections_count: i64 = 0,
        incoming_connections_count: i64 = 0,
        synchronized: bool = false,
        mainnet: bool = false,
        testnet: bool = false,
        stagenet: bool = false,
    };

    /// Bound (ms) on a status/stop RPC round-trip. A healthy salviumd answers
    /// `get_info` in milliseconds; this cap exists so a wedged or over-busy daemon
    /// — one whose RPC thread is starved under load, so it accepts the connection
    /// but never replies — can't hang the poll worker (and, through it, the app's
    /// quit) forever. Without it a stuck daemon pins the status on "Checking…"
    /// indefinitely, because the poll never returns to clear it.
    const status_timeout_ms: u32 = 8000;

    /// Bound (ms) on a wallet-RPC op. A Monero wallet open/create/restore drives an
    /// initial refresh that can legitimately take many seconds, so these get a far
    /// longer cap than the status path — still bounded so a hung wallet service
    /// can't wedge the worker.
    const wallet_timeout_ms: u32 = 60_000;

    /// Fetch + parse `get_info`. Caller must `deinit` the returned `Parsed`.
    fn fetchInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !std.json.Parsed(models.JsonRpcResponse(SalviumInfo)) {
        const raw = try rpc.moneroPost(allocator, auth, "/json_rpc", "{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"get_info\"}", status_timeout_ms);
        defer allocator.free(raw);
        return std.json.parseFromSlice(
            models.JsonRpcResponse(SalviumInfo),
            allocator,
            raw,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
    }

    /// Salvium's block-target interval (seconds): `DIFFICULTY_TARGET_V2 = 120` in
    /// `cryptonote_config.h`. Used only to turn the block gap into a "behind by"
    /// estimate; the daemon never reports a tip timestamp we could use directly.
    const block_target_seconds: i64 = 120;

    /// Estimate how many seconds the local tip is behind the chain from the block
    /// gap. Monero's `get_info` carries no tip timestamp, and
    /// `get_last_block_header` returns `BUSY` mid-sync — exactly when the
    /// "behind by …" hint matters — so we approximate: each block still to fetch
    /// (`tip − height`) is about one block-target of chain time. Returns 0 when
    /// caught up, so the frontend shows no hint. Pure, so it's unit-testable; the
    /// frontend uses it directly (`BlockchainState.seconds_behind`) since the coin
    /// has no clock to synthesise a `tip_time`.
    fn estimateSecondsBehind(tip: i64, height: i64, synced: bool) i64 {
        const behind_blocks = @max(tip - height, 0);
        if (synced or behind_blocks == 0) return 0;
        return behind_blocks * block_target_seconds;
    }

    /// Live `get_info`, normalized for a frontend. Monero has no
    /// `verificationprogress`; sync is the `synchronized` flag, or `height`
    /// reaching the network `target_height` (which is 0 once caught up).
    pub fn blockchainState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.BlockchainState {
        var parsed = try fetchInfo(allocator, auth);
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        const tip = @max(r.target_height, r.height);
        const chain = if (r.testnet) "testnet" else if (r.stagenet) "stagenet" else "mainnet";
        const synced = r.synchronized or (r.height > 0 and (r.target_height == 0 or r.height >= r.target_height));
        return .{
            .chain = try allocator.dupe(u8, chain),
            .blocks = r.height,
            .headers = tip,
            .verification_progress = if (tip > 0)
                @as(f64, @floatFromInt(r.height)) / @as(f64, @floatFromInt(tip))
            else
                0,
            .synced = synced,
            .network_height = tip,
            // Monero gives no tip timestamp, so report how far behind the tip is
            // from the block gap — drives the shared "behind by …" sync readout.
            .seconds_behind = estimateSecondsBehind(tip, r.height, synced),
        };
    }

    /// Live `get_info`, normalized for a frontend. The peer count is the daemon's
    /// total connections; Salvium is proof-of-work, so `staking_active` is false.
    pub fn daemonInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.DaemonInfo {
        var parsed = try fetchInfo(allocator, auth);
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return .{
            .blocks = r.height,
            .connections = r.outgoing_connections_count + r.incoming_connections_count,
            .staking_active = false,
        };
    }

    /// Ask salviumd to shut down via Monero's direct `POST /stop_daemon` (not a
    /// `/json_rpc` method).
    pub fn requestStop(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        const reply = try rpc.moneroPost(allocator, auth, "/stop_daemon", "{}", status_timeout_ms);
        allocator.free(reply);
    }

    // --- Files / paths ---------------------------------------------------

    /// The daemon's default data directory (`~/.salvium`, `%APPDATA%\salvium` on
    /// Windows), where `salvium.conf` and the chain live.
    pub fn dataDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        return conf.dataDir(allocator, home, home_dir, home_dir_win);
    }

    /// True if `salviumd` (`salviumd.exe` on Windows) is already present under
    /// `install_root`.
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, daemon_file);
    }

    /// Download + unpack the Salvium daemon files into `install_root`.
    ///
    /// The bundle is a `.zip` whose three binaries sit at the archive root, so
    /// extraction drops them straight into the install root — there's nothing to
    /// promote. `std.zip` doesn't restore the unix executable bit, so on POSIX we
    /// re-set it; otherwise `salviumd`/the wallet binaries would land non-executable
    /// and fail to launch.
    pub fn install(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        const dl = download orelse return error.UnsupportedPlatform;
        try install_mod.downloadAndExtract(allocator, dl.url, dl.format, install_root, scratch_file, 0, progress);
        try makeExecutable(allocator, install_root);
        cleanupMacOsDir(allocator, install_root);
    }

    /// Re-set the executable bit on the promoted binaries (no-op on Windows, where
    /// `Permissions` carries no executable bit). `std.zip.extract` writes files with
    /// the default mode and ignores the archive's stored unix attributes, so the
    /// daemon/CLI/wallet-rpc come out non-executable on Linux/macOS without this.
    fn makeExecutable(allocator: std.mem.Allocator, install_root: []const u8) !void {
        if (!std.Io.File.Permissions.has_executable_bit) return;
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var dir = try std.Io.Dir.cwd().openDir(io, install_root, .{});
        defer dir.close(io);
        for (promote_files) |name| {
            var f = dir.openFile(io, name, .{}) catch continue;
            defer f.close(io);
            f.setPermissions(io, std.Io.File.Permissions.fromMode(0o755)) catch {};
        }
    }

    /// Drop the `__MACOSX` metadata dir some macOS-built zips carry at the root.
    /// Best-effort; absent on the Linux/Windows bundles.
    fn cleanupMacOsDir(allocator: std.mem.Allocator, install_root: []const u8) void {
        if (builtin.os.tag != .macos) return;
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var dir = std.Io.Dir.cwd().openDir(io, install_root, .{}) catch return;
        defer dir.close(io);
        dir.deleteTree(io, "__MACOSX") catch {};
    }

    /// The canonical `salvium.conf` body. salviumd parses this on startup (its
    /// `--config-file` defaults to `<data-dir>/salvium.conf`), so it must contain
    /// only Monero-style options. `rpc-bind-port` is the default RPC port stated
    /// explicitly so it's self-documenting and survives any upstream default change.
    const conf_body = "rpc-bind-port=" ++ rpc_default_port ++ "\n";

    /// Ensure the data dir and `salvium.conf` exist so the status poll's `readAuth`
    /// (which needs the conf present) succeeds.
    ///
    /// Unlike the bitcoin coins, salviumd *reads* this file on every startup. The
    /// shared `conf.populate` writes bitcoin keys (`rpcuser`, `server`, …) that
    /// Monero's parser rejects outright (`unrecognised option 'rpcuser'`), so
    /// salviumd exits before its RPC ever comes up — which looked like an
    /// unstoppable daemon. So we (over)write the canonical Monero conf instead.
    /// The clobbering write is deliberate: BoxWallet owns this conf and a stale
    /// bitcoin-style one is actively harmful, so prepare is self-healing. The
    /// `rpc-bind-port` is also salviumd's default; `readAuth` doesn't recognise that
    /// key and falls back to its defaults (`rpc_default_port`, unauthenticated),
    /// which already match, so the poll/stop path is unaffected.
    pub fn prepareConf(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        try conf.writeConf(io, data_dir, conf_file, conf_body);
    }

    /// Salvium's daemon runs in the foreground of its own process, so it's spawned
    /// detached (with `--non-interactive`) and the status poll confirms it came up
    /// — never the bitcoin `-daemon` fork path.
    pub fn launchMode() Coin.LaunchMode {
        return .foreground;
    }

    /// `salviumd --non-interactive` so it runs as a server rather than opening its
    /// interactive console. Caller owns the returned slice and its strings.
    pub fn daemonArgv(allocator: std.mem.Allocator, install_root: []const u8, _: []const u8) ![]const []const u8 {
        const path = try std.fs.path.join(allocator, &.{ install_root, daemon_file });
        errdefer allocator.free(path);

        const argv = try allocator.alloc([]const u8, 2);
        argv[0] = path;
        argv[1] = try allocator.dupe(u8, "--non-interactive");
        return argv;
    }

    // --- External wallet (Monero wallet-rpc) -----------------------------
    //
    // Salvium's wallet lives in a *separate* process (`salvium-wallet-rpc`), not the
    // daemon. BoxWallet launches it bound to localhost:`wallet_rpc_port`, locked to
    // per-session credentials (`--rpc-login <user>:<pass>`, HTTP digest auth — the
    // wallet RPC exposes the spend key and `sweep_all`, so localhost alone isn't
    // enough), pointed at the local daemon, and drives create/restore/open/balance
    // over Monero's wallet `POST /json_rpc`. All funds-sensitive: a wallet is only
    // ever created with a user-supplied password, never silently. See `coin.zig`'s
    // `ExternalWallet`.

    /// The managed wallet directory (`<datadir>/wallets`), where `salvium-wallet-rpc`
    /// creates and opens `BoxWallet`(+`.keys`). Caller owns the slice.
    fn walletDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        return std.fs.path.join(allocator, &.{ data_dir, "wallets" });
    }

    /// The managed wallet's on-disk location for the Settings tab: the Monero
    /// `<datadir>/wallets/BoxWallet` file plus its `.keys` companion. Caller owns
    /// the returned strings.
    pub fn walletPath(allocator: std.mem.Allocator, home: []const u8) !?Coin.WalletFile {
        const dir = try walletDir(allocator, home);
        defer allocator.free(dir);
        const path = try std.fs.path.join(allocator, &.{ dir, wallet_name });
        errdefer allocator.free(path);
        const keys = try std.fs.path.join(allocator, &.{ dir, wallet_name ++ ".keys" });
        return .{ .path = path, .keys = keys };
    }

    /// Port the wallet process is bound to — its RPC endpoint, distinct from the
    /// daemon's. The lifecycle in `app.zig` builds a `wallet_auth` from this.
    fn walletRpcPort() []const u8 {
        return wallet_rpc_port;
    }

    /// argv to spawn `salvium-wallet-rpc`, bound to `port` on localhost and pointed
    /// at the local daemon. `--wallet-dir` lets it create/open wallets by name over
    /// RPC; `--rpc-login <user>:<pass>` locks the wallet RPC to the per-session
    /// credentials BoxWallet generated, so another local process can't drive it
    /// (the wallet RPC exposes the spend key and `sweep_all`). Caller owns the
    /// returned slice and its strings.
    fn walletProcessArgv(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home: []const u8,
        port: []const u8,
        rpc_user: []const u8,
        rpc_password: []const u8,
    ) anyerror![]const []const u8 {
        const path = try std.fs.path.join(allocator, &.{ install_root, wallet_rpc_file });
        errdefer allocator.free(path);
        const dir = try walletDir(allocator, home);
        errdefer allocator.free(dir);
        const daemon_addr = try std.fmt.allocPrint(allocator, "127.0.0.1:{s}", .{rpc_default_port});
        errdefer allocator.free(daemon_addr);
        const login = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ rpc_user, rpc_password });
        errdefer allocator.free(login);

        const argv = try allocator.alloc([]const u8, 11);
        errdefer allocator.free(argv);
        argv[0] = path;
        argv[1] = try allocator.dupe(u8, "--wallet-dir");
        argv[2] = dir;
        argv[3] = try allocator.dupe(u8, "--rpc-bind-ip");
        argv[4] = try allocator.dupe(u8, "127.0.0.1");
        argv[5] = try allocator.dupe(u8, "--rpc-bind-port");
        argv[6] = try allocator.dupe(u8, port);
        argv[7] = try allocator.dupe(u8, "--daemon-address");
        argv[8] = daemon_addr;
        argv[9] = try allocator.dupe(u8, "--rpc-login");
        argv[10] = login;
        return argv;
    }

    /// True if the managed `BoxWallet` already exists on disk (its `.keys` file is
    /// the authoritative marker — the cache rebuilds from the daemon). A pure disk
    /// check, so the UI can decide "set up" vs "open" without a running process.
    fn walletExists(allocator: std.mem.Allocator, home: []const u8) bool {
        const dir = walletDir(allocator, home) catch return false;
        defer allocator.free(dir);
        return install_mod.fileExists(allocator, dir, wallet_name ++ ".keys");
    }

    // Wallet-RPC result subsets. `get_balance` reports atomic-unit integers;
    // `query_key` returns the requested key (the mnemonic, for create display).
    // `create_wallet`/`open_wallet` return an empty object on success, so an
    // absent `result` (Monero put an `error` in its place) signals failure.
    const WalletBalanceResult = struct { balance: u64 = 0, unlocked_balance: u64 = 0 };
    const QueryKeyResult = struct { key: []const u8 = "" };
    const EmptyResult = struct {};

    /// The `error` half of a Monero wallet-RPC reply (`{ "code": …, "message": … }`),
    /// present in place of `result` when an op fails. `walletRpcError` reads its
    /// `message` to give the user a specific reason rather than a bare "failed".
    const RpcErrObj = struct { code: i64 = 0, message: []const u8 = "" };

    /// JSON-RPC envelope that keeps the `error` object (unlike the shared
    /// `models.JsonRpcResponse`, which drops it) so wallet ops can translate the
    /// daemon's failure message into a precise BoxWallet error.
    fn WalletEnvelope(comptime T: type) type {
        return struct { result: ?T = null, @"error": ?RpcErrObj = null };
    }

    /// POST a wallet-RPC `method` with a raw JSON `params` object (a complete
    /// `{...}` literal — any user string in it must already be JSON-escaped via
    /// `rpc.jsonQuote`) and parse `result`/`error` into the envelope. Caller
    /// `deinit`s the `Parsed`.
    fn walletCall(
        comptime T: type,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        method: []const u8,
        params: []const u8,
    ) !std.json.Parsed(WalletEnvelope(T)) {
        const body = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"{s}\",\"params\":{s}}}",
            .{ method, params },
        );
        defer allocator.free(body);
        const raw = try rpc.moneroPost(allocator, auth, "/json_rpc", body, wallet_timeout_ms);
        defer allocator.free(raw);
        // `.alloc_always` so parsed strings (the mnemonic, the error message)
        // survive `raw` being freed.
        return std.json.parseFromSlice(
            WalletEnvelope(T),
            allocator,
            raw,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
    }

    /// Record the daemon's raw failure `message` into `detail` (for the UI/log) and
    /// return the mapped BoxWallet error. Used at every wallet-op failure so the
    /// real reason is never swallowed — even for messages we don't specifically map.
    fn failWallet(detail: *Coin.WalletErrSink, err: ?RpcErrObj, fallback: anyerror) anyerror {
        if (err) |e| detail.set(e.message);
        return walletRpcError(err, fallback);
    }

    /// Translate a Monero wallet-RPC `error` into the most specific BoxWallet error
    /// so the UI can tell the user *why* an op failed, not just that it did. Falls
    /// back to `fallback` when there's no error object or the message is unfamiliar.
    fn walletRpcError(err: ?RpcErrObj, fallback: anyerror) anyerror {
        const msg = (err orelse return fallback).message;
        if (containsIgnoreCase(msg, "already exists")) return error.WalletAlreadyExists;
        if (containsIgnoreCase(msg, "verification") or
            containsIgnoreCase(msg, "number of words") or
            containsIgnoreCase(msg, "invalid word")) return error.SeedWordsInvalid;
        if (containsIgnoreCase(msg, "invalid password") or
            containsIgnoreCase(msg, "wrong password") or
            containsIgnoreCase(msg, "failed to read")) return error.WrongPassword;
        return fallback;
    }

    /// Case-insensitive substring test (ASCII). Used to match Monero's English
    /// error strings regardless of how the daemon cases them.
    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
        }
        return false;
    }

    /// Create a new wallet named `BoxWallet` under `password`, then read back its
    /// freshly-generated 25-word mnemonic for the user to write down. Fails if a
    /// wallet of that name already exists (Monero returns an error → null result).
    fn walletCreate(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        password: []const u8,
        detail: *Coin.WalletErrSink,
    ) anyerror!models.Seed {
        const qpw = try rpc.jsonQuote(allocator, password);
        defer allocator.free(qpw);
        {
            const params = try std.fmt.allocPrint(
                allocator,
                "{{\"filename\":\"{s}\",\"password\":{s},\"language\":\"English\"}}",
                .{ wallet_name, qpw },
            );
            defer allocator.free(params);
            var parsed = try walletCall(EmptyResult, allocator, wallet_auth, "create_wallet", params);
            defer parsed.deinit();
            if (parsed.value.result == null) return failWallet(detail, parsed.value.@"error", error.WalletCreateFailed);
        }
        var parsed = try walletCall(QueryKeyResult, allocator, wallet_auth, "query_key", "{\"key_type\":\"mnemonic\"}");
        defer parsed.deinit();
        const r = parsed.value.result orelse return error.WalletCreateFailed;
        return models.Seed.from(r.key);
    }

    /// Restore the managed wallet from a 25-word deterministic `seed` under
    /// `password`. v1 does a full rescan (`restore_height` 0); a restore-height
    /// prompt is a future add. The seed's word count is checked first so an obvious
    /// typo fails fast with a clear error rather than a daemon-side rejection.
    fn walletRestoreSeed(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        install_root: []const u8,
        home: []const u8,
        password: []const u8,
        seed: []const u8,
        detail: *Coin.WalletErrSink,
    ) anyerror!void {
        // Normalize first: lowercase + single-space the words so a capitalized
        // first word or a paste with stray newlines/double spaces doesn't trip the
        // (case-sensitive) deterministic decode and look like a bad seed.
        const normalized = try normalizeSeed(allocator, seed);
        defer allocator.free(normalized);
        if (!isValidSeed(normalized)) return error.InvalidSeed;

        // The wallet is materialized on disk by a one-shot `salvium-wallet-cli
        // --generate-from-json` (the CLAUDE.md-blessed temp-secret path, mirroring
        // Nerva) and then opened over RPC like any other wallet — robust across
        // Monero-fork vintages regardless of which restore RPC the bundled
        // wallet-rpc exposes.
        try cliGenerateFromSeed(allocator, install_root, home, password, normalized, detail);
        try walletOpen(allocator, wallet_auth, password, detail);
    }

    /// Restore the managed wallet from `seed` by driving a one-shot
    /// `salvium-wallet-cli --generate-from-json`: the CLI reads the
    /// seed/password/filename from a temporary JSON spec and writes
    /// `BoxWallet`(+`.keys`) into the wallet dir, `--offline` so it never blocks on
    /// a chain sync. The spec carries the secret in plaintext, so it's overwritten
    /// and deleted the instant the call returns. Success is the `.keys` file
    /// appearing on disk — the CLI's exit code is unreliable across Monero vintages,
    /// so on failure its own stderr/stdout is surfaced as the reason.
    fn cliGenerateFromSeed(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home: []const u8,
        password: []const u8,
        seed: []const u8,
        detail: *Coin.WalletErrSink,
    ) !void {
        const dir = try walletDir(allocator, home);
        defer allocator.free(dir);
        const wallet_path = try std.fs.path.join(allocator, &.{ dir, wallet_name });
        defer allocator.free(wallet_path);

        // The --generate-from-json spec; every user string is JSON-escaped.
        const qpw = try rpc.jsonQuote(allocator, password);
        defer allocator.free(qpw);
        const qseed = try rpc.jsonQuote(allocator, seed);
        defer allocator.free(qseed);
        const qpath = try rpc.jsonQuote(allocator, wallet_path);
        defer allocator.free(qpath);
        const spec = try std.fmt.allocPrint(
            allocator,
            "{{\"version\":1,\"filename\":{s},\"scan_from_height\":0,\"password\":{s},\"seed\":{s}}}",
            .{ qpath, qpw, qseed },
        );
        defer allocator.free(spec);

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var dd = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
        defer dd.close(io);

        const spec_name = wallet_name ++ ".restore.json";
        try dd.writeFile(io, .{ .sub_path = spec_name, .data = spec });
        // Shred + delete the plaintext-secret spec however we leave this function.
        const blank = try allocator.alloc(u8, spec.len);
        @memset(blank, 0);
        defer allocator.free(blank);
        defer {
            dd.writeFile(io, .{ .sub_path = spec_name, .data = blank }) catch {};
            dd.deleteFile(io, spec_name) catch {};
        }

        const spec_path = try std.fs.path.join(allocator, &.{ dir, spec_name });
        defer allocator.free(spec_path);
        const cli_path = try std.fs.path.join(allocator, &.{ install_root, cli_file });
        defer allocator.free(cli_path);

        // `--command exit` plus the closed stdin (run uses `.ignore`, so the REPL
        // reads EOF) guarantees the CLI exits once the wallet is written; the
        // timeout is a backstop against any vintage that ignores both.
        const argv = [_][]const u8{
            cli_path,
            "--generate-from-json", spec_path,
            "--offline",
            "--log-level",          "0",
            "--command",            "exit",
        };
        const res = std.process.run(allocator, io, .{
            .argv = &argv,
            .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(120), .clock = .awake } },
        }) catch |err| {
            detail.set(@errorName(err));
            return error.WalletRestoreFailed;
        };
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);

        if (!install_mod.fileExists(allocator, dir, wallet_name ++ ".keys")) {
            const why = std.mem.trim(u8, if (res.stderr.len > 0) res.stderr else res.stdout, " \t\r\n");
            detail.set(if (why.len > 0) why else "salvium-wallet-cli did not create the wallet");
            return error.WalletRestoreFailed;
        }
    }

    /// Import an existing wallet file (browsed to) as the managed `BoxWallet`, then
    /// open it. Monero wallets are a `<name>`/`<name>.keys` pair; the `.keys` file
    /// holds the secret and is all that's needed — the cache rebuilds from the
    /// daemon on open, so only the (small) keys file is copied (no large-file slurp).
    /// Accepts either member of the pair from the picker and resolves the keys file.
    fn walletRestoreFile(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        home: []const u8,
        src_path: []const u8,
        password: []const u8,
        detail: *Coin.WalletErrSink,
    ) anyerror!void {
        const keys_src = if (std.mem.endsWith(u8, src_path, ".keys"))
            try allocator.dupe(u8, src_path)
        else
            try std.fmt.allocPrint(allocator, "{s}.keys", .{src_path});
        defer allocator.free(keys_src);

        const dest_dir = try walletDir(allocator, home);
        defer allocator.free(dest_dir);

        try copyKeysFile(allocator, keys_src, dest_dir, wallet_name ++ ".keys");
        try walletOpen(allocator, wallet_auth, password, detail);
    }

    /// Copy a (small) Monero `.keys` file from absolute `src_path` into `dest_dir`
    /// as `dest_name`, creating `dest_dir` if needed. Keys files are a few KB, so a
    /// single bounded read+write is fine (and avoids a streaming copy for a tiny
    /// file). The cache file is intentionally not copied — it regenerates on open.
    fn copyKeysFile(
        allocator: std.mem.Allocator,
        src_path: []const u8,
        dest_dir: []const u8,
        dest_name: []const u8,
    ) !void {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        // Open via (dir, basename) so an absolute picker path works the same way
        // the conf code opens files.
        const src_dir = std.fs.path.dirname(src_path) orelse ".";
        const src_base = std.fs.path.basename(src_path);
        var sd = std.Io.Dir.cwd().openDir(io, src_dir, .{}) catch return error.WalletFileNotFound;
        defer sd.close(io);
        var src = sd.openFile(io, src_base, .{}) catch return error.WalletFileNotFound;
        defer src.close(io);

        var buf: [64 * 1024]u8 = undefined;
        const n = try src.readPositionalAll(io, &buf, 0);

        var dd = try std.Io.Dir.cwd().createDirPathOpen(io, dest_dir, .{});
        defer dd.close(io);
        try dd.writeFile(io, .{ .sub_path = dest_name, .data = buf[0..n] });
    }

    /// Open the existing managed wallet with `password` so its balance can be read.
    /// Called once at process start when a wallet already exists.
    fn walletOpen(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        password: []const u8,
        detail: *Coin.WalletErrSink,
    ) anyerror!void {
        const qpw = try rpc.jsonQuote(allocator, password);
        defer allocator.free(qpw);
        const params = try std.fmt.allocPrint(
            allocator,
            "{{\"filename\":\"{s}\",\"password\":{s}}}",
            .{ wallet_name, qpw },
        );
        defer allocator.free(params);
        var parsed = try walletCall(EmptyResult, allocator, wallet_auth, "open_wallet", params);
        defer parsed.deinit();
        if (parsed.value.result == null) return failWallet(detail, parsed.value.@"error", error.WalletOpenFailed);
    }

    /// Read the open wallet's balance. `balance` is the total (includes locked and
    /// unconfirmed); `unlocked_balance` is spendable now — exactly the Total /
    /// Available split the frontend renders. Salvium is multi-asset, so the request
    /// pins `asset_type` to the primary coin (SAL1); the reply's flat
    /// `balance`/`unlocked_balance` are for that asset (extra fields are ignored).
    fn walletBalance(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
    ) anyerror!models.WalletBalance {
        var parsed = try walletCall(WalletBalanceResult, allocator, wallet_auth, "get_balance", "{\"account_index\":0,\"asset_type\":\"" ++ primary_asset ++ "\"}");
        defer parsed.deinit();
        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return atomicToBalance(r.balance, r.unlocked_balance);
    }

    /// Map Monero atomic balances to the normalized `WalletBalance`. Pure, so it's
    /// unit-testable without a wallet process.
    fn atomicToBalance(balance: u64, unlocked: u64) models.WalletBalance {
        return .{
            .total = @as(f64, @floatFromInt(balance)) / atomic_per_sal,
            .available = @as(f64, @floatFromInt(unlocked)) / atomic_per_sal,
        };
    }

    // --- Transactions / receive / send (wallet RPC) ----------------------
    //
    // These ride the same `salvium-wallet-rpc` process as balance, so the app
    // hands them the wallet endpoint (`extWalletAuth`) and polls them only
    // once the wallet is open.

    /// Salvium is multi-asset; the primary coin's asset tag, as `get_balance`
    /// already pins and `transfer` requires for its source/dest assets.
    const primary_asset = "SAL1";

    /// `transaction_type::TRANSFER` from Salvium's `cryptonote_protocol/enums.h`
    /// — the `tx_type` a plain send must carry (0 is UNSET, which the wallet
    /// rejects).
    const tx_type_transfer = 3;

    /// One `get_transfers` entry (the subset BoxWallet uses). Salvium's modern
    /// wallet-rpc reports `confirmations` per entry; `asset_type` tags which
    /// asset the amount is in, and a coinbase (mined) credit arrives in the
    /// `in` bucket with `type == "block"`.
    const TransferEntry = struct {
        amount: u64 = 0,
        timestamp: i64 = 0,
        confirmations: i64 = 0,
        asset_type: []const u8 = "",
        @"type": []const u8 = "",
    };

    /// `get_transfers` groups entries by state; direction falls out of the
    /// bucket (`in` received, `out`/`pending` sent, `pool` incoming-unconfirmed).
    const GetTransfersResult = struct {
        in: []TransferEntry = &.{},
        out: []TransferEntry = &.{},
        pending: []TransferEntry = &.{},
        pool: []TransferEntry = &.{},
    };
    const AddressResult = struct { address: []const u8 = "" };
    const TransferResult = struct { tx_hash: []const u8 = "" };

    /// The open wallet's most recent transactions, newest-first, via the wallet
    /// RPC's `get_transfers`. The reply spans the wallet's whole history (the
    /// RPC has no count cap), but it's parsed into minimal entries and freed on
    /// return — only the `limit` newest normalized rows survive.
    fn walletTransactions(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        limit: usize,
    ) anyerror![]models.WalletTx {
        var parsed = try walletCall(GetTransfersResult, allocator, wallet_auth, "get_transfers", "{\"in\":true,\"out\":true,\"pending\":true,\"pool\":true,\"account_index\":0}");
        defer parsed.deinit();
        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return mapTransfers(allocator, r, limit);
    }

    /// Whether an entry's amount is denominated in the primary coin. Entries
    /// for other assets are dropped rather than shown with a SAL-scaled amount;
    /// an empty tag (a vintage that doesn't report one) passes.
    fn isPrimaryAsset(asset_type: []const u8) bool {
        return asset_type.len == 0 or std.mem.eql(u8, asset_type, primary_asset);
    }

    /// Flatten the four `get_transfers` buckets into normalized `WalletTx`es,
    /// newest-first, capped at `limit`. Split out from `walletTransactions` so
    /// the mapping/ordering is unit-testable without a wallet process.
    fn mapTransfers(allocator: std.mem.Allocator, r: GetTransfersResult, limit: usize) ![]models.WalletTx {
        const total = r.in.len + r.out.len + r.pending.len + r.pool.len;
        const all = try allocator.alloc(models.WalletTx, total);
        defer allocator.free(all);
        var n: usize = 0;
        for (r.in) |e| {
            if (!isPrimaryAsset(e.asset_type)) continue;
            // A coinbase credit (type "block") was minted by the wallet itself.
            const direction: models.TxDirection = if (std.mem.eql(u8, e.@"type", "block")) .stake else .received;
            all[n] = mapEntry(e, direction);
            n += 1;
        }
        for (r.out) |e| {
            if (!isPrimaryAsset(e.asset_type)) continue;
            all[n] = mapEntry(e, .sent);
            n += 1;
        }
        for (r.pending) |e| {
            if (!isPrimaryAsset(e.asset_type)) continue;
            all[n] = mapEntry(e, .sent);
            n += 1;
        }
        for (r.pool) |e| {
            if (!isPrimaryAsset(e.asset_type)) continue;
            all[n] = mapEntry(e, .received);
            n += 1;
        }
        std.mem.sort(models.WalletTx, all[0..n], {}, newerFirst);

        const out = try allocator.alloc(models.WalletTx, @min(n, limit));
        @memcpy(out, all[0..out.len]);
        return out;
    }

    /// One entry → the normalized row (atomic units → whole SAL).
    fn mapEntry(e: TransferEntry, direction: models.TxDirection) models.WalletTx {
        return .{
            .direction = direction,
            .amount = @as(f64, @floatFromInt(e.amount)) / atomic_per_sal,
            .time = e.timestamp,
            .confirmations = e.confirmations,
        };
    }

    /// Sort helper: newest (largest timestamp) first.
    fn newerFirst(_: void, lhs: models.WalletTx, rhs: models.WalletTx) bool {
        return lhs.time > rhs.time;
    }

    /// The open wallet's receive address (`get_address`, account 0). CryptoNote
    /// stealth addressing keeps a reused address private, so the main address
    /// is the stable "current" one; an explicit user-requested rotation mints a
    /// fresh subaddress (`create_address`).
    fn walletReceiveAddress(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        force_new: bool,
    ) anyerror![]const u8 {
        const method: []const u8 = if (force_new) "create_address" else "get_address";
        var parsed = try walletCall(AddressResult, allocator, wallet_auth, method, "{\"account_index\":0}");
        defer parsed.deinit();
        const r = parsed.value.result orelse return error.EmptyRpcResult;
        if (r.address.len == 0) return error.EmptyRpcResult;
        return allocator.dupe(u8, r.address); // parsed.deinit() frees its arena below us
    }

    /// Send `amount` SAL to `address` via the wallet RPC `transfer`. Salvium's
    /// `transfer` extends Monero's with the asset pair and a transaction type —
    /// a plain send is `SAL1 → SAL1` with `tx_type` TRANSFER. The wallet does
    /// its own address validation and balance check — `SendResult` carries
    /// whichever of those (or the success tx hash) came back, verbatim. The
    /// amount is converted to integer atomic units before splicing.
    fn walletSend(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        address: []const u8,
        amount: f64,
    ) anyerror!models.SendResult {
        const atomic = atomicFromAmount(amount) orelse return .{ .failed = "invalid amount" };
        const addr_q = try rpc.jsonQuote(allocator, address);
        defer allocator.free(addr_q);
        const params = try std.fmt.allocPrint(
            allocator,
            "{{\"destinations\":[{{\"amount\":{d},\"address\":{s}}}],\"source_asset\":\"{s}\",\"dest_asset\":\"{s}\",\"tx_type\":{d},\"get_tx_key\":true}}",
            .{ atomic, addr_q, primary_asset, primary_asset, tx_type_transfer },
        );
        defer allocator.free(params);

        var parsed = try walletCall(TransferResult, allocator, wallet_auth, "transfer", params);
        defer parsed.deinit();
        if (parsed.value.result) |r| {
            if (r.tx_hash.len > 0) return .{ .ok = try allocator.dupe(u8, r.tx_hash) };
        }
        if (parsed.value.@"error") |e| return .{ .failed = try allocator.dupe(u8, e.message) };
        return .{ .failed = "no response from wallet" };
    }

    /// Convert a user-entered SAL amount to integer atomic units (rounded to
    /// the nearest atomic). Null for anything unusable — non-finite,
    /// non-positive, or too large for u64 — so a bad amount is rejected before
    /// any RPC.
    fn atomicFromAmount(amount: f64) ?u64 {
        if (!std.math.isFinite(amount) or amount <= 0) return null;
        const scaled = @round(amount * atomic_per_sal);
        if (scaled >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return null;
        return @intFromFloat(scaled);
    }

    /// Produce the canonical form of a user-entered seed for the wallet RPC:
    /// every word lowercased and joined by single spaces, with leading/trailing and
    /// repeated whitespace collapsed. Monero's English wordlist is all lowercase and
    /// the deterministic decode is case-sensitive, so a transcriber who capitalizes
    /// a word — or pastes with newlines/double spaces — would otherwise hit a
    /// spurious "word list failed verification". Caller owns the returned slice.
    fn normalizeSeed(allocator: std.mem.Allocator, seed: []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        var it = std.mem.tokenizeAny(u8, seed, " \t\r\n");
        var first = true;
        while (it.next()) |word| {
            if (!first) try out.writer.writeByte(' ');
            first = false;
            for (word) |c| try out.writer.writeByte(std.ascii.toLower(c));
        }
        return out.toOwnedSlice();
    }

    /// Count whitespace-separated tokens in `s`. Pure helper behind `isValidSeed`.
    fn wordCount(s: []const u8) usize {
        var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        return n;
    }

    /// Cheap pre-flight check that `seed` has the right word count (25) before it's
    /// sent to the wallet RPC. Not a full mnemonic-checksum validation — the wallet
    /// process does that — just a fast guard against an obviously wrong paste.
    fn isValidSeed(seed: []const u8) bool {
        return wordCount(std.mem.trim(u8, seed, " \t\r\n")) == seed_word_count;
    }

    /// Remove the managed wallet so a different one can be created/restored in its
    /// place — the destructive in-app "Replace wallet". Drops the whole
    /// `<datadir>/wallets` dir (the `BoxWallet` cache, its `.keys` secret, and the
    /// `.address.txt`), so `walletExists` reports false next. The caller (`app.zig`)
    /// kills `salvium-wallet-rpc` first — releasing the file locks — and leaves the
    /// daemon (and its sync) running; the next create/restore re-creates the dir.
    /// Idempotent — a missing dir is fine; `deleteTree` holds nothing in memory
    /// beyond a path.
    fn walletRemove(allocator: std.mem.Allocator, home: []const u8) anyerror!void {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const dir = try walletDir(allocator, home);
        defer allocator.free(dir);
        try std.Io.Dir.cwd().deleteTree(threaded.io(), dir);
    }

    /// The external-wallet capability wired into the vtable. Funds-sensitive ops
    /// route through here; bitcoin coins leave `external_wallet` null instead.
    pub const external_wallet: Coin.ExternalWallet = .{
        .rpc_port = walletRpcPort,
        .process_argv = walletProcessArgv,
        .exists = walletExists,
        .create = walletCreate,
        .restore_seed = walletRestoreSeed,
        .restore_file = walletRestoreFile,
        .open = walletOpen,
        .remove = walletRemove,
        .balance = walletBalance,
    };

    // --- vtable plumbing -------------------------------------------------

    const vtable: Coin.VTable = .{
        .coin_name = vtCoinName,
        .coin_name_abbrev = vtCoinNameAbbrev,
        .coin_description = vtCoinDescription,
        .coin_color = vtCoinColor,
        .tip_address = vtTipAddress,
        .core_version = vtCoreVersion,
        .proof_of_stake = vtProofOfStake,
        .conf_file = vtConfFile,
        .daemon_file = vtDaemonFile,
        .rpc_default_port = vtRpcDefaultPort,
        .rpc_default_username = vtRpcDefaultUsername,
        .blockchain_state = vtBlockchainState,
        .daemon_info = vtDaemonInfo,
        .data_dir = vtDataDir,
        .wallet_path = vtWalletPath,
        .is_installed = vtIsInstalled,
        .install = vtInstall,
        .prepare_conf = vtPrepareConf,
        .launch_mode = vtLaunchMode,
        .daemon_argv = vtDaemonArgv,
        .request_stop = vtRequestStop,
        .wallet_transactions = vtWalletTransactions,
        .wallet_receive_address = vtWalletReceiveAddress,
        .wallet_send = vtWalletSend,
        .external_wallet = &external_wallet,
    };

    // The three hooks below ride the wallet process's endpoint: for an
    // external-wallet coin, `app.zig` passes `extWalletAuth()` (never the
    // daemon's auth) and calls them only once the wallet is open.
    fn vtWalletTransactions(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        limit: usize,
    ) anyerror![]models.WalletTx {
        return walletTransactions(allocator, wallet_auth, limit);
    }
    fn vtWalletReceiveAddress(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        force_new: bool,
    ) anyerror![]const u8 {
        return walletReceiveAddress(allocator, wallet_auth, force_new);
    }
    fn vtWalletSend(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        address: []const u8,
        amount: f64,
    ) anyerror!models.SendResult {
        return walletSend(allocator, wallet_auth, address, amount);
    }

    fn vtCoinName(_: *anyopaque) []const u8 {
        return coin_name;
    }
    fn vtCoinDescription(_: *anyopaque) []const u8 {
        return coin_description;
    }
    fn vtCoinNameAbbrev(_: *anyopaque) []const u8 {
        return coin_name_abbrev;
    }
    fn vtCoinColor(_: *anyopaque) []const u8 {
        return coin_color;
    }
    fn vtTipAddress(_: *anyopaque) []const u8 {
        return tip_address;
    }
    fn vtCoreVersion(_: *anyopaque) []const u8 {
        return core_version;
    }
    fn vtProofOfStake(_: *anyopaque) bool {
        return proof_of_stake;
    }
    fn vtConfFile(_: *anyopaque) []const u8 {
        return conf_file;
    }
    fn vtDaemonFile(_: *anyopaque) []const u8 {
        return daemon_file;
    }
    fn vtRpcDefaultPort(_: *anyopaque) []const u8 {
        return rpc_default_port;
    }
    fn vtRpcDefaultUsername(_: *anyopaque) []const u8 {
        return rpc_default_username;
    }
    fn vtBlockchainState(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) anyerror!models.BlockchainState {
        return blockchainState(allocator, auth);
    }
    fn vtDaemonInfo(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) anyerror!models.DaemonInfo {
        return daemonInfo(allocator, auth);
    }
    fn vtDataDir(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        home: []const u8,
    ) anyerror![]const u8 {
        return dataDir(allocator, home);
    }
    fn vtWalletPath(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        home: []const u8,
    ) anyerror!?Coin.WalletFile {
        return walletPath(allocator, home);
    }
    fn vtIsInstalled(_: *anyopaque, allocator: std.mem.Allocator, install_root: []const u8) bool {
        return isInstalled(allocator, install_root);
    }
    fn vtInstall(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        install_root: []const u8,
        progress: ?install_mod.Progress,
    ) anyerror!void {
        return install(allocator, install_root, progress);
    }
    fn vtPrepareConf(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        install_root: []const u8,
        home: []const u8,
    ) anyerror!void {
        _ = install_root;
        return prepareConf(allocator, io, home);
    }
    fn vtLaunchMode(_: *anyopaque) Coin.LaunchMode {
        return launchMode();
    }
    fn vtDaemonArgv(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home: []const u8,
    ) anyerror![]const []const u8 {
        return daemonArgv(allocator, install_root, home);
    }
    fn vtRequestStop(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) anyerror!void {
        return requestStop(allocator, auth);
    }
};

test "parses get_info into a synced BlockchainState" {
    const allocator = std.testing.allocator;

    // Canned Monero `get_info` reply (subset) — fully synced: target_height 0 and
    // `synchronized` true. Proves the flat parse + height-derived sync without a
    // running salviumd.
    const raw =
        \\{"id":"0","jsonrpc":"2.0","result":{"status":"OK","height":1500000,
        \\"target_height":0,"synchronized":true,"outgoing_connections_count":8,
        \\"incoming_connections_count":4,"mainnet":true,"testnet":false}}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(Salvium.SalviumInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    const tip = @max(r.target_height, r.height);
    const state: models.BlockchainState = .{
        .chain = try allocator.dupe(u8, "mainnet"),
        .blocks = r.height,
        .headers = tip,
        .verification_progress = 0,
        .synced = r.synchronized or (r.height > 0 and (r.target_height == 0 or r.height >= r.target_height)),
        .network_height = tip,
    };
    defer state.deinit(allocator);

    try std.testing.expectEqualStrings("mainnet", state.chain);
    try std.testing.expectEqual(@as(i64, 1500000), state.blocks);
    try std.testing.expect(state.synced);
}

test "estimateSecondsBehind turns the block gap into a behind-by estimate" {
    // 100 blocks behind at 120s/block → ~12000s behind.
    try std.testing.expectEqual(@as(i64, 12000), Salvium.estimateSecondsBehind(1000, 900, false));

    // Synced → 0, so the frontend shows no "behind by" hint.
    try std.testing.expectEqual(@as(i64, 0), Salvium.estimateSecondsBehind(1000, 1000, true));

    // Caught up by height (target reached) even if the flag lags → still 0.
    try std.testing.expectEqual(@as(i64, 0), Salvium.estimateSecondsBehind(1000, 1000, false));
}

test "a daemon still catching up reads as not synced" {
    // Mid-sync: height behind target_height and not yet synchronized.
    const r: Salvium.SalviumInfo = .{ .height = 900_000, .target_height = 1_500_000, .synchronized = false };
    const synced = r.synchronized or (r.height > 0 and (r.target_height == 0 or r.height >= r.target_height));
    try std.testing.expect(!synced);
    try std.testing.expectEqual(@as(i64, 1_500_000), @max(r.target_height, r.height));
}

test "maps get_info into DaemonInfo (connections summed, PoW so no staking)" {
    const allocator = std.testing.allocator;

    const raw =
        \\{"id":"0","jsonrpc":"2.0","result":{"status":"OK","height":1500000,
        \\"target_height":0,"synchronized":true,"outgoing_connections_count":8,
        \\"incoming_connections_count":4,"mainnet":true}}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(Salvium.SalviumInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    const info: models.DaemonInfo = .{
        .blocks = r.height,
        .connections = r.outgoing_connections_count + r.incoming_connections_count,
        .staking_active = false,
    };

    try std.testing.expectEqual(@as(i64, 1500000), info.blocks);
    try std.testing.expectEqual(@as(i64, 12), info.connections);
    try std.testing.expect(!info.staking_active);
}

test "platform selection resolves a zip bundle for the build target" {
    // Where Salvium ships a bundle for the target, the URL carries the version tag
    // and the coin name, and every bundle is a `.zip`.
    if (Salvium.download) |dl| {
        try std.testing.expect(std.mem.indexOf(u8, dl.url, "/v" ++ Salvium.core_version ++ "/") != null);
        try std.testing.expect(std.mem.indexOf(u8, dl.url, "salvium-v" ++ Salvium.core_version) != null);
        try std.testing.expectEqual(install_mod.Format.zip, dl.format);
        try std.testing.expect(std.mem.endsWith(u8, dl.url, ".zip"));
    }

    // Binary names carry `.exe` only on Windows.
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("salviumd.exe", Salvium.daemon_file);
    } else {
        try std.testing.expectEqualStrings("salviumd", Salvium.daemon_file);
    }
}

test "daemonArgv runs the daemon non-interactive (no quicksync flag)" {
    const allocator = std.testing.allocator;

    const argv = try Salvium.daemonArgv(allocator, "/opt/bw", "");
    defer {
        for (argv) |a| allocator.free(a);
        allocator.free(argv);
    }
    try std.testing.expectEqual(@as(usize, 2), argv.len);
    try std.testing.expect(std.mem.endsWith(u8, argv[0], Salvium.daemon_file));
    try std.testing.expect(std.mem.startsWith(u8, argv[0], "/opt/bw"));
    try std.testing.expectEqualStrings("--non-interactive", argv[1]);
}

test "coin vtable dispatches to Salvium metadata" {
    var n: Salvium = .{};
    const c = n.coin();
    try std.testing.expectEqualStrings("Salvium", c.coinName());
    try std.testing.expectEqualStrings("SAL", c.coinNameAbbrev());
    try std.testing.expectEqualStrings("#0AEB85", c.coinColor());
    try std.testing.expect(!c.isProofOfStake());
    try std.testing.expectEqualStrings("salvium.conf", c.confFile());
    try std.testing.expectEqualStrings("19081", c.rpcDefaultPort());
    try std.testing.expectEqual(Coin.LaunchMode.foreground, c.launchMode());
}

test "walletPath reports the Monero wallet file plus its .keys companion" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var n: Salvium = .{};
    const wf = (try n.coin().walletPath(allocator, "/home/alice")).?;
    defer allocator.free(wf.path);
    defer allocator.free(wf.keys.?);
    try std.testing.expectEqualStrings("/home/alice/.salvium/wallets/BoxWallet", wf.path);
    try std.testing.expectEqualStrings("/home/alice/.salvium/wallets/BoxWallet.keys", wf.keys.?);
}

test "prepareConf writes a Monero-valid conf salviumd can parse (no bitcoin keys)" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A throwaway home; prepareConf resolves `<home>/.salvium/salvium.conf` from it,
    // so this stays entirely offline (no real datadir touched).
    const home = "test-salvium-home";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // Pre-seed a poisoned, bitcoin-style conf (what older builds wrote and what
    // crashed salviumd) to prove prepare is self-healing — it must be replaced, not
    // appended to.
    {
        const poisoned = try std.fs.path.join(allocator, &.{ home, Salvium.home_dir });
        defer allocator.free(poisoned);
        var pd = try std.Io.Dir.cwd().createDirPathOpen(io, poisoned, .{});
        defer pd.close(io);
        try pd.writeFile(io, .{ .sub_path = Salvium.conf_file, .data = "rpcuser=salviumrpc\nserver=1\ndaemon=1\nrpcport=19081\n" });
    }

    try Salvium.prepareConf(allocator, io, home);

    // Read the conf back. salviumd parses this on startup, so it must carry only
    // Monero-style options — the bitcoin keys (`rpcuser`/`server`/`daemon`/
    // `rpcport`) it rejects must be absent, and the RPC port present in Monero form.
    const path = try std.fs.path.join(allocator, &.{ home, Salvium.home_dir });
    defer allocator.free(path);
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    var f = try dir.openFile(io, Salvium.conf_file, .{});
    defer f.close(io);
    var rb: [4096]u8 = undefined;
    const n = try f.readPositionalAll(io, &rb, 0);
    const content = rb[0..n];

    try std.testing.expect(std.mem.indexOf(u8, content, "rpc-bind-port=" ++ Salvium.rpc_default_port) != null);
    for ([_][]const u8{ "rpcuser", "rpcpassword", "server", "daemon=", "rpcport" }) |bad| {
        try std.testing.expect(std.mem.indexOf(u8, content, bad) == null);
    }
}

// --- External wallet (Monero wallet-rpc) tests ---------------------------

test "get_balance atomic units map to SAL Total/Available (8 decimals)" {
    const allocator = std.testing.allocator;

    // 1.5 SAL total, 1.0 SAL unlocked, in 1e8 atomic units.
    const raw =
        \\{"id":"0","jsonrpc":"2.0","result":{"balance":150000000,"unlocked_balance":100000000}}
    ;
    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(Salvium.WalletBalanceResult),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    const bal = Salvium.atomicToBalance(r.balance, r.unlocked_balance);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), bal.total, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), bal.available, 1e-9);
    // Total ahead of available → funds still settling.
    try std.testing.expect(bal.hasPending());
}

test "isValidSeed accepts a 25-word phrase and rejects other counts" {
    // 25 space-separated tokens (content irrelevant — only the count is checked).
    const ok = "a a a a a a a a a a a a a a a a a a a a a a a a a";
    try std.testing.expect(Salvium.isValidSeed(ok));
    // Leading/trailing whitespace is trimmed, internal runs tolerated.
    try std.testing.expect(Salvium.isValidSeed("  " ++ ok ++ "\n"));
    // Too few / too many words fail fast.
    try std.testing.expect(!Salvium.isValidSeed("a a a"));
    try std.testing.expect(!Salvium.isValidSeed(ok ++ " extra"));
    try std.testing.expect(!Salvium.isValidSeed(""));
}

test "normalizeSeed lowercases words and collapses whitespace to single spaces" {
    const allocator = std.testing.allocator;

    // Capitalized first word + newlines + double spaces all clean up to the
    // canonical single-spaced lowercase phrase Monero's decode expects.
    const got = try Salvium.normalizeSeed(allocator, "  Abbey   bacon\nCactus  ");
    defer allocator.free(got);
    try std.testing.expectEqualStrings("abbey bacon cactus", got);

    // An already-clean phrase is returned unchanged.
    const clean = try Salvium.normalizeSeed(allocator, "abbey bacon cactus");
    defer allocator.free(clean);
    try std.testing.expectEqualStrings("abbey bacon cactus", clean);
}

test "walletRpcError maps known Monero messages to specific errors" {
    const E = Salvium.RpcErrObj;
    try std.testing.expect(Salvium.walletRpcError(E{ .code = -8, .message = "Wallet already exists." }, error.WalletRestoreFailed) == error.WalletAlreadyExists);
    try std.testing.expect(Salvium.walletRpcError(E{ .message = "Electrum-style word list failed verification" }, error.WalletRestoreFailed) == error.SeedWordsInvalid);
    try std.testing.expect(Salvium.walletRpcError(E{ .message = "invalid password" }, error.WalletOpenFailed) == error.WrongPassword);
    // Unfamiliar message / no error object → the caller's fallback.
    try std.testing.expect(Salvium.walletRpcError(E{ .message = "something new" }, error.WalletRestoreFailed) == error.WalletRestoreFailed);
    try std.testing.expect(Salvium.walletRpcError(null, error.WalletRestoreFailed) == error.WalletRestoreFailed);
}

test "walletProcessArgv binds wallet-rpc to localhost and points it at the daemon" {
    const allocator = std.testing.allocator;

    const argv = try Salvium.walletProcessArgv(allocator, "/opt/bw", "/home/alice", Salvium.wallet_rpc_port, "rpcuser123", "rpcpass456");
    defer {
        for (argv) |a| allocator.free(a);
        allocator.free(argv);
    }

    // First arg is the promoted wallet-rpc binary under the install root.
    try std.testing.expect(std.mem.endsWith(u8, argv[0], Salvium.wallet_rpc_file));
    try std.testing.expect(std.mem.startsWith(u8, argv[0], "/opt/bw"));

    // Joined for easy substring assertions on the flags.
    const joined = try std.mem.join(allocator, " ", argv);
    defer allocator.free(joined);
    try std.testing.expect(std.mem.indexOf(u8, joined, "--wallet-dir") != null);
    // The wallet dir is `<datadir>/wallets`.
    try std.testing.expect(std.mem.indexOf(u8, joined, "wallets") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "--rpc-bind-ip 127.0.0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "--rpc-bind-port " ++ Salvium.wallet_rpc_port) != null);
    // Pointed at the local daemon's RPC port.
    try std.testing.expect(std.mem.indexOf(u8, joined, "--daemon-address 127.0.0.1:" ++ Salvium.rpc_default_port) != null);
    // The wallet RPC is locked to the per-session credentials, not keyless.
    try std.testing.expect(std.mem.indexOf(u8, joined, "--rpc-login rpcuser123:rpcpass456") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "--disable-rpc-login") == null);
}

test "walletExists keys off the BoxWallet.keys file on disk" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A throwaway home; walletExists resolves `<home>/.salvium/wallets/BoxWallet.keys`.
    const home = "test-salvium-wallet-home";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // No wallet yet → false.
    try std.testing.expect(!Salvium.walletExists(allocator, home));

    // Lay down the keys file and it flips to true.
    const wallet_dir = try std.fs.path.join(allocator, &.{ home, Salvium.home_dir, "wallets" });
    defer allocator.free(wallet_dir);
    var wd = try std.Io.Dir.cwd().createDirPathOpen(io, wallet_dir, .{});
    defer wd.close(io);
    try wd.writeFile(io, .{ .sub_path = "BoxWallet.keys", .data = "KEYS" });

    try std.testing.expect(Salvium.walletExists(allocator, home));
}

test "walletRemove drops the wallet dir so a replacement can be set up" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-salvium-remove-home";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // Idempotent on a missing wallet — replace before any wallet exists is fine.
    try Salvium.walletRemove(allocator, home);

    // Lay down a full Monero wallet triple, then remove it; walletExists flips back.
    const wallet_dir = try std.fs.path.join(allocator, &.{ home, Salvium.home_dir, "wallets" });
    defer allocator.free(wallet_dir);
    var wd = try std.Io.Dir.cwd().createDirPathOpen(io, wallet_dir, .{});
    defer wd.close(io);
    try wd.writeFile(io, .{ .sub_path = "BoxWallet", .data = "CACHE" });
    try wd.writeFile(io, .{ .sub_path = "BoxWallet.keys", .data = "KEYS" });
    try wd.writeFile(io, .{ .sub_path = "BoxWallet.address.txt", .data = "ADDR" });
    try std.testing.expect(Salvium.walletExists(allocator, home));

    try Salvium.walletRemove(allocator, home);
    try std.testing.expect(!Salvium.walletExists(allocator, home));
}

test "Salvium wires the external-wallet capability" {
    var n: Salvium = .{};
    const c = n.coin();
    try std.testing.expect(c.hasExternalWallet());
    const ew = c.externalWallet().?;
    try std.testing.expect(c.hasExternalWalletProcess());
    try std.testing.expect(c.supportsWalletReplace());
    try std.testing.expectEqualStrings(Salvium.wallet_rpc_port, ew.rpc_port.?());
}

test "parses a get_transfers reply into bucketed TransferEntry lists (asset-tagged)" {
    const allocator = std.testing.allocator;

    // Canned wallet-rpc reply (subset): a mined credit, a SAL1 receive, and an
    // entry in a different asset (dropped by the mapper). Extra fields
    // (txid/fee/height/...) fall away via ignore_unknown_fields.
    const raw =
        \\{"id":"0","jsonrpc":"2.0","result":{"in":[
        \\{"txid":"aa","type":"block","asset_type":"SAL1","amount":500000000,"timestamp":100,"confirmations":900},
        \\{"txid":"bb","type":"in","asset_type":"SAL1","amount":250000000,"timestamp":200,"confirmations":10},
        \\{"txid":"cc","type":"in","asset_type":"VSD","amount":42,"timestamp":250,"confirmations":5}
        \\],"out":[{"txid":"dd","type":"out","asset_type":"SAL1","amount":125000000,"timestamp":300,"confirmations":1}]}}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(Salvium.GetTransfersResult),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    try std.testing.expectEqual(@as(usize, 3), r.in.len);
    try std.testing.expectEqual(@as(usize, 1), r.out.len);
    try std.testing.expectEqualStrings("block", r.in[0].@"type");
    try std.testing.expectEqual(@as(i64, 10), r.in[1].confirmations);

    const txs = try Salvium.mapTransfers(allocator, r, 32);
    defer allocator.free(txs);

    // The VSD entry is dropped (its amount isn't SAL-denominated); the rest come
    // back newest-first with 8-decimal atomic amounts scaled to whole SAL.
    try std.testing.expectEqual(@as(usize, 3), txs.len);
    try std.testing.expectEqual(models.TxDirection.sent, txs[0].direction);
    try std.testing.expectEqual(@as(i64, 1), txs[0].confirmations);
    try std.testing.expectEqual(models.TxDirection.received, txs[1].direction);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), txs[1].amount, 1e-9);
    try std.testing.expectEqual(models.TxDirection.stake, txs[2].direction);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), txs[2].amount, 1e-9);
}

test "mapTransfers caps at limit, newest-first" {
    const allocator = std.testing.allocator;
    var in = [_]Salvium.TransferEntry{
        .{ .@"type" = "in", .amount = 1, .timestamp = 100, .confirmations = 3 },
        .{ .@"type" = "in", .amount = 2, .timestamp = 300, .confirmations = 1 },
    };
    var out = [_]Salvium.TransferEntry{
        .{ .@"type" = "out", .amount = 3, .timestamp = 200, .confirmations = 2 },
    };
    const r: Salvium.GetTransfersResult = .{ .in = &in, .out = &out };

    const txs = try Salvium.mapTransfers(allocator, r, 2);
    defer allocator.free(txs);
    try std.testing.expectEqual(@as(usize, 2), txs.len);
    try std.testing.expectEqual(@as(i64, 300), txs[0].time);
    try std.testing.expectEqual(@as(i64, 200), txs[1].time);
}

test "atomicFromAmount converts SAL to 8-decimal atomic units and rejects bad amounts" {
    try std.testing.expectEqual(@as(?u64, 150_000_000), Salvium.atomicFromAmount(1.5));
    try std.testing.expectEqual(@as(?u64, 1), Salvium.atomicFromAmount(0.00000001));
    try std.testing.expect(Salvium.atomicFromAmount(0) == null);
    try std.testing.expect(Salvium.atomicFromAmount(-1.0) == null);
    try std.testing.expect(Salvium.atomicFromAmount(std.math.inf(f64)) == null);
    try std.testing.expect(Salvium.atomicFromAmount(1e30) == null);
}

test "coin vtable exposes transactions, receive address, and send for Salvium" {
    var s: Salvium = .{};
    const c = s.coin();
    try std.testing.expect(c.supportsTransactions());
    try std.testing.expect(c.supportsReceiveAddress());
    try std.testing.expect(c.supportsSend());
}
