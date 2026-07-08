const std = @import("std");

/// RPC connection details for a running coin daemon.
/// Mirrors `models.CoinAuth` from the Go source.
pub const CoinAuth = struct {
    rpc_user: []const u8,
    rpc_password: []const u8,
    ip_address: []const u8,
    port: []const u8,
    /// The coin's data directory — where its conf (and, for some coins, an
    /// out-of-band credential file) lives. `readAuth` fills this in so a coin
    /// whose secret isn't a `key=value` conf entry can locate it (Epic reads its
    /// Owner-API secret from `<data_dir>/.api_secret`). Empty when the auth was
    /// built without a data dir (e.g. the external-wallet auth); coins that don't
    /// need it ignore it.
    data_dir: []const u8 = "",
};

/// One JSON-RPC error object (`{"code":N,"message":"..."}`), for callers that
/// need the daemon's actual failure reason (invalid address, insufficient
/// funds, wallet locked, ...) rather than a generic "it failed."
pub const RpcError = struct {
    code: i64 = 0,
    message: []const u8 = "",
};

/// JSON-RPC response envelope. Daemons reply with
/// `{ "result": <T>, "error": ..., "id": ... }`.
/// `id` is dropped via `ignore_unknown_fields` at parse time; `error` is kept
/// (as `?RpcError`) for callers that want the daemon's own message on
/// failure — most callers only read `.result` and are unaffected.
pub fn JsonRpcResponse(comptime T: type) type {
    return struct {
        result: ?T = null,
        @"error": ?RpcError = null,
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

/// Raw `getblockchaininfo` result for Litecoin (subset). Litecoin Core 0.21 is
/// Bitcoin Core 0.21-based: no `getinfo`, and it reports `verificationprogress`,
/// so sync is derived from it exactly as for DigiByte. Defaults keep parsing
/// resilient to omitted fields.
pub const LtcBlockchainInfo = struct {
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

/// Raw `getnetworkinfo` result for Litecoin (subset). Litecoin Core 0.21 has no
/// `getinfo`, so the live peer count comes from here. Defaults keep parsing
/// resilient to omitted fields.
pub const LtcNetworkInfo = struct {
    version: i64 = 0,
    connections: i64 = 0,
};

/// Raw `getwalletinfo` result for Litecoin (Bitcoin Core 0.21 fork): same shape
/// as DigiByte — numeric `unlocked_until` for security (absent/0/positive) plus
/// the balance triplet. Defaults keep parsing resilient to omitted fields.
pub const LtcWalletInfo = struct {
    unlocked_until: ?i64 = null,
    balance: f64 = 0,
    unconfirmed_balance: f64 = 0,
    immature_balance: f64 = 0,
};

/// Raw `getblockchaininfo` result for Bitcoin (subset). Bitcoin Core reports
/// `verificationprogress`, so sync is derived from it exactly as for Litecoin.
/// Defaults keep parsing resilient to omitted fields.
pub const BtcBlockchainInfo = struct {
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

/// Raw `getnetworkinfo` result for Bitcoin (subset). Bitcoin Core has no
/// `getinfo`, so the live peer count comes from here. Defaults keep parsing
/// resilient to omitted fields.
pub const BtcNetworkInfo = struct {
    version: i64 = 0,
    connections: i64 = 0,
};

/// Raw `getwalletinfo` result for Bitcoin (Bitcoin Core): numeric
/// `unlocked_until` for security (absent/0/positive) plus the balance triplet.
/// Defaults keep parsing resilient to omitted fields.
pub const BtcWalletInfo = struct {
    unlocked_until: ?i64 = null,
    balance: f64 = 0,
    unconfirmed_balance: f64 = 0,
    immature_balance: f64 = 0,
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

/// Canonical normalization for a user-entered recovery seed: every word lowercased
/// and joined by single spaces, with leading/trailing and repeated whitespace
/// collapsed. The BIP39 (Ergo) and Monero/CryptoNote (Nerva/Salvium) wordlists are
/// all lowercase and decode case-sensitively, so a phrase typed with a capitalized
/// word — or pasted with newlines / double spaces — would otherwise be rejected.
///
/// **Convention:** every restore-from-seed path runs the seed through this before
/// handing it to the daemon/wallet, so a messy paste still restores. Caller owns the
/// returned slice; since it holds the (secret) mnemonic, wipe it before freeing.
pub fn normalizeSeedWords(allocator: std.mem.Allocator, seed: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var it = std.mem.tokenizeAny(u8, seed, " \t\r\n");
    var first = true;
    while (it.next()) |word| {
        if (!first) try out.writer.writeByte(' ');
        first = false;
        for (word) |c| try out.writer.writeByte(std.ascii.toLower(c));
    }
    return out.toOwnedSlice();
}

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

/// Coin-agnostic direction of a wallet transaction, for the Transactions tab.
/// `stake` covers a proof-of-stake reward (or, on a coin that still mines, a
/// mined block reward) — coins the wallet minted itself rather than received
/// from/sent to another party.
pub const TxDirection = enum { received, sent, stake };

/// One wallet transaction, normalized for display. Deliberately scalar-only
/// (no owned strings) so a bounded, fixed-capacity cache of these can be
/// memcpy'd across the poll-worker/UI-thread boundary the same way the daemon
/// version string already is (`Activity.poll_version_buf` in `app.zig`) — no
/// per-entry allocation or `deinit`.
pub const WalletTx = struct {
    direction: TxDirection,
    amount: f64, // positive magnitude; `direction` carries the sign
    time: i64, // unix seconds
    confirmations: i64,
};

/// Outcome of a send attempt, normalized for display. `failed` carries the
/// daemon's own message (invalid address / insufficient funds / wallet
/// locked / ...) verbatim — never collapsed to a generic "failed."
pub const SendResult = union(enum) {
    ok: []const u8, // txid
    failed: []const u8, // human-readable reason
};

// --- Stablecoin (DigiDollar) -----------------------------------------------
//
// Normalized models for a coin-issued stablecoin (DigiByte's DigiDollar — DD
// minted against locked DGB collateral). Amounts are **integer USD cents**
// (10000 == $100.00) end to end, matching the daemon's own unit, so no float
// rounding can creep into money figures. All of these are scalar-only /
// bounded-buffer, for the same reason as `WalletTx`: fixed-capacity caches of
// them are memcpy'd across the poll-worker/UI-thread boundary.

/// A stablecoin wallet balance, in integer cents. `confirmed` is spendable;
/// `pending` is still settling in the mempool.
pub const StablecoinBalance = struct {
    confirmed_cents: i64 = 0,
    pending_cents: i64 = 0,

    /// The headline figure — confirmed plus everything still settling.
    pub fn totalCents(self: StablecoinBalance) i64 {
        return self.confirmed_cents + self.pending_cents;
    }
};

/// What a stablecoin transaction did, normalized from the daemon's `category`.
/// `mint` created new stablecoin against locked collateral; `redeem` burned it
/// and released the collateral; `sent`/`received` are plain transfers.
pub const StablecoinTxKind = enum { mint, sent, received, redeem };

/// One stablecoin transaction, normalized for display. Scalar-only, like
/// `WalletTx`.
pub const StablecoinTx = struct {
    kind: StablecoinTxKind,
    amount_cents: i64, // positive magnitude; `kind` carries the sign
    time: i64, // unix seconds
    confirmations: i64,
};

/// One collateral position (vault): stablecoin minted against locked collateral
/// that can be redeemed — burned to release the collateral — once its timelock
/// expires. `id` is the mint transaction hash (the daemon's position handle),
/// held in a bounded buffer so the struct stays memcpy-safe.
pub const StablecoinPosition = struct {
    id_buf: [64]u8 = undefined,
    id_len: usize = 0,
    /// The stablecoin amount minted (and the amount a redeem must burn — the
    /// daemon requires redeeming the full vault), in cents.
    amount_cents: i64 = 0,
    /// The lock tier the position was minted at (indexes the coin's tier table).
    tier: u8 = 0,
    /// Block height at which the timelock expires and the vault can be redeemed.
    unlock_height: i64 = 0,
    /// The daemon's own "this can be redeemed now" verdict (timelock expired,
    /// confirmed, unspent) — the field the integration guide says to filter on.
    can_redeem: bool = false,

    pub fn id(self: *const StablecoinPosition) []const u8 {
        return self.id_buf[0..self.id_len];
    }

    pub fn setId(self: *StablecoinPosition, txid: []const u8) void {
        const n = @min(txid.len, self.id_buf.len);
        @memcpy(self.id_buf[0..n], txid[0..n]);
        self.id_len = n;
    }
};

/// Live stablecoin system state, folded from the daemon's info RPCs. Everything
/// is best-effort past `active`: a daemon mid-warmup (or an oracle hiccup)
/// leaves the affected figures at their zero values rather than erroring the
/// whole snapshot.
pub const StablecoinInfo = struct {
    /// Whether the consensus feature is ACTIVE on this network (BIP9 status
    /// "active"). Until it is, minting/sending/redeeming are gated off and the
    /// UI explains the deployment status instead.
    active: bool = false,
    /// The raw BIP9 deployment status ("defined"/"started"/"locked_in"/
    /// "active"/"failed"), for the pre-activation readout. Bounded buffer.
    status_buf: [24]u8 = undefined,
    status_len: usize = 0,
    /// The block height the feature activates at (the daemon's
    /// `activation_height` once known, else its `min_activation_height`), so a
    /// pre-activation UI can count down to it. 0 = unknown.
    activation_height: i64 = 0,
    /// Oracle consensus price of the collateral coin in **micro-USD per coin**
    /// (1_000_000 == $1.00). 0 = unknown/unavailable.
    price_micro_usd: u64 = 0,
    /// Whether the oracle price is stale (old enough that minting against it
    /// is blocked) — surfaced so the user knows why a mint might refuse.
    price_stale: bool = false,
    /// System-wide stablecoin supply, in cents. 0 when unknown.
    total_supply_cents: i64 = 0,
    /// Total collateral locked system-wide, in the collateral coin's units.
    total_collateral: f64 = 0,
    /// System health: aggregate collateral ratio, percent (e.g. 312.5). 0 when
    /// unknown.
    health_ratio: f64 = 0,
    /// Whether the protocol's volatility protection currently blocks minting.
    minting_blocked: bool = false,

    pub fn status(self: *const StablecoinInfo) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    pub fn setStatus(self: *StablecoinInfo, s: []const u8) void {
        const n = @min(s.len, self.status_buf.len);
        @memcpy(self.status_buf[0..n], s[0..n]);
        self.status_len = n;
    }
};

/// How far a wallet rescan has progressed — `scanned` blocks of `target`. Reported
/// by an in-daemon wallet that re-scans the chain after a restore (Ergo, whose node
/// only scans forward, so a restored seed's history is found by an explicit
/// rescan-from-0). Scalar-only; owns no memory. A frontend shows it as a
/// "Rescanning… X%" indicator until `scanned` catches up to `target`.
pub const RescanProgress = struct {
    scanned: i64,
    target: i64,

    /// Fraction scanned in `[0, 1]`. Guards a zero/negative `target` (returns 0) and
    /// clamps overshoot, so a frontend can multiply by 100 for a percentage safely.
    pub fn fraction(self: RescanProgress) f64 {
        if (self.target <= 0) return 0;
        const f = @as(f64, @floatFromInt(self.scanned)) / @as(f64, @floatFromInt(self.target));
        return std.math.clamp(f, 0, 1);
    }
};

/// Live CPU-mining state from a daemon that mines in-process (the CryptoNote
/// coins — Nerva's `mining_status`). Scalar-only, so it owns no memory, can be
/// carried through the poll worker's atomics, and needs no `deinit`.
pub const MiningStatus = struct {
    /// Whether the daemon is currently mining.
    active: bool = false,
    /// How many CPU threads the miner is running on (0 when not mining).
    threads: u32 = 0,
    /// Current hashrate in hashes per second (0 when not mining).
    speed: u64 = 0,
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
    /// The running daemon's own version, normalized to a dotted string (e.g.
    /// "8.26.2"), or empty when the coin can't report one. Each coin fills this
    /// from whatever its RPC exposes — a numeric `CLIENT_VERSION`, a version
    /// string, or a user-agent. Owned by the caller's allocator (the poll arena).
    version: []const u8 = "",
};

/// Decode a bitcoin-style `CLIENT_VERSION` integer into a dotted version string.
/// The encoding is `1000000*MAJOR + 10000*MINOR + 100*REVISION + BUILD` (e.g.
/// 8260200 → "8.26.2"). The build component is dropped when zero so the common
/// case reads cleanly; a non-zero build is appended. Returns an empty string for a
/// non-positive value (unknown). Caller owns the returned slice.
pub fn clientVersionString(allocator: std.mem.Allocator, v: i64) ![]u8 {
    if (v <= 0) return allocator.dupe(u8, "");
    const major = @divTrunc(v, 1_000_000);
    const minor = @mod(@divTrunc(v, 10_000), 100);
    const rev = @mod(@divTrunc(v, 100), 100);
    const build = @mod(v, 100);
    if (build != 0)
        return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ major, minor, rev, build });
    return std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{ major, minor, rev });
}

test "clientVersionString decodes the bitcoin CLIENT_VERSION encoding" {
    const a = std.testing.allocator;
    const cases = .{
        .{ 8_260_200, "8.26.2" }, // DigiByte 8.26.2 (build 0 dropped)
        .{ 4_220_900, "4.22.9" }, // generic 3-part decode (build 0 dropped)
        .{ 42_209, "0.4.22.9" }, // ReddCoin's real CLIENT_VERSION → legacy 4-part "0.4.22.9"
        .{ 2_000_000, "2.0.0" }, // Nexa 2.0.0.0 → 2.0.0 (pads equal under isNewer)
        .{ 1_020_304, "1.2.3.4" }, // non-zero build is kept
    };
    inline for (cases) |c| {
        const s = try clientVersionString(a, c[0]);
        defer a.free(s);
        try std.testing.expectEqualStrings(c[1], s);
    }
    const empty = try clientVersionString(a, 0);
    defer a.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

test "RescanProgress.fraction derives a clamped 0..1 ratio" {
    // Partway through: 500k of 1.2M scanned.
    try std.testing.expectApproxEqAbs(
        @as(f64, 500000.0 / 1200000.0),
        (RescanProgress{ .scanned = 500000, .target = 1200000 }).fraction(),
        1e-9,
    );
    // A zero/unknown target can't divide — reads as 0, not NaN/inf.
    try std.testing.expectEqual(@as(f64, 0), (RescanProgress{ .scanned = 10, .target = 0 }).fraction());
    // Overshoot (scanned past a stale target) clamps to 1 rather than exceeding it.
    try std.testing.expectEqual(@as(f64, 1), (RescanProgress{ .scanned = 1300000, .target = 1200000 }).fraction());
}

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
