const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const rpc = @import("../rpc.zig");
const install_mod = @import("../install.zig");
const conf = @import("../conf.zig");
const Coin = @import("../coin.zig").Coin;

/// PIVX backend.
///
/// PIVX is the chain Divi forked from, so the two share a lot of surface: the
/// same `getinfo` with its `"staking status"` string, the same mainnet ports
/// (51472/51473 — PIVX had them first, and BoxWallet moves PIVX off both in a
/// data dir it creates, so the two daemons can run at once; see `prepareConf`),
/// and a
/// wallet the daemon creates itself at first start. Where they differ, PIVX 5.x
/// is the more modern lineage: real headers-first sync and a
/// `verificationprogress` in `getblockchaininfo`, a numeric `unlocked_until`
/// instead of Divi's `encryption_status` string, the label API instead of
/// accounts, and clean `dumpwallet`/`importwallet` for the backup ceremony.
///
/// The one install-time extra (verified against the v5.6.1 release archive):
/// pivxd refuses to start unless the two Sapling proving parameters sit in the
/// shared per-platform `PIVXParams` dir. The release bundle ships them under
/// `share/pivx/`, so install copies them out — no separate download.
pub const Pivx = struct {
    /// Whether the coin is exposed in the nav. False keeps it out of the left
    /// bar entirely (registered but hidden) until it's ready for users.
    pub const live = true;
    pub const coin_name = "PIVX";
    pub const coin_name_abbrev = "PIVX";
    /// One-line description shown under the coin name on the detail pane.
    pub const coin_description = "Proof-of-stake coin with cold staking and SHIELD privacy.";
    /// PIVX brand colour (`#RRGGBB`), for tinting the coin in the frontend —
    /// sampled from the logo's dominant purple.
    pub const coin_color = "#642D8F";
    /// This coin's id on the price host, for the USD quote beside its
    /// balance (see `src/price.zig`).
    pub const price_id = "pivx";
    /// Donation address for BoxWallet development, in PIVX's own currency.
    /// TODO: replace with a real address before surfacing tips for this coin.
    pub const tip_address = "D9V4gsahYXM7aRdnyKkab7CqxJjjTr3wkV";
    /// PIVX is proof-of-stake — the wallet can stake.
    pub const proof_of_stake = true;
    pub const conf_file = "pivx.conf";
    pub const home_dir = ".pivx";
    pub const home_dir_win = "PIVX";
    /// Which Windows directory that name hangs off — the roaming `%APPDATA%`, as
    /// every bitcoin-derived daemon picks. See `conf.WinBase`.
    pub const home_dir_win_base: conf.WinBase = .roaming;
    /// macOS data dir name. PIVX Core: `~/Library/Application Support/PIVX`.
    pub const home_dir_mac: ?[]const u8 = "PIVX";
    pub const rpc_default_username = "pivxrpc";
    /// Upstream's mainnet RPC port (`chainparamsbase.cpp`) — what pivxd binds
    /// when the conf says nothing. This is the *fallback* `conf.readAuth` seeds
    /// `CoinAuth.port` with, so it must stay equal to the daemon's own default:
    /// set it to the port we'd merely *prefer* and every conf without an
    /// explicit `rpcport` (an adopted PIVX Desktop one, say) gets talked to on
    /// the wrong port. The port BoxWallet actually *writes* is
    /// `rpc_boxwallet_port`.
    pub const rpc_default_port = "51473";

    // --- Ports for a data dir BoxWallet created --------------------------------
    //
    // Divi forked from PIVX and kept both of its mainnet ports, so the two
    // daemons can't run side by side on the defaults: whichever starts second
    // dies with "Unable to start HTTP server" (RPC 51473) and then, once that's
    // cleared, "Failed to listen on any port" (P2P 51472). Divi is the one more
    // likely to be already synced under the upstream numbers, so PIVX is the one
    // that moves — but *only in a data dir BoxWallet made itself*. In a dir
    // adopted from PIVX Desktop these are never written: those ports are that
    // app's settings, and a user switching between the two wallets must find
    // their node exactly as they left it. See `prepareConf`.

    /// RPC port written into a `pivx.conf` BoxWallet owns. `populate` writes it
    /// explicitly, so `readAuth` reads it straight back out of the conf and
    /// never falls through to `rpc_default_port`.
    pub const rpc_boxwallet_port = "51475";
    /// P2P listen port written into a `pivx.conf` BoxWallet owns. Only the
    /// daemon consumes it, so it's a plain `port=` line that's never read back.
    pub const p2p_boxwallet_port = "51474";
    pub const core_version = "5.6.1";

    // Binary names. Windows appends `.exe`; Linux/macOS use the bare names.
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    pub const daemon_file = "pivxd" ++ exe_suffix;
    pub const cli_file = "pivx-cli" ++ exe_suffix;
    pub const tx_file = "pivx-tx" ++ exe_suffix;

    // Download host. Every bundle wraps its files in `pivx-<ver>/` with binaries
    // under `bin/` and the Sapling params under `share/pivx/`, identically across
    // platforms (Linux/macOS `.tar.gz`, Windows `.zip`).
    const download_base = "https://github.com/PIVX-Project/PIVX/releases/download/v" ++ core_version ++ "/";

    /// The download URL + archive format for the build target, or null where PIVX
    /// publishes no matching binary. Selected at comptime from OS/arch:
    ///   - Linux x86_64 and aarch64 are native; 32-bit arm uses `gnueabihf`.
    ///   - PIVX ships no native Apple-Silicon build, so both macOS arches use the
    ///     Intel `osx64` build — which runs on M1+ under Rosetta 2 (like Divi).
    const download: ?install_mod.Download = switch (builtin.os.tag) {
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => .{ .url = download_base ++ "pivx-" ++ core_version ++ "-win64.zip", .format = .zip },
            else => null,
        },
        .macos => .{ .url = download_base ++ "pivx-" ++ core_version ++ "-osx64.tar.gz", .format = .tar_gz },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => .{ .url = download_base ++ "pivx-" ++ core_version ++ "-x86_64-linux-gnu.tar.gz", .format = .tar_gz },
            .aarch64 => .{ .url = download_base ++ "pivx-" ++ core_version ++ "-aarch64-linux-gnu.tar.gz", .format = .tar_gz },
            .arm => .{ .url = download_base ++ "pivx-" ++ core_version ++ "-arm-linux-gnueabihf.tar.gz", .format = .tar_gz },
            else => null,
        },
        else => null,
    };

    // Layout inside the archive: keep only the daemon/cli/tx binaries (from
    // `bin/`) at the install root; the whole `pivx-<ver>/` tree is discarded
    // after the Sapling params are copied out of it.
    const extracted_dir = "pivx-" ++ core_version;
    const bin_subdir = "bin";
    const promote_files = [_][]const u8{ daemon_file, cli_file, tx_file };

    // Temp file the download streams to. Keyed off the daemon name so a
    // concurrent install of another coin into the same `~/.boxwallet` root uses
    // a different scratch file and the two never collide.
    pub const scratch_file = ".boxwallet-" ++ daemon_file ++ ".part";

    // --- Sapling proving parameters ---------------------------------------
    //
    // pivxd shuts down from init unless both Sapling parameter files are present
    // in the shared per-platform PIVXParams dir. They are the same two files the
    // zcashd family uses, and the release archive ships them under `share/pivx/`
    // with an `install-params.sh` that copies them into place — BoxWallet does
    // that copy itself at install, verifying each against the SHA-256 upstream's
    // own script pins. A file already in the params dir is another app's
    // property and is never re-copied, overwritten, or even re-hashed.

    /// One proving-parameter file: its canonical name and pinned SHA-256
    /// (upstream `install-params.sh`, identical to zcash's `fetch-params.sh`).
    const ParamFile = struct { name: []const u8, sha256: *const [64]u8 };

    pub const sapling_params = [_]ParamFile{
        // ~48 MB
        .{ .name = "sapling-spend.params", .sha256 = "8e48ffd23abb3a5fd9c5589204f32d9c31285a04b78096ba40a79b75677efc13" },
        // ~3.6 MB
        .{ .name = "sapling-output.params", .sha256 = "2f0ebbcbb9bb0bcffe95a397e7eba89c29eb4dde6191c339db88570e3f3fb0e4" },
    };

    /// The shared PIVX params directory for an explicit `os` — split out (like
    /// `conf.dataDirFor`) so every platform's path is checkable from one native
    /// test run. Upstream `util/system.cpp` `ZC_GetParamsDir`: `~/.pivx-params`
    /// on Linux, `~/Library/Application Support/PIVXParams` on macOS,
    /// `%APPDATA%\PIVXParams` on Windows.
    fn paramsDirFor(allocator: std.mem.Allocator, home: []const u8, os: std.Target.Os.Tag) ![]const u8 {
        return conf.dataDirFor(allocator, home, os, ".pivx-params", "PIVXParams", "PIVXParams", .roaming);
    }

    /// The shared PIVX params directory for the build target. An empty `home` is
    /// rejected rather than tolerated: `path.join` would drop it and yield a
    /// *relative* `.pivx-params` in whatever the process's CWD happens to be
    /// instead of the dir every PIVX app shares.
    pub fn paramsDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        if (home.len == 0) return error.NoHomeDir;
        return paramsDirFor(allocator, home, builtin.os.tag);
    }

    /// Copy the Sapling parameters out of the freshly extracted archive into the
    /// shared params dir. Runs before `promoteAndTidy` discards the wrapper tree.
    /// Each missing file is checksum-verified in the extracted tree, copied to a
    /// scratch name, and renamed into place only then — a torn or tampered file
    /// never sits where the daemon would load it.
    fn installSaplingParams(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home: []const u8,
    ) !void {
        const dir_path = try paramsDir(allocator, home);
        defer allocator.free(dir_path);

        const src_path = try std.fs.path.join(allocator, &.{ install_root, extracted_dir, "share", "pivx" });
        defer allocator.free(src_path);

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var src = try std.Io.Dir.cwd().openDir(io, src_path, .{});
        defer src.close(io);
        var dst = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
        defer dst.close(io);

        for (sapling_params) |p| {
            // Already present → another PIVX app's (or a previous install's);
            // share it untouched.
            if (install_mod.fileExists(allocator, dir_path, p.name)) continue;

            if (!install_mod.fileMatchesSha256(allocator, src_path, p.name, p.sha256))
                return error.ParamsChecksumMismatch;

            const scratch = try std.fmt.allocPrint(allocator, ".boxwallet-{s}.part", .{p.name});
            defer allocator.free(scratch);
            // Never leave a torn copy behind — a retry (or the user) could
            // mistake it for a good file.
            errdefer dst.deleteFile(io, scratch) catch {};
            try src.copyFile(p.name, dst, scratch, io, .{});
            try dst.rename(scratch, dst, p.name, io);
        }
    }

    /// Build the type-erased `Coin` handle for this instance.
    pub fn coin(self: *Pivx) Coin {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Live `getblockchaininfo`, normalized for a frontend. PIVX 5.x reports a
    /// checkpoint-derived `verificationprogress` and a real headers-first
    /// `headers`, so "synced" is derived from progress as for Bitcoin. The reply
    /// carries no tip timestamp at all, so while behind it comes from the tip
    /// block itself — two extra calls, made only while actually syncing.
    pub fn blockchainState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.BlockchainState {
        var parsed = try rpc.callParsed(models.PivxBlockchainInfo, allocator, auth, "getblockchaininfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        const synced = r.verificationprogress > 0.99999;
        return .{
            .chain = try allocator.dupe(u8, r.chain),
            .blocks = r.blocks,
            // Keep headers from ever sinking below blocks (they can trail
            // momentarily around a restart), which would peg the Blocks bar at a
            // false 100%.
            .headers = @max(r.headers, r.blocks),
            .verification_progress = r.verificationprogress,
            .synced = synced,
            // Network tip from peers, so the frontend's Headers bar can fill
            // toward it. A getpeerinfo hiccup just leaves it 0 (unknown).
            .network_height = rpc.networkHeight(allocator, auth) catch 0,
            .tip_time = if (synced) 0 else rpc.tipBlockTime(allocator, auth, r.blocks),
        };
    }

    /// Live `getinfo`, normalized for a frontend. PIVX kept `getinfo`, and it
    /// carries everything in one call: height, peer count, the numeric
    /// `CLIENT_VERSION`, and the same human-readable `"staking status"` string
    /// Divi inherited — mapped to a bool so the frontend never sees the wording.
    pub fn daemonInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.DaemonInfo {
        var parsed = try rpc.callParsed(models.PivxGetInfo, allocator, auth, "getinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return .{
            .blocks = r.blocks,
            .connections = r.connections,
            .staking_active = std.mem.eql(u8, r.@"staking status", "Staking Active"),
            // Numeric CLIENT_VERSION (5.6.1 → 5060100) → dotted string.
            .version = try models.clientVersionString(allocator, r.version),
        };
    }

    /// The daemon's default data directory (`~/.pivx`), where `pivx.conf` lives.
    pub fn dataDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        return conf.dataDir(allocator, home, home_dir, home_dir_win, home_dir_mac, home_dir_win_base);
    }

    /// The managed wallet's on-disk location (`<datadir>/wallet.dat`) — the
    /// daemon's default wallet, created by pivxd itself at first start. Caller
    /// owns the returned strings.
    pub fn walletPath(allocator: std.mem.Allocator, home: []const u8) !?Coin.WalletFile {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        return .{ .path = try std.fs.path.join(allocator, &.{ data_dir, "wallet.dat" }) };
    }

    /// True if `pivxd` (`pivxd.exe` on Windows) is already present under
    /// `install_root`.
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, daemon_file);
    }

    /// Download + unarchive the PIVX daemon files into `install_root`, copy the
    /// Sapling proving parameters out of the archive into the shared params dir
    /// (the daemon refuses to start without them), then promote the daemon/cli/tx
    /// binaries and discard the wrapper tree. Optionally reports download/extract
    /// progress; the params are in the bundle, so nothing extra is downloaded.
    pub fn install(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        const dl = download orelse return error.UnsupportedPlatform;
        try install_mod.downloadAndExtract(allocator, dl.url, dl.format, install_root, scratch_file, 0, progress);
        try installSaplingParams(allocator, install_root, home);
        try install_mod.promoteAndTidy(allocator, install_root, extracted_dir, bin_subdir, &promote_files);
    }

    /// Ensure `pivx.conf` carries the RPC creds (and `server=1`/`daemon=1`/
    /// `rpcport`) BoxWallet needs before the daemon reads it; existing values are
    /// kept. A standard bitcoin-derived `key=value` conf.
    ///
    /// The Divi port clash is settled here, and only for a data dir BoxWallet
    /// created itself. A dir that was already on disk belongs to PIVX Desktop (or
    /// another pivxd): its ports are that app's configuration, and moving them
    /// would silently retune a node the user still switches back to — breaking a
    /// forwarded 51472 and any tool pointed at RPC 51473 — so an adopted dir keeps
    /// upstream's numbers and, if Divi is also installed, is left to fail its bind
    /// honestly rather than be reconfigured behind the user's back.
    ///
    /// `blocks/` and the conf itself are the markers (`conf.dataDirHasEntry`, per
    /// the same rule `pruneShouldOffer` follows), and they're sampled *before*
    /// `populate` runs — it creates the conf, so checking afterwards would read
    /// every dir, including ours, as adopted.
    pub fn prepareConf(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);

        const adopted = conf.dataDirHasEntry(allocator, data_dir, conf_file) or
            conf.dataDirHasEntry(allocator, data_dir, "blocks");

        _ = try conf.populate(
            allocator,
            io,
            data_dir,
            conf_file,
            rpc_default_username,
            if (adopted) rpc_default_port else rpc_boxwallet_port,
        );
        if (adopted) return;

        // Ours to place — but still never clobber a `port` a previous run (or the
        // user) already put there; `setValue` would replace it in place.
        if (try conf.readValue(allocator, io, data_dir, conf_file, "port")) |existing| {
            allocator.free(existing);
        } else {
            try conf.setValue(allocator, io, data_dir, conf_file, "port", p2p_boxwallet_port);
        }
    }

    /// PIVX is a bitcoin-derived daemon: it forks itself into the background with
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

    /// Ask pivxd to shut down via the JSON-RPC `stop`.
    pub fn requestStop(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        const reply = try rpc.call(allocator, auth, "stop");
        allocator.free(reply);
    }

    /// Read the wallet's security state from `getwalletinfo`. Bitcoin-core style:
    /// `unlocked_until` is **absent** on an unencrypted wallet, `0` when locked,
    /// and a positive unlock timestamp otherwise. (A staking-only unlock reads as
    /// plain `unlocked` — the reply carries nothing to tell the two apart.)
    pub fn walletSecurityState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.WalletSecurity {
        var parsed = try rpc.callParsed(models.PivxWalletInfo, allocator, auth, "getwalletinfo");
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
        var parsed = try rpc.callParsed(models.PivxWalletInfo, allocator, auth, "getwalletinfo");
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

    /// Map PIVX's `listtransactions` `category` to the normalized direction.
    /// PIVX 5.x kept only the classic set (verified against upstream
    /// `ListTransactions`): unlike Divi it never grew `stake_reward`/`mn_reward`
    /// categories — a stake appears as an ordinary send + receive pair — so
    /// `"generate"`/`"immature"`/`"orphan"` (coinbase maturity stages) are all
    /// that maps to `.stake`. Anything else has no direction (null; dropped).
    fn directionFromCategory(category: []const u8) ?models.TxDirection {
        if (std.mem.eql(u8, category, "receive")) return .received;
        if (std.mem.eql(u8, category, "send")) return .sent;
        if (std.mem.eql(u8, category, "generate") or
            std.mem.eql(u8, category, "immature") or
            std.mem.eql(u8, category, "orphan")) return .stake;
        return null;
    }

    /// The wallet's most recent transactions, newest-first — the shared
    /// bitcoin-family `listtransactions` flow with PIVX's category map.
    pub fn walletTransactions(allocator: std.mem.Allocator, auth: models.CoinAuth, limit: usize) ![]models.WalletTx {
        return rpc.walletTransactions(allocator, auth, limit, directionFromCategory);
    }

    /// Marker label that tracks the wallet's current receive address. PIVX 5.x
    /// removed the accounts API (and with it any stable "current address" RPC),
    /// so the shared label flow keeps exactly one address under this label —
    /// see `rpc.receiveAddressLabeled`.
    const receive_label = "boxwallet-receive";

    /// The wallet's receive address: the labelled current one (minted on first
    /// use), or a fresh mint on an explicit user-requested rotation
    /// (`force_new` — only ever called on demand, never polled).
    pub fn receiveAddress(allocator: std.mem.Allocator, auth: models.CoinAuth, force_new: bool) ![]const u8 {
        return rpc.receiveAddressLabeled(allocator, auth, force_new, receive_label);
    }

    /// Send `amount` PIV to `address` via `sendtoaddress` (8-decimal amounts).
    /// The daemon's own rejection reason (invalid address, insufficient funds,
    /// locked wallet) rides back verbatim in the `SendResult`.
    pub fn sendToAddress(allocator: std.mem.Allocator, auth: models.CoinAuth, address: []const u8, amount: f64) !models.SendResult {
        return rpc.sendToAddress(allocator, auth, address, amount, 8);
    }

    /// Encrypt the wallet with `passphrase`. pivxd stops itself afterwards (the
    /// caller restarts it). The passphrase is JSON-escaped before splicing.
    pub fn walletEncrypt(allocator: std.mem.Allocator, auth: models.CoinAuth, passphrase: []const u8) !void {
        const pw = try rpc.jsonQuote(allocator, passphrase);
        defer allocator.free(pw);
        const params = try std.fmt.allocPrint(allocator, "[{s}]", .{pw});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "encryptwallet", params);
    }

    /// Unlock the wallet via `walletpassphrase`; `staking` adds PIVX's
    /// `staking_only` flag as the third parameter.
    ///
    /// The timeout is a long finite one, **not `0`**: upstream only sets
    /// `nRelockTime` when the timeout is positive (v5.6.1 `walletpassphrase`), so
    /// a 0-timeout unlock — though valid, and held until shutdown — leaves
    /// `getwalletinfo` reporting `unlocked_until: 0`, which reads back as
    /// *locked*. pivxd clamps anything over 100000000s, so 9999999 (~115 days)
    /// is comfortably inside what it accepts.
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

    /// Back up the wallet to `dest_path` via `dumpwallet` — a human-readable dump
    /// of the wallet's keys + HD seed that the user keeps as their backup (it is
    /// the backup, not a temp: don't shred it). pivxd refuses this on a locked
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
    /// finishes, so on a slow machine this can outlast the client timeout and
    /// read as a failure even though pivxd keeps rescanning — acceptable for v1.
    /// Like backup, requires the wallet unlocked/unencrypted. Path JSON-escaped.
    pub fn walletImportFile(allocator: std.mem.Allocator, auth: models.CoinAuth, src_path: []const u8) !void {
        const qpath = try rpc.jsonQuote(allocator, src_path);
        defer allocator.free(qpath);
        const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qpath});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "importwallet", params);
    }

    /// PIVX retains `getinfo`, so probe it for the daemon's warm-up phase.
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
        .wallet_backup = vtWalletBackup,
        .wallet_import_file = vtWalletImportFile,
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
    fn vtWarmupProbeMethod(_: *anyopaque) []const u8 {
        return warmupProbeMethod();
    }
};

