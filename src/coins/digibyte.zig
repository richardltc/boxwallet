const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const rpc = @import("../rpc.zig");
const install_mod = @import("../install.zig");
const conf = @import("../conf.zig");
const Coin = @import("../coin.zig").Coin;

/// DigiByte backend. Constants lifted from
/// `cmd/cli/cmd/coins/digibyte/digibyte.go`.
///
/// DigiByte is a bitcoin-core fork, so it shares the streaming install path and
/// `key=value` conf with Nexa/Divi. The one structural difference is the RPC
/// surface: DigiByte dropped `getinfo` in core 6.16.0, so the live status is
/// assembled from two calls — `getblockchaininfo` (chain/height/sync) and
/// `getnetworkinfo` (peer count) — rather than a single `getinfo`.
pub const DigiByte = struct {
    /// Whether the coin is exposed in the nav. False keeps it out of the left
    /// bar entirely (registered but hidden) until it's ready for users.
    pub const live = true;
    pub const coin_name = "DigiByte";
    pub const coin_name_abbrev = "DGB";
    /// One-line description shown under the coin name on the detail pane.
    pub const coin_description = "Fast, secure UTXO blockchain with five mining algorithms.";
    /// DigiByte brand colour (`#RRGGBB`), for tinting the coin in the frontend.
    pub const coin_color = "#0066CC";
    /// This coin's id on the price host, for the USD quote beside its
    /// balance (see `src/price.zig`).
    pub const price_id = "digibyte";
    /// Donation address for BoxWallet development, in DigiByte's own
    /// currency.
    pub const tip_address = "dgb1qqhd2rgrt4059vzz94yaezc9m03wgqq8my9dp57";
    /// DigiByte is proof-of-work (multi-algo) — no wallet staking.
    pub const proof_of_stake = false;
    pub const conf_file = "digibyte.conf";
    pub const home_dir = ".digibyte";
    pub const home_dir_win = "DIGIBYTE";
    /// macOS data dir name. DigiByte Core: `~/Library/Application Support/DigiByte`. Unreachable
    /// today — DigiByte ships no macOS daemon (GUI-only `.app`), so `download` is
    /// null there — but stated correctly so it holds if that changes.
    pub const home_dir_mac: ?[]const u8 = "DigiByte";
    pub const rpc_default_username = "digibyterpc";
    pub const rpc_default_port = "14022";
    // Latest 8.x stable release. The Go reference still pins 7.17.2, but BoxWallet
    // tracks the current stable line. The trade-off of moving to 8.x is platform
    // reach: 8.x publishes no streamable daemon bundle outside Linux — Windows
    // ships solely an NSIS `setup.exe` (not an archive the installer can stream),
    // and the macOS `.zip` carries only the DigiByte-Qt GUI app (no
    // `digibyted`/cli/tx). So only Linux resolves a usable download below; Windows
    // and macOS are null (`error.UnsupportedPlatform` at install time).
    pub const core_version = "9.26.4";

    // Binary names. Windows appends `.exe`; Linux/macOS use the bare names. The
    // per-target name is what `isInstalled`, the daemon launcher, and the promote
    // list all use, so a Windows build looks for `digibyted.exe` and a POSIX build
    // for `digibyted`.
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    pub const daemon_file = "digibyted" ++ exe_suffix;
    pub const cli_file = "digibyte-cli" ++ exe_suffix;
    pub const tx_file = "digibyte-tx" ++ exe_suffix;

    // Download host. The Linux bundles wrap their executables in
    // `digibyte-<ver>/bin/` (verified against the 8.26.2 tar.gz, x86_64 + aarch64).
    const download_base = "https://github.com/DigiByte-Core/digibyte/releases/download/v" ++ core_version ++ "/";

    /// The download URL + archive format for the build target, or null where
    /// DigiByte publishes no streamable daemon bundle. Selected at comptime from
    /// the OS/arch. Only Linux x86_64/aarch64 ship a usable `.tar.gz`; everything
    /// else is null:
    ///   - Windows ships only an NSIS `setup.exe`, which the installer can't stream.
    ///   - macOS ships only a GUI-only `DigiByte-Qt.app` zip (no daemon/cli/tx).
    ///   - Linux arm32/386 have no published build.
    const download: ?install_mod.Download = switch (builtin.os.tag) {
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => .{ .url = download_base ++ "digibyte-" ++ core_version ++ "-x86_64-linux-gnu.tar.gz", .format = .tar_gz },
            .aarch64 => .{ .url = download_base ++ "digibyte-" ++ core_version ++ "-aarch64-linux-gnu.tar.gz", .format = .tar_gz },
            else => null,
        },
        else => null,
    };

    // Layout inside the archive: keep only the daemon/cli/tx binaries (from
    // `bin/`) at the install root; the whole `digibyte-<ver>/` tree is discarded
    // afterwards. Matches the Go installer.
    const extracted_dir = "digibyte-" ++ core_version;
    const bin_subdir = "bin";
    const promote_files = [_][]const u8{ daemon_file, cli_file, tx_file };

    // Temp file the download streams to. Keyed off the daemon name so a
    // concurrent install of another coin into the same `~/.boxwallet` root uses
    // a different scratch file and the two never collide.
    pub const scratch_file = ".boxwallet-" ++ daemon_file ++ ".part";

    /// Build the type-erased `Coin` handle for this instance.
    pub fn coin(self: *DigiByte) Coin {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Live `getblockchaininfo`, normalized for a frontend. DigiByte reports
    /// `verificationprogress`, so "synced" is derived from it exactly as for Nexa
    /// (Go's `BlockchainIsSynced` => progress > 0.99999).
    pub fn blockchainState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.BlockchainState {
        var parsed = try rpc.callParsed(models.DgbBlockchainInfo, allocator, auth, "getblockchaininfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return .{
            .chain = try allocator.dupe(u8, r.chain),
            .blocks = r.blocks,
            .headers = r.headers,
            .verification_progress = r.verificationprogress,
            .synced = r.verificationprogress > 0.99999,
            // Network tip from peers, so the frontend's Headers bar can fill
            // toward it. A getpeerinfo hiccup just leaves it 0 (unknown).
            .network_height = rpc.networkHeight(allocator, auth) catch 0,
            // Tip block timestamp, so the frontend can show how far behind in
            // wall-clock time the chain is while validating. Prefer the exact
            // tip `time`; fall back to `mediantime` when the daemon omits it.
            .tip_time = if (r.time > 0) r.time else r.mediantime,
        };
    }

    /// Live status, normalized for a frontend. DigiByte has no `getinfo`, so the
    /// block height comes from `getblockchaininfo` and the peer count from
    /// `getnetworkinfo`. DigiByte is proof-of-work, so `staking_active` is always
    /// false.
    pub fn daemonInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.DaemonInfo {
        var bc = try rpc.callParsed(models.DgbBlockchainInfo, allocator, auth, "getblockchaininfo");
        defer bc.deinit();
        const b = bc.value.result orelse return error.EmptyRpcResult;

        var net = try rpc.callParsed(models.DgbNetworkInfo, allocator, auth, "getnetworkinfo");
        defer net.deinit();
        const n = net.value.result orelse return error.EmptyRpcResult;

        // `getnetworkinfo`'s numeric CLIENT_VERSION → dotted string, owned by
        // `allocator` so it outlives `net`'s deinit. DigiByte's CLIENT_VERSION
        // carries a legacy leading-0 major (82602 → "0.8.26.2"), but the release is
        // branded/distributed as "8.26.2" (== core_version). Drop the "0." so the
        // Running line and the on-disk version marker line up with the bundled
        // version — otherwise the same release reads as an endless "update available".
        const full = try models.clientVersionString(allocator, n.version);
        const version = if (std.mem.startsWith(u8, full, "0.")) blk: {
            defer allocator.free(full);
            break :blk try allocator.dupe(u8, full[2..]);
        } else full;

        return .{
            .blocks = b.blocks,
            .connections = n.connections,
            .staking_active = false,
            .version = version,
        };
    }

    /// The daemon's default data directory (`~/.digibyte`), where `digibyte.conf`
    /// lives.
    pub fn dataDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        return conf.dataDir(allocator, home, home_dir, home_dir_win, home_dir_mac);
    }

    /// The managed wallet's on-disk location — the bitcoin-core 0.21+ wallet
    /// directory `<datadir>/wallets/BoxWallet` (holding `wallet.dat`), created by
    /// `ensureWallet`. Caller owns the returned strings.
    pub fn walletPath(allocator: std.mem.Allocator, home: []const u8) !?Coin.WalletFile {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        return .{ .path = try std.fs.path.join(allocator, &.{ data_dir, "wallets", "BoxWallet" }) };
    }

    /// True if `digibyted` (`digibyted.exe` on Windows) is already present under
    /// `install_root`.
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, daemon_file);
    }

    /// Download + unarchive the DigiByte daemon files into `install_root`,
    /// optionally reporting download/extract progress.
    ///
    /// Extracts the versioned wrapper dir intact, then `promoteAndTidy` lifts the
    /// daemon/cli/tx binaries to the install root and removes the wrapper,
    /// leaving `digibyted` exactly where `isInstalled` looks for it.
    pub fn install(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        const dl = download orelse return error.UnsupportedPlatform;
        try install_mod.downloadAndExtract(allocator, dl.url, dl.format, install_root, scratch_file, 0, progress);
        try install_mod.promoteAndTidy(allocator, install_root, extracted_dir, bin_subdir, &promote_files);
    }

    /// Ensure `digibyte.conf` carries the RPC creds (and `server=1`/`daemon=1`/
    /// `rpcport`) BoxWallet needs before the daemon reads it; existing values are
    /// kept. A standard bitcoin-derived `key=value` conf.
    ///
    /// On top of the shared creds, DigiByte's DigiDollar feature needs the
    /// transaction index and the DigiDollar subsystem switched on (`txindex=1`,
    /// `digidollar=1`). These are **DigiByte-only** — no other BoxWallet coin
    /// supports DigiDollar — so they're set here in the coin file rather than in
    /// the shared conf helper, and only added when absent so a user's explicit
    /// choice (even `=0`) survives.
    pub fn prepareConf(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        _ = try conf.populate(allocator, io, data_dir, conf_file, rpc_default_username, rpc_default_port);
        try ensureEnabled(allocator, io, data_dir, "txindex");
        try ensureEnabled(allocator, io, data_dir, "digidollar");
    }

    /// Append `key=1` to `digibyte.conf` only if the key isn't already present,
    /// leaving any existing value (including an explicit `key=0`) untouched.
    /// Idempotent — a second prepare reads the key back and writes nothing.
    fn ensureEnabled(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8, key: []const u8) !void {
        if (try conf.readValue(allocator, io, data_dir, conf_file, key)) |existing| {
            allocator.free(existing);
            return;
        }
        try conf.setValue(allocator, io, data_dir, conf_file, key, "1");
    }

    /// DigiByte is a bitcoin-derived daemon: it forks itself into the background
    /// with `-daemon` on POSIX, but runs in the foreground on Windows.
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

    /// Ask digibyted to shut down via the JSON-RPC `stop`.
    pub fn requestStop(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        const reply = try rpc.call(allocator, auth, "stop");
        allocator.free(reply);
    }

    /// DigiByte 8.x (Bitcoin Core 26) doesn't auto-create a wallet, so address /
    /// balance RPCs have none to act on until one exists. Load-or-create a wallet
    /// named "BoxWallet" once the daemon is up.
    pub fn ensureWallet(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        return rpc.ensureWallet(allocator, auth, "BoxWallet");
    }

    /// Read the wallet's security state from `getwalletinfo`. DigiByte is
    /// bitcoin-core style: `unlocked_until` is **absent** on an unencrypted wallet,
    /// `0` when locked, and a positive unlock timestamp otherwise.
    pub fn walletSecurityState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.WalletSecurity {
        var parsed = try rpc.callParsed(models.DgbWalletInfo, allocator, auth, "getwalletinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return securityFromUnlockedUntil(r.unlocked_until);
    }

    /// Read the wallet's balances from `getwalletinfo`. `available` is the
    /// confirmed spendable `balance`; `total` adds the mempool
    /// (`unconfirmed_balance`) and maturing (`immature_balance`) funds, so it
    /// reflects incoming money the moment it's seen.
    pub fn walletBalance(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.WalletBalance {
        var parsed = try rpc.callParsed(models.DgbWalletInfo, allocator, auth, "getwalletinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return models.WalletBalance.fromParts(r.balance, r.unconfirmed_balance, r.immature_balance);
    }

    /// Map a bitcoin-core `unlocked_until` (absent/0/positive) to the normalized
    /// `WalletSecurity`. Shared by the parse path and its unit test.
    fn securityFromUnlockedUntil(unlocked_until: ?i64) models.WalletSecurity {
        const u = unlocked_until orelse return .unencrypted;
        if (u == 0) return .locked;
        return .unlocked;
    }

    /// Map DigiByte's `listtransactions` `category` to the normalized direction.
    /// `"generate"`/`"immature"`/`"orphan"` are coinbase (mined) rewards at their
    /// maturity stages — the normalized `.stake` covers a mined block reward on a
    /// proof-of-work coin (see `models.TxDirection`). Anything else has no
    /// direction (null; the caller drops it).
    fn directionFromCategory(category: []const u8) ?models.TxDirection {
        if (std.mem.eql(u8, category, "receive")) return .received;
        if (std.mem.eql(u8, category, "send")) return .sent;
        if (std.mem.eql(u8, category, "generate") or
            std.mem.eql(u8, category, "immature") or
            std.mem.eql(u8, category, "orphan")) return .stake;
        return null;
    }

    /// The wallet's most recent transactions, newest-first — the shared
    /// bitcoin-family `listtransactions` flow with DigiByte's category map.
    pub fn walletTransactions(allocator: std.mem.Allocator, auth: models.CoinAuth, limit: usize) ![]models.WalletTx {
        return rpc.walletTransactions(allocator, auth, limit, directionFromCategory);
    }

    /// Marker label that tracks the wallet's current receive address. DigiByte's
    /// Core-26 base removed the accounts API (and with it any stable "current
    /// address" RPC), so the shared label flow keeps exactly one address under
    /// this label — see `rpc.receiveAddressLabeled`.
    const receive_label = "boxwallet-receive";

    /// The wallet's receive address: the labelled current one (minted on first
    /// use), or a fresh mint on an explicit user-requested rotation
    /// (`force_new` — only ever called on demand, never polled).
    pub fn receiveAddress(allocator: std.mem.Allocator, auth: models.CoinAuth, force_new: bool) ![]const u8 {
        return rpc.receiveAddressLabeled(allocator, auth, force_new, receive_label);
    }

    /// Send `amount` DGB to `address` via `sendtoaddress` (8-decimal amounts).
    /// The daemon's own rejection reason (invalid address, insufficient funds,
    /// locked wallet) rides back verbatim in the `SendResult`.
    pub fn sendToAddress(allocator: std.mem.Allocator, auth: models.CoinAuth, address: []const u8, amount: f64) !models.SendResult {
        return rpc.sendToAddress(allocator, auth, address, amount, 8);
    }

    /// Encrypt the wallet with `passphrase`. digibyted stops itself afterwards (the
    /// caller restarts it). The passphrase is JSON-escaped before splicing.
    pub fn walletEncrypt(allocator: std.mem.Allocator, auth: models.CoinAuth, passphrase: []const u8) !void {
        const pw = try rpc.jsonQuote(allocator, passphrase);
        defer allocator.free(pw);
        const params = try std.fmt.allocPrint(allocator, "[{s}]", .{pw});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "encryptwallet", params);
    }

    /// Unlock the wallet via `walletpassphrase`. DigiByte is proof-of-work, so the
    /// `staking` flag is irrelevant — a plain unlock with an indefinite timeout (0)
    /// is used either way.
    pub fn walletUnlock(allocator: std.mem.Allocator, auth: models.CoinAuth, passphrase: []const u8, _: bool) !void {
        const pw = try rpc.jsonQuote(allocator, passphrase);
        defer allocator.free(pw);
        const params = try std.fmt.allocPrint(allocator, "[{s},0]", .{pw});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "walletpassphrase", params);
    }

    /// Re-lock the wallet via `walletlock`.
    pub fn walletLock(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        return rpc.callExpectOk(allocator, auth, "walletlock", "[]");
    }

    /// DigiByte dropped `getinfo`, so probe `getnetworkinfo` for the daemon's
    /// warm-up phase (any supported method returns the "-28 in warm-up" reply).
    pub fn warmupProbeMethod() []const u8 {
        return "getnetworkinfo";
    }

    // --- DigiDollar (DD) ---------------------------------------------------
    //
    // DigiByte's chain-native USD stablecoin: DD is minted by locking DGB as
    // collateral at a chosen lock tier (longer lock → less collateral), moved
    // with its own wallet RPCs, and redeemed — burned to unlock the collateral —
    // once the tier's timelock expires. Shipped in core v9.26 behind a BIP9
    // deployment, so everything here also works *before* mainnet activation:
    // `ddInfo` reports the deployment status and the UI gates the actions on it.
    //
    // RPC surface verified against a live digibyted v9.26.4 (`help <rpc>` +
    // live replies, 2026-07-08). Amounts are **integer USD cents** on the wire
    // (10000 == $100.00) — integers are passed through verbatim so no float
    // ever touches a money amount we send. The oracle price rides in micro-USD
    // per DGB (1_000_000 == $1.00). Fees are paid in DGB, not DD.
    //
    // Pre-activation behaviour (verified): every DD RPC except
    // `getdigidollardeploymentinfo` errors with "DigiDollar is not yet active
    // on this blockchain" until the chain reaches the activation height — so
    // the frontend polls only the deployment info until `active` flips.

    /// Lock tiers, from the DigiDollar spec: tier index == the `tier` RPC
    /// argument; ratio is the required collateral in percent of the minted
    /// value at the oracle price.
    const dd_tiers = [_]Coin.StablecoinTier{
        .{ .tier = 0, .duration = "1 hour", .ratio_pct = 1000 },
        .{ .tier = 1, .duration = "30 days", .ratio_pct = 500 },
        .{ .tier = 2, .duration = "90 days", .ratio_pct = 400 },
        .{ .tier = 3, .duration = "180 days", .ratio_pct = 350 },
        .{ .tier = 4, .duration = "1 year", .ratio_pct = 300 },
        .{ .tier = 5, .duration = "2 years", .ratio_pct = 275 },
        .{ .tier = 6, .duration = "3 years", .ratio_pct = 250 },
        .{ .tier = 7, .duration = "5 years", .ratio_pct = 225 },
        .{ .tier = 8, .duration = "7 years", .ratio_pct = 212 },
        .{ .tier = 9, .duration = "10 years", .ratio_pct = 200 },
    };

    /// The stablecoin capability handed to the frontend — lights up the
    /// DigiDollar tab on DigiByte's detail pane. Mint bounds are the daemon's
    /// own consensus limits ($100 minimum, $100,000 maximum per mint).
    const stablecoin_cap: Coin.Stablecoin = .{
        .name = "DigiDollar",
        .symbol = "DD",
        .min_mint_cents = 10_000,
        .max_mint_cents = 10_000_000,
        // 15-second blocks, for the pre-activation countdown's wall-clock ETA.
        .block_seconds = 15,
        .tiers = &dd_tiers,
        .info = ddInfo,
        .balance = ddBalance,
        .receive_address = ddReceiveAddress,
        .transactions = ddTransactions,
        .positions = ddPositions,
        .estimate_collateral = ddEstimateCollateral,
        .mint = ddMint,
        .send = ddSend,
        .redeem = ddRedeem,
    };

    /// A JSON number that may arrive as an integer, float, or decimal string
    /// (the guide shows DGB figures as "decimal strings"), normalized to f64.
    fn jsonNumber(v: std.json.Value) ?f64 {
        return switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            .number_string, .string => |s| std.fmt.parseFloat(f64, s) catch null,
            else => null,
        };
    }

    /// Round a parsed JSON amount to integer cents. Cents fit f64 exactly up to
    /// 2^53 (~$90 quadrillion), far past any DD figure; `lossyCast` saturates
    /// rather than trapping on garbage input.
    fn centsFrom(v: f64) i64 {
        return std.math.lossyCast(i64, @round(v));
    }

    // Raw RPC reply shapes (DigiByte-specific, so they live here, not in
    // models.zig), the field subsets BoxWallet uses — verified against the
    // daemon's own `help <rpc>` documentation. All parsed with
    // `ignore_unknown_fields` and defaulted, so an omitted optional field
    // degrades to its zero value instead of failing the poll.

    const DdBalanceResult = struct {
        confirmed: f64 = 0,
        unconfirmed: f64 = 0,
    };

    const DdDeploymentInfo = struct {
        /// Whether DigiDollar is active right now — the authoritative gate.
        enabled: bool = false,
        /// BIP9 status: defined / started / locked_in / active / failed.
        status: []const u8 = "",
        /// Earliest height the deployment can activate at (always present).
        min_activation_height: i64 = 0,
        /// The actual activation height, present only once active.
        activation_height: ?i64 = null,
    };

    const DdOraclePrice = struct {
        price_micro_usd: f64 = 0,
        is_stale: bool = false,
    };

    const DdStats = struct {
        health_percentage: f64 = 0,
        total_collateral_dgb: f64 = 0,
        total_dd_supply: f64 = 0,
        /// Why minting is restricted: "none", "oracle_unavailable", or
        /// "err_active".
        minting_restricted_reason: []const u8 = "none",
    };

    const DdAddressEntry = struct {
        address: []const u8 = "",
    };

    const DdTxEntry = struct {
        category: []const u8 = "",
        amount: f64 = 0,
        time: i64 = 0,
        confirmations: i64 = 0,
    };

    const DdPositionEntry = struct {
        position_id: []const u8 = "",
        /// The DD minted by this position, in cents (what a redeem must burn).
        dd_minted: f64 = 0,
        lock_tier: i64 = 0,
        unlock_height: i64 = 0,
        /// pending / active / unlocked / redeemed.
        status: []const u8 = "",
        can_redeem: bool = false,
    };

    const DdEstimate = struct {
        /// Minimum consensus DGB collateral for the mint.
        required_dgb: f64 = 0,
        /// What the wallet's mint builder will actually lock (consensus
        /// minimum plus its safety margin) — the honest figure to show.
        wallet_collateral_dgb: ?f64 = null,
    };

    /// Live DigiDollar system state: the BIP9 deployment status (the anchor —
    /// if this call fails, the snapshot fails; it's also the only DD RPC that
    /// answers before activation), then the oracle price and the system-wide
    /// stats — supply/collateral/health plus the mint-restriction reason —
    /// each best-effort (pre-activation both error, leaving zero values).
    pub fn ddInfo(allocator: std.mem.Allocator, auth: models.CoinAuth) !models.StablecoinInfo {
        var out: models.StablecoinInfo = .{};

        {
            var parsed = try rpc.callParsed(DdDeploymentInfo, allocator, auth, "getdigidollardeploymentinfo");
            defer parsed.deinit();
            if (parsed.value.result) |r| {
                out.setStatus(r.status);
                out.active = r.enabled;
                out.activation_height = r.activation_height orelse r.min_activation_height;
            } else if (parsed.value.@"error") |e| {
                // A daemon without the DD RPCs (pre-9.26) answers "Method not
                // found" — report that as a distinct status so the tab can say
                // "needs a newer core" instead of spinning on "checking…".
                if (std.ascii.indexOfIgnoreCase(e.message, "not found") != null) {
                    out.setStatus("unsupported");
                    return out;
                }
                return error.EmptyRpcResult;
            } else return error.EmptyRpcResult;
        }

        if (rpc.callParsed(DdOraclePrice, allocator, auth, "getoracleprice")) |parsed_const| {
            var parsed = parsed_const;
            defer parsed.deinit();
            if (parsed.value.result) |r| {
                out.price_micro_usd = std.math.lossyCast(u64, @round(@max(r.price_micro_usd, 0)));
                out.price_stale = r.is_stale;
            }
        } else |_| {}

        if (rpc.callParsed(DdStats, allocator, auth, "getdigidollarstats")) |parsed_const| {
            var parsed = parsed_const;
            defer parsed.deinit();
            if (parsed.value.result) |r| {
                out.total_supply_cents = centsFrom(r.total_dd_supply);
                out.total_collateral = r.total_collateral_dgb;
                out.health_ratio = r.health_percentage;
                out.minting_blocked = ddMintRestricted(r.minting_restricted_reason);
            }
        } else |_| {}

        return out;
    }

    /// Whether the stats' `minting_restricted_reason` means minting is blocked
    /// right now ("none"/empty = fine; anything else — "oracle_unavailable",
    /// "err_active" — blocks).
    fn ddMintRestricted(reason: []const u8) bool {
        return reason.len > 0 and !std.mem.eql(u8, reason, "none");
    }

    /// The wallet's DD balance via `getdigidollarbalance` (no args = the whole
    /// wallet, minconf 1) — integer cents on the wire.
    pub fn ddBalance(allocator: std.mem.Allocator, auth: models.CoinAuth) !models.StablecoinBalance {
        var parsed = try rpc.callParsed(DdBalanceResult, allocator, auth, "getdigidollarbalance");
        defer parsed.deinit();
        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return .{
            .confirmed_cents = centsFrom(r.confirmed),
            .pending_cents = centsFrom(r.unconfirmed),
        };
    }

    /// The wallet's DD deposit address. Reuses the first existing address
    /// (including still-empty generated ones — `include_empty=true` — so a
    /// fresh session doesn't mint a new address every launch); generates one
    /// via `getdigidollaraddress` when none exists or on an explicit
    /// user-requested rotation (`force_new`). Caller owns the result.
    pub fn ddReceiveAddress(allocator: std.mem.Allocator, auth: models.CoinAuth, force_new: bool) ![]const u8 {
        if (!force_new) {
            if (rpc.callParsedParams([]const DdAddressEntry, allocator, auth, "listdigidollaraddresses", "[false,0,true]")) |parsed_const| {
                var parsed = parsed_const;
                defer parsed.deinit();
                if (parsed.value.result) |rows| {
                    if (rows.len > 0 and rows[0].address.len > 0)
                        return allocator.dupe(u8, rows[0].address);
                }
            } else |_| {}
        }
        var parsed = try rpc.callParsed([]const u8, allocator, auth, "getdigidollaraddress");
        defer parsed.deinit();
        const addr = parsed.value.result orelse return error.EmptyRpcResult;
        return allocator.dupe(u8, addr);
    }

    /// Map a `listdigidollartxs` category to the normalized kind.
    /// `redeem_change` (the daemon's internal change row of a redemption) and
    /// unknown categories are dropped (null).
    fn ddTxKind(category: []const u8) ?models.StablecoinTxKind {
        if (std.mem.eql(u8, category, "mint")) return .mint;
        if (std.mem.eql(u8, category, "send")) return .sent;
        if (std.mem.eql(u8, category, "receive")) return .received;
        if (std.mem.eql(u8, category, "redeem")) return .redeem;
        return null;
    }

    /// The wallet's most recent DD transactions, newest-first, via
    /// `listdigidollartxs <limit>`. The reply's ordering isn't documented, so
    /// the mapped rows are explicitly sorted newest-first by timestamp rather
    /// than trusting the daemon's order (see `mapDdTransactions`).
    pub fn ddTransactions(allocator: std.mem.Allocator, auth: models.CoinAuth, limit: usize) ![]models.StablecoinTx {
        const params = try std.fmt.allocPrint(allocator, "[{d}]", .{limit});
        defer allocator.free(params);
        var parsed = try rpc.callParsedParams([]const DdTxEntry, allocator, auth, "listdigidollartxs", params);
        defer parsed.deinit();
        const raw = parsed.value.result orelse return error.EmptyRpcResult;
        return mapDdTransactions(allocator, raw);
    }

    /// Normalize `raw` and sort it newest-first by timestamp, dropping
    /// categories with no mapped kind. Two passes so the slice is allocated at
    /// its exact final length (same shape as `rpc.mapListTransactions`).
    fn mapDdTransactions(allocator: std.mem.Allocator, raw: []const DdTxEntry) ![]models.StablecoinTx {
        var count: usize = 0;
        for (raw) |r| {
            if (ddTxKind(r.category) != null) count += 1;
        }
        var out = try allocator.alloc(models.StablecoinTx, count);
        var n: usize = 0;
        for (raw) |r| {
            const kind = ddTxKind(r.category) orelse continue;
            out[n] = .{
                .kind = kind,
                // Send rows arrive negated; `kind` carries the sign.
                .amount_cents = centsFrom(@abs(r.amount)),
                .time = r.time,
                .confirmations = r.confirmations,
            };
            n += 1;
        }
        std.mem.sort(models.StablecoinTx, out, {}, struct {
            fn newerFirst(_: void, a: models.StablecoinTx, b: models.StablecoinTx) bool {
                return a.time > b.time;
            }
        }.newerFirst);
        return out;
    }

    /// The wallet's collateral positions (vaults) via
    /// `listdigidollarpositions false` (all positions — `active_only` defaults
    /// to true, which would hide freshly-unlocked vaults), capped at `limit`.
    /// Fully-redeemed positions are dropped (`mapDdPositions`) — they're
    /// history, already visible as `redeem` rows in the transaction list.
    pub fn ddPositions(allocator: std.mem.Allocator, auth: models.CoinAuth, limit: usize) ![]models.StablecoinPosition {
        var parsed = try rpc.callParsedParams([]const DdPositionEntry, allocator, auth, "listdigidollarpositions", "[false]");
        defer parsed.deinit();
        const raw = parsed.value.result orelse return error.EmptyRpcResult;
        return mapDdPositions(allocator, raw, limit);
    }

    /// Normalize raw position rows, skipping any without an id (nothing to
    /// redeem them by) and any already redeemed. Split out for offline tests.
    fn mapDdPositions(allocator: std.mem.Allocator, raw: []const DdPositionEntry, limit: usize) ![]models.StablecoinPosition {
        var count: usize = 0;
        for (raw) |r| {
            if (count >= limit) break;
            if (ddPositionShown(r)) count += 1;
        }
        var out = try allocator.alloc(models.StablecoinPosition, count);
        var n: usize = 0;
        for (raw) |r| {
            if (n >= count) break;
            if (!ddPositionShown(r)) continue;
            out[n] = .{
                .amount_cents = centsFrom(r.dd_minted),
                .tier = std.math.lossyCast(u8, r.lock_tier),
                .unlock_height = r.unlock_height,
                .can_redeem = r.can_redeem,
            };
            out[n].setId(r.position_id);
            n += 1;
        }
        return out;
    }

    /// Whether a raw position row belongs on the tab: it must carry an id, and
    /// not be fully redeemed already.
    fn ddPositionShown(r: DdPositionEntry) bool {
        return r.position_id.len > 0 and !std.mem.eql(u8, r.status, "redeemed");
    }

    /// How much DGB minting `cents` at `tier` would lock right now, via
    /// `estimatecollateral`. Prefers `wallet_collateral_dgb` (what the wallet's
    /// mint builder will actually lock, safety margin included) over the bare
    /// consensus minimum `required_dgb`.
    pub fn ddEstimateCollateral(allocator: std.mem.Allocator, auth: models.CoinAuth, cents: i64, tier: u8) !f64 {
        const params = try std.fmt.allocPrint(allocator, "[{d},{d}]", .{ cents, tier });
        defer allocator.free(params);
        var parsed = try rpc.callParsedParams(DdEstimate, allocator, auth, "estimatecollateral", params);
        defer parsed.deinit();
        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return r.wallet_collateral_dgb orelse r.required_dgb;
    }

    /// Mint `cents` of DD at lock `tier` (`mintdigidollar <cents> <tier>`),
    /// locking DGB collateral until the tier's unlock height. Success carries
    /// the txid plus the locked-DGB figure; a daemon rejection (locked wallet,
    /// stale oracle price, below-minimum amount) rides back verbatim.
    pub fn ddMint(allocator: std.mem.Allocator, auth: models.CoinAuth, cents: i64, tier: u8) !models.SendResult {
        const params = try std.fmt.allocPrint(allocator, "[{d},{d}]", .{ cents, tier });
        defer allocator.free(params);
        return ddOp(allocator, auth, "mintdigidollar", params, "dgb_collateral", "locked");
    }

    /// Send `cents` of DD to `address` (`senddigidollar <addr> <cents>`). The
    /// integer amount is cents by the RPC's own convention; the miner fee is
    /// paid in DGB, so the wallet needs a little DGB alongside the DD.
    pub fn ddSend(allocator: std.mem.Allocator, auth: models.CoinAuth, address: []const u8, cents: i64) !models.SendResult {
        const addr_q = try rpc.jsonQuote(allocator, address);
        defer allocator.free(addr_q);
        const params = try std.fmt.allocPrint(allocator, "[{s},{d}]", .{ addr_q, cents });
        defer allocator.free(params);
        return ddOp(allocator, auth, "senddigidollar", params, null, "");
    }

    /// Redeem position `position_id` in full (`redeemdigidollar <id> <cents>` —
    /// the daemon requires the whole vault amount), burning the DD and
    /// unlocking its DGB collateral. Success carries the unlocked-DGB figure.
    pub fn ddRedeem(allocator: std.mem.Allocator, auth: models.CoinAuth, position_id: []const u8, cents: i64) !models.SendResult {
        const id_q = try rpc.jsonQuote(allocator, position_id);
        defer allocator.free(id_q);
        const params = try std.fmt.allocPrint(allocator, "[{s},{d}]", .{ id_q, cents });
        defer allocator.free(params);
        return ddOp(allocator, auth, "redeemdigidollar", params, "dgb_unlocked", "unlocked");
    }

    /// Run one DD wallet op and normalize the outcome (`SendResult`): the
    /// daemon's own rejection message rides back verbatim, success carries the
    /// txid — plus, when `detail_key` names a DGB figure in the reply, a
    /// "(<verb> N DGB)" suffix so the user sees what the op did to their
    /// collateral.
    fn ddOp(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        method: []const u8,
        params: []const u8,
        detail_key: ?[]const u8,
        detail_verb: []const u8,
    ) !models.SendResult {
        var parsed = try rpc.callParsedParams(std.json.Value, allocator, auth, method, params);
        defer parsed.deinit();
        return ddOutcome(allocator, parsed.value, detail_key, detail_verb);
    }

    /// The pure mapping half of `ddOp`, split out for offline tests.
    fn ddOutcome(
        allocator: std.mem.Allocator,
        resp: models.JsonRpcResponse(std.json.Value),
        detail_key: ?[]const u8,
        detail_verb: []const u8,
    ) !models.SendResult {
        if (resp.@"error") |e| return .{ .failed = try allocator.dupe(u8, e.message) };
        const result = resp.result orelse return .{ .failed = try allocator.dupe(u8, "no response from daemon") };
        const txid: []const u8 = switch (result) {
            .string => |s| s,
            .object => |o| blk: {
                const t = o.get("txid") orelse break :blk "";
                break :blk switch (t) {
                    .string => |s| s,
                    else => "",
                };
            },
            else => "",
        };
        if (txid.len == 0) return .{ .failed = try allocator.dupe(u8, "unexpected reply from daemon") };
        if (detail_key) |key| {
            if (result == .object) {
                if (result.object.get(key)) |field| {
                    if (jsonNumber(field)) |dgb| {
                        return .{ .ok = try std.fmt.allocPrint(allocator, "{s} ({s} {d} DGB)", .{ txid, detail_verb, dgb }) };
                    }
                }
            }
        }
        return .{ .ok = try allocator.dupe(u8, txid) };
    }

    // --- vtable plumbing -------------------------------------------------

    const vtable: Coin.VTable = .{
        .coin_name = vtCoinName,
        .coin_name_abbrev = vtCoinNameAbbrev,
        .coin_description = vtCoinDescription,
        .coin_color = vtCoinColor,
        .tip_address = vtTipAddress,
        .price_id = vtPriceId,
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
        .ensure_wallet = vtEnsureWallet,
        .wallet_security_state = vtWalletSecurityState,
        .wallet_balance = vtWalletBalance,
        .wallet_transactions = vtWalletTransactions,
        .wallet_receive_address = vtWalletReceiveAddress,
        .wallet_send = vtWalletSend,
        .wallet_encrypt = vtWalletEncrypt,
        .wallet_unlock = vtWalletUnlock,
        .wallet_lock = vtWalletLock,
        .warmup_probe_method = vtWarmupProbeMethod,
        .stablecoin = &stablecoin_cap,
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
    fn vtPriceId(_: *anyopaque) []const u8 {
        return price_id;
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
        _: []const u8,
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
    fn vtEnsureWallet(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) anyerror!void {
        return ensureWallet(allocator, auth);
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
    fn vtWarmupProbeMethod(_: *anyopaque) []const u8 {
        return warmupProbeMethod();
    }
};

test "parses getblockchaininfo into normalized BlockchainState" {
    const allocator = std.testing.allocator;

    // Canned daemon reply — proves parse + map without a running digibyted. Note
    // the per-algo `difficulties` object DigiByte uses in place of a scalar
    // `difficulty`; it's ignored at parse time.
    const raw =
        \\{"result":{"chain":"main","blocks":18650123,"headers":18650123,
        \\"bestblockhash":"deadbeef","difficulties":{"scrypt":1234.5},
        \\"mediantime":1700000000,"verificationprogress":0.999998,
        \\"initialblockdownload":false,"size_on_disk":9876543210,"pruned":false},
        \\"error":null,"id":"boxwallet"}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.DgbBlockchainInfo),
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
    try std.testing.expectEqual(@as(i64, 18650123), state.blocks);
    try std.testing.expectEqual(@as(i64, 18650123), state.headers);
    try std.testing.expect(state.synced);
}

test "a chain mid-sync reads as not synced" {
    // verificationprogress below the 0.99999 threshold → still catching up.
    const r: models.DgbBlockchainInfo = .{ .blocks = 9_000_000, .headers = 18_650_123, .verificationprogress = 0.482 };
    try std.testing.expect(!(r.verificationprogress > 0.99999));
}

test "combines getblockchaininfo + getnetworkinfo into DaemonInfo (PoW, no getinfo)" {
    const allocator = std.testing.allocator;

    // DigiByte has no `getinfo`: blocks come from getblockchaininfo, peers from
    // getnetworkinfo. Prove each parses on its own, then the merge.
    const bc_raw =
        \\{"result":{"chain":"main","blocks":18650200,"headers":18650200,
        \\"verificationprogress":1.0},"error":null,"id":"boxwallet"}
    ;
    const net_raw =
        \\{"result":{"version":92604,"subversion":"/DigiByte:9.26.4/",
        \\"protocolversion":70017,"connections":12,"networkactive":true,
        \\"relayfee":0.00001000,"warnings":""},"error":null,"id":"boxwallet"}
    ;

    var bc = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.DgbBlockchainInfo),
        allocator,
        bc_raw,
        .{ .ignore_unknown_fields = true },
    );
    defer bc.deinit();
    var net = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.DgbNetworkInfo),
        allocator,
        net_raw,
        .{ .ignore_unknown_fields = true },
    );
    defer net.deinit();

    // DigiByte's CLIENT_VERSION 92604 decodes via the generic bitcoin packing to
    // the legacy 4-part "0.9.26.4"; daemonInfo strips the leading "0." so the
    // Running line and the version marker match the branded "9.26.4" (==
    // core_version) — otherwise the same release nags as "update available".
    const full = try models.clientVersionString(allocator, net.value.result.?.version);
    try std.testing.expectEqualStrings("0.9.26.4", full);
    const version = if (std.mem.startsWith(u8, full, "0.")) blk: {
        defer allocator.free(full);
        break :blk try allocator.dupe(u8, full[2..]);
    } else full;
    defer allocator.free(version);
    try std.testing.expectEqualStrings("9.26.4", version);
    try std.testing.expectEqualStrings(DigiByte.core_version, version);

    const info: models.DaemonInfo = .{
        .blocks = bc.value.result.?.blocks,
        .connections = net.value.result.?.connections,
        .staking_active = false,
        .version = version,
    };

    try std.testing.expectEqual(@as(i64, 18650200), info.blocks);
    try std.testing.expectEqual(@as(i64, 12), info.connections);
    // DigiByte is proof-of-work — staking is never active.
    try std.testing.expect(!info.staking_active);
}

