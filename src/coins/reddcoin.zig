const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const rpc = @import("../rpc.zig");
const install_mod = @import("../install.zig");
const conf = @import("../conf.zig");
const walletfile = @import("../walletfile.zig");
const Coin = @import("../coin.zig").Coin;

/// ReddCoin (RDD) backend. Constants seeded from
/// `cmd/cli/cmd/coins/reddcoin/reddcoin.go`, but updated to the current
/// **4.22.9.4** core (the Go reference's 3.10.3 downloads are gone, and 4.x is a
/// major upgrade: ReddCoin Core rebased onto Bitcoin Core 22).
///
/// ReddCoin is a bitcoin-derived Proof-of-Stake-Velocity coin, so it shares the
/// streaming install path and `key=value` conf with the other forks, with two
/// wrinkles from the Bitcoin-22 rebase:
///
///   * **No `getinfo`** — removed upstream in Bitcoin 0.16. Like DigiByte, the
///     status is assembled from `getblockchaininfo` (chain/height/sync) and
///     `getnetworkinfo` (peer count).
///   * **Staking** — PoSV staking state comes from ReddCoin's own
///     `getstakinginfo`, whose `staking` bool ("has the staking thread searched
///     recently *and* does the wallet have stakeable weight") drives the
///     normalized `staking_active`. Not the `staking` RPC: that one only reports
///     the daemon-wide `-staking` switch and the per-wallet enable flags — it has
///     no `staking` key at all, so reading it always said "not staking".
///     Best-effort: a wallet that can't answer (locked, none loaded) just reads
///     as not staking rather than failing the whole poll. Arming staking takes
///     *two* switches, not one — see `enableStaking`.
pub const ReddCoin = struct {
    /// Whether the coin is exposed in the nav. False keeps it out of the left
    /// bar entirely (registered but hidden) until it's ready for users.
    pub const live = true;
    pub const coin_name = "ReddCoin";
    pub const coin_name_abbrev = "RDD";
    /// One-line description shown under the coin name on the detail pane.
    pub const coin_description = "The social currency — staking-powered tipping.";
    /// ReddCoin brand colour (`#RRGGBB`), for tinting the coin in the frontend.
    pub const coin_color = "#e30613";
    /// This coin's id on the price host, for the USD quote beside its
    /// balance (see `src/price.zig`).
    pub const price_id = "reddcoin";
    /// Donation address for BoxWallet development, in ReddCoin's own
    /// currency.
    pub const tip_address = "Ri9AGKMp14tLm9kc7W7e2TWM3sR4oo1fki";
    /// Secondary brand colour for the "Coin" half of the wordmark — the nav draws
    /// "Redd" in `coin_color` and "Coin" in this near-white. Split after "Redd".
    pub const coin_color_alt = "#f0f0f0";
    pub const wordmark_split = "Redd".len;
    /// ReddCoin is proof-of-stake (PoSV) — the wallet can stake.
    pub const proof_of_stake = true;
    pub const conf_file = "reddcoin.conf";
    pub const home_dir = ".reddcoin";
    pub const home_dir_win = "REDDCOIN";
    /// Which Windows directory that name hangs off — the roaming `%APPDATA%`, as
    /// every bitcoin-derived daemon picks. See `conf.WinBase`.
    pub const home_dir_win_base: conf.WinBase = .roaming;
    /// macOS data dir name. Reddcoin Core: `~/Library/Application Support/Reddcoin` — note the
    /// casing differs from the Windows `REDDCOIN`.
    pub const home_dir_mac: ?[]const u8 = "Reddcoin";
    pub const rpc_default_username = "reddcoinrpc";
    pub const rpc_default_port = "45443";
    pub const core_version = "4.22.9.4";

    // Binary names. Windows appends `.exe`; Linux/macOS use the bare names.
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    pub const daemon_file = "reddcoind" ++ exe_suffix;
    pub const cli_file = "reddcoin-cli" ++ exe_suffix;
    pub const tx_file = "reddcoin-tx" ++ exe_suffix;

    // Download host (ReddCoin's own, not GitHub). Each bundle wraps its
    // executables in `reddcoin-<ver>/bin/`, identically across platforms.
    const download_base = "https://download.reddcoin.com/bin/reddcoin-core-" ++ core_version ++ "/";

    /// The download URL + archive format for the build target, or null where
    /// ReddCoin publishes no matching binary. Selected at comptime from OS/arch:
    ///   - Linux x86_64/aarch64/arm all ship a `.tar.gz`.
    ///   - Windows ships `win64.zip`.
    ///   - ReddCoin ships no native Apple-Silicon build, so both macOS arches use
    ///     the Intel `osx64` build (runs on M1+ under Rosetta 2), mirroring Divi.
    const download: ?install_mod.Download = switch (builtin.os.tag) {
        .windows => .{ .url = download_base ++ "reddcoin-" ++ core_version ++ "-win64.zip", .format = .zip },
        .macos => .{ .url = download_base ++ "reddcoin-" ++ core_version ++ "-osx64.tar.gz", .format = .tar_gz },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => .{ .url = download_base ++ "reddcoin-" ++ core_version ++ "-x86_64-linux-gnu.tar.gz", .format = .tar_gz },
            .aarch64 => .{ .url = download_base ++ "reddcoin-" ++ core_version ++ "-aarch64-linux-gnu.tar.gz", .format = .tar_gz },
            .arm => .{ .url = download_base ++ "reddcoin-" ++ core_version ++ "-arm-linux-gnueabihf.tar.gz", .format = .tar_gz },
            else => null,
        },
        else => null,
    };

    // Layout inside the archive: keep only the daemon/cli/tx binaries (from
    // `bin/`) at the install root; the whole `reddcoin-<ver>/` tree is discarded.
    const extracted_dir = "reddcoin-" ++ core_version;
    const bin_subdir = "bin";
    const promote_files = [_][]const u8{ daemon_file, cli_file, tx_file };

    // Temp file the download streams to (unique to ReddCoin so concurrent installs
    // don't collide on it).
    pub const scratch_file = ".boxwallet-" ++ daemon_file ++ ".part";

    /// Raw `getstakinginfo` result (subset). `enabled` is the daemon-wide
    /// `-staking` switch; `staking` is true only while this wallet is actually
    /// minting — the daemon derives it from its last coinstake search interval
    /// and the wallet's average stake weight, so a wallet that is enabled but
    /// locked, empty, or holding only immature coins reads false. Defaults keep
    /// the parse resilient.
    const RddStakingInfo = struct {
        enabled: bool = false,
        staking: bool = false,
    };

    /// Raw node-level `staking` result (subset). Not a status report on any
    /// wallet — `enabled` is the daemon-wide `-staking` switch and `thread_count`
    /// is how many staking threads `CStakeman` currently has running. Read only
    /// to decide whether the threads still need starting; the wallet's actual
    /// state comes from `RddStakingInfo`.
    const RddStakingSwitch = struct {
        enabled: bool = false,
        running: bool = false,
        thread_count: i64 = 0,
    };

    /// Build the type-erased `Coin` handle for this instance.
    pub fn coin(self: *ReddCoin) Coin {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Live `getblockchaininfo`, normalized for a frontend. ReddCoin reports
    /// `verificationprogress`, so "synced" is derived from it as for Nexa
    /// (Go's `BlockchainIsSynced` => progress > 0.99999).
    pub fn blockchainState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.BlockchainState {
        var parsed = try rpc.callParsed(models.RddBlockchainInfo, allocator, auth, "getblockchaininfo");
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

    /// Live status, normalized for a frontend. ReddCoin 4.x has no `getinfo`, so
    /// the block height comes from `getblockchaininfo`, the peer count from
    /// `getnetworkinfo`, and staking from `getstakinginfo`.
    pub fn daemonInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.DaemonInfo {
        var bc = try rpc.callParsed(models.RddBlockchainInfo, allocator, auth, "getblockchaininfo");
        defer bc.deinit();
        const b = bc.value.result orelse return error.EmptyRpcResult;

        var net = try rpc.callParsed(models.RddNetworkInfo, allocator, auth, "getnetworkinfo");
        defer net.deinit();
        const n = net.value.result orelse return error.EmptyRpcResult;

        // Staking is best-effort: a wallet that can't answer `getstakinginfo`
        // (locked, no wallet loaded, RPC quirk) reads as "not staking" rather than
        // failing the whole poll and flipping the daemon to "down".
        const staking = blk: {
            var st = rpc.callParsed(RddStakingInfo, allocator, auth, "getstakinginfo") catch break :blk false;
            defer st.deinit();
            break :blk if (st.value.result) |s| s.staking else false;
        };

        // `getnetworkinfo`'s numeric CLIENT_VERSION → dotted string, owned by
        // `allocator` so it outlives `net`'s deinit. 4.22.9.4 restored the standard
        // bitcoin encoding (4_220_904 → "4.22.9.4" == core_version), but 4.22.9 and
        // earlier packed the version without the major's millions place (42209 →
        // "0.4.22.9"), so a daemon still on one of those decodes with a spurious
        // leading "0.". Strip it there so the Running line and the on-disk version
        // marker stay comparable to the bundled version rather than reading as an
        // endless "update available".
        const full = try models.clientVersionString(allocator, n.version);
        const version = if (std.mem.startsWith(u8, full, "0.")) blk: {
            defer allocator.free(full);
            break :blk try allocator.dupe(u8, full[2..]);
        } else full;

        return .{
            .blocks = b.blocks,
            .connections = n.connections,
            .staking_active = staking,
            .version = version,
        };
    }

    /// The daemon's default data directory (`~/.reddcoin`), where `reddcoin.conf`
    /// lives.
    pub fn dataDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        return conf.dataDir(allocator, home, home_dir, home_dir_win, home_dir_mac, home_dir_win_base);
    }

    /// The managed wallet's on-disk location — the bitcoin-core 0.21+ wallet
    /// directory holding `wallet.dat`, created by `ensureWallet`. Resolved
    /// against the disk (`walletfile.coreWalletDir`) rather than hard-coded: the
    /// daemon only uses a `wallets/` parent when that directory already exists,
    /// so a data dir BoxWallet created keeps the wallet at `<datadir>/BoxWallet`.
    /// Caller owns the returned strings.
    pub fn walletPath(allocator: std.mem.Allocator, home: []const u8) !?Coin.WalletFile {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        return .{ .path = try walletfile.coreWalletDir(allocator, data_dir, "BoxWallet") };
    }

    /// True if `reddcoind` (`reddcoind.exe` on Windows) is already present under
    /// `install_root`.
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, daemon_file);
    }

    /// Download + unarchive the ReddCoin daemon files into `install_root`.
    ///
    /// Extracts the versioned wrapper dir intact, then `promoteAndTidy` lifts the
    /// daemon/cli/tx binaries to the install root and removes the wrapper.
    pub fn install(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        const dl = download orelse return error.UnsupportedPlatform;
        try install_mod.downloadAndExtract(allocator, dl.url, dl.format, install_root, scratch_file, 0, progress);
        try install_mod.promoteAndTidy(allocator, install_root, extracted_dir, bin_subdir, &promote_files);
    }

    /// Ensure `reddcoin.conf` carries the RPC creds (and `server=1`/`daemon=1`/
    /// `rpcport`) BoxWallet needs before the daemon reads it; existing values are
    /// kept. A standard bitcoin-derived `key=value` conf.
    pub fn prepareConf(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        _ = try conf.populate(allocator, io, data_dir, conf_file, rpc_default_username, rpc_default_port);
    }

    /// ReddCoin is a bitcoin-derived daemon: it forks itself into the background
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

    /// Ask reddcoind to shut down via the JSON-RPC `stop`.
    pub fn requestStop(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        const reply = try rpc.call(allocator, auth, "stop");
        allocator.free(reply);
    }

    /// The name of the wallet BoxWallet loads/creates. Core 22 keeps a named
    /// wallet in its own directory under the data dir, so this is also the
    /// directory holding `wallet.dat` — see `walletDir`.
    pub const wallet_name = "BoxWallet";

    /// ReddCoin 4.x (Bitcoin Core 22) doesn't auto-create a wallet, so the
    /// `staking` status and any address/balance RPCs have none to act on until one
    /// exists. Load-or-create a wallet named "BoxWallet" once the daemon is up.
    pub fn ensureWallet(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        return rpc.ensureWallet(allocator, auth, wallet_name);
    }

    /// The directory holding our named wallet's `wallet.dat`.
    ///
    /// Core 22 puts a named wallet in `<data_dir>/<name>/` (it only uses a
    /// `wallets/` parent when that directory already exists, which it doesn't on
    /// a data dir created by `createwallet` — verified against reddcoind 4.22.9,
    /// where our wallet sits at `~/.reddcoin/BoxWallet/wallet.dat`).
    pub fn walletDir(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        return std.fs.path.join(allocator, &.{ data_dir, wallet_name });
    }

    /// Read the wallet's security state from `getwalletinfo`. ReddCoin is
    /// bitcoin-core style: `unlocked_until` is **absent** on an unencrypted wallet,
    /// `0` when locked, and a positive unlock timestamp otherwise (an unlock on a
    /// proof-of-stake coin is typically for staking).
    pub fn walletSecurityState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.WalletSecurity {
        var parsed = try rpc.callParsed(models.RddWalletInfo, allocator, auth, "getwalletinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return securityFromUnlockedUntil(r.unlocked_until);
    }

    /// Read the wallet's balances from `getwalletinfo`. ReddCoin reports only the
    /// confirmed `balance`, so `total` equals `available` (its reply carries no
    /// mempool/immature split). The triplet is still summed via `fromParts` so the
    /// behaviour matches the other coins if a future daemon adds those fields.
    pub fn walletBalance(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.WalletBalance {
        var parsed = try rpc.callParsed(models.RddWalletInfo, allocator, auth, "getwalletinfo");
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

    /// Map ReddCoin's `listtransactions` `category` to the normalized direction.
    /// ReddCoin 4.x categorizes PoSV coinstakes with dedicated categories
    /// (upstream `PushCoinStakeCategory`): `"stake"` (mature), `"stake-mint"`
    /// (immature), `"stake-orphan"` — all a stake reward at some maturity stage.
    /// `"generate"`/`"immature"`/`"orphan"` are the plain coinbase categories from
    /// the coin's early PoW era. Anything else has no direction (null; dropped).
    fn directionFromCategory(category: []const u8) ?models.TxDirection {
        if (std.mem.eql(u8, category, "receive")) return .received;
        if (std.mem.eql(u8, category, "send")) return .sent;
        if (std.mem.eql(u8, category, "stake") or
            std.mem.eql(u8, category, "stake-mint") or
            std.mem.eql(u8, category, "stake-orphan") or
            std.mem.eql(u8, category, "generate") or
            std.mem.eql(u8, category, "immature") or
            std.mem.eql(u8, category, "orphan")) return .stake;
        return null;
    }

    /// The wallet's most recent transactions, newest-first — the shared
    /// bitcoin-family `listtransactions` flow with ReddCoin's category map.
    pub fn walletTransactions(allocator: std.mem.Allocator, auth: models.CoinAuth, limit: usize) ![]models.WalletTx {
        return rpc.walletTransactions(allocator, auth, limit, directionFromCategory);
    }

    /// Marker label that tracks the wallet's current receive address. ReddCoin's
    /// Core-22 base removed the accounts API (and with it any stable "current
    /// address" RPC), so the shared label flow keeps exactly one address under
    /// this label — see `rpc.receiveAddressLabeled`.
    const receive_label = "boxwallet-receive";

    /// The wallet's receive address: the labelled current one (minted on first
    /// use), or a fresh mint on an explicit user-requested rotation
    /// (`force_new` — only ever called on demand, never polled).
    pub fn receiveAddress(allocator: std.mem.Allocator, auth: models.CoinAuth, force_new: bool) ![]const u8 {
        return rpc.receiveAddressLabeled(allocator, auth, force_new, receive_label);
    }

    /// Send `amount` RDD to `address` via `sendtoaddress` (8-decimal amounts).
    /// The daemon's own rejection reason (invalid address, insufficient funds,
    /// locked wallet) rides back verbatim in the `SendResult`.
    pub fn sendToAddress(allocator: std.mem.Allocator, auth: models.CoinAuth, address: []const u8, amount: f64) !models.SendResult {
        return rpc.sendToAddress(allocator, auth, address, amount, 8);
    }

    /// Encrypt the wallet with `passphrase`. reddcoind stops itself afterwards (the
    /// caller restarts it). The passphrase is JSON-escaped before splicing.
    pub fn walletEncrypt(allocator: std.mem.Allocator, auth: models.CoinAuth, passphrase: []const u8) !void {
        const pw = try rpc.jsonQuote(allocator, passphrase);
        defer allocator.free(pw);
        const params = try std.fmt.allocPrint(allocator, "[{s}]", .{pw});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "encryptwallet", params);
    }

    /// Unlock the wallet via `walletpassphrase`. ReddCoin is proof-of-stake, so a
    /// `staking` unlock adds the third `true` flag (unlock-for-staking-only).
    ///
    /// **Both forms pass a long finite timeout, never `0`.** On this Bitcoin-22
    /// daemon `0` is not "indefinite": it sets the relock time to *now* and
    /// schedules the relock immediately, so the RPC returns success on a wallet
    /// that is already locked again — BoxWallet said "Wallet unlocked" while
    /// `getwalletinfo` still read `unlocked_until: 0` (verified against reddcoind
    /// 4.22.9). The daemon clamps anything above 100000000s, so 9999999 (~115
    /// days) is well inside what it accepts and matches the convention the other
    /// coins here use for "until the user locks it or the daemon restarts".
    pub fn walletUnlock(allocator: std.mem.Allocator, auth: models.CoinAuth, passphrase: []const u8, staking: bool) !void {
        const pw = try rpc.jsonQuote(allocator, passphrase);
        defer allocator.free(pw);
        const params = if (staking)
            try std.fmt.allocPrint(allocator, "[{s},9999999,true]", .{pw})
        else
            try std.fmt.allocPrint(allocator, "[{s},9999999]", .{pw});
        defer allocator.free(params);
        try rpc.callExpectOk(allocator, auth, "walletpassphrase", params);
        if (staking) try enableStaking(allocator, auth);
    }

    /// Put the wallet on the staking list and start the daemon's staking threads.
    ///
    /// **The unlock-for-staking flag is necessary but not sufficient on ReddCoin
    /// 4.x.** `walletpassphrase …, true` only says "these keys may be used to
    /// mint"; whether the wallet mints at all is a *second*, per-wallet switch,
    /// and a fresh node has it off. `CStakeman::Start` launches a thread only for
    /// wallets whose `GetEnableStaking()` is set — set either by `setstaking` or
    /// by `-stake=<wallet>` at startup — so with the switch off there is no
    /// staking thread, `getstakinginfo` reports `search-interval: 0`, and
    /// `staking` stays false however much stake weight and unlocked time the
    /// wallet has (verified against reddcoind 4.22.9.4 on a synced node with a
    /// balance: unlocked-for-staking, `thread_count: 0`, not staking).
    ///
    /// So: `setstaking` sets the switch, then the node-level `staking` starts the
    /// threads so it takes effect now rather than at the next daemon start.
    ///
    /// **`staking true` is only sent when no thread is running.** It doesn't
    /// resume a staking session, it *starts* one: `CStakeman::StakeWalletAdd`
    /// pushes a fresh thread for every enabled wallet with no check for one it
    /// already has, so sending it twice leaves two threads minting the same
    /// wallet (reproduced live: a second unlock took `thread_count` 1 → 2). Worse,
    /// the thread map keeps only the newest id per wallet, so the older duplicate
    /// can't be stopped again short of a daemon restart. `setstaking` is safely
    /// idempotent and always sent; the thread start is guarded on the count.
    ///
    /// `setstaking`'s second argument would persist the wallet into the data
    /// dir's `settings.json` — deliberately not passed. It's a shared dir we
    /// don't own (see the data-dir rule), and it would buy nothing: the wallet
    /// relocks on every daemon restart, so staking has to be re-armed with the
    /// passphrase anyway, which is this call.
    fn enableStaking(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        try rpc.callExpectOk(allocator, auth, "setstaking", "[true]");

        var sw = try rpc.callParsed(RddStakingSwitch, allocator, auth, "staking");
        defer sw.deinit();
        const running = if (sw.value.result) |r| r.thread_count > 0 else false;
        if (running) return;

        try rpc.callExpectOk(allocator, auth, "staking", "[true]");
    }

    /// Re-lock the wallet via `walletlock`.
    pub fn walletLock(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        return rpc.callExpectOk(allocator, auth, "walletlock", "[]");
    }

    /// Back up the wallet to `dest_path` via `dumpwallet` — a human-readable dump
    /// of the wallet's keys + HD seed that the user keeps as their backup (it is
    /// the backup, not a temp: don't shred it). reddcoind refuses this on a locked
    /// wallet, so the UI only offers it when the wallet is unlocked/unencrypted.
    /// The path is JSON-escaped before splicing.
    pub fn walletBackup(allocator: std.mem.Allocator, auth: models.CoinAuth, dest_path: []const u8) !void {
        const qpath = try rpc.jsonQuote(allocator, dest_path);
        defer allocator.free(qpath);
        const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qpath});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "dumpwallet", params);
    }

    /// Restore wallet keys from a `dumpwallet` file via `importwallet`, which
    /// imports the keys and rescans the chain. The rescan blocks the RPC until it
    /// finishes, so on a slow machine this can outlast the client timeout and read
    /// as a failure even though reddcoind keeps rescanning — acceptable for v1.
    /// Like backup, requires the wallet unlocked/unencrypted. Path JSON-escaped.
    ///
    /// **The file is checked to be a key dump first**, because `importwallet`
    /// cannot report that it wasn't: it reads the file line by line and skips
    /// whatever it can't parse, so handed a *binary* `wallet.dat` it returns a
    /// clean success having imported zero keys — telling the user their wallet
    /// was restored when nothing was. A success indistinguishable from a no-op is
    /// worse than a refusal, so a file without the dump header is rejected and
    /// pointed at the wallet.dat option (`walletRestoreFileOffline`) instead.
    pub fn walletImportFile(allocator: std.mem.Allocator, auth: models.CoinAuth, src_path: []const u8) !void {
        if (!walletfile.looksLikeKeyDump(allocator, src_path)) return error.NotAWalletKeyDump;

        const qpath = try rpc.jsonQuote(allocator, src_path);
        defer allocator.free(qpath);
        const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qpath});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "importwallet", params);
    }

    /// Restore the wallet by swapping in a user-supplied binary `wallet.dat` —
    /// the file-level counterpart to `walletImportFile`'s key-dump import, for a
    /// wallet brought from another Reddcoin Core install (its own backup is a
    /// `backupwallet` copy, which `importwallet` cannot read). The daemon holds
    /// `wallet.dat` open while running, so the caller stops it before calling this
    /// and restarts it after; this hook only touches files and takes no auth.
    ///
    /// The swap targets our **named** wallet's directory
    /// (`<data_dir>/BoxWallet/wallet.dat`), not the data dir root — that's the
    /// wallet `ensureWallet` loads and every wallet RPC then acts on. A default
    /// wallet belonging to another Reddcoin install is left untouched.
    ///
    /// Safety (in `walletfile.restoreOffline`): a text key dump or an empty file
    /// is refused before anything is touched, and the current `wallet.dat` is
    /// moved aside to a timestamped sibling so a wrong-file restore stays
    /// recoverable.
    pub fn walletRestoreFileOffline(
        allocator: std.mem.Allocator,
        home: []const u8,
        src_path: []const u8,
    ) !void {
        const wallet_dir = try walletDir(allocator, home);
        defer allocator.free(wallet_dir);

        return walletfile.restoreOffline(allocator, wallet_dir, "wallet.dat", src_path);
    }

    /// ReddCoin dropped `getinfo`, so probe `getnetworkinfo` for the daemon's
    /// warm-up phase (any supported method returns the "-28 in warm-up" reply).
    pub fn warmupProbeMethod() []const u8 {
        return "getnetworkinfo";
    }

    // --- vtable plumbing -------------------------------------------------

    /// The block-index rebuild. Markers are the Core-derived defaults, checked
    /// against the shipped reddcoind binary.
    pub const reindex_caps: Coin.Reindex = .{
        .warning = "reddcoind re-reads the block files already on disk to rebuild the index — hours of CPU on a large chain, and the daemon is unusable until it finishes. Nothing is downloaded a second time unless this node is pruned, in which case the blocks it has already deleted are fetched again.",
    };

    const vtable: Coin.VTable = .{
        .coin_name = vtCoinName,
        .coin_name_abbrev = vtCoinNameAbbrev,
        .coin_description = vtCoinDescription,
        .coin_color = vtCoinColor,
        .tip_address = vtTipAddress,
        .wordmark = vtWordmark,
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
        .wallet_backup = vtWalletBackup,
        .wallet_import_file = vtWalletImportFile,
        .wallet_restore_file_offline = vtWalletRestoreFileOffline,
        .warmup_probe_method = vtWarmupProbeMethod,
        .reindex = &reindex_caps,
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
    /// "Redd" in `coin_color`, "Coin" in `coin_color_alt`.
    fn vtWordmark(_: *anyopaque) Coin.Wordmark {
        return .{ .split = wordmark_split, .alt_color = coin_color_alt };
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
    fn vtWalletBackup(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        dest_path: []const u8,
    ) anyerror!void {
        return walletBackup(allocator, auth, dest_path);
    }
    fn vtWalletImportFile(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        src_path: []const u8,
    ) anyerror!void {
        return walletImportFile(allocator, auth, src_path);
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
};

test "parses getblockchaininfo into normalized BlockchainState" {
    const allocator = std.testing.allocator;

    // Canned daemon reply — proves parse + map without a running reddcoind.
    const raw =
        \\{"result":{"chain":"main","blocks":4567890,"headers":4567890,
        \\"bestblockhash":"deadbeef","difficulty":1234.5,
        \\"verificationprogress":0.999997,"chainwork":"abc"},
        \\"error":null,"id":"boxwallet"}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.RddBlockchainInfo),
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
    try std.testing.expectEqual(@as(i64, 4567890), state.blocks);
    try std.testing.expect(state.synced);
}

test "combines getnetworkinfo + getstakinginfo into DaemonInfo (no getinfo, PoSV)" {
    const allocator = std.testing.allocator;

    // ReddCoin 4.x has no `getinfo`: peers come from getnetworkinfo and staking
    // from `getstakinginfo`. Prove each parses, then the staking decode.
    const net_raw =
        \\{"result":{"version":4220904,"subversion":"/ReddCoin:4.22.9.4/",
        \\"connections":16,"networkactive":true},"error":null,"id":"boxwallet"}
    ;
    // Verbatim getstakinginfo shape (4.22.9.4).
    const staking_raw =
        \\{"result":{"enabled":true,"staking":true,"chain":"main","blocks":4567890,
        \\"difficulty":123.45,"networkhashps":0,"pooledtx":3,"search-interval":16,
        \\"averageweight":12345,"totalweight":67890,"netstakeweight":112233,
        \\"expectedtime":120,"warnings":""},"error":null,"id":"boxwallet"}
    ;

    var net = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.RddNetworkInfo),
        allocator,
        net_raw,
        .{ .ignore_unknown_fields = true },
    );
    defer net.deinit();
    var st = try std.json.parseFromSlice(
        models.JsonRpcResponse(ReddCoin.RddStakingInfo),
        allocator,
        staking_raw,
        .{ .ignore_unknown_fields = true },
    );
    defer st.deinit();

    const info: models.DaemonInfo = .{
        .blocks = 4567890,
        .connections = net.value.result.?.connections,
        .staking_active = if (st.value.result) |s| s.staking else false,
    };

    try std.testing.expectEqual(@as(i64, 16), info.connections);
    try std.testing.expect(info.staking_active);
}