test "parses getblockchaininfo into normalized BlockchainState" {
    const allocator = std.testing.allocator;

    // Shaped like a live pivxd v5.6.1 reply (upstream `getblockchaininfo`):
    // checkpoint-derived verificationprogress, a real headers count, and — the
    // per-coin quirk — **no** tip `time`/`mediantime` fields at all. The extra
    // shield/upgrade keys exercise the ignore-unknowns path.
    const raw =
        \\{"result":{"chain":"main","blocks":4650000,"headers":4650000,
        \\"bestblockhash":"deadbeef","difficulty":48372.51,
        \\"verificationprogress":0.9999998,
        \\"chainwork":"00000000000000000000000000000000000000000000000000275f7d24e0cf1e",
        \\"shield_pool_value":{"chainValue":481252.55},
        \\"initial_block_downloading":false,"warnings":""},
        \\"error":null,"id":"boxwallet"}
    ;
    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.PivxBlockchainInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    try std.testing.expectEqualStrings("main", r.chain);
    try std.testing.expectEqual(@as(i64, 4650000), r.blocks);
    try std.testing.expectEqual(@as(i64, 4650000), r.headers);
    // Caught up: the progress figure alone decides synced, as for Bitcoin.
    try std.testing.expect(r.verificationprogress > 0.99999);
}