test "platform selection resolves a streamable download only on Linux" {
    // DigiByte 8.x ships a usable daemon bundle only for Linux x86_64/aarch64
    // (`.tar.gz`). Windows (NSIS installer) and macOS (GUI-only app) yield no
    // streamable daemon, so the download is null there — as are Linux arm32/386.
    switch (builtin.os.tag) {
        .linux => switch (builtin.cpu.arch) {
            .x86_64, .aarch64 => {
                try std.testing.expect(DigiByte.download != null);
                try std.testing.expectEqual(install_mod.Format.tar_gz, DigiByte.download.?.format);
            },
            else => try std.testing.expect(DigiByte.download == null),
        },
        else => try std.testing.expect(DigiByte.download == null),
    }

    // Binary names still carry `.exe` only on Windows (kept for the few places the
    // name is used even though Windows resolves no download).
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("digibyted.exe", DigiByte.daemon_file);
    } else {
        try std.testing.expectEqualStrings("digibyted", DigiByte.daemon_file);
    }
}

test "coin vtable dispatches to DigiByte metadata" {
    var dgb: DigiByte = .{};
    const c = dgb.coin();
    try std.testing.expectEqualStrings("DigiByte", c.coinName());
    try std.testing.expectEqualStrings("DGB", c.coinNameAbbrev());
    try std.testing.expectEqualStrings("#0066CC", c.coinColor());
    try std.testing.expect(!c.isProofOfStake());
    try std.testing.expectEqualStrings("digibyte.conf", c.confFile());
    try std.testing.expectEqualStrings("digibyted", c.daemonFile());
    try std.testing.expectEqualStrings("14022", c.rpcDefaultPort());
    // Core-26 fork: needs an explicit wallet created/loaded after start.
    try std.testing.expect(c.needsWallet());
    // Bitcoin-core wallet over RPC: the `w` menu and the balance lines are both on.
    try std.testing.expect(c.supportsWallet());
    try std.testing.expect(c.supportsBalance());
}

