const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const rpc = @import("../rpc.zig");
const install_mod = @import("../install.zig");
const conf = @import("../conf.zig");
const price = @import("../price.zig");
const walletfile = @import("../walletfile.zig");
const bip39 = @import("../bip39.zig");
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
    // No `price_id`: Divi is priced from its own exchange instead — see
    // `priceSource` below. Wiring both would fetch it twice and let whichever
    // reply landed last win.
    /// Donation address for BoxWallet development, in Divi's own
    /// currency.
    pub const tip_address = "DKHL4vUMS9BWcwhT4Y8NMJ62yYxLgeBdZb";
    /// Divi is proof-of-stake — the wallet can stake.
    pub const proof_of_stake = true;
    pub const conf_file = "divi.conf";
    pub const home_dir = ".divi";
    pub const home_dir_win = "DIVI";
    /// Which Windows directory that name hangs off — the roaming `%APPDATA%`, as
    /// every bitcoin-derived daemon picks. See `conf.WinBase`.
    pub const home_dir_win_base: conf.WinBase = .roaming;
    /// macOS data dir name. Divi Core: `~/Library/Application Support/DIVI`.
    pub const home_dir_mac: ?[]const u8 = "DIVI";
    pub const rpc_default_username = "divirpc";
    /// Upstream's mainnet RPC port (inherited from PIVX when Divi forked) — what
    /// divid binds when the conf says nothing. This is the *fallback*
    /// `conf.readAuth` seeds `CoinAuth.port` with, so it must stay equal to the
    /// daemon's own default; the port BoxWallet actually *writes* into a data dir
    /// it created is `rpc_boxwallet_port`.
    pub const rpc_default_port = "51473";

    // --- Ports for a data dir BoxWallet created --------------------------------
    //
    // Divi forked from PIVX and kept both of its mainnet ports (P2P 51472, RPC
    // 51473), so the two daemons can't both bind the defaults — the second to
    // start dies with "Unable to start HTTP server", then "Failed to listen on
    // any port". `pivx.zig` moves PIVX off them in a dir BoxWallet created; Divi
    // does the same here, because otherwise a user with an existing PIVX Desktop
    // install (which rightly keeps 51472/51473) who then installs Divi through
    // BoxWallet gets a fresh Divi dir handed exactly those ports.
    //
    // As in `pivx.zig`, this only ever applies to a dir BoxWallet made itself. A
    // dir adopted from Divi Desktop keeps upstream's ports: they're that app's
    // settings, and a user still switching between the two wallets must find
    // their node as they left it. See `prepareConf`.

    /// RPC port written into a `divi.conf` BoxWallet owns. `populate` writes it
    /// explicitly, so `readAuth` reads it straight back out of the conf and never
    /// falls through to `rpc_default_port`.
    pub const rpc_boxwallet_port = "51477";
    /// P2P listen port written into a `divi.conf` BoxWallet owns. Only the daemon
    /// consumes it, so it's a plain `port=` line that's never read back.
    pub const p2p_boxwallet_port = "51476";
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
    /// Divi's reply is sparse — verified against a live divid, it carries only
    /// `chain`, `blocks`, `headers`, `bestblockhash`, `difficulty` and
    /// `chainwork`. **No `verificationprogress`, no tip timestamp, and `headers`
    /// is merely a copy of `blocks`** (this daemon has no headers-first sync, so
    /// there is no header chain running ahead to compare against).
    ///
    /// That last point is why sync state can't come from the reply: `blocks >=
    /// headers` is trivially true, so deriving "synced" from it reported a
    /// caught-up chain from the first poll — pegging both frontends' gauges at
    /// 100% while the node was still hundreds of blocks behind. The honest
    /// measure left is the local height against the tip the *peers* report, which
    /// is what SpiderByte's daemon (same two gaps) already uses.
    pub fn blockchainState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.BlockchainState {
        var parsed = try rpc.callParsed(models.DiviBlockchainInfo, allocator, auth, "getblockchaininfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;

        // Network tip from peers. A getpeerinfo hiccup leaves it 0 (unknown),
        // which `syncFromNetworkHeight` deliberately reads as "not synced" rather
        // than risk claiming a chain is caught up when we can't tell.
        const network = rpc.networkHeight(allocator, auth) catch 0;

        // Tip timestamp for the "behind by …" wall-clock readout. This daemon's
        // `getblockchaininfo` carries none, so it comes from the tip block itself
        // — two extra calls, made only while actually behind.
        const behind = !models.syncFromNetworkHeight(r.blocks, network).synced;
        const tip_time = if (behind) rpc.tipBlockTime(allocator, auth, r.blocks) else 0;

        return mapBlockchainState(allocator, r, network, tip_time);
    }

    /// The pure half of `blockchainState`: a parsed reply plus the peer-estimated
    /// tip, mapped to the normalized model. Split out so the mapping is unit-
    /// testable without a daemon — the RPC calls above can't be.
    fn mapBlockchainState(
        allocator: std.mem.Allocator,
        r: models.DiviBlockchainInfo,
        network: i64,
        tip_time: i64,
    ) !models.BlockchainState {
        const st = models.syncFromNetworkHeight(r.blocks, network);
        return .{
            .chain = try allocator.dupe(u8, r.chain),
            .blocks = r.blocks,
            // No header-download phase on this daemon, so there's no header
            // progress to show: report the network tip and the Headers bar reads
            // complete, leaving the *Blocks* bar to carry the real progress. The
            // `max` guard keeps headers from ever falling below blocks, which
            // would peg the Blocks bar at a false 100%.
            .headers = @max(network, r.blocks),
            // The daemon reports no progress figure of its own, so the height
            // ratio stands in for it — without this the frontends' percentage
            // reads a flat 0% for the whole sync.
            .verification_progress = st.progress,
            .synced = st.synced,
            .network_height = network,
            .tip_time = tip_time,
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
        return conf.dataDir(allocator, home, home_dir, home_dir_win, home_dir_mac, home_dir_win_base);
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
        // The allow-list above names the only directories a snapshot may write,
        // so it is also what would silently drop *everything* if upstream ever
        // reshaped the archive (a versioned wrapper dir, a renamed `blocks/`).
        // Extraction would still report success, and divid would then be handed
        // an empty data dir and start syncing from genesis — a "the snapshot did
        // nothing" bug wearing a "the daemon won't start" costume. Say it plainly
        // instead, and leave nothing behind: no half-dir to suppress the next
        // prompt, no archive to unpack fruitlessly again.
        if (!chainPresent(allocator, data_dir)) {
            removeSnapshotDirs(allocator, data_dir);
            install_mod.discardPartial(allocator, install_root, snapshot_file);
            return error.SnapshotLaidDownNoChain;
        }

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
    ///
    /// A data dir BoxWallet created also gets its ports moved off the pair Divi
    /// shares with PIVX (see `rpc_boxwallet_port`); a dir adopted from Divi
    /// Desktop is left on upstream's, ports included. `blocks/` and the conf
    /// itself are the markers (`conf.dataDirHasEntry`), sampled *before*
    /// `populate` runs — it creates the conf, so checking afterwards would read
    /// every dir, including ours, as adopted.
    ///
    /// Existing installs don't move: `populate` wrote an explicit `rpcport=51473`
    /// into every conf BoxWallet has ever managed, and both it and the `port`
    /// guard below skip a key that's already there.
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

    // --- price ------------------------------------------------------------
    //
    // Divi is priced from NonKYC, the exchange its liquid market is actually on,
    // rather than from the roster host.
    //
    // Measured 2026-08-15, the two side by side:
    //
    //   CoinGecko `divi`   $0.00035     24h volume $24.51    24h change  -0.07%
    //   NonKYC DIVI/USDT   $0.0018193   24h volume ~$30k     24h change -14.86%
    //
    // CoinGecko's figure isn't stale in the usual sense — its timestamp was
    // current — it is a live price off a market trading twenty-four dollars a
    // day, and it is out by a factor of five. A holder was being shown a fifth
    // of what their Divi is worth, and a flat day when the market had moved 15%.
    //
    // The trade-off is going in with eyes open: one venue, no aggregation, a
    // ~0.8% spread, and nothing to cross-check against. That is worse in theory
    // than an aggregate and much better in practice than this particular one.

    /// NonKYC's public market endpoint for DIVI/USDT. No API key, and the URL is
    /// fixed — every BoxWallet requests it on every price cycle whether or not
    /// Divi is installed, so it reveals nothing about what the user holds (the
    /// same property the roster request has by construction).
    const price_url = "https://api.nonkyc.io/api/v2/market/getbysymbol/DIVI_USDT";

    /// The subset of NonKYC's market reply BoxWallet reads. **Every number in it
    /// arrives as a JSON string** (`"0.001825"`), hence the `[]const u8` fields;
    /// `isPaused` is the one genuine bool. Defaults keep the parse resilient to
    /// fields the host drops, and the reply carries ~60 keys in under 2 KB, well
    /// inside the transport's cap.
    const NonKycMarket = struct {
        /// The exchange's own USD conversion of the last trade. Preferred over
        /// `lastPrice`, which is denominated in USDT — near enough to a dollar
        /// but not the same thing, and this figure already accounts for it.
        primaryUsdValue: []const u8 = "",
        lastPrice: []const u8 = "",
        changePercent: []const u8 = "",
        /// A halted market: the last price is whatever it was when trading
        /// stopped, so it's reported as no price rather than as a live one.
        isPaused: bool = false,
    };

    /// Divi's price source, for `price.fetchOne`.
    pub fn priceSource() price.Source {
        return .{ .url = price_url, .parse = parsePrice };
    }

    /// Parse a NonKYC market reply into a quote. Null — meaning "no price", the
    /// same as an unlisted coin — for a halted market, an unreadable body, or a
    /// price that isn't a positive finite number. Retains nothing from `body`.
    fn parsePrice(gpa: std.mem.Allocator, body: []const u8) ?price.Quote {
        var parsed = std.json.parseFromSlice(
            NonKycMarket,
            gpa,
            body,
            .{ .ignore_unknown_fields = true },
        ) catch return null;
        defer parsed.deinit();

        const m = parsed.value;
        if (m.isPaused) return null;

        // The USD figure first, the USDT one only if the host omitted it.
        const usd = parseNum(m.primaryUsdValue) orelse parseNum(m.lastPrice) orelse return null;
        if (!(usd > 0) or !std.math.isFinite(usd)) return null;

        return .{
            .usd = usd,
            // A missing or unreadable change is null, not zero: "no figure" and
            // "flat" are different claims, and `Quote.change_24h` is optional
            // precisely so a caller can't confuse them.
            .change_24h = parseNum(m.changePercent),
            .have = true,
        };
    }

    /// A host number (a JSON string) as f64, or null when it's absent or not a
    /// number. Scalar out, nothing borrowed.
    fn parseNum(s: []const u8) ?f64 {
        if (s.len == 0) return null;
        const v = std.fmt.parseFloat(f64, s) catch return null;
        if (!std.math.isFinite(v)) return null;
        return v;
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

    /// Back up the wallet to `dest_path` via `backupwallet` — a binary copy of
    /// `wallet.dat`, which is what this daemon offers: divid has **no**
    /// `dumpwallet`/`importwallet` pair (checked against the shipped divi-cli
    /// 3.0.0), so there is no key-dump text file for it either to write or to
    /// read back. The counterpart restore is therefore the offline file swap
    /// below, not `wallet_import_file`.
    ///
    /// This is the user's backup, not a temp — don't shred it. Works regardless
    /// of lock state (it is just a file copy). The path is JSON-escaped before
    /// splicing.
    pub fn walletBackup(allocator: std.mem.Allocator, auth: models.CoinAuth, dest_path: []const u8) !void {
        const qpath = try rpc.jsonQuote(allocator, dest_path);
        defer allocator.free(qpath);
        const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qpath});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "backupwallet", params);
    }

    /// Restore the wallet by swapping in a user-supplied backup `wallet.dat`.
    /// The daemon holds the file open while running, so the caller stops it
    /// before calling this and restarts it after (the offline-restore
    /// orchestration in `app.zig` / `capi.zig`); this hook only touches files and
    /// takes no auth.
    ///
    /// Divi keeps its wallet at the top of the data dir — it predates Core's
    /// named-wallet sub-directories, and `divi-cli` exposes no `createwallet` —
    /// so the destination is `<data_dir>/wallet.dat`. Safety is
    /// `walletfile.restoreOffline`'s: a text key dump or an empty file is
    /// refused, and the current wallet is moved aside to a timestamped sibling
    /// before anything is written.
    pub fn walletRestoreFileOffline(
        allocator: std.mem.Allocator,
        home: []const u8,
        src_path: []const u8,
    ) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);

        return walletfile.restoreOffline(allocator, data_dir, "wallet.dat", src_path);
    }

    // --- restore from seed words ------------------------------------------
    //
    // divid is HD (BIP39, standard derivation — `dumphdinfo` on a wallet built
    // from the canonical all-zero-entropy phrase returns exactly the BIP39 test
    // vector's seed), and it takes the phrase through a `mnemonic=` conf entry or
    // the matching `-mnemonic` argv. Verified against the shipped divid 3.0.0.
    //
    // **Neither of those is safe to point at the user's own data dir**, which is
    // the whole reason this hook works the way it does:
    //
    //   * The help text says `-mnemonic` "only has effect during wallet
    //     creation/first start". It does not. On *every* start with the entry
    //     present, divid renames the current wallet to `wallet.dat<unixtime>.moved`
    //     and builds a fresh one — even when the phrase already matches the wallet
    //     that is there. Left in a conf, it is a wallet-wipe armed on every launch,
    //     in a file BoxWallet shares with whatever else owns that dir.
    //   * It moves the wallet aside *before* validating the phrase, so a mistyped
    //     seed leaves the user with their wallet renamed and a daemon that won't
    //     start ("SetMnemonic: invalid mnemonic: please check your words").
    //   * `divi.conf` is world-readable in the wild (mode 664 as divid leaves it),
    //     and argv is readable by any local user for the daemon's whole lifetime,
    //     so both routes publish the seed to every account on the machine.
    //
    // So the phrase is never written to the user's conf and never passed on the
    // real daemon's command line. Instead a throwaway data dir under the install
    // root — ours, created 0700, deleted on every path — gets a minimal conf
    // carrying the `mnemonic=`, divid is run against *that* to mint the wallet,
    // and the resulting `wallet.dat` is swapped into the real data dir through
    // the same `walletfile.restoreOffline` the file restore uses. The user's
    // wallet is kept aside timestamped, an invalid phrase fails in the scratch dir
    // without the real one ever being touched, and the secret's only disk
    // residence is a private file shredded in a `defer`.

    /// Owner-only modes for the scratch dir and the conf inside it. `Permissions`
    /// is the portable type: a POSIX mode on Unix, a file-attribute enum on
    /// Windows (which has no mode bits, so it keeps the default there and relies
    /// on the profile directory's own ACL).
    const private_dir_perms: std.Io.File.Permissions =
        if (builtin.os.tag == .windows) .default_dir else @enumFromInt(0o700);
    const private_file_perms: std.Io.File.Permissions =
        if (builtin.os.tag == .windows) .default_file else @enumFromInt(0o600);

    /// Name of the scratch data dir minted under the install root. Keyed off the
    /// daemon name so a concurrent op on another coin can't collide.
    const seed_restore_dir = ".boxwallet-" ++ daemon_file ++ ".seedrestore";

    /// Ports the scratch daemon binds. It only has to reach the point of creating
    /// a wallet, so it runs with no network at all (`connect=0`, `listen=0`,
    /// `maxconnections=0`) — but it still binds an RPC port to be asked whether
    /// the restore took, and that must not be a port a real node might hold.
    const seed_restore_rpc_port = "51479";
    const seed_restore_p2p_port = "51478";

    /// Read the wallet's HD seed back out so the user can write it down — the
    /// counterpart of the seed restore, and the reason a Divi wallet created here
    /// is recoverable at all. Without it the restore only helps someone who got
    /// their phrase from another wallet.
    ///
    /// `dumphdinfo` needs a readable wallet: divid answers -13 ("Please enter the
    /// wallet passphrase") on a locked one, which is why the menu only offers this
    /// when the wallet is unencrypted or unlocked. That error is threaded up as-is
    /// rather than flattened, so "unlock first" is distinguishable from "this
    /// daemon can't".
    ///
    /// A wallet that was itself restored from a raw hex seed has **no mnemonic**
    /// (verified: `dumphdinfo` returns an empty string for it), so the hex is
    /// carried too and is the only thing to write down in that case.
    pub fn walletSeedBackup(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        detail: *Coin.WalletErrSink,
    ) !Coin.SeedBackup {
        const body = rpc.call(allocator, auth, "dumphdinfo") catch |err| {
            detail.set(@errorName(err));
            return error.SeedBackupFailed;
        };
        defer {
            // The reply *is* the seed — don't leave it in freed memory.
            @memset(body, 0);
            allocator.free(body);
        }

        // A daemon-side refusal (locked wallet, most likely) comes back as a JSON
        // error rather than the fields, so say what it said.
        const hex = jsonStringField(body, "hdseed") orelse {
            // A refusal comes back as {"error":{"code":-13,"message":"..."}} — the
            // message is the useful half ("Please enter the wallet passphrase
            // with walletpassphrase first"), so pass it through verbatim.
            if (jsonStringField(body, "message")) |msg| {
                detail.set(msg);
            } else {
                detail.set("The daemon didn't return this wallet's seed.");
            }
            return error.SeedBackupFailed;
        };

        const out: Coin.SeedBackup = .{
            .words = .from(jsonStringField(body, "mnemonic") orelse ""),
            .passphrase = .from(jsonStringField(body, "mnemonicpassphrase") orelse ""),
            .hex = .from(hex),
        };
        return out;
    }

    /// Restore the wallet from a BIP39 mnemonic **or** a raw 512-bit `hdseed`,
    /// with the daemon stopped.
    ///
    /// `seed` takes either form and they are told apart here rather than by the
    /// user (`bip39.looksLikeHexSeed` — the two are unambiguous by construction):
    ///
    ///   * **Words** go to divid as `mnemonic=`, with `passphrase` as
    ///     `mnemonicpassphrase=` when non-empty. They are normalized and
    ///     checksum-checked first, so a mistyped word is a message rather than a
    ///     minute-long daemon start that fails; divid's own check stays the
    ///     authority.
    ///   * **Hex** goes as `hdseed=`. That value is what the mnemonic and the
    ///     passphrase *derive to*, so a passphrase alongside it is meaningless and
    ///     is refused rather than silently ignored — quietly dropping it would
    ///     restore a wallet the user didn't ask for.
    ///
    /// `passphrase` is the BIP39 passphrase (the "25th word"), **not** the wallet
    /// encryption password. It is part of the secret: the same words with and
    /// without one derive completely different wallets, so an omitted passphrase
    /// restores an empty wallet rather than failing. Verified against divid 3.0.0,
    /// which implements the standard derivation (the `TREZOR` test vector matches).
    ///
    /// `wallet_password` encrypts the restored wallet before it is swapped in.
    /// **This matters more than it looks.** A wallet minted from a seed is a fresh,
    /// *unencrypted* one, so restoring over an encrypted wallet would otherwise
    /// hand back the same funds with the password silently removed — a security
    /// downgrade the user never asked for and wouldn't notice. Empty deliberately
    /// leaves it unencrypted (the front-end says so at the confirm), which is the
    /// right answer when the wallet being restored never had a password.
    ///
    /// The encryption happens **inside the scratch dir**, against the throwaway
    /// daemon, before anything is swapped: `encryptwallet` needs a running daemon,
    /// and the alternative — swap first, then encrypt after the real daemon comes
    /// back — leaves a window where the funds sit unencrypted on disk, and fails
    /// messily if the restart doesn't happen. Verified on divid 3.0.0 that
    /// encrypting preserves the HD seed, mnemonic and keys (it answers "Wallet
    /// reloaded!" and, unlike Bitcoin Core, keeps running).
    ///
    /// On success the real `<data_dir>/wallet.dat` has been replaced (previous one
    /// kept aside, timestamped) and the caller restarts the daemon, which rescans
    /// and picks up the restored keys.
    ///
    /// Both secrets are wiped: the normalized copies, the conf text built around
    /// them, and the scratch dir holding that conf all go on every path.
    pub fn walletRestoreSeed(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home: []const u8,
        seed: []const u8,
        passphrase: []const u8,
        wallet_password: []const u8,
        detail: *Coin.WalletErrSink,
    ) !void {
        // Normalize exactly as every other restore does — a phrase pasted with
        // stray case or double spaces still restores. For the hex form this just
        // lowercases and trims it, which is equally what we want.
        const words = try models.normalizeSeedWords(allocator, seed);
        defer {
            @memset(words, 0);
            allocator.free(words);
        }

        // The passphrase reaches divid as a `key=value` conf line, so anything it
        // can't survive that trip has to be refused rather than mangled: a newline
        // would inject a conf line outright, and leading/trailing spaces are eaten
        // by the parser — which would silently restore a *different* wallet, the
        // exact failure this whole hook exists to prevent. (The post-start check
        // against `dumphdinfo` would catch it, but a minute later and less
        // clearly.) The seed itself is already safe: normalizing tokenizes it on
        // whitespace, so no control character survives.
        for (passphrase) |c| {
            if (c == '\n' or c == '\r' or c == 0) {
                detail.set("That passphrase contains a line break, which Divi can't accept.");
                return error.InvalidSeed;
            }
        }
        if (passphrase.len > 0 and
            (std.ascii.isWhitespace(passphrase[0]) or std.ascii.isWhitespace(passphrase[passphrase.len - 1])))
        {
            detail.set("That passphrase starts or ends with a space, which Divi would drop — restoring a different wallet. Remove it, or the seed isn't the one you think.");
            return error.InvalidSeed;
        }

        const is_hex = bip39.looksLikeHexSeed(words);
        if (is_hex) {
            // A passphrase only exists on the way from words to a seed. Given the
            // seed itself there is nothing left for it to do, and honouring the
            // request as typed is impossible — so say so instead of restoring
            // something subtly different from what was asked for.
            if (passphrase.len > 0) {
                detail.set("A raw hex seed already includes any passphrase — clear the passphrase field, or enter your words instead.");
                return error.InvalidSeed;
            }
        } else {
            bip39.validate(words) catch |err| {
                detail.set(switch (err) {
                    error.BadWordCount => "That isn't a BIP39 seed length — Divi takes 12, 15, 18, 21 or 24 words (or a 128-character hex seed).",
                    error.UnknownWord => "One of those words isn't in the BIP39 wordlist — check for a typo.",
                    error.BadChecksum => "Those are all real words, but the phrase's checksum doesn't match — a word is probably mistyped or two are swapped.",
                });
                return error.InvalidSeed;
            };
        }

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        // --- the scratch data dir -----------------------------------------
        const scratch = try std.fs.path.join(allocator, &.{ install_root, seed_restore_dir });
        defer allocator.free(scratch);

        // A leftover from an interrupted run would hand divid a wallet that
        // already exists (and a stale conf), so start from nothing every time.
        std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
        // Remove the whole scratch tree however we leave here: it holds the conf
        // with the plaintext seed and the minted wallet itself.
        defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};

        // Owner-only from the moment it exists — the conf about to land in it
        // carries the seed in plaintext, and the user's own `divi.conf` is
        // world-readable in the wild (divid leaves it 0664).
        var sdir = try std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{ .permissions = private_dir_perms });
        defer sdir.close(io);

        // Random RPC password: the scratch daemon is localhost-only and lives for
        // seconds, but it is still a live wallet RPC while it runs.
        var pw_buf: [32]u8 = undefined;
        const rpc_pw = conf.randomPassword(io, &pw_buf);
        defer @memset(&pw_buf, 0);

        // The scratch conf. `daemon=1` so the launcher forks and returns;
        // everything else keeps it off the network — it never needs a peer, only
        // to reach wallet creation.
        // The secret half of the conf: the seed in whichever form it arrived, plus
        // the passphrase line only when there is one (an empty `mnemonicpassphrase=`
        // is the same as absent, but writing it needlessly puts an extra copy of a
        // secret-shaped line on disk).
        const seed_lines = if (is_hex)
            try std.fmt.allocPrint(allocator, "hdseed={s}\n", .{words})
        else if (passphrase.len > 0)
            try std.fmt.allocPrint(allocator, "mnemonic={s}\nmnemonicpassphrase={s}\n", .{ words, passphrase })
        else
            try std.fmt.allocPrint(allocator, "mnemonic={s}\n", .{words});
        defer {
            @memset(seed_lines, 0);
            allocator.free(seed_lines);
        }

        const conf_text = try std.fmt.allocPrint(allocator,
            \\server=1
            \\daemon=1
            \\listen=0
            \\connect=0
            \\maxconnections=0
            \\rpcuser={s}
            \\rpcpassword={s}
            \\rpcport={s}
            \\port={s}
            \\{s}
        , .{ rpc_default_username, rpc_pw, seed_restore_rpc_port, seed_restore_p2p_port, seed_lines });
        // Shred the in-memory copy of the conf — it carries the seed verbatim.
        defer {
            @memset(conf_text, 0);
            allocator.free(conf_text);
        }
        try sdir.writeFile(io, .{
            .sub_path = conf_file,
            .data = conf_text,
            .flags = .{ .permissions = private_file_perms },
        });

        // --- mint the wallet ----------------------------------------------
        const daemon_path = try std.fs.path.join(allocator, &.{ install_root, daemon_file });
        defer allocator.free(daemon_path);
        const datadir_arg = try std.fmt.allocPrint(allocator, "-datadir={s}", .{scratch});
        defer allocator.free(datadir_arg);

        // The launcher forks and exits on POSIX; on Windows divid has no -daemon
        // and stays in the foreground, so it is spawned detached and polled the
        // same way. Either way the wallet is minted asynchronously and the RPC
        // below is what says it finished.
        const argv = [_][]const u8{ daemon_path, datadir_arg };
        var child = std.process.spawn(io, .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| {
            detail.set(@errorName(err));
            return error.WalletRestoreFailed;
        };

        const scratch_auth: models.CoinAuth = .{
            .rpc_user = rpc_default_username,
            .rpc_password = rpc_pw,
            .ip_address = "127.0.0.1",
            .port = seed_restore_rpc_port,
            .data_dir = scratch,
        };

        // However we leave, the scratch daemon must not outlive us — it holds the
        // wallet file open and would keep binding its port. The success path stops
        // it early (the swap can't read a file the daemon still owns) and clears
        // this, so the child is reaped exactly once: `Child.wait` asserts on a
        // second call rather than tolerating it.
        var stopped = false;
        defer if (!stopped) stopScratchDaemon(allocator, io, scratch_auth, &child);

        // Poll `dumphdinfo` until the wallet exists. It is both the readiness
        // signal and the verification: it returns the phrase the wallet was
        // actually built from, so a mismatch is caught before anything is swapped
        // into the real data dir. ~90s covers a cold start on a slow disk; a
        // daemon that died on a bad phrase never answers and we fall out.
        var ok = false;
        var waited: usize = 0;
        while (waited < 90) : (waited += 1) {
            io.sleep(.fromSeconds(1), .awake) catch {};
            const body = rpc.call(allocator, scratch_auth, "dumphdinfo") catch continue;
            defer allocator.free(body);

            // Compare against what we asked for rather than merely trusting a 200:
            // this is the one moment we can prove the restore took. A hex restore
            // is checked against `hdseed` (its `mnemonic` comes back empty — the
            // words aren't recoverable from a seed); a word restore against
            // `mnemonic`, *and* against `mnemonicpassphrase`, since the same words
            // with and without a passphrase are different wallets and a dropped
            // passphrase would otherwise pass silently as a success.
            const field = if (is_hex) "hdseed" else "mnemonic";
            const got = jsonStringField(body, field) orelse {
                // Answered, but with no such field — not a wallet we can vouch for.
                if (std.mem.indexOf(u8, body, "\"hdseed\"") != null) {
                    detail.set("divid answered with a wallet this restore can't verify.");
                    return error.WalletRestoreFailed;
                }
                continue;
            };
            if (!std.mem.eql(u8, got, words)) {
                detail.set(if (is_hex)
                    "divid built a wallet from a different seed than the one given."
                else
                    "divid built a wallet from a different phrase than the one given.");
                return error.WalletRestoreFailed;
            }
            if (!is_hex) {
                const got_pp = jsonStringField(body, "mnemonicpassphrase") orelse "";
                if (!std.mem.eql(u8, got_pp, passphrase)) {
                    detail.set("divid didn't apply the passphrase — the restored wallet would be the wrong one.");
                    return error.WalletRestoreFailed;
                }
            }
            ok = true;
            break;
        }
        if (!ok) {
            // The daemon never got to a wallet. Its own log carries the reason —
            // a bad phrase reads "SetMnemonic: invalid mnemonic: please check
            // your words".
            setScratchFailureReason(allocator, io, scratch, detail);
            return error.WalletRestoreFailed;
        }

        // Encrypt the freshly-minted wallet *before* it leaves the sandbox, so the
        // file that lands in the user's data dir is already protected and there is
        // never a moment where the restored funds sit unencrypted in place.
        if (wallet_password.len > 0) {
            walletEncrypt(allocator, scratch_auth, wallet_password) catch |err| {
                detail.set(@errorName(err));
                return error.WalletEncryptFailed;
            };

            // divid reloads the wallet in place ("Wallet reloaded!") rather than
            // shutting down as Core does, so wait for it to answer again and then
            // confirm it really is encrypted — shipping a wallet the user believes
            // is protected but isn't would be worse than failing here.
            var enc_ok = false;
            var enc_wait: usize = 0;
            while (enc_wait < 60) : (enc_wait += 1) {
                io.sleep(.fromSeconds(1), .awake) catch {};
                const info = rpc.call(allocator, scratch_auth, "getwalletinfo") catch continue;
                defer allocator.free(info);
                const status = jsonStringField(info, "encryption_status") orelse continue;
                if (!std.mem.eql(u8, status, "unencrypted")) {
                    enc_ok = true;
                    break;
                }
            }
            if (!enc_ok) {
                detail.set("The restored wallet couldn't be encrypted, so it was not installed.");
                return error.WalletEncryptFailed;
            }
        }

        // Stop it before touching the file it has open, then swap.
        stopScratchDaemon(allocator, io, scratch_auth, &child);
        stopped = true;

        const src_wallet = try std.fs.path.join(allocator, &.{ scratch, "wallet.dat" });
        defer allocator.free(src_wallet);
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);

        // The same swap the file restore uses — so the user's existing wallet is
        // kept aside under a timestamped name rather than destroyed.
        walletfile.restoreOffline(allocator, data_dir, "wallet.dat", src_wallet) catch |err| {
            detail.set(@errorName(err));
            return err;
        };
    }

    /// The value of top-level string field `name` in `body`, or null if it isn't
    /// there. A deliberately small reader for the one reply this restore checks:
    /// `dumphdinfo` returns three flat string fields, and the values compared
    /// against it (a mnemonic, a hex seed, a passphrase) are the whole point of
    /// the verification — so it reads the field rather than substring-matching the
    /// body, where a passphrase that happened to occur inside the mnemonic would
    /// have matched the wrong thing.
    ///
    /// Returns a slice *into* `body`, so it lives as long as the caller's buffer.
    /// Escapes are not decoded: divid emits none for these fields, and a value
    /// containing one simply fails to compare equal, which fails the restore
    /// closed rather than open.
    fn jsonStringField(body: []const u8, name: []const u8) ?[]const u8 {
        // Match the quoted key, so "mnemonic" can't match "mnemonicpassphrase".
        var key_buf: [64]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "\"{s}\"", .{name}) catch return null;

        var from: usize = 0;
        while (std.mem.indexOfPos(u8, body, from, key)) |at| {
            from = at + key.len;
            // Only a `"key" : "value"` pair counts; skip whitespace then the colon.
            var i = from;
            while (i < body.len and (body[i] == ' ' or body[i] == '\t')) i += 1;
            if (i >= body.len or body[i] != ':') continue;
            i += 1;
            while (i < body.len and (body[i] == ' ' or body[i] == '\t')) i += 1;
            if (i >= body.len or body[i] != '"') continue;
            i += 1;
            const end = std.mem.indexOfScalarPos(u8, body, i, '"') orelse return null;
            return body[i..end];
        }
        return null;
    }

    /// Ask the scratch daemon to stop over RPC, then make sure it is gone and reap
    /// the child. **Call exactly once** — `Child.wait` asserts if the process has
    /// already been reaped, so the caller tracks whether it has run.
    fn stopScratchDaemon(
        allocator: std.mem.Allocator,
        io: std.Io,
        auth: models.CoinAuth,
        child: *std.process.Child,
    ) void {
        if (rpc.call(allocator, auth, "stop")) |body| {
            allocator.free(body);
            // Give it a moment to flush the wallet and unlink its lock.
            var waited: usize = 0;
            while (waited < 30) : (waited += 1) {
                io.sleep(.fromSeconds(1), .awake) catch {};
                if (!rpc.daemonReachable(allocator, auth)) break;
            }
        } else |_| {}
        // On POSIX the launcher has already exited (it forked); on Windows this is
        // the daemon itself. Either way, reap what we spawned so no zombie is left.
        _ = child.wait(io) catch {};
    }

    /// Put the reason the scratch daemon never produced a wallet into `detail`,
    /// read from the last failure-looking line of its own `debug.log`. The point
    /// is to thread divid's words up ("SetMnemonic: invalid mnemonic: please
    /// check your words") rather than swallow them into a bare "restore failed".
    ///
    /// Writes through the sink rather than returning a slice: the log tail lives
    /// in a stack buffer here, and `WalletErrSink.set` copies.
    fn setScratchFailureReason(
        allocator: std.mem.Allocator,
        io: std.Io,
        scratch: []const u8,
        detail: *Coin.WalletErrSink,
    ) void {
        detail.set("divid didn't finish creating the wallet — see the action log.");

        const log_path = std.fs.path.join(allocator, &.{ scratch, "debug.log" }) catch return;
        defer allocator.free(log_path);

        var f = std.Io.Dir.openFileAbsolute(io, log_path, .{}) catch return;
        defer f.close(io);
        const stat = f.stat(io) catch return;

        // Bounded tail — the log is small here (a chainless start), but the rule
        // holds regardless of size.
        var buf: [4096]u8 = undefined;
        const start = if (stat.size > buf.len) stat.size - buf.len else 0;
        const n = f.readPositionalAll(io, &buf, start) catch return;

        var it = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (std.mem.indexOf(u8, t, "SetMnemonic") != null or
                std.mem.startsWith(u8, t, "Error:"))
            {
                detail.set(t);
            }
        }
    }

    /// Divi retains `getinfo`, so probe it for the daemon's warm-up phase.
    pub fn warmupProbeMethod() []const u8 {
        return "getinfo";
    }

    // --- vtable plumbing -------------------------------------------------

    /// The block-index rebuild. Markers are the Core-derived defaults, checked
    /// against the shipped divid binary.
    pub const reindex_caps: Coin.Reindex = .{
        .warning = "divid re-reads the block files already on disk to rebuild the index — hours of CPU on a large chain, and the daemon is unusable until it finishes. Nothing is downloaded a second time unless this node is pruned, in which case the blocks it has already deleted are fetched again.",
    };

    const vtable: Coin.VTable = .{
        .coin_name = vtCoinName,
        .coin_name_abbrev = vtCoinNameAbbrev,
        .coin_description = vtCoinDescription,
        .coin_color = vtCoinColor,
        .tip_address = vtTipAddress,
        .price_source = vtPriceSource,
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
        // `backupwallet` copies the wallet file with its keys still encrypted, so
        // it works in every lock state — including locked, where a key dump can't.
        .wallet_backup_kind = .file_copy,
        .wallet_seed_backup = vtWalletSeedBackup,
        .wallet_restore_file_offline = vtWalletRestoreFileOffline,
        .wallet_restore_seed = vtWalletRestoreSeed,
        // divid takes any standard BIP39 length (verified: 12 and 24 both mint a
        // wallet whose `dumphdinfo` seed matches the canonical test vector).
        .restore_seed_word_counts = &.{ 12, 15, 18, 21, 24 },
        .warmup_probe_method = vtWarmupProbeMethod,
        .reindex = &reindex_caps,
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
    fn vtPriceSource(_: *anyopaque) price.Source {
        return priceSource();
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
    fn vtWalletSeedBackup(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        detail: *Coin.WalletErrSink,
    ) anyerror!Coin.SeedBackup {
        return walletSeedBackup(allocator, auth, detail);
    }
    fn vtWalletRestoreSeed(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home: []const u8,
        seed: []const u8,
        passphrase: []const u8,
        wallet_password: []const u8,
        detail: *Coin.WalletErrSink,
    ) anyerror!void {
        return walletRestoreSeed(allocator, install_root, home, seed, passphrase, wallet_password, detail);
    }
    fn vtWarmupProbeMethod(_: *anyopaque) []const u8 {
        return warmupProbeMethod();
    }
};

test "sync state comes from the peer tip, not the daemon's mirrored headers" {
    const allocator = std.testing.allocator;

    // A live divid reply, verbatim in shape: no verificationprogress, no tip
    // timestamp, and headers identical to blocks — this daemon has no
    // headers-first sync, so the two always match whatever the network is doing.
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

    // The reply parses as it always did: blocks == headers, no progress figure.
    try std.testing.expectEqual(@as(i64, 4071165), r.blocks);
    try std.testing.expectEqual(r.blocks, r.headers);
    try std.testing.expectEqual(@as(f64, 0), r.verificationprogress);

    // Behind the tip the peers report. The old `blocks >= headers` test called
    // this synced — it is trivially true on every reply this daemon sends — which
    // is exactly the bug: gauges pegged at 100% through the whole sync.
    {
        const state = try Divi.mapBlockchainState(allocator, r, 4_141_990, 1785101525);
        defer state.deinit(allocator);
        try std.testing.expect(!state.synced);
        try std.testing.expect(state.verification_progress > 0.98 and state.verification_progress < 1.0);
        // Headers read as the tip, so that bar shows complete (nothing to
        // pre-download) and the Blocks bar carries the real progress.
        try std.testing.expectEqual(@as(i64, 4_141_990), state.headers);
        try std.testing.expectEqual(@as(i64, 4071165), state.blocks);
        try std.testing.expectEqual(@as(i64, 4_141_990), state.network_height);
        // A tip timestamp is carried through for the "behind by …" readout.
        try std.testing.expectEqual(@as(i64, 1785101525), state.tip_time);
    }

    // Caught up to the tip.
    {
        const state = try Divi.mapBlockchainState(allocator, r, r.blocks, 0);
        defer state.deinit(allocator);
        try std.testing.expect(state.synced);
        try std.testing.expectApproxEqAbs(@as(f64, 1), state.verification_progress, 0.0001);
    }

    // No peers: the tip is unknown, so it must read as syncing rather than claim
    // a chain we can't measure is finished. Headers must not sink below blocks
    // either — that would peg the Blocks bar at a false 100%, the very failure
    // the old logic produced.
    {
        const state = try Divi.mapBlockchainState(allocator, r, 0, 0);
        defer state.deinit(allocator);
        try std.testing.expect(!state.synced);
        try std.testing.expectEqual(@as(f64, 0), state.verification_progress);
        try std.testing.expectEqual(r.blocks, state.headers);
    }
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
    try std.testing.expectEqualStrings("divid" ++ Divi.exe_suffix, c.daemonFile());
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

test "a snapshot that lays down no chain fails instead of reporting success" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-divi-snapshot-empty";
    const root = "test-divi-snapshot-empty-root";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var dd = try std.Io.Dir.cwd().createDirPathOpen(io, home ++ "/.divi", .{});
    defer dd.close(io);
    // A wallet and a conf already in the data dir, as on any real machine.
    try dd.writeFile(io, .{ .sub_path = "wallet.dat", .data = "mine, not the archive's" });

    var rd = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer rd.close(io);
    // An archive shaped the way upstream's *isn't*: nothing the allow-list
    // permits, so the extraction writes nothing at all. Standing in for upstream
    // reshaping the snapshot (a versioned wrapper dir, a renamed blocks/) — the
    // case where the guard would otherwise drop everything in silence.
    try rd.writeFile(io, .{
        .sub_path = Divi.snapshot_file,
        .data = @embedFile("../testdata/fixture.tar.gz"),
    });

    try std.testing.expectError(
        error.SnapshotLaidDownNoChain,
        Divi.snapshotApply(allocator, root, home, null, null),
    );

    // Nothing usable was left behind to confuse the next run: no chain dirs to
    // suppress the prompt, and no archive to unpack fruitlessly again.
    try std.testing.expect(!Divi.chainPresent(allocator, home ++ "/.divi"));
    try std.testing.expect(!install_mod.fileExists(allocator, root, Divi.snapshot_file));

    // And the wallet that was already there is untouched — the allow-list's
    // whole purpose, checked on the failure path too.
    var wallet_buf: [64]u8 = undefined;
    const wf = try dd.openFile(io, "wallet.dat", .{});
    defer wf.close(io);
    const n = try wf.readPositionalAll(io, &wallet_buf, 0);
    try std.testing.expectEqualStrings("mine, not the archive's", wallet_buf[0..n]);
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

test "parses a NonKYC market reply into a USD quote" {
    // A real reply from api.nonkyc.io, captured 2026-08-15 (trimmed to the keys
    // BoxWallet reads plus a few of its neighbours, so the ignore-unknowns path
    // is exercised too). Every number in it is a JSON *string* — that is the
    // shape this parser exists for.
    const body =
        \\{"_id":"69093a8681166a1edcbfd0d2","symbol":"DIVI/USDT","primaryName":"Divi",
        \\"primaryTicker":"DIVI","lastPrice":"0.001825","yesterdayPrice":"0.0021436",
        \\"highPrice":"0.0023222","lowPrice":"0.001806","volume":"16467044.0000",
        \\"isPaused":false,"bestAsk":"0.0018267","bestBid":"0.0018112",
        \\"primaryUsdValue":"0.001819305000","changePercent":"-14.86","spreadPercent":"0.848"}
    ;
    const q = Divi.parsePrice(std.testing.allocator, body).?;
    try std.testing.expect(q.have);
    // The exchange's own USD figure, not the USDT lastPrice beside it.
    try std.testing.expectApproxEqAbs(@as(f64, 0.001819305), q.usd, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -14.86), q.change_24h.?, 1e-9);

    // For scale, this is what the roster host was reporting the same day —
    // a fifth of the price, off a market doing $24 a day. The gap is the whole
    // reason Divi is priced from here.
    try std.testing.expect(q.usd > 0.00035 * 4);
}

test "a NonKYC reply with no usable price reads as no price, not a wrong one" {
    const allocator = std.testing.allocator;

    // A halted market: the last trade is whatever it was when trading stopped,
    // so it must not be shown as a live price.
    try std.testing.expect(Divi.parsePrice(allocator,
        \\{"symbol":"DIVI/USDT","primaryUsdValue":"0.0018","isPaused":true}
    ) == null);

    // No price field at all, a zero, a negative, and a non-numeric one.
    for ([_][]const u8{
        \\{"symbol":"DIVI/USDT","isPaused":false}
        ,
        \\{"primaryUsdValue":"0","lastPrice":"0","isPaused":false}
        ,
        \\{"primaryUsdValue":"-1","isPaused":false}
        ,
        \\{"primaryUsdValue":"n/a","isPaused":false}
        ,
        \\not json at all
        ,
    }) |body| {
        try std.testing.expect(Divi.parsePrice(allocator, body) == null);
    }

    // Missing the USD conversion falls back to the USDT last price rather than
    // dropping the quote — near enough for an ambient figure.
    const fallback = Divi.parsePrice(allocator,
        \\{"symbol":"DIVI/USDT","lastPrice":"0.001825","isPaused":false}
    ).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.001825), fallback.usd, 1e-12);

    // An unreadable change is null, not zero: "no figure" and "flat" are
    // different claims about a market.
    const no_change = Divi.parsePrice(allocator,
        \\{"primaryUsdValue":"0.0018","changePercent":"","isPaused":false}
    ).?;
    try std.testing.expect(no_change.change_24h == null);
}