test "maps getinfo into normalized DaemonInfo, decoding staking status and version" {
    const allocator = std.testing.allocator;

    // Canned reply mirroring pivxd's getinfo (upstream `rpc/misc.cpp`): the
    // `"staking status"` field carries a literal space and a human-readable
    // value — the same wording Divi inherited — and `version` is the numeric
    // CLIENT_VERSION, unlike Divi's ready-made string.
    const raw =
        \\{"result":{"version":5060100,"protocolversion":70927,
        \\"walletversion":170000,"balance":1234.56789,
        \\"staking status":"Staking Active","blocks":4650000,"timeoffset":0,
        \\"connections":12,"proxy":"","difficulty":48372.51,"testnet":false,
        \\"moneysupply":89000000.0,"errors":""},
        \\"error":null,"id":"boxwallet"}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.PivxGetInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    try std.testing.expectEqual(@as(i64, 4650000), r.blocks);
    try std.testing.expectEqual(@as(i64, 12), r.connections);
    try std.testing.expect(std.mem.eql(u8, r.@"staking status", "Staking Active"));

    // 5060100 decodes to the dotted release (build 0 dropped).
    const ver = try models.clientVersionString(allocator, r.version);
    defer allocator.free(ver);
    try std.testing.expectEqualStrings("5.6.1", ver);
}

