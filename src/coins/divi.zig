const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const rpc = @import("../rpc.zig");
const install_mod = @import("../install.zig");
const conf = @import("../conf.zig");
const Coin = @import("../coin.zig").Coin;

/// Divi backend. Constants lifted from
/// `cmd/cli/cmd/coins/divi/divi.go`.
pub const Divi = struct {
    /// Whether the coin is exposed in the nav. False keeps it out of the left
    /// bar entirely (registered but hidden) until it's ready for users.
    pub const live = true;
    pub const coin_name = "Divi";
    pub const coin_name_abbrev = "DIVI";
    /// One-line description shown under the coin name on the detail pane.
    pub const coin_description = "Proof-of-stake coin with blockchain lottery.";
    /// Divi brand colour (`#RRGGBB`), for tinting the coin in the frontend.
    pub const coin_color = "#ED295A";
    /// This coin's id on the price host, for the USD quote beside its
    /// balance (see `src/price.zig`).
    pub const price_id = "divi";
    /// Donation address for BoxWallet development, in Divi's own
    /// currency.
    pub const tip_address = "DKHL4vUMS9BWcwhT4Y8NMJ62yYxLgeBdZb";
    /// Divi is proof-of-stake — the wallet can stake.
    pub const proof_of_stake = true;
    pub const conf_file = "divi.conf";
    pub const home_dir = ".divi";
    pub const home_dir_win = "DIVI";
    /// macOS data dir name. Divi Core: `~/Library/Application Support/DIVI`.
    pub const home_dir_mac: ?[]const u8 = "DIVI";
    pub const rpc_default_username = "divirpc";
    pub const rpc_default_port = "51473";
    pub const core_version = "3.0.0";

    // Binary names. Windows appends `.exe`; Linux/macOS use the bare names. The
    // per-target name is what `isInstalled`, the daemon launcher, and the promote
    // list all use.
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    pub const daemon_file = "divid" ++ exe_suffix;
    pub const cli_file = "divi-cli" ++ exe_suffix;
    pub const tx_file = "divi-tx" ++ exe_suffix;

    // Download host. Divi ships GitHub release archives whose filename carries an
    // arch/commit suffix, but each still wraps everything in the plain
    // `divi-<ver>/` dir with binaries under `bin/` — same shape on every platform.
    const download_base = "https://github.com/DiviProject/Divi/releases/download/v" ++ core_version ++ "/";

    /// The download URL + archive format for the build target, or null where Divi
    /// publishes no matching binary. Selected at comptime from OS/arch, mirroring
    /// the Go installer's `runtime.GOOS`/`GOARCH` switch:
    ///   - Linux arm64 and Linux 386 are unsupported upstream (null).
    ///   - Divi ships no native Apple-Silicon build, so both macOS arches use the
    ///     Intel `osx64` build — which runs on M1+ under Rosetta 2.
    const download: ?install_mod.Download = switch (builtin.os.tag) {
        .windows => .{ .url = download_base ++ "divi-" ++ core_version ++ "-win64-9e2f76c.zip", .format = .zip },
        .macos => .{ .url = download_base ++ "divi-" ++ core_version ++ "-osx64-9e2f76c.tar.gz", .format = .tar_gz },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => .{ .url = download_base ++ "divi-" ++ core_version ++ "-x86_64-linux-gnu-9e2f76c.tar.gz", .format = .tar_gz },
            .arm => .{ .url = download_base ++ "divi-" ++ core_version ++ "-RPi2-9e2f76c.tar.gz", .format = .tar_gz },
            else => null,
        },
        else => null,
    };

    // Layout inside the archive: keep only the daemon/cli/tx binaries (from
    // `bin/`) at the install root; the whole `divi-<ver>/` tree is discarded
    // afterwards. Matches the Go installer.
    const extracted_dir = "divi-" ++ core_version;
    const bin_subdir = "bin";
    const promote_files = [_][]const u8{ daemon_file, cli_file, tx_file };

    // Temp file the download streams to. Keyed off the daemon name so a
    // concurrent install of another coin into the same `~/.boxwallet` root uses
    // a different scratch file and the two never collide.
    pub const scratch_file = ".boxwallet-" ++ daemon_file ++ ".part";

    /// Build the type-erased `Coin` handle for this instance.
    pub fn coin(self: *Divi) Coin {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Live `getblockchaininfo`, normalized for a frontend.
    ///
    /// Unlike Nexa's daemon, Divi's `getblockchaininfo` does **not** report
    /// `verificationprogress` (the field is absent, so it parses as 0). Go's
    /// `BlockchainIsSynced` reads the masternode `mnsync status` instead, with a
    /// commented-out progress fallback. Rather than take that single extra-field
    /// path, we derive "synced" from the heights the call does return: the chain
    /// is caught up once validated `blocks` have reached the header tip
    /// (`blocks >= headers`, with at least one header seen). The header-vs-block
    /// counts also drive the sync progress bars.
    pub fn blockchainState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.BlockchainState {
        var parsed = try rpc.callParsed(models.DiviBlockchainInfo, allocator, auth, "getblockchaininfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return .{
            .chain = try allocator.dupe(u8, r.chain),
            .blocks = r.blocks,
            .headers = r.headers,
            .verification_progress = r.verificationprogress,
            .synced = r.headers > 0 and r.blocks >= r.headers,
            // Network tip from peers, so the frontend's Headers bar can fill
            // toward it. A getpeerinfo hiccup just leaves it 0 (unknown).
            .network_height = rpc.networkHeight(allocator, auth) catch 0,
            // Tip block timestamp, so the frontend can show how far behind in
            // wall-clock time the chain is while validating. Prefer the exact
            // tip `time`; fall back to `mediantime` when the daemon omits it.
            .tip_time = if (r.time > 0) r.time else r.mediantime,
        };
    }

    /// Live `getinfo`, normalized for a frontend. Divi exposes staking through a
    /// `"staking status"` string; we map the daemon's "Staking Active" to a bool
    /// so the frontend never sees the per-coin wording.
    pub fn daemonInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.DaemonInfo {
        var parsed = try rpc.callParsed(models.DiviGetInfo, allocator, auth, "getinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return .{
            .blocks = r.blocks,
            .connections = r.connections,
            .staking_active = std.mem.eql(u8, r.@"staking status", "Staking Active"),
            // Divi reports a ready-made version string; dupe it so it outlives `parsed`.
            .version = try allocator.dupe(u8, r.version),
        };
    }

    /// The daemon's default data directory (`~/.divi`), where `divi.conf` lives.
    pub fn dataDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        return conf.dataDir(allocator, home, home_dir, home_dir_win, home_dir_mac);
    }

    /// The managed wallet's on-disk location (`<datadir>/wallet.dat`) — the
    /// daemon's default wallet, a single file. Caller owns the returned strings.
    pub fn walletPath(allocator: std.mem.Allocator, home: []const u8) !?Coin.WalletFile {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        return .{ .path = try std.fs.path.join(allocator, &.{ data_dir, "wallet.dat" }) };
    }

    /// True if `divid` (`divid.exe` on Windows) is already present under
    /// `install_root`.
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, daemon_file);
    }

    /// Download + unarchive the Divi daemon files into `install_root`,
    /// optionally reporting download/extract progress.
    ///
    /// Extracts the versioned wrapper dir intact, then `promoteAndTidy` lifts the
    /// daemon/cli/tx binaries to the install root and removes the wrapper,
    /// leaving `divid` exactly where `isInstalled` looks for it.
    pub fn install(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        const dl = download orelse return error.UnsupportedPlatform;
        try install_mod.downloadAndExtract(allocator, dl.url, dl.format, install_root, scratch_file, 0, progress);
        try install_mod.promoteAndTidy(allocator, install_root, extracted_dir, bin_subdir, &promote_files);
    }

    // --- blockchain snapshot ---------------------------------------------
    //
    // Divi publishes a chain snapshot rebuilt every 24 hours, which turns a
    // multi-day initial sync into a download. The tarball holds `blocks/` and
    // `chainstate/` at its top level — already the shape of the data dir — so it
    // unpacks with no path stripping and no wrapper to flatten.

    const snapshot_url = "https://snapshots.diviproject.org/dist/DIVI-snapshot.tar.gz";

    /// The snapshot's partial download. It lives in BoxWallet's **install root**,
    /// not the data dir: ~4.7 GB of scratch is ours to manage, and the user's data
    /// dir must not be touched at all until the archive is complete and we're
    /// actually unpacking it. Dot-prefixed and coin-scoped like the install
    /// scratch, so it can't collide with another coin's.
    pub const snapshot_file = ".boxwallet-divi-snapshot.tar.gz";

    /// Directories the snapshot lays down — also the marker for "this data dir
    /// already has a chain", and what to clean up if an unpack fails partway.
    const snapshot_dirs = [_][]const u8{ "blocks", "chainstate" };

    /// Whether to offer the snapshot before launching divid.
    ///
    /// **Only when the data dir carries no chain at all.** A `blocks/` or
    /// `chainstate/` already there may well be another app's — Divi Desktop keeps
    /// its chain in exactly this directory — and unpacking a snapshot over a live
    /// `chainstate/` would corrupt days of someone else's sync with no way back.
    /// It's equally the "already done" check: once divid has run for even a
    /// moment, `blocks/` exists and the prompt never returns, so this is a
    /// one-time offer without needing a marker of its own.
    ///
    /// A pure disk check, so it runs with the daemon down.
    fn snapshotShouldOffer(allocator: std.mem.Allocator, _: []const u8, home: []const u8) bool {
        const data_dir = dataDir(allocator, home) catch return false;
        defer allocator.free(data_dir);
        return !chainPresent(allocator, data_dir);
    }

    /// True if any snapshot-owned directory already exists in `data_dir`.
    fn chainPresent(allocator: std.mem.Allocator, data_dir: []const u8) bool {
        for (snapshot_dirs) |d| {
            if (conf.dataDirHasEntry(allocator, data_dir, d)) return true;
        }
        return false;
    }

    /// Fetch the snapshot into the install root, **resuming** an interrupted
    /// attempt rather than starting the ~4.7 GB transfer over — at this size a
    /// connection dropping at 90% would otherwise make the feature useless.
    ///
    /// A stopped or failed transfer deliberately leaves its partial behind (that's
    /// what the next attempt resumes from); `install_mod.downloadFileResumable`
    /// guards against resuming into a *different* snapshot, since upstream
    /// regenerates this file daily, and returns immediately when the archive is
    /// already complete. Streamed to disk throughout — memory stays flat.
    fn snapshotDownload(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        _: []const u8,
        progress: ?install_mod.Progress,
        cancel: ?install_mod.Cancel,
    ) anyerror!void {
        return install_mod.downloadFileResumable(allocator, snapshot_url, install_root, snapshot_file, progress, cancel);
    }

    /// Unpack the downloaded snapshot into the data dir, then drop the archive.
    ///
    /// Re-checks for existing chain data first: `should_offer` ran before a
    /// multi-GB download that may have taken hours, and this is the last moment
    /// before we write into a directory that might not be ours.
    ///
    /// A failed unpack cleans up **both** sides: the archive (so a truncated or
    /// corrupt one isn't unpacked again forever) and the half-written `blocks/` /
    /// `chainstate/` (which would otherwise read as a chain, suppressing the
    /// prompt and handing divid a broken one). Deleting those is safe precisely
    /// because the check above proved they didn't exist before we started.
    ///
    /// A **pause** is not a failure and is handled differently: the half-written
    /// directories still have to go (they're not a usable chain, and leaving them
    /// would suppress the prompt), but the archive is kept, so resuming re-unpacks
    /// rather than re-downloading 4.7 GB.
    fn snapshotApply(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home: []const u8,
        progress: ?install_mod.Progress,
        cancel: ?install_mod.Cancel,
    ) anyerror!void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);

        if (chainPresent(allocator, data_dir)) return error.ChainDataAlreadyPresent;

        // Only the directories the snapshot exists to lay down. The data dir may
        // hold a wallet and a conf that aren't ours, and the archive picks its own
        // paths — so anything else it carries is dropped rather than written.
        install_mod.extractLocalTarGzAllowing(allocator, install_root, snapshot_file, data_dir, 0, &snapshot_dirs, progress, cancel) catch |err| {
            removeSnapshotDirs(allocator, data_dir);
            if (err != error.Paused) install_mod.discardPartial(allocator, install_root, snapshot_file);
            return err;
        };
        // Unpacked: the 4.7 GB archive has done its job and is pure dead weight.
        install_mod.discardPartial(allocator, install_root, snapshot_file);
    }

    /// Remove a half-unpacked snapshot's directories. Only ever called on the
    /// failure path above, where they are known to be ours.
    fn removeSnapshotDirs(allocator: std.mem.Allocator, data_dir: []const u8) void {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var dir = std.Io.Dir.cwd().openDir(io, data_dir, .{}) catch return;
        defer dir.close(io);
        for (snapshot_dirs) |d| dir.deleteTree(io, d) catch {};
    }

    /// Bytes of a previous, interrupted snapshot download waiting on disk — what
    /// the prompt shows so "Yes" reads as continuing rather than starting over.
    /// 0 when there's nothing resumable (see `install_mod.partialBytes`, which
    /// discounts a partial whose origin sidecar is missing).
    fn snapshotPartialBytes(allocator: std.mem.Allocator, install_root: []const u8, _: []const u8) u64 {
        return install_mod.partialBytes(allocator, install_root, snapshot_file);
    }

    /// The sync-accelerator capability wired into the vtable: offer the snapshot
    /// before the first daemon start on an empty data dir, download it (resumably)
    /// on the user's yes, unpack it, then launch.
    pub const sync_accelerator: Coin.SyncAccelerator = .{
        .name = "Blockchain snapshot",
        .prompt_detail = "Download ~4.7 GB of chain data to sync in minutes instead of days. Resumes if interrupted.",
        .resumable = true,
        .should_offer = snapshotShouldOffer,
        .download = snapshotDownload,
        .apply = snapshotApply,
        .partial_bytes = snapshotPartialBytes,
    };

    /// Ensure `divi.conf` carries the RPC creds (and `server=1`/`daemon=1`/
    /// `rpcport`) BoxWallet needs before the daemon reads it; existing values are
    /// kept. A standard bitcoin-derived `key=value` conf.
    pub fn prepareConf(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        _ = try conf.populate(allocator, io, data_dir, conf_file, rpc_default_username, rpc_default_port);
    }

    /// Divi is a bitcoin-derived daemon: it forks itself into the background with
    /// `-daemon` on POSIX, but runs in the foreground on Windows.
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

    /// Ask divid to shut down via the JSON-RPC `stop`.
    pub fn requestStop(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        const reply = try rpc.call(allocator, auth, "stop");
        allocator.free(reply);
    }

    /// Read the wallet's security state from `getwalletinfo`. Divi (PIVX-derived)
    /// reports a human-readable `encryption_status` string rather than a numeric
    /// `unlocked_until`. Mirrors Go's `WalletSecurityState`.
    pub fn walletSecurityState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.WalletSecurity {
        var parsed = try rpc.callParsed(models.DiviWalletInfo, allocator, auth, "getwalletinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return securityFromStatus(r.encryption_status);
    }

    /// Read the wallet's balances from `getwalletinfo`. `available` is the
    /// confirmed spendable `balance`; `total` adds the mempool
    /// (`unconfirmed_balance`) and maturing (`immature_balance`) funds, so it
    /// reflects incoming money the moment it's seen. Same `getwalletinfo` shape as
    /// `walletSecurityState`.
    pub fn walletBalance(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.WalletBalance {
        var parsed = try rpc.callParsed(models.DiviWalletInfo, allocator, auth, "getwalletinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return models.WalletBalance.fromParts(r.balance, r.unconfirmed_balance, r.immature_balance);
    }

    /// Map Divi's `encryption_status` string to the normalized `WalletSecurity`.
    /// Shared by the parse path and its unit test. An unrecognized value reads as
    /// `unknown`.
    fn securityFromStatus(status: []const u8) models.WalletSecurity {
        if (std.mem.eql(u8, status, "unencrypted")) return .unencrypted;
        if (std.mem.eql(u8, status, "locked")) return .locked;
        if (std.mem.eql(u8, status, "unlocked")) return .unlocked;
        if (std.mem.eql(u8, status, "unlocked-for-staking")) return .unlocked_for_staking;
        return .unknown;
    }

    /// Map Divi's `listtransactions` `category` to the normalized direction.
    /// Divi (PIVX-derived) has its own reward categories on top of the classic
    /// set (upstream `ParseTransactionDetails`): `"stake_reward"` /
    /// `"stake_reward+"` for PoS stakes, `"mn_reward"` for masternode payouts,
    /// and `"lottery"` for lottery-block wins — all protocol rewards the wallet
    /// minted/earned itself, so they map to the normalized `.stake`, as do the
    /// classic coinbase `"generate"`/`"immature"`/`"orphan"`. `"darksent"` is
    /// still money leaving the wallet (a private send), so it reads as sent.
    /// Anything else (`"move"`) has no direction (null; the caller drops it).
    fn directionFromCategory(category: []const u8) ?models.TxDirection {
        if (std.mem.eql(u8, category, "receive")) return .received;
        if (std.mem.eql(u8, category, "send") or
            std.mem.eql(u8, category, "darksent")) return .sent;
        if (std.mem.eql(u8, category, "stake_reward") or
            std.mem.eql(u8, category, "stake_reward+") or
            std.mem.eql(u8, category, "mn_reward") or
            std.mem.eql(u8, category, "lottery") or
            std.mem.eql(u8, category, "generate") or
            std.mem.eql(u8, category, "immature") or
            std.mem.eql(u8, category, "orphan")) return .stake;
        return null;
    }

    /// The wallet's most recent transactions, newest-first — the shared
    /// bitcoin-family `listtransactions` flow with Divi's category map.
    pub fn walletTransactions(allocator: std.mem.Allocator, auth: models.CoinAuth, limit: usize) ![]models.WalletTx {
        return rpc.walletTransactions(allocator, auth, limit, directionFromCategory);
    }

    /// The wallet's receive address. Divi's PIVX-era wallet keeps the accounts
    /// API, so the shared accounts flow applies: `getaccountaddress ""` for the
    /// stable current address, `getnewaddress` on an explicit user-requested
    /// rotation (`force_new` — only ever called on demand, never polled).
    pub fn receiveAddress(allocator: std.mem.Allocator, auth: models.CoinAuth, force_new: bool) ![]const u8 {
        return rpc.receiveAddressAccount(allocator, auth, force_new);
    }

    /// Send `amount` DIVI to `address` via `sendtoaddress` (8-decimal amounts).
    /// The daemon's own rejection reason (invalid address, insufficient funds,
    /// locked wallet) rides back verbatim in the `SendResult`.
    pub fn sendToAddress(allocator: std.mem.Allocator, auth: models.CoinAuth, address: []const u8, amount: f64) !models.SendResult {
        return rpc.sendToAddress(allocator, auth, address, amount, 8);
    }

    /// Encrypt the wallet with `passphrase`. divid stops itself afterwards (the
    /// caller restarts it). The passphrase is JSON-escaped before splicing.
    pub fn walletEncrypt(allocator: std.mem.Allocator, auth: models.CoinAuth, passphrase: []const u8) !void {
        const pw = try rpc.jsonQuote(allocator, passphrase);
        defer allocator.free(pw);
        const params = try std.fmt.allocPrint(allocator, "[{s}]", .{pw});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "encryptwallet", params);
    }

    /// Unlock the wallet via `walletpassphrase`. A plain unlock uses an indefinite
    /// timeout (0, matching Go's `WalletUnlock`); `staking` requests an
    /// unlock-for-staking with the long timeout + `true` flag (Go's
    /// `WalletUnlockFS`).
    pub fn walletUnlock(allocator: std.mem.Allocator, auth: models.CoinAuth, passphrase: []const u8, staking: bool) !void {
        const pw = try rpc.jsonQuote(allocator, passphrase);
        defer allocator.free(pw);
        const params = if (staking)
            try std.fmt.allocPrint(allocator, "[{s},9999999,true]", .{pw})
        else
            try std.fmt.allocPrint(allocator, "[{s},0]", .{pw});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "walletpassphrase", params);
    }

    /// Re-lock the wallet via `walletlock`.
    pub fn walletLock(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        return rpc.callExpectOk(allocator, auth, "walletlock", "[]");
    }

    /// Divi retains `getinfo`, so probe it for the daemon's warm-up phase.
    pub fn warmupProbeMethod() []const u8 {
        return "getinfo";
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
        .wallet_security_state = vtWalletSecurityState,
        .wallet_balance = vtWalletBalance,
        .wallet_transactions = vtWalletTransactions,
        .wallet_receive_address = vtWalletReceiveAddress,
        .wallet_send = vtWalletSend,
        .wallet_encrypt = vtWalletEncrypt,
        .wallet_unlock = vtWalletUnlock,
        .wallet_lock = vtWalletLock,
        .warmup_probe_method = vtWarmupProbeMethod,
        .sync_accelerator = &sync_accelerator,
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

test "maps getblockchaininfo into BlockchainState, syncing on blocks vs headers" {
    const allocator = std.testing.allocator;

    // Canned reply mirroring a live divid getblockchaininfo — note there is no
    // `verificationprogress` field (Divi's daemon omits it). blocks == headers
    // here, so the chain reads as synced.
    const raw =
        \\{"result":{"chain":"main","blocks":4071165,"headers":4071165,
        \\"bestblockhash":"322d04e1197d59ed4f47583f4accda109c4f7e32b38871c30b812d571355f171",
        \\"difficulty":43135.79559493,
        \\"chainwork":"000000000000000000000000000000000000000000000017f092768cd23927cb"},
        \\"error":null,"id":"boxwallet"}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.DiviBlockchainInfo),
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
        .synced = r.headers > 0 and r.blocks >= r.headers,
    };
    defer state.deinit(allocator);

    try std.testing.expectEqualStrings("main", state.chain);
    try std.testing.expectEqual(@as(i64, 4071165), state.blocks);
    try std.testing.expectEqual(@as(i64, 4071165), state.headers);
    // No verificationprogress in the reply → parses as 0, but synced is derived
    // from the heights (blocks have caught up to the header tip).
    try std.testing.expectEqual(@as(f64, 0), state.verification_progress);
    try std.testing.expect(state.synced);
}

