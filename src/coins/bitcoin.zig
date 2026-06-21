const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const rpc = @import("../rpc.zig");
const install_mod = @import("../install.zig");
const conf = @import("../conf.zig");
const Coin = @import("../coin.zig").Coin;

/// Bitcoin backend.
///
/// Bitcoin Core shares the streaming install path and `key=value` conf with the
/// other Bitcoin-derived coins (Nexa/Divi/DigiByte/Litecoin). It has no
/// `getinfo`, so the live status is assembled from `getblockchaininfo`
/// (chain/height/sync) + `getnetworkinfo` (peer count), and a modern Core daemon
/// no longer auto-creates a wallet, so one is load-or-created after start.
///
/// Bitcoin's full chain is very large, so — like Litecoin — it wires the optional
/// `Pruning` capability: the first time its daemon starts, the user is asked how
/// much disk to cap the blockchain at, persisted as `prune=<MiB>` in the conf and
/// surfaced read-only on the Settings tab.
pub const Bitcoin = struct {
    /// Whether the coin is exposed in the nav. False keeps it out of the left
    /// bar entirely (registered but hidden) until it's ready for users.
    pub const live = true;
    pub const coin_name = "Bitcoin";
    pub const coin_name_abbrev = "BTC";
    /// One-line description shown under the coin name on the detail pane.
    pub const coin_description = "The original cryptocurrency — digital gold.";
    /// Bitcoin brand colour (`#RRGGBB`), for tinting the coin in the frontend.
    pub const coin_color = "#F7931A";
    /// Bitcoin is proof-of-work (SHA-256) — no wallet staking.
    pub const proof_of_stake = false;
    pub const conf_file = "bitcoin.conf";
    pub const home_dir = ".bitcoin";
    pub const home_dir_win = "Bitcoin";
    pub const rpc_default_username = "bitcoinrpc";
    pub const rpc_default_port = "8332";
    pub const core_version = "31.0";

    // Binary names. Windows appends `.exe`; Linux/macOS use the bare names.
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    pub const daemon_file = "bitcoind" ++ exe_suffix;
    pub const cli_file = "bitcoin-cli" ++ exe_suffix;
    pub const tx_file = "bitcoin-tx" ++ exe_suffix;

    // Download host. Every bundle wraps its executables in `bitcoin-<ver>/bin/`,
    // identically across platforms (Linux/macOS `.tar.gz`, Windows `.zip`).
    const download_base = "https://bitcoincore.org/bin/bitcoin-core-" ++ core_version ++ "/";

    /// The download URL + archive format for the build target, or null where
    /// Bitcoin Core publishes no matching daemon bundle. Selected at comptime from
    /// the OS/arch. Bitcoin Core ships streamable bundles for every desktop target,
    /// including a **native** Apple-Silicon build (unlike Litecoin):
    ///   - Linux x86_64/aarch64: `.tar.gz`.
    ///   - Windows x86_64: `win64.zip` (extracted from the seekable scratch file).
    ///   - macOS x86_64/arm64: their respective `apple-darwin.tar.gz`.
    const download: ?install_mod.Download = switch (builtin.os.tag) {
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => .{ .url = download_base ++ "bitcoin-" ++ core_version ++ "-win64.zip", .format = .zip },
            else => null,
        },
        .macos => switch (builtin.cpu.arch) {
            .x86_64 => .{ .url = download_base ++ "bitcoin-" ++ core_version ++ "-x86_64-apple-darwin.tar.gz", .format = .tar_gz },
            .aarch64 => .{ .url = download_base ++ "bitcoin-" ++ core_version ++ "-arm64-apple-darwin.tar.gz", .format = .tar_gz },
            else => null,
        },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => .{ .url = download_base ++ "bitcoin-" ++ core_version ++ "-x86_64-linux-gnu.tar.gz", .format = .tar_gz },
            .aarch64 => .{ .url = download_base ++ "bitcoin-" ++ core_version ++ "-aarch64-linux-gnu.tar.gz", .format = .tar_gz },
            else => null,
        },
        else => null,
    };

    // Layout inside the archive: keep only the daemon/cli/tx binaries (from
    // `bin/`) at the install root; the whole `bitcoin-<ver>/` tree is discarded.
    const extracted_dir = "bitcoin-" ++ core_version;
    const bin_subdir = "bin";
    const promote_files = [_][]const u8{ daemon_file, cli_file, tx_file };

    // Temp file the download streams to. Keyed off the daemon name so a concurrent
    // install of another coin into the same `~/.boxwallet` root uses a different
    // scratch file and the two never collide.
    pub const scratch_file = ".boxwallet-" ++ daemon_file ++ ".part";

    /// Build the type-erased `Coin` handle for this instance.
    pub fn coin(self: *Bitcoin) Coin {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Live `getblockchaininfo`, normalized for a frontend. Bitcoin reports
    /// `verificationprogress`, so "synced" is derived from it as for Litecoin
    /// (progress > 0.99999).
    pub fn blockchainState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.BlockchainState {
        var parsed = try rpc.callParsed(models.BtcBlockchainInfo, allocator, auth, "getblockchaininfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return .{
            .chain = try allocator.dupe(u8, r.chain),
            .blocks = r.blocks,
            .headers = r.headers,
            .verification_progress = r.verificationprogress,
            .synced = r.verificationprogress > 0.99999,
            // Network tip from peers, so the frontend's Headers bar can fill
            // toward it. A getpeerinfo hiccup just leaves it 0 (unknown).
            .network_height = rpc.networkHeight(allocator, auth) catch 0,
            // Tip block timestamp, so the frontend can show how far behind in
            // wall-clock time the chain is while validating. Prefer the exact tip
            // `time`; fall back to `mediantime` when the daemon omits it.
            .tip_time = if (r.time > 0) r.time else r.mediantime,
        };
    }

    /// Live status, normalized for a frontend. Bitcoin has no `getinfo`, so the
    /// block height comes from `getblockchaininfo` and the peer count from
    /// `getnetworkinfo`. Bitcoin is proof-of-work, so `staking_active` is false.
    pub fn daemonInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.DaemonInfo {
        var bc = try rpc.callParsed(models.BtcBlockchainInfo, allocator, auth, "getblockchaininfo");
        defer bc.deinit();
        const b = bc.value.result orelse return error.EmptyRpcResult;

        var net = try rpc.callParsed(models.BtcNetworkInfo, allocator, auth, "getnetworkinfo");
        defer net.deinit();
        const n = net.value.result orelse return error.EmptyRpcResult;

        return .{
            .blocks = b.blocks,
            .connections = n.connections,
            .staking_active = false,
            // `getnetworkinfo`'s numeric CLIENT_VERSION → dotted string, owned by
            // `allocator` so it outlives `net`'s deinit.
            .version = try models.clientVersionString(allocator, n.version),
        };
    }

    /// The daemon's default data directory (`~/.bitcoin`), where `bitcoin.conf`
    /// lives.
    pub fn dataDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        return conf.dataDir(allocator, home, home_dir, home_dir_win);
    }

    /// The managed wallet's on-disk location — the bitcoin-core wallet directory
    /// `<datadir>/wallets/BoxWallet` (holding `wallet.dat`), created by
    /// `ensureWallet`. Caller owns the returned strings.
    pub fn walletPath(allocator: std.mem.Allocator, home: []const u8) !?Coin.WalletFile {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        return .{ .path = try std.fs.path.join(allocator, &.{ data_dir, "wallets", "BoxWallet" }) };
    }

    /// True if `bitcoind` (`bitcoind.exe` on Windows) is already present under
    /// `install_root`.
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, daemon_file);
    }

    /// Download + unarchive the Bitcoin daemon files into `install_root`,
    /// optionally reporting download/extract progress. Streams to a scratch file,
    /// then `promoteAndTidy` lifts daemon/cli/tx out of the wrapper's `bin/`.
    pub fn install(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        const dl = download orelse return error.UnsupportedPlatform;
        try install_mod.downloadAndExtract(allocator, dl.url, dl.format, install_root, scratch_file, 0, progress);
        try install_mod.promoteAndTidy(allocator, install_root, extracted_dir, bin_subdir, &promote_files);
    }

    /// Ensure `bitcoin.conf` carries the RPC creds (and `server=1`/`rpcport`)
    /// BoxWallet needs before the daemon reads it; existing values are kept. A
    /// standard bitcoin-derived `key=value` conf. The user's chosen `prune` value
    /// (written by the prune prompt at first start) is preserved untouched.
    pub fn prepareConf(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        _ = try conf.populate(allocator, io, data_dir, conf_file, rpc_default_username, rpc_default_port);
    }

    /// Bitcoin is a bitcoin-derived daemon: it forks itself into the background
    /// with `-daemon` on POSIX, but runs in the foreground on Windows.
    pub fn launchMode() Coin.LaunchMode {
        return if (builtin.os.tag == .windows) .foreground else .fork;
    }

    /// The daemon binary path. The launcher appends `-daemon` itself for the fork
    /// path; on Windows it's spawned bare (detached).
    pub fn daemonArgv(allocator: std.mem.Allocator, install_root: []const u8, _: []const u8) ![]const []const u8 {
        const path = try std.fs.path.join(allocator, &.{ install_root, daemon_file });
        const argv = try allocator.alloc([]const u8, 1);
        argv[0] = path;
        return argv;
    }

    /// Ask bitcoind to shut down via the JSON-RPC `stop`.
    pub fn requestStop(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        const reply = try rpc.call(allocator, auth, "stop");
        allocator.free(reply);
    }

    /// Bitcoin Core doesn't auto-create a wallet, so address/balance RPCs have
    /// none to act on until one exists. Load-or-create a wallet named "BoxWallet"
    /// once the daemon is up.
    pub fn ensureWallet(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        return rpc.ensureWallet(allocator, auth, "BoxWallet");
    }

    /// Read the wallet's security state from `getwalletinfo`. Bitcoin-core style:
    /// `unlocked_until` is **absent** on an unencrypted wallet, `0` when locked,
    /// and a positive unlock timestamp otherwise.
    pub fn walletSecurityState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.WalletSecurity {
        var parsed = try rpc.callParsed(models.BtcWalletInfo, allocator, auth, "getwalletinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return securityFromUnlockedUntil(r.unlocked_until);
    }

    /// Read the wallet's balances from `getwalletinfo`. `available` is the
    /// confirmed spendable `balance`; `total` adds the mempool
    /// (`unconfirmed_balance`) and maturing (`immature_balance`) funds.
    pub fn walletBalance(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.WalletBalance {
        var parsed = try rpc.callParsed(models.BtcWalletInfo, allocator, auth, "getwalletinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return models.WalletBalance.fromParts(r.balance, r.unconfirmed_balance, r.immature_balance);
    }

    /// Map a bitcoin-core `unlocked_until` (absent/0/positive) to the normalized
    /// `WalletSecurity`. Shared by the parse path and its unit test.
    fn securityFromUnlockedUntil(unlocked_until: ?i64) models.WalletSecurity {
        const u = unlocked_until orelse return .unencrypted;
        if (u == 0) return .locked;
        return .unlocked;
    }

    /// Encrypt the wallet with `passphrase`. bitcoind stops itself afterwards (the
    /// caller restarts it). The passphrase is JSON-escaped before splicing.
    pub fn walletEncrypt(allocator: std.mem.Allocator, auth: models.CoinAuth, passphrase: []const u8) !void {
        const pw = try rpc.jsonQuote(allocator, passphrase);
        defer allocator.free(pw);
        const params = try std.fmt.allocPrint(allocator, "[{s}]", .{pw});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "encryptwallet", params);
    }

    /// Unlock the wallet via `walletpassphrase`. Bitcoin is proof-of-work, so the
    /// `staking` flag is irrelevant — a plain unlock with an indefinite timeout (0).
    pub fn walletUnlock(allocator: std.mem.Allocator, auth: models.CoinAuth, passphrase: []const u8, _: bool) !void {
        const pw = try rpc.jsonQuote(allocator, passphrase);
        defer allocator.free(pw);
        const params = try std.fmt.allocPrint(allocator, "[{s},0]", .{pw});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "walletpassphrase", params);
    }

    /// Re-lock the wallet via `walletlock`.
    pub fn walletLock(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        return rpc.callExpectOk(allocator, auth, "walletlock", "[]");
    }

    /// Back up the wallet to `dest_path` via `dumpwallet` — a human-readable dump
    /// of the wallet's keys + HD seed that the user keeps as their backup (it is
    /// the backup, not a temp: don't shred it). bitcoind refuses this on a locked
    /// wallet, so the UI only offers it when the wallet is unlocked/unencrypted.
    /// The path is JSON-escaped before splicing.
    pub fn walletBackup(allocator: std.mem.Allocator, auth: models.CoinAuth, dest_path: []const u8) !void {
        const qpath = try rpc.jsonQuote(allocator, dest_path);
        defer allocator.free(qpath);
        const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qpath});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "dumpwallet", params);
    }

    /// Restore wallet keys from a `dumpwallet` file via `importwallet`, which
    /// imports the keys and rescans the chain. The rescan blocks the RPC until it
    /// finishes, so on a slow machine this can outlast the client timeout and read
    /// as a failure even though bitcoind keeps rescanning — acceptable for v1.
    /// Like backup, requires the wallet unlocked/unencrypted. Path JSON-escaped.
    pub fn walletImportFile(allocator: std.mem.Allocator, auth: models.CoinAuth, src_path: []const u8) !void {
        const qpath = try rpc.jsonQuote(allocator, src_path);
        defer allocator.free(qpath);
        const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qpath});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "importwallet", params);
    }

    /// Bitcoin has no `getinfo`, so probe `getnetworkinfo` for the daemon's
    /// warm-up phase (any supported method returns the "-28 in warm-up" reply).
    pub fn warmupProbeMethod() []const u8 {
        return "getnetworkinfo";
    }

    // --- pruning capability ----------------------------------------------
    //
    // Bitcoin's chain is very large, so on the *first* daemon start the user picks
    // how much disk to cap it at; the choice is written to `bitcoin.conf` as
    // `prune=<MiB>` (0 = full node) and read back for the Settings tab. Each fn
    // creates its own threaded IO so callers don't thread one through.

    pub const pruning_caps: Coin.Pruning = .{
        .should_offer = pruneShouldOffer,
        .apply = pruneApply,
        .current = pruneCurrent,
    };

    /// Offer the prune prompt only when the conf carries no `prune` setting yet —
    /// so it's asked exactly once, and a conf the user already pruned is respected.
    fn pruneShouldOffer(allocator: std.mem.Allocator, home: []const u8) bool {
        const cur = pruneCurrent(allocator, home) catch return false;
        return cur == null;
    }

    /// Persist the chosen prune target (MiB; 0 = full node) to `bitcoin.conf`,
    /// creating the conf/dir if absent and preserving every other line.
    fn pruneApply(allocator: std.mem.Allocator, home: []const u8, prune_mib: i64) anyerror!void {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        var buf: [24]u8 = undefined;
        const val = std.fmt.bufPrint(&buf, "{d}", .{prune_mib}) catch unreachable;
        try conf.setValue(allocator, io, data_dir, conf_file, "prune", val);
    }

    /// The configured prune target (MiB, 0, or null when unset) for the Settings
    /// tab. A malformed value reads as null rather than erroring the display.
    fn pruneCurrent(allocator: std.mem.Allocator, home: []const u8) anyerror!?i64 {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        const raw = (try conf.readValue(allocator, io, data_dir, conf_file, "prune")) orelse return null;
        defer allocator.free(raw);
        return std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t"), 10) catch null;
    }

    // --- vtable plumbing -------------------------------------------------

    const vtable: Coin.VTable = .{
        .coin_name = vtCoinName,
        .coin_name_abbrev = vtCoinNameAbbrev,
        .coin_description = vtCoinDescription,
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
        .wallet_path = vtWalletPath,
        .is_installed = vtIsInstalled,
        .install = vtInstall,
        .prepare_conf = vtPrepareConf,
        .launch_mode = vtLaunchMode,
        .daemon_argv = vtDaemonArgv,
        .request_stop = vtRequestStop,
        .ensure_wallet = vtEnsureWallet,
        .wallet_security_state = vtWalletSecurityState,
        .wallet_balance = vtWalletBalance,
        .wallet_encrypt = vtWalletEncrypt,
        .wallet_unlock = vtWalletUnlock,
        .wallet_lock = vtWalletLock,
        .wallet_backup = vtWalletBackup,
        .wallet_import_file = vtWalletImportFile,
        .warmup_probe_method = vtWarmupProbeMethod,
        .pruning = &pruning_caps,
    };

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
    fn vtEnsureWallet(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) anyerror!void {
        return ensureWallet(allocator, auth);
    }
    fn vtWalletSecurityState(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) anyerror!models.WalletSecurity {
        return walletSecurityState(allocator, auth);
    }
    fn vtWalletBalance(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) anyerror!models.WalletBalance {
        return walletBalance(allocator, auth);
    }
    fn vtWalletEncrypt(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        passphrase: []const u8,
    ) anyerror!void {
        return walletEncrypt(allocator, auth, passphrase);
    }
    fn vtWalletUnlock(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        passphrase: []const u8,
        staking: bool,
    ) anyerror!void {
        return walletUnlock(allocator, auth, passphrase, staking);
    }
    fn vtWalletLock(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) anyerror!void {
        return walletLock(allocator, auth);
    }
    fn vtWalletBackup(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        dest_path: []const u8,
    ) anyerror!void {
        return walletBackup(allocator, auth, dest_path);
    }
    fn vtWalletImportFile(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        src_path: []const u8,
    ) anyerror!void {
        return walletImportFile(allocator, auth, src_path);
    }
    fn vtWarmupProbeMethod(_: *anyopaque) []const u8 {
        return warmupProbeMethod();
    }
};