test "prepareConf enables txindex + digidollar (DigiDollar) alongside the shared creds" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Use a throwaway home; prepareConf writes to <home>/.digibyte/digibyte.conf
    // (POSIX). Windows resolves a different data dir, so skip there.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const home = "test-dgb-conf-out";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    try DigiByte.prepareConf(allocator, io, home);

    const data_dir = try DigiByte.dataDir(allocator, home);
    defer allocator.free(data_dir);

    // server=1 from the shared populate, txindex=1 + digidollar=1 from the coin.
    inline for (.{ "server", "txindex", "digidollar" }) |key| {
        const v = try conf.readValue(allocator, io, data_dir, DigiByte.conf_file, key);
        defer if (v) |p| allocator.free(p);
        try std.testing.expectEqualStrings("1", v.?);
    }

    // Idempotent: a second prepare keeps the same values (nothing duplicated).
    try DigiByte.prepareConf(allocator, io, home);
    {
        const v = try conf.readValue(allocator, io, data_dir, DigiByte.conf_file, "digidollar");
        defer if (v) |p| allocator.free(p);
        try std.testing.expectEqualStrings("1", v.?);
    }
}

test "prepareConf preserves an explicit digidollar=0 rather than forcing it on" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const home = "test-dgb-conf-keep-out";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // A user who has deliberately turned DigiDollar off; prepareConf must not
    // override that choice.
    const data_dir = try DigiByte.dataDir(allocator, home);
    defer allocator.free(data_dir);
    var d = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
    d.writeFile(io, .{ .sub_path = DigiByte.conf_file, .data = "digidollar=0\n" }) catch {};
    d.close(io);

    try DigiByte.prepareConf(allocator, io, home);

    const dd = try conf.readValue(allocator, io, data_dir, DigiByte.conf_file, "digidollar");
    defer if (dd) |p| allocator.free(p);
    try std.testing.expectEqualStrings("0", dd.?);
    // txindex was still absent, so it's added.
    const tx = try conf.readValue(allocator, io, data_dir, DigiByte.conf_file, "txindex");
    defer if (tx) |p| allocator.free(p);
    try std.testing.expectEqualStrings("1", tx.?);
}

