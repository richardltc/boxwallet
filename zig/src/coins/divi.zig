const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const rpc = @import("../rpc.zig");
const install_mod = @import("../install.zig");
const conf = @import("../conf.zig");
const Coin = @import("../coin.zig").Coin;

/// Divi backend. Constants lifted from
/// `cmd/cli/cmd/coins/divi/divi.go`.
pub const Divi = struct {
    pub const coin_name = "Divi";
    pub const coin_name_abbrev = "DIVI";
    /// Divi brand colour (`#RRGGBB`), for tinting the coin in the frontend.
    pub const coin_color = "#ED295A";
    /// Divi is proof-of-stake — the wallet can stake.
    pub const proof_of_stake = true;
    pub const conf_file = "divi.conf";
    pub const home_dir = ".divi";
    pub const home_dir_win = "DIVI";
    pub const rpc_default_username = "divirpc";
    pub const rpc_default_port = "51473";
    pub const core_version = "3.0.0";

    // Binary names. Windows appends `.exe`; Linux/macOS use the bare names. The
    // per-target name is what `isInstalled`, the daemon launcher, and the promote
    // list all use.
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    pub const daemon_file = "divid" ++ exe_suffix;
    pub const cli_file = "divi-cli" ++ exe_suffix;
    pub const tx_file = "divi-tx" ++ exe_suffix;

    // Download host. Divi ships GitHub release archives whose filename carries an
    // arch/commit suffix, but each still wraps everything in the plain
    // `divi-<ver>/` dir with binaries under `bin/` — same shape on every platform.
    const download_base = "https://github.com/DiviProject/Divi/releases/download/v" ++ core_version ++ "/";

    /// The download URL + archive format for the build target, or null where Divi
    /// publishes no matching binary. Selected at comptime from OS/arch, mirroring
    /// the Go installer's `runtime.GOOS`/`GOARCH` switch:
    ///   - Linux arm64 and Linux 386 are unsupported upstream (null).
    ///   - Divi ships no native Apple-Silicon build, so both macOS arches use the
    ///     Intel `osx64` build — which runs on M1+ under Rosetta 2.
    const download: ?install_mod.Download = switch (builtin.os.tag) {
        .windows => .{ .url = download_base ++ "divi-" ++ core_version ++ "-win64-9e2f76c.zip", .format = .zip },
        .macos => .{ .url = download_base ++ "divi-" ++ core_version ++ "-osx64-9e2f76c.tar.gz", .format = .tar_gz },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => .{ .url = download_base ++ "divi-" ++ core_version ++ "-x86_64-linux-gnu-9e2f76c.tar.gz", .format = .tar_gz },
            .arm => .{ .url = download_base ++ "divi-" ++ core_version ++ "-RPi2-9e2f76c.tar.gz", .format = .tar_gz },
            else => null,
        },
        else => null,
    };

    // Layout inside the archive: keep only the daemon/cli/tx binaries (from
    // `bin/`) at the install root; the whole `divi-<ver>/` tree is discarded
    // afterwards. Matches the Go installer.
    const extracted_dir = "divi-" ++ core_version;
    const bin_subdir = "bin";
    const promote_files = [_][]const u8{ daemon_file, cli_file, tx_file };

    // Temp file the download streams to. Keyed off the daemon name so a
    // concurrent install of another coin into the same `~/.boxwallet` root uses
    // a different scratch file and the two never collide.
    pub const scratch_file = ".boxwallet-" ++ daemon_file ++ ".part";

    /// Build the type-erased `Coin` handle for this instance.
    pub fn coin(self: *Divi) Coin {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Live `getblockchaininfo`, normalized for a frontend.
    ///
    /// Unlike Nexa's daemon, Divi's `getblockchaininfo` does **not** report
    /// `verificationprogress` (the field is absent, so it parses as 0). Go's
    /// `BlockchainIsSynced` reads the masternode `mnsync status` instead, with a
    /// commented-out progress fallback. Rather than take that single extra-field
    /// path, we derive "synced" from the heights the call does return: the chain
    /// is caught up once validated `blocks` have reached the header tip
    /// (`blocks >= headers`, with at least one header seen). The header-vs-block
    /// counts also drive the sync progress bars.
    pub fn blockchainState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.BlockchainState {
        var parsed = try rpc.callParsed(models.DiviBlockchainInfo, allocator, auth, "getblockchaininfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return .{
            .chain = try allocator.dupe(u8, r.chain),
            .blocks = r.blocks,
            .headers = r.headers,
            .verification_progress = r.verificationprogress,
            .synced = r.headers > 0 and r.blocks >= r.headers,
            // Network tip from peers, so the frontend's Headers bar can fill
            // toward it. A getpeerinfo hiccup just leaves it 0 (unknown).
            .network_height = rpc.networkHeight(allocator, auth) catch 0,
            // Tip block timestamp, so the frontend can show how far behind in
            // wall-clock time the chain is while validating. Prefer the exact
            // tip `time`; fall back to `mediantime` when the daemon omits it.
            .tip_time = if (r.time > 0) r.time else r.mediantime,
        };
    }

    /// Live `getinfo`, normalized for a frontend. Divi exposes staking through a
    /// `"staking status"` string; we map the daemon's "Staking Active" to a bool
    /// so the frontend never sees the per-coin wording.
    pub fn daemonInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.DaemonInfo {
        var parsed = try rpc.callParsed(models.DiviGetInfo, allocator, auth, "getinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return .{
            .blocks = r.blocks,
            .connections = r.connections,
            .staking_active = std.mem.eql(u8, r.@"staking status", "Staking Active"),
        };
    }

    /// The daemon's default data directory (`~/.divi`), where `divi.conf` lives.
    pub fn dataDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        return conf.dataDir(allocator, home, home_dir, home_dir_win);
    }

    /// True if `divid` (`divid.exe` on Windows) is already present under
    /// `install_root`.
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, daemon_file);
    }

    /// Download + unarchive the Divi daemon files into `install_root`,
    /// optionally reporting download/extract progress.
    ///
    /// Extracts the versioned wrapper dir intact, then `promoteAndTidy` lifts the
    /// daemon/cli/tx binaries to the install root and removes the wrapper,
    /// leaving `divid` exactly where `isInstalled` looks for it.
    pub fn install(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        const dl = download orelse return error.UnsupportedPlatform;
        try install_mod.downloadAndExtract(allocator, dl.url, dl.format, install_root, scratch_file, 0, progress);
        try install_mod.promoteAndTidy(allocator, install_root, extracted_dir, bin_subdir, &promote_files);
    }

    /// Ensure `divi.conf` carries the RPC creds (and `server=1`/`daemon=1`/
    /// `rpcport`) BoxWallet needs before the daemon reads it; existing values are
    /// kept. A standard bitcoin-derived `key=value` conf.
    pub fn prepareConf(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        _ = try conf.populate(allocator, io, data_dir, conf_file, rpc_default_username, rpc_default_port);
    }

    /// Divi is a bitcoin-derived daemon: it forks itself into the background with
    /// `-daemon` on POSIX, but runs in the foreground on Windows.
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

    /// Ask divid to shut down via the JSON-RPC `stop`.
    pub fn requestStop(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        const reply = try rpc.call(allocator, auth, "stop");
        allocator.free(reply);
    }

    /// Read the wallet's security state from `getwalletinfo`. Divi (PIVX-derived)
    /// reports a human-readable `encryption_status` string rather than a numeric
    /// `unlocked_until`. Mirrors Go's `WalletSecurityState`.
    pub fn walletSecurityState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.WalletSecurity {
        var parsed = try rpc.callParsed(models.DiviWalletInfo, allocator, auth, "getwalletinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return securityFromStatus(r.encryption_status);
    }

    /// Read the wallet's balances from `getwalletinfo`. `available` is the
    /// confirmed spendable `balance`; `total` adds the mempool
    /// (`unconfirmed_balance`) and maturing (`immature_balance`) funds, so it
    /// reflects incoming money the moment it's seen. Same `getwalletinfo` shape as
    /// `walletSecurityState`.
    pub fn walletBalance(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.WalletBalance {
        var parsed = try rpc.callParsed(models.DiviWalletInfo, allocator, auth, "getwalletinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return models.WalletBalance.fromParts(r.balance, r.unconfirmed_balance, r.immature_balance);
    }

    /// Map Divi's `encryption_status` string to the normalized `WalletSecurity`.
    /// Shared by the parse path and its unit test. An unrecognized value reads as
    /// `unknown`.
    fn securityFromStatus(status: []const u8) models.WalletSecurity {
        if (std.mem.eql(u8, status, "unencrypted")) return .unencrypted;
        if (std.mem.eql(u8, status, "locked")) return .locked;
        if (std.mem.eql(u8, status, "unlocked")) return .unlocked;
        if (std.mem.eql(u8, status, "unlocked-for-staking")) return .unlocked_for_staking;
        return .unknown;
    }

    /// Encrypt the wallet with `passphrase`. divid stops itself afterwards (the
    /// caller restarts it). The passphrase is JSON-escaped before splicing.
    pub fn walletEncrypt(allocator: std.mem.Allocator, auth: models.CoinAuth, passphrase: []const u8) !void {
        const pw = try rpc.jsonQuote(allocator, passphrase);
        defer allocator.free(pw);
        const params = try std.fmt.allocPrint(allocator, "[{s}]", .{pw});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "encryptwallet", params);
    }

    /// Unlock the wallet via `walletpassphrase`. A plain unlock uses an indefinite
    /// timeout (0, matching Go's `WalletUnlock`); `staking` requests an
    /// unlock-for-staking with the long timeout + `true` flag (Go's
    /// `WalletUnlockFS`).
    pub fn walletUnlock(allocator: std.mem.Allocator, auth: models.CoinAuth, passphrase: []const u8, staking: bool) !void {
        const pw = try rpc.jsonQuote(allocator, passphrase);
        defer allocator.free(pw);
        const params = if (staking)
            try std.fmt.allocPrint(allocator, "[{s},9999999,true]", .{pw})
        else
            try std.fmt.allocPrint(allocator, "[{s},0]", .{pw});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "walletpassphrase", params);
    }

    /// Re-lock the wallet via `walletlock`.
    pub fn walletLock(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        return rpc.callExpectOk(allocator, auth, "walletlock", "[]");
    }

    /// Divi retains `getinfo`, so probe it for the daemon's warm-up phase.
    pub fn warmupProbeMethod() []const u8 {
        return "getinfo";
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

test "maps getblockchaininfo into BlockchainState, syncing on blocks vs headers" {
    const allocator = std.testing.allocator;

    // Canned reply mirroring a live divid getblockchaininfo — note there is no
    // `verificationprogress` field (Divi's daemon omits it). blocks == headers
    // here, so the chain reads as synced.
    const raw =
        \\{"result":{"chain":"main","blocks":4071165,"headers":4071165,
        \\"bestblockhash":"322d04e1197d59ed4f47583f4accda109c4f7e32b38871c30b812d571355f171",
        \\"difficulty":43135.79559493,
        \\"chainwork":"000000000000000000000000000000000000000000000017f092768cd23927cb"},
        \\"error":null,"id":"boxwallet"}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.DiviBlockchainInfo),
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
        .synced = r.headers > 0 and r.blocks >= r.headers,
    };
    defer state.deinit(allocator);

    try std.testing.expectEqualStrings("main", state.chain);
    try std.testing.expectEqual(@as(i64, 4071165), state.blocks);
    try std.testing.expectEqual(@as(i64, 4071165), state.headers);
    // No verificationprogress in the reply → parses as 0, but synced is derived
    // from the heights (blocks have caught up to the header tip).
    try std.testing.expectEqual(@as(f64, 0), state.verification_progress);
    try std.testing.expect(state.synced);
}

