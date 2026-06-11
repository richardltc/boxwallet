const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const install_mod = @import("../install.zig");
const conf = @import("../conf.zig");
const rpc = @import("../rpc.zig");
const Coin = @import("../coin.zig").Coin;

/// Nerva (XNV) backend. Nerva isn't in the Go app, so this is a fresh backend
/// rather than a port; the shapes below come from Nerva itself (a Monero/
/// CryptoNote fork), not a reference implementation.
///
/// Two things set Nerva apart from the bitcoin-core coins:
///
///   * **Distribution** — Linux/macOS bundles ship as `.tar.bz2`. Zig's stdlib has
///     no bzip2, so the install path uses BoxWallet's own pure-Zig bzip2 decoder
///     (`install`/`bzip2.zig`). Windows ships a `.zip` (streamed normally). Every
///     bundle wraps its binaries in a versioned `nerva-<os>-<arch>-v<ver>/` dir
///     (no `bin/` subdir); the daemon/cli are promoted out and the rest dropped.
///   * **RPC** — Monero's daemon RPC, not the bitcoin JSON-RPC. `get_info` is a
///     `POST /json_rpc` method returning a flat result; sync is derived from
///     `height` vs `target_height` (0 once caught up) and the `synchronized` flag,
///     and the peer count from the connection counts. Shutdown is the direct
///     `POST /stop_daemon` endpoint. The daemon is unauthenticated by default, so
///     no basic auth is sent (mirrors Ergo's keyless REST).
pub const Nerva = struct {
    pub const coin_name = "Nerva";
    pub const coin_name_abbrev = "XNV";
    /// Nerva brand colour (`#RRGGBB`), for tinting the coin in the frontend.
    pub const coin_color = "#344769";
    /// Nerva is proof-of-work (CPU-mined, Monero-derived) — no wallet staking.
    pub const proof_of_stake = false;
    pub const conf_file = "nerva.conf";

    // Data dir names. Monero forks use `~/.<name>` on Linux *and* macOS (not the
    // macOS Library convention) and `%APPDATA%\<name>` on Windows — exactly what
    // the shared `conf.dataDir(posix, win)` produces.
    pub const home_dir = ".nerva";
    pub const home_dir_win = "nerva";

    /// Unauthenticated by default; a value is kept only so the shared conf/readAuth
    /// path has a username to write (the daemon ignores it).
    pub const rpc_default_username = "nervarpc";
    pub const rpc_default_port = "17566";
    pub const core_version = "0.2.2.0";

    // Binary names. Windows appends `.exe`. The wallet CLI is `nerva-wallet-cli`;
    // there's no `*-tx` helper. `nerva-wallet-rpc` drives the (external) wallet —
    // BoxWallet launches it alongside the daemon for create/restore/balance (see
    // the external-wallet section below), so it's promoted too.
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    pub const daemon_file = "nervad" ++ exe_suffix;
    pub const cli_file = "nerva-wallet-cli" ++ exe_suffix;
    pub const wallet_rpc_file = "nerva-wallet-rpc" ++ exe_suffix;

    /// Port BoxWallet binds the managed `nerva-wallet-rpc` to (localhost only).
    /// Must avoid the daemon's reserved ports: P2P 17565, RPC 17566, and — easy to
    /// miss — the **ZMQ-RPC** server at `rpc-bind-port + 1` = 17567 (Monero/Nerva
    /// bind it by default). Colliding there makes *nervad* fail to start ("ZMQ RPC
    /// Server bind failed: Address already in use") and die, so the wallet port is
    /// moved well clear.
    pub const wallet_rpc_port = "18566";

    /// The single managed wallet's filename, inside the wallet dir. Fixed so
    /// `walletExists` is a pure disk check and every wallet-RPC call targets the
    /// same file by name.
    const wallet_name = "BoxWallet";

    /// Nerva inherits Monero's 12-decimal atomic unit
    /// (`CRYPTONOTE_DISPLAY_DECIMAL_POINT = 12`, verified against
    /// nerva-project/nerva `cryptonote_config.h`): the wallet RPC reports balances
    /// as integer atomic units, so divide by this to get whole XNV.
    const atomic_per_xnv: f64 = 1_000_000_000_000;

    /// A Nerva (Monero) deterministic restore seed is exactly 25 words.
    pub const seed_word_count = 25;

    const release_base = "https://github.com/nerva-project/nerva/releases/download/v" ++ core_version ++ "/";

    // The per-target bundle "stem" (also the versioned wrapper dir inside the
    // archive) and its format. Mirrors Nerva's release asset names. macOS and
    // Linux ship `.tar.bz2`; Windows ships `.zip`. Arch tags follow Nerva's own
    // naming (`armv8`/`armv7`/`x86_64`/`x64`).
    const Bundle = struct { stem: []const u8, format: install_mod.Format };
    const bundle: ?Bundle = switch (builtin.os.tag) {
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => .{ .stem = "nerva-linux-x86_64-v" ++ core_version, .format = .tar_bz2 },
            .aarch64 => .{ .stem = "nerva-linux-armv8-v" ++ core_version, .format = .tar_bz2 },
            .arm => .{ .stem = "nerva-linux-armv7-v" ++ core_version, .format = .tar_bz2 },
            else => null,
        },
        .macos => switch (builtin.cpu.arch) {
            .x86_64 => .{ .stem = "nerva-macos-x64-v" ++ core_version, .format = .tar_bz2 },
            .aarch64 => .{ .stem = "nerva-macos-armv8-v" ++ core_version, .format = .tar_bz2 },
            else => null,
        },
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => .{ .stem = "nerva-windows-x64-v" ++ core_version, .format = .zip },
            else => null,
        },
        else => null,
    };

    /// The download URL + format for the build target, or null where Nerva
    /// publishes no matching binary (e.g. Linux i686, FreeBSD, Windows x86).
    const download: ?install_mod.Download = if (bundle) |b| .{
        .url = release_base ++ b.stem ++ (if (b.format == .zip) ".zip" else ".tar.bz2"),
        .format = b.format,
    } else null;

    // The versioned wrapper dir the bundle extracts to (the stem). Binaries sit
    // directly inside it, so `bin_subdir` is empty. "" when this target has no
    // bundle (download is null and install bails before using it).
    const extracted_dir = if (bundle) |b| b.stem else "";
    const bin_subdir = "";
    const promote_files = [_][]const u8{ daemon_file, cli_file, wallet_rpc_file };

    // Scratch file the bundle streams to (unique to Nerva). For `.tar.bz2` the
    // installer derives a sibling `.tar` from this name during decompression.
    pub const scratch_file = ".boxwallet-nerva.part";

    /// Build the type-erased `Coin` handle for this instance.
    pub fn coin(self: *Nerva) Coin {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // --- RPC (Monero daemon) ---------------------------------------------

    /// Subset of `get_info`'s result. Monero reports a flat object; `synchronized`
    /// is authoritative for sync state, with `height`/`target_height` as the
    /// fallback (`target_height` is 0 once caught up). Defaults keep the parse
    /// resilient to omitted fields.
    const NervaInfo = struct {
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

    /// POST `payload` to `path` on the local daemon and return the response body.
    /// Caller owns the slice. No basic auth — Nerva's daemon RPC is open by
    /// default (like Ergo's keyless REST).
    fn httpPost(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        path: []const u8,
        payload: []const u8,
    ) ![]u8 {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();

        var client: std.http.Client = .{ .allocator = allocator, .io = threaded.io() };
        defer client.deinit();

        const url = try std.fmt.allocPrint(allocator, "http://{s}:{s}{s}", .{ auth.ip_address, auth.port, path });
        defer allocator.free(url);

        var body: std.Io.Writer.Allocating = .init(allocator);
        defer body.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .response_writer = &body.writer,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
        if (result.status == .unauthorized) return error.AuthFailed;

        return body.toOwnedSlice();
    }

    /// Fetch + parse `get_info`. Caller must `deinit` the returned `Parsed`.
    fn fetchInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !std.json.Parsed(models.JsonRpcResponse(NervaInfo)) {
        const raw = try httpPost(allocator, auth, "/json_rpc", "{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"get_info\"}");
        defer allocator.free(raw);
        return std.json.parseFromSlice(
            models.JsonRpcResponse(NervaInfo),
            allocator,
            raw,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
    }

    /// Nerva's block-target interval (seconds). A CryptoNote 60-second block —
    /// ~4.3M blocks since the 2018 launch confirm the cadence. Used only to turn
    /// the block gap into a "behind by" estimate; the daemon never reports a tip
    /// timestamp we could use directly.
    const block_target_seconds: i64 = 60;

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
    /// total connections; Nerva is proof-of-work, so `staking_active` is false.
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

    /// Ask nervad to shut down via Monero's direct `POST /stop_daemon` (not a
    /// `/json_rpc` method).
    pub fn requestStop(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        const reply = try httpPost(allocator, auth, "/stop_daemon", "{}");
        allocator.free(reply);
    }

    // --- Files / paths ---------------------------------------------------

    /// The daemon's default data directory (`~/.nerva`, `%APPDATA%\nerva` on
    /// Windows), where `nerva.conf` and the chain live.
    pub fn dataDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        return conf.dataDir(allocator, home, home_dir, home_dir_win);
    }

    /// True if `nervad` (`nervad.exe` on Windows) is already present under
    /// `install_root`.
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, daemon_file);
    }

    /// Download + unpack the Nerva daemon files into `install_root`.
    ///
    /// Streams the bundle to disk (a `.tar.bz2` via the pure-Zig bzip2 decoder, or
    /// a `.zip`), then `promoteAndTidy` lifts `nervad`/`nerva-wallet-cli` out of
    /// the versioned wrapper (binaries are directly inside it, so `bin_subdir` is
    /// empty) and removes the wrapper.
    pub fn install(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        const dl = download orelse return error.UnsupportedPlatform;
        try install_mod.downloadAndExtract(allocator, dl.url, dl.format, install_root, scratch_file, 0, progress);
        try install_mod.promoteAndTidy(allocator, install_root, extracted_dir, bin_subdir, &promote_files);
        cleanupAppleDouble(allocator, install_root);
    }

    /// Remove the `._<wrapper>` AppleDouble sibling that Nerva's macOS-built
    /// tarballs carry at the archive root (the matching ones inside the wrapper go
    /// with it when `promoteAndTidy` drops the tree). Best-effort; no-op on the
    /// Windows zip, which has no such files.
    fn cleanupAppleDouble(allocator: std.mem.Allocator, install_root: []const u8) void {
        if (builtin.os.tag == .windows) return;
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var dir = std.Io.Dir.cwd().openDir(io, install_root, .{}) catch return;
        defer dir.close(io);
        dir.deleteFile(io, "._" ++ extracted_dir) catch {};
    }

    /// The canonical `nerva.conf` body. nervad parses this on startup (its
    /// `--config-file` defaults to `<data-dir>/nerva.conf`), so it must contain
    /// only Monero-style options. `rpc-bind-port` is the default RPC port stated
    /// explicitly so it's self-documenting and survives any upstream default change.
    const conf_body = "rpc-bind-port=" ++ rpc_default_port ++ "\n";

    /// Ensure the data dir and `nerva.conf` exist so the status poll's `readAuth`
    /// (which needs the conf present) succeeds.
    ///
    /// Unlike the bitcoin coins, nervad *reads* this file on every startup. The
    /// shared `conf.populate` writes bitcoin keys (`rpcuser`, `server`, …) that
    /// Monero's parser rejects outright (`unrecognised option 'rpcuser'`), so
    /// nervad exits before its RPC ever comes up — which looked like an
    /// unstoppable daemon. So we (over)write the canonical Monero conf instead.
    /// The clobbering write is deliberate: BoxWallet owns this conf and a stale
    /// bitcoin-style one is actively harmful, so prepare is self-healing. The
    /// `rpc-bind-port` is also nervad's default; `readAuth` doesn't recognise that
    /// key and falls back to its defaults (`rpc_default_port`, unauthenticated),
    /// which already match, so the poll/stop path is unaffected.
    pub fn prepareConf(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        try conf.writeConf(io, data_dir, conf_file, conf_body);
    }

    /// Nerva's daemon runs in the foreground of its own process, so it's spawned
    /// detached (with `--non-interactive`) and the status poll confirms it came up
    /// — never the bitcoin `-daemon` fork path.
    pub fn launchMode() Coin.LaunchMode {
        return .foreground;
    }

    /// `nervad --non-interactive` (so it runs as a server rather than opening its
    /// interactive console). Caller owns the returned slice and its strings.
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
    // Nerva's wallet lives in a *separate* process (`nerva-wallet-rpc`), not the
    // daemon. BoxWallet launches it bound to localhost:`wallet_rpc_port`, keyless
    // (`--disable-rpc-login`, mirroring the daemon's open RPC), pointed at the
    // local daemon, and drives create/restore/open/balance over Monero's wallet
    // `POST /json_rpc`. All funds-sensitive: a wallet is only ever created with a
    // user-supplied password, never silently. See `coin.zig`'s `ExternalWallet`.

    /// The managed wallet directory (`<datadir>/wallets`), where `nerva-wallet-rpc`
    /// creates and opens `BoxWallet`(+`.keys`). Caller owns the slice.
    fn walletDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        return std.fs.path.join(allocator, &.{ data_dir, "wallets" });
    }

    /// Port the wallet process is bound to — its RPC endpoint, distinct from the
    /// daemon's. The lifecycle in `app.zig` builds a `wallet_auth` from this.
    fn walletRpcPort() []const u8 {
        return wallet_rpc_port;
    }

    /// argv to spawn `nerva-wallet-rpc`, bound to `port` on localhost and pointed
    /// at the local daemon. `--wallet-dir` lets it create/open wallets by name over
    /// RPC; `--disable-rpc-login` keeps it keyless (both localhost-only). Caller
    /// owns the returned slice and its strings.
    fn walletProcessArgv(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home: []const u8,
        port: []const u8,
    ) anyerror![]const []const u8 {
        const path = try std.fs.path.join(allocator, &.{ install_root, wallet_rpc_file });
        errdefer allocator.free(path);
        const dir = try walletDir(allocator, home);
        errdefer allocator.free(dir);
        const daemon_addr = try std.fmt.allocPrint(allocator, "127.0.0.1:{s}", .{rpc_default_port});
        errdefer allocator.free(daemon_addr);

        const argv = try allocator.alloc([]const u8, 10);
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
        argv[9] = try allocator.dupe(u8, "--disable-rpc-login");
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
        const raw = try httpPost(allocator, auth, "/json_rpc", body);
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

        // Nerva's bundled wallet-rpc is an older Monero that has no
        // `restore_deterministic_wallet` method ("Method not found"), so the wallet
        // is materialized on disk by a one-shot `nerva-wallet-cli
        // --generate-from-json` and then opened over RPC like any other wallet.
        try cliGenerateFromSeed(allocator, install_root, home, password, normalized, detail);
        try walletOpen(allocator, wallet_auth, password, detail);
    }

    /// Restore the managed wallet from `seed` by driving a one-shot
    /// `nerva-wallet-cli --generate-from-json`: the CLI reads the
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
            detail.set(if (why.len > 0) why else "nerva-wallet-cli did not create the wallet");
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
    /// Available split the frontend renders.
    fn walletBalance(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
    ) anyerror!models.WalletBalance {
        var parsed = try walletCall(WalletBalanceResult, allocator, wallet_auth, "get_balance", "{\"account_index\":0}");
        defer parsed.deinit();
        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return atomicToBalance(r.balance, r.unlocked_balance);
    }

    /// Map Monero atomic balances to the normalized `WalletBalance`. Pure, so it's
    /// unit-testable without a wallet process.
    fn atomicToBalance(balance: u64, unlocked: u64) models.WalletBalance {
        return .{
            .total = @as(f64, @floatFromInt(balance)) / atomic_per_xnv,
            .available = @as(f64, @floatFromInt(unlocked)) / atomic_per_xnv,
        };
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
        .balance = walletBalance,
    };

    // --- vtable plumbing -------------------------------------------------

    const vtable: Coin.VTable = .{
        .coin_name = vtCoinName,
        .coin_name_abbrev = vtCoinNameAbbrev,
        .coin_color = vtCoinColor,
        .core_version = vtCoreVersion,
        .proof_of_stake = vtProofOfStake,
        .conf_file = vtConfFile,
        .daemon_file = vtDaemonFile,
        .rpc_default_port = vtRpcDefaultPort,
        .rpc_default_username = vtRpcDefaultUsername,
        .blockchain_state = vtBlockchainState,
        .daemon_info = vtDaemonInfo,
        .data_dir = vtDataDir,
        .is_installed = vtIsInstalled,
        .install = vtInstall,
        .prepare_conf = vtPrepareConf,
        .launch_mode = vtLaunchMode,
        .daemon_argv = vtDaemonArgv,
        .request_stop = vtRequestStop,
        .external_wallet = &external_wallet,
    };

    fn vtCoinName(_: *anyopaque) []const u8 {
        return coin_name;
    }
    fn vtCoinNameAbbrev(_: *anyopaque) []const u8 {
        return coin_name_abbrev;
    }
    fn vtCoinColor(_: *anyopaque) []const u8 {
        return coin_color;
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
        home: []const u8,
    ) anyerror!void {
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
    // running nervad.
    const raw =
        \\{"id":"0","jsonrpc":"2.0","result":{"status":"OK","height":1500000,
        \\"target_height":0,"synchronized":true,"outgoing_connections_count":8,
        \\"incoming_connections_count":4,"mainnet":true,"testnet":false}}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(Nerva.NervaInfo),
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
    // 100 blocks behind at 60s/block → ~6000s behind.
    try std.testing.expectEqual(@as(i64, 6000), Nerva.estimateSecondsBehind(1000, 900, false));

    // Synced → 0, so the frontend shows no "behind by" hint.
    try std.testing.expectEqual(@as(i64, 0), Nerva.estimateSecondsBehind(1000, 1000, true));

    // Caught up by height (target reached) even if the flag lags → still 0.
    try std.testing.expectEqual(@as(i64, 0), Nerva.estimateSecondsBehind(1000, 1000, false));
}