test "getinfo without active staking maps staking_active false" {
    const allocator = std.testing.allocator;

    const raw =
        \\{"result":{"version":5060100,"blocks":4650000,"connections":8,
        \\"staking status":"Staking Not Active"},"error":null,"id":"boxwallet"}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.PivxGetInfo),
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
    // PIVX ships zip on Windows and tar.gz everywhere else — including the Intel
    // osx64 build both macOS arches use (Rosetta 2 on Apple Silicon, like Divi).
    if (Pivx.download) |dl| {
        switch (builtin.os.tag) {
            .windows => try std.testing.expectEqual(install_mod.Format.zip, dl.format),
            else => try std.testing.expectEqual(install_mod.Format.tar_gz, dl.format),
        }
    }

    // Binary names carry `.exe` only on Windows.
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("pivxd.exe", Pivx.daemon_file);
    } else {
        try std.testing.expectEqualStrings("pivxd", Pivx.daemon_file);
    }
}

test "coin vtable dispatches to PIVX metadata" {
    var pivx: Pivx = .{};
    const c = pivx.coin();
    try std.testing.expectEqualStrings("PIVX", c.coinName());
    try std.testing.expectEqualStrings("#642D8F", c.coinColor());
    try std.testing.expect(c.isProofOfStake());
    try std.testing.expectEqualStrings("pivx.conf", c.confFile());
    try std.testing.expectEqualStrings("pivxd" ++ Pivx.exe_suffix, c.daemonFile());
    // Upstream's port, not the 51475 we write: this is the fallback `readAuth`
    // uses when a conf omits `rpcport`, so it must match what pivxd itself binds.
    try std.testing.expectEqualStrings("51473", c.rpcDefaultPort());
    // pivxd creates its default wallet itself — nothing to ensure after start.
    try std.testing.expect(!c.needsWallet());
    // The wallet is manageable over RPC — the `w` menu is available.
    try std.testing.expect(c.supportsWallet());
    // And it reports a balance, so the Total/Available lines light up.
    try std.testing.expect(c.supportsBalance());
    // dumpwallet/importwallet backup ceremony is wired (like Bitcoin/ReddCoin).
    try std.testing.expect(c.supportsWalletBackup());
    try std.testing.expect(c.supportsWalletImport());
}

