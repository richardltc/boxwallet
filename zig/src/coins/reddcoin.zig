const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const rpc = @import("../rpc.zig");
const install_mod = @import("../install.zig");
const conf = @import("../conf.zig");
const Coin = @import("../coin.zig").Coin;

/// ReddCoin (RDD) backend. Constants seeded from
/// `cmd/cli/cmd/coins/reddcoin/reddcoin.go`, but updated to the current
/// **4.22.9** core (the Go reference's 3.10.3 downloads are gone, and 4.x is a
/// major upgrade: ReddCoin Core rebased onto Bitcoin Core 22).
///
/// ReddCoin is a bitcoin-derived Proof-of-Stake-Velocity coin, so it shares the
/// streaming install path and `key=value` conf with the other forks, with two
/// wrinkles from the Bitcoin-22 rebase:
///
///   * **No `getinfo`** — removed upstream in Bitcoin 0.16. Like DigiByte, the
///     status is assembled from `getblockchaininfo` (chain/height/sync) and
///     `getnetworkinfo` (peer count).
///   * **Staking** — PoSV staking state comes from ReddCoin's own `staking` RPC
///     (called with no args it reports status); its `staking` bool drives the
///     normalized `staking_active`. Best-effort: a wallet that can't answer it
///     just reads as not staking rather than failing the whole poll.
pub const ReddCoin = struct {
    pub const coin_name = "ReddCoin";
    pub const coin_name_abbrev = "RDD";
    /// ReddCoin brand colour (`#RRGGBB`), for tinting the coin in the frontend.
    pub const coin_color = "#ED1C24";
    /// ReddCoin is proof-of-stake (PoSV) — the wallet can stake.
    pub const proof_of_stake = true;
    pub const conf_file = "reddcoin.conf";
    pub const home_dir = ".reddcoin";
    pub const home_dir_win = "REDDCOIN";
    pub const rpc_default_username = "reddcoinrpc";
    pub const rpc_default_port = "45443";
    pub const core_version = "4.22.9";

    // Binary names. Windows appends `.exe`; Linux/macOS use the bare names.
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    pub const daemon_file = "reddcoind" ++ exe_suffix;
    pub const cli_file = "reddcoin-cli" ++ exe_suffix;
    pub const tx_file = "reddcoin-tx" ++ exe_suffix;

    // Download host (ReddCoin's own, not GitHub). Each bundle wraps its
    // executables in `reddcoin-<ver>/bin/`, identically across platforms.
    const download_base = "https://download.reddcoin.com/bin/reddcoin-core-" ++ core_version ++ "/";

    /// The download URL + archive format for the build target, or null where
    /// ReddCoin publishes no matching binary. Selected at comptime from OS/arch:
    ///   - Linux x86_64/aarch64/arm all ship a `.tar.gz`.
    ///   - Windows ships `win64.zip`.
    ///   - ReddCoin ships no native Apple-Silicon build, so both macOS arches use
    ///     the Intel `osx64` build (runs on M1+ under Rosetta 2), mirroring Divi.
    const download: ?install_mod.Download = switch (builtin.os.tag) {
        .windows => .{ .url = download_base ++ "reddcoin-" ++ core_version ++ "-win64.zip", .format = .zip },
        .macos => .{ .url = download_base ++ "reddcoin-" ++ core_version ++ "-osx64.tar.gz", .format = .tar_gz },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => .{ .url = download_base ++ "reddcoin-" ++ core_version ++ "-x86_64-linux-gnu.tar.gz", .format = .tar_gz },
            .aarch64 => .{ .url = download_base ++ "reddcoin-" ++ core_version ++ "-aarch64-linux-gnu.tar.gz", .format = .tar_gz },
            .arm => .{ .url = download_base ++ "reddcoin-" ++ core_version ++ "-arm-linux-gnueabihf.tar.gz", .format = .tar_gz },
            else => null,
        },
        else => null,
    };

    // Layout inside the archive: keep only the daemon/cli/tx binaries (from
    // `bin/`) at the install root; the whole `reddcoin-<ver>/` tree is discarded.
    const extracted_dir = "reddcoin-" ++ core_version;
    const bin_subdir = "bin";
    const promote_files = [_][]const u8{ daemon_file, cli_file, tx_file };

    // Temp file the download streams to (unique to ReddCoin so concurrent installs
    // don't collide on it).
    pub const scratch_file = ".boxwallet-" ++ daemon_file ++ ".part";

    /// Raw `staking` result (subset). Called with no args, ReddCoin's `staking`
    /// RPC reports the current state; `staking` is true while the wallet is
    /// actively minting. Defaults keep the parse resilient.
    const RddStakingInfo = struct {
        enabled: bool = false,
        staking: bool = false,
    };

    /// Build the type-erased `Coin` handle for this instance.
    pub fn coin(self: *ReddCoin) Coin {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Live `getblockchaininfo`, normalized for a frontend. ReddCoin reports
    /// `verificationprogress`, so "synced" is derived from it as for Nexa
    /// (Go's `BlockchainIsSynced` => progress > 0.99999).
    pub fn blockchainState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.BlockchainState {
        var parsed = try rpc.callParsed(models.RddBlockchainInfo, allocator, auth, "getblockchaininfo");
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

    /// Live status, normalized for a frontend. ReddCoin 4.x has no `getinfo`, so
    /// the block height comes from `getblockchaininfo`, the peer count from
    /// `getnetworkinfo`, and staking from the `staking` RPC.
    pub fn daemonInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.DaemonInfo {
        var bc = try rpc.callParsed(models.RddBlockchainInfo, allocator, auth, "getblockchaininfo");
        defer bc.deinit();
        const b = bc.value.result orelse return error.EmptyRpcResult;

        var net = try rpc.callParsed(models.RddNetworkInfo, allocator, auth, "getnetworkinfo");
        defer net.deinit();
        const n = net.value.result orelse return error.EmptyRpcResult;

        // Staking is best-effort: a wallet that can't answer `staking` (locked, no
        // wallet loaded, RPC quirk) reads as "not staking" rather than failing the
        // whole poll and flipping the daemon to "down".
        const staking = blk: {
            var st = rpc.callParsed(RddStakingInfo, allocator, auth, "staking") catch break :blk false;
            defer st.deinit();
            break :blk if (st.value.result) |s| s.staking else false;
        };

        return .{
            .blocks = b.blocks,
            .connections = n.connections,
            .staking_active = staking,
        };
    }

    /// The daemon's default data directory (`~/.reddcoin`), where `reddcoin.conf`
    /// lives.
    pub fn dataDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        return conf.dataDir(allocator, home, home_dir, home_dir_win);
    }

    /// True if `reddcoind` (`reddcoind.exe` on Windows) is already present under
    /// `install_root`.
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, daemon_file);
    }

    /// Download + unarchive the ReddCoin daemon files into `install_root`.
    ///
    /// Extracts the versioned wrapper dir intact, then `promoteAndTidy` lifts the
    /// daemon/cli/tx binaries to the install root and removes the wrapper.
    pub fn install(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        const dl = download orelse return error.UnsupportedPlatform;
        try install_mod.downloadAndExtract(allocator, dl.url, dl.format, install_root, scratch_file, 0, progress);
        try install_mod.promoteAndTidy(allocator, install_root, extracted_dir, bin_subdir, &promote_files);
    }

    /// Ensure `reddcoin.conf` carries the RPC creds (and `server=1`/`daemon=1`/
    /// `rpcport`) BoxWallet needs before the daemon reads it; existing values are
    /// kept. A standard bitcoin-derived `key=value` conf.
    pub fn prepareConf(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        _ = try conf.populate(allocator, io, data_dir, conf_file, rpc_default_username, rpc_default_port);
    }

    /// ReddCoin is a bitcoin-derived daemon: it forks itself into the background
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

    /// Ask reddcoind to shut down via the JSON-RPC `stop`.
    pub fn requestStop(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        const reply = try rpc.call(allocator, auth, "stop");
        allocator.free(reply);
    }

    /// ReddCoin 4.x (Bitcoin Core 22) doesn't auto-create a wallet, so the
    /// `staking` status and any address/balance RPCs have none to act on until one
    /// exists. Load-or-create a wallet named "BoxWallet" once the daemon is up.
    pub fn ensureWallet(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        return rpc.ensureWallet(allocator, auth, "BoxWallet");
    }

    /// ReddCoin dropped `getinfo`, so probe `getnetworkinfo` for the daemon's
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
    fn vtEnsureWallet(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) anyerror!void {
        return ensureWallet(allocator, auth);
    }
    fn vtWarmupProbeMethod(_: *anyopaque) []const u8 {
        return warmupProbeMethod();
    }
};