test "parses getblockchaininfo into normalized BlockchainState" {
    const allocator = std.testing.allocator;

    const raw =
        \\{"result":{"chain":"main","blocks":880000,"headers":880000,
        \\"bestblockhash":"deadbeef","verificationprogress":0.999999,
        \\"mediantime":1700000000,"time":1700000005,"pruned":true},
        \\"error":null,"id":"boxwallet"}
    ;
    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.BtcBlockchainInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    const state: models.BlockchainState = .{
        .chain = try allocator.dupe(u8, r.chain),
        .blocks = r.blocks,
        .headers = r.headers,
        .verification_progress = r.verificationprogress,
        .synced = r.verificationprogress > 0.99999,
        .tip_time = if (r.time > 0) r.time else r.mediantime,
    };
    defer state.deinit(allocator);

    try std.testing.expectEqualStrings("main", state.chain);
    try std.testing.expectEqual(@as(i64, 880000), state.blocks);
    try std.testing.expect(state.synced);
    try std.testing.expectEqual(@as(i64, 1700000005), state.tip_time);
}

test "platform selection resolves a streamable bundle for the build target" {
    switch (builtin.os.tag) {
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => try std.testing.expectEqual(install_mod.Format.zip, Bitcoin.download.?.format),
            else => try std.testing.expect(Bitcoin.download == null),
        },
        .macos => switch (builtin.cpu.arch) {
            .x86_64, .aarch64 => try std.testing.expectEqual(install_mod.Format.tar_gz, Bitcoin.download.?.format),
            else => try std.testing.expect(Bitcoin.download == null),
        },
        .linux => switch (builtin.cpu.arch) {
            .x86_64, .aarch64 => try std.testing.expectEqual(install_mod.Format.tar_gz, Bitcoin.download.?.format),
            else => try std.testing.expect(Bitcoin.download == null),
        },
        else => try std.testing.expect(Bitcoin.download == null),
    }

    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("bitcoind.exe", Bitcoin.daemon_file);
    } else {
        try std.testing.expectEqualStrings("bitcoind", Bitcoin.daemon_file);
    }
}