test "coin vtable exposes transactions, receive address, and send for PIVX" {
    var pivx: Pivx = .{};
    const c = pivx.coin();
    try std.testing.expect(c.supportsTransactions());
    try std.testing.expect(c.supportsReceiveAddress());
    try std.testing.expect(c.supportsSend());
}

test "walletPath points at the daemon's default wallet.dat" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var pivx: Pivx = .{};
    const wf = (try pivx.coin().walletPath(allocator, "/home/alice")).?;
    defer allocator.free(wf.path);
    try std.testing.expectEqualStrings("/home/alice/.pivx/wallet.dat", wf.path);
    try std.testing.expect(wf.keys == null);
}

test "maps getwalletinfo unlocked_until to the wallet security state" {
    try std.testing.expectEqual(models.WalletSecurity.unencrypted, Pivx.securityFromUnlockedUntil(null));
    try std.testing.expectEqual(models.WalletSecurity.locked, Pivx.securityFromUnlockedUntil(0));
    try std.testing.expectEqual(models.WalletSecurity.unlocked, Pivx.securityFromUnlockedUntil(1893456000));

    // The field parses out of a representative getwalletinfo reply — including
    // PIVX's extra delegated/cold-staking balances, which ride the
    // ignore-unknowns path.
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.PivxWalletInfo),
        allocator,
        \\{"result":{"walletname":"","walletversion":170000,"balance":100.0,
        \\"delegated_balance":0.0,"cold_staking_balance":0.0,
        \\"unconfirmed_balance":5.0,"immature_balance":2.5,
        \\"immature_delegated_balance":0.0,"immature_cold_staking_balance":0.0,
        \\"txcount":42,"unlocked_until":0,"paytxfee":0.0},
        \\"error":null,"id":"boxwallet"}
    ,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    try std.testing.expectEqual(models.WalletSecurity.locked, Pivx.securityFromUnlockedUntil(r.unlocked_until));

    // The balance triplet maps into available + total exactly as for Bitcoin.
    const bal = models.WalletBalance.fromParts(r.balance, r.unconfirmed_balance, r.immature_balance);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), bal.available, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 107.5), bal.total, 1e-9);
    try std.testing.expect(bal.hasPending());
}