test "Divi is priced from its own source, and never from the roster" {
    var divi: Divi = .{};
    const c = divi.coin();
    try std.testing.expect(c.priceId() == null);
    const source = c.priceSource().?;
    try std.testing.expect(std.mem.indexOf(u8, source.url, "nonkyc.io") != null);
    // The pair matters: a USDT market, whose USD conversion the reply carries.
    try std.testing.expect(std.mem.endsWith(u8, source.url, "DIVI_USDT"));
}

test "prepareConf moves a BoxWallet-created dir off the ports Divi shares with PIVX" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-divi-conf-fresh";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    const data_dir = try Divi.dataDir(allocator, home);
    defer allocator.free(data_dir);

    // Nothing on disk: the dir is ours, so both ports move off 51472/51473 —
    // which an adopted PIVX Desktop install is entitled to keep.
    try Divi.prepareConf(allocator, io, home);
    try expectConfValue(allocator, io, data_dir, "rpcport", "51477");
    try expectConfValue(allocator, io, data_dir, "port", "51476");

    // Idempotent, and the marker check now sees our own conf: a rerun must not
    // duplicate the keys or fall back to the upstream ports.
    try Divi.prepareConf(allocator, io, home);
    try expectConfValue(allocator, io, data_dir, "rpcport", "51477");
    try expectConfValue(allocator, io, data_dir, "port", "51476");

    // A listen port the user chose afterwards is theirs — leave it alone.
    try conf.setValue(allocator, io, data_dir, Divi.conf_file, "port", "51999");
    try Divi.prepareConf(allocator, io, home);
    try expectConfValue(allocator, io, data_dir, "port", "51999");
}

