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
    /// Tip block's own timestamp (unix seconds) — exact, preferred for the
    /// "behind by …" estimate. Only newer Bitcoin Core bases report it in
    /// `getblockchaininfo`; 0 if omitted, in which case `mediantime` is used.
    time: i64 = 0,
    /// Median timestamp (unix seconds) of the last 11 blocks. Always present on
    /// bitcoin-derived daemons, so it's the fallback when `time` is absent. Lags
    /// the true tip by ~5 blocks — negligible against a day-and-up readout.
    mediantime: i64 = 0,
};

/// Raw `getinfo` result for Nexa (subset).
pub const NexaGetInfo = struct {
    version: i64 = 0,
    blocks: i64 = 0,
    connections: i64 = 0,
    difficulty: f64 = 0,
    balance: f64 = 0,
};

/// Raw `getinfo` result for Divi (subset BoxWallet uses). Divi reports staking
/// through a `"staking status"` string — note the literal space, bound here with
/// an `@""` identifier so `std.json` matches it — that reads "Staking Active"
/// when the wallet is staking. Defaults keep parsing resilient to omitted fields.
pub const DiviGetInfo = struct {
    version: []const u8 = "",
    blocks: i64 = 0,
    connections: i64 = 0,
    difficulty: f64 = 0,
    balance: f64 = 0,
    @"staking status": []const u8 = "",
};

/// Raw `getblockchaininfo` result for DigiByte (subset BoxWallet uses).
/// DigiByte reports `verificationprogress`, so sync is derived from it the same
/// way as Nexa. Difficulty is nested per-algo under `difficulties` and unused
/// here. Defaults keep parsing resilient to fields the daemon omits.
pub const DgbBlockchainInfo = struct {
    chain: []const u8 = "",
    blocks: i64 = 0,
    headers: i64 = 0,
    bestblockhash: []const u8 = "",
    verificationprogress: f64 = 0,
    /// Tip block's own timestamp (unix seconds) — exact, preferred over
    /// `mediantime`. 0 if omitted.
    time: i64 = 0,
    /// Median timestamp (unix seconds) of the last 11 blocks — fallback for the
    /// "behind by …" estimate when `time` is absent. 0 if omitted.
    mediantime: i64 = 0,
};

/// Raw `getnetworkinfo` result for DigiByte (subset). DigiByte dropped `getinfo`
/// in core 6.16.0, so the live peer count comes from here instead. Defaults keep
/// parsing resilient to omitted fields.
pub const DgbNetworkInfo = struct {
    version: i64 = 0,
    connections: i64 = 0,
};

/// Raw `getblockchaininfo` result for ReddCoin (subset). ReddCoin 4.x is Bitcoin
/// 22-based and reports `verificationprogress`, so sync is derived from it the
/// same way as Nexa. Defaults keep parsing resilient to omitted fields.
pub const RddBlockchainInfo = struct {
    chain: []const u8 = "",
    blocks: i64 = 0,
    headers: i64 = 0,
    bestblockhash: []const u8 = "",
    verificationprogress: f64 = 0,
    /// Tip block's own timestamp (unix seconds) — exact, preferred over
    /// `mediantime`. 0 if omitted (ReddCoin's BTC-22 base may not report it).
    time: i64 = 0,
    /// Median timestamp (unix seconds) of the last 11 blocks — fallback for the
    /// "behind by …" estimate when `time` is absent. 0 if omitted.
    mediantime: i64 = 0,
};

/// Raw `getnetworkinfo` result for ReddCoin (subset). ReddCoin 4.x dropped
/// `getinfo` (Bitcoin 22 base), so the live peer count comes from here. Defaults
/// keep parsing resilient to omitted fields.
pub const RddNetworkInfo = struct {
    version: i64 = 0,
    connections: i64 = 0,
};

/// A bitcoin-derived daemon's warm-up phase, read from the "-28 in warm-up" RPC
/// reply it returns before its RPC is fully live. These daemons report only the
/// qualitative phase (no percentage), so a frontend can show *what* it's doing
/// while it comes up but not how far along it is. `none` means no warm-up phase
/// was detected (the daemon is responsive, down, or not a bitcoin-style coin).
pub const LoadingPhase = enum {
    none,
    loading,
    rescanning,
    rewinding,
    verifying,
    calculating,
};

