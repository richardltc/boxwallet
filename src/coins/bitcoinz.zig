const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const rpc = @import("../rpc.zig");
const install_mod = @import("../install.zig");
const conf = @import("../conf.zig");
const walletfile = @import("../walletfile.zig");
const Coin = @import("../coin.zig").Coin;

/// BitcoinZ backend.
///
/// BitcoinZ is a zcashd fork (Bitcoin 0.11 lineage with Zcash's shielded
/// tech), which sets it apart from the Core-derived coins in four ways:
///
///   * **It needs the Zcash zk-SNARK proving parameters** (three files, ~780 MB,
///     shared across every zcashd-family app in the per-platform `ZcashParams`
///     dir) or the daemon shuts itself down at startup. `install` fetches any
///     that are missing — checksum-verified, never re-downloading or touching
///     files already there (they may be a zcashd install's).
///   * **Wallet encryption is disabled upstream** (zcashd ships `encryptwallet`
///     behind developer-experimental flags because it doesn't cover shielded
///     keys), so `wallet_encrypt` is left null and the `w` menu offers backup/
///     restore without an Encrypt action. Unlock/lock stay wired for the rare
///     wallet encrypted elsewhere.
///   * **`dumpwallet` only writes inside the daemon's `-exportdir`** (bare
///     alphanumeric filename, no paths), so `prepareConf` points `exportdir` at
///     a subdir of the data dir and `walletBackup` copies the dump out to the
///     user's chosen destination, then shreds the original.
///   * **No accounts, no labels**: the receive address comes from the wallet's
///     address book (`listaddresses`), minting the first one on a fresh wallet.
///
/// Heads-up for a future release: 2.2.0 carries zcashd's auto-deprecation and
/// hard-stops at block 1,993,192 (`src/deprecation.h` upstream, no override
/// flag) — expected around early 2027 at 2.5-minute blocks, by when upstream
/// plans a successor release to bump `core_version` to.
pub const BitcoinZ = struct {
    /// Whether the coin is exposed in the nav. False keeps it out of the left
    /// bar entirely (registered but hidden) until it's ready for users.
    pub const live = true;
    pub const coin_name = "BitcoinZ";
    pub const coin_name_abbrev = "BTCZ";
    /// One-line description shown under the coin name on the detail pane.
    pub const coin_description = "Community-driven Bitcoin fork with Zcash privacy tech.";
    /// BitcoinZ brand gold (`#RRGGBB`), for tinting the coin in the frontend.
    pub const coin_color = "#F5A623";
    /// This coin's id on the price host, for the USD quote beside its
    /// balance (see `src/price.zig`).
    pub const price_id = "bitcoinz";
    /// Two-tone wordmark: "Bitcoin" in white, the trailing "Z" in the brand
    /// gold — the SpiderByte colour assignment (white head, brand tail).
    pub const wordmark_head_color = "#ffffff";
    pub const wordmark_split = "Bitcoin".len;
    /// Donation address for BoxWallet development, in BitcoinZ's own currency.
    /// TODO(richard): replace with the real BTCZ tip address.
    pub const tip_address = "t1fJS8kqdDNo5EyRuiNV3qPCFZmy5pbrb5Q";
    /// BitcoinZ is proof-of-work (Equihash) — no wallet staking.
    pub const proof_of_stake = false;
    pub const conf_file = "bitcoinz.conf";
    pub const home_dir = ".bitcoinz";
    pub const home_dir_win = "BitcoinZ";
    /// Which Windows directory that name hangs off — the roaming `%APPDATA%`, as
    /// every bitcoin-derived daemon picks. See `conf.WinBase`.
    pub const home_dir_win_base: conf.WinBase = .roaming;
    /// macOS data dir name: `~/Library/Application Support/BitcoinZ` (upstream
    /// `util.cpp` `GetDefaultDataDir`).
    pub const home_dir_mac: ?[]const u8 = "BitcoinZ";
    pub const rpc_default_username = "bitcoinzrpc";
    /// Mainnet RPC port (upstream `chainparamsbase.cpp`).
    pub const rpc_default_port = "1979";
    pub const core_version = "2.2.0";

    // Binary names. Windows appends `.exe`; Linux/macOS use the bare names.
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    pub const daemon_file = "bitcoinzd" ++ exe_suffix;
    pub const cli_file = "bitcoinz-cli" ++ exe_suffix;
    pub const tx_file = "bitcoinz-tx" ++ exe_suffix;

    // Download host. The 2.2.0 assets are keyed by a build commit hash rather
    // than the version, identically across platforms — every bundle wraps its
    // executables in `bitcoinz-<hash>/bin/`.
    const build_tag = "e90047d4ae65";
    const download_base = "https://github.com/btcz/bitcoinz/releases/download/" ++ core_version ++ "/bitcoinz-" ++ build_tag ++ "-";

    /// The download URL + archive format for the build target, or null where
    /// BitcoinZ publishes no matching daemon bundle. Selected at comptime from
    /// the OS/arch. 2.2.0 covers every desktop target, including a native
    /// Apple-Silicon build:
    ///   - Linux x86_64/aarch64: `.tar.gz`.
    ///   - Windows x86_64: `win64.zip` (extracted from the seekable scratch file).
    ///   - macOS x86_64/arm64: their respective `apple-darwin.tar.gz`.
    const download: ?install_mod.Download = switch (builtin.os.tag) {
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => .{ .url = download_base ++ "win64.zip", .format = .zip },
            else => null,
        },
        .macos => switch (builtin.cpu.arch) {
            .x86_64 => .{ .url = download_base ++ "x86_64-apple-darwin.tar.gz", .format = .tar_gz },
            .aarch64 => .{ .url = download_base ++ "arm64-apple-darwin.tar.gz", .format = .tar_gz },
            else => null,
        },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => .{ .url = download_base ++ "x86_64-linux-gnu.tar.gz", .format = .tar_gz },
            .aarch64 => .{ .url = download_base ++ "aarch64-linux-gnu.tar.gz", .format = .tar_gz },
            else => null,
        },
        else => null,
    };

    // Layout inside the archive: keep only the daemon/cli/tx binaries (from
    // `bin/`) at the install root; the whole `bitcoinz-<hash>/` tree is discarded.
    const extracted_dir = "bitcoinz-" ++ build_tag;
    const bin_subdir = "bin";
    const promote_files = [_][]const u8{ daemon_file, cli_file, tx_file };

    // Temp file the download streams to. Keyed off the daemon name so a concurrent
    // install of another coin into the same `~/.boxwallet` root uses a different
    // scratch file and the two never collide.
    pub const scratch_file = ".boxwallet-" ++ daemon_file ++ ".part";

    // --- Zcash proving parameters ----------------------------------------
    //
    // bitcoinzd refuses to start (shuts down from init) unless all three zk-SNARK
    // parameter files are present in the shared per-platform ZcashParams dir. They
    // are the same files every zcashd-family app uses, served from the Zcash
    // Foundation's download host, and pinned by SHA-256 (the hashes upstream's own
    // `fetch-params.sh` verifies). `ensureParams` fetches only what's missing:
    // a file already there is another app's property and is never re-downloaded,
    // overwritten, or even re-hashed.

    /// One proving-parameter file: its canonical name and pinned SHA-256.
    const ParamFile = struct { name: []const u8, sha256: *const [64]u8 };

    pub const zcash_params = [_]ParamFile{
        // ~48 MB
        .{ .name = "sapling-spend.params", .sha256 = "8e48ffd23abb3a5fd9c5589204f32d9c31285a04b78096ba40a79b75677efc13" },
        // ~3.6 MB
        .{ .name = "sapling-output.params", .sha256 = "2f0ebbcbb9bb0bcffe95a397e7eba89c29eb4dde6191c339db88570e3f3fb0e4" },
        // ~726 MB — the bulk of the install download
        .{ .name = "sprout-groth16.params", .sha256 = "b685d700c60328498fbde589c8c7c484c722b788b265b72af448a5bf0ee55b50" },
    };

    const params_download_base = "https://download.z.cash/downloads/";

    /// The shared Zcash params directory for an explicit `os` — split out (like
    /// `conf.dataDirFor`) so every platform's path is checkable from one native
    /// test run. Upstream `util.cpp` `ZC_GetBaseParamsDir`: `~/.zcash-params` on
    /// Linux, `~/Library/Application Support/ZcashParams` on macOS,
    /// `%APPDATA%\ZcashParams` on Windows.
    fn paramsDirFor(allocator: std.mem.Allocator, home: []const u8, os: std.Target.Os.Tag) ![]const u8 {
        return conf.dataDirFor(allocator, home, os, ".zcash-params", "ZcashParams", "ZcashParams", .roaming);
    }

    /// The shared Zcash params directory for the build target. An empty `home`
    /// is rejected rather than tolerated: `path.join` would drop it and yield a
    /// *relative* `.zcash-params`, scattering ~780 MB into whatever the process's
    /// CWD happens to be instead of the dir every zcashd-family app shares.
    pub fn paramsDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        if (home.len == 0) return error.NoHomeDir;
        return paramsDirFor(allocator, home, builtin.os.tag);
    }

    /// Ensure all three proving-parameter files are present in the shared params
    /// dir, downloading (with progress) and checksum-verifying any that are
    /// missing. Each download lands in a scratch `.part` first and is renamed
    /// into place only after its SHA-256 matches the pin, so a torn or tampered
    /// download can never sit where the daemon would load it.
    fn ensureParams(
        allocator: std.mem.Allocator,
        home: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        const dir_path = try paramsDir(allocator, home);
        defer allocator.free(dir_path);

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        for (zcash_params) |p| {
            // Already present → another zcash app's (or a previous install's);
            // share it untouched.
            if (install_mod.fileExists(allocator, dir_path, p.name)) continue;

            const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ params_download_base, p.name });
            defer allocator.free(url);
            const scratch = try std.fmt.allocPrint(allocator, ".boxwallet-{s}.part", .{p.name});
            defer allocator.free(scratch);

            var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
            defer dir.close(io);
            // Never leave a torn or unverified download behind — a retry (or the
            // user) could mistake it for a good file.
            errdefer dir.deleteFile(io, scratch) catch {};

            try install_mod.downloadFile(allocator, url, dir_path, scratch, progress);
            if (!install_mod.fileMatchesSha256(allocator, dir_path, scratch, p.sha256))
                return error.ParamsChecksumMismatch;
            try dir.rename(scratch, dir, p.name, io);
        }
    }

    /// Build the type-erased `Coin` handle for this instance.
    pub fn coin(self: *BitcoinZ) Coin {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Live `getblockchaininfo`, normalized for a frontend. BitcoinZ reports
    /// `verificationprogress` (checkpoint-derived, like every bitcoin-family
    /// daemon), so "synced" is derived from it as for Bitcoin. There is no tip
    /// `time` field on this lineage — `mediantime` carries the behind-by hint.
    pub fn blockchainState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.BlockchainState {
        var parsed = try rpc.callParsed(models.BtczBlockchainInfo, allocator, auth, "getblockchaininfo");
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
            .tip_time = if (r.time > 0) r.time else r.mediantime,
        };
    }

    /// Live status, normalized for a frontend. The block height comes from
    /// `getblockchaininfo` and the peer count + version from `getnetworkinfo`.
    /// BitcoinZ is proof-of-work, so `staking_active` is false.
    pub fn daemonInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.DaemonInfo {
        var bc = try rpc.callParsed(models.BtczBlockchainInfo, allocator, auth, "getblockchaininfo");
        defer bc.deinit();
        const b = bc.value.result orelse return error.EmptyRpcResult;

        var net = try rpc.callParsed(models.BtczNetworkInfo, allocator, auth, "getnetworkinfo");
        defer net.deinit();
        const n = net.value.result orelse return error.EmptyRpcResult;

        return .{
            .blocks = b.blocks,
            .connections = n.connections,
            .staking_active = false,
            // Numeric CLIENT_VERSION → release string (see `versionFromClient`),
            // owned by `allocator` so it outlives `net`'s deinit.
            .version = try versionFromClient(allocator, n.version),
        };
    }

    /// Decode BitcoinZ's numeric CLIENT_VERSION into the release string it names.
    /// zcashd forks encode *release status* in the build component (0–24 beta,
    /// 25–49 rc, 50 = the official release), so v2.2.0's wire version 2020050
    /// must read "2.2.0" — the generic `clientVersionString` renders "2.2.0.50",
    /// which `differs` from the pinned "2.2.0" and permanently flags a fresh
    /// install's daemon as "not the bundled version". Non-release builds
    /// (build != 50) keep the four-part decode so a beta/rc *does* read as
    /// different from the pinned release.
    fn versionFromClient(allocator: std.mem.Allocator, v: i64) ![]u8 {
        if (v > 0 and @mod(v, 100) == 50) {
            return std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{
                @divTrunc(v, 1_000_000),
                @mod(@divTrunc(v, 10_000), 100),
                @mod(@divTrunc(v, 100), 100),
            });
        }
        return models.clientVersionString(allocator, v);
    }

    /// The daemon's default data directory (`~/.bitcoinz`), where `bitcoinz.conf`
    /// lives.
    pub fn dataDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        return conf.dataDir(allocator, home, home_dir, home_dir_win, home_dir_mac, home_dir_win_base);
    }

    /// The managed wallet's on-disk location — zcashd-era daemons keep a single
    /// auto-created `wallet.dat` directly in the data dir (no `wallets/` subdir).
    /// Caller owns the returned strings.
    pub fn walletPath(allocator: std.mem.Allocator, home: []const u8) !?Coin.WalletFile {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        return .{ .path = try std.fs.path.join(allocator, &.{ data_dir, "wallet.dat" }) };
    }

    /// True if `bitcoinzd` (`bitcoinzd.exe` on Windows) is already present under
    /// `install_root`.
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, daemon_file);
    }

    /// Download + unarchive the BitcoinZ daemon files into `install_root`, then
    /// ensure the Zcash proving parameters are in the shared params dir (the
    /// daemon refuses to start without them). Optionally reports download/extract
    /// progress; the params add up to ~780 MB on a machine with no zcash-family
    /// app installed, and nothing when the files are already there.
    pub fn install(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        const dl = download orelse return error.UnsupportedPlatform;
        try install_mod.downloadAndExtract(allocator, dl.url, dl.format, install_root, scratch_file, 0, progress);
        try install_mod.promoteAndTidy(allocator, install_root, extracted_dir, bin_subdir, &promote_files);
        try ensureParams(allocator, home, progress);
    }

    /// Subdir of the data dir the daemon's `-exportdir` points at — where
    /// `dumpwallet` is allowed to write (the daemon creates it on first use).
    const export_subdir = "export";

    /// Known-good peers seeded into the conf so a fresh node finds the network
    /// quickly (BitcoinZ's seeding is thin enough that initial sync can stall
    /// peerless without them). 1989 is the mainnet P2P port. `addnode` is purely
    /// additive — the daemon just also tries these — and `prepareConf` appends
    /// each line only when it isn't already present, so a user's own addnode
    /// entries are always kept.
    pub const seed_nodes = [_][]const u8{
        "addnode=37.187.76.80:1989",
        "addnode=51.222.50.26:1989",
        "addnode=152.89.232.103:1989",
        "addnode=146.59.69.245:1989",
        "addnode=90.157.141.190:1989",
        "addnode=45.32.135.197:1989",
        "addnode=173.176.66.36:1989",
        "addnode=57.128.236.79:1989",
        "addnode=explorer.btcz.app:1989",
        "addnode=explorer.btcz.rocks:1989",
    };

    /// Ensure `bitcoinz.conf` carries the RPC creds (and `server=1`/`rpcport`)
    /// BoxWallet needs before the daemon reads it; existing values are kept. Also
    /// appends the missing `seed_nodes` (see there), and points `exportdir` at
    /// `<datadir>/export` when the user hasn't set one: zcashd-era `dumpwallet`
    /// writes only inside `-exportdir` and there is no default, so without it
    /// the wallet-backup RPC can never succeed. An adopted conf's own
    /// `exportdir` wins untouched.
    pub fn prepareConf(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        _ = try conf.populate(allocator, io, data_dir, conf_file, rpc_default_username, rpc_default_port);
        _ = try conf.ensureLines(allocator, io, data_dir, conf_file, &seed_nodes);

        if (try conf.readValue(allocator, io, data_dir, conf_file, "exportdir")) |existing| {
            allocator.free(existing);
            return;
        }
        const export_dir = try std.fs.path.join(allocator, &.{ data_dir, export_subdir });
        defer allocator.free(export_dir);
        try conf.setValue(allocator, io, data_dir, conf_file, "exportdir", export_dir);
    }

    /// BitcoinZ is a bitcoin-derived daemon: it forks itself into the background
    /// with `-daemon` on POSIX, but runs in the foreground on Windows.
    pub fn launchMode() Coin.LaunchMode {
        return if (builtin.os.tag == .windows) .foreground else .fork;
    }

    /// The daemon's log file under the data dir, whose tail is read for a
    /// startup-failure reason when the daemon dies without saying why on stderr
    /// (e.g. the missing-proving-parameters shutdown).
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

    /// Ask bitcoinzd to shut down via the JSON-RPC `stop`.
    pub fn requestStop(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        const reply = try rpc.call(allocator, auth, "stop");
        allocator.free(reply);
    }

    /// Read the wallet's security state from `getwalletinfo`. zcashd style
    /// matches bitcoin-core: `unlocked_until` is **absent** on an unencrypted
    /// wallet (the norm here — encryption is disabled upstream), `0` when
    /// locked, and a positive unlock timestamp otherwise.
    pub fn walletSecurityState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.WalletSecurity {
        var parsed = try rpc.callParsed(models.BtczWalletInfo, allocator, auth, "getwalletinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return securityFromUnlockedUntil(r.unlocked_until);
    }

    /// Read the wallet's balances from `getwalletinfo`. `available` is the
    /// confirmed spendable transparent `balance`; `total` adds the mempool
    /// (`unconfirmed_balance`) and maturing (`immature_balance`) funds. BoxWallet
    /// manages the transparent wallet only — shielded (z-address) balances are
    /// out of scope.
    pub fn walletBalance(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.WalletBalance {
        var parsed = try rpc.callParsed(models.BtczWalletInfo, allocator, auth, "getwalletinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return models.WalletBalance.fromParts(r.balance, r.unconfirmed_balance, r.immature_balance);
    }

    /// Map a `getwalletinfo` `unlocked_until` (absent/0/positive) to the
    /// normalized `WalletSecurity`. Shared by the parse path and its unit test.
    fn securityFromUnlockedUntil(unlocked_until: ?i64) models.WalletSecurity {
        const u = unlocked_until orelse return .unencrypted;
        if (u == 0) return .locked;
        return .unlocked;
    }

    /// Map a `listtransactions` `category` to the normalized direction —
    /// BitcoinZ's zcashd lineage uses the classic bitcoin categories.
    /// `"generate"`/`"immature"`/`"orphan"` are coinbase (mined) rewards at
    /// their maturity stages; the normalized `.stake` covers a mined block
    /// reward on a proof-of-work coin (see `models.TxDirection`). Anything else
    /// has no direction (null; the caller drops it).
    fn directionFromCategory(category: []const u8) ?models.TxDirection {
        if (std.mem.eql(u8, category, "receive")) return .received;
        if (std.mem.eql(u8, category, "send")) return .sent;
        if (std.mem.eql(u8, category, "generate") or
            std.mem.eql(u8, category, "immature") or
            std.mem.eql(u8, category, "orphan")) return .stake;
        return null;
    }

    /// The wallet's most recent transparent transactions, newest-first — the
    /// shared bitcoin-family `listtransactions` flow with BitcoinZ's category map.
    pub fn walletTransactions(allocator: std.mem.Allocator, auth: models.CoinAuth, limit: usize) ![]models.WalletTx {
        return rpc.walletTransactions(allocator, auth, limit, directionFromCategory);
    }

    /// The wallet's receive address. BitcoinZ's zcashd lineage removed the
    /// accounts API and never gained labels, so there is no "current address"
    /// RPC to lean on. Instead the wallet's own address book (`listaddresses` —
    /// every address ever minted by `getnewaddress`) stands in: its first entry
    /// is the stable "current" (the book is returned in a deterministic order,
    /// and every wallet address stays valid to pay), a fresh wallet's empty
    /// book mints the first one, and `force_new` (an explicit user-requested
    /// rotation, never polled) mints another.
    pub fn receiveAddress(allocator: std.mem.Allocator, auth: models.CoinAuth, force_new: bool) ![]const u8 {
        if (!force_new) {
            var parsed = try rpc.callParsedParams([][]const u8, allocator, auth, "listaddresses", "[]");
            defer parsed.deinit();
            if (parsed.value.result) |addrs| {
                if (addrs.len > 0) return allocator.dupe(u8, addrs[0]);
            }
            // Fresh wallet (empty address book) — mint the first one below.
        }
        var parsed = try rpc.callParsedParams([]const u8, allocator, auth, "getnewaddress", "[]");
        defer parsed.deinit();
        const addr = parsed.value.result orelse return error.EmptyRpcResult;
        return allocator.dupe(u8, addr);
    }

    /// Send `amount` BTCZ to `address` via `sendtoaddress` (8-decimal amounts).
    /// The daemon's own rejection reason (invalid address, insufficient funds,
    /// locked wallet) rides back verbatim in the `SendResult`.
    pub fn sendToAddress(allocator: std.mem.Allocator, auth: models.CoinAuth, address: []const u8, amount: f64) !models.SendResult {
        return rpc.sendToAddress(allocator, auth, address, amount, 8);
    }

    /// Unlock the wallet via `walletpassphrase` — only reachable on a wallet
    /// encrypted outside BoxWallet (upstream ships `encryptwallet` disabled).
    /// This codebase re-locks after exactly the given timeout and treats `0` as
    /// "now", so a long finite timeout stands in for "indefinite" (the
    /// SpiderByte-era convention). BitcoinZ is proof-of-work, so the `staking`
    /// flag is irrelevant.
    pub fn walletUnlock(allocator: std.mem.Allocator, auth: models.CoinAuth, passphrase: []const u8, _: bool) !void {
        const pw = try rpc.jsonQuote(allocator, passphrase);
        defer allocator.free(pw);
        const params = try std.fmt.allocPrint(allocator, "[{s},9999999]", .{pw});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "walletpassphrase", params);
    }

    /// Re-lock the wallet via `walletlock`.
    pub fn walletLock(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        return rpc.callExpectOk(allocator, auth, "walletlock", "[]");
    }

    /// Back up the wallet's transparent keys to `dest_path` via `dumpwallet`.
    ///
    /// zcashd-era `dumpwallet` takes a bare alphanumeric filename and writes it
    /// inside the daemon's `-exportdir` (pointed at `<datadir>/export` by
    /// `prepareConf`), returning the full path — it can't write to an arbitrary
    /// destination and refuses to overwrite, so a unique clock-derived name is
    /// minted, the dump is streamed out to the user's `dest_path`, and the
    /// export-dir original (a second on-disk copy of the wallet's keys) is
    /// shredded + deleted on every path out. `dest_path` is the user's backup —
    /// theirs to keep.
    pub fn walletBackup(allocator: std.mem.Allocator, auth: models.CoinAuth, dest_path: []const u8) !void {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var name_buf: [40]u8 = undefined;
        const secs = std.Io.Clock.real.now(io).toSeconds();
        const name = std.fmt.bufPrint(&name_buf, "boxwallet{d}", .{secs}) catch unreachable;
        const params = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{name});
        defer allocator.free(params);

        var parsed = try rpc.callParsedParams([]const u8, allocator, auth, "dumpwallet", params);
        defer parsed.deinit();
        const exported = parsed.value.result orelse return error.RpcCallFailed;

        // Shred + delete the export-dir key dump however we leave this function
        // (runs after the copy handles below are closed).
        defer shredFile(io, exported);

        var src = try std.Io.Dir.cwd().openFile(io, exported, .{});
        defer src.close(io);
        var rbuf: [64 * 1024]u8 = undefined;
        var fr = src.reader(io, &rbuf);

        var dst = try std.Io.Dir.cwd().createFile(io, dest_path, .{});
        defer dst.close(io);
        var wbuf: [64 * 1024]u8 = undefined;
        var fw = dst.writer(io, &wbuf);

        while (true) {
            _ = fr.interface.stream(&fw.interface, .limited(64 * 1024)) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return error.BackupReadFailed,
                error.WriteFailed => return error.BackupWriteFailed,
            };
        }
        fw.interface.flush() catch return error.BackupWriteFailed;
    }

    /// Overwrite the file at `path` with zeros and delete it — the Nerva
    /// restore-spec pattern for key material that had to touch disk. Best-effort
    /// (used from defers): a failure leaves the delete to still run.
    fn shredFile(io: std.Io, path: []const u8) void {
        const size: u64 = blk: {
            var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return;
            defer f.close(io);
            const st = f.stat(io) catch break :blk 0;
            break :blk st.size;
        };
        {
            var f = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
            defer f.close(io);
            var wbuf: [4096]u8 = undefined;
            var fw = f.writer(io, &wbuf);
            const zeros = [_]u8{0} ** 4096;
            var left = size;
            while (left > 0) {
                const n: usize = @intCast(@min(left, zeros.len));
                fw.interface.writeAll(zeros[0..n]) catch break;
                left -= n;
            }
            fw.interface.flush() catch {};
        }
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }


    /// Restore transparent keys from a `dumpwallet` file via `importwallet`,
    /// which imports the keys and rescans the chain (unlike `dumpwallet`, it
    /// reads any full path). The rescan blocks the RPC until it finishes, so on
    /// a slow machine this can outlast the client timeout and read as a failure
    /// even though the daemon keeps rescanning — acceptable for v1. Path
    /// JSON-escaped before splicing.
    ///
    /// **The file is checked to be a key dump first**, because `importwallet`
    /// cannot report that it wasn't. It parses the file line by line and skips
    /// whatever it can't read, so handed a *binary* `wallet.dat` it returns a
    /// clean `"error":null` success having imported **zero keys** — and the user
    /// is told their wallet was restored when nothing was. (Verified against
    /// bitcoinzd 2.2.0: the address book is unchanged across such a call.) A
    /// success that can't be distinguished from a no-op is worse than a refusal,
    /// so a file without the dump header is rejected with
    /// `error.NotAWalletKeyDump`, whose message points at the wallet.dat option
    /// (`walletRestoreFileOffline`) instead.
    pub fn walletImportFile(allocator: std.mem.Allocator, auth: models.CoinAuth, src_path: []const u8) !void {
        if (!looksLikeKeyDump(allocator, src_path)) return error.NotAWalletKeyDump;

        const qpath = try rpc.jsonQuote(allocator, src_path);
        defer allocator.free(qpath);
        const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qpath});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "importwallet", params);
    }

    /// True if the file at `path` opens with a `dumpwallet` header — i.e. it's a
    /// text key dump `importwallet` can actually read, not a binary `wallet.dat`
    /// (or anything else). The sniff itself is shared with the other coins that
    /// take a key dump (`walletfile.looksLikeKeyDump`).
    fn looksLikeKeyDump(allocator: std.mem.Allocator, path: []const u8) bool {
        return walletfile.looksLikeKeyDump(allocator, path);
    }

    /// Restore the wallet by swapping in a user-supplied binary `wallet.dat` —
    /// the file-level counterpart to `walletImportFile`'s key-dump import, for a
    /// wallet brought from another BitcoinZ install. The daemon holds
    /// `wallet.dat` open while running, so the caller stops it before calling
    /// this and restarts it after (the offline-restore orchestration in
    /// `app.zig`); this hook only touches files and takes no auth.
    ///
    /// Safety: the existing `wallet.dat` (if any) is first moved aside to a
    /// timestamped `wallet.dat.bak-<ns>` sibling, so a mistaken restore never
    /// destroys the current wallet — it stays recoverable. An empty source is
    /// rejected before anything is clobbered, as is a *text key dump* picked by
    /// mistake (that's `walletImportFile`'s job, and copying one over
    /// `wallet.dat` would leave the daemon unable to open its wallet at all).
    pub fn walletRestoreFileOffline(
        allocator: std.mem.Allocator,
        home: []const u8,
        src_path: []const u8,
    ) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);

        // zcashd keeps its wallet at the top of the data dir — this lineage
        // predates Core's named wallet sub-directories.
        return walletfile.restoreOffline(allocator, data_dir, "wallet.dat", src_path);
    }

    /// Probe `getnetworkinfo` for the daemon's warm-up phase (any supported
    /// method returns the "-28 in warm-up" reply — "Loading block index…",
    /// "Verifying blocks…", "Rescanning…").
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
        // No `ensure_wallet`: zcashd-era daemons auto-create `wallet.dat`.
        .wallet_security_state = vtWalletSecurityState,
        .wallet_balance = vtWalletBalance,
        .wallet_transactions = vtWalletTransactions,
        .wallet_receive_address = vtWalletReceiveAddress,
        .wallet_send = vtWalletSend,
        // No `wallet_encrypt`: upstream ships `encryptwallet` disabled (see the
        // module doc). Unlock/lock stay wired for a wallet encrypted elsewhere.
        .wallet_unlock = vtWalletUnlock,
        .wallet_lock = vtWalletLock,
        .wallet_backup = vtWalletBackup,
        .wallet_import_file = vtWalletImportFile,
        // Both restore shapes: a BoxWallet-made key dump goes back in over RPC
        // (`wallet_import_file`), a binary wallet.dat from another install is a
        // daemon-stopped file swap (this).
        .wallet_restore_file_offline = vtWalletRestoreFileOffline,
        .warmup_probe_method = vtWarmupProbeMethod,
        // Bitcoin 0.11 lineage — no Core 24+ headers pre-synchronization pass,
        // so the frontend's stalled-header presync inference must never fire.
        .has_header_presync = vtHasHeaderPresync,
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
    /// "Bitcoin" in `wordmark_head_color` (white), "Z" in `coin_color`.
    fn vtWordmark(_: *anyopaque) Coin.Wordmark {
        return .{ .split = wordmark_split, .alt_color = coin_color, .head_color = wordmark_head_color };
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
        home: []const u8,
        progress: ?install_mod.Progress,
    ) anyerror!void {
        return install(allocator, install_root, home, progress);
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
    fn vtHasHeaderPresync(_: *anyopaque) bool {
        return false;
    }
};

