const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const rpc = @import("../rpc.zig");
const install_mod = @import("../install.zig");
const conf = @import("../conf.zig");
const Coin = @import("../coin.zig").Coin;

/// DigiByte backend. Constants lifted from
/// `cmd/cli/cmd/coins/digibyte/digibyte.go`.
///
/// DigiByte is a bitcoin-core fork, so it shares the streaming install path and
/// `key=value` conf with Nexa/Divi. The one structural difference is the RPC
/// surface: DigiByte dropped `getinfo` in core 6.16.0, so the live status is
/// assembled from two calls — `getblockchaininfo` (chain/height/sync) and
/// `getnetworkinfo` (peer count) — rather than a single `getinfo`.
pub const DigiByte = struct {
    pub const coin_name = "DigiByte";
    pub const coin_name_abbrev = "DGB";
    /// DigiByte brand colour (`#RRGGBB`), for tinting the coin in the frontend.
    pub const coin_color = "#0066CC";
    /// DigiByte is proof-of-work (multi-algo) — no wallet staking.
    pub const proof_of_stake = false;
    pub const conf_file = "digibyte.conf";
    pub const home_dir = ".digibyte";
    pub const home_dir_win = "DIGIBYTE";
    pub const rpc_default_username = "digibyterpc";
    pub const rpc_default_port = "14022";
    // Latest 8.x stable release. The Go reference still pins 7.17.2, but BoxWallet
    // tracks the current stable line. The trade-off of moving to 8.x is platform
    // reach: 8.x publishes no streamable daemon bundle outside Linux — Windows
    // ships solely an NSIS `setup.exe` (not an archive the installer can stream),
    // and the macOS `.zip` carries only the DigiByte-Qt GUI app (no
    // `digibyted`/cli/tx). So only Linux resolves a usable download below; Windows
    // and macOS are null (`error.UnsupportedPlatform` at install time).
    pub const core_version = "8.26.2";

    // Binary names. Windows appends `.exe`; Linux/macOS use the bare names. The
    // per-target name is what `isInstalled`, the daemon launcher, and the promote
    // list all use, so a Windows build looks for `digibyted.exe` and a POSIX build
    // for `digibyted`.
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    pub const daemon_file = "digibyted" ++ exe_suffix;
    pub const cli_file = "digibyte-cli" ++ exe_suffix;
    pub const tx_file = "digibyte-tx" ++ exe_suffix;

    // Download host. The Linux bundles wrap their executables in
    // `digibyte-<ver>/bin/` (verified against the 8.26.2 tar.gz, x86_64 + aarch64).
    const download_base = "https://github.com/DigiByte-Core/digibyte/releases/download/v" ++ core_version ++ "/";

    /// The download URL + archive format for the build target, or null where
    /// DigiByte publishes no streamable daemon bundle. Selected at comptime from
    /// the OS/arch. Only Linux x86_64/aarch64 ship a usable `.tar.gz`; everything
    /// else is null:
    ///   - Windows ships only an NSIS `setup.exe`, which the installer can't stream.
    ///   - macOS ships only a GUI-only `DigiByte-Qt.app` zip (no daemon/cli/tx).
    ///   - Linux arm32/386 have no published build.
    const download: ?install_mod.Download = switch (builtin.os.tag) {
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => .{ .url = download_base ++ "digibyte-" ++ core_version ++ "-x86_64-linux-gnu.tar.gz", .format = .tar_gz },
            .aarch64 => .{ .url = download_base ++ "digibyte-" ++ core_version ++ "-aarch64-linux-gnu.tar.gz", .format = .tar_gz },
            else => null,
        },
        else => null,
    };

    // Layout inside the archive: keep only the daemon/cli/tx binaries (from
    // `bin/`) at the install root; the whole `digibyte-<ver>/` tree is discarded
    // afterwards. Matches the Go installer.
    const extracted_dir = "digibyte-" ++ core_version;
    const bin_subdir = "bin";
    const promote_files = [_][]const u8{ daemon_file, cli_file, tx_file };

    // Temp file the download streams to. Keyed off the daemon name so a
    // concurrent install of another coin into the same `~/.boxwallet` root uses
    // a different scratch file and the two never collide.
    pub const scratch_file = ".boxwallet-" ++ daemon_file ++ ".part";

    /// Build the type-erased `Coin` handle for this instance.
    pub fn coin(self: *DigiByte) Coin {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Live `getblockchaininfo`, normalized for a frontend. DigiByte reports
    /// `verificationprogress`, so "synced" is derived from it exactly as for Nexa
    /// (Go's `BlockchainIsSynced` => progress > 0.99999).
    pub fn blockchainState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.BlockchainState {
        var parsed = try rpc.callParsed(models.DgbBlockchainInfo, allocator, auth, "getblockchaininfo");
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
            // wall-clock time the chain is while validating. Prefer the exact
            // tip `time`; fall back to `mediantime` when the daemon omits it.
            .tip_time = if (r.time > 0) r.time else r.mediantime,
        };
    }

    /// Live status, normalized for a frontend. DigiByte has no `getinfo`, so the
    /// block height comes from `getblockchaininfo` and the peer count from
    /// `getnetworkinfo`. DigiByte is proof-of-work, so `staking_active` is always
    /// false.
    pub fn daemonInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.DaemonInfo {
        var bc = try rpc.callParsed(models.DgbBlockchainInfo, allocator, auth, "getblockchaininfo");
        defer bc.deinit();
        const b = bc.value.result orelse return error.EmptyRpcResult;

        var net = try rpc.callParsed(models.DgbNetworkInfo, allocator, auth, "getnetworkinfo");
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

    /// The daemon's default data directory (`~/.digibyte`), where `digibyte.conf`
    /// lives.
    pub fn dataDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        return conf.dataDir(allocator, home, home_dir, home_dir_win);
    }

    /// True if `digibyted` (`digibyted.exe` on Windows) is already present under
    /// `install_root`.
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, daemon_file);
    }

    /// Download + unarchive the DigiByte daemon files into `install_root`,
    /// optionally reporting download/extract progress.
    ///
    /// Extracts the versioned wrapper dir intact, then `promoteAndTidy` lifts the
    /// daemon/cli/tx binaries to the install root and removes the wrapper,
    /// leaving `digibyted` exactly where `isInstalled` looks for it.
    pub fn install(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        const dl = download orelse return error.UnsupportedPlatform;
        try install_mod.downloadAndExtract(allocator, dl.url, dl.format, install_root, scratch_file, 0, progress);
        try install_mod.promoteAndTidy(allocator, install_root, extracted_dir, bin_subdir, &promote_files);
    }

    /// Ensure `digibyte.conf` carries the RPC creds (and `server=1`/`daemon=1`/
    /// `rpcport`) BoxWallet needs before the daemon reads it; existing values are
    /// kept. A standard bitcoin-derived `key=value` conf.
    pub fn prepareConf(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        _ = try conf.populate(allocator, io, data_dir, conf_file, rpc_default_username, rpc_default_port);
    }

    /// DigiByte is a bitcoin-derived daemon: it forks itself into the background
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

    /// Ask digibyted to shut down via the JSON-RPC `stop`.
    pub fn requestStop(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        const reply = try rpc.call(allocator, auth, "stop");
        allocator.free(reply);
    }

    /// DigiByte 8.x (Bitcoin Core 26) doesn't auto-create a wallet, so address /
    /// balance RPCs have none to act on until one exists. Load-or-create a wallet
    /// named "BoxWallet" once the daemon is up.
    pub fn ensureWallet(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        return rpc.ensureWallet(allocator, auth, "BoxWallet");
    }

    /// Read the wallet's security state from `getwalletinfo`. DigiByte is
    /// bitcoin-core style: `unlocked_until` is **absent** on an unencrypted wallet,
    /// `0` when locked, and a positive unlock timestamp otherwise.
    pub fn walletSecurityState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.WalletSecurity {
        var parsed = try rpc.callParsed(models.DgbWalletInfo, allocator, auth, "getwalletinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return securityFromUnlockedUntil(r.unlocked_until);
    }

    /// Read the wallet's balances from `getwalletinfo`. `available` is the
    /// confirmed spendable `balance`; `total` adds the mempool
    /// (`unconfirmed_balance`) and maturing (`immature_balance`) funds, so it
    /// reflects incoming money the moment it's seen.
    pub fn walletBalance(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.WalletBalance {
        var parsed = try rpc.callParsed(models.DgbWalletInfo, allocator, auth, "getwalletinfo");
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

    /// Encrypt the wallet with `passphrase`. digibyted stops itself afterwards (the
    /// caller restarts it). The passphrase is JSON-escaped before splicing.
    pub fn walletEncrypt(allocator: std.mem.Allocator, auth: models.CoinAuth, passphrase: []const u8) !void {
        const pw = try rpc.jsonQuote(allocator, passphrase);
        defer allocator.free(pw);
        const params = try std.fmt.allocPrint(allocator, "[{s}]", .{pw});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "encryptwallet", params);
    }

    /// Unlock the wallet via `walletpassphrase`. DigiByte is proof-of-work, so the
    /// `staking` flag is irrelevant — a plain unlock with an indefinite timeout (0)
    /// is used either way.
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

    /// DigiByte dropped `getinfo`, so probe `getnetworkinfo` for the daemon's
    /// warm-up phase (any supported method returns the "-28 in warm-up" reply).
    pub fn warmupProbeMethod() []const u8 {
        return "getnetworkinfo";
    }

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
        .ensure_wallet = vtEnsureWallet,
        .wallet_security_state = vtWalletSecurityState,
        .wallet_balance = vtWalletBalance,
        .wallet_encrypt = vtWalletEncrypt,
        .wallet_unlock = vtWalletUnlock,
        .wallet_lock = vtWalletLock,
        .warmup_probe_method = vtWarmupProbeMethod,
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
    fn vtWarmupProbeMethod(_: *anyopaque) []const u8 {
        return warmupProbeMethod();
    }
};

test "parses getblockchaininfo into normalized BlockchainState" {
    const allocator = std.testing.allocator;

    // Canned daemon reply — proves parse + map without a running digibyted. Note
    // the per-algo `difficulties` object DigiByte uses in place of a scalar
    // `difficulty`; it's ignored at parse time.
    const raw =
        \\{"result":{"chain":"main","blocks":18650123,"headers":18650123,
        \\"bestblockhash":"deadbeef","difficulties":{"scrypt":1234.5},
        \\"mediantime":1700000000,"verificationprogress":0.999998,
        \\"initialblockdownload":false,"size_on_disk":9876543210,"pruned":false},
        \\"error":null,"id":"boxwallet"}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.DgbBlockchainInfo),
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
    };
    defer state.deinit(allocator);

    try std.testing.expectEqualStrings("main", state.chain);
    try std.testing.expectEqual(@as(i64, 18650123), state.blocks);
    try std.testing.expectEqual(@as(i64, 18650123), state.headers);
    try std.testing.expect(state.synced);
}