/// Normalized wallet security state — the coin-agnostic view a frontend renders
/// and the wallet menu keys its options off. Per-coin `getwalletinfo` shapes
/// (Nexa's numeric `unlocked_until`, Divi's `encryption_status` string) map onto
/// this. Mirrors Go's `models.WEType`.
pub const WalletSecurity = enum {
    /// State not yet known (no successful poll, or the coin exposes no wallet).
    unknown,
    /// Wallet has no passphrase set — it can be encrypted.
    unencrypted,
    /// Encrypted and locked — needs a passphrase to unlock.
    locked,
    /// Encrypted and unlocked for spending.
    unlocked,
    /// Encrypted and unlocked for staking only.
    unlocked_for_staking,
};

/// Raw `getwalletinfo` result for Nexa (and other bitcoin-core-style daemons):
/// security state is read from `unlocked_until`. The field is **absent** on an
/// unencrypted wallet, so it's optional here — `null` distinguishes "no field"
/// (unencrypted) from a present `0` (locked). `>0` is an unlock timestamp.
///
/// The three balance fields feed `WalletBalance`: `balance` is the confirmed,
/// spendable amount; `unconfirmed_balance` is funds seen in the mempool but not
/// yet in a block; `immature_balance` is mined coins still maturing. Defaults
/// keep parsing resilient — a daemon that omits the mempool/immature fields just
/// reads 0, so total falls back to the confirmed balance.
pub const NexaWalletInfo = struct {
    unlocked_until: ?i64 = null,
    balance: f64 = 0,
    unconfirmed_balance: f64 = 0,
    immature_balance: f64 = 0,
};

/// Raw `getwalletinfo` result for Divi (PIVX-derived): security state is a
/// human-readable `encryption_status` string ("unencrypted" / "locked" /
/// "unlocked" / "unlocked-for-staking"). The balance triplet feeds
/// `WalletBalance` exactly as for Nexa. Defaults keep parsing resilient.
pub const DiviWalletInfo = struct {
    encryption_status: []const u8 = "",
    balance: f64 = 0,
    unconfirmed_balance: f64 = 0,
    immature_balance: f64 = 0,
};

/// Raw `getwalletinfo` result for DigiByte (Bitcoin Core 26 fork): same shape as
/// Nexa — numeric `unlocked_until` for security (absent/0/positive) plus the
/// balance triplet. Defaults keep parsing resilient to omitted fields.
pub const DgbWalletInfo = struct {
    unlocked_until: ?i64 = null,
    balance: f64 = 0,
    unconfirmed_balance: f64 = 0,
    immature_balance: f64 = 0,
};

/// Raw `getwalletinfo` result for ReddCoin (Bitcoin 22 fork, proof-of-stake):
/// numeric `unlocked_until` for security. ReddCoin's reply reports only the
/// confirmed `balance` (no mempool/immature split), so those default to 0 and
/// total collapses to the confirmed figure. Defaults keep parsing resilient.
pub const RddWalletInfo = struct {
    unlocked_until: ?i64 = null,
    balance: f64 = 0,
    unconfirmed_balance: f64 = 0,
    immature_balance: f64 = 0,
};

/// A wallet mnemonic seed (the 25-word CryptoNote/Monero backup phrase),
/// returned by an external wallet's `create` so the UI can show it for the user
/// to write down. Held in a small fixed buffer — the secret never lands on the
/// heap (memory constraint, and it's funds-sensitive), and the value lives only
/// as long as the setup modal that displays it. 256 bytes comfortably holds a
/// 25-word phrase (~200 chars).
pub const Seed = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    /// Build a `Seed` from a phrase, truncating at the buffer cap (a real seed
    /// never approaches it).
    pub fn from(words: []const u8) Seed {
        var s: Seed = .{};
        const n = @min(words.len, s.buf.len);
        @memcpy(s.buf[0..n], words[0..n]);
        s.len = n;
        return s;
    }

    pub fn slice(self: *const Seed) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Normalized wallet balance — the coin-agnostic view a frontend renders. Per-coin