test "parses getblockchaininfo into normalized BlockchainState (mediantime fallback)" {
    const allocator = std.testing.allocator;

    // A real-shaped zcashd-era reply: no tip `time` field, only `mediantime`.
    const raw =
        \\{"result":{"chain":"main","blocks":1861000,"headers":1861000,
        \\"bestblockhash":"deadbeef","verificationprogress":0.999999,
        \\"mediantime":1770000000,"pruned":false,"commitments":123},
        \\"error":null,"id":"boxwallet"}
    ;
    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.BtczBlockchainInfo),
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
    try std.testing.expectEqual(@as(i64, 1861000), state.blocks);
    try std.testing.expect(state.synced);
    // No `time` on this lineage → mediantime carries the behind-by hint.
    try std.testing.expectEqual(@as(i64, 1770000000), state.tip_time);
}

test "platform selection resolves a bundle for every published target" {
    switch (builtin.os.tag) {
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => try std.testing.expectEqual(install_mod.Format.zip, BitcoinZ.download.?.format),
            else => try std.testing.expect(BitcoinZ.download == null),
        },
        .macos => switch (builtin.cpu.arch) {
            .x86_64, .aarch64 => try std.testing.expectEqual(install_mod.Format.tar_gz, BitcoinZ.download.?.format),
            else => try std.testing.expect(BitcoinZ.download == null),
        },
        .linux => switch (builtin.cpu.arch) {
            .x86_64, .aarch64 => try std.testing.expectEqual(install_mod.Format.tar_gz, BitcoinZ.download.?.format),
            else => try std.testing.expect(BitcoinZ.download == null),
        },
        else => try std.testing.expect(BitcoinZ.download == null),
    }

    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("bitcoinzd.exe", BitcoinZ.daemon_file);
    } else {
        try std.testing.expectEqualStrings("bitcoinzd", BitcoinZ.daemon_file);
    }
}