test "blocks behind the header tip read as not synced" {
    // Mid-sync: headers race ahead of validated blocks.
    const r: models.DiviBlockchainInfo = .{ .blocks = 2_000_000, .headers = 4_071_165 };
    try std.testing.expect(!(r.headers > 0 and r.blocks >= r.headers));
}

test "maps getinfo into normalized DaemonInfo, decoding staking status" {
    const allocator = std.testing.allocator;

    // Canned reply mirroring a live divid getinfo — note the `"staking status"`
    // field carries a literal space and the human-readable "Staking Active".
    const raw =
        \\{"result":{"version":"3.0.0.0","protocolversion":70915,
        \\"walletversion":120200,"balance":3139364.85688449,"blocks":4071089,
        \\"timeoffset":0,"connections":29,"proxy":"","difficulty":54392.69715429,
        \\"testnet":false,"moneysupply":4678085823.73950005,"relayfee":0.00010000,
        \\"staking status":"Staking Active","errors":""},
        \\"error":null,"id":"boxwallet"}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.DiviGetInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    const info: models.DaemonInfo = .{
        .blocks = r.blocks,
        .connections = r.connections,
        .staking_active = std.mem.eql(u8, r.@"staking status", "Staking Active"),
    };

    try std.testing.expectEqual(@as(i64, 4071089), info.blocks);
    try std.testing.expectEqual(@as(i64, 29), info.connections);
    try std.testing.expect(info.staking_active);
}