test "blocks behind the header tip read as not synced" {
    // Mid-sync: headers race ahead of validated blocks.
    const r: models.DiviBlockchainInfo = .{ .blocks = 2_000_000, .headers = 4_071_165 };
    try std.testing.expect(!(r.headers > 0 and r.blocks >= r.headers));
}

test "maps getinfo into normalized DaemonInfo, decoding staking status" {
    const allocator = std.testing.allocator;

    // Canned reply mirroring a live divid getinfo — note the `"staking status"`
    // field carries a literal space and the human-readable "Staking Active".
    const raw =
        \\{"result":{"version":"3.0.0.0","protocolversion":70915,
        \\"walletversion":120200,"balance":3139364.85688449,"blocks":4071089,
        \\"timeoffset":0,"connections":29,"proxy":"","difficulty":54392.69715429,
        \\"testnet":false,"moneysupply":4678085823.73950005,"relayfee":0.00010000,
        \\"staking status":"Staking Active","errors":""},
        \\"error":null,"id":"boxwallet"}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.DiviGetInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    const info: models.DaemonInfo = .{
        .blocks = r.blocks,
        .connections = r.connections,
        .staking_active = std.mem.eql(u8, r.@"staking status", "Staking Active"),
    };

    try std.testing.expectEqual(@as(i64, 4071089), info.blocks);
    try std.testing.expectEqual(@as(i64, 29), info.connections);
    try std.testing.expect(info.staking_active);
}