test "the `staking` RPC carries no staking flag — hence getstakinginfo" {
    const allocator = std.testing.allocator;

    // Verbatim `staking` reply (4.22.9.4): the daemon-wide switch, the staking
    // thread count, and a per-wallet enable list — and no `staking` key. Reading
    // it left `staking_active` on its `false` default no matter what the wallet
    // was doing, which is why the status glyph never pulsed. Kept as a guard
    // against anyone pointing the poll back at it.
    const staking_raw =
        \\{"result":{"enabled":true,"running":true,"thread_count":1,
        \\"enabled_wallet":[{"BoxWallet":true}]},"error":null,"id":"boxwallet"}
    ;

    var st = try std.json.parseFromSlice(
        models.JsonRpcResponse(ReddCoin.RddStakingInfo),
        allocator,
        staking_raw,
        .{ .ignore_unknown_fields = true },
    );
    defer st.deinit();

    try std.testing.expect(!st.value.result.?.staking);

    // What it does carry: the thread count enableStaking guards on, so a second
    // unlock-for-staking doesn't pile a duplicate thread onto the same wallet.
    var sw = try std.json.parseFromSlice(
        models.JsonRpcResponse(ReddCoin.RddStakingSwitch),
        allocator,
        staking_raw,
        .{ .ignore_unknown_fields = true },
    );
    defer sw.deinit();

    try std.testing.expectEqual(@as(i64, 1), sw.value.result.?.thread_count);
}

