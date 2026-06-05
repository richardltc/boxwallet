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
    pub const conf_file = "nexa.conf";
    pub const home_dir = ".nexa";
    pub const home_dir_win = "NEXA";
    pub const rpc_default_username = "nexarpc";
    pub const rpc_default_port = "7227";
    pub const core_version = "2.0.0.0";
    pub const daemon_file_lin = "nexad";
    pub const daemon_file_win = "nexad.exe";

    // Download location (Linux). The tarball unpacks into `nexa-<ver>/`,
    // so install strips one path component.
    const download_base = "https://bitcoinunlimited.info/nexa/" ++ core_version ++ "/";
    const download_file_linux = "nexa-" ++ core_version ++ "-linux64.tar.gz";
    pub const download_url_linux = download_base ++ download_file_linux;

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

    /// Download + unarchive the Nexa daemon files into `install_root`.
    pub fn install(allocator: std.mem.Allocator, install_root: []const u8) !void {
        try install_mod.downloadAndExtract(allocator, download_url_linux, .tar_gz, install_root, 1);
    }

    // --- vtable plumbing -------------------------------------------------

    const vtable: Coin.VTable = .{
        .coin_name = vtCoinName,
        .coin_name_abbrev = vtCoinNameAbbrev,
        .conf_file = vtConfFile,
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
    fn vtConfFile(_: *anyopaque) []const u8 {
        return conf_file;
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
    fn vtInstall(_: *anyopaque, allocator: std.mem.Allocator, install_root: []const u8) anyerror!void {
        return install(allocator, install_root);
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
    try std.testing.expectEqualStrings("nexa.conf", c.confFile());
    try std.testing.expectEqualStrings("7227", c.rpcDefaultPort());
}