test "coin vtable dispatches to BitcoinZ metadata and capabilities" {
    var btcz: BitcoinZ = .{};
    const c = btcz.coin();
    try std.testing.expectEqualStrings("BitcoinZ", c.coinName());
    try std.testing.expectEqualStrings("BTCZ", c.coinNameAbbrev());
    try std.testing.expectEqualStrings("#F5A623", c.coinColor());
    try std.testing.expect(!c.isProofOfStake());
    try std.testing.expectEqualStrings("bitcoinz.conf", c.confFile());
    try std.testing.expectEqualStrings("1979", c.rpcDefaultPort());
    // zcashd-era daemon: auto-creates wallet.dat, so no ensure-wallet step.
    try std.testing.expect(!c.needsWallet());
    try std.testing.expect(c.supportsWallet());
    try std.testing.expect(c.supportsBalance());
    try std.testing.expect(c.supportsTransactions());
    try std.testing.expect(c.supportsReceiveAddress());
    try std.testing.expect(c.supportsSend());
    // dumpwallet/importwallet backup ceremony is wired…
    try std.testing.expect(c.supportsWalletBackup());
    try std.testing.expect(c.supportsWalletImport());
    // …but encryption is upstream-disabled, so the menu must not offer it.
    try std.testing.expect(!c.supportsWalletEncrypt());
    // Bitcoin 0.11 lineage — no Core 24+ headers presync pass.
    try std.testing.expect(!c.hasHeaderPresync());
    try std.testing.expect(c.hasRpcStop());
    // The "Z" tail of the wordmark wears the brand gold.
    const wm = c.wordmark().?;
    try std.testing.expectEqual(@as(usize, "Bitcoin".len), wm.split);
    try std.testing.expectEqualStrings(BitcoinZ.coin_color, wm.alt_color);
}