test "directionFromCategory maps listtransactions categories to normalized direction" {
    try std.testing.expectEqual(models.TxDirection.received, DigiByte.directionFromCategory("receive").?);
    try std.testing.expectEqual(models.TxDirection.sent, DigiByte.directionFromCategory("send").?);
    // Coinbase (mined) rewards at their maturity stages — DigiByte is
    // proof-of-work, so the normalized `.stake` here means a mined block reward.
    try std.testing.expectEqual(models.TxDirection.stake, DigiByte.directionFromCategory("generate").?);
    try std.testing.expectEqual(models.TxDirection.stake, DigiByte.directionFromCategory("immature").?);
    try std.testing.expectEqual(models.TxDirection.stake, DigiByte.directionFromCategory("orphan").?);
    // No direction — dropped by the shared mapper.
    try std.testing.expect(DigiByte.directionFromCategory("move") == null);
    try std.testing.expect(DigiByte.directionFromCategory("something-unknown") == null);
}

test "coin vtable exposes transactions, receive address, and send for DigiByte" {
    var dgb: DigiByte = .{};
    const c = dgb.coin();
    try std.testing.expect(c.supportsTransactions());
    try std.testing.expect(c.supportsReceiveAddress());
    try std.testing.expect(c.supportsSend());
}

test "walletPath points at the bitcoin-core BoxWallet directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var dgb: DigiByte = .{};
    const wf = (try dgb.coin().walletPath(allocator, "/home/alice")).?;
    defer allocator.free(wf.path);
    try std.testing.expectEqualStrings("/home/alice/.digibyte/wallets/BoxWallet", wf.path);
    try std.testing.expect(wf.keys == null);
}

