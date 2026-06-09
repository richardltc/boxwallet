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
    pub const coin_name = "DIVI";
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
    try std.testing.expectEqualStrings("DIVI", c.coinName());
    try std.testing.expectEqualStrings("#ED295A", c.coinColor());
    try std.testing.expect(c.isProofOfStake());
    try std.testing.expectEqualStrings("divi.conf", c.confFile());
    try std.testing.expectEqualStrings("divid", c.daemonFile());
    try std.testing.expectEqualStrings("51473", c.rpcDefaultPort());
}
