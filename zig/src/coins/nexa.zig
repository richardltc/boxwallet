const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const rpc = @import("../rpc.zig");
const install_mod = @import("../install.zig");
const conf = @import("../conf.zig");
const Coin = @import("../coin.zig").Coin;

/// Nexa backend. Constants lifted from
/// `cmd/cli/cmd/coins/nexa/nexa.go`.
pub const Nexa = struct {
    pub const coin_name = "NEXA";
    pub const coin_name_abbrev = "NEXA";
    /// Nexa brand colour (`#RRGGBB`), for tinting the coin in the frontend.
    pub const coin_color = "#FEE043";
    /// Nexa is proof-of-work — no wallet staking.
    pub const proof_of_stake = false;
    pub const conf_file = "nexa.conf";
    pub const home_dir = ".nexa";
    pub const home_dir_win = "NEXA";
    pub const rpc_default_username = "nexarpc";
    pub const rpc_default_port = "7227";
    pub const core_version = "2.0.0.0";

    // Binary names. Windows appends `.exe`; Linux/macOS use the bare names. The
    // per-target name is what `isInstalled`, the daemon launcher, and the promote
    // list all use, so a Windows build looks for `nexad.exe` and a POSIX build for
    // `nexad`.
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    pub const daemon_file = "nexad" ++ exe_suffix;
    pub const cli_file = "nexa-cli" ++ exe_suffix;
    pub const tx_file = "nexa-tx" ++ exe_suffix;

    // Download host. Every bundle wraps its executables in `nexa-<ver>/bin/`,
    // identically across platforms (Linux/macOS tar.gz, Windows zip).
    const download_base = "https://bitcoinunlimited.info/nexa/" ++ core_version ++ "/";

    /// The download URL + archive format for the build target, or null where Nexa
    /// publishes no matching binary. Selected at comptime from the OS/arch so a
    /// build only ever references its own platform's artifact. Mirrors the Go
    /// installer's `runtime.GOOS`/`GOARCH` switch, plus the macOS builds the Go
    /// app never wired (arm64 for Apple Silicon, x86 for Intel).
    const download: ?install_mod.Download = switch (builtin.os.tag) {
        .windows => .{ .url = download_base ++ "nexa-" ++ core_version ++ "-win64.zip", .format = .zip },
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => .{ .url = download_base ++ "nexa-" ++ core_version ++ "-macos-arm64-unsigned.tar.gz", .format = .tar_gz },
            .x86_64 => .{ .url = download_base ++ "nexa-" ++ core_version ++ "-macos-x86-unsigned.tar.gz", .format = .tar_gz },
            else => null,
        },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => .{ .url = download_base ++ "nexa-" ++ core_version ++ "-linux64.tar.gz", .format = .tar_gz },
            .aarch64 => .{ .url = download_base ++ "nexa-" ++ core_version ++ "-arm64.tar.gz", .format = .tar_gz },
            .arm => .{ .url = download_base ++ "nexa-" ++ core_version ++ "-arm32.tar.gz", .format = .tar_gz },
            else => null,
        },
        else => null,
    };

    // Layout inside the archive. BoxWallet keeps only the daemon/cli/tx binaries
    // (from `bin/`) at the install root and discards the rest of the extracted
    // tree — the GUI/miner/rostrum, `lib/`, `share/`, the bundled `INSTALL.md`.
    // `nexad` links only against system libraries, so dropping `lib/libnexa.so`
    // is safe. Matches the Go installer.
    const extracted_dir = "nexa-" ++ core_version;
    const bin_subdir = "bin";
    const promote_files = [_][]const u8{ daemon_file, cli_file, tx_file };

    // Temp file the download streams to. Keyed off the daemon name so a
    // concurrent install of another coin into the same `~/.boxwallet` root uses
    // a different scratch file and the two never collide.
    pub const scratch_file = ".boxwallet-" ++ daemon_file ++ ".part";

    /// Build the type-erased `Coin` handle for this instance.
    pub fn coin(self: *Nexa) Coin {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Live `getblockchaininfo`, normalized for a frontend.
    /// `BlockchainIsSynced` in Go is the `synced` field here.
    pub fn blockchainState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.BlockchainState {
        var parsed = try rpc.callParsed(models.NexaBlockchainInfo, allocator, auth, "getblockchaininfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return .{
            .chain = try allocator.dupe(u8, r.chain),
            .blocks = r.blocks,
            .headers = r.headers,
            .verification_progress = r.verificationprogress,
            // Matches Go: BlockchainIsSynced => verificationprogress > 0.99999
            .synced = r.verificationprogress > 0.99999,
            // Network tip from peers, so the frontend's Headers bar can fill
            // toward it. A getpeerinfo hiccup just leaves it 0 (unknown).
            .network_height = rpc.networkHeight(allocator, auth) catch 0,
        };
    }

    /// Live `getinfo`, normalized for a frontend. Nexa is proof-of-work, so
    /// `staking_active` is always false.
    pub fn daemonInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.DaemonInfo {
        var parsed = try rpc.callParsed(models.NexaGetInfo, allocator, auth, "getinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return .{
            .blocks = r.blocks,
            .connections = r.connections,
            .staking_active = false,
        };
    }

    /// The daemon's default data directory (`~/.nexa`), where `nexa.conf` lives.
    pub fn dataDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        return conf.dataDir(allocator, home, home_dir, home_dir_win);
    }

    /// True if `nexad` (`nexad.exe` on Windows) is already present under
    /// `install_root`.
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, daemon_file);
    }

    /// Download + unarchive the Nexa daemon files into `install_root`,
    /// optionally reporting download/extract progress.
    ///
    /// Extracts the versioned wrapper dir intact, then `promoteAndTidy` lifts the
    /// daemon/cli/tx binaries to the install root and removes the wrapper,
    /// leaving `nexad` exactly where `isInstalled` looks for it.
    pub fn install(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        const dl = download orelse return error.UnsupportedPlatform;
        try install_mod.downloadAndExtract(allocator, dl.url, dl.format, install_root, scratch_file, 0, progress);
        try install_mod.promoteAndTidy(allocator, install_root, extracted_dir, bin_subdir, &promote_files);
    }

    /// Ensure `nexa.conf` carries the RPC creds (and `server=1`/`daemon=1`/
    /// `rpcport`) BoxWallet needs before the daemon reads it; existing values are
    /// kept. A standard bitcoin-derived `key=value` conf.
    pub fn prepareConf(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        _ = try conf.populate(allocator, io, data_dir, conf_file, rpc_default_username, rpc_default_port);
    }

    /// Nexa is a bitcoin-derived daemon: it forks itself into the background with
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

    /// Ask nexad to shut down via the JSON-RPC `stop`.
    pub fn requestStop(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        const reply = try rpc.call(allocator, auth, "stop");
        allocator.free(reply);
    }

    // --- vtable plumbing -------------------------------------------------

    const vtable: Coin.VTable = .{
        .coin_name = vtCoinName,
        .coin_name_abbrev = vtCoinNameAbbrev,
        .coin_color = vtCoinColor,
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

test "parses getblockchaininfo into normalized BlockchainState" {
    const allocator = std.testing.allocator;

    // Canned daemon reply — proves parse + map without a running nexad.
    const raw =
        \\{"result":{"chain":"nexa","blocks":1234567,"headers":1234567,
        \\"bestblockhash":"deadbeef","difficulty":12345.678,
        \\"verificationprogress":0.999995,"initialblockdownload":false,
        \\"size_on_disk":987654321,"pruned":false,
        \\"softforks":[],"bip9_softforks":{},"bip135_forks":{}},
        \\"error":null,"id":"boxwallet"}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.NexaBlockchainInfo),
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

    try std.testing.expectEqualStrings("nexa", state.chain);
    try std.testing.expectEqual(@as(i64, 1234567), state.blocks);
    try std.testing.expect(state.synced);
}