test "prepareConf never retunes a data dir adopted from Divi Desktop" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-divi-conf-adopted";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    const data_dir = try Divi.dataDir(allocator, home);
    defer allocator.free(data_dir);

    // A Divi Desktop ~/.divi: a synced chain, and a conf that sets neither port
    // because both are already upstream's defaults.
    {
        var d = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
        defer d.close(io);
        try d.writeFile(io, .{ .sub_path = Divi.conf_file, .data = "# Divi Desktop\nstaking=1\nmaxconnections=64\n" });
        try d.createDirPath(io, "blocks");
    }

    try Divi.prepareConf(allocator, io, home);

    // The P2P port is untouched, so a forwarded 51472 and their peers survive.
    try std.testing.expect((try conf.readValue(allocator, io, data_dir, Divi.conf_file, "port")) == null);
    // RPC stays where Divi Desktop and any external tool expect it, and that's
    // also what `readAuth` resolves — so we talk to the port divid really bound.
    try expectConfValue(allocator, io, data_dir, "rpcport", "51473");
    {
        const auth = try conf.readAuth(allocator, io, data_dir, Divi.conf_file, Divi.rpc_default_username, Divi.rpc_default_port);
        defer conf.freeAuth(allocator, auth);
        try std.testing.expectEqualStrings("51473", auth.port);
    }
    // Their own settings are still there, verbatim.
    try expectConfValue(allocator, io, data_dir, "staking", "1");
    try expectConfValue(allocator, io, data_dir, "maxconnections", "64");
}

