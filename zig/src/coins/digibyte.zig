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
}