test "daemon CLIENT_VERSION drops ReddCoin's legacy leading-0 major" {
    const allocator = std.testing.allocator;

    // 4.22.9.4 encodes CLIENT_VERSION the standard bitcoin way (4_220_904), which
    // decodes straight to the branded, bundled version — the strip is a no-op.
    const current = try models.clientVersionString(allocator, 4_220_904);
    defer allocator.free(current);
    try std.testing.expectEqualStrings("4.22.9.4", current);
    try std.testing.expectEqualStrings(
        ReddCoin.core_version,
        if (std.mem.startsWith(u8, current, "0.")) current[2..] else current,
    );

    // 4.22.9 and earlier dropped the major's millions place (42209), which the
    // bitcoin decoder renders as the 4-part "0.4.22.9". daemonInfo strips the
    // leading "0." so a daemon still on one of those reports the branded "4.22.9"
    // and stays comparable to core_version instead of reading as a wild mismatch.
    const legacy = try models.clientVersionString(allocator, 42209);
    defer allocator.free(legacy);
    try std.testing.expectEqualStrings("0.4.22.9", legacy);
    try std.testing.expectEqualStrings("4.22.9", legacy[2..]);
}

test "staking RPC absent or wallet-locked reads as not staking" {
    const allocator = std.testing.allocator;

    // A method-not-found / no-wallet reply parses with result == null → false,
    // rather than failing the poll.
    const raw = "{\"result\":null,\"error\":{\"code\":-32601,\"message\":\"Method not found\"},\"id\":\"boxwallet\"}";
    var st = try std.json.parseFromSlice(
        models.JsonRpcResponse(ReddCoin.RddStakingInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer st.deinit();
    const staking = if (st.value.result) |s| s.staking else false;
    try std.testing.expect(!staking);
}

test "platform selection resolves a download for supported targets" {
    // ReddCoin ships Linux (x86_64/aarch64/arm), Windows, and macOS (osx64)
    // builds, so the current target should resolve a tar.gz (or zip on Windows).
    if (ReddCoin.download) |dl| {
        switch (builtin.os.tag) {
            .windows => try std.testing.expectEqual(install_mod.Format.zip, dl.format),
            else => try std.testing.expectEqual(install_mod.Format.tar_gz, dl.format),
        }
        try std.testing.expect(std.mem.indexOf(u8, dl.url, ReddCoin.core_version) != null);
    }

    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("reddcoind.exe", ReddCoin.daemon_file);
    } else {
        try std.testing.expectEqualStrings("reddcoind", ReddCoin.daemon_file);
    }
}

test "coin vtable dispatches to ReddCoin metadata" {
    var rdd: ReddCoin = .{};
    const c = rdd.coin();
    try std.testing.expectEqualStrings("ReddCoin", c.coinName());
    try std.testing.expectEqualStrings("RDD", c.coinNameAbbrev());
    try std.testing.expectEqualStrings("#e30613", c.coinColor());
    try std.testing.expect(c.isProofOfStake());
    try std.testing.expectEqualStrings("reddcoin.conf", c.confFile());
    try std.testing.expectEqualStrings("reddcoind" ++ ReddCoin.exe_suffix, c.daemonFile());
    try std.testing.expectEqualStrings("45443", c.rpcDefaultPort());
    // Core-22 fork: needs an explicit wallet created/loaded after start.
    try std.testing.expect(c.needsWallet());
    // Bitcoin-core wallet over RPC: the `w` menu and the balance lines are both on.
    try std.testing.expect(c.supportsWallet());
    try std.testing.expect(c.supportsBalance());
}

test "directionFromCategory maps listtransactions categories to normalized direction" {
    try std.testing.expectEqual(models.TxDirection.received, ReddCoin.directionFromCategory("receive").?);
    try std.testing.expectEqual(models.TxDirection.sent, ReddCoin.directionFromCategory("send").?);
    // ReddCoin 4.x PoSV coinstakes carry dedicated categories (upstream
    // `PushCoinStakeCategory`) — all map to the normalized stake direction.
    try std.testing.expectEqual(models.TxDirection.stake, ReddCoin.directionFromCategory("stake").?);
    try std.testing.expectEqual(models.TxDirection.stake, ReddCoin.directionFromCategory("stake-mint").?);
    try std.testing.expectEqual(models.TxDirection.stake, ReddCoin.directionFromCategory("stake-orphan").?);
    // Plain coinbase categories from the coin's early PoW era.
    try std.testing.expectEqual(models.TxDirection.stake, ReddCoin.directionFromCategory("generate").?);
    try std.testing.expectEqual(models.TxDirection.stake, ReddCoin.directionFromCategory("immature").?);
    try std.testing.expectEqual(models.TxDirection.stake, ReddCoin.directionFromCategory("orphan").?);
    // No direction — dropped by the shared mapper.
    try std.testing.expect(ReddCoin.directionFromCategory("move") == null);
    try std.testing.expect(ReddCoin.directionFromCategory("something-unknown") == null);
}

test "coin vtable exposes transactions, receive address, and send for ReddCoin" {
    var rdd: ReddCoin = .{};
    const c = rdd.coin();
    try std.testing.expect(c.supportsTransactions());
    try std.testing.expect(c.supportsReceiveAddress());
    try std.testing.expect(c.supportsSend());
}

test "coin vtable offers both restore shapes for ReddCoin" {
    var rdd: ReddCoin = .{};
    const c = rdd.coin();
    // The key-dump import (live daemon, importwallet)…
    try std.testing.expect(c.supportsWalletImport());
    // …and the daemon-stopped wallet.dat swap, which is what moves a wallet
    // brought from another Reddcoin Core install (its `backupwallet` copy is
    // binary — importwallet can't read it).
    try std.testing.expect(c.supportsWalletRestoreOffline());
}

test "offline restore swaps the named wallet's wallet.dat, not the data dir root" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-rdd-offline-restore";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // The wallet reddcoind actually acts on lives in the *named* wallet dir.
    const wallet_dir = try ReddCoin.walletDir(allocator, home);
    defer allocator.free(wallet_dir);
    var wd = try std.Io.Dir.cwd().createDirPathOpen(io, wallet_dir, .{});
    defer wd.close(io);
    try wd.writeFile(io, .{ .sub_path = "wallet.dat", .data = "OLD-WALLET" });

    // A default wallet belonging to some other Reddcoin install, at the data
    // dir root. The restore must not touch it.
    const data_dir = try ReddCoin.dataDir(allocator, home);
    defer allocator.free(data_dir);
    var dd = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
    defer dd.close(io);
    try dd.writeFile(io, .{ .sub_path = "wallet.dat", .data = "SOMEONE-ELSES-WALLET" });

    var src = try std.Io.Dir.cwd().createDirPathOpen(io, home ++ "/backups", .{});
    defer src.close(io);
    try src.writeFile(io, .{ .sub_path = "wallet.dat", .data = "NEW-WALLET" });

    try ReddCoin.walletRestoreFileOffline(allocator, home, home ++ "/backups/wallet.dat");

    const restored = try wd.readFileAlloc(io, "wallet.dat", allocator, .limited(64));
    defer allocator.free(restored);
    try std.testing.expectEqualStrings("NEW-WALLET", restored);

    const other = try dd.readFileAlloc(io, "wallet.dat", allocator, .limited(64));
    defer allocator.free(other);
    try std.testing.expectEqualStrings("SOMEONE-ELSES-WALLET", other);
}

