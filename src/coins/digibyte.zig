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
    /// Donation address for BoxWallet development, in DigiByte's own
    /// currency.
    /// TODO(richard): replace with the real DGB tip address.
    pub const tip_address = "TODO-DGB-TIP-ADDRESS-NOT-SET";
    /// DigiByte is proof-of-work (multi-algo) — no wallet staking.
    pub const proof_of_stake = false;
    pub const conf_file = "digibyte.conf";
    pub const home_dir = ".digibyte";
    pub const home_dir_win = "DIGIBYTE";
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
        return conf.dataDir(allocator, home, home_dir, home_dir_win);
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
