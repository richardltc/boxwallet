const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const rpc = @import("../rpc.zig");
const install_mod = @import("../install.zig");
const conf = @import("../conf.zig");
const Coin = @import("../coin.zig").Coin;

/// Litecoin backend.
///
/// Litecoin Core 0.21 is a Bitcoin Core 0.21 fork, so it shares the streaming
/// install path and `key=value` conf with Nexa/Divi/DigiByte. Like DigiByte it
/// dropped `getinfo`, so the live status is assembled from `getblockchaininfo`
/// (chain/height/sync) + `getnetworkinfo` (peer count), and a Core-0.21 daemon no
/// longer auto-creates a wallet, so one is load-or-created after start.
///
/// Litecoin's full chain is large, so it's the first coin to wire the optional
/// `Pruning` capability: the first time its daemon starts, the user is asked how
/// much disk to cap the blockchain at, persisted as `prune=<MiB>` in the conf and
/// surfaced read-only on the Settings tab.
pub const Litecoin = struct {
    /// Whether the coin is exposed in the nav. False keeps it out of the left
    /// bar entirely (registered but hidden) until it's ready for users.
    pub const live = true;
    pub const coin_name = "Litecoin";
    pub const coin_name_abbrev = "LTC";
    /// One-line description shown under the coin name on the detail pane.
    pub const coin_description = "The silver to Bitcoin's gold — fast, low-fee payments.";
    /// Litecoin brand colour (`#RRGGBB`), for tinting the coin in the frontend.
    pub const coin_color = "#345D9D";
    /// Donation address for BoxWallet development, in Litecoin's own
    /// currency.
    pub const tip_address = "ltc1qdzccuuf2nr73rs58vtgn242sf6csw3v3azpzpq";
    /// Litecoin is proof-of-work (scrypt) — no wallet staking.
    pub const proof_of_stake = false;
    pub const conf_file = "litecoin.conf";
    pub const home_dir = ".litecoin";
    pub const home_dir_win = "Litecoin";
    /// macOS data dir name. Litecoin Core: `~/Library/Application Support/Litecoin`. (Its
    /// source comment still says "Bitcoin"; the code returns "Litecoin".)
    pub const home_dir_mac: ?[]const u8 = "Litecoin";
    pub const rpc_default_username = "litecoinrpc";
    pub const rpc_default_port = "9332";
    pub const core_version = "0.21.5.5";

    // Binary names. Windows appends `.exe`; Linux/macOS use the bare names.
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    pub const daemon_file = "litecoind" ++ exe_suffix;
    pub const cli_file = "litecoin-cli" ++ exe_suffix;
    pub const tx_file = "litecoin-tx" ++ exe_suffix;

    // Download host. Every bundle wraps its executables in `litecoin-<ver>/bin/`,
    // identically across platforms (Linux/macOS `.tar.gz`, Windows `.zip`).
    const download_base = "https://github.com/litecoin-project/litecoin/releases/download/v" ++ core_version ++ "/";

    /// The download URL + archive format for the build target, or null where
    /// Litecoin publishes no matching daemon bundle. Selected at comptime from the
    /// OS/arch. Litecoin ships streamable bundles for every desktop target:
    ///   - Linux x86_64/aarch64: `.tar.gz`.
    ///   - Windows x86_64: `win64.zip` (extracted from the seekable scratch file).
    ///   - macOS: only an Intel `osx64.tar.gz` — used for both arches, so Apple
    ///     Silicon runs `litecoind` under Rosetta 2 (as Divi does).
    const download: ?install_mod.Download = switch (builtin.os.tag) {
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => .{ .url = download_base ++ "litecoin-" ++ core_version ++ "-win64.zip", .format = .zip },
            else => null,
        },
        .macos => switch (builtin.cpu.arch) {
            // No native arm64 build upstream — the Intel osx64 bundle runs under Rosetta.
            .aarch64, .x86_64 => .{ .url = download_base ++ "litecoin-" ++ core_version ++ "-osx64.tar.gz", .format = .tar_gz },
            else => null,
        },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => .{ .url = download_base ++ "litecoin-" ++ core_version ++ "-x86_64-linux-gnu.tar.gz", .format = .tar_gz },
            .aarch64 => .{ .url = download_base ++ "litecoin-" ++ core_version ++ "-aarch64-linux-gnu.tar.gz", .format = .tar_gz },
            else => null,
        },
        else => null,
    };

    // Layout inside the archive: keep only the daemon/cli/tx binaries (from
    // `bin/`) at the install root; the whole `litecoin-<ver>/` tree is discarded.
    const extracted_dir = "litecoin-" ++ core_version;
    const bin_subdir = "bin";
    const promote_files = [_][]const u8{ daemon_file, cli_file, tx_file };

    // Temp file the download streams to. Keyed off the daemon name so a concurrent
    // install of another coin into the same `~/.boxwallet` root uses a different
    // scratch file and the two never collide.
    pub const scratch_file = ".boxwallet-" ++ daemon_file ++ ".part";

    /// Build the type-erased `Coin` handle for this instance.
    pub fn coin(self: *Litecoin) Coin {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Live `getblockchaininfo`, normalized for a frontend. Litecoin reports
    /// `verificationprogress`, so "synced" is derived from it as for DigiByte
    /// (progress > 0.99999).
    pub fn blockchainState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.BlockchainState {
        var parsed = try rpc.callParsed(models.LtcBlockchainInfo, allocator, auth, "getblockchaininfo");
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
            // wall-clock time the chain is while validating. Prefer the exact tip
            // `time`; fall back to `mediantime` when the daemon omits it.
            .tip_time = if (r.time > 0) r.time else r.mediantime,
        };
    }

    /// Live status, normalized for a frontend. Litecoin has no `getinfo`, so the
    /// block height comes from `getblockchaininfo` and the peer count from
    /// `getnetworkinfo`. Litecoin is proof-of-work, so `staking_active` is false.
    pub fn daemonInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.DaemonInfo {
        var bc = try rpc.callParsed(models.LtcBlockchainInfo, allocator, auth, "getblockchaininfo");
        defer bc.deinit();
        const b = bc.value.result orelse return error.EmptyRpcResult;

        var net = try rpc.callParsed(models.LtcNetworkInfo, allocator, auth, "getnetworkinfo");
        defer net.deinit();
        const n = net.value.result orelse return error.EmptyRpcResult;

        return .{
            .blocks = b.blocks,
            .connections = n.connections,
            .staking_active = false,
            // `getnetworkinfo`'s numeric CLIENT_VERSION → dotted string, owned by
            // `allocator` so it outlives `net`'s deinit.
            .version = try models.clientVersionString(allocator, n.version),
        };
    }

    /// The daemon's default data directory (`~/.litecoin`), where `litecoin.conf`
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

    /// True if `litecoind` (`litecoind.exe` on Windows) is already present under
    /// `install_root`.
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, daemon_file);
    }

    /// Download + unarchive the Litecoin daemon files into `install_root`,
    /// optionally reporting download/extract progress. Streams to a scratch file,
    /// then `promoteAndTidy` lifts daemon/cli/tx out of the wrapper's `bin/`.
    pub fn install(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        const dl = download orelse return error.UnsupportedPlatform;
        try install_mod.downloadAndExtract(allocator, dl.url, dl.format, install_root, scratch_file, 0, progress);
        try install_mod.promoteAndTidy(allocator, install_root, extracted_dir, bin_subdir, &promote_files);
    }

    /// Ensure `litecoin.conf` carries the RPC creds (and `server=1`/`rpcport`)
    /// BoxWallet needs before the daemon reads it; existing values are kept. A
    /// standard bitcoin-derived `key=value` conf. The user's chosen `prune` value
    /// (written by the prune prompt at first start) is preserved untouched.
    pub fn prepareConf(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        _ = try conf.populate(allocator, io, data_dir, conf_file, rpc_default_username, rpc_default_port);
    }

    /// Litecoin is a bitcoin-derived daemon: it forks itself into the background
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

    /// Ask litecoind to shut down via the JSON-RPC `stop`.
    pub fn requestStop(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        const reply = try rpc.call(allocator, auth, "stop");
        allocator.free(reply);
    }

    /// Litecoin Core 0.21 doesn't auto-create a wallet, so address/balance RPCs
    /// have none to act on until one exists. Load-or-create a wallet named
    /// "BoxWallet" once the daemon is up.
    pub fn ensureWallet(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        return rpc.ensureWallet(allocator, auth, "BoxWallet");
    }

    /// Read the wallet's security state from `getwalletinfo`. Bitcoin-core style:
    /// `unlocked_until` is **absent** on an unencrypted wallet, `0` when locked,
    /// and a positive unlock timestamp otherwise.
    pub fn walletSecurityState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.WalletSecurity {
        var parsed = try rpc.callParsed(models.LtcWalletInfo, allocator, auth, "getwalletinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return securityFromUnlockedUntil(r.unlocked_until);
    }

    /// Read the wallet's balances from `getwalletinfo`. `available` is the
    /// confirmed spendable `balance`; `total` adds the mempool
    /// (`unconfirmed_balance`) and maturing (`immature_balance`) funds.
    pub fn walletBalance(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.WalletBalance {
        var parsed = try rpc.callParsed(models.LtcWalletInfo, allocator, auth, "getwalletinfo");
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

    /// Map Litecoin's `listtransactions` `category` to the normalized direction.
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
    /// bitcoin-family `listtransactions` flow with Litecoin's category map.
    pub fn walletTransactions(allocator: std.mem.Allocator, auth: models.CoinAuth, limit: usize) ![]models.WalletTx {
        return rpc.walletTransactions(allocator, auth, limit, directionFromCategory);
    }

    /// Marker label that tracks the wallet's current receive address. Litecoin's
    /// Core-0.21 base removed the accounts API (and with it any stable "current
    /// address" RPC), so the shared label flow keeps exactly one address under
    /// this label — see `rpc.receiveAddressLabeled`.
    const receive_label = "boxwallet-receive";

    /// The wallet's receive address: the labelled current one (minted on first
    /// use), or a fresh mint on an explicit user-requested rotation
    /// (`force_new` — only ever called on demand, never polled).
    pub fn receiveAddress(allocator: std.mem.Allocator, auth: models.CoinAuth, force_new: bool) ![]const u8 {
        return rpc.receiveAddressLabeled(allocator, auth, force_new, receive_label);
    }

    /// Send `amount` LTC to `address` via `sendtoaddress` (8-decimal amounts).
    /// The daemon's own rejection reason (invalid address, insufficient funds,
    /// locked wallet) rides back verbatim in the `SendResult`.
    pub fn sendToAddress(allocator: std.mem.Allocator, auth: models.CoinAuth, address: []const u8, amount: f64) !models.SendResult {
        return rpc.sendToAddress(allocator, auth, address, amount, 8);
    }

    /// Encrypt the wallet with `passphrase`. litecoind stops itself afterwards (the
    /// caller restarts it). The passphrase is JSON-escaped before splicing.
    pub fn walletEncrypt(allocator: std.mem.Allocator, auth: models.CoinAuth, passphrase: []const u8) !void {
        const pw = try rpc.jsonQuote(allocator, passphrase);
        defer allocator.free(pw);
        const params = try std.fmt.allocPrint(allocator, "[{s}]", .{pw});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "encryptwallet", params);
    }

    /// Unlock the wallet via `walletpassphrase`. Litecoin is proof-of-work, so the
    /// `staking` flag is irrelevant — a plain unlock with an indefinite timeout (0).
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

    /// Litecoin dropped `getinfo`, so probe `getnetworkinfo` for the daemon's
    /// warm-up phase (any supported method returns the "-28 in warm-up" reply).
    pub fn warmupProbeMethod() []const u8 {
        return "getnetworkinfo";
    }

    // --- pruning capability ----------------------------------------------
    //
    // Litecoin's chain is large, so on the *first* daemon start the user picks how
    // much disk to cap it at; the choice is written to `litecoin.conf` as
    // `prune=<MiB>` (0 = full node) and read back for the Settings tab. Each fn
    // creates its own threaded IO so callers don't thread one through.

    pub const pruning_caps: Coin.Pruning = .{
        .should_offer = pruneShouldOffer,
        .apply = pruneApply,
        .current = pruneCurrent,
    };

    /// The directory `litecoind` stores block files in. Its presence means a chain
    /// already lives in the data dir — see `pruneShouldOffer`.
    const chain_dir = "blocks";

    /// Offer the prune prompt only when the conf carries no `prune` setting yet —
    /// so it's asked exactly once, and a conf the user already pruned is respected
    /// — **and** only when the data dir holds no chain yet.
    ///
    /// That second condition is what stops BoxWallet destroying someone else's
    /// node. BoxWallet uses `~/.litecoin`, which may well be an existing Litecoin Core
    /// node's, with a fully synced chain in it. An unpruned node carries no `prune`
    /// key *by definition* — you only add one to opt in — so the conf check alone
    /// reads a full node as "never asked" and offers to prune it. Accepting would
    /// write `prune=` to their conf and have litecoind discard block data
    /// irreversibly: there's no un-prune without a full re-sync, and a pruned node
    /// can no longer rescan an old wallet. A `blocks/` dir means someone was here
    /// first, so the prompt is withheld and their node is left exactly as it was.
    ///
    /// This never suppresses the legitimate prompt: it's evaluated *before the
    /// daemon's first start* (see `app.zig`'s start preflight), so a data dir
    /// BoxWallet is setting up fresh has no `blocks/` yet and is still offered.
    fn pruneShouldOffer(allocator: std.mem.Allocator, home: []const u8) bool {
        const cur = pruneCurrent(allocator, home) catch return false;
        if (cur != null) return false;

        const data_dir = dataDir(allocator, home) catch return false;
        defer allocator.free(data_dir);
        return !conf.dataDirHasEntry(allocator, data_dir, chain_dir);
    }

    /// Persist the chosen prune target (MiB; 0 = full node) to `litecoin.conf`,
    /// creating the conf/dir if absent and preserving every other line.
    fn pruneApply(allocator: std.mem.Allocator, home: []const u8, prune_mib: i64) anyerror!void {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        var buf: [24]u8 = undefined;
        const val = std.fmt.bufPrint(&buf, "{d}", .{prune_mib}) catch unreachable;
        try conf.setValue(allocator, io, data_dir, conf_file, "prune", val);
    }

    /// The configured prune target (MiB, 0, or null when unset) for the Settings
    /// tab. A malformed value reads as null rather than erroring the display.
    fn pruneCurrent(allocator: std.mem.Allocator, home: []const u8) anyerror!?i64 {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        const raw = (try conf.readValue(allocator, io, data_dir, conf_file, "prune")) orelse return null;
        defer allocator.free(raw);
        return std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t"), 10) catch null;
    }

    // --- vtable plumbing -------------------------------------------------

    const vtable: Coin.VTable = .{
        .coin_name = vtCoinName,
        .coin_name_abbrev = vtCoinNameAbbrev,
        .coin_description = vtCoinDescription,
        .coin_color = vtCoinColor,
        .tip_address = vtTipAddress,
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
        .pruning = &pruning_caps,
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

    const raw =
        \\{"result":{"chain":"main","blocks":2700000,"headers":2700000,
        \\"bestblockhash":"deadbeef","verificationprogress":0.999999,
        \\"mediantime":1700000000,"time":1700000005,"pruned":true},
        \\"error":null,"id":"boxwallet"}
    ;
    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.LtcBlockchainInfo),
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
        .tip_time = if (r.time > 0) r.time else r.mediantime,
    };
    defer state.deinit(allocator);

    try std.testing.expectEqualStrings("main", state.chain);
    try std.testing.expectEqual(@as(i64, 2700000), state.blocks);
    try std.testing.expect(state.synced);
    try std.testing.expectEqual(@as(i64, 1700000005), state.tip_time);
}