test "walletImportFile refuses a binary wallet.dat, which importwallet would 'succeed' on" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-rdd-import-guard";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "wallet.dat", .data = "\x00\x00\x00\x00\x62\x31\x05\x00binary" });

    // Refused before any RPC — the auth here is never reached, so this needs no
    // daemon. Handing the file to `importwallet` would report success having
    // imported nothing.
    const auth: models.CoinAuth = .{
        .rpc_user = "u",
        .rpc_password = "p",
        .ip_address = "127.0.0.1",
        .port = "1",
    };
    try std.testing.expectError(
        error.NotAWalletKeyDump,
        ReddCoin.walletImportFile(allocator, auth, root ++ "/wallet.dat"),
    );
}

test "walletPath points at the bitcoin-core BoxWallet directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var rdd: ReddCoin = .{};
    // No `wallets/` directory under this (non-existent) data dir, so the daemon
    // would keep the named wallet directly under it — the layout `createwallet`
    // actually produces. See `walletfile.coreWalletDir`.
    const wf = (try rdd.coin().walletPath(allocator, "/home/alice")).?;
    defer allocator.free(wf.path);
    try std.testing.expectEqualStrings("/home/alice/.reddcoin/BoxWallet", wf.path);
    try std.testing.expect(wf.keys == null);
}

test "maps getwalletinfo unlocked_until to the wallet security state" {
    // Bitcoin-core style: absent → unencrypted, 0 → locked, positive → unlocked.
    try std.testing.expectEqual(models.WalletSecurity.unencrypted, ReddCoin.securityFromUnlockedUntil(null));
    try std.testing.expectEqual(models.WalletSecurity.locked, ReddCoin.securityFromUnlockedUntil(0));
    try std.testing.expectEqual(models.WalletSecurity.unlocked, ReddCoin.securityFromUnlockedUntil(1893456000));
}

test "maps getwalletinfo balance to available + total (no mempool split)" {
    const allocator = std.testing.allocator;

    // ReddCoin reports only `balance`; total collapses to the confirmed figure.
    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.RddWalletInfo),
        allocator,
        "{\"result\":{\"walletversion\":60000,\"balance\":42.5,\"unlocked_until\":0},\"error\":null,\"id\":\"boxwallet\"}",
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    const bal = models.WalletBalance.fromParts(r.balance, r.unconfirmed_balance, r.immature_balance);
    try std.testing.expectApproxEqAbs(@as(f64, 42.5), bal.available, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 42.5), bal.total, 1e-9);
    try std.testing.expect(!bal.hasPending());
}