test "walletPath points at the zcashd-style wallet.dat in the data dir" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var btcz: BitcoinZ = .{};
    const wf = (try btcz.coin().walletPath(allocator, "/home/alice")).?;
    defer allocator.free(wf.path);
    if (builtin.os.tag == .macos) {
        try std.testing.expectEqualStrings("/home/alice/Library/Application Support/BitcoinZ/wallet.dat", wf.path);
    } else {
        try std.testing.expectEqualStrings("/home/alice/.bitcoinz/wallet.dat", wf.path);
    }
    try std.testing.expect(wf.keys == null);
}

test "params dir resolves to the shared ZcashParams location on every platform" {
    const allocator = std.testing.allocator;
    const pathtest = @import("../pathtest.zig");

    // Each branch is asked for a *simulated* OS, so the separator in the answer
    // is the host's and says nothing about correctness — compared on '/' so one
    // expectation holds on all three hosts.
    const linux = try BitcoinZ.paramsDirFor(allocator, "/home/alice", .linux);
    defer allocator.free(linux);
    try pathtest.expectEqual("/home/alice/.zcash-params", linux);

    const mac = try BitcoinZ.paramsDirFor(allocator, "/Users/alice", .macos);
    defer allocator.free(mac);
    try pathtest.expectEqual("/Users/alice/Library/Application Support/ZcashParams", mac);

    const win = try BitcoinZ.paramsDirFor(allocator, "C:\\Users\\alice", .windows);
    defer allocator.free(win);
    try pathtest.expectEqual("C:\\Users\\alice\\AppData\\Roaming\\ZcashParams", win);
}