test "getinfo without active staking maps staking_active false" {
    const allocator = std.testing.allocator;

    const raw =
        \\{"result":{"blocks":4071089,"connections":8,
        \\"staking status":"Staking Not Active"},"error":null,"id":"boxwallet"}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.DiviGetInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    try std.testing.expect(!std.mem.eql(u8, r.@"staking status", "Staking Active"));
    try std.testing.expectEqual(@as(i64, 8), r.connections);
}

test "platform selection resolves a download for supported targets" {
    // Divi has no native Linux-arm64 build, so the download is allowed to be null
    // there; when present, the format must match the OS (zip on Windows, else
    // tar.gz — including the Intel osx64 build used for both macOS arches).
    if (Divi.download) |dl| {
        switch (builtin.os.tag) {
            .windows => try std.testing.expectEqual(install_mod.Format.zip, dl.format),
            else => try std.testing.expectEqual(install_mod.Format.tar_gz, dl.format),
        }
    }

    // Binary names carry `.exe` only on Windows.
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("divid.exe", Divi.daemon_file);
    } else {
        try std.testing.expectEqualStrings("divid", Divi.daemon_file);
    }
}

test "coin vtable dispatches to Divi metadata" {
    var divi: Divi = .{};
    const c = divi.coin();
    try std.testing.expectEqualStrings("Divi", c.coinName());
    try std.testing.expectEqualStrings("#ED295A", c.coinColor());
    try std.testing.expect(c.isProofOfStake());
    try std.testing.expectEqualStrings("divi.conf", c.confFile());
    try std.testing.expectEqualStrings("divid", c.daemonFile());
    try std.testing.expectEqualStrings("51473", c.rpcDefaultPort());
    // Divi's wallet is manageable over RPC — the `w` menu is available.
    try std.testing.expect(c.supportsWallet());
    // And it reports a balance, so the Total/Available lines light up.
    try std.testing.expect(c.supportsBalance());
}

