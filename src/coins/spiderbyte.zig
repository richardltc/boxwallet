const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const rpc = @import("../rpc.zig");
const install_mod = @import("../install.zig");
const conf = @import("../conf.zig");
const Coin = @import("../coin.zig").Coin;

/// SpiderByte (SPB) backend. A **LitecoinPlus**-derived, NovaCoin/PPCoin-era
/// Proof-of-Stake coin (the daemon's peer `subver` reads `LitecoinPlus:7.0.0.1`),
/// so it predates the Bitcoin-Core split of `getinfo` into
/// `getblockchaininfo`/`getnetworkinfo`/`getwalletinfo`:
///
///   * **Everything comes from `getinfo`** — block height, peer count, the
///     daemon's version string, the wallet balance, and the encrypt/lock state
///     (`unlocked_until`). There is no `getblockchaininfo`, `getwalletinfo`, or
///     `getstakinginfo`. The block target a syncing node climbs toward is read
///     from peers (`getpeerinfo` `startingheight`) the same way as the bitcoin
///     coins, since `getinfo` reports neither `headers` nor `verificationprogress`.
///   * **Staking is implicit.** These wallets mint automatically whenever the
///     wallet is *not locked* (an unencrypted or unlocked wallet stakes; an
///     encrypted+locked one doesn't). There's no staking RPC to query, so
///     `staking_active` is derived from `getinfo`'s `unlocked_until`.
///   * **No public download.** Upstream publishes no per-platform binary bundle
///     yet, so `install` is unsupported — the `spiderbyted` binary is provided
///     out-of-band in the install root and `isInstalled` simply detects it.
///   * **Wallet auto-loads.** Unlike the Bitcoin-Core 0.21+ forks, the daemon
///     creates/loads its single `wallet.dat` itself, so no `ensure_wallet` step
///     is needed. Backups are a binary `backupwallet` copy (there's no
///     `dumpwallet`/`importwallet`), so file *import* isn't offered.
pub const SpiderByte = struct {
    /// Whether the coin is exposed in the nav. False keeps it out of the left
    /// bar entirely (registered but hidden) until it's ready for users.
    pub const live = true;
    pub const coin_name = "SpiderByte";
    pub const coin_name_abbrev = "SPB";
    /// One-line description shown under the coin name on the detail pane.
    pub const coin_description = "Lightweight, eco-friendly proof-of-stake coin.";
    /// SpiderByte brand colour (`#RRGGBB`), for tinting the coin in the frontend.
    pub const coin_color = "#f72585";
    /// Donation address for BoxWallet development, in SpiderByte's own
    /// currency.
    /// TODO(richard): replace with the real SPB tip address.
    pub const tip_address = "TODO-SPB-TIP-ADDRESS-NOT-SET";
    /// Two-tone wordmark: the nav and detail pane draw "Spider" in
    /// `wordmark_head_color` (white) and "Byte" in `coin_color`, split after
    /// "Spider" — the reverse colour assignment from ReddCoin's "Redd"+"Coin".
    pub const wordmark_head_color = "#ffffff";
    pub const wordmark_split = "Spider".len;
    /// SpiderByte is proof-of-stake (PoS) — the wallet can stake.
    pub const proof_of_stake = true;
    pub const conf_file = "SpiderByte.conf";
    pub const home_dir = ".SpiderByte";
    pub const home_dir_win = "SpiderByte";
    /// macOS data dir name. **Unverified and currently unreachable**: SpiderByte
    /// publishes no bundle for any platform (`download` is null), so it can never
    /// be installed and this path is never resolved. The name follows its
    /// LitecoinPlus/bitcoin lineage convention rather than a read of the source,
    /// which isn't published — confirm it against the daemon before shipping any
    /// macOS build.
    pub const home_dir_mac: ?[]const u8 = "SpiderByte";
    pub const rpc_default_username = "spiderbyterpc";
    /// JSON-RPC default port (P2P is 44351); BoxWallet pins it in the conf.
    pub const rpc_default_port = "44350";
    /// The bundled daemon version. The binary self-reports `getinfo.version` as
    /// `v7.0.0.1`; the leading `v` is stripped in `daemonInfo` so the Running line
    /// and on-disk version marker match this string.
    pub const core_version = "7.0.0.1";

    // Binary name. The single `spiderbyted` is both daemon and CLI (commands run
    // as `spiderbyted <cmd>`), so there are no separate cli/tx binaries. Windows
    // appends `.exe`; Linux/macOS use the bare name.
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    pub const daemon_file = "spiderbyted" ++ exe_suffix;

    /// No upstream binary bundle is published for any platform yet, so there's
    /// nothing to download — the daemon binary is provided out-of-band in the
    /// install root. Kept as an explicit null (mirroring the other coins' shape)
    /// so `install` surfaces a clear `error.UnsupportedPlatform`.
    const download: ?install_mod.Download = null;

    /// Raw `getinfo` result (the subset BoxWallet uses). This old daemon folds
    /// the chain, network, and wallet views into one call:
    ///   - `version` is a string (`"v7.0.0.1"`).
    ///   - `blocks`/`connections` drive the live status.
    ///   - `balance` is the confirmed spendable amount; `stake` is coins committed
    ///     to in-progress staking and `newmint` freshly minted immature coins —
    ///     both still yours but not yet spendable.
    ///   - `unlocked_until` is **absent** on an unencrypted wallet, `0` when
    ///     locked, and a positive unlock timestamp otherwise — the same encoding
    ///     bitcoin-core reports in `getwalletinfo`.
    ///   - `testnet` distinguishes the chain (no `chain` string on this daemon).
    /// Defaults keep parsing resilient to fields the daemon omits.
    const SpiderByteGetInfo = struct {
        version: []const u8 = "",
        blocks: i64 = 0,
        connections: i64 = 0,
        balance: f64 = 0,
        stake: f64 = 0,
        newmint: f64 = 0,
        unlocked_until: ?i64 = null,
        testnet: bool = false,
    };

    /// The single `getblock` field BoxWallet needs: the tip block's `time` (unix
    /// seconds), used for the "behind by …" sync readout. Everything else in the
    /// verbose `getblock` result is dropped via `ignore_unknown_fields`.
    const SpiderByteBlock = struct {
        time: i64 = 0,
    };

    /// Build the type-erased `Coin` handle for this instance.
    pub fn coin(self: *SpiderByte) Coin {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Live chain state, normalized for a frontend. `getinfo` reports only the
    /// local `blocks` (no `headers`/`verificationprogress`), so the network tip is
    /// estimated from peers (`getpeerinfo` `startingheight`) and "synced" / progress
    /// are derived against it. With no header-download phase on this old daemon,
    /// `headers` tracks `blocks` (single-phase sync).
    pub fn blockchainState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.BlockchainState {
        var parsed = try rpc.callParsed(SpiderByteGetInfo, allocator, auth, "getinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;

        // Network tip from peers, so the Headers bar can fill toward it. A
        // getpeerinfo hiccup just leaves it 0 (unknown).
        const network = rpc.networkHeight(allocator, auth) catch 0;
        const st = syncStatus(r.blocks, network);

        // Tip-block timestamp for the "behind by …" wall-clock readout. `getinfo`
        // reports none on this NovaCoin-era daemon, so it's fetched from the tip
        // block itself — but only while syncing, to avoid two extra RPCs per poll
        // once caught up (the frontend shows this readout only during a sync).
        const tip_time: i64 = if (!st.synced) tipTime(allocator, auth, r.blocks) else 0;

        return .{
            .chain = try allocator.dupe(u8, if (r.testnet) "test" else "main"),
            .blocks = r.blocks,
            // This daemon has no separate header-download phase (headers and blocks
            // advance together), so there's no "headers" progress to show. Report
            // headers as the network tip: the frontend's Headers bar then reads
            // complete (nothing to pre-download) and the *Blocks* bar carries the
            // real sync progress (`blocks / network`). `max`-guarded so when we're
            // caught up — or before any peer reports a tip — headers never falls
            // below blocks, which would peg the Blocks bar at a false 100%.
            .headers = @max(network, r.blocks),
            .verification_progress = st.progress,
            .synced = st.synced,
            .network_height = network,
            .tip_time = tip_time,
        };
    }

    /// The tip block's timestamp (unix seconds), so the frontend can show how far
    /// behind in wall-clock time the chain is while syncing. `getinfo` carries no
    /// tip timestamp on this NovaCoin-era daemon, so it's read from the tip block
    /// in two steps: `getblockhash(<height>)` → `getblock(<hash>).time`.
    ///
    /// Best-effort: any hiccup (missing method, no such block, transport error)
    /// returns 0 (unknown), which just leaves the readout omitted — never fatal to
    /// the poll. Each call parses into a minimal struct and frees its reply, so the
    /// working set stays flat.
    fn tipTime(allocator: std.mem.Allocator, auth: models.CoinAuth, height: i64) i64 {
        if (height <= 0) return 0;

        // getblockhash <height> → "<hash>"
        const hp = std.fmt.allocPrint(allocator, "[{d}]", .{height}) catch return 0;
        defer allocator.free(hp);
        var hash_parsed = rpc.callParsedParams([]const u8, allocator, auth, "getblockhash", hp) catch return 0;
        defer hash_parsed.deinit();
        const hash = hash_parsed.value.result orelse return 0;

        // getblock "<hash>" → { time }
        const hq = rpc.jsonQuote(allocator, hash) catch return 0;
        defer allocator.free(hq);
        const bp = std.fmt.allocPrint(allocator, "[{s}]", .{hq}) catch return 0;
        defer allocator.free(bp);
        var blk_parsed = rpc.callParsedParams(SpiderByteBlock, allocator, auth, "getblock", bp) catch return 0;
        defer blk_parsed.deinit();
        const b = blk_parsed.value.result orelse return 0;
        return b.time;
    }

    /// Live status, normalized for a frontend — all from the one `getinfo` call:
    /// block height, peer count, the daemon version (leading `v` stripped to match
    /// `core_version`), and staking state (derived from `unlocked_until`).
    pub fn daemonInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.DaemonInfo {
        var parsed = try rpc.callParsed(SpiderByteGetInfo, allocator, auth, "getinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return .{
            .blocks = r.blocks,
            .connections = r.connections,
            .staking_active = stakingFromUnlockedUntil(r.unlocked_until),
            // Owned by `allocator` so it outlives `parsed`'s deinit.
            .version = try normalizeVersion(allocator, r.version),
        };
    }

    /// The daemon's default data directory (`~/.SpiderByte`), where
    /// `SpiderByte.conf` and the chain/wallet live.
    pub fn dataDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        return conf.dataDir(allocator, home, home_dir, home_dir_win, home_dir_mac);
    }

    /// The managed wallet's on-disk location — the single `wallet.dat` the daemon
    /// keeps directly under its data dir (NovaCoin-era layout, no `wallets/`
    /// subdir). Caller owns the returned strings.
    pub fn walletPath(allocator: std.mem.Allocator, home: []const u8) !?Coin.WalletFile {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        return .{ .path = try std.fs.path.join(allocator, &.{ data_dir, "wallet.dat" }) };
    }

    /// True if `spiderbyted` (`spiderbyted.exe` on Windows) is already present
    /// under `install_root`. SpiderByte has no installer, so this is the only way
    /// the binary becomes available.
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, daemon_file);
    }

    /// No upstream binary bundle is published yet, so there's nothing to fetch —
    /// the `spiderbyted` binary is provided out-of-band in the install root.
    pub fn install(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        _ = allocator;
        _ = install_root;
        _ = progress;
        if (download == null) return error.UnsupportedPlatform;
    }

    /// Ensure `SpiderByte.conf` carries the RPC creds (and `server=1`/`rpcport`)
    /// BoxWallet needs before the daemon reads it; existing values are kept. A
    /// standard NovaCoin-derived `key=value` conf.
    pub fn prepareConf(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        _ = try conf.populate(allocator, io, data_dir, conf_file, rpc_default_username, rpc_default_port);
    }

    /// SpiderByte forks itself into the background with `-daemon` on POSIX, but
    /// runs in the foreground on Windows (no `-daemon` support there).
    pub fn launchMode() Coin.LaunchMode {
        return if (builtin.os.tag == .windows) .foreground else .fork;
    }

    /// The daemon's log file under the data dir, whose tail is read for a
    /// startup-failure reason when the daemon dies without saying why on stderr.
    pub fn daemonLogFile() []const u8 {
        return "debug.log";
    }

    /// The daemon binary path. The launcher appends `-daemon` itself for the fork
    /// path; on Windows it's spawned bare (detached).
    pub fn daemonArgv(allocator: std.mem.Allocator, install_root: []const u8, _: []const u8) ![]const []const u8 {
        const path = try std.fs.path.join(allocator, &.{ install_root, daemon_file });
        const argv = try allocator.alloc([]const u8, 1);
        argv[0] = path;
        return argv;
    }

    /// Ask spiderbyted to shut down via the JSON-RPC `stop`.
    pub fn requestStop(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        const reply = try rpc.call(allocator, auth, "stop");
        allocator.free(reply);
    }

    /// Read the wallet's security state from `getinfo`. NovaCoin-era daemons report
    /// `unlocked_until` here (not in a separate `getwalletinfo`): **absent** on an
    /// unencrypted wallet, `0` when locked, a positive unlock timestamp otherwise.
    pub fn walletSecurityState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.WalletSecurity {
        var parsed = try rpc.callParsed(SpiderByteGetInfo, allocator, auth, "getinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return securityFromUnlockedUntil(r.unlocked_until);
    }

    /// Read the wallet's balances from `getinfo`. `available` is the confirmed
    /// `balance`; coins committed to in-progress `stake` and freshly minted
    /// (`newmint`, immature) coins are still yours but not yet spendable, so they
    /// lift `total` above `available` exactly like the mempool/immature split on
    /// the bitcoin coins.
    pub fn walletBalance(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.WalletBalance {
        var parsed = try rpc.callParsed(SpiderByteGetInfo, allocator, auth, "getinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return models.WalletBalance.fromParts(r.balance, r.stake, r.newmint);
    }

    /// One `listtransactions` entry (the subset BoxWallet uses).
    const SpiderByteTx = struct {
        category: []const u8 = "",
        amount: f64 = 0,
        time: i64 = 0,
        confirmations: i64 = 0,
    };

    /// The wallet's most recent transactions, newest-first, via
    /// `listtransactions "*" <limit> 0`. This NovaCoin-era daemon returns them
    /// oldest-to-newest (confirmed against upstream `rpcwallet.cpp`'s own
    /// `std::reverse(...); // Return oldest to newest`), so the result is reversed
    /// here. `"move"` entries (transfers between named accounts BoxWallet never
    /// uses) are dropped by `directionFromCategory` returning null.
    pub fn walletTransactions(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        limit: usize,
    ) ![]models.WalletTx {
        const params = try std.fmt.allocPrint(allocator, "[\"*\",{d},0]", .{limit});
        defer allocator.free(params);
        var parsed = try rpc.callParsedParams([]SpiderByteTx, allocator, auth, "listtransactions", params);
        defer parsed.deinit();

        const raw = parsed.value.result orelse return error.EmptyRpcResult;
        return mapTransactions(allocator, raw);
    }

    /// Reverse `raw` (oldest-to-newest, as the daemon returns it) into
    /// newest-first `WalletTx`es, mapping each `category` via
    /// `directionFromCategory` and dropping entries with no mapped direction
    /// (`"move"`). Split out from `walletTransactions` so the mapping/ordering
    /// logic is unit-testable without a live RPC call. Two passes (count, then
    /// fill) so the returned slice is allocated at its exact final length —
    /// callers free exactly what was allocated.
    fn mapTransactions(allocator: std.mem.Allocator, raw: []const SpiderByteTx) ![]models.WalletTx {
        var count: usize = 0;
        for (raw) |r| {
            if (directionFromCategory(r.category) != null) count += 1;
        }

        var out = try allocator.alloc(models.WalletTx, count);
        var n: usize = 0;
        var i = raw.len;
        while (i > 0) {
            i -= 1;
            const direction = directionFromCategory(raw[i].category) orelse continue;
            out[n] = .{
                .direction = direction,
                .amount = @abs(raw[i].amount),
                .time = raw[i].time,
                .confirmations = raw[i].confirmations,
            };
            n += 1;
        }
        return out;
    }

    /// Map this daemon's `listtransactions` `category` to the normalized
    /// direction. `"generate"`/`"immature"`/`"orphan"` all come from
    /// `CWalletTx::GetAmounts`'s combined `IsCoinBase() || IsCoinStake()` check —
    /// SpiderByte never mines, so these three only ever represent a stake reward
    /// at different maturity stages. `"move"` has no direction (null; the caller
    /// skips it).
    fn directionFromCategory(category: []const u8) ?models.TxDirection {
        if (std.mem.eql(u8, category, "receive")) return .received;
        if (std.mem.eql(u8, category, "send")) return .sent;
        if (std.mem.eql(u8, category, "generate") or
            std.mem.eql(u8, category, "immature") or
            std.mem.eql(u8, category, "orphan")) return .stake;
        return null;
    }

    /// The wallet's receive address. `force_new` picks the RPC:
    /// `getaccountaddress ""` for the stable "current" address (used only for
    /// the one-time initial fetch — see `rpcwallet.cpp`'s `GetAccountAddress`,
    /// which silently rotates once the address has been paid), or
    /// `getnewaddress` to mint a fresh one on an explicit user-requested
    /// rotation (mints a new key on *every* call, so it's only ever called on
    /// demand, never polled).
    pub fn receiveAddress(allocator: std.mem.Allocator, auth: models.CoinAuth, force_new: bool) ![]const u8 {
        var parsed = try rpc.callParsedParams([]const u8, allocator, auth, receiveAddressMethod(force_new), "[\"\"]");
        defer parsed.deinit();
        const addr = parsed.value.result orelse return error.EmptyRpcResult;
        return allocator.dupe(u8, addr); // parsed.deinit() frees its arena below us
    }

    /// Which RPC `receiveAddress` calls for a given `force_new` — split out as
    /// a pure helper so the method-selection logic is unit-testable without a
    /// live daemon.
    fn receiveAddressMethod(force_new: bool) []const u8 {
        return if (force_new) "getnewaddress" else "getaccountaddress";
    }

    /// Send `amount` SPB to `address` via `sendtoaddress`. The daemon does its
    /// own address validation, lock-state check, and balance check —
    /// `SendResult` carries whichever of those (or success) came back,
    /// verbatim, rather than collapsing a rejected send into a generic error.
    pub fn sendToAddress(allocator: std.mem.Allocator, auth: models.CoinAuth, address: []const u8, amount: f64) !models.SendResult {
        const addr_q = try rpc.jsonQuote(allocator, address);
        defer allocator.free(addr_q);
        var amount_buf: [32]u8 = undefined;
        const params = try std.fmt.allocPrint(allocator, "[{s},{s}]", .{ addr_q, formatSendAmount(&amount_buf, amount) });
        defer allocator.free(params);

        var parsed = try rpc.callParsedParams([]const u8, allocator, auth, "sendtoaddress", params);
        defer parsed.deinit();
        if (parsed.value.result) |txid| return .{ .ok = try allocator.dupe(u8, txid) };
        if (parsed.value.@"error") |e| return .{ .failed = try allocator.dupe(u8, e.message) };
        return .{ .failed = "no response from daemon" };
    }

    /// Format `amount` as a fixed 8-decimal-place string (never scientific
    /// notation) for splicing into the `sendtoaddress` params array — split
    /// out as a pure helper so the formatting is unit-testable without a live
    /// daemon. The daemon itself rounds to 6dp (`rpcwallet.cpp`: "amount is a
    /// real and is rounded to the nearest 0.000001"), so 8dp is a safe, exact
    /// superset that matches the display convention used everywhere else in
    /// this coin file. Returns a slice into `buf` (sized for any sane amount;
    /// callers pass a `[32]u8`).
    fn formatSendAmount(buf: []u8, amount: f64) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        w.printFloat(amount, .{ .mode = .decimal, .precision = 8 }) catch return "0.00000000";
        return w.buffered();
    }

    /// Encrypt the wallet with `passphrase`. spiderbyted stops itself afterwards
    /// (the caller restarts it). The passphrase is JSON-escaped before splicing.
    pub fn walletEncrypt(allocator: std.mem.Allocator, auth: models.CoinAuth, passphrase: []const u8) !void {
        const pw = try rpc.jsonQuote(allocator, passphrase);
        defer allocator.free(pw);
        const params = try std.fmt.allocPrint(allocator, "[{s}]", .{pw});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "encryptwallet", params);
    }

    /// Unlock the wallet via `walletpassphrase`. This NovaCoin-era daemon takes the
    /// timeout in seconds; `0` would re-lock immediately on this codebase (unlike
    /// Bitcoin-Core 22), so a long finite timeout stands in for "indefinite". A
    /// `staking` unlock adds the third `true` flag (unlock-for-staking-only).
    pub fn walletUnlock(allocator: std.mem.Allocator, auth: models.CoinAuth, passphrase: []const u8, staking: bool) !void {
        const pw = try rpc.jsonQuote(allocator, passphrase);
        defer allocator.free(pw);
        const params = if (staking)
            try std.fmt.allocPrint(allocator, "[{s},9999999,true]", .{pw})
        else
            try std.fmt.allocPrint(allocator, "[{s},9999999]", .{pw});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "walletpassphrase", params);
    }

    /// Re-lock the wallet via `walletlock`.
    pub fn walletLock(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        return rpc.callExpectOk(allocator, auth, "walletlock", "[]");
    }

    /// Back up the wallet to `dest_path` via `backupwallet` — a binary copy of
    /// `wallet.dat` that the user keeps as their backup (it is the backup, not a
    /// temp: don't shred it). Works regardless of lock state (it's just a file
    /// copy). The path is JSON-escaped before splicing.
    pub fn walletBackup(allocator: std.mem.Allocator, auth: models.CoinAuth, dest_path: []const u8) !void {
        const qpath = try rpc.jsonQuote(allocator, dest_path);
        defer allocator.free(qpath);
        const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qpath});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "backupwallet", params);
    }

    /// Restore the wallet by swapping in a user-supplied backup `wallet.dat`.
    /// This NovaCoin-era daemon has no `importwallet` RPC — its backup is a binary
    /// `backupwallet` copy — so restore is the file-level counterpart: replace
    /// `<data_dir>/wallet.dat` with `src_path`. The daemon holds `wallet.dat` open
    /// while running, so the caller stops it before calling this and restarts it
    /// after (see the offline-restore orchestration in `app.zig`); this hook only
    /// touches files and takes no auth.
    ///
    /// Safety: the existing `wallet.dat` (if any) is first moved aside to a
    /// timestamped `wallet.dat.bak-<unix_ts>` sibling, so a mistaken restore never
    /// destroys the current wallet — it stays recoverable. An empty source is
    /// rejected before anything is clobbered. The copy is streamed in a fixed
    /// buffer (no whole-file buffering).
    pub fn walletRestoreFileOffline(
        allocator: std.mem.Allocator,
        home: []const u8,
        src_path: []const u8,
    ) !void {
        // Self-contained blocking IO (mirrors Ergo's walletRemove and the
        // Monero-style coins' copyKeysFile) — the file work is bounded and this hook
        // takes no `io` from the caller.
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);

        // Open source via (dir, basename) so an absolute picker path works the same
        // way the conf code / copyKeysFile open files.
        const src_dir = std.fs.path.dirname(src_path) orelse ".";
        const src_base = std.fs.path.basename(src_path);
        var sd = std.Io.Dir.cwd().openDir(io, src_dir, .{}) catch return error.WalletFileNotFound;
        defer sd.close(io);

        // Reject an empty/missing source before touching the current wallet.
        const src_stat = sd.statFile(io, src_base, .{}) catch return error.WalletFileNotFound;
        if (src_stat.size == 0) return error.EmptyWalletFile;

        var dd = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
        defer dd.close(io);

        // Preserve the current wallet.dat (if present) as a timestamped backup so a
        // wrong-file restore stays recoverable. A missing current wallet is fine.
        if (dd.statFile(io, "wallet.dat", .{})) |_| {
            const ns = std.Io.Timestamp.now(io, .real).toNanoseconds();
            const bak = try std.fmt.allocPrint(allocator, "wallet.dat.bak-{d}", .{ns});
            defer allocator.free(bak);
            try dd.rename("wallet.dat", dd, bak, io);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        // Stream the backup into place. Unlike copyKeysFile (a single 64 KB read,
        // fine for tiny .keys files), a BDB wallet.dat can be large, so copyFile's
        // streaming copy is used — still bounded memory, but no truncation.
        try sd.copyFile(src_base, dd, "wallet.dat", io, .{});
    }

    /// This daemon answers `getinfo` immediately *once its RPC is up* (no
    /// bitcoin-style "-28 warm-up" phase), so probe it for liveness/warm-up.
    pub fn warmupProbeMethod() []const u8 {
        return "getinfo";
    }

    /// Classify the daemon's warm-up phase from a `debug.log` tail. This
    /// NovaCoin-era daemon predates the `-28` RPC warm-up: it starts its RPC
    /// server *before* reading the on-disk block index (minutes, on a deep chain),
    /// but can't serve `getinfo` until that load — and the wallet load after it —
    /// finish, so a poll mid-load just fails, indistinguishable from a dead node.
    /// The daemon logs a `Loading block index...` line when it begins and nothing
    /// of substance until it finishes with `Done loading`, so if the most recent
    /// of those two markers is the start line, it's still loading. No percentage
    /// is reported: the legacy code emits none. `.none` otherwise (including once
    /// loading has completed), so a transient RPC blip on an already-running node
    /// doesn't masquerade as a fresh load.
    ///
    /// Note the daemon's own RPC access log ("ThreadRPCServer method=getinfo",
    /// written once per BoxWallet poll) piles up after the start marker during the
    /// load, so the caller must pass a tail long enough to still contain it.
    pub fn warmupPhaseFromLog(tail: []const u8) models.LoadingPhase {
        const start = std.mem.lastIndexOf(u8, tail, "Loading block index") orelse return .none;
        // "Done loading" after the last load marker ⇒ init finished (RPC about to
        // serve); its absence ⇒ still mid-load.
        if (std.mem.indexOf(u8, tail[start..], "Done loading") != null) return .none;
        return .loading_block_index;
    }

    // --- pure helpers (unit-tested without a daemon) ---------------------

    /// Derived sync state from the local height vs the peer-estimated network tip.
    const SyncStatus = struct { synced: bool, progress: f64 };

    /// Compute "synced" + a 0..1 progress fraction from local `blocks` against the
    /// `network_height` estimated from peers. With no peers (network_height <= 0)
    /// the tip is unknown, so it reads as not-synced / 0 progress rather than
    /// falsely 100%.
    fn syncStatus(blocks: i64, network_height: i64) SyncStatus {
        if (network_height <= 0) return .{ .synced = false, .progress = 0 };
        const p = @as(f64, @floatFromInt(blocks)) / @as(f64, @floatFromInt(network_height));
        return .{ .synced = blocks >= network_height, .progress = std.math.clamp(p, 0, 1) };
    }

    /// Whether the wallet is actively staking, derived from `getinfo`'s
    /// `unlocked_until`. These wallets mint automatically whenever the wallet is
    /// not locked: an **unencrypted** wallet (field absent → null) or an
    /// **unlocked** one (`> 0`) stakes; an encrypted+**locked** wallet (`0`) does
    /// not. There's no staking RPC on this daemon, so this is the honest proxy.
    fn stakingFromUnlockedUntil(unlocked_until: ?i64) bool {
        const u = unlocked_until orelse return true;
        return u != 0;
    }

    /// Map a NovaCoin/bitcoin-style `unlocked_until` (absent/0/positive) to the
    /// normalized `WalletSecurity`. This daemon can't distinguish a spending unlock
    /// from a staking unlock over RPC, so any positive timestamp reads as
    /// `.unlocked`.
    fn securityFromUnlockedUntil(unlocked_until: ?i64) models.WalletSecurity {
        const u = unlocked_until orelse return .unencrypted;
        if (u == 0) return .locked;
        return .unlocked;
    }

    /// Strip the leading `v`/`V` from the daemon's `getinfo.version`
    /// (`"v7.0.0.1"` → `"7.0.0.1"`) so the Running line and the on-disk version
    /// marker line up with `core_version`. Caller owns the returned slice.
    fn normalizeVersion(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
        const v = if (raw.len > 0 and (raw[0] == 'v' or raw[0] == 'V')) raw[1..] else raw;
        return allocator.dupe(u8, v);
    }

    // --- vtable plumbing -------------------------------------------------

    const vtable: Coin.VTable = .{
        .coin_name = vtCoinName,
        .coin_name_abbrev = vtCoinNameAbbrev,
        .coin_description = vtCoinDescription,
        .coin_color = vtCoinColor,
        .tip_address = vtTipAddress,
        .wordmark = vtWordmark,
        .core_version = vtCoreVersion,
        .proof_of_stake = vtProofOfStake,
        .conf_file = vtConfFile,
        .daemon_file = vtDaemonFile,
        .rpc_default_port = vtRpcDefaultPort,
        .rpc_default_username = vtRpcDefaultUsername,
        .blockchain_state = vtBlockchainState,
        .daemon_info = vtDaemonInfo,
        .data_dir = vtDataDir,
        .wallet_path = vtWalletPath,
        .is_installed = vtIsInstalled,
        .install = vtInstall,
        .prepare_conf = vtPrepareConf,
        .launch_mode = vtLaunchMode,
        .daemon_log_file = vtDaemonLogFile,
        .daemon_argv = vtDaemonArgv,
        .request_stop = vtRequestStop,
        .wallet_security_state = vtWalletSecurityState,
        .wallet_balance = vtWalletBalance,
        .wallet_transactions = vtWalletTransactions,
        .wallet_receive_address = vtWalletReceiveAddress,
        .wallet_send = vtWalletSend,
        .wallet_encrypt = vtWalletEncrypt,
        .wallet_unlock = vtWalletUnlock,
        .wallet_lock = vtWalletLock,
        .wallet_backup = vtWalletBackup,
        .wallet_restore_file_offline = vtWalletRestoreFileOffline,
        .warmup_probe_method = vtWarmupProbeMethod,
        .warmup_phase_from_log = vtWarmupPhaseFromLog,
    };

    fn vtCoinName(_: *anyopaque) []const u8 {
        return coin_name;
    }
    fn vtCoinDescription(_: *anyopaque) []const u8 {
        return coin_description;
    }
    fn vtCoinNameAbbrev(_: *anyopaque) []const u8 {
        return coin_name_abbrev;
    }
    fn vtCoinColor(_: *anyopaque) []const u8 {
        return coin_color;
    }
    fn vtTipAddress(_: *anyopaque) []const u8 {
        return tip_address;
    }
    /// "Spider" in `wordmark_head_color` (white), "Byte" in `coin_color`.
    fn vtWordmark(_: *anyopaque) Coin.Wordmark {
        return .{ .split = wordmark_split, .alt_color = coin_color, .head_color = wordmark_head_color };
    }
    fn vtCoreVersion(_: *anyopaque) []const u8 {
        return core_version;
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
    fn vtWalletPath(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        home: []const u8,
    ) anyerror!?Coin.WalletFile {
        return walletPath(allocator, home);
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
        install_root: []const u8,
        home: []const u8,
    ) anyerror!void {
        _ = install_root;
        return prepareConf(allocator, io, home);
    }
    fn vtLaunchMode(_: *anyopaque) Coin.LaunchMode {
        return launchMode();
    }
    fn vtDaemonLogFile(_: *anyopaque) []const u8 {
        return daemonLogFile();
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
    fn vtWalletSecurityState(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) anyerror!models.WalletSecurity {
        return walletSecurityState(allocator, auth);
    }
    fn vtWalletBalance(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) anyerror!models.WalletBalance {
        return walletBalance(allocator, auth);
    }
    fn vtWalletTransactions(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        limit: usize,
    ) anyerror![]models.WalletTx {
        return walletTransactions(allocator, auth, limit);
    }
    fn vtWalletReceiveAddress(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        force_new: bool,
    ) anyerror![]const u8 {
        return receiveAddress(allocator, auth, force_new);
    }
    fn vtWalletSend(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        address: []const u8,
        amount: f64,
    ) anyerror!models.SendResult {
        return sendToAddress(allocator, auth, address, amount);
    }
    fn vtWalletEncrypt(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        passphrase: []const u8,
    ) anyerror!void {
        return walletEncrypt(allocator, auth, passphrase);
    }
    fn vtWalletUnlock(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        passphrase: []const u8,
        staking: bool,
    ) anyerror!void {
        return walletUnlock(allocator, auth, passphrase, staking);
    }
    fn vtWalletLock(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) anyerror!void {
        return walletLock(allocator, auth);
    }
    fn vtWalletBackup(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        dest_path: []const u8,
    ) anyerror!void {
        return walletBackup(allocator, auth, dest_path);
    }
    fn vtWalletRestoreFileOffline(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        home: []const u8,
        src_path: []const u8,
    ) anyerror!void {
        return walletRestoreFileOffline(allocator, home, src_path);
    }
    fn vtWarmupProbeMethod(_: *anyopaque) []const u8 {
        return warmupProbeMethod();
    }
    fn vtWarmupPhaseFromLog(_: *anyopaque, tail: []const u8) models.LoadingPhase {
        return warmupPhaseFromLog(tail);
    }
};

test "parses getinfo into normalized BlockchainState fields" {
    const allocator = std.testing.allocator;

    // Canned daemon reply — proves the getinfo parse + the chain/blocks mapping
    // without a running spiderbyted. (network_height/synced are derived from
    // getpeerinfo at runtime and exercised by syncStatus's own test.)
    const raw =
        \\{"result":{"version":"v7.0.0.1","protocolversion":60007,"walletversion":60000,
        \\"balance":12.5,"newmint":0.0,"stake":3.0,"blocks":1234567,"moneysupply":4000000.0,
        \\"connections":16,"difficulty":0.0008,"testnet":false,"keypoolsize":101},
        \\"error":null,"id":"boxwallet"}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(SpiderByte.SpiderByteGetInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    try std.testing.expectEqual(@as(i64, 1234567), r.blocks);
    try std.testing.expectEqual(@as(i64, 16), r.connections);
    try std.testing.expect(!r.testnet);
    // Unencrypted wallet: getinfo omits unlocked_until → null.
    try std.testing.expect(r.unlocked_until == null);
}

test "parses the tip block's time from a getblock reply" {
    const allocator = std.testing.allocator;

    // Canned getblock reply — proves the tip-time parse (feeding the "behind by …"
    // readout) without a running spiderbyted. The many other verbose getblock
    // fields are dropped via ignore_unknown_fields.
    const raw =
        \\{"result":{"hash":"00000000abc","height":1234567,"time":1893456000,
        \\"nonce":42,"bits":"1d00ffff","difficulty":0.0008},"error":null,"id":"boxwallet"}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(SpiderByte.SpiderByteBlock),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 1893456000), parsed.value.result.?.time);
}

