const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const install_mod = @import("../install.zig");
const conf = @import("../conf.zig");
const rpc = @import("../rpc.zig");
const Coin = @import("../coin.zig").Coin;

/// Monero (XMR) backend — the original CryptoNote privacy coin the Nerva/Salvium
/// backends are forks of, so it follows their external-wallet shape (a separate
/// `monero-wallet-rpc` process) rather than the bitcoin-core coins.
///
/// Three things set Monero apart from the bitcoin-core coins:
///
///   * **Distribution** — binaries are hosted by the project itself
///     (`downloads.getmonero.org`), *not* GitHub releases: the
///     `monero-project/monero` release carries no assets at all, only the notes
///     and checksums. Linux/macOS bundles ship as `.tar.bz2` (Zig's stdlib has no
///     bzip2, so the install path uses BoxWallet's own pure-Zig decoder — see
///     `bzip2.zig`); Windows ships a `.zip`. Every bundle wraps its binaries in a
///     versioned dir (no `bin/` subdir); the daemon/CLI/wallet-rpc are promoted
///     out and the rest dropped.
///   * **Archive dir ≠ asset name** — unlike Nerva, whose wrapper dir *is* its
///     asset stem, Monero's download name and its wrapper dir use different arch
///     spellings: `monero-linux-x64-v0.18.5.1.tar.bz2` unpacks to
///     `monero-x86_64-linux-gnu-v0.18.5.1/`. So `Bundle` carries the two
///     separately — deriving one from the other would break the promote step
///     (verified against the real archives for every target below).
///   * **RPC** — Monero's daemon RPC, not the bitcoin JSON-RPC. `get_info` is a
///     `POST /json_rpc` method returning a flat result; sync is derived from
///     `height` vs `target_height` (0 once caught up) and the `synchronized` flag,
///     and the peer count from the connection counts. Shutdown is the direct
///     `POST /stop_daemon` endpoint. The daemon is unauthenticated by default, so
///     no basic auth is sent (mirrors Ergo's keyless REST).
pub const Monero = struct {
    /// Whether the coin is exposed in the nav. False keeps it out of the left
    /// bar entirely (registered but hidden) until it's ready for users.
    pub const live = true;
    pub const coin_name = "Monero";
    pub const coin_name_abbrev = "XMR";
    /// One-line description shown under the coin name on the detail pane.
    pub const coin_description = "The leading private, untraceable CryptoNote currency.";
    /// Monero brand colour (`#RRGGBB`), for tinting the coin in the frontend —
    /// the orange from Monero's official brand guide.
    pub const coin_color = "#FF6600";
    /// Donation address for BoxWallet development, in Monero's own currency.
    /// TODO(richard): replace with the real XMR tip address. Left as a marker
    /// rather than a guessed address — a wrong one would send tips into the void.
    pub const tip_address = "86fcmcNhhWeCx3jf8TbC2cWDLRY2DYJr9E6Z5Zq9wyaHhEDsa4ETzQ42Bnm4Hio1HmH6bmbT4KWtZNp7vUwZn7LANdMSbfz";
    /// Monero is proof-of-work (RandomX) — no wallet staking.
    pub const proof_of_stake = false;

    /// monerod's config file. Monero's on-disk identity is still its original
    /// name — `CRYPTONOTE_NAME` is `"bitmonero"`, not `"monero"` — and the daemon
    /// derives its conf (`<data-dir>/bitmonero.conf`), log, and data dir from it,
    /// so all three carry that name rather than the coin's.
    pub const conf_file = "bitmonero.conf";

    // Data dir names. Monero uses `~/.bitmonero` on Linux *and* macOS (not the
    // macOS Library convention) and `%APPDATA%\bitmonero` on Windows — exactly
    // what the shared `conf.dataDir(posix, win)` produces.
    pub const home_dir = ".bitmonero";
    pub const home_dir_win = "bitmonero";
    /// macOS data dir name. `null` means macOS uses the **POSIX** path
    /// (`~/.bitmonero`) rather than a `Library/Application Support`
    /// dir — Monero and its forks are explicit that it's "Unix & Mac:
    /// ~/.CRYPTONOTE_NAME", unlike the bitcoin-derived coins. Not an oversight:
    /// pointing this at a Library dir would orphan an existing wallet on macOS.
    pub const home_dir_mac: ?[]const u8 = null;

    /// Unauthenticated by default; a value is kept only so the shared conf/readAuth
    /// path has a username to write (the daemon ignores it).
    pub const rpc_default_username = "monerorpc";
    /// `RPC_DEFAULT_PORT` from `cryptonote_config.h`.
    pub const rpc_default_port = "18081";
    pub const core_version = "0.18.5.1";

    // Binary names. Windows appends `.exe`. The wallet CLI is `monero-wallet-cli`;
    // `monero-wallet-rpc` drives the (external) wallet — BoxWallet launches it
    // alongside the daemon for create/restore/balance (see the external-wallet
    // section below), so it's promoted too. The bundle also ships the
    // `monero-blockchain-*` tools, which BoxWallet doesn't use and drops.
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    pub const daemon_file = "monerod" ++ exe_suffix;
    pub const cli_file = "monero-wallet-cli" ++ exe_suffix;
    pub const wallet_rpc_file = "monero-wallet-rpc" ++ exe_suffix;

    /// Port BoxWallet binds the managed `monero-wallet-rpc` to (localhost only).
    /// Must avoid monerod's reserved ports: P2P 18080, RPC 18081, and — easy to
    /// miss — the **ZMQ-RPC** server at 18082 (`ZMQ_RPC_DEFAULT_PORT`, bound by
    /// default). Colliding there makes *monerod* itself fail to start ("ZMQ RPC
    /// Server bind failed: Address already in use") and die, so the wallet port is
    /// moved well clear of the block.
    pub const wallet_rpc_port = "18085";

    /// The single managed wallet's filename, inside the wallet dir. Fixed so
    /// `walletExists` is a pure disk check and every wallet-RPC call targets the
    /// same file by name.
    const wallet_name = "BoxWallet";

    /// Monero's atomic unit (`CRYPTONOTE_DISPLAY_DECIMAL_POINT = 12`, verified
    /// against monero-project/monero `cryptonote_config.h`): the wallet RPC reports
    /// balances as integer atomic units, so divide by this to get whole XMR.
    const atomic_per_xmr: f64 = 1_000_000_000_000;

    /// A Monero deterministic restore seed is exactly 25 words.
    pub const seed_word_count = 25;

    /// Monero self-hosts its binaries; the GitHub release carries no assets.
    const release_base = "https://downloads.getmonero.org/cli/";

    // The per-target bundle: the download's asset stem, the versioned wrapper dir
    // it unpacks to, and its format. The two names use *different* arch spellings
    // (see the type doc), so both are stated per target rather than derived — each
    // was read back off the real published archive. Linux/macOS ship `.tar.bz2`;
    // Windows ships `.zip`.
    const Bundle = struct { asset: []const u8, dir: []const u8, format: install_mod.Format };

    /// The bundle Monero publishes for `os`/`arch`, or null where it publishes
    /// none. Taken as parameters rather than read from `builtin` directly so the
    /// whole matrix is checkable from a single native test run — otherwise a test
    /// could only ever assert about the target it happens to be compiled for, and
    /// would pass vacuously on the ones it can't see.
    fn bundleFor(os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) ?Bundle {
        return switch (os) {
            .linux => switch (arch) {
                .x86_64 => .{
                    .asset = "monero-linux-x64-v" ++ core_version,
                    .dir = "monero-x86_64-linux-gnu-v" ++ core_version,
                    .format = .tar_bz2,
                },
                .aarch64 => .{
                    .asset = "monero-linux-armv8-v" ++ core_version,
                    .dir = "monero-aarch64-linux-gnu-v" ++ core_version,
                    .format = .tar_bz2,
                },
                .arm => .{
                    .asset = "monero-linux-armv7-v" ++ core_version,
                    .dir = "monero-arm-linux-gnueabihf-v" ++ core_version,
                    .format = .tar_bz2,
                },
                .x86 => .{
                    .asset = "monero-linux-x86-v" ++ core_version,
                    .dir = "monero-i686-linux-gnu-v" ++ core_version,
                    .format = .tar_bz2,
                },
                else => null,
            },
            .macos => switch (arch) {
                .x86_64 => .{
                    .asset = "monero-mac-x64-v" ++ core_version,
                    .dir = "monero-x86_64-apple-darwin11-v" ++ core_version,
                    .format = .tar_bz2,
                },
                .aarch64 => .{
                    .asset = "monero-mac-armv8-v" ++ core_version,
                    .dir = "monero-aarch64-apple-darwin11-v" ++ core_version,
                    .format = .tar_bz2,
                },
                else => null,
            },
            .windows => switch (arch) {
                .x86_64 => .{
                    .asset = "monero-win-x64-v" ++ core_version,
                    .dir = "monero-x86_64-w64-mingw32-v" ++ core_version,
                    .format = .zip,
                },
                .x86 => .{
                    .asset = "monero-win-x86-v" ++ core_version,
                    .dir = "monero-i686-w64-mingw32-v" ++ core_version,
                    .format = .zip,
                },
                else => null,
            },
            // Windows, macOS, Linux only — BoxWallet's platforms. Monero also
            // publishes FreeBSD/Android/riscv64 bundles; they're deliberately not
            // mapped, so they resolve `error.UnsupportedPlatform` at install time.
            else => null,
        };
    }

    /// The bundle for *this* build target.
    const bundle: ?Bundle = bundleFor(builtin.os.tag, builtin.cpu.arch);

    /// The download URL + format for the build target, or null where Monero
    /// publishes no matching binary (e.g. ARM Windows).
    const download: ?install_mod.Download = if (bundle) |b| .{
        .url = release_base ++ b.asset ++ (if (b.format == .zip) ".zip" else ".tar.bz2"),
        .format = b.format,
    } else null;

    // The versioned wrapper dir the bundle extracts to. Binaries sit directly
    // inside it, so `bin_subdir` is empty. "" when this target has no bundle
    // (download is null and install bails before using it).
    const extracted_dir = if (bundle) |b| b.dir else "";
    const bin_subdir = "";
    const promote_files = [_][]const u8{ daemon_file, cli_file, wallet_rpc_file };

    // Scratch file the bundle streams to (unique to Monero). For `.tar.bz2` the
    // installer derives a sibling `.tar` from this name during decompression.
    pub const scratch_file = ".boxwallet-monero.part";

    /// Build the type-erased `Coin` handle for this instance.
    pub fn coin(self: *Monero) Coin {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // --- RPC (Monero daemon) ---------------------------------------------

    /// Subset of `get_info`'s result. Monero reports a flat object; `synchronized`
    /// is authoritative for sync state, with `height`/`target_height` as the
    /// fallback (`target_height` is 0 once caught up). Defaults keep the parse
    /// resilient to omitted fields.
    const MoneroInfo = struct {
        status: []const u8 = "",
        height: i64 = 0,
        target_height: i64 = 0,
        outgoing_connections_count: i64 = 0,
        incoming_connections_count: i64 = 0,
        synchronized: bool = false,
        mainnet: bool = false,
        testnet: bool = false,
        stagenet: bool = false,
        /// The daemon's own version, e.g. "0.18.5.1-release". Unlike the Nerva /
        /// Salvium forks, upstream Monero's `get_info` does report this, so the
        /// version marker can come straight off the RPC.
        version: []const u8 = "",
    };

    /// Bound (ms) on a status/stop RPC round-trip. A healthy monerod answers
    /// `get_info` in milliseconds; this cap exists so a wedged or over-busy daemon
    /// — one whose RPC thread is starved under load, so it accepts the connection
    /// but never replies — can't hang the poll worker (and, through it, the app's
    /// quit) forever.
    const status_timeout_ms: u32 = 8000;

    /// Bound (ms) on a wallet-RPC op. A Monero wallet open/create/restore drives an
    /// initial refresh that can legitimately take many seconds, so these get a far
    /// longer cap than the status path — still bounded so a hung wallet service
    /// can't wedge the worker.
    const wallet_timeout_ms: u32 = 60_000;

    /// Budget (ms) to wait for `monero-wallet-rpc` to become ready — i.e. answer an
    /// authenticated request — before the first wallet op. The service is spawned
    /// detached (see `app.zig`'s `ensureWalletRpc`) and returns immediately, so a
    /// create/restore/open fired straight after can race its startup and get a
    /// spurious `AuthFailed`. Gating on `rpc.moneroWalletReady` closes that window.
    const wallet_ready_timeout_ms: u32 = 25_000;

    /// Fetch + parse `get_info`. Caller must `deinit` the returned `Parsed`.
    fn fetchInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !std.json.Parsed(models.JsonRpcResponse(MoneroInfo)) {
        const raw = try rpc.moneroPost(allocator, auth, "/json_rpc", "{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"get_info\"}", status_timeout_ms);
        defer allocator.free(raw);
        return std.json.parseFromSlice(
            models.JsonRpcResponse(MoneroInfo),
            allocator,
            raw,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
    }

    /// Monero's block-target interval (seconds): `DIFFICULTY_TARGET_V2 = 120` in
    /// `cryptonote_config.h`. Used only to turn the block gap into a "behind by"
    /// estimate; the daemon never reports a tip timestamp we could use directly.
    const block_target_seconds: i64 = 120;

    /// Estimate how many seconds the local tip is behind the chain from the block
    /// gap. Monero's `get_info` carries no tip timestamp, and
    /// `get_last_block_header` returns `BUSY` mid-sync — exactly when the
    /// "behind by …" hint matters — so we approximate: each block still to fetch
    /// (`tip − height`) is about one block-target of chain time. Returns 0 when
    /// caught up, so the frontend shows no hint. Pure, so it's unit-testable; the
    /// frontend uses it directly (`BlockchainState.seconds_behind`) since the coin
    /// has no clock to synthesise a `tip_time`.
    fn estimateSecondsBehind(tip: i64, height: i64, synced: bool) i64 {
        const behind_blocks = @max(tip - height, 0);
        if (synced or behind_blocks == 0) return 0;
        return behind_blocks * block_target_seconds;
    }

    /// Live `get_info`, normalized for a frontend. Monero has no
    /// `verificationprogress`; sync is the `synchronized` flag, or `height`
    /// reaching the network `target_height` (which is 0 once caught up).
    pub fn blockchainState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.BlockchainState {
        var parsed = try fetchInfo(allocator, auth);
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        const tip = @max(r.target_height, r.height);
        const chain = if (r.testnet) "testnet" else if (r.stagenet) "stagenet" else "mainnet";
        const synced = r.synchronized or (r.height > 0 and (r.target_height == 0 or r.height >= r.target_height));
        return .{
            .chain = try allocator.dupe(u8, chain),
            .blocks = r.height,
            .headers = tip,
            .verification_progress = if (tip > 0)
                @as(f64, @floatFromInt(r.height)) / @as(f64, @floatFromInt(tip))
            else
                0,
            .synced = synced,
            .network_height = tip,
            // Monero gives no tip timestamp, so report how far behind the tip is
            // from the block gap — drives the shared "behind by …" sync readout.
            .seconds_behind = estimateSecondsBehind(tip, r.height, synced),
        };
    }

    /// Live `get_info`, normalized for a frontend. The peer count is the daemon's
    /// total connections; Monero is proof-of-work, so `staking_active` is false.
    pub fn daemonInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.DaemonInfo {
        var parsed = try fetchInfo(allocator, auth);
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return .{
            .blocks = r.height,
            .connections = r.outgoing_connections_count + r.incoming_connections_count,
            .staking_active = false,
            // Freshly formatted on `allocator`, so it outlives `parsed`'s deinit. The
            // build suffix is dropped so "0.18.5.1-release" lines up with the pinned
            // `core_version` ("0.18.5.1") rather than reading as a mismatch.
            .version = try allocator.dupe(u8, models.trimBuildSuffix(r.version)),
        };
    }

    /// Ask monerod to shut down via Monero's direct `POST /stop_daemon` (not a
    /// `/json_rpc` method).
    pub fn requestStop(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        const reply = try rpc.moneroPost(allocator, auth, "/stop_daemon", "{}", status_timeout_ms);
        allocator.free(reply);
    }

    // --- Files / paths ---------------------------------------------------

    /// The daemon's default data directory (`~/.bitmonero`, `%APPDATA%\bitmonero`
    /// on Windows), where `bitmonero.conf` and the chain live.
    pub fn dataDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        return conf.dataDir(allocator, home, home_dir, home_dir_win, home_dir_mac);
    }

    /// True if `monerod` (`monerod.exe` on Windows) is already present under
    /// `install_root`.
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, daemon_file);
    }

    /// Ask the installed `monerod` its version by running `monerod --version`, whose
    /// banner reads:
    ///
    ///     Monero 'Fluorine Fermi' (v0.18.5.1-release)
    ///
    /// Monero's `get_info` *does* carry a `version`, so unlike Nerva/Salvium the RPC
    /// can stamp the marker on its own. The probe is wired anyway because it also
    /// answers with the **daemon stopped** — and with its RPC wedged behind the
    /// blockchain lock mid-sync — which is exactly when a user most wants to know an
    /// update is waiting.
    ///
    /// Caller owns the returned version string.
    fn probeInstalledVersion(allocator: std.mem.Allocator, install_root: []const u8) anyerror![]const u8 {
        return install_mod.probeBinaryVersion(allocator, install_root, daemon_file, ".monerod.probe");
    }

    /// Download + unpack the Monero daemon files into `install_root`.
    ///
    /// Streams the bundle to disk (a `.tar.bz2` via the pure-Zig bzip2 decoder, or
    /// a `.zip`), then `promoteAndTidy` lifts `monerod`/`monero-wallet-cli`/
    /// `monero-wallet-rpc` out of the versioned wrapper (binaries are directly
    /// inside it, so `bin_subdir` is empty) and removes the wrapper — which is also
    /// what discards the `monero-blockchain-*` tools BoxWallet doesn't use.
    pub fn install(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        const dl = download orelse return error.UnsupportedPlatform;
        try install_mod.downloadAndExtract(allocator, dl.url, dl.format, install_root, scratch_file, 0, progress);
        try install_mod.promoteAndTidy(allocator, install_root, extracted_dir, bin_subdir, &promote_files);
        cleanupAppleDouble(allocator, install_root);
    }

    /// Remove the `._<wrapper>` AppleDouble sibling a macOS-built tarball can carry
    /// at the archive root (the matching ones inside the wrapper go with it when
    /// `promoteAndTidy` drops the tree). Best-effort; no-op on the Windows zip,
    /// which has no such files.
    fn cleanupAppleDouble(allocator: std.mem.Allocator, install_root: []const u8) void {
        if (builtin.os.tag == .windows) return;
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var dir = std.Io.Dir.cwd().openDir(io, install_root, .{}) catch return;
        defer dir.close(io);
        dir.deleteFile(io, "._" ++ extracted_dir) catch {};
    }

    /// The canonical `bitmonero.conf` body. monerod parses this on startup (its
    /// `--config-file` defaults to `<data-dir>/bitmonero.conf`), so it must contain
    /// only Monero-style options. `rpc-bind-port` is the default RPC port stated
    /// explicitly so it's self-documenting and survives any upstream default change.
    const conf_body = "rpc-bind-port=" ++ rpc_default_port ++ "\n";

    /// Ensure the data dir and `bitmonero.conf` exist so the status poll's `readAuth`
    /// (which needs the conf present) succeeds.
    ///
    /// Unlike the bitcoin coins, monerod *reads* this file on every startup, and the
    /// shared `conf.populate` writes bitcoin keys (`rpcuser`, `server`, …) that
    /// Monero's parser rejects outright (`unrecognised option 'rpcuser'`) — monerod
    /// would exit before its RPC came up, which reads as an unstoppable daemon. So
    /// the canonical Monero conf is written instead of populated.
    ///
    /// **An existing conf is never touched.** Nerva and Salvium clobber theirs on the
    /// reasoning that BoxWallet owns the file, which holds for a coin nobody else is
    /// likely to be running. It does not hold for Monero: `~/.bitmonero` is the
    /// standard data dir on Linux *and* macOS, so this conf very plausibly belongs to
    /// an existing node and carries settings that matter (`prune-blockchain`,
    /// `out-peers`, Tor/i2p, a custom `rpc-bind-port`). Overwriting it would break
    /// someone else's node to configure ours — and BoxWallet shares what's already
    /// there rather than reshaping it. We only write the conf when there isn't one,
    /// which is exactly the case where the dir is ours anyway.
    ///
    /// Deferring to their conf is safe for the poll/stop path: the only key we'd have
    /// written is `rpc-bind-port`, and `readAuth` doesn't recognise that key — it
    /// falls back to `rpc_default_port` regardless. If their node moved the RPC port,
    /// BoxWallet simply can't reach it and reports the daemon as unreachable, rather
    /// than silently rewriting their config to suit itself.
    pub fn prepareConf(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        if (conf.dataDirHasEntry(allocator, data_dir, conf_file)) return;
        try conf.writeConf(io, data_dir, conf_file, conf_body);
    }

    // --- pruning capability ----------------------------------------------
    //
    // Monero's chain is very large (hundreds of GB), so on the *first* daemon start
    // the user is asked how to store it; the answer is written to `bitmonero.conf`
    // as `prune-blockchain=1`/`0` and read back for the Settings tab.
    //
    // Unlike the bitcoin-derived coins there is no size to choose: monerod's
    // pruning is all-or-nothing — it drops ~7/8 of the ring-signature data,
    // leaving roughly a third of the chain — so the capability runs in `.on_off`
    // mode with a two-row menu and no custom amount.

    pub const pruning_caps: Coin.Pruning = .{
        .mode = .on_off,
        .presets = &prune_presets,
        .prompt = "How should the blockchain be stored? The full chain is 250+ GB; pruning keeps about a third of it and still validates every block.",
        .should_offer = pruneShouldOffer,
        .apply = pruneApply,
        .current = pruneCurrent,
    };

    /// The two ways monerod can store the chain. Full node first, so the cursor
    /// starts on the choice that discards nothing. Labels are kept short enough to
    /// fit a menu row of the modal (the box pads but never truncates) — `app.zig`
    /// has a test over every coin's labels that pins this.
    const prune_presets = [_]Coin.PrunePreset{
        .{ .label = "Keep the full blockchain (250+ GB)", .value = 0 },
        .{ .label = "Prune the blockchain (~1/3 the disk)", .value = 1 },
    };

    /// The conf key monerod takes the choice from.
    const prune_key = "prune-blockchain";

    /// The directory monerod keeps its LMDB blockchain in. Its presence means a
    /// chain already lives in the data dir — see `pruneShouldOffer`.
    const chain_dir = "lmdb";

    /// Offer the prune prompt only when the conf carries no `prune-blockchain`
    /// setting yet — so it's asked exactly once, and a conf the user already
    /// configured is respected — **and** only when the data dir holds no chain yet.
    ///
    /// That second condition is what stops BoxWallet touching someone else's node.
    /// `~/.bitmonero` is the standard data dir on Linux *and* macOS, so it may well
    /// belong to an existing monerod with a chain that took days to sync. A node
    /// that was never pruned carries no `prune-blockchain` key *by definition* — you
    /// only add one to opt in — so the conf check alone reads a full node as "never
    /// asked" and offers to prune it. An `lmdb/` dir means someone was here first,
    /// so the prompt is withheld and their node is left exactly as it was.
    ///
    /// Withholding it also matches what monerod can actually do: `--prune-blockchain`
    /// only prunes while syncing from scratch, and pruning an existing chain is a
    /// separate, irreversible `monero-blockchain-prune` run we never perform.
    ///
    /// This never suppresses the legitimate prompt: it's evaluated *before the
    /// daemon's first start* (see `app.zig`'s start preflight), so a data dir
    /// BoxWallet is setting up fresh has no `lmdb/` yet and is still offered.
    fn pruneShouldOffer(allocator: std.mem.Allocator, home: []const u8) bool {
        const cur = pruneCurrent(allocator, home) catch return false;
        if (cur != null) return false;

        const data_dir = dataDir(allocator, home) catch return false;
        defer allocator.free(data_dir);
        return !conf.dataDirHasEntry(allocator, data_dir, chain_dir);
    }

    /// Persist the choice to `bitmonero.conf` as `prune-blockchain=1`/`0`,
    /// preserving every other line. The "off" answer is written out too, so the
    /// prompt knows it was already asked.
    ///
    /// `prepareConf` runs first: this is the first thing to touch the conf on a
    /// fresh install, and a bare `setValue` would create a file holding only the
    /// prune key — which `prepareConf` would then skip as "already there", losing
    /// the canonical body. Where a conf already exists both calls leave it alone
    /// apart from this one key.
    fn pruneApply(allocator: std.mem.Allocator, home: []const u8, prune_value: i64) anyerror!void {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        try prepareConf(allocator, io, home);

        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        try conf.setValue(allocator, io, data_dir, conf_file, prune_key, if (prune_value != 0) "1" else "0");
    }

    /// The configured prune setting (1 = pruned, 0 = full node, null = unset) for
    /// the Settings tab. monerod's option parser takes `1`/`0` and `true`/`false`,
    /// so both spellings are read back; anything else reads as null rather than
    /// erroring the display.
    fn pruneCurrent(allocator: std.mem.Allocator, home: []const u8) anyerror!?i64 {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        const raw = (try conf.readValue(allocator, io, data_dir, conf_file, prune_key)) orelse return null;
        defer allocator.free(raw);

        const val = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.eql(u8, val, "1") or std.ascii.eqlIgnoreCase(val, "true")) return 1;
        if (std.mem.eql(u8, val, "0") or std.ascii.eqlIgnoreCase(val, "false")) return 0;
        return null;
    }

    /// Monero's daemon runs in the foreground of its own process, so it's spawned
    /// detached (with `--non-interactive`) and the status poll confirms it came up
    /// — never the bitcoin `-daemon` fork path.
    pub fn launchMode() Coin.LaunchMode {
        return .foreground;
    }

    /// The daemon's log file under the data dir, whose tail is read for a
    /// startup-failure reason when the daemon dies without saying why on stderr.
    /// Named for `CRYPTONOTE_NAME`, like the conf and data dir — `bitmonero.log`,
    /// not `monero.log`.
    pub fn daemonLogFile() []const u8 {
        return "bitmonero.log";
    }

    /// `monerod --non-interactive` so it runs as a server rather than opening its
    /// interactive console. Caller owns the returned slice and its strings.
    pub fn daemonArgv(allocator: std.mem.Allocator, install_root: []const u8, _: []const u8) ![]const []const u8 {
        const path = try std.fs.path.join(allocator, &.{ install_root, daemon_file });
        errdefer allocator.free(path);

        const argv = try allocator.alloc([]const u8, 2);
        argv[0] = path;
        argv[1] = try allocator.dupe(u8, "--non-interactive");
        return argv;
    }

    // --- External wallet (Monero wallet-rpc) -----------------------------
    //
    // Monero's wallet lives in a *separate* process (`monero-wallet-rpc`), not the
    // daemon. BoxWallet launches it bound to localhost:`wallet_rpc_port`, locked to
    // per-session credentials (`--rpc-login <user>:<pass>`, HTTP digest auth — the
    // wallet RPC exposes the spend key and `sweep_all`, so localhost alone isn't
    // enough), pointed at the local daemon, and drives create/restore/open/balance
    // over Monero's wallet `POST /json_rpc`. All funds-sensitive: a wallet is only
    // ever created with a user-supplied password, never silently. See `coin.zig`'s
    // `ExternalWallet`.

    /// The managed wallet directory (`<datadir>/wallets`), where `monero-wallet-rpc`
    /// creates and opens `BoxWallet`(+`.keys`). Caller owns the slice.
    fn walletDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        return std.fs.path.join(allocator, &.{ data_dir, "wallets" });
    }

    /// The managed wallet's on-disk location for the Settings tab: the Monero
    /// `<datadir>/wallets/BoxWallet` file plus its `.keys` companion. Caller owns
    /// the returned strings.
    pub fn walletPath(allocator: std.mem.Allocator, home: []const u8) !?Coin.WalletFile {
        const dir = try walletDir(allocator, home);
        defer allocator.free(dir);
        const path = try std.fs.path.join(allocator, &.{ dir, wallet_name });
        errdefer allocator.free(path);
        const keys = try std.fs.path.join(allocator, &.{ dir, wallet_name ++ ".keys" });
        return .{ .path = path, .keys = keys };
    }

    /// Port the wallet process is bound to — its RPC endpoint, distinct from the
    /// daemon's. The lifecycle in `app.zig` builds a `wallet_auth` from this.
    fn walletRpcPort() []const u8 {
        return wallet_rpc_port;
    }

    /// argv to spawn `monero-wallet-rpc`, bound to `port` on localhost and pointed
    /// at the local daemon. `--wallet-dir` lets it create/open wallets by name over
    /// RPC; `--rpc-login <user>:<pass>` locks the wallet RPC to the per-session
    /// credentials BoxWallet generated, so another local process can't drive it
    /// (the wallet RPC exposes the spend key and `sweep_all`). Caller owns the
    /// returned slice and its strings.
    fn walletProcessArgv(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home: []const u8,
        port: []const u8,
        rpc_user: []const u8,
        rpc_password: []const u8,
    ) anyerror![]const []const u8 {
        const path = try std.fs.path.join(allocator, &.{ install_root, wallet_rpc_file });
        errdefer allocator.free(path);
        const dir = try walletDir(allocator, home);
        errdefer allocator.free(dir);
        const daemon_addr = try std.fmt.allocPrint(allocator, "127.0.0.1:{s}", .{rpc_default_port});
        errdefer allocator.free(daemon_addr);
        const login = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ rpc_user, rpc_password });
        errdefer allocator.free(login);

        const argv = try allocator.alloc([]const u8, 11);
        errdefer allocator.free(argv);
        argv[0] = path;
        argv[1] = try allocator.dupe(u8, "--wallet-dir");
        argv[2] = dir;
        argv[3] = try allocator.dupe(u8, "--rpc-bind-ip");
        argv[4] = try allocator.dupe(u8, "127.0.0.1");
        argv[5] = try allocator.dupe(u8, "--rpc-bind-port");
        argv[6] = try allocator.dupe(u8, port);
        argv[7] = try allocator.dupe(u8, "--daemon-address");
        argv[8] = daemon_addr;
        argv[9] = try allocator.dupe(u8, "--rpc-login");
        argv[10] = login;
        return argv;
    }

    /// True if the managed `BoxWallet` already exists on disk (its `.keys` file is
    /// the authoritative marker — the cache rebuilds from the daemon). A pure disk
    /// check, so the UI can decide "set up" vs "open" without a running process.
    fn walletExists(allocator: std.mem.Allocator, home: []const u8) bool {
        const dir = walletDir(allocator, home) catch return false;
        defer allocator.free(dir);
        return install_mod.fileExists(allocator, dir, wallet_name ++ ".keys");
    }

    // Wallet-RPC result subsets. `get_balance` reports atomic-unit integers;
    // `query_key` returns the requested key (the mnemonic, for create display).
    // `create_wallet`/`open_wallet` return an empty object on success, so an
    // absent `result` (Monero put an `error` in its place) signals failure.
    //
    // Monero is single-asset, so `get_balance` reports a flat top-level
    // `balance`/`unlocked_balance` pair — not the per-asset `balances` array its
    // multi-asset Salvium fork returns.
    const WalletBalanceResult = struct { balance: u64 = 0, unlocked_balance: u64 = 0 };
    const QueryKeyResult = struct { key: []const u8 = "" };
    const EmptyResult = struct {};

    /// The `error` half of a Monero wallet-RPC reply (`{ "code": …, "message": … }`),
    /// present in place of `result` when an op fails. `walletRpcError` reads its
    /// `message` to give the user a specific reason rather than a bare "failed".
    const RpcErrObj = struct { code: i64 = 0, message: []const u8 = "" };

    /// JSON-RPC envelope that keeps the `error` object (unlike the shared
    /// `models.JsonRpcResponse`, which drops it) so wallet ops can translate the
    /// daemon's failure message into a precise BoxWallet error.
    fn WalletEnvelope(comptime T: type) type {
        return struct { result: ?T = null, @"error": ?RpcErrObj = null };
    }

    /// POST a wallet-RPC `method` with a raw JSON `params` object (a complete
    /// `{...}` literal — any user string in it must already be JSON-escaped via
    /// `rpc.jsonQuote`) and parse `result`/`error` into the envelope. Caller
    /// `deinit`s the `Parsed`.
    fn walletCall(
        comptime T: type,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        method: []const u8,
        params: []const u8,
    ) !std.json.Parsed(WalletEnvelope(T)) {
        const body = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"{s}\",\"params\":{s}}}",
            .{ method, params },
        );
        defer allocator.free(body);
        const raw = try rpc.moneroPost(allocator, auth, "/json_rpc", body, wallet_timeout_ms);
        defer allocator.free(raw);
        // `.alloc_always` so parsed strings (the mnemonic, the error message)
        // survive `raw` being freed.
        return std.json.parseFromSlice(
            WalletEnvelope(T),
            allocator,
            raw,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
    }

    /// Record the daemon's raw failure `message` into `detail` (for the UI/log) and
    /// return the mapped BoxWallet error. Used at every wallet-op failure so the
    /// real reason is never swallowed — even for messages we don't specifically map.
    fn failWallet(detail: *Coin.WalletErrSink, err: ?RpcErrObj, fallback: anyerror) anyerror {
        if (err) |e| detail.set(e.message);
        return walletRpcError(err, fallback);
    }

    /// Translate a Monero wallet-RPC `error` into the most specific BoxWallet error
    /// so the UI can tell the user *why* an op failed, not just that it did. Falls
    /// back to `fallback` when there's no error object or the message is unfamiliar.
    fn walletRpcError(err: ?RpcErrObj, fallback: anyerror) anyerror {
        const msg = (err orelse return fallback).message;
        if (containsIgnoreCase(msg, "already exists")) return error.WalletAlreadyExists;
        if (containsIgnoreCase(msg, "verification") or
            containsIgnoreCase(msg, "number of words") or
            containsIgnoreCase(msg, "invalid word")) return error.SeedWordsInvalid;
        if (containsIgnoreCase(msg, "invalid password") or
            containsIgnoreCase(msg, "wrong password") or
            containsIgnoreCase(msg, "failed to read")) return error.WrongPassword;
        return fallback;
    }

    /// Case-insensitive substring test (ASCII). Used to match Monero's English
    /// error strings regardless of how the daemon cases them.
    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
        }
        return false;
    }

    /// Create a new wallet named `BoxWallet` under `password`, then read back its
    /// freshly-generated 25-word mnemonic for the user to write down. Fails if a
    /// wallet of that name already exists (Monero returns an error → null result).
    fn walletCreate(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        password: []const u8,
        detail: *Coin.WalletErrSink,
    ) anyerror!models.Seed {
        // Don't fire into a still-starting wallet-rpc (races → spurious AuthFailed).
        if (!rpc.moneroWalletReady(allocator, wallet_auth, wallet_ready_timeout_ms))
            return error.WalletServiceNotReady;
        const qpw = try rpc.jsonQuote(allocator, password);
        defer allocator.free(qpw);
        {
            const params = try std.fmt.allocPrint(
                allocator,
                "{{\"filename\":\"{s}\",\"password\":{s},\"language\":\"English\"}}",
                .{ wallet_name, qpw },
            );
            defer allocator.free(params);
            var parsed = try walletCall(EmptyResult, allocator, wallet_auth, "create_wallet", params);
            defer parsed.deinit();
            if (parsed.value.result == null) return failWallet(detail, parsed.value.@"error", error.WalletCreateFailed);
        }
        var parsed = try walletCall(QueryKeyResult, allocator, wallet_auth, "query_key", "{\"key_type\":\"mnemonic\"}");
        defer parsed.deinit();
        const r = parsed.value.result orelse return error.WalletCreateFailed;
        return models.Seed.from(r.key);
    }

    /// Restore the managed wallet from a 25-word deterministic `seed` under
    /// `password`. v1 does a full rescan (`scan_from_height` 0); a restore-height
    /// prompt is a future add. The seed's word count is checked first so an obvious
    /// typo fails fast with a clear error rather than a daemon-side rejection.
    fn walletRestoreSeed(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        install_root: []const u8,
        home: []const u8,
        password: []const u8,
        seed: []const u8,
        detail: *Coin.WalletErrSink,
    ) anyerror!void {
        // Normalize first: lowercase + single-space the words so a capitalized
        // first word or a paste with stray newlines/double spaces doesn't trip the
        // (case-sensitive) deterministic decode and look like a bad seed.
        const normalized = try normalizeSeed(allocator, seed);
        defer allocator.free(normalized);
        if (!isValidSeed(normalized)) return error.InvalidSeed;

        // The wallet is materialized on disk by a one-shot `monero-wallet-cli
        // --generate-from-json` (the CLAUDE.md-blessed temp-secret path, mirroring
        // Nerva/Salvium) and then opened over RPC like any other wallet — robust
        // regardless of which restore RPC the bundled wallet-rpc exposes.
        try cliGenerateFromSeed(allocator, install_root, home, password, normalized, detail);
        try walletOpen(allocator, wallet_auth, password, detail);
        // No explicit rescan is issued here. `monero-wallet-rpc` auto-refreshes a
        // freshly opened wallet in the background — starting immediately (its last-
        // refresh clock initializes to the minimum time) and scanning in bounded
        // 256-block chunks that yield the single server thread between them. A
        // blocking `refresh` RPC would instead monopolize that one thread for the
        // whole genesis-to-tip scan, stalling every status/`get_height` poll (and
        // so the "Rescanning… X%" readout) until it finished. Progress is surfaced
        // by `walletRescanProgress`, which the poll worker calls each tick.
    }

    /// Restore the managed wallet from `seed` by driving a one-shot
    /// `monero-wallet-cli --generate-from-json`: the CLI reads the
    /// seed/password/filename from a temporary JSON spec and writes
    /// `BoxWallet`(+`.keys`) into the wallet dir, `--offline` so it never blocks on
    /// a chain sync. The spec carries the secret in plaintext, so it's overwritten
    /// and deleted the instant the call returns. Success is the `.keys` file
    /// appearing on disk — the CLI's exit code is unreliable here, so on failure its
    /// own stderr/stdout is surfaced as the reason.
    fn cliGenerateFromSeed(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home: []const u8,
        password: []const u8,
        seed: []const u8,
        detail: *Coin.WalletErrSink,
    ) !void {
        const dir = try walletDir(allocator, home);
        defer allocator.free(dir);
        const wallet_path = try std.fs.path.join(allocator, &.{ dir, wallet_name });
        defer allocator.free(wallet_path);

        // The --generate-from-json spec; every user string is JSON-escaped.
        const qpw = try rpc.jsonQuote(allocator, password);
        defer allocator.free(qpw);
        const qseed = try rpc.jsonQuote(allocator, seed);
        defer allocator.free(qseed);
        const qpath = try rpc.jsonQuote(allocator, wallet_path);
        defer allocator.free(qpath);
        const spec = try std.fmt.allocPrint(
            allocator,
            "{{\"version\":1,\"filename\":{s},\"scan_from_height\":0,\"password\":{s},\"seed\":{s}}}",
            .{ qpath, qpw, qseed },
        );
        defer allocator.free(spec);

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var dd = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
        defer dd.close(io);

        const spec_name = wallet_name ++ ".restore.json";
        try dd.writeFile(io, .{ .sub_path = spec_name, .data = spec });
        // Shred + delete the plaintext-secret spec however we leave this function.
        const blank = try allocator.alloc(u8, spec.len);
        @memset(blank, 0);
        defer allocator.free(blank);
        defer {
            dd.writeFile(io, .{ .sub_path = spec_name, .data = blank }) catch {};
            dd.deleteFile(io, spec_name) catch {};
        }

        const spec_path = try std.fs.path.join(allocator, &.{ dir, spec_name });
        defer allocator.free(spec_path);
        const cli_path = try std.fs.path.join(allocator, &.{ install_root, cli_file });
        defer allocator.free(cli_path);

        // `--command exit` plus the closed stdin (run uses `.ignore`, so the REPL
        // reads EOF) guarantees the CLI exits once the wallet is written; the
        // timeout is a backstop against any vintage that ignores both.
        const argv = [_][]const u8{
            cli_path,
            "--generate-from-json",
            spec_path,
            "--offline",
            "--log-level",
            "0",
            "--command",
            "exit",
        };
        const res = std.process.run(allocator, io, .{
            .argv = &argv,
            .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(120), .clock = .awake } },
        }) catch |err| {
            detail.set(@errorName(err));
            return error.WalletRestoreFailed;
        };
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);

        if (!install_mod.fileExists(allocator, dir, wallet_name ++ ".keys")) {
            const why = std.mem.trim(u8, if (res.stderr.len > 0) res.stderr else res.stdout, " \t\r\n");
            detail.set(if (why.len > 0) why else "monero-wallet-cli did not create the wallet");
            return error.WalletRestoreFailed;
        }
    }

    /// Import an existing wallet file (browsed to) as the managed `BoxWallet`, then
    /// open it. Monero wallets are a `<name>`/`<name>.keys` pair; the `.keys` file
    /// holds the secret and is all that's needed — the cache rebuilds from the
    /// daemon on open, so only the (small) keys file is copied (no large-file slurp).
    /// Accepts either member of the pair from the picker and resolves the keys file.
    fn walletRestoreFile(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        home: []const u8,
        src_path: []const u8,
        password: []const u8,
        detail: *Coin.WalletErrSink,
    ) anyerror!void {
        const keys_src = if (std.mem.endsWith(u8, src_path, ".keys"))
            try allocator.dupe(u8, src_path)
        else
            try std.fmt.allocPrint(allocator, "{s}.keys", .{src_path});
        defer allocator.free(keys_src);

        const dest_dir = try walletDir(allocator, home);
        defer allocator.free(dest_dir);

        try copyKeysFile(allocator, keys_src, dest_dir, wallet_name ++ ".keys");
        try walletOpen(allocator, wallet_auth, password, detail);
    }

    /// Copy a (small) Monero `.keys` file from absolute `src_path` into `dest_dir`
    /// as `dest_name`, creating `dest_dir` if needed. Keys files are a few KB, so a
    /// single bounded read+write is fine (and avoids a streaming copy for a tiny
    /// file). The cache file is intentionally not copied — it regenerates on open.
    fn copyKeysFile(
        allocator: std.mem.Allocator,
        src_path: []const u8,
        dest_dir: []const u8,
        dest_name: []const u8,
    ) !void {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        // Open via (dir, basename) so an absolute picker path works the same way
        // the conf code opens files.
        const src_dir = std.fs.path.dirname(src_path) orelse ".";
        const src_base = std.fs.path.basename(src_path);
        var sd = std.Io.Dir.cwd().openDir(io, src_dir, .{}) catch return error.WalletFileNotFound;
        defer sd.close(io);
        var src = sd.openFile(io, src_base, .{}) catch return error.WalletFileNotFound;
        defer src.close(io);

        var buf: [64 * 1024]u8 = undefined;
        const n = try src.readPositionalAll(io, &buf, 0);

        var dd = try std.Io.Dir.cwd().createDirPathOpen(io, dest_dir, .{});
        defer dd.close(io);
        try dd.writeFile(io, .{ .sub_path = dest_name, .data = buf[0..n] });
    }

    /// Open the existing managed wallet with `password` so its balance can be read.
    /// Called once at process start when a wallet already exists.
    fn walletOpen(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        password: []const u8,
        detail: *Coin.WalletErrSink,
    ) anyerror!void {
        // The restore/open paths reach here right after the wallet-rpc is spawned;
        // wait for it to answer auth so a startup race can't look like a bad password.
        if (!rpc.moneroWalletReady(allocator, wallet_auth, wallet_ready_timeout_ms))
            return error.WalletServiceNotReady;
        const qpw = try rpc.jsonQuote(allocator, password);
        defer allocator.free(qpw);
        const params = try std.fmt.allocPrint(
            allocator,
            "{{\"filename\":\"{s}\",\"password\":{s}}}",
            .{ wallet_name, qpw },
        );
        defer allocator.free(params);
        var parsed = try walletCall(EmptyResult, allocator, wallet_auth, "open_wallet", params);
        defer parsed.deinit();
        if (parsed.value.result == null) return failWallet(detail, parsed.value.@"error", error.WalletOpenFailed);
    }

    /// Read the open wallet's balance. `balance` is the total (includes locked and
    /// unconfirmed); `unlocked_balance` is spendable now — exactly the Total /
    /// Available split the frontend renders.
    fn walletBalance(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
    ) anyerror!models.WalletBalance {
        var parsed = try walletCall(WalletBalanceResult, allocator, wallet_auth, "get_balance", "{\"account_index\":0}");
        defer parsed.deinit();
        if (parsed.value.result) |r| return atomicToBalance(r.balance, r.unlocked_balance);
        // No result → the wallet-rpc returned an error. "No wallet file" (-13) means
        // no wallet is open: the wallet-rpc was restarted (e.g. a daemon bounce) and
        // never re-opened. Surface it distinctly so the app can revert the wallet
        // line to "Locked" rather than showing a stale balance; any other error is
        // transient and the poll leaves the last value in place.
        if (walletIsClosed(parsed.value.@"error")) return error.WalletClosed;
        return error.EmptyRpcResult;
    }

    /// True if a wallet-RPC `error` reports that no wallet is open. Monero returns
    /// code -13 (`WALLET_RPC_ERROR_CODE_NO_WALLET_FILE`) with a "No wallet file"
    /// message; matching either is robust across vintage wording changes.
    fn walletIsClosed(err: ?RpcErrObj) bool {
        const e = err orelse return false;
        return e.code == -13 or containsIgnoreCase(e.message, "no wallet");
    }

    /// Map Monero atomic balances to the normalized `WalletBalance`. Pure, so it's
    /// unit-testable without a wallet process.
    fn atomicToBalance(balance: u64, unlocked: u64) models.WalletBalance {
        return .{
            .total = @as(f64, @floatFromInt(balance)) / atomic_per_xmr,
            .available = @as(f64, @floatFromInt(unlocked)) / atomic_per_xmr,
        };
    }

    /// One-field subset of `get_height`'s wallet-RPC result: how far the wallet's
    /// own background refresh has scanned the chain (a block count, i.e. tip+1).
    const WalletHeightResult = struct { height: u64 = 0 };

    /// Blocks of slack below the daemon tip within which the wallet counts as
    /// "caught up". Steady-state, the wallet can trail the tip by a block between
    /// 20-second auto-refreshes; this margin keeps that from flickering the
    /// "Rescanning…" readout. A genuine restore rescans from height 0 (millions of
    /// blocks), so the margin never hides real progress. Pure heuristic — the
    /// scanned/target heights it gates are honest.
    const rescan_done_slack: i64 = 4;

    /// Report how far the wallet's background refresh has scanned a freshly restored
    /// wallet, so the UI can show "Rescanning… X%". `monero-wallet-rpc`
    /// auto-refreshes an open wallet in 256-block chunks (see `walletRestoreSeed`),
    /// advancing its `get_height` as it goes. The scanned height is that wallet
    /// `get_height` (`wallet_auth`); the target is the daemon's chain tip from
    /// `get_info` (`daemon_auth`) — wallet and daemon are separate processes, so
    /// both auths are needed. Returns null when the wallet is within
    /// `rescan_done_slack` of the tip (caught up) or the tip isn't known yet, which
    /// clears the indicator. Best-effort: a read error propagates and the poll
    /// worker treats it as "no progress this tick" (keeping the last value).
    fn walletRescanProgress(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        daemon_auth: models.CoinAuth,
    ) anyerror!?models.RescanProgress {
        var info = try fetchInfo(allocator, daemon_auth);
        defer info.deinit();
        const di = info.value.result orelse return null;
        const tip = @max(di.target_height, di.height);
        if (tip <= 0) return null;

        var parsed = try walletCall(WalletHeightResult, allocator, wallet_auth, "get_height", "{}");
        defer parsed.deinit();
        const wh = parsed.value.result orelse return null;
        return rescanFrom(@intCast(wh.height), tip);
    }

    /// Decide the rescan readout from the wallet's `scanned` height and the daemon
    /// `tip`. Null = caught up (within `rescan_done_slack` of the tip) or the tip
    /// isn't known yet, which clears the "Rescanning…" indicator; otherwise the
    /// scanned/target pair to show. Pure, so it's unit-testable without either
    /// process.
    fn rescanFrom(scanned: i64, tip: i64) ?models.RescanProgress {
        if (tip <= 0) return null;
        if (scanned >= tip - rescan_done_slack) return null;
        return .{ .scanned = scanned, .target = tip };
    }

    // --- Transactions / receive / send (wallet RPC) ----------------------
    //
    // These ride the same `monero-wallet-rpc` process as balance, so the app
    // hands them the wallet endpoint (`extWalletAuth`) and polls them only
    // once the wallet is open.

    /// One `get_transfers` entry (the subset BoxWallet uses). Monero's 0.18
    /// wallet-rpc reports `confirmations` per entry; a coinbase (mined) credit
    /// arrives in the `in` bucket with `type == "block"`.
    const TransferEntry = struct {
        amount: u64 = 0,
        fee: u64 = 0,
        timestamp: i64 = 0,
        confirmations: i64 = 0,
        type: []const u8 = "",
    };

    /// `get_transfers` groups entries by state; direction falls out of the
    /// bucket (`in` received, `out`/`pending` sent, `pool` incoming-unconfirmed).
    const GetTransfersResult = struct {
        in: []TransferEntry = &.{},
        out: []TransferEntry = &.{},
        pending: []TransferEntry = &.{},
        pool: []TransferEntry = &.{},
    };
    const AddressResult = struct { address: []const u8 = "" };
    const TransferResult = struct { tx_hash: []const u8 = "" };

    /// The open wallet's most recent transactions, newest-first, via the wallet
    /// RPC's `get_transfers`. The reply spans the wallet's whole history (the
    /// RPC has no count cap), but it's parsed into minimal entries and freed on
    /// return — only the `limit` newest normalized rows survive.
    fn walletTransactions(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        limit: usize,
    ) anyerror![]models.WalletTx {
        var parsed = try walletCall(GetTransfersResult, allocator, wallet_auth, "get_transfers", "{\"in\":true,\"out\":true,\"pending\":true,\"pool\":true,\"account_index\":0}");
        defer parsed.deinit();
        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return mapTransfers(allocator, r, limit);
    }

    /// Flatten the four `get_transfers` buckets into normalized `WalletTx`es,
    /// newest-first, capped at `limit`. Split out from `walletTransactions` so
    /// the mapping/ordering is unit-testable without a wallet process.
    fn mapTransfers(allocator: std.mem.Allocator, r: GetTransfersResult, limit: usize) ![]models.WalletTx {
        const total = r.in.len + r.out.len + r.pending.len + r.pool.len;
        const all = try allocator.alloc(models.WalletTx, total);
        defer allocator.free(all);
        var n: usize = 0;
        for (r.in) |e| {
            // A coinbase credit (type "block") was mined by the wallet itself.
            const direction: models.TxDirection = if (std.mem.eql(u8, e.type, "block")) .stake else .received;
            all[n] = mapEntry(e, direction);
            n += 1;
        }
        for (r.out) |e| {
            all[n] = mapEntry(e, .sent);
            n += 1;
        }
        for (r.pending) |e| {
            all[n] = mapEntry(e, .sent);
            n += 1;
        }
        for (r.pool) |e| {
            all[n] = mapEntry(e, .received);
            n += 1;
        }
        std.mem.sort(models.WalletTx, all[0..n], {}, newerFirst);

        const out = try allocator.alloc(models.WalletTx, @min(n, limit));
        @memcpy(out, all[0..out.len]);
        return out;
    }

    /// One entry → the normalized row (atomic units → whole XMR).
    fn mapEntry(e: TransferEntry, direction: models.TxDirection) models.WalletTx {
        return .{
            .direction = direction,
            .amount = @as(f64, @floatFromInt(e.amount)) / atomic_per_xmr,
            .time = e.timestamp,
            .confirmations = e.confirmations,
        };
    }

    /// Sort helper: newest (largest timestamp) first.
    fn newerFirst(_: void, lhs: models.WalletTx, rhs: models.WalletTx) bool {
        return lhs.time > rhs.time;
    }

    /// The open wallet's receive address (`get_address`, account 0). CryptoNote
    /// stealth addressing keeps a reused address private, so the main address
    /// is the stable "current" one; an explicit user-requested rotation mints a
    /// fresh subaddress (`create_address`).
    fn walletReceiveAddress(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        force_new: bool,
    ) anyerror![]const u8 {
        const method: []const u8 = if (force_new) "create_address" else "get_address";
        var parsed = try walletCall(AddressResult, allocator, wallet_auth, method, "{\"account_index\":0}");
        defer parsed.deinit();
        const r = parsed.value.result orelse return error.EmptyRpcResult;
        if (r.address.len == 0) return error.EmptyRpcResult;
        return allocator.dupe(u8, r.address); // parsed.deinit() frees its arena below us
    }

    /// Send `amount` XMR to `address` via the wallet RPC `transfer`. The wallet
    /// does its own address validation and balance check — `SendResult` carries
    /// whichever of those (or the success tx hash) came back, verbatim. The
    /// amount is converted to integer atomic units before splicing.
    fn walletSend(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        address: []const u8,
        amount: f64,
    ) anyerror!models.SendResult {
        const atomic = atomicFromAmount(amount) orelse return .{ .failed = "invalid amount" };
        const addr_q = try rpc.jsonQuote(allocator, address);
        defer allocator.free(addr_q);
        const params = try std.fmt.allocPrint(
            allocator,
            "{{\"destinations\":[{{\"amount\":{d},\"address\":{s}}}],\"account_index\":0,\"get_tx_key\":true}}",
            .{ atomic, addr_q },
        );
        defer allocator.free(params);

        var parsed = try walletCall(TransferResult, allocator, wallet_auth, "transfer", params);
        defer parsed.deinit();
        if (parsed.value.result) |r| {
            if (r.tx_hash.len > 0) return .{ .ok = try allocator.dupe(u8, r.tx_hash) };
        }
        if (parsed.value.@"error") |e| return .{ .failed = try allocator.dupe(u8, e.message) };
        return .{ .failed = "no response from wallet" };
    }

    /// Convert a user-entered XMR amount to integer atomic units (rounded to
    /// the nearest atomic). Null for anything unusable — non-finite,
    /// non-positive, or too large for u64 — so a bad amount is rejected before
    /// any RPC.
    fn atomicFromAmount(amount: f64) ?u64 {
        if (!std.math.isFinite(amount) or amount <= 0) return null;
        const scaled = @round(amount * atomic_per_xmr);
        if (scaled >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return null;
        return @intFromFloat(scaled);
    }

    /// Produce the canonical form of a user-entered seed for the wallet RPC:
    /// every word lowercased and joined by single spaces, with leading/trailing and
    /// repeated whitespace collapsed. Monero's English wordlist is all lowercase and
    /// the deterministic decode is case-sensitive, so a transcriber who capitalizes
    /// a word — or pastes with newlines/double spaces — would otherwise hit a
    /// spurious "word list failed verification". Caller owns the returned slice.
    fn normalizeSeed(allocator: std.mem.Allocator, seed: []const u8) ![]const u8 {
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

    /// Count whitespace-separated tokens in `s`. Pure helper behind `isValidSeed`.
    fn wordCount(s: []const u8) usize {
        var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        return n;
    }

    /// Cheap pre-flight check that `seed` has the right word count (25) before it's
    /// sent to the wallet RPC. Not a full mnemonic-checksum validation — the wallet
    /// process does that — just a fast guard against an obviously wrong paste.
    fn isValidSeed(seed: []const u8) bool {
        return wordCount(std.mem.trim(u8, seed, " \t\r\n")) == seed_word_count;
    }

    /// Remove the managed wallet so a different one can be created/restored in its
    /// place — the destructive in-app "Replace wallet". Drops the whole
    /// `<datadir>/wallets` dir (the `BoxWallet` cache, its `.keys` secret, and the
    /// `.address.txt`), so `walletExists` reports false next. The caller (`app.zig`)
    /// kills `monero-wallet-rpc` first — releasing the file locks — and leaves the
    /// daemon (and its sync) running; the next create/restore re-creates the dir.
    /// Idempotent — a missing dir is fine; `deleteTree` holds nothing in memory
    /// beyond a path.
    fn walletRemove(allocator: std.mem.Allocator, home: []const u8) anyerror!void {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const dir = try walletDir(allocator, home);
        defer allocator.free(dir);
        try std.Io.Dir.cwd().deleteTree(threaded.io(), dir);
    }

    /// The external-wallet capability wired into the vtable. Funds-sensitive ops
    /// route through here; bitcoin coins leave `external_wallet` null instead.
    pub const external_wallet: Coin.ExternalWallet = .{
        .rpc_port = walletRpcPort,
        .process_argv = walletProcessArgv,
        .exists = walletExists,
        .create = walletCreate,
        .restore_seed = walletRestoreSeed,
        .restore_file = walletRestoreFile,
        .open = walletOpen,
        .remove = walletRemove,
        .balance = walletBalance,
        .rescan_progress = walletRescanProgress,
    };

    // --- vtable plumbing -------------------------------------------------
    //
    // No `wallet_stake`/`stake_hint`: Monero is pure proof-of-work, so — unlike
    // its Salvium fork — there's no stake action to offer.

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
        .installed_version_probe = vtProbeInstalledVersion,
        .install = vtInstall,
        .prepare_conf = vtPrepareConf,
        .launch_mode = vtLaunchMode,
        .daemon_log_file = vtDaemonLogFile,
        .daemon_argv = vtDaemonArgv,
        .request_stop = vtRequestStop,
        .wallet_transactions = vtWalletTransactions,
        .wallet_receive_address = vtWalletReceiveAddress,
        .wallet_send = vtWalletSend,
        .external_wallet = &external_wallet,
        .pruning = &pruning_caps,
    };

    // The three hooks below ride the wallet process's endpoint: for an
    // external-wallet coin, `app.zig` passes `extWalletAuth()` (never the
    // daemon's auth) and calls them only once the wallet is open.
    fn vtWalletTransactions(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        limit: usize,
    ) anyerror![]models.WalletTx {
        return walletTransactions(allocator, wallet_auth, limit);
    }
    fn vtWalletReceiveAddress(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        force_new: bool,
    ) anyerror![]const u8 {
        return walletReceiveAddress(allocator, wallet_auth, force_new);
    }
    fn vtWalletSend(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        address: []const u8,
        amount: f64,
    ) anyerror!models.SendResult {
        return walletSend(allocator, wallet_auth, address, amount);
    }

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
    fn vtProbeInstalledVersion(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        install_root: []const u8,
    ) anyerror![]const u8 {
        return probeInstalledVersion(allocator, install_root);
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
};

test "parses get_info into a synced BlockchainState" {
    const allocator = std.testing.allocator;

    // Canned Monero `get_info` reply (subset) — fully synced: target_height 0 and
    // `synchronized` true. Proves the flat parse + height-derived sync without a
    // running monerod.
    const raw =
        \\{"id":"0","jsonrpc":"2.0","result":{"status":"OK","height":3400000,
        \\"target_height":0,"synchronized":true,"outgoing_connections_count":12,
        \\"incoming_connections_count":8,"mainnet":true,"testnet":false,
        \\"version":"0.18.5.1-release"}}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(Monero.MoneroInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    try std.testing.expectEqual(@as(i64, 3_400_000), r.height);
    try std.testing.expect(r.synchronized);
    // Monero, unlike its Nerva/Salvium forks, reports its version over RPC — and
    // the build suffix must be trimmed so it lines up with the pinned core_version.
    try std.testing.expectEqualStrings(Monero.core_version, models.trimBuildSuffix(r.version));
}

test "estimateSecondsBehind turns the block gap into a behind-by estimate" {
    // 100 blocks behind at 120s/block → ~12000s behind.
    try std.testing.expectEqual(@as(i64, 12000), Monero.estimateSecondsBehind(1000, 900, false));

    // Synced → 0, so the frontend shows no "behind by" hint.
    try std.testing.expectEqual(@as(i64, 0), Monero.estimateSecondsBehind(1000, 1000, true));

    // Caught up by height (target reached) even if the flag lags → still 0.
    try std.testing.expectEqual(@as(i64, 0), Monero.estimateSecondsBehind(1000, 1000, false));
}

test "a daemon still catching up reads as not synced" {
    // Mid-sync: height behind target_height and not yet synchronized.
    const r: Monero.MoneroInfo = .{ .height = 900_000, .target_height = 3_400_000, .synchronized = false };
    const synced = r.synchronized or (r.height > 0 and (r.target_height == 0 or r.height >= r.target_height));
    try std.testing.expect(!synced);
    try std.testing.expectEqual(@as(i64, 3_400_000), @max(r.target_height, r.height));
}

test "every platform BoxWallet ships resolves a Monero bundle" {
    // BoxWallet releases for exactly these five targets (see `release_targets` in
    // build.zig). Monero must publish a bundle for all of them, or that platform
    // gets a dead Monero tab. Checked via `bundleFor` rather than the target-bound
    // `bundle` const, so one native run covers the whole matrix instead of passing
    // vacuously for the four targets it isn't compiled for.
    const shipped = [_]struct { os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch }{
        .{ .os = .linux, .arch = .x86_64 },
        .{ .os = .linux, .arch = .aarch64 },
        .{ .os = .macos, .arch = .x86_64 },
        .{ .os = .macos, .arch = .aarch64 },
        .{ .os = .windows, .arch = .x86_64 },
    };
    for (shipped) |t| {
        const b = Monero.bundleFor(t.os, t.arch) orelse return error.TestUnexpectedResult;
        // The whole reason `Bundle` carries both names: the wrapper dir is *not*
        // the asset stem (`monero-linux-x64-…` unpacks to
        // `monero-x86_64-linux-gnu-…`). Deriving one from the other would silently
        // break the promote step, leaving an install with no binaries.
        try std.testing.expect(!std.mem.eql(u8, b.asset, b.dir));
        try std.testing.expect(std.mem.endsWith(u8, b.asset, "-v" ++ Monero.core_version));
        try std.testing.expect(std.mem.endsWith(u8, b.dir, "-v" ++ Monero.core_version));
        // Windows ships zips, Linux/macOS tar.bz2.
        try std.testing.expectEqual(
            if (t.os == .windows) install_mod.Format.zip else install_mod.Format.tar_bz2,
            b.format,
        );
    }

    // Platforms BoxWallet doesn't support resolve nothing, so install fails with a
    // clear UnsupportedPlatform rather than a 404 mid-download.
    try std.testing.expect(Monero.bundleFor(.freebsd, .x86_64) == null);
    try std.testing.expect(Monero.bundleFor(.linux, .riscv64) == null);
    // Upstream publishes no ARM Windows build.
    try std.testing.expect(Monero.bundleFor(.windows, .aarch64) == null);
}

test "the download URL is self-hosted and matches the bundle's format" {
    // Monero hosts its own binaries — its GitHub release carries no assets at all,
    // so the GitHub-releases URL shape every other coin uses would 404 here.
    if (Monero.download) |dl| {
        try std.testing.expect(std.mem.startsWith(u8, dl.url, "https://downloads.getmonero.org/cli/"));
        try std.testing.expect(std.mem.indexOf(u8, dl.url, "-v" ++ Monero.core_version) != null);
        switch (dl.format) {
            .zip => try std.testing.expect(std.mem.endsWith(u8, dl.url, ".zip")),
            .tar_bz2 => try std.testing.expect(std.mem.endsWith(u8, dl.url, ".tar.bz2")),
            .tar_gz => return error.TestUnexpectedResult,
        }
    }

    // Binary names carry `.exe` only on Windows.
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("monerod.exe", Monero.daemon_file);
    } else {
        try std.testing.expectEqualStrings("monerod", Monero.daemon_file);
    }
}

test "daemonArgv runs the daemon non-interactive" {
    const allocator = std.testing.allocator;

    const argv = try Monero.daemonArgv(allocator, "/opt/bw", "");
    defer {
        for (argv) |a| allocator.free(a);
        allocator.free(argv);
    }
    try std.testing.expectEqual(@as(usize, 2), argv.len);
    try std.testing.expect(std.mem.endsWith(u8, argv[0], Monero.daemon_file));
    try std.testing.expect(std.mem.startsWith(u8, argv[0], "/opt/bw"));
    try std.testing.expectEqualStrings("--non-interactive", argv[1]);
}

test "the wallet-rpc port avoids monerod's P2P/RPC/ZMQ block" {
    // 18080 P2P, 18081 RPC, 18082 ZMQ-RPC are all monerod's. Binding the wallet
    // on any of them makes *monerod itself* fail to start, so this must stay clear.
    for ([_][]const u8{ "18080", "18081", "18082" }) |reserved| {
        try std.testing.expect(!std.mem.eql(u8, Monero.wallet_rpc_port, reserved));
    }
    try std.testing.expectEqualStrings("18081", Monero.rpc_default_port);
}

test "the version probe round-trips monerod's banner" {
    var m: Monero = .{};
    const c = m.coin();
    try std.testing.expect(c.vtable.installed_version_probe != null);

    // `monerod --version` prints this; the shared parser takes the run after `v`.
    const banner = "Monero 'Fluorine Fermi' (v" ++ Monero.core_version ++ "-release)";
    try std.testing.expectEqualStrings(Monero.core_version, install_mod.parseVersionBanner(banner).?);
}

test "coin vtable dispatches to Monero metadata" {
    var m: Monero = .{};
    const c = m.coin();
    try std.testing.expectEqualStrings("Monero", c.coinName());
    try std.testing.expectEqualStrings("XMR", c.coinNameAbbrev());
    try std.testing.expectEqualStrings("#FF6600", c.coinColor());
    try std.testing.expect(!c.isProofOfStake());
    // Monero's on-disk identity is `bitmonero`, not `monero` — conf and log both.
    try std.testing.expectEqualStrings("bitmonero.conf", c.confFile());
    try std.testing.expectEqualStrings("bitmonero.log", c.daemonLogFile().?);
    try std.testing.expectEqualStrings("18081", c.rpcDefaultPort());
    try std.testing.expectEqual(Coin.LaunchMode.foreground, c.launchMode());
}

test "Monero is pure PoW, so it offers no stake action" {
    var m: Monero = .{};
    const c = m.coin();
    // Salvium (a Monero fork) wires these; upstream Monero has no staking, so the
    // frontend must not render the stake chrome for it.
    try std.testing.expect(c.vtable.wallet_stake == null);
    try std.testing.expect(c.vtable.stake_hint == null);
}

test "walletPath reports the Monero wallet file plus its .keys companion" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var m: Monero = .{};
    const wf = (try m.coin().walletPath(allocator, "/home/alice")).?;
    defer allocator.free(wf.path);
    defer allocator.free(wf.keys.?);
    try std.testing.expectEqualStrings("/home/alice/.bitmonero/wallets/BoxWallet", wf.path);
    try std.testing.expectEqualStrings("/home/alice/.bitmonero/wallets/BoxWallet.keys", wf.keys.?);
}