test "directionFromCategory maps listtransactions categories to normalized direction" {
    try std.testing.expectEqual(models.TxDirection.received, Pivx.directionFromCategory("receive").?);
    try std.testing.expectEqual(models.TxDirection.sent, Pivx.directionFromCategory("send").?);
    // Coinbase maturity stages read as the normalized stake direction.
    try std.testing.expectEqual(models.TxDirection.stake, Pivx.directionFromCategory("generate").?);
    try std.testing.expectEqual(models.TxDirection.stake, Pivx.directionFromCategory("immature").?);
    try std.testing.expectEqual(models.TxDirection.stake, Pivx.directionFromCategory("orphan").?);
    // Divi's added reward categories do NOT exist on PIVX — an unknown value has
    // no direction and is dropped rather than guessed at.
    try std.testing.expect(Pivx.directionFromCategory("stake_reward") == null);
    try std.testing.expect(Pivx.directionFromCategory("move") == null);
    try std.testing.expect(Pivx.directionFromCategory("something-unknown") == null);
}

test "paramsDir resolves the shared PIVXParams dir per platform" {
    const allocator = std.testing.allocator;
    const pathtest = @import("../pathtest.zig");

    // Every platform's path from one native run, mirroring upstream
    // `ZC_GetParamsDir`.
    {
        const p = try Pivx.paramsDirFor(allocator, "/home/alice", .linux);
        defer allocator.free(p);
        try pathtest.expectEqual("/home/alice/.pivx-params", p);
    }
    {
        const p = try Pivx.paramsDirFor(allocator, "/Users/alice", .macos);
        defer allocator.free(p);
        try pathtest.expectEqual("/Users/alice/Library/Application Support/PIVXParams", p);
    }
    {
        const p = try Pivx.paramsDirFor(allocator, "C:\\Users\\alice", .windows);
        defer allocator.free(p);
        try pathtest.expectEqual("C:\\Users\\alice\\AppData\\Roaming\\PIVXParams", p);
    }

    // An empty home is refused — a relative `.pivx-params` scattered into the
    // CWD is never acceptable for files the daemon must find.
    try std.testing.expectError(error.NoHomeDir, Pivx.paramsDir(allocator, ""));
}