test "a daemon still catching up reads as not synced" {
    // Mid-sync: height behind target_height and not yet synchronized.
    const r: Nerva.NervaInfo = .{ .height = 900_000, .target_height = 1_500_000, .synchronized = false };
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
        models.JsonRpcResponse(Nerva.NervaInfo),
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

test "platform selection resolves a bundle for the build target" {
    // Where Nerva ships a bundle for the target, the URL carries the version and
    // the wrapper stem, and the extension matches the format (zip on Windows,
    // tar.bz2 elsewhere).
    if (Nerva.download) |dl| {
        try std.testing.expect(std.mem.indexOf(u8, dl.url, "/v" ++ Nerva.core_version ++ "/") != null);
        try std.testing.expect(std.mem.indexOf(u8, dl.url, Nerva.extracted_dir) != null);
        switch (dl.format) {
            .zip => try std.testing.expect(std.mem.endsWith(u8, dl.url, ".zip")),
            .tar_bz2 => try std.testing.expect(std.mem.endsWith(u8, dl.url, ".tar.bz2")),
            .tar_gz => try std.testing.expect(false),
        }
    }

    // Binary names carry `.exe` only on Windows.
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("nervad.exe", Nerva.daemon_file);
    } else {
        try std.testing.expectEqualStrings("nervad", Nerva.daemon_file);
    }
}

