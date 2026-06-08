const std = @import("std");
const models = @import("../models.zig");
const rpc = @import("../rpc.zig");
const install_mod = @import("../install.zig");
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
    /// Go's `BlockchainIsSynced` reads `mnsync status`'s `IsBlockchainSynced`,
    /// but the same file keeps a commented-out `verificationprogress > 0.99999`
    /// fallback. We use that single-call form here (as Nexa does) so every coin
    /// maps to the shared `BlockchainState` the same way; the masternode-sync
    /// signal can be layered on later if needed.
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
            .synced = r.verificationprogress > 0.99999,
        };
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

test "parses getblockchaininfo into normalized BlockchainState" {
    const allocator = std.testing.allocator;

    // Canned daemon reply — proves parse + map without a running divid.
    const raw =
        \\{"result":{"chain":"main","blocks":2345678,"headers":2345678,
        \\"bestblockhash":"cafebabe","difficulty":98765.4321,
        \\"verificationprogress":0.9999995,
        \\"chainwork":"00000000000000000000000000000000000000000000abcdef0123456789abcd"},
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
        .synced = r.verificationprogress > 0.99999,
    };
    defer state.deinit(allocator);

    try std.testing.expectEqualStrings("main", state.chain);
    try std.testing.expectEqual(@as(i64, 2345678), state.blocks);
    try std.testing.expect(state.synced);
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