test "sapling params carry the pinned upstream checksums" {
    // The two files upstream's install-params.sh verifies, with its own pins —
    // the same params (and hashes) the whole zcashd family shares.
    try std.testing.expectEqual(@as(usize, 2), Pivx.sapling_params.len);
    try std.testing.expectEqualStrings("sapling-spend.params", Pivx.sapling_params[0].name);
    try std.testing.expectEqualStrings("sapling-output.params", Pivx.sapling_params[1].name);
    for (Pivx.sapling_params) |p| {
        try std.testing.expectEqual(@as(usize, 64), p.sha256.len);
    }
}

test "installSaplingParams copies from the archive but never over another app's files" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-pivx-params-home";
    const root = "test-pivx-params-root";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    // A fake extracted archive whose params don't match the pinned hashes —
    // stand-in for a torn or tampered bundle. The copy must refuse.
    {
        var share = try std.Io.Dir.cwd().createDirPathOpen(io, root ++ "/" ++ Pivx.extracted_dir ++ "/share/pivx", .{});
        defer share.close(io);
        try share.writeFile(io, .{ .sub_path = "sapling-spend.params", .data = "not the real params" });
        try share.writeFile(io, .{ .sub_path = "sapling-output.params", .data = "not these either" });
    }
    try std.testing.expectError(
        error.ParamsChecksumMismatch,
        Pivx.installSaplingParams(allocator, root, home),
    );
    // The refusal left nothing behind where pivxd would look.
    {
        const params_dir = try Pivx.paramsDir(allocator, home);
        defer allocator.free(params_dir);
        try std.testing.expect(!install_mod.fileExists(allocator, params_dir, "sapling-spend.params"));
    }

    // Files already in the params dir are another app's property: with both
    // present, the (still-bogus) archive is never even hashed — the copy is a
    // no-op and the existing files are untouched.
    {
        const params_dir = try Pivx.paramsDir(allocator, home);
        defer allocator.free(params_dir);
        var pd = try std.Io.Dir.cwd().createDirPathOpen(io, params_dir, .{});
        defer pd.close(io);
        try pd.writeFile(io, .{ .sub_path = "sapling-spend.params", .data = "theirs" });
        try pd.writeFile(io, .{ .sub_path = "sapling-output.params", .data = "also theirs" });
    }
    try Pivx.installSaplingParams(allocator, root, home);
    {
        const params_dir = try Pivx.paramsDir(allocator, home);
        defer allocator.free(params_dir);
        var pd = try std.Io.Dir.cwd().openDir(io, params_dir, .{});
        defer pd.close(io);
        var buf: [16]u8 = undefined;
        const f = try pd.openFile(io, "sapling-spend.params", .{});
        defer f.close(io);
        const n = try f.readPositionalAll(io, &buf, 0);
        try std.testing.expectEqualStrings("theirs", buf[0..n]);
    }
}