test "syncStatus derives synced + progress from local vs network height" {
    // Fully caught up to (or past) the peer tip → synced, ~full progress.
    {
        const s = SpiderByte.syncStatus(1_000_000, 1_000_000);
        try std.testing.expect(s.synced);
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), s.progress, 1e-9);
    }
    // Half-way through a sync → not synced, 0.5 progress.
    {
        const s = SpiderByte.syncStatus(500_000, 1_000_000);
        try std.testing.expect(!s.synced);
        try std.testing.expectApproxEqAbs(@as(f64, 0.5), s.progress, 1e-9);
    }
    // No peers reported a height → tip unknown → not synced, 0 progress (not a
    // false 100%).
    {
        const s = SpiderByte.syncStatus(500_000, 0);
        try std.testing.expect(!s.synced);
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), s.progress, 1e-9);
    }
}

test "staking_active is derived from the wallet lock state (no staking RPC)" {
    // Unencrypted (absent) or unlocked (>0) → minting automatically; locked (0) →
    // not staking.
    try std.testing.expect(SpiderByte.stakingFromUnlockedUntil(null));
    try std.testing.expect(SpiderByte.stakingFromUnlockedUntil(1_893_456_000));
    try std.testing.expect(!SpiderByte.stakingFromUnlockedUntil(0));
}