test "a chain mid-sync reads as not synced" {
    // verificationprogress below the 0.99999 threshold → still catching up.
    const r: models.DgbBlockchainInfo = .{ .blocks = 9_000_000, .headers = 18_650_123, .verificationprogress = 0.482 };
    try std.testing.expect(!(r.verificationprogress > 0.99999));
}

test "combines getblockchaininfo + getnetworkinfo into DaemonInfo (PoW, no getinfo)" {
    const allocator = std.testing.allocator;

    // DigiByte has no `getinfo`: blocks come from getblockchaininfo, peers from
    // getnetworkinfo. Prove each parses on its own, then the merge.
    const bc_raw =
        \\{"result":{"chain":"main","blocks":18650200,"headers":18650200,
        \\"verificationprogress":1.0},"error":null,"id":"boxwallet"}
    ;
    const net_raw =
        \\{"result":{"version":8260200,"subversion":"/DigiByte:8.26.2/",
        \\"protocolversion":70017,"connections":12,"networkactive":true,
        \\"relayfee":0.00001000,"warnings":""},"error":null,"id":"boxwallet"}
    ;

    var bc = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.DgbBlockchainInfo),
        allocator,
        bc_raw,
        .{ .ignore_unknown_fields = true },
    );
    defer bc.deinit();
    var net = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.DgbNetworkInfo),
        allocator,
        net_raw,
        .{ .ignore_unknown_fields = true },
    );
    defer net.deinit();

    const info: models.DaemonInfo = .{
        .blocks = bc.value.result.?.blocks,
        .connections = net.value.result.?.connections,
        .staking_active = false,
    };

    try std.testing.expectEqual(@as(i64, 18650200), info.blocks);
    try std.testing.expectEqual(@as(i64, 12), info.connections);
    // DigiByte is proof-of-work — staking is never active.
    try std.testing.expect(!info.staking_active);
}