test "atomicToBalance maps 12-decimal atomic units to whole XMR" {
    // Monero's atomic unit is 1e-12 XMR (not Salvium's 1e-8) — a decimal slip here
    // would misreport a balance by four orders of magnitude.
    const b = Monero.atomicToBalance(1_500_000_000_000, 500_000_000_000);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), b.total, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), b.available, 1e-9);
}

test "atomicFromAmount rejects unusable amounts before any RPC" {
    try std.testing.expectEqual(@as(?u64, 1_000_000_000_000), Monero.atomicFromAmount(1.0));
    try std.testing.expectEqual(@as(?u64, null), Monero.atomicFromAmount(0));
    try std.testing.expectEqual(@as(?u64, null), Monero.atomicFromAmount(-1));
    try std.testing.expectEqual(@as(?u64, null), Monero.atomicFromAmount(std.math.inf(f64)));
    try std.testing.expectEqual(@as(?u64, null), Monero.atomicFromAmount(std.math.nan(f64)));
    // Far beyond u64 atomic units.
    try std.testing.expectEqual(@as(?u64, null), Monero.atomicFromAmount(1e30));
}

test "mapTransfers flattens the buckets newest-first and caps at the limit" {
    const allocator = std.testing.allocator;

    const r: Monero.GetTransfersResult = .{
        .in = @constCast(&[_]Monero.TransferEntry{
            .{ .amount = 2_000_000_000_000, .timestamp = 100, .confirmations = 10 },
            // A coinbase credit is mined by this wallet, not received from a peer.
            .{ .amount = 1_000_000_000_000, .timestamp = 300, .confirmations = 5, .type = "block" },
        }),
        .out = @constCast(&[_]Monero.TransferEntry{
            .{ .amount = 500_000_000_000, .timestamp = 200, .confirmations = 7 },
        }),
        .pool = @constCast(&[_]Monero.TransferEntry{
            .{ .amount = 250_000_000_000, .timestamp = 400 },
        }),
    };

    const txs = try Monero.mapTransfers(allocator, r, 3);
    defer allocator.free(txs);

    // Capped at the limit, and ordered newest-first by timestamp.
    try std.testing.expectEqual(@as(usize, 3), txs.len);
    try std.testing.expectEqual(@as(i64, 400), txs[0].time);
    try std.testing.expectEqual(@as(i64, 300), txs[1].time);
    try std.testing.expectEqual(@as(i64, 200), txs[2].time);

    // A pool entry is an unconfirmed *incoming* transfer.
    try std.testing.expectEqual(models.TxDirection.received, txs[0].direction);
    // The coinbase row is marked as minted, not received.
    try std.testing.expectEqual(models.TxDirection.stake, txs[1].direction);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), txs[1].amount, 1e-9);
    try std.testing.expectEqual(models.TxDirection.sent, txs[2].direction);
}