test "platform selection resolves a streamable bundle for the build target" {
    switch (builtin.os.tag) {
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => try std.testing.expectEqual(install_mod.Format.zip, Litecoin.download.?.format),
            else => try std.testing.expect(Litecoin.download == null),
        },
        .macos => switch (builtin.cpu.arch) {
            .aarch64, .x86_64 => try std.testing.expectEqual(install_mod.Format.tar_gz, Litecoin.download.?.format),
            else => try std.testing.expect(Litecoin.download == null),
        },
        .linux => switch (builtin.cpu.arch) {
            .x86_64, .aarch64 => try std.testing.expectEqual(install_mod.Format.tar_gz, Litecoin.download.?.format),
            else => try std.testing.expect(Litecoin.download == null),
        },
        else => try std.testing.expect(Litecoin.download == null),
    }

    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("litecoind.exe", Litecoin.daemon_file);
    } else {
        try std.testing.expectEqualStrings("litecoind", Litecoin.daemon_file);
    }
}

test "coin vtable dispatches to Litecoin metadata" {
    var ltc: Litecoin = .{};
    const c = ltc.coin();
    try std.testing.expectEqualStrings("Litecoin", c.coinName());
    try std.testing.expectEqualStrings("LTC", c.coinNameAbbrev());
    try std.testing.expectEqualStrings("#345D9D", c.coinColor());
    try std.testing.expect(!c.isProofOfStake());
    try std.testing.expectEqualStrings("litecoin.conf", c.confFile());
    try std.testing.expectEqualStrings("9332", c.rpcDefaultPort());
    // Core-0.21 fork: needs an explicit wallet created/loaded after start.
    try std.testing.expect(c.needsWallet());
    try std.testing.expect(c.supportsWallet());
    try std.testing.expect(c.supportsBalance());
}