test "coin vtable dispatches to Nerva metadata" {
    var n: Nerva = .{};
    const c = n.coin();
    try std.testing.expectEqualStrings("Nerva", c.coinName());
    try std.testing.expectEqualStrings("XNV", c.coinNameAbbrev());
    try std.testing.expectEqualStrings("#344769", c.coinColor());
    try std.testing.expect(!c.isProofOfStake());
    try std.testing.expectEqualStrings("nerva.conf", c.confFile());
    try std.testing.expectEqualStrings("17566", c.rpcDefaultPort());
    try std.testing.expectEqual(Coin.LaunchMode.foreground, c.launchMode());
}

test "prepareConf writes a Monero-valid conf nervad can parse (no bitcoin keys)" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A throwaway home; prepareConf resolves `<home>/.nerva/nerva.conf` from it,
    // so this stays entirely offline (no real datadir touched).
    const home = "test-nerva-home";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // Pre-seed a poisoned, bitcoin-style conf (what older builds wrote and what
    // crashed nervad) to prove prepare is self-healing — it must be replaced, not
    // appended to.
    {
        const poisoned = try std.fs.path.join(allocator, &.{ home, Nerva.home_dir });
        defer allocator.free(poisoned);
        var pd = try std.Io.Dir.cwd().createDirPathOpen(io, poisoned, .{});
        defer pd.close(io);
        try pd.writeFile(io, .{ .sub_path = Nerva.conf_file, .data = "rpcuser=nervarpc\nserver=1\ndaemon=1\nrpcport=17566\n" });
    }

    try Nerva.prepareConf(allocator, io, home);

    // Read the conf back. nervad parses this on startup, so it must carry only
    // Monero-style options — the bitcoin keys (`rpcuser`/`server`/`daemon`/
    // `rpcport`) it rejects must be absent, and the RPC port present in Monero form.
    const path = try std.fs.path.join(allocator, &.{ home, Nerva.home_dir });
    defer allocator.free(path);
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    var f = try dir.openFile(io, Nerva.conf_file, .{});
    defer f.close(io);
    var rb: [4096]u8 = undefined;
    const n = try f.readPositionalAll(io, &rb, 0);
    const content = rb[0..n];

    try std.testing.expect(std.mem.indexOf(u8, content, "rpc-bind-port=" ++ Nerva.rpc_default_port) != null);
    for ([_][]const u8{ "rpcuser", "rpcpassword", "server", "daemon=", "rpcport" }) |bad| {
        try std.testing.expect(std.mem.indexOf(u8, content, bad) == null);
    }
}