test "getinfo without active staking maps staking_active false" {
    const allocator = std.testing.allocator;

    const raw =
        \\{"result":{"blocks":4071089,"connections":8,
        \\"staking status":"Staking Not Active"},"error":null,"id":"boxwallet"}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.DiviGetInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    try std.testing.expect(!std.mem.eql(u8, r.@"staking status", "Staking Active"));
    try std.testing.expectEqual(@as(i64, 8), r.connections);
}

test "platform selection resolves a download for supported targets" {
    // Divi has no native Linux-arm64 build, so the download is allowed to be null
    // there; when present, the format must match the OS (zip on Windows, else
    // tar.gz — including the Intel osx64 build used for both macOS arches).
    if (Divi.download) |dl| {
        switch (builtin.os.tag) {
            .windows => try std.testing.expectEqual(install_mod.Format.zip, dl.format),
            else => try std.testing.expectEqual(install_mod.Format.tar_gz, dl.format),
        }
    }

    // Binary names carry `.exe` only on Windows.
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("divid.exe", Divi.daemon_file);
    } else {
        try std.testing.expectEqualStrings("divid", Divi.daemon_file);
    }
}

test "coin vtable dispatches to Divi metadata" {
    var divi: Divi = .{};
    const c = divi.coin();
    try std.testing.expectEqualStrings("Divi", c.coinName());
    try std.testing.expectEqualStrings("#ED295A", c.coinColor());
    try std.testing.expect(c.isProofOfStake());
    try std.testing.expectEqualStrings("divi.conf", c.confFile());
    try std.testing.expectEqualStrings("divid", c.daemonFile());
    try std.testing.expectEqualStrings("51473", c.rpcDefaultPort());
    // Divi's wallet is manageable over RPC — the `w` menu is available.
    try std.testing.expect(c.supportsWallet());
    // And it reports a balance, so the Total/Available lines light up.
    try std.testing.expect(c.supportsBalance());
}