test "walletPath points at the bitcoin-core BoxWallet directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var ltc: Litecoin = .{};
    const wf = (try ltc.coin().walletPath(allocator, "/home/alice")).?;
    defer allocator.free(wf.path);
    try std.testing.expectEqualStrings("/home/alice/.litecoin/wallets/BoxWallet", wf.path);
    try std.testing.expect(wf.keys == null);
}

test "maps getwalletinfo unlocked_until to the wallet security state" {
    try std.testing.expectEqual(models.WalletSecurity.unencrypted, Litecoin.securityFromUnlockedUntil(null));
    try std.testing.expectEqual(models.WalletSecurity.locked, Litecoin.securityFromUnlockedUntil(0));
    try std.testing.expectEqual(models.WalletSecurity.unlocked, Litecoin.securityFromUnlockedUntil(1893456000));
}

test "directionFromCategory maps listtransactions categories to normalized direction" {
    try std.testing.expectEqual(models.TxDirection.received, Litecoin.directionFromCategory("receive").?);
    try std.testing.expectEqual(models.TxDirection.sent, Litecoin.directionFromCategory("send").?);
    // Coinbase (mined) rewards at their maturity stages — Litecoin is
    // proof-of-work, so the normalized `.stake` here means a mined block reward.
    try std.testing.expectEqual(models.TxDirection.stake, Litecoin.directionFromCategory("generate").?);
    try std.testing.expectEqual(models.TxDirection.stake, Litecoin.directionFromCategory("immature").?);
    try std.testing.expectEqual(models.TxDirection.stake, Litecoin.directionFromCategory("orphan").?);
    // No direction — dropped by the shared mapper.
    try std.testing.expect(Litecoin.directionFromCategory("move") == null);
    try std.testing.expect(Litecoin.directionFromCategory("something-unknown") == null);
}