test "an empty home dir is refused rather than resolving relative to the CWD" {
    // Regression: an unset home once yielded a bare ".zcash-params", which put
    // ~780 MB of proving params wherever the process happened to be running.
    try std.testing.expectError(error.NoHomeDir, BitcoinZ.paramsDir(std.testing.allocator, ""));
}

test "the pinned proving parameters carry well-formed SHA-256 hex pins" {
    // Guard against a typo'd pin: exactly three files, each with 64 lowercase
    // hex chars (the constants the checksum gate trusts).
    try std.testing.expectEqual(@as(usize, 3), BitcoinZ.zcash_params.len);
    for (BitcoinZ.zcash_params) |p| {
        try std.testing.expect(p.name.len > 0);
        for (p.sha256) |ch| {
            const ok = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f');
            try std.testing.expect(ok);
        }
    }
}

test "maps getwalletinfo unlocked_until to the wallet security state" {
    try std.testing.expectEqual(models.WalletSecurity.unencrypted, BitcoinZ.securityFromUnlockedUntil(null));
    try std.testing.expectEqual(models.WalletSecurity.locked, BitcoinZ.securityFromUnlockedUntil(0));
    try std.testing.expectEqual(models.WalletSecurity.unlocked, BitcoinZ.securityFromUnlockedUntil(1893456000));
}