test "rescanFrom reports progress only while genuinely behind" {
    // Mid-rescan → the scanned/target pair drives "Rescanning… X%".
    const p = Monero.rescanFrom(1_000_000, 3_400_000).?;
    try std.testing.expectEqual(@as(i64, 1_000_000), p.scanned);
    try std.testing.expectEqual(@as(i64, 3_400_000), p.target);

    // Within the slack of the tip → caught up, indicator cleared.
    try std.testing.expectEqual(@as(?models.RescanProgress, null), Monero.rescanFrom(3_399_999, 3_400_000));
    // Tip unknown → nothing to report.
    try std.testing.expectEqual(@as(?models.RescanProgress, null), Monero.rescanFrom(0, 0));
}

test "normalizeSeed lowercases and collapses whitespace" {
    const allocator = std.testing.allocator;
    // A seed pasted with a capitalized first word, a newline, and a double space
    // must still decode — Monero's wordlist is lowercase and the decode is
    // case-sensitive, so this is the difference between a restore and a scary
    // "word list failed verification".
    const s = try Monero.normalizeSeed(allocator, "  Abbey\tbaby   cadets\ndagger ");
    defer allocator.free(s);
    try std.testing.expectEqualStrings("abbey baby cadets dagger", s);
}

test "isValidSeed accepts exactly 25 words" {
    const allocator = std.testing.allocator;

    // Build a 25-word phrase (content is irrelevant — this is a shape check; the
    // wallet process does the real checksum validation).
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    for (0..Monero.seed_word_count) |i| {
        if (i != 0) try buf.writer.writeByte(' ');
        try buf.writer.writeAll("abbey");
    }
    try std.testing.expect(Monero.isValidSeed(buf.written()));

    // 24 words is a BIP39-length paste — a real user error worth catching early.
    try std.testing.expect(!Monero.isValidSeed("abbey abbey abbey"));
    try std.testing.expect(!Monero.isValidSeed(""));
}

