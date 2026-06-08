const std = @import("std");
const models = @import("../models.zig");
const rpc = @import("../rpc.zig");
const install_mod = @import("../install.zig");
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
    pub const daemon_file_lin = "nexad";
    pub const daemon_file_win = "nexad.exe";
    pub const cli_file_lin = "nexa-cli";
    pub const tx_file_lin = "nexa-tx";

    // Download location (Linux). The tarball wraps everything in `nexa-<ver>/`,
    // with the executables under `nexa-<ver>/bin/`.
    const download_base = "https://bitcoinunlimited.info/nexa/" ++ core_version ++ "/";
    const download_file_linux = "nexa-" ++ core_version ++ "-linux64.tar.gz";
    pub const download_url_linux = download_base ++ download_file_linux;

    // Layout inside the archive. BoxWallet keeps only the daemon/cli/tx binaries
    // (from `bin/`) at the install root and discards the rest of the extracted
    // tree — the GUI/miner/rostrum, `lib/`, `share/`, the bundled `INSTALL.md`.
    // `nexad` links only against system libraries, so dropping `lib/libnexa.so`
    // is safe. Matches the Go installer.
    const extracted_dir = "nexa-" ++ core_version;
    const bin_subdir = "bin";
    const promote_files = [_][]const u8{ daemon_file_lin, cli_file_lin, tx_file_lin };

    // Temp file the download streams to. Keyed off the daemon name so a
    // concurrent install of another coin into the same `~/.boxwallet` root uses
    // a different scratch file and the two never collide.
    pub const scratch_file = ".boxwallet-" ++ daemon_file_lin ++ ".part";

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
        };
    }

    /// True if `nexad` is already present under `install_root`.
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, daemon_file_lin);
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

test "coin vtable dispatches to Nexa metadata" {
    var nexa: Nexa = .{};
    const c = nexa.coin();
    try std.testing.expectEqualStrings("NEXA", c.coinName());
    try std.testing.expectEqualStrings("#FEE043", c.coinColor());
    try std.testing.expect(!c.isProofOfStake());
    try std.testing.expectEqualStrings("nexa.conf", c.confFile());
    try std.testing.expectEqualStrings("7227", c.rpcDefaultPort());
}