test "platform selection resolves a streamable download only on Linux" {
    // DigiByte 8.x ships a usable daemon bundle only for Linux x86_64/aarch64
    // (`.tar.gz`). Windows (NSIS installer) and macOS (GUI-only app) yield no
    // streamable daemon, so the download is null there — as are Linux arm32/386.
    switch (builtin.os.tag) {
        .linux => switch (builtin.cpu.arch) {
            .x86_64, .aarch64 => {
                try std.testing.expect(DigiByte.download != null);
                try std.testing.expectEqual(install_mod.Format.tar_gz, DigiByte.download.?.format);
            },
            else => try std.testing.expect(DigiByte.download == null),
        },
        else => try std.testing.expect(DigiByte.download == null),
    }

    // Binary names still carry `.exe` only on Windows (kept for the few places the
    // name is used even though Windows resolves no download).
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("digibyted.exe", DigiByte.daemon_file);
    } else {
        try std.testing.expectEqualStrings("digibyted", DigiByte.daemon_file);
    }
}

test "coin vtable dispatches to DigiByte metadata" {
    var dgb: DigiByte = .{};
    const c = dgb.coin();
    try std.testing.expectEqualStrings("DigiByte", c.coinName());
    try std.testing.expectEqualStrings("DGB", c.coinNameAbbrev());
    try std.testing.expectEqualStrings("#0066CC", c.coinColor());
    try std.testing.expect(!c.isProofOfStake());
    try std.testing.expectEqualStrings("digibyte.conf", c.confFile());
    try std.testing.expectEqualStrings("digibyted", c.daemonFile());
    try std.testing.expectEqualStrings("14022", c.rpcDefaultPort());
    // Core-26 fork: needs an explicit wallet created/loaded after start.
    try std.testing.expect(c.needsWallet());
    // Bitcoin-core wallet over RPC: the `w` menu and the balance lines are both on.
    try std.testing.expect(c.supportsWallet());
    try std.testing.expect(c.supportsBalance());
}

test "maps getwalletinfo unlocked_until to the wallet security state" {
    // Bitcoin-core style: absent → unencrypted, 0 → locked, positive → unlocked.
    try std.testing.expectEqual(models.WalletSecurity.unencrypted, DigiByte.securityFromUnlockedUntil(null));
    try std.testing.expectEqual(models.WalletSecurity.locked, DigiByte.securityFromUnlockedUntil(0));
    try std.testing.expectEqual(models.WalletSecurity.unlocked, DigiByte.securityFromUnlockedUntil(1893456000));
}

test "maps getwalletinfo balances to available + total" {
    const allocator = std.testing.allocator;

    const raw =
        \\{"result":{"walletversion":169900,"balance":250.0,
        \\"unconfirmed_balance":10.0,"immature_balance":5.0,"unlocked_until":0},
        \\"error":null,"id":"boxwallet"}
    ;
    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.DgbWalletInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    const bal = models.WalletBalance.fromParts(r.balance, r.unconfirmed_balance, r.immature_balance);
    try std.testing.expectApproxEqAbs(@as(f64, 250.0), bal.available, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 265.0), bal.total, 1e-9);
    try std.testing.expect(bal.hasPending());
}