// --- External wallet (Monero wallet-rpc) tests ---------------------------

test "get_balance atomic units map to XNV Total/Available (12 decimals)" {
    const allocator = std.testing.allocator;

    // 1.5 XNV total, 1.0 XNV unlocked, in 1e12 atomic units.
    const raw =
        \\{"id":"0","jsonrpc":"2.0","result":{"balance":1500000000000,"unlocked_balance":1000000000000}}
    ;
    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(Nerva.WalletBalanceResult),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    const bal = Nerva.atomicToBalance(r.balance, r.unlocked_balance);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), bal.total, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), bal.available, 1e-9);
    // Total ahead of available → funds still settling.
    try std.testing.expect(bal.hasPending());
}

test "isValidSeed accepts a 25-word phrase and rejects other counts" {
    // 25 space-separated tokens (content irrelevant — only the count is checked).
    const ok = "a a a a a a a a a a a a a a a a a a a a a a a a a";
    try std.testing.expect(Nerva.isValidSeed(ok));
    // Leading/trailing whitespace is trimmed, internal runs tolerated.
    try std.testing.expect(Nerva.isValidSeed("  " ++ ok ++ "\n"));
    // Too few / too many words fail fast.
    try std.testing.expect(!Nerva.isValidSeed("a a a"));
    try std.testing.expect(!Nerva.isValidSeed(ok ++ " extra"));
    try std.testing.expect(!Nerva.isValidSeed(""));
}