test "walletPath points at the daemon's default wallet.dat" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var divi: Divi = .{};
    const wf = (try divi.coin().walletPath(allocator, "/home/alice")).?;
    defer allocator.free(wf.path);
    try std.testing.expectEqualStrings("/home/alice/.divi/wallet.dat", wf.path);
    try std.testing.expect(wf.keys == null);
}

test "directionFromCategory maps listtransactions categories to normalized direction" {
    try std.testing.expectEqual(models.TxDirection.received, Divi.directionFromCategory("receive").?);
    try std.testing.expectEqual(models.TxDirection.sent, Divi.directionFromCategory("send").?);
    // A private send is still money leaving the wallet.
    try std.testing.expectEqual(models.TxDirection.sent, Divi.directionFromCategory("darksent").?);
    // Divi's protocol rewards — stakes, masternode payouts, lottery wins — plus
    // the classic coinbase categories all read as the normalized stake direction.
    try std.testing.expectEqual(models.TxDirection.stake, Divi.directionFromCategory("stake_reward").?);
    try std.testing.expectEqual(models.TxDirection.stake, Divi.directionFromCategory("stake_reward+").?);
    try std.testing.expectEqual(models.TxDirection.stake, Divi.directionFromCategory("mn_reward").?);
    try std.testing.expectEqual(models.TxDirection.stake, Divi.directionFromCategory("lottery").?);
    try std.testing.expectEqual(models.TxDirection.stake, Divi.directionFromCategory("generate").?);
    try std.testing.expectEqual(models.TxDirection.stake, Divi.directionFromCategory("immature").?);
    try std.testing.expectEqual(models.TxDirection.stake, Divi.directionFromCategory("orphan").?);
    // No direction — dropped by the shared mapper.
    try std.testing.expect(Divi.directionFromCategory("move") == null);
    try std.testing.expect(Divi.directionFromCategory("something-unknown") == null);
}