test "maps getwalletinfo balances to available + total" {
    const allocator = std.testing.allocator;

    // 100 confirmed, 5 in the mempool: total moves to 105 immediately, available
    // stays 100 until the mempool funds confirm.
    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.DiviWalletInfo),
        allocator,
        "{\"result\":{\"encryption_status\":\"unlocked\",\"balance\":100.0,\"unconfirmed_balance\":5.0},\"error\":null,\"id\":\"boxwallet\"}",
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    const bal = models.WalletBalance.fromParts(r.balance, r.unconfirmed_balance, r.immature_balance);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), bal.available, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 105.0), bal.total, 1e-9);
    try std.testing.expect(bal.hasPending());
}

test "maps getwalletinfo encryption_status to the wallet security state" {
    // Divi reports the state as a string; each of the four values maps to its
    // normalized state, and anything unexpected reads as unknown.
    try std.testing.expectEqual(models.WalletSecurity.unencrypted, Divi.securityFromStatus("unencrypted"));
    try std.testing.expectEqual(models.WalletSecurity.locked, Divi.securityFromStatus("locked"));
    try std.testing.expectEqual(models.WalletSecurity.unlocked, Divi.securityFromStatus("unlocked"));
    try std.testing.expectEqual(models.WalletSecurity.unlocked_for_staking, Divi.securityFromStatus("unlocked-for-staking"));
    try std.testing.expectEqual(models.WalletSecurity.unknown, Divi.securityFromStatus("something-else"));

    // The field parses out of a representative getwalletinfo reply.
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.DiviWalletInfo),
        allocator,
        "{\"result\":{\"walletversion\":120200,\"encryption_status\":\"locked\"},\"error\":null,\"id\":\"boxwallet\"}",
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqual(models.WalletSecurity.locked, Divi.securityFromStatus(parsed.value.result.?.encryption_status));
}