test "parses getblockchaininfo into normalized BlockchainState" {
    const allocator = std.testing.allocator;

    // Canned daemon reply — proves parse + map without a running reddcoind.
    const raw =
        \\{"result":{"chain":"main","blocks":4567890,"headers":4567890,
        \\"bestblockhash":"deadbeef","difficulty":1234.5,
        \\"verificationprogress":0.999997,"chainwork":"abc"},
        \\"error":null,"id":"boxwallet"}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.RddBlockchainInfo),
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
    try std.testing.expectEqual(@as(i64, 4567890), state.blocks);
    try std.testing.expect(state.synced);
}

test "combines getnetworkinfo + staking into DaemonInfo (no getinfo, PoSV)" {
    const allocator = std.testing.allocator;

    // ReddCoin 4.x has no `getinfo`: peers come from getnetworkinfo and staking
    // from the `staking` RPC. Prove each parses, then the staking decode.
    const net_raw =
        \\{"result":{"version":4220900,"subversion":"/ReddCoin:4.22.9/",
        \\"connections":16,"networkactive":true},"error":null,"id":"boxwallet"}
    ;
    const staking_raw =
        \\{"result":{"enabled":true,"staking":true,"errors":"","weight":12345,
        \\"netstakeweight":67890,"expectedtime":120},"error":null,"id":"boxwallet"}
    ;

    var net = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.RddNetworkInfo),
        allocator,
        net_raw,
        .{ .ignore_unknown_fields = true },
    );
    defer net.deinit();
    var st = try std.json.parseFromSlice(
        models.JsonRpcResponse(ReddCoin.RddStakingInfo),
        allocator,
        staking_raw,
        .{ .ignore_unknown_fields = true },
    );
    defer st.deinit();

    const info: models.DaemonInfo = .{
        .blocks = 4567890,
        .connections = net.value.result.?.connections,
        .staking_active = if (st.value.result) |s| s.staking else false,
    };

    try std.testing.expectEqual(@as(i64, 16), info.connections);
    try std.testing.expect(info.staking_active);
}