test "coin vtable exposes transactions, receive address, and send for Divi" {
    var divi: Divi = .{};
    const c = divi.coin();
    try std.testing.expect(c.supportsTransactions());
    try std.testing.expect(c.supportsReceiveAddress());
    try std.testing.expect(c.supportsSend());
}

test "maps getwalletinfo balances to available + total" {
    const allocator = std.testing.allocator;

    // 100 confirmed, 5 in the mempool: total moves to 105 immediately, available
    // stays 100 until the mempool funds confirm.
    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.DiviWalletInfo),
        allocator,
        "{\"result\":{\"encryption_status\":\"unlocked\",\"balance\":100.0,\"unconfirmed_balance\":5.0},\"error\":null,\"id\":\"boxwallet\"}",
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    const bal = models.WalletBalance.fromParts(r.balance, r.unconfirmed_balance, r.immature_balance);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), bal.available, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 105.0), bal.total, 1e-9);
    try std.testing.expect(bal.hasPending());
}

test "maps getwalletinfo encryption_status to the wallet security state" {
    // Divi reports the state as a string; each of the four values maps to its
    // normalized state, and anything unexpected reads as unknown.
    try std.testing.expectEqual(models.WalletSecurity.unencrypted, Divi.securityFromStatus("unencrypted"));
    try std.testing.expectEqual(models.WalletSecurity.locked, Divi.securityFromStatus("locked"));
    try std.testing.expectEqual(models.WalletSecurity.unlocked, Divi.securityFromStatus("unlocked"));
    try std.testing.expectEqual(models.WalletSecurity.unlocked_for_staking, Divi.securityFromStatus("unlocked-for-staking"));
    try std.testing.expectEqual(models.WalletSecurity.unknown, Divi.securityFromStatus("something-else"));

    // The field parses out of a representative getwalletinfo reply.
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.DiviWalletInfo),
        allocator,
        "{\"result\":{\"walletversion\":120200,\"encryption_status\":\"locked\"},\"error\":null,\"id\":\"boxwallet\"}",
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqual(models.WalletSecurity.locked, Divi.securityFromStatus(parsed.value.result.?.encryption_status));
}