test "coin vtable dispatches to Bitcoin metadata" {
    var btc: Bitcoin = .{};
    const c = btc.coin();
    try std.testing.expectEqualStrings("Bitcoin", c.coinName());
    try std.testing.expectEqualStrings("BTC", c.coinNameAbbrev());
    try std.testing.expectEqualStrings("#F7931A", c.coinColor());
    try std.testing.expect(!c.isProofOfStake());
    try std.testing.expectEqualStrings("bitcoin.conf", c.confFile());
    try std.testing.expectEqualStrings("8332", c.rpcDefaultPort());
    // Bitcoin Core: needs an explicit wallet created/loaded after start.
    try std.testing.expect(c.needsWallet());
    try std.testing.expect(c.supportsWallet());
    try std.testing.expect(c.supportsBalance());
    // dumpwallet/importwallet backup ceremony is wired (like ReddCoin).
    try std.testing.expect(c.supportsWalletBackup());
    try std.testing.expect(c.supportsWalletImport());
}

test "walletPath points at the bitcoin-core BoxWallet directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var btc: Bitcoin = .{};
    const wf = (try btc.coin().walletPath(allocator, "/home/alice")).?;
    defer allocator.free(wf.path);
    try std.testing.expectEqualStrings("/home/alice/.bitcoin/wallets/BoxWallet", wf.path);
    try std.testing.expect(wf.keys == null);
}