test "maps getinfo unlocked_until to the wallet security state" {
    // NovaCoin-style: absent → unencrypted, 0 → locked, positive → unlocked.
    try std.testing.expectEqual(models.WalletSecurity.unencrypted, SpiderByte.securityFromUnlockedUntil(null));
    try std.testing.expectEqual(models.WalletSecurity.locked, SpiderByte.securityFromUnlockedUntil(0));
    try std.testing.expectEqual(models.WalletSecurity.unlocked, SpiderByte.securityFromUnlockedUntil(1_893_456_000));
}

test "normalizeVersion strips the daemon's leading v to match core_version" {
    const allocator = std.testing.allocator;
    const v = try SpiderByte.normalizeVersion(allocator, "v7.0.0.1");
    defer allocator.free(v);
    try std.testing.expectEqualStrings("7.0.0.1", v);
    try std.testing.expectEqualStrings(SpiderByte.core_version, v);

    // A version without the prefix is passed through unchanged.
    const w = try SpiderByte.normalizeVersion(allocator, "7.0.0.1");
    defer allocator.free(w);
    try std.testing.expectEqualStrings("7.0.0.1", w);
}

test "maps getinfo balance to available + total (stake/newmint pending)" {
    const allocator = std.testing.allocator;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(SpiderByte.SpiderByteGetInfo),
        allocator,
        "{\"result\":{\"balance\":12.5,\"stake\":3.0,\"newmint\":1.5,\"unlocked_until\":0},\"error\":null,\"id\":\"boxwallet\"}",
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    const bal = models.WalletBalance.fromParts(r.balance, r.stake, r.newmint);
    // available = confirmed; total adds the staking + freshly-minted (immature) coins.
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), bal.available, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 17.0), bal.total, 1e-9);
    try std.testing.expect(bal.hasPending());
}