test "parses getinfo with a numeric version field" {
    const allocator = std.testing.allocator;

    // nexad reports `version` as a number (e.g. 2000000), not a string — the
    // struct must type it that way or the whole poll fails to parse and the
    // daemon reads as "not running" even though it's up.
    const raw =
        \\{"result":{"version":2000000,"protocolversion":80006,
        \\"walletversion":130000,"balance":0.00,"blocks":180763,
        \\"connections":2,"difficulty":42315.13684998719,"testnet":false},
        \\"error":null,"id":"boxwallet"}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.NexaGetInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    try std.testing.expectEqual(@as(i64, 2000000), r.version);
    try std.testing.expectEqual(@as(i64, 2), r.connections);
}

test "platform selection resolves a download for the build target" {
    // Nexa publishes binaries for every OS/arch BoxWallet builds for, so the
    // current target must always resolve a download (and to the right format).
    const dl = Nexa.download orelse return error.SkipZigTest;
    switch (builtin.os.tag) {
        .windows => try std.testing.expectEqual(install_mod.Format.zip, dl.format),
        else => try std.testing.expectEqual(install_mod.Format.tar_gz, dl.format),
    }

    // Binary names carry `.exe` only on Windows.
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("nexad.exe", Nexa.daemon_file);
    } else {
        try std.testing.expectEqualStrings("nexad", Nexa.daemon_file);
    }
}

test "coin vtable dispatches to Nexa metadata" {
    var nexa: Nexa = .{};
    const c = nexa.coin();
    try std.testing.expectEqualStrings("NEXA", c.coinName());
    try std.testing.expectEqualStrings("#FEE043", c.coinColor());
    try std.testing.expect(!c.isProofOfStake());
    try std.testing.expectEqualStrings("nexa.conf", c.confFile());
    try std.testing.expectEqualStrings("7227", c.rpcDefaultPort());
}