test "maps getwalletinfo unlocked_until to the wallet security state" {
    // Bitcoin-core style: absent → unencrypted, 0 → locked, positive → unlocked.
    try std.testing.expectEqual(models.WalletSecurity.unencrypted, DigiByte.securityFromUnlockedUntil(null));
    try std.testing.expectEqual(models.WalletSecurity.locked, DigiByte.securityFromUnlockedUntil(0));
    try std.testing.expectEqual(models.WalletSecurity.unlocked, DigiByte.securityFromUnlockedUntil(1893456000));
}

test "DigiDollar: capability is wired with the full tier table and mint bounds" {
    var dgb: DigiByte = .{};
    const c = dgb.coin();
    try std.testing.expect(c.supportsStablecoin());
    const sc = c.stablecoin().?;
    try std.testing.expectEqualStrings("DigiDollar", sc.name);
    try std.testing.expectEqualStrings("DD", sc.symbol);
    // $100 minimum, $100,000 maximum per mint (consensus limits).
    try std.testing.expectEqual(@as(i64, 10_000), sc.min_mint_cents);
    try std.testing.expectEqual(@as(i64, 10_000_000), sc.max_mint_cents);
    // Ten tiers, index == tier number, ratios strictly easing as locks lengthen.
    try std.testing.expectEqual(@as(usize, 10), sc.tiers.len);
    for (sc.tiers, 0..) |t, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), t.tier);
        if (i > 0) try std.testing.expect(t.ratio_pct < sc.tiers[i - 1].ratio_pct);
    }
    try std.testing.expectEqual(@as(u32, 1000), sc.tiers[0].ratio_pct);
    try std.testing.expectEqual(@as(u32, 200), sc.tiers[9].ratio_pct);
}