test "directionFromCategory maps listtransactions categories to normalized direction" {
    try std.testing.expectEqual(models.TxDirection.received, BitcoinZ.directionFromCategory("receive").?);
    try std.testing.expectEqual(models.TxDirection.sent, BitcoinZ.directionFromCategory("send").?);
    // Coinbase (mined) rewards at their maturity stages — BitcoinZ is
    // proof-of-work, so the normalized `.stake` here means a mined block reward.
    try std.testing.expectEqual(models.TxDirection.stake, BitcoinZ.directionFromCategory("generate").?);
    try std.testing.expectEqual(models.TxDirection.stake, BitcoinZ.directionFromCategory("immature").?);
    try std.testing.expectEqual(models.TxDirection.stake, BitcoinZ.directionFromCategory("orphan").?);
    // No direction — dropped by the shared mapper.
    try std.testing.expect(BitcoinZ.directionFromCategory("move") == null);
    try std.testing.expect(BitcoinZ.directionFromCategory("something-unknown") == null);
}

test "prepareConf writes an exportdir but never overrides the user's own" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-btcz-conf-home";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // Fresh data dir: populate writes the RPC keys and exportdir lands on
    // <datadir>/export (dumpwallet can only write inside -exportdir).
    try BitcoinZ.prepareConf(allocator, io, home);
    const data_dir = try BitcoinZ.dataDir(allocator, home);
    defer allocator.free(data_dir);
    {
        const got = (try conf.readValue(allocator, io, data_dir, BitcoinZ.conf_file, "exportdir")).?;
        defer allocator.free(got);
        const expected = try std.fs.path.join(allocator, &.{ data_dir, BitcoinZ.export_subdir });
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, got);
        // RPC essentials landed too.
        const user = (try conf.readValue(allocator, io, data_dir, BitcoinZ.conf_file, "rpcuser")).?;
        defer allocator.free(user);
        try std.testing.expectEqualStrings(BitcoinZ.rpc_default_username, user);
    }

    // An adopted conf carrying the user's own exportdir keeps it verbatim.
    try conf.setValue(allocator, io, data_dir, BitcoinZ.conf_file, "exportdir", "/mnt/backups");
    try BitcoinZ.prepareConf(allocator, io, home);
    {
        const got = (try conf.readValue(allocator, io, data_dir, BitcoinZ.conf_file, "exportdir")).?;
        defer allocator.free(got);
        try std.testing.expectEqualStrings("/mnt/backups", got);
    }
}