test "walletRpcError maps the wallet's own message to a specific error" {
    // The point: the user must be able to tell a typo'd password from a bad seed
    // from a name clash — never a generic "failed".
    try std.testing.expectEqual(
        error.WrongPassword,
        Monero.walletRpcError(.{ .code = -1, .message = "invalid password" }, error.WalletOpenFailed),
    );
    try std.testing.expectEqual(
        error.SeedWordsInvalid,
        Monero.walletRpcError(.{ .code = -1, .message = "electrum-style word list failed verification" }, error.WalletRestoreFailed),
    );
    try std.testing.expectEqual(
        error.WalletAlreadyExists,
        Monero.walletRpcError(.{ .code = -21, .message = "Wallet already exists." }, error.WalletCreateFailed),
    );
    // An unfamiliar message keeps the caller's fallback (and the raw text is still
    // recorded into the sink by `failWallet`).
    try std.testing.expectEqual(
        error.WalletOpenFailed,
        Monero.walletRpcError(.{ .code = -1, .message = "something new upstream" }, error.WalletOpenFailed),
    );
    try std.testing.expectEqual(error.WalletOpenFailed, Monero.walletRpcError(null, error.WalletOpenFailed));
}

test "walletIsClosed recognises the no-wallet-open reply" {
    // -13 means the wallet-rpc restarted and nothing is open: the app must revert
    // the line to "Locked" rather than keep showing a stale balance.
    try std.testing.expect(Monero.walletIsClosed(.{ .code = -13, .message = "No wallet file" }));
    try std.testing.expect(Monero.walletIsClosed(.{ .code = 0, .message = "no wallet is currently open" }));
    try std.testing.expect(!Monero.walletIsClosed(.{ .code = -1, .message = "invalid password" }));
    try std.testing.expect(!Monero.walletIsClosed(null));
}