test "prepareConf moves a BoxWallet-created dir off Divi's ports" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-pivx-conf-fresh";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    const data_dir = try Pivx.dataDir(allocator, home);
    defer allocator.free(data_dir);

    // Nothing on disk: the dir is ours, so both ports move off Divi's 51472/51473
    // or the second daemon to start dies on the bind.
    try Pivx.prepareConf(allocator, io, home);
    try expectConfValue(allocator, io, data_dir, "rpcport", "51475");
    try expectConfValue(allocator, io, data_dir, "port", "51474");

    // Idempotent, and the marker check now sees our own conf: a rerun must not
    // duplicate the keys or fall back to the upstream ports.
    try Pivx.prepareConf(allocator, io, home);
    try expectConfValue(allocator, io, data_dir, "rpcport", "51475");
    try expectConfValue(allocator, io, data_dir, "port", "51474");

    // A listen port the user chose afterwards is theirs — leave it alone.
    try conf.setValue(allocator, io, data_dir, Pivx.conf_file, "port", "51999");
    try Pivx.prepareConf(allocator, io, home);
    try expectConfValue(allocator, io, data_dir, "port", "51999");
}

test "prepareConf never retunes a data dir adopted from PIVX Desktop" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-pivx-conf-adopted";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    const data_dir = try Pivx.dataDir(allocator, home);
    defer allocator.free(data_dir);

    // What a PIVX Desktop ~/.pivx actually looks like: a synced chain, and a conf
    // that sets neither port because both are already upstream's defaults.
    const theirs = "# PIVX Desktop\nstaking=1\nmaxconnections=64\n";
    {
        var d = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
        defer d.close(io);
        try d.writeFile(io, .{ .sub_path = Pivx.conf_file, .data = theirs });
        try d.createDirPath(io, "blocks");
    }

    try Pivx.prepareConf(allocator, io, home);

    // The P2P port is untouched — the node still listens on 51472, so a forwarded
    // port and their peers survive the round trip through BoxWallet.
    try std.testing.expect((try conf.readValue(allocator, io, data_dir, Pivx.conf_file, "port")) == null);
    // And RPC stays on the port PIVX Desktop and any external tool expect.
    try expectConfValue(allocator, io, data_dir, "rpcport", "51473");
    // Which is also the port `readAuth` resolves, so BoxWallet talks to the node
    // the daemon actually bound.
    {
        const auth = try conf.readAuth(allocator, io, data_dir, Pivx.conf_file, Pivx.rpc_default_username, Pivx.rpc_default_port);
        defer conf.freeAuth(allocator, auth);
        try std.testing.expectEqualStrings("51473", auth.port);
    }
    // Their own settings are still there, verbatim.
    try expectConfValue(allocator, io, data_dir, "staking", "1");
    try expectConfValue(allocator, io, data_dir, "maxconnections", "64");
}

/// Assert `key` in the PIVX conf under `data_dir` reads back as `want`.
fn expectConfValue(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    key: []const u8,
    want: []const u8,
) !void {
    const got = (try conf.readValue(allocator, io, data_dir, Pivx.conf_file, key)) orelse {
        std.debug.print("conf has no `{s}` (expected {s})\n", .{ key, want });
        return error.TestExpectedEqual;
    };
    defer allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}