test "an existing BoxWallet Divi install keeps the port it was set up on" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-divi-conf-legacy";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    const data_dir = try Divi.dataDir(allocator, home);
    defer allocator.free(data_dir);

    // What every BoxWallet-managed divi.conf looks like today: `populate` wrote
    // an explicit rpcport=51473. Moving a synced node's RPC port out from under
    // it on upgrade would be a regression, so this must stay put.
    {
        var d = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
        defer d.close(io);
        try d.writeFile(io, .{
            .sub_path = Divi.conf_file,
            .data = "rpcuser=divirpc\nrpcpassword=oldsecret\nserver=1\nrpcport=51473\n",
        });
        try d.createDirPath(io, "blocks");
    }

    try Divi.prepareConf(allocator, io, home);
    try expectConfValue(allocator, io, data_dir, "rpcport", "51473");
    try expectConfValue(allocator, io, data_dir, "rpcpassword", "oldsecret");
}

/// Assert `key` in the Divi conf under `data_dir` reads back as `want`.
fn expectConfValue(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    key: []const u8,
    want: []const u8,
) !void {
    const got = (try conf.readValue(allocator, io, data_dir, Divi.conf_file, key)) orelse {
        std.debug.print("conf has no `{s}` (expected {s})\n", .{ key, want });
        return error.TestExpectedEqual;
    };
    defer allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "walletRestoreFileOffline swaps a backup in and keeps the old wallet aside" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const home = "test-divi-restore-home";
    cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, home) catch {};

    const data_dir = try Divi.dataDir(allocator, home);
    defer allocator.free(data_dir);
    var dd = try cwd.createDirPathOpen(io, data_dir, .{});
    defer dd.close(io);

    // Divi keeps its wallet at the top of the data dir — no `wallets/` subdir.
    try dd.writeFile(io, .{ .sub_path = "wallet.dat", .data = "OLD-DIVI-WALLET" });
    var hd = try cwd.createDirPathOpen(io, home, .{});
    defer hd.close(io);
    try hd.writeFile(io, .{ .sub_path = "backup.dat", .data = "NEW-DIVI-WALLET" });
    const src = try std.fs.path.join(allocator, &.{ home, "backup.dat" });
    defer allocator.free(src);

    try Divi.walletRestoreFileOffline(allocator, home, src);

    const got = try dd.readFileAlloc(io, "wallet.dat", allocator, .limited(64));
    defer allocator.free(got);
    try std.testing.expectEqualStrings("NEW-DIVI-WALLET", got);

    // The wallet that was there is recoverable, not destroyed.
    var idir = try cwd.openDir(io, data_dir, .{ .iterate = true });
    defer idir.close(io);
    var it = idir.iterate();
    var found_bak = false;
    while (try it.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "wallet.dat.bak-")) {
            const old = try dd.readFileAlloc(io, entry.name, allocator, .limited(64));
            defer allocator.free(old);
            try std.testing.expectEqualStrings("OLD-DIVI-WALLET", old);
            found_bak = true;
        }
    }
    try std.testing.expect(found_bak);
}