test "directionFromCategory maps listtransactions categories to normalized direction" {
    try std.testing.expectEqual(models.TxDirection.received, SpiderByte.directionFromCategory("receive").?);
    try std.testing.expectEqual(models.TxDirection.sent, SpiderByte.directionFromCategory("send").?);
    // "generate"/"immature"/"orphan" all come from the daemon's combined
    // IsCoinBase()||IsCoinStake() check — SpiderByte never mines, so all three
    // represent a stake reward at some maturity stage.
    try std.testing.expectEqual(models.TxDirection.stake, SpiderByte.directionFromCategory("generate").?);
    try std.testing.expectEqual(models.TxDirection.stake, SpiderByte.directionFromCategory("immature").?);
    try std.testing.expectEqual(models.TxDirection.stake, SpiderByte.directionFromCategory("orphan").?);
    // "move" (a transfer between named accounts BoxWallet never uses) has no
    // direction — the caller drops it.
    try std.testing.expect(SpiderByte.directionFromCategory("move") == null);
    try std.testing.expect(SpiderByte.directionFromCategory("something-unknown") == null);
}

test "mapTransactions reverses to newest-first, maps categories, drops move, and takes abs(amount)" {
    const allocator = std.testing.allocator;

    // The daemon returns oldest-to-newest; a "send" amount already arrives
    // negated (ValueFromAmount(-s.second) in rpcwallet.cpp).
    const raw = [_]SpiderByte.SpiderByteTx{
        .{ .category = "generate", .amount = 5.0, .time = 100, .confirmations = 500 }, // oldest: a mature stake reward
        .{ .category = "receive", .amount = 2.5, .time = 200, .confirmations = 10 },
        .{ .category = "move", .amount = 1.0, .time = 250, .confirmations = 10 }, // dropped: internal account transfer
        .{ .category = "send", .amount = -1.25, .time = 300, .confirmations = 1 }, // newest
    };

    const txs = try SpiderByte.mapTransactions(allocator, &raw);
    defer allocator.free(txs);

    // "move" dropped, so 4 raw entries → 3 mapped, newest-first.
    try std.testing.expectEqual(@as(usize, 3), txs.len);

    try std.testing.expectEqual(models.TxDirection.sent, txs[0].direction);
    try std.testing.expectApproxEqAbs(@as(f64, 1.25), txs[0].amount, 1e-9);
    try std.testing.expectEqual(@as(i64, 300), txs[0].time);
    try std.testing.expectEqual(@as(i64, 1), txs[0].confirmations);

    try std.testing.expectEqual(models.TxDirection.received, txs[1].direction);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), txs[1].amount, 1e-9);
    try std.testing.expectEqual(@as(i64, 200), txs[1].time);
    try std.testing.expectEqual(@as(i64, 10), txs[1].confirmations);

    try std.testing.expectEqual(models.TxDirection.stake, txs[2].direction);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), txs[2].amount, 1e-9);
    try std.testing.expectEqual(@as(i64, 100), txs[2].time);
    try std.testing.expectEqual(@as(i64, 500), txs[2].confirmations);
}