test "prepareConf writes a Monero-valid conf, and never touches an existing one" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-monero-home";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    const data_dir = try Monero.dataDir(allocator, home);
    defer allocator.free(data_dir);

    // Fresh dir: BoxWallet writes the canonical Monero conf. It must carry only
    // Monero-style options — a bitcoin `rpcuser` line makes monerod refuse to boot.
    try Monero.prepareConf(allocator, io, home);
    {
        const got = try conf.readValue(allocator, io, data_dir, Monero.conf_file, "rpc-bind-port");
        defer if (got) |g| allocator.free(g);
        try std.testing.expectEqualStrings(Monero.rpc_default_port, got.?);
    }

    // Now the case that matters: `~/.bitmonero` is the standard Monero data dir on
    // Linux and macOS, so this conf may be an existing node's, holding settings that
    // matter. Overwrite it and we've broken their node to configure ours.
    const theirs = "# my node\nprune-blockchain=1\nout-peers=16\nrpc-bind-port=28081\n";
    {
        var dd = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
        defer dd.close(io);
        try dd.writeFile(io, .{ .sub_path = Monero.conf_file, .data = theirs });
    }
    try Monero.prepareConf(allocator, io, home);

    // Byte-for-byte untouched: their prune setting, peer count, and custom port all
    // survive.
    {
        var dd = try std.Io.Dir.cwd().openDir(io, data_dir, .{});
        defer dd.close(io);
        var f = try dd.openFile(io, Monero.conf_file, .{});
        defer f.close(io);
        var buf: [512]u8 = undefined;
        const n = try f.readPositionalAll(io, &buf, 0);
        try std.testing.expectEqualStrings(theirs, buf[0..n]);
    }
}

