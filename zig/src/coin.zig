const std = @import("std");
const models = @import("models.zig");
const install_mod = @import("install.zig");

/// Runtime-polymorphic handle to a coin backend — the Zig equivalent of the
/// Go `Coin` interface in `coins.go`. A frontend (the ZigZag TUI) holds a
/// `Coin` and drives any of the ~30 coins through it without knowing which
/// concrete type backs it.
///
/// Each concrete coin exposes a `coin()` method returning one of these,
/// pairing a type-erased `*Self` pointer with a static vtable.
pub const Coin = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        coin_name: *const fn (ptr: *anyopaque) []const u8,
        coin_name_abbrev: *const fn (ptr: *anyopaque) []const u8,
        /// The coin's brand colour as a `#RRGGBB` hex string, for the frontend.
        coin_color: *const fn (ptr: *anyopaque) []const u8,
        /// True for proof-of-stake coins (which expose a staking status); false
        /// for proof-of-work coins.
        proof_of_stake: *const fn (ptr: *anyopaque) bool,
        conf_file: *const fn (ptr: *anyopaque) []const u8,
        /// Daemon binary filename for the host OS (e.g. `nexad`, `divid`).
        daemon_file: *const fn (ptr: *anyopaque) []const u8,
        rpc_default_port: *const fn (ptr: *anyopaque) []const u8,
        rpc_default_username: *const fn (ptr: *anyopaque) []const u8,
        /// Live call: returns normalized chain state. Returned value owns its
        /// `chain` string and must be `deinit`-ed by the caller.
        blockchain_state: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
        ) anyerror!models.BlockchainState,
        /// Live call: returns a normalized `getinfo` snapshot (peer count, block
        /// height, staking). Scalar-only — no cleanup needed.
        daemon_info: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
        ) anyerror!models.DaemonInfo,
        /// Resolve the coin daemon's default data directory (where its `.conf`
        /// lives) under the process `home_dir`. Caller owns the returned slice.
        data_dir: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            home_dir: []const u8,
        ) anyerror![]const u8,
        /// True if the daemon binary is present under `install_root`.
        is_installed: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            install_root: []const u8,
        ) bool,
        /// Download + unarchive the daemon files into `install_root`,
        /// optionally reporting download/extract progress.
        install: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            install_root: []const u8,
            progress: ?install_mod.Progress,
        ) anyerror!void,
    };

    pub fn coinName(self: Coin) []const u8 {
        return self.vtable.coin_name(self.ptr);
    }
    pub fn coinNameAbbrev(self: Coin) []const u8 {
        return self.vtable.coin_name_abbrev(self.ptr);
    }
    /// The coin's brand colour as a `#RRGGBB` hex string.
    pub fn coinColor(self: Coin) []const u8 {
        return self.vtable.coin_color(self.ptr);
    }
    /// True for proof-of-stake coins (which expose a staking status).
    pub fn isProofOfStake(self: Coin) bool {
        return self.vtable.proof_of_stake(self.ptr);
    }
    pub fn confFile(self: Coin) []const u8 {
        return self.vtable.conf_file(self.ptr);
    }
    pub fn daemonFile(self: Coin) []const u8 {
        return self.vtable.daemon_file(self.ptr);
    }
    pub fn rpcDefaultPort(self: Coin) []const u8 {
        return self.vtable.rpc_default_port(self.ptr);
    }
    pub fn rpcDefaultUsername(self: Coin) []const u8 {
        return self.vtable.rpc_default_username(self.ptr);
    }
    pub fn blockchainState(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.BlockchainState {
        return self.vtable.blockchain_state(self.ptr, allocator, auth);
    }
    pub fn daemonInfo(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.DaemonInfo {
        return self.vtable.daemon_info(self.ptr, allocator, auth);
    }
    pub fn dataDir(
        self: Coin,
        allocator: std.mem.Allocator,
        home_dir: []const u8,
    ) ![]const u8 {
        return self.vtable.data_dir(self.ptr, allocator, home_dir);
    }
    pub fn isInstalled(self: Coin, allocator: std.mem.Allocator, install_root: []const u8) bool {
        return self.vtable.is_installed(self.ptr, allocator, install_root);
    }
    pub fn install(
        self: Coin,
        allocator: std.mem.Allocator,
        install_root: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        return self.vtable.install(self.ptr, allocator, install_root, progress);
    }
};