test "walletRestoreFileOffline refuses a key dump before touching the wallet" {
    // divid has no importwallet, so a key dump is never the right file here —
    // and copied over wallet.dat it leaves a daemon that can't open its wallet.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const home = "test-divi-restore-dump";
    cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, home) catch {};

    const data_dir = try Divi.dataDir(allocator, home);
    defer allocator.free(data_dir);
    var dd = try cwd.createDirPathOpen(io, data_dir, .{});
    defer dd.close(io);
    try dd.writeFile(io, .{ .sub_path = "wallet.dat", .data = "OLD-DIVI-WALLET" });

    var hd = try cwd.createDirPathOpen(io, home, .{});
    defer hd.close(io);
    try hd.writeFile(io, .{
        .sub_path = "dump.txt",
        .data = "# Wallet dump created by Divi v3.0.0\n# * Created on 2026-09-03T00:00:00Z\n",
    });
    const src = try std.fs.path.join(allocator, &.{ home, "dump.txt" });
    defer allocator.free(src);

    try std.testing.expectError(error.IsAWalletKeyDump, Divi.walletRestoreFileOffline(allocator, home, src));

    // The wallet that was there is untouched — the refusal came first.
    const got = try dd.readFileAlloc(io, "wallet.dat", allocator, .limited(64));
    defer allocator.free(got);
    try std.testing.expectEqualStrings("OLD-DIVI-WALLET", got);
}

