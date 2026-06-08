const std = @import("std");
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
    pub const daemon_file_lin = "divid";
    pub const daemon_file_win = "divid.exe";
    pub const cli_file_lin = "divi-cli";
    pub const tx_file_lin = "divi-tx";

    // Download location (Linux). Divi ships GitHub release tarballs whose
    // filename carries an arch/commit suffix, but the archive still wraps
    // everything in the plain `divi-<ver>/` dir with binaries under `bin/`.
    const download_base = "https://github.com/DiviProject/Divi/releases/download/v" ++ core_version ++ "/";
    const download_file_linux = "divi-" ++ core_version ++ "-x86_64-linux-gnu-9e2f76c.tar.gz";
    pub const download_url_linux = download_base ++ download_file_linux;

    // Layout inside the archive: keep only the daemon/cli/tx binaries (from
    // `bin/`) at the install root; the whole `divi-<ver>/` tree is discarded
    // afterwards. Matches the Go installer.
    const extracted_dir = "divi-" ++ core_version;
    const bin_subdir = "bin";
    const promote_files = [_][]const u8{ daemon_file_lin, cli_file_lin, tx_file_lin };

    // Temp file the download streams to. Keyed off the daemon name so a
    // concurrent install of another coin into the same `~/.boxwallet` root uses
    // a different scratch file and the two never collide.
    pub const scratch_file = ".boxwallet-" ++ daemon_file_lin ++ ".part";

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

    /// True if `divid` is already present under `install_root`.
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, daemon_file_lin);
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
        try install_mod.downloadAndExtract(allocator, download_url_linux, .tar_gz, install_root, scratch_file, 0, progress);
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
        return daemon_file_lin;
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