test "parses a listtransactions reply into SpiderByteTx entries" {
    const allocator = std.testing.allocator;

    // A canned reply shaped like the real daemon's listtransactions output
    // (rpcwallet.cpp), with the extra fields BoxWallet doesn't use
    // (account/address/txid/...) dropped via ignore_unknown_fields.
    const raw =
        \\{"result":[
        \\{"account":"","category":"generate","amount":5.0,"confirmations":120,"time":100},
        \\{"account":"","address":"S1abc","category":"receive","amount":2.5,"confirmations":10,"time":200}
        \\],"error":null,"id":"boxwallet"}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse([]SpiderByte.SpiderByteTx),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expectEqualStrings("generate", r[0].category);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), r[0].amount, 1e-9);
    try std.testing.expectEqual(@as(i64, 100), r[0].time);
    try std.testing.expectEqual(@as(i64, 120), r[0].confirmations);
    try std.testing.expectEqualStrings("receive", r[1].category);
}

test "coin vtable exposes wallet_transactions for SpiderByte" {
    var spb: SpiderByte = .{};
    const c = spb.coin();
    try std.testing.expect(c.supportsTransactions());
}

test "receiveAddressMethod picks getaccountaddress vs getnewaddress" {
    // Stable "current" address for the one-time initial fetch...
    try std.testing.expectEqualStrings("getaccountaddress", SpiderByte.receiveAddressMethod(false));
    // ...a fresh mint only for an explicit user-requested rotation.
    try std.testing.expectEqualStrings("getnewaddress", SpiderByte.receiveAddressMethod(true));
}