test "a bad seed is refused before the daemon or the wallet is touched" {
    // The phrase is checked here, so a typo costs a message rather than a
    // minute-long daemon start — and, critically, divid never runs, so the real
    // wallet is never moved aside. (divid moves wallet.dat *before* it validates
    // the mnemonic, which is why this check has to come first.)
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const home = "test-divi-seed-bad";
    cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, home) catch {};

    const data_dir = try Divi.dataDir(allocator, home);
    defer allocator.free(data_dir);
    var dd = try cwd.createDirPathOpen(io, data_dir, .{});
    defer dd.close(io);
    try dd.writeFile(io, .{ .sub_path = "wallet.dat", .data = "OLD-DIVI-WALLET" });

    // An install root with no divid in it: if any of these got as far as
    // spawning, the failure would be a spawn error rather than the seed reason.
    const root = "test-divi-seed-bad-root";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    const cases = [_]struct { seed: []const u8, expect: []const u8 }{
        // Right words, wrong length.
        .{
            .seed = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
            .expect = "BIP39 seed length",
        },
        // A word that isn't in the list.
        .{
            .seed = "abandonn abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
            .expect = "BIP39 wordlist",
        },
        // Real words, right length, broken checksum — the transposition case.
        .{
            .seed = "legal winner thank year wave sausage worth useful legal winner yellow thank",
            .expect = "checksum",
        },
    };
    for (cases) |c| {
        var detail: Coin.WalletErrSink = .{};
        try std.testing.expectError(
            error.InvalidSeed,
            Divi.walletRestoreSeed(allocator, root, home, c.seed, "", "", &detail),
        );
        // The message names the mistake rather than saying "failed".
        try std.testing.expect(std.mem.indexOf(u8, detail.slice(), c.expect) != null);
    }

    // The wallet is exactly as it was — nothing was moved, renamed or replaced.
    const got = try dd.readFileAlloc(io, "wallet.dat", allocator, .limited(64));
    defer allocator.free(got);
    try std.testing.expectEqualStrings("OLD-DIVI-WALLET", got);
}

