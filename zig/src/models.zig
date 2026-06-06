const std = @import("std");

/// RPC connection details for a running coin daemon.
/// Mirrors `models.CoinAuth` from the Go source.
pub const CoinAuth = struct {
    rpc_user: []const u8,
    rpc_password: []const u8,
    ip_address: []const u8,
    port: []const u8,
};

/// JSON-RPC response envelope. Daemons reply with
/// `{ "result": <T>, "error": ..., "id": ... }`.
/// `error` and `id` are dropped via `ignore_unknown_fields` at parse time.
pub fn JsonRpcResponse(comptime T: type) type {
    return struct {
        result: ?T = null,
    };
}

/// Raw `getblockchaininfo` result for Nexa — the subset BoxWallet uses.
/// Defaults make parsing resilient to fields the daemon omits.
pub const NexaBlockchainInfo = struct {
    chain: []const u8 = "",
    blocks: i64 = 0,
    headers: i64 = 0,
    bestblockhash: []const u8 = "",
    difficulty: f64 = 0,
    verificationprogress: f64 = 0,
    initialblockdownload: bool = false,
    size_on_disk: i64 = 0,
    pruned: bool = false,
};

/// Raw `getinfo` result for Nexa (subset).
pub const NexaGetInfo = struct {
    version: []const u8 = "",
    blocks: i64 = 0,
    connections: i64 = 0,
    difficulty: f64 = 0,
    balance: f64 = 0,
};

/// Raw `getblockchaininfo` result for Divi (subset). Same standard fields as
/// other bitcoin-derived daemons, with `chainwork` in place of Nexa's
/// pruning/IBD fields. Defaults keep parsing resilient to omitted fields.
pub const DiviBlockchainInfo = struct {
    chain: []const u8 = "",
    blocks: i64 = 0,
    headers: i64 = 0,
    bestblockhash: []const u8 = "",
    difficulty: f64 = 0,
    verificationprogress: f64 = 0,
    chainwork: []const u8 = "",
};

/// Coin-agnostic view of chain sync state. This is what a frontend (the
/// ZigZag TUI) renders — it never touches per-coin JSON shapes.
///
/// Owns its `chain` string; call `deinit` with the same allocator that
/// produced it.
pub const BlockchainState = struct {
    chain: []const u8,
    blocks: i64,
    headers: i64,
    verification_progress: f64,
    synced: bool,

    pub fn deinit(self: BlockchainState, allocator: std.mem.Allocator) void {
        allocator.free(self.chain);
    }
};