test "parses a getaccountaddress/getnewaddress reply (bare JSON string result)" {
    const allocator = std.testing.allocator;

    // Both RPCs return the address as a bare string result, same shape as
    // getblockhash (see the tipTime test above).
    const raw = "{\"result\":\"XmM8G6mfvJvqfxLnf78EE7oGDwtvfxKz9y\",\"error\":null,\"id\":\"boxwallet\"}";

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse([]const u8),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("XmM8G6mfvJvqfxLnf78EE7oGDwtvfxKz9y", parsed.value.result.?);
}

test "coin vtable exposes wallet_receive_address for SpiderByte" {
    var spb: SpiderByte = .{};
    const c = spb.coin();
    try std.testing.expect(c.supportsReceiveAddress());
}

test "formatSendAmount is a fixed 8dp decimal, never scientific notation" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0.10000000", SpiderByte.formatSendAmount(&buf, 0.1));
    try std.testing.expectEqualStrings("1.50000000", SpiderByte.formatSendAmount(&buf, 1.5));
    try std.testing.expectEqualStrings("0.00000000", SpiderByte.formatSendAmount(&buf, 0));
    try std.testing.expectEqualStrings("1234567.00000000", SpiderByte.formatSendAmount(&buf, 1_234_567));
}

test "parses a sendtoaddress success reply (bare txid string, error null)" {
    const allocator = std.testing.allocator;
    const raw = "{\"result\":\"a1b2c3d4e5f6\",\"error\":null,\"id\":\"boxwallet\"}";

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse([]const u8),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("a1b2c3d4e5f6", parsed.value.result.?);
    try std.testing.expect(parsed.value.@"error" == null);
}