test "the seed restore normalizes case and spacing before judging the phrase" {
    // A phrase pasted out of a password manager arrives with capitals and double
    // spaces; it must still be recognised as valid (this one is), not rejected as
    // an unknown word. It gets as far as needing divid, which isn't there — so
    // the telling part is that it does NOT come back as InvalidSeed.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const home = "test-divi-seed-norm";
    const root = "test-divi-seed-norm-root";
    cwd.deleteTree(io, home) catch {};
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, root) catch {};

    var detail: Coin.WalletErrSink = .{};
    const messy = "  Legal   WINNER thank year wave sausage\tworth useful legal winner thank Yellow  ";
    const err = Divi.walletRestoreSeed(allocator, root, home, messy, "", "", &detail);
    try std.testing.expectError(error.WalletRestoreFailed, err);
    // Specifically not the seed-validation rejection.
    try std.testing.expect(std.mem.indexOf(u8, detail.slice(), "wordlist") == null);
    try std.testing.expect(std.mem.indexOf(u8, detail.slice(), "checksum") == null);
}

test "a hex seed is taken as a seed, and refuses a passphrase it cannot apply" {
    // The hex form is the value a mnemonic *derives to*, so a passphrase
    // alongside it can't be honoured. Dropping it silently would restore a
    // different wallet than the user asked for, so it's refused instead.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const home = "test-divi-hex-home";
    const root = "test-divi-hex-root";
    cwd.deleteTree(io, home) catch {};
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, root) catch {};

    // The real hdseed for "legal winner…yellow", as dumphdinfo reports it.
    const hex = "878386efb78845b3355bd15ea4d39ef97d179cb712b77d5c12b6be415fffeffe5f377ba02bf3f8544ab800b955e51fbff09828f682052a20faa6addbbddfb096";

    var detail: Coin.WalletErrSink = .{};
    try std.testing.expectError(
        error.InvalidSeed,
        Divi.walletRestoreSeed(allocator, root, home, hex, "TREZOR", "", &detail),
    );
    try std.testing.expect(std.mem.indexOf(u8, detail.slice(), "passphrase") != null);

    // Without a passphrase the same hex is accepted as a seed — it gets past
    // validation and fails only for want of a divid to run, which is the point:
    // it must NOT come back as InvalidSeed the way a bad phrase does.
    detail = .{};
    try std.testing.expectError(
        error.WalletRestoreFailed,
        Divi.walletRestoreSeed(allocator, root, home, hex, "", "", &detail),
    );

    // And it is never put through the word checks — those would reject it.
    try std.testing.expect(std.mem.indexOf(u8, detail.slice(), "wordlist") == null);
    try std.testing.expect(std.mem.indexOf(u8, detail.slice(), "checksum") == null);
    try std.testing.expect(std.mem.indexOf(u8, detail.slice(), "seed length") == null);
}