test "shredFile overwrites and removes a key dump" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-btcz-shred";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "dump.txt", .data = "Kprivatekeymaterial" });

    BitcoinZ.shredFile(io, root ++ "/dump.txt");
    dir.access(io, "dump.txt", .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        return;
    };
    return error.TestExpectedFileGone;
}

test "versionFromClient reads a build-50 CLIENT_VERSION as the plain release" {
    const a = std.testing.allocator;
    // 2.2.0's wire version: build 50 == the official release → "2.2.0", which
    // must compare equal to the pinned core_version (no mismatch warning).
    const rel = try BitcoinZ.versionFromClient(a, 2_020_050);
    defer a.free(rel);
    try std.testing.expectEqualStrings("2.2.0", rel);
    try std.testing.expectEqualStrings(BitcoinZ.core_version, rel);

    // An rc build (25–49) keeps the four-part decode, so it *does* differ from
    // the pinned release.
    const rc = try BitcoinZ.versionFromClient(a, 2_020_025);
    defer a.free(rc);
    try std.testing.expectEqualStrings("2.2.0.25", rc);

    // Unknown/absent version stays empty.
    const none = try BitcoinZ.versionFromClient(a, 0);
    defer a.free(none);
    try std.testing.expectEqualStrings("", none);
}

test "prepareConf seeds the addnode peers exactly once" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-btcz-addnode-home";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // Two runs: the second must not duplicate any addnode line.
    try BitcoinZ.prepareConf(allocator, io, home);
    try BitcoinZ.prepareConf(allocator, io, home);

    const data_dir = try BitcoinZ.dataDir(allocator, home);
    defer allocator.free(data_dir);
    var dir = try std.Io.Dir.cwd().openDir(io, data_dir, .{});
    defer dir.close(io);
    var f = try dir.openFile(io, BitcoinZ.conf_file, .{});
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    const n = try f.readPositionalAll(io, &buf, 0);
    const got = buf[0..n];

    for (BitcoinZ.seed_nodes) |line| {
        // Present…
        try std.testing.expect(std.mem.indexOf(u8, got, line) != null);
        // …exactly once.
        const first = std.mem.indexOf(u8, got, line).?;
        try std.testing.expect(std.mem.indexOfPos(u8, got, first + line.len, line) == null);
    }
}