test "DigiDollar: parses getdigidollarbalance cents into StablecoinBalance" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"result":{"confirmed":12550,"unconfirmed":500,"total":13050},
        \\"error":null,"id":"boxwallet"}
    ;
    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(DigiByte.DdBalanceResult),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    const r = parsed.value.result.?;
    const bal: models.StablecoinBalance = .{
        .confirmed_cents = DigiByte.centsFrom(r.confirmed),
        .pending_cents = DigiByte.centsFrom(r.unconfirmed),
    };
    try std.testing.expectEqual(@as(i64, 12550), bal.confirmed_cents); // $125.50
    try std.testing.expectEqual(@as(i64, 500), bal.pending_cents);
    try std.testing.expectEqual(@as(i64, 13050), bal.totalCents());
}

test "DigiDollar: maps listdigidollartxs categories, drops redeem_change, reverses to newest-first" {
    const allocator = std.testing.allocator;
    // Oldest-to-newest, as the daemon returns the window. Send rows negated.
    const raw = [_]DigiByte.DdTxEntry{
        .{ .category = "mint", .amount = 10000, .time = 100, .confirmations = 50 },
        .{ .category = "send", .amount = -2500, .time = 200, .confirmations = 20 },
        .{ .category = "redeem_change", .amount = 1, .time = 200, .confirmations = 20 },
        .{ .category = "receive", .amount = 750, .time = 300, .confirmations = 3 },
        .{ .category = "redeem", .amount = 10000, .time = 400, .confirmations = 1 },
    };
    const txs = try DigiByte.mapDdTransactions(allocator, &raw);
    defer allocator.free(txs);
    try std.testing.expectEqual(@as(usize, 4), txs.len);
    // Newest first; redeem_change dropped.
    try std.testing.expectEqual(models.StablecoinTxKind.redeem, txs[0].kind);
    try std.testing.expectEqual(models.StablecoinTxKind.received, txs[1].kind);
    try std.testing.expectEqual(models.StablecoinTxKind.sent, txs[2].kind);
    try std.testing.expectEqual(models.StablecoinTxKind.mint, txs[3].kind);
    // Send magnitude is positive; the kind carries the sign.
    try std.testing.expectEqual(@as(i64, 2500), txs[2].amount_cents);
    try std.testing.expectEqual(@as(i64, 300), txs[1].time);
}