test "staking RPC absent or wallet-locked reads as not staking" {
    const allocator = std.testing.allocator;

    // A method-not-found / no-wallet reply parses with result == null → false,
    // rather than failing the poll.
    const raw = "{\"result\":null,\"error\":{\"code\":-32601,\"message\":\"Method not found\"},\"id\":\"boxwallet\"}";
    var st = try std.json.parseFromSlice(
        models.JsonRpcResponse(ReddCoin.RddStakingInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer st.deinit();
    const staking = if (st.value.result) |s| s.staking else false;
    try std.testing.expect(!staking);
}

test "platform selection resolves a download for supported targets" {
    // ReddCoin ships Linux (x86_64/aarch64/arm), Windows, and macOS (osx64)
    // builds, so the current target should resolve a tar.gz (or zip on Windows).
    if (ReddCoin.download) |dl| {
        switch (builtin.os.tag) {
            .windows => try std.testing.expectEqual(install_mod.Format.zip, dl.format),
            else => try std.testing.expectEqual(install_mod.Format.tar_gz, dl.format),
        }
        try std.testing.expect(std.mem.indexOf(u8, dl.url, ReddCoin.core_version) != null);
    }

    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("reddcoind.exe", ReddCoin.daemon_file);
    } else {
        try std.testing.expectEqualStrings("reddcoind", ReddCoin.daemon_file);
    }
}

test "coin vtable dispatches to ReddCoin metadata" {
    var rdd: ReddCoin = .{};
    const c = rdd.coin();
    try std.testing.expectEqualStrings("ReddCoin", c.coinName());
    try std.testing.expectEqualStrings("RDD", c.coinNameAbbrev());
    try std.testing.expectEqualStrings("#ED1C24", c.coinColor());
    try std.testing.expect(c.isProofOfStake());
    try std.testing.expectEqualStrings("reddcoin.conf", c.confFile());
    try std.testing.expectEqualStrings("reddcoind", c.daemonFile());
    try std.testing.expectEqualStrings("45443", c.rpcDefaultPort());
    // Core-22 fork: needs an explicit wallet created/loaded after start.
    try std.testing.expect(c.needsWallet());
}