test "maps getwalletinfo unlocked_until to the wallet security state" {
    try std.testing.expectEqual(models.WalletSecurity.unencrypted, Bitcoin.securityFromUnlockedUntil(null));
    try std.testing.expectEqual(models.WalletSecurity.locked, Bitcoin.securityFromUnlockedUntil(0));
    try std.testing.expectEqual(models.WalletSecurity.unlocked, Bitcoin.securityFromUnlockedUntil(1893456000));
}

test "pruning: offered when unset, then applied value is read back and not re-offered" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var btc: Bitcoin = .{};
    const c = btc.coin();

    // A throwaway HOME whose ~/.bitcoin/bitcoin.conf doesn't exist yet.
    const home = "test-btc-prune-home";
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // No conf → prompt is offered and there's no configured value.
    try std.testing.expect(c.offersPrunePrompt(allocator, home));
    try std.testing.expect((try c.pruningState(allocator, home)) == null);

    // Apply 5 GB (5000 MiB): it's read back and the prompt is no longer offered.
    try c.applyPrune(allocator, home, 5000);
    try std.testing.expectEqual(@as(?i64, 5000), try c.pruningState(allocator, home));
    try std.testing.expect(!c.offersPrunePrompt(allocator, home));

    // "No pruning" (0) is a real configured value, distinct from unset.
    try c.applyPrune(allocator, home, 0);
    try std.testing.expectEqual(@as(?i64, 0), try c.pruningState(allocator, home));
    try std.testing.expect(!c.offersPrunePrompt(allocator, home));
}