test "looksLikeKeyDump separates a dumpwallet text file from a binary wallet.dat" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-btcz-dumpsniff";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer dir.close(io);

    // A real dumpwallet header, as bitcoinzd 2.2.0 writes it.
    try dir.writeFile(io, .{
        .sub_path = "dump.txt",
        .data = "# Wallet dump created by BitcoinZ v2.2.0-ge90047d4a\n# * Created on 2026-07-18T10:54:39Z\n",
    });
    // A binary wallet.dat: BDB's magic, no header. This is the file that made
    // importwallet report success while importing nothing.
    try dir.writeFile(io, .{ .sub_path = "wallet.dat", .data = "\x00\x00\x00\x00\x62\x31\x05\x00\xff\xfe\x00binary" });
    // Leading blank lines are fine; the header need only come first.
    try dir.writeFile(io, .{ .sub_path = "padded.txt", .data = "\n\n# Wallet dump created by BitcoinZ v2.2.0\n" });

    const dump = try std.fs.path.join(allocator, &.{ root, "dump.txt" });
    defer allocator.free(dump);
    const wdat = try std.fs.path.join(allocator, &.{ root, "wallet.dat" });
    defer allocator.free(wdat);
    const padded = try std.fs.path.join(allocator, &.{ root, "padded.txt" });
    defer allocator.free(padded);
    const absent = try std.fs.path.join(allocator, &.{ root, "nope.txt" });
    defer allocator.free(absent);

    try std.testing.expect(BitcoinZ.looksLikeKeyDump(allocator, dump));
    try std.testing.expect(BitcoinZ.looksLikeKeyDump(allocator, padded));
    try std.testing.expect(!BitcoinZ.looksLikeKeyDump(allocator, wdat));
    // Unreadable reads as "not a dump" — the caller refuses rather than handing
    // the daemon a file it would silently skip.
    try std.testing.expect(!BitcoinZ.looksLikeKeyDump(allocator, absent));
}

test "offline restore swaps wallet.dat, preserves the old one, and refuses a key dump" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-btcz-offline-restore";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    const data_dir = try BitcoinZ.dataDir(allocator, home);
    defer allocator.free(data_dir);
    var dd = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
    defer dd.close(io);
    // An existing wallet that must survive the restore, recoverable.
    try dd.writeFile(io, .{ .sub_path = "wallet.dat", .data = "OLD-WALLET" });

    // The user's backup wallet.dat, browsed to from elsewhere.
    var src = try std.Io.Dir.cwd().createDirPathOpen(io, home ++ "/backups", .{});
    defer src.close(io);
    try src.writeFile(io, .{ .sub_path = "wallet.dat", .data = "NEW-WALLET" });
    try src.writeFile(io, .{
        .sub_path = "dump.txt",
        .data = "# Wallet dump created by BitcoinZ v2.2.0\n",
    });

    const good = try std.fs.path.join(allocator, &.{ home, "backups", "wallet.dat" });
    defer allocator.free(good);
    try BitcoinZ.walletRestoreFileOffline(allocator, home, good);

    // The backup is now the live wallet…
    {
        var f = try dd.openFile(io, "wallet.dat", .{});
        defer f.close(io);
        var buf: [64]u8 = undefined;
        const n = try f.readPositionalAll(io, &buf, 0);
        try std.testing.expectEqualStrings("NEW-WALLET", buf[0..n]);
    }
    // …and the previous one was kept aside intact, not destroyed. Iterating
    // needs a handle opened for it (`.iterate = true`).
    {
        var idir = try std.Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = true });
        defer idir.close(io);
        var it = idir.iterate();
        var found_bak = false;
        while (try it.next(io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "wallet.dat.bak-")) continue;
            const old = try dd.readFileAlloc(io, entry.name, allocator, .limited(64));
            defer allocator.free(old);
            try std.testing.expectEqualStrings("OLD-WALLET", old);
            found_bak = true;
        }
        try std.testing.expect(found_bak);
    }

    // A key dump picked by mistake is refused *before* anything is touched —
    // copying one over wallet.dat would leave the daemon unable to open it.
    const dump = try std.fs.path.join(allocator, &.{ home, "backups", "dump.txt" });
    defer allocator.free(dump);
    try std.testing.expectError(error.IsAWalletKeyDump, BitcoinZ.walletRestoreFileOffline(allocator, home, dump));
    {
        var f = try dd.openFile(io, "wallet.dat", .{});
        defer f.close(io);
        var buf: [64]u8 = undefined;
        const n = try f.readPositionalAll(io, &buf, 0);
        try std.testing.expectEqualStrings("NEW-WALLET", buf[0..n]);
    }

    // An empty source is rejected too, current wallet untouched.
    try src.writeFile(io, .{ .sub_path = "empty.dat", .data = "" });
    const empty = try std.fs.path.join(allocator, &.{ home, "backups", "empty.dat" });
    defer allocator.free(empty);
    try std.testing.expectError(error.EmptyWalletFile, BitcoinZ.walletRestoreFileOffline(allocator, home, empty));
}

test "coin vtable offers both restore shapes for BitcoinZ" {
    var btcz: BitcoinZ = .{};
    const c = btcz.coin();
    // The key-dump import (live daemon, importwallet)…
    try std.testing.expect(c.supportsWalletImport());
    // …and the daemon-stopped wallet.dat swap, which is what actually moves a
    // wallet brought from another install.
    try std.testing.expect(c.supportsWalletRestoreOffline());
}