test "DigiDollar: maps positions (dd_minted/lock_tier), skipping id-less and redeemed rows" {
    const allocator = std.testing.allocator;
    const raw = [_]DigiByte.DdPositionEntry{
        .{ .position_id = "aa11", .dd_minted = 10000, .lock_tier = 4, .unlock_height = 19_000_000, .status = "active", .can_redeem = false },
        .{ .position_id = "bb22", .dd_minted = 50000, .lock_tier = 1, .unlock_height = 18_500_000, .status = "unlocked", .can_redeem = true },
        .{ .position_id = "cc33", .dd_minted = 25000, .status = "redeemed" }, // history — dropped
        .{ .dd_minted = 999 }, // no id → unusable, skipped
    };
    const ps = try DigiByte.mapDdPositions(allocator, &raw, 8);
    defer allocator.free(ps);
    try std.testing.expectEqual(@as(usize, 2), ps.len);
    try std.testing.expectEqualStrings("aa11", ps[0].id());
    try std.testing.expectEqual(@as(i64, 10000), ps[0].amount_cents);
    try std.testing.expectEqual(@as(u8, 4), ps[0].tier);
    try std.testing.expect(!ps[0].can_redeem);
    try std.testing.expectEqualStrings("bb22", ps[1].id());
    try std.testing.expectEqual(@as(i64, 50000), ps[1].amount_cents);
    try std.testing.expectEqual(@as(u8, 1), ps[1].tier);
    try std.testing.expect(ps[1].can_redeem);
}