/// `getwalletinfo` shapes map onto this.
///
///   - `available` — confirmed, spendable balance (`balance`).
///   - `total` — `available` plus everything still settling: funds in the mempool
///     (`unconfirmed_balance`) and mined coins still maturing (`immature_balance`).
///     Because the mempool figure lands the instant a transaction is seen, `total`
///     moves immediately — the headline figure feels responsive — while
///     `available` only rises once those funds confirm.
///
/// Scalar-only, so it owns no memory and needs no `deinit`.
pub const WalletBalance = struct {
    total: f64,
    available: f64,

    /// Compose from the three `getwalletinfo` figures: available is the confirmed
    /// balance, total adds the mempool and immature amounts on top.
    pub fn fromParts(balance: f64, unconfirmed: f64, immature: f64) WalletBalance {
        return .{ .available = balance, .total = balance + unconfirmed + immature };
    }

    /// Whether any funds are still settling (mempool/immature) — `total` is ahead
    /// of `available`. Frontends tint `total` differently while this holds.
    pub fn hasPending(self: WalletBalance) bool {
        // A hair above zero to swallow float noise from the sum.
        return self.total - self.available > 1e-12;
    }
};

/// Coin-agnostic snapshot from a daemon's `getinfo` — the live "is it healthy"
/// numbers a frontend shows alongside chain sync (peer count, block height,
/// whether the wallet is staking). Scalar-only, so it owns no memory and needs
/// no `deinit`.
pub const DaemonInfo = struct {
    blocks: i64,
    connections: i64,
    /// Wallet actively staking. Proof-of-stake coins only; always false for PoW.
    staking_active: bool,
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
    /// Tip block's own timestamp (unix seconds) — exact, preferred over
    /// `mediantime`. 0 if omitted (Divi's PIVX base may not report it).
    time: i64 = 0,
    /// Median timestamp (unix seconds) of the last 11 blocks — fallback for the
    /// "behind by …" estimate when `time` is absent. 0 if omitted.
    mediantime: i64 = 0,
};

/// Subset of a `getpeerinfo` array entry, used to estimate the network tip —
/// the height a syncing node is catching up to, which `getblockchaininfo` alone
/// doesn't report. The estimate is the max across peers of both fields below;
/// all other per-peer fields are ignored at parse time. Shape is common to
/// bitcoin-derived daemons (Bitcoin Core, PIVX/Divi, Bitcoin Unlimited/Nexa).
pub const PeerInfo = struct {
    /// The peer's own best block height, advertised when it connected. A stable
    /// estimate of the network tip from the first poll — unlike `synced_headers`
    /// it doesn't move with our own progress, so it's what makes the Headers bar
    /// start near 0% on a fresh sync instead of pinned at 100%.
    startingheight: i64 = 0,
    /// The last header height we have *in common* with this peer — i.e. our own
    /// header-download progress against it, not the peer's tip. Equals our local
    /// header count early on (hence useless alone as a target), but eventually
    /// climbs past `startingheight` as the chain grows during a long sync, so the
    /// max of the two keeps the target correct late as well as early.
    synced_headers: i64 = 0,
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
    /// Estimated network tip (max `synced_headers` across peers), or 0 when no
    /// peer reported one. The Headers sync bar fills toward this; `blocks`/
    /// `headers` only describe the local chain.
    network_height: i64 = 0,
    /// Timestamp (unix seconds) of the tip block, or 0 when the daemon doesn't
    /// report one. Frontends derive "how far behind in time" from `now - tip_time`
    /// while syncing — a wall-clock measure that needs no per-coin block interval.
    tip_time: i64 = 0,
    /// Seconds the local tip is behind the chain, supplied directly when a coin
    /// can't give a `tip_time` (e.g. Monero's daemon reports no tip timestamp and
    /// refuses `get_last_block_header` mid-sync, so Nerva derives this from the
    /// block gap × its block target). -1 means "not supplied" — frontends then
    /// fall back to the `now - tip_time` derivation. Takes precedence over
    /// `tip_time` when >= 0, since it's the coin's own answer.
    seconds_behind: i64 = -1,

    pub fn deinit(self: BlockchainState, allocator: std.mem.Allocator) void {
        allocator.free(self.chain);
    }
};