test "normalizeSeed lowercases words and collapses whitespace to single spaces" {
    const allocator = std.testing.allocator;

    // Capitalized first word + newlines + double spaces all clean up to the
    // canonical single-spaced lowercase phrase Monero's decode expects.
    const got = try Nerva.normalizeSeed(allocator, "  Abbey   bacon\nCactus  ");
    defer allocator.free(got);
    try std.testing.expectEqualStrings("abbey bacon cactus", got);

    // An already-clean phrase is returned unchanged.
    const clean = try Nerva.normalizeSeed(allocator, "abbey bacon cactus");
    defer allocator.free(clean);
    try std.testing.expectEqualStrings("abbey bacon cactus", clean);
}

test "walletRpcError maps known Monero messages to specific errors" {
    const E = Nerva.RpcErrObj;
    try std.testing.expect(Nerva.walletRpcError(E{ .code = -8, .message = "Wallet already exists." }, error.WalletRestoreFailed) == error.WalletAlreadyExists);
    try std.testing.expect(Nerva.walletRpcError(E{ .message = "Electrum-style word list failed verification" }, error.WalletRestoreFailed) == error.SeedWordsInvalid);
    try std.testing.expect(Nerva.walletRpcError(E{ .message = "invalid password" }, error.WalletOpenFailed) == error.WrongPassword);
    // Unfamiliar message / no error object → the caller's fallback.
    try std.testing.expect(Nerva.walletRpcError(E{ .message = "something new" }, error.WalletRestoreFailed) == error.WalletRestoreFailed);
    try std.testing.expect(Nerva.walletRpcError(null, error.WalletRestoreFailed) == error.WalletRestoreFailed);
}