test "DigiDollar: estimatecollateral prefers the wallet's real lock figure over the consensus minimum" {
    const allocator = std.testing.allocator;
    // Field subset as documented by `digibyted help estimatecollateral` (9.26.4).
    const raw =
        \\{"result":{"required_dgb":41666.67,"minimum_required_dgb":41666.67,
        \\"wallet_collateral_dgb":42083.33,"collateral_safety_margin_dgb":416.66,
        \\"dd_amount":10000,"lock_tier":4,"lock_days":365,"base_ratio":300,
        \\"dca_multiplier":1.0,"effective_ratio":300,"oracle_price_micro_usd":14230,
        \\"usd_value":100.0},"error":null,"id":"boxwallet"}
    ;
    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(DigiByte.DdEstimate),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    const r = parsed.value.result.?;
    try std.testing.expectApproxEqAbs(@as(f64, 42083.33), r.wallet_collateral_dgb orelse r.required_dgb, 1e-9);
    // Without the wallet figure, the consensus minimum is the fallback.
    const bare: DigiByte.DdEstimate = .{ .required_dgb = 41666.67 };
    try std.testing.expectApproxEqAbs(@as(f64, 41666.67), bare.wallet_collateral_dgb orelse bare.required_dgb, 1e-9);
}

test "DigiDollar: ddOutcome maps success (txid + DGB detail) and daemon rejection verbatim" {
    const allocator = std.testing.allocator;

    // A mint success: txid + collateral figure → "(locked N DGB)" suffix.
    {
        const raw =
            \\{"result":{"txid":"cafe01","dd_minted":10000,"dgb_collateral":"41666.67",
            \\"lock_tier":4,"unlock_height":19000000},"error":null,"id":"boxwallet"}
        ;
        var parsed = try std.json.parseFromSlice(
            models.JsonRpcResponse(std.json.Value),
            allocator,
            raw,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();
        const outcome = try DigiByte.ddOutcome(allocator, parsed.value, "dgb_collateral", "locked");
        defer allocator.free(outcome.ok);
        try std.testing.expectEqualStrings("cafe01 (locked 41666.67 DGB)", outcome.ok);
    }

    // A daemon rejection rides back verbatim — never a generic "failed".
    {
        const raw =
            \\{"result":null,"error":{"code":-4,"message":"Timelock has not expired"},
            \\"id":"boxwallet"}
        ;
        var parsed = try std.json.parseFromSlice(
            models.JsonRpcResponse(std.json.Value),
            allocator,
            raw,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();
        const outcome = try DigiByte.ddOutcome(allocator, parsed.value, "dgb_unlocked", "unlocked");
        defer allocator.free(outcome.failed);
        try std.testing.expectEqualStrings("Timelock has not expired", outcome.failed);
    }

    // A send success with no detail key: bare txid.
    {
        const raw =
            \\{"result":{"txid":"beef02","to_address":"DD1x","amount":5000,
            \\"status":"broadcast"},"error":null,"id":"boxwallet"}
        ;
        var parsed = try std.json.parseFromSlice(
            models.JsonRpcResponse(std.json.Value),
            allocator,
            raw,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();
        const outcome = try DigiByte.ddOutcome(allocator, parsed.value, null, "");
        defer allocator.free(outcome.ok);
        try std.testing.expectEqualStrings("beef02", outcome.ok);
    }
}

test "DigiDollar: ddInfo mapping gates on `enabled` and carries the activation height" {
    const allocator = std.testing.allocator;

    // Pre-activation deployment reply, exactly as a live 9.26.4 mainnet
    // daemon answered it (status "defined", enabled false, activation height
    // published up front).
    {
        const raw =
            \\{"result":{"enabled":false,"bit":23,"start_time":1780272000,
            \\"timeout":1811808000,"min_activation_height":23627520,
            \\"status":"defined","oracle_activation_height":23627520,
            \\"oracle_pubkey_count":35},"error":null,"id":"boxwallet"}
        ;
        var parsed = try std.json.parseFromSlice(
            models.JsonRpcResponse(DigiByte.DdDeploymentInfo),
            allocator,
            raw,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();
        const r = parsed.value.result.?;
        var info: models.StablecoinInfo = .{};
        info.setStatus(r.status);
        info.active = r.enabled;
        info.activation_height = r.activation_height orelse r.min_activation_height;
        try std.testing.expectEqualStrings("defined", info.status());
        try std.testing.expect(!info.active);
        try std.testing.expectEqual(@as(i64, 23_627_520), info.activation_height);
    }

    // Mint gate: only "none"/empty means minting is allowed.
    try std.testing.expect(!DigiByte.ddMintRestricted("none"));
    try std.testing.expect(!DigiByte.ddMintRestricted(""));
    try std.testing.expect(DigiByte.ddMintRestricted("oracle_unavailable"));
    try std.testing.expect(DigiByte.ddMintRestricted("err_active"));

    // Oracle price: micro-USD figure + top-level staleness flag (per
    // `help getoracleprice`).
    {
        const raw =
            \\{"result":{"price_micro_usd":14230,"price_cents":1,"price_usd":0.01423,
            \\"last_update_height":23700000,"is_stale":true,"oracle_count":12,
            \\"status":"warning"},"error":null,"id":"boxwallet"}
        ;
        var parsed = try std.json.parseFromSlice(
            models.JsonRpcResponse(DigiByte.DdOraclePrice),
            allocator,
            raw,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();
        const r = parsed.value.result.?;
        try std.testing.expectApproxEqAbs(@as(f64, 14230), r.price_micro_usd, 1e-9);
        try std.testing.expect(r.is_stale);
    }

    // System stats: health/collateral/supply + the mint-restriction reason
    // (per `help getdigidollarstats`).
    {
        const raw =
            \\{"result":{"health_percentage":312.5,"health_status":"healthy",
            \\"total_collateral_dgb":123456.78,"total_dd_supply":5000000,
            \\"oracle_price_micro_usd":14230,"oracle_available":true,
            \\"minting_restricted_reason":"none","is_emergency":false},
            \\"error":null,"id":"boxwallet"}
        ;
        var parsed = try std.json.parseFromSlice(
            models.JsonRpcResponse(DigiByte.DdStats),
            allocator,
            raw,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();
        const r = parsed.value.result.?;
        try std.testing.expectApproxEqAbs(@as(f64, 312.5), r.health_percentage, 1e-9);
        try std.testing.expectEqual(@as(i64, 5_000_000), DigiByte.centsFrom(r.total_dd_supply));
        try std.testing.expect(!DigiByte.ddMintRestricted(r.minting_restricted_reason));
    }
}

test "maps getwalletinfo balances to available + total" {
    const allocator = std.testing.allocator;

    const raw =
        \\{"result":{"walletversion":169900,"balance":250.0,
        \\"unconfirmed_balance":10.0,"immature_balance":5.0,"unlocked_until":0},
        \\"error":null,"id":"boxwallet"}
    ;
    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.DgbWalletInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    const bal = models.WalletBalance.fromParts(r.balance, r.unconfirmed_balance, r.immature_balance);
    try std.testing.expectApproxEqAbs(@as(f64, 250.0), bal.available, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 265.0), bal.total, 1e-9);
    try std.testing.expect(bal.hasPending());
}