test "parses a sendtoaddress failure reply (result null, error object with the daemon's real message)" {
    const allocator = std.testing.allocator;
    // Matches the real daemon's shape (rpcwallet.cpp/bitcoinrpc.cpp): a
    // rejected send comes back as a proper JSON-RPC error, not a generic
    // failure — this is the exact case the new `models.RpcError` plumbing
    // exists to preserve.
    const raw = "{\"result\":null,\"error\":{\"code\":-4,\"message\":\"Insufficient funds\"},\"id\":\"boxwallet\"}";

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse([]const u8),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.value.result == null);
    try std.testing.expectEqual(@as(i64, -4), parsed.value.@"error".?.code);
    try std.testing.expectEqualStrings("Insufficient funds", parsed.value.@"error".?.message);
}

test "coin vtable exposes wallet_send for SpiderByte" {
    var spb: SpiderByte = .{};
    const c = spb.coin();
    try std.testing.expect(c.supportsSend());
}

test "no upstream bundle: install is unsupported" {
    // SpiderByte publishes no per-platform binary, so download is null and install
    // surfaces UnsupportedPlatform on every target.
    try std.testing.expectError(error.UnsupportedPlatform, SpiderByte.install(std.testing.allocator, "irrelevant", null));
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("spiderbyted.exe", SpiderByte.daemon_file);
    } else {
        try std.testing.expectEqualStrings("spiderbyted", SpiderByte.daemon_file);
    }
}

test "coin vtable dispatches to SpiderByte metadata" {
    var spb: SpiderByte = .{};
    const c = spb.coin();
    try std.testing.expectEqualStrings("SpiderByte", c.coinName());
    try std.testing.expectEqualStrings("SPB", c.coinNameAbbrev());
    try std.testing.expectEqualStrings("#f72585", c.coinColor());
    try std.testing.expect(c.isProofOfStake());
    try std.testing.expectEqualStrings("SpiderByte.conf", c.confFile());
    try std.testing.expectEqualStrings("spiderbyted", c.daemonFile());
    try std.testing.expectEqualStrings("44350", c.rpcDefaultPort());
    // Daemon auto-loads its own wallet.dat → no explicit create/load step.
    try std.testing.expect(!c.needsWallet());
    // Wallet is manageable over RPC (the `w` menu) and reports a balance.
    try std.testing.expect(c.supportsWallet());
    try std.testing.expect(c.supportsBalance());
    // Binary backup (backupwallet) is offered; there's no importwallet, so file
    // import is not.
    try std.testing.expect(c.supportsWalletBackup());
    try std.testing.expect(!c.supportsWalletImport());
}

test "two-tone wordmark splits SpiderByte into a white head and brand tail" {
    var spb: SpiderByte = .{};
    const wm = spb.coin().wordmark().?;
    // Split after "Spider" so the head is "Spider" and the tail "Byte".
    try std.testing.expectEqual(@as(usize, 6), wm.split);
    try std.testing.expectEqualStrings("Spider", SpiderByte.coin_name[0..wm.split]);
    try std.testing.expectEqualStrings("Byte", SpiderByte.coin_name[wm.split..]);
    // Head is the white override; tail is the brand colour.
    try std.testing.expectEqualStrings("#ffffff", wm.head_color.?);
    try std.testing.expectEqualStrings("#f72585", wm.alt_color);
}