test "walletProcessArgv binds wallet-rpc to localhost and points it at the daemon" {
    const allocator = std.testing.allocator;

    const argv = try Nerva.walletProcessArgv(allocator, "/opt/bw", "/home/alice", Nerva.wallet_rpc_port);
    defer {
        for (argv) |a| allocator.free(a);
        allocator.free(argv);
    }

    // First arg is the promoted wallet-rpc binary under the install root.
    try std.testing.expect(std.mem.endsWith(u8, argv[0], Nerva.wallet_rpc_file));
    try std.testing.expect(std.mem.startsWith(u8, argv[0], "/opt/bw"));

    // Joined for easy substring assertions on the flags.
    const joined = try std.mem.join(allocator, " ", argv);
    defer allocator.free(joined);
    try std.testing.expect(std.mem.indexOf(u8, joined, "--wallet-dir") != null);
    // The wallet dir is `<datadir>/wallets`.
    try std.testing.expect(std.mem.indexOf(u8, joined, "wallets") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "--rpc-bind-ip 127.0.0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "--rpc-bind-port " ++ Nerva.wallet_rpc_port) != null);
    // Pointed at the local daemon's RPC port, and keyless to match its open RPC.
    try std.testing.expect(std.mem.indexOf(u8, joined, "--daemon-address 127.0.0.1:" ++ Nerva.rpc_default_port) != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "--disable-rpc-login") != null);
}

test "walletExists keys off the BoxWallet.keys file on disk" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A throwaway home; walletExists resolves `<home>/.nerva/wallets/BoxWallet.keys`.
    const home = "test-nerva-wallet-home";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // No wallet yet → false.
    try std.testing.expect(!Nerva.walletExists(allocator, home));

    // Lay down the keys file and it flips to true.
    const wallet_dir = try std.fs.path.join(allocator, &.{ home, Nerva.home_dir, "wallets" });
    defer allocator.free(wallet_dir);
    var wd = try std.Io.Dir.cwd().createDirPathOpen(io, wallet_dir, .{});
    defer wd.close(io);
    try wd.writeFile(io, .{ .sub_path = "BoxWallet.keys", .data = "KEYS" });

    try std.testing.expect(Nerva.walletExists(allocator, home));
}

test "Nerva wires the external-wallet capability" {
    var n: Nerva = .{};
    const c = n.coin();
    try std.testing.expect(c.hasExternalWallet());
    const ew = c.externalWallet().?;
    try std.testing.expectEqualStrings(Nerva.wallet_rpc_port, ew.rpc_port());
}