test "pruning: offered when unset, then the choice is read back and not re-offered" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var xmr: Monero = .{};
    const c = xmr.coin();

    // A throwaway HOME whose ~/.bitmonero/bitmonero.conf doesn't exist yet.
    const home = "test-xmr-prune-home";
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // No conf → prompt is offered and there's no configured value.
    try std.testing.expect(c.offersPrunePrompt(allocator, home));
    try std.testing.expect((try c.pruningState(allocator, home)) == null);

    // Pruning on: read back as 1, and the prompt is done asking.
    try c.applyPrune(allocator, home, 1);
    try std.testing.expectEqual(@as(?i64, 1), try c.pruningState(allocator, home));
    try std.testing.expect(!c.offersPrunePrompt(allocator, home));

    // Applying the choice must not cost us the canonical conf body — `pruneApply`
    // runs `prepareConf` first precisely so `rpc-bind-port` is still there.
    const data_dir = try Monero.dataDir(allocator, home);
    defer allocator.free(data_dir);
    {
        const port = (try conf.readValue(allocator, io, data_dir, Monero.conf_file, "rpc-bind-port")).?;
        defer allocator.free(port);
        try std.testing.expectEqualStrings(Monero.rpc_default_port, port);
    }

    // "Keep the full blockchain" (0) is a real configured value, distinct from unset.
    try c.applyPrune(allocator, home, 0);
    try std.testing.expectEqual(@as(?i64, 0), try c.pruningState(allocator, home));
    try std.testing.expect(!c.offersPrunePrompt(allocator, home));
}