test "a passphrase is accepted alongside words" {
    // The passphrase is not validated here (only the user knows it); what matters
    // is that supplying one doesn't make a good phrase look bad.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const home = "test-divi-pp-home";
    const root = "test-divi-pp-root";
    cwd.deleteTree(io, home) catch {};
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, root) catch {};

    var detail: Coin.WalletErrSink = .{};
    const words = "legal winner thank year wave sausage worth useful legal winner thank yellow";
    try std.testing.expectError(
        error.WalletRestoreFailed,
        Divi.walletRestoreSeed(allocator, root, home, words, "TREZOR", "", &detail),
    );
    try std.testing.expect(std.mem.indexOf(u8, detail.slice(), "checksum") == null);
    try std.testing.expect(std.mem.indexOf(u8, detail.slice(), "wordlist") == null);
}

test "jsonStringField reads the field asked for, not one that merely contains it" {
    // The reason this exists: substring-matching a dumphdinfo body would let
    // "mnemonic" match inside "mnemonicpassphrase", and would let a passphrase
    // that happens to occur inside the mnemonic pass a comparison it should fail.
    const body =
        \\{
        \\    "hdseed" : "abcd1234",
        \\    "mnemonic" : "legal winner thank",
        \\    "mnemonicpassphrase" : "TREZOR"
        \\}
    ;
    try std.testing.expectEqualStrings("abcd1234", Divi.jsonStringField(body, "hdseed").?);
    try std.testing.expectEqualStrings("legal winner thank", Divi.jsonStringField(body, "mnemonic").?);
    try std.testing.expectEqualStrings("TREZOR", Divi.jsonStringField(body, "mnemonicpassphrase").?);
    try std.testing.expect(Divi.jsonStringField(body, "nosuch") == null);

    // An empty passphrase (the common case) reads as empty, not as absent.
    const empty =
        \\{"mnemonic" : "a b c", "mnemonicpassphrase" : ""}
    ;
    try std.testing.expectEqualStrings("", Divi.jsonStringField(empty, "mnemonicpassphrase").?);
}

test "a passphrase a conf line can't carry is refused, not mangled" {
    // divid reads the passphrase from a `key=value` conf line. A newline injects a
    // line; surrounding spaces are eaten by the parser. Either would restore a
    // different wallet than asked for, so both are refused up front — quietly
    // restoring the wrong wallet is the failure mode with no recovery.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const home = "test-divi-ppbad-home";
    const root = "test-divi-ppbad-root";
    cwd.deleteTree(io, home) catch {};
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, root) catch {};

    const words = "legal winner thank year wave sausage worth useful legal winner thank yellow";
    const cases = [_]struct { pp: []const u8, expect: []const u8 }{
        .{ .pp = "bad\nrpcpassword=hunter2", .expect = "line break" },
        .{ .pp = "trailing ", .expect = "space" },
        .{ .pp = " leading", .expect = "space" },
    };
    for (cases) |c| {
        var detail: Coin.WalletErrSink = .{};
        try std.testing.expectError(
            error.InvalidSeed,
            Divi.walletRestoreSeed(allocator, root, home, words, c.pp, "", &detail),
        );
        try std.testing.expect(std.mem.indexOf(u8, detail.slice(), c.expect) != null);
    }

    // An ordinary passphrase with an interior space is fine — only the edges and
    // line breaks are a problem.
    var ok_detail: Coin.WalletErrSink = .{};
    try std.testing.expectError(
        error.WalletRestoreFailed, // gets past validation; no divid to run
        Divi.walletRestoreSeed(allocator, root, home, words, "correct horse battery", "", &ok_detail),
    );
}