test "the snapshot is offered only into a data dir with no chain in it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-divi-snapshot-home";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // A data dir that doesn't exist yet — a first-ever start. Offer it.
    try std.testing.expect(Divi.snapshotShouldOffer(allocator, "", home));

    // The dir exists but holds only a conf (BoxWallet's own `prepareConf` runs
    // before the daemon ever does): still no chain, still offered.
    var dd = try std.Io.Dir.cwd().createDirPathOpen(io, home ++ "/.divi", .{});
    defer dd.close(io);
    try dd.writeFile(io, .{ .sub_path = Divi.conf_file, .data = "server=1\n" });
    try std.testing.expect(Divi.snapshotShouldOffer(allocator, "", home));

    // Chain data is present. It may be Divi Desktop's — days of sync that
    // unpacking a snapshot over would destroy — and it's equally what "already
    // done" looks like. Either way: never offer, so it's never overwritten.
    var blocks = try std.Io.Dir.cwd().createDirPathOpen(io, home ++ "/.divi/blocks", .{});
    blocks.close(io);
    try std.testing.expect(!Divi.snapshotShouldOffer(allocator, "", home));

    // chainstate/ alone counts too — a half-present chain is still not ours.
    std.Io.Dir.cwd().deleteTree(io, home ++ "/.divi/blocks") catch {};
    var cs = try std.Io.Dir.cwd().createDirPathOpen(io, home ++ "/.divi/chainstate", .{});
    cs.close(io);
    try std.testing.expect(!Divi.snapshotShouldOffer(allocator, "", home));
}