test "pruning: monerod's true/false spelling reads back, junk reads as unset" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var xmr: Monero = .{};
    const c = xmr.coin();

    const home = "test-xmr-prune-spelling";
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    const data_dir = try Monero.dataDir(allocator, home);
    defer allocator.free(data_dir);
    var dd = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
    defer dd.close(io);

    // monerod's option parser takes both spellings, so a conf written by hand
    // (or by another wallet) must still read as "already answered".
    try dd.writeFile(io, .{ .sub_path = Monero.conf_file, .data = "prune-blockchain=true\n" });
    try std.testing.expectEqual(@as(?i64, 1), try c.pruningState(allocator, home));
    try dd.writeFile(io, .{ .sub_path = Monero.conf_file, .data = "prune-blockchain=false\n" });
    try std.testing.expectEqual(@as(?i64, 0), try c.pruningState(allocator, home));

    // An unparseable value reads as unset rather than erroring the Settings tab.
    try dd.writeFile(io, .{ .sub_path = Monero.conf_file, .data = "prune-blockchain=maybe\n" });
    try std.testing.expectEqual(@as(?i64, null), try c.pruningState(allocator, home));
}

test "pruning is never offered for a chain that was already here" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var xmr: Monero = .{};
    const c = xmr.coin();

    // The scenario this guards: `~/.bitmonero` is monerod's standard data dir on
    // Linux and macOS, so it may hold an existing node. A node that was never
    // pruned has *no* `prune-blockchain` key — that's what unpruned means — so
    // without the chain check it reads as "never asked" and BoxWallet offers to
    // prune someone else's chain.
    const home = "test-xmr-adopted-home";
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    const data_dir = try Monero.dataDir(allocator, home);
    defer allocator.free(data_dir);

    // A data dir that looks like an existing node: an `lmdb/` chain, and a conf
    // carrying no `prune-blockchain` key (what a full node's conf looks like).
    {
        var dd = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
        defer dd.close(io);
        try dd.writeFile(io, .{ .sub_path = Monero.conf_file, .data = "out-peers=16\n" });
    }
    {
        const lmdb = try std.fs.path.join(allocator, &.{ data_dir, "lmdb" });
        defer allocator.free(lmdb);
        var ld = try std.Io.Dir.cwd().createDirPathOpen(io, lmdb, .{});
        ld.close(io);
    }

    // Nothing is configured — but the prompt must still be withheld, because the
    // chain isn't ours to prune.
    try std.testing.expect((try c.pruningState(allocator, home)) == null);
    try std.testing.expect(!c.offersPrunePrompt(allocator, home));
}