test "walletRestoreFileOffline swaps a backup into place, preserving the old wallet" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    // A fake home (relative to cwd) whose .SpiderByte data dir we can inspect.
    const home = "test-spb-restore-home";
    cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, home) catch {};

    const data_dir = try SpiderByte.dataDir(allocator, home);
    defer allocator.free(data_dir);
    var dd = try cwd.createDirPathOpen(io, data_dir, .{});
    defer dd.close(io);

    // Seed an existing (current) wallet.dat and a separate backup to restore.
    try dd.writeFile(io, .{ .sub_path = "wallet.dat", .data = "OLD-WALLET" });
    var hd = try cwd.createDirPathOpen(io, home, .{});
    defer hd.close(io);
    try hd.writeFile(io, .{ .sub_path = "backup.dat", .data = "NEW-WALLET" });
    const src = try std.fs.path.join(allocator, &.{ home, "backup.dat" });
    defer allocator.free(src);

    try SpiderByte.walletRestoreFileOffline(allocator, home, src);

    // Destination now holds the backup's contents…
    {
        const got = try dd.readFileAlloc(io, "wallet.dat", allocator, .limited(64));
        defer allocator.free(got);
        try std.testing.expectEqualStrings("NEW-WALLET", got);
    }

    // …and the previous wallet.dat was preserved as a wallet.dat.bak-* sibling.
    var idir = try cwd.openDir(io, data_dir, .{ .iterate = true });
    defer idir.close(io);
    var it = idir.iterate();
    var found_bak = false;
    while (try it.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "wallet.dat.bak-")) {
            const old = try dd.readFileAlloc(io, entry.name, allocator, .limited(64));
            defer allocator.free(old);
            try std.testing.expectEqualStrings("OLD-WALLET", old);
            found_bak = true;
        }
    }
    try std.testing.expect(found_bak);
}

test "walletRestoreFileOffline restores into a fresh data dir (no prior wallet)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const home = "test-spb-restore-fresh";
    cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, home) catch {};

    const data_dir = try SpiderByte.dataDir(allocator, home);
    defer allocator.free(data_dir);
    var dd = try cwd.createDirPathOpen(io, data_dir, .{});
    defer dd.close(io);

    var hd = try cwd.createDirPathOpen(io, home, .{});
    defer hd.close(io);
    try hd.writeFile(io, .{ .sub_path = "backup.dat", .data = "RESTORED" });
    const src = try std.fs.path.join(allocator, &.{ home, "backup.dat" });
    defer allocator.free(src);

    // No current wallet.dat present — restore should just drop the backup in.
    try SpiderByte.walletRestoreFileOffline(allocator, home, src);

    const got = try dd.readFileAlloc(io, "wallet.dat", allocator, .limited(64));
    defer allocator.free(got);
    try std.testing.expectEqualStrings("RESTORED", got);
}

test "walletRestoreFileOffline rejects an empty source before clobbering the wallet" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const home = "test-spb-restore-empty";
    cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, home) catch {};

    const data_dir = try SpiderByte.dataDir(allocator, home);
    defer allocator.free(data_dir);
    var dd = try cwd.createDirPathOpen(io, data_dir, .{});
    defer dd.close(io);
    try dd.writeFile(io, .{ .sub_path = "wallet.dat", .data = "KEEP-ME" });

    // An empty backup is refused outright — the current wallet must be untouched.
    var hd = try cwd.createDirPathOpen(io, home, .{});
    defer hd.close(io);
    try hd.writeFile(io, .{ .sub_path = "empty.dat", .data = "" });
    const src = try std.fs.path.join(allocator, &.{ home, "empty.dat" });
    defer allocator.free(src);

    try std.testing.expectError(error.EmptyWalletFile, SpiderByte.walletRestoreFileOffline(allocator, home, src));

    const still = try dd.readFileAlloc(io, "wallet.dat", allocator, .limited(64));
    defer allocator.free(still);
    try std.testing.expectEqualStrings("KEEP-ME", still);
}

test "coin vtable exposes the offline wallet-file restore" {
    var spb: SpiderByte = .{};
    const c = spb.coin();
    // SpiderByte offers the offline file swap but not the RPC importwallet path.
    try std.testing.expect(c.supportsWalletRestoreOffline());
    try std.testing.expect(!c.supportsWalletImport());
    // Backup is still offered (binary backupwallet copy).
    try std.testing.expect(c.supportsWalletBackup());
}

test "walletPath points at the NovaCoin-era wallet.dat under the data dir" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var spb: SpiderByte = .{};
    const wf = (try spb.coin().walletPath(allocator, "/home/alice")).?;
    defer allocator.free(wf.path);
    try std.testing.expectEqualStrings("/home/alice/.SpiderByte/wallet.dat", wf.path);
    try std.testing.expect(wf.keys == null);
}

test "warmupPhaseFromLog reports loading only while the block index is being read" {
    // Mid-load: the daemon has logged the start marker and nothing since (it's
    // blocked reading blkindex.dat for minutes) → still loading.
    const mid_load =
        \\SpiderByte version v7.0.0.1
        \\Default data directory /home/alice/.SpiderByte
        \\Loading block index...
    ;
    try std.testing.expectEqual(models.LoadingPhase.loading_block_index, SpiderByte.warmupPhaseFromLog(mid_load));

    // Realistic mid-load tail: the RPC is up during the load, so each failed
    // BoxWallet poll appends a getinfo access line after the start marker. The
    // marker must still win over that spam (the caller sizes the tail for it).
    const mid_load_spam =
        \\Loading block index...
        \\ThreadRPCServer method=getinfo
        \\ThreadRPCServer method=getinfo
        \\ThreadRPCServer method=getinfo
    ;
    try std.testing.expectEqual(models.LoadingPhase.loading_block_index, SpiderByte.warmupPhaseFromLog(mid_load_spam));

    // Init finished: "Done loading" follows the load marker → not loading (the RPC
    // is about to come up, so the normal getinfo poll takes over).
    const done =
        \\Loading block index...
        \\LoadBlockIndex(): hashBestChain=7a69a024 height=10760482
        \\Verifying last 2500 blocks at level 1
        \\ block index          398473ms
        \\Loading wallet...
        \\Done loading
    ;
    try std.testing.expectEqual(models.LoadingPhase.none, SpiderByte.warmupPhaseFromLog(done));

    // A long-running node's log tail (the start marker has scrolled off) → not a
    // fresh load, so a transient RPC blip can't masquerade as one.
    const running =
        \\received block 0000abcd
        \\UpdateTip: new best=0000abcd height=10760500
    ;
    try std.testing.expectEqual(models.LoadingPhase.none, SpiderByte.warmupPhaseFromLog(running));

    // Empty tail (no debug.log yet) → nothing to report.
    try std.testing.expectEqual(models.LoadingPhase.none, SpiderByte.warmupPhaseFromLog(""));
}

test "coin vtable routes warmupPhaseFromLog through to the SpiderByte classifier" {
    var spb: SpiderByte = .{};
    const c = spb.coin();
    try std.testing.expectEqual(
        models.LoadingPhase.loading_block_index,
        c.warmupPhaseFromLog("Loading block index...\n"),
    );
    // A coin that doesn't wire the hook stays `.none` — verified here so the
    // default path (most coins) is covered too.
    try std.testing.expectEqual(models.LoadingPhase.none, c.warmupPhaseFromLog("random log line\n"));
}