test "coin vtable exposes transactions, receive address, and send for Litecoin" {
    var ltc: Litecoin = .{};
    const c = ltc.coin();
    try std.testing.expect(c.supportsTransactions());
    try std.testing.expect(c.supportsReceiveAddress());
    try std.testing.expect(c.supportsSend());
}

test "pruning is never offered for a chain that was already here" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var c_inst: Litecoin = .{};
    const c = c_inst.coin();

    // The scenario this guards: BoxWallet uses the daemon's standard data dir, so
    // it may be an existing Litecoin Core full node. An unpruned node has *no* `prune`
    // key — that's what unpruned means — so without the chain check it reads as
    // "never asked" and BoxWallet offers to prune someone else's node. Saying yes
    // discards their block data irreversibly.
    const home = "test-litecoin-adopted-home";
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    const data_dir = try Litecoin.dataDir(allocator, home);
    defer allocator.free(data_dir);

    // A data dir that looks like an existing node: a `blocks/` dir, and a conf
    // carrying no `prune` key (exactly what a full node's conf looks like).
    {
        var dd = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
        defer dd.close(io);
        try dd.writeFile(io, .{ .sub_path = Litecoin.conf_file, .data = "rpcuser=someoneelse\n" });
    }
    {
        const blocks = try std.fs.path.join(allocator, &.{ data_dir, "blocks" });
        defer allocator.free(blocks);
        var bd = try std.Io.Dir.cwd().createDirPathOpen(io, blocks, .{});
        bd.close(io);
    }

    // No prune key is configured — but the prompt must still be withheld, because
    // the chain isn't ours to prune.
    try std.testing.expect((try c.pruningState(allocator, home)) == null);
    try std.testing.expect(!c.offersPrunePrompt(allocator, home));
}

test "pruning: offered when unset, then applied value is read back and not re-offered" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var ltc: Litecoin = .{};
    const c = ltc.coin();

    // A throwaway HOME whose ~/.litecoin/litecoin.conf doesn't exist yet.
    const home = "test-ltc-prune-home";
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // No conf → prompt is offered and there's no configured value.
    try std.testing.expect(c.offersPrunePrompt(allocator, home));
    try std.testing.expect((try c.pruningState(allocator, home)) == null);

    // Apply 5 GB (5000 MiB): it's read back and the prompt is no longer offered.
    try c.applyPrune(allocator, home, 5000);
    try std.testing.expectEqual(@as(?i64, 5000), try c.pruningState(allocator, home));
    try std.testing.expect(!c.offersPrunePrompt(allocator, home));

    // "No pruning" (0) is a real configured value, distinct from unset.
    try c.applyPrune(allocator, home, 0);
    try std.testing.expectEqual(@as(?i64, 0), try c.pruningState(allocator, home));
    try std.testing.expect(!c.offersPrunePrompt(allocator, home));
}