test "applying a snapshot refuses to write over chain data that appeared meanwhile" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-divi-snapshot-apply";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // The download can run for hours, so the should_offer check is stale by the
    // time it finishes — the user may have started Divi Desktop in between. The
    // re-check is the last guard before we write into their data dir.
    var blocks = try std.Io.Dir.cwd().createDirPathOpen(io, home ++ "/.divi/blocks", .{});
    blocks.close(io);
    try std.testing.expectError(
        error.ChainDataAlreadyPresent,
        Divi.snapshotApply(allocator, "test-divi-snapshot-root", home, null, null),
    );
}

test "the snapshot capability is wired up as a resumable, applied accelerator" {
    var divi: Divi = .{};
    const sa = divi.coin().syncAccelerator().?;

    // Resumable — 4.7 GB is far too much to refetch after a dropped connection,
    // and the prompt keys its "continue from here" wording off this.
    try std.testing.expect(sa.resumable);
    // A snapshot is inert until it's unpacked, so it must carry an apply step
    // (unlike Nerva's quicksync file, which the daemon reads where it lands).
    try std.testing.expect(sa.apply != null);
    try std.testing.expect(sa.partial_bytes != null);

    // The archive lands in BoxWallet's own root, never in the user's data dir.
    try std.testing.expect(std.mem.startsWith(u8, Divi.snapshot_file, ".boxwallet-"));
    // Upstream serves the tarball whose entries are already the data dir's shape.
    try std.testing.expect(std.mem.endsWith(u8, Divi.snapshot_url, ".tar.gz"));
}
