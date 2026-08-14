const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const install_mod = @import("../install.zig");
const conf = @import("../conf.zig");
const rpc = @import("../rpc.zig");
const warmup = @import("../warmup.zig");
const Coin = @import("../coin.zig").Coin;

/// Nerva (XNV) backend. Nerva isn't in the Go app, so this is a fresh backend
/// rather than a port; the shapes below come from Nerva itself (a Monero/
/// CryptoNote fork), not a reference implementation.
///
/// Two things set Nerva apart from the bitcoin-core coins:
///
///   * **Distribution** — Linux/macOS bundles ship as `.tar.bz2`. Zig's stdlib has
///     no bzip2, so the install path uses BoxWallet's own pure-Zig bzip2 decoder
///     (`install`/`bzip2.zig`). Windows ships a `.zip` (streamed normally). Every
///     bundle wraps its binaries in a versioned `nerva-<os>-<arch>-v<ver>/` dir
///     (no `bin/` subdir); the daemon/cli are promoted out and the rest dropped.
///   * **RPC** — Monero's daemon RPC, not the bitcoin JSON-RPC. `get_info` is a
///     `POST /json_rpc` method returning a flat result; sync is derived from
///     `height` vs `target_height` (0 once caught up) and the `synchronized` flag,
///     and the peer count from the connection counts. Shutdown is the direct
///     `POST /stop_daemon` endpoint. The daemon is unauthenticated by default, so
///     no basic auth is sent (mirrors Ergo's keyless REST).
pub const Nerva = struct {
    /// Whether the coin is exposed in the nav. False keeps it out of the left
    /// bar entirely (registered but hidden) until it's ready for users.
    pub const live = true;
    pub const coin_name = "Nerva";
    pub const coin_name_abbrev = "XNV";
    /// One-line description shown under the coin name on the detail pane.
    pub const coin_description = "ASIC-resistant, CPU-mined private CryptoNote coin.";
    /// Nerva brand colour (`#RRGGBB`), for tinting the coin in the frontend.
    pub const coin_color = "#344769";
    /// This coin's id on the price host, for the USD quote beside its
    /// balance (see `src/price.zig`).
    pub const price_id = "nerva";
    /// Donation address for BoxWallet development, in Nerva's own
    /// currency.
    /// TODO(richard): replace with the real XNV tip address.
    pub const tip_address = "NV1TQhxgTQQPFKMsU7JRj3Xk7C93CYhsA46M7wGdsQiBa1VPNCKv4Wjgeez1rs9Qw4WPymdT3b6N1hgRKJ9ZmzK82Ks6gauZn";
    /// Nerva is proof-of-work (CPU-mined, Monero-derived) — no wallet staking.
    pub const proof_of_stake = false;
    pub const conf_file = "nerva.conf";

    // Data dir names. Monero forks use `~/.<name>` on Linux *and* macOS (not the
    // macOS Library convention) and `%APPDATA%\<name>` on Windows — exactly what
    // the shared `conf.dataDir(posix, win)` produces.
    pub const home_dir = ".nerva";
    pub const home_dir_win = "nerva";
    /// macOS data dir name. `null` means macOS uses the **POSIX** path
    /// (`~/.nerva`) rather than a `Library/Application Support`
    /// dir — Monero and its forks are explicit that it's "Unix & Mac:
    /// ~/.CRYPTONOTE_NAME", unlike the bitcoin-derived coins. Not an oversight:
    /// pointing this at a Library dir would orphan an existing wallet on macOS.
    pub const home_dir_mac: ?[]const u8 = null;

    /// Unauthenticated by default; a value is kept only so the shared conf/readAuth
    /// path has a username to write (the daemon ignores it).
    pub const rpc_default_username = "nervarpc";
    pub const rpc_default_port = "17566";
    pub const core_version = "0.3.0.0";

    // Binary names. Windows appends `.exe`. The wallet CLI is `nerva-wallet-cli`;
    // there's no `*-tx` helper. `nerva-wallet-rpc` drives the (external) wallet —
    // BoxWallet launches it alongside the daemon for create/restore/balance (see
    // the external-wallet section below), so it's promoted too.
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    pub const daemon_file = "nervad" ++ exe_suffix;
    pub const cli_file = "nerva-wallet-cli" ++ exe_suffix;
    pub const wallet_rpc_file = "nerva-wallet-rpc" ++ exe_suffix;

    /// Port BoxWallet binds the managed `nerva-wallet-rpc` to (localhost only).
    /// Must avoid the daemon's reserved ports: P2P 17565, RPC 17566, and — easy to
    /// miss — the **ZMQ-RPC** server at `rpc-bind-port + 1` = 17567 (Monero/Nerva
    /// bind it by default). Colliding there makes *nervad* fail to start ("ZMQ RPC
    /// Server bind failed: Address already in use") and die, so the wallet port is
    /// moved well clear.
    pub const wallet_rpc_port = "18566";

    /// The single managed wallet's filename, inside the wallet dir. Fixed so
    /// `walletExists` is a pure disk check and every wallet-RPC call targets the
    /// same file by name.
    const wallet_name = "BoxWallet";

    /// Nerva inherits Monero's 12-decimal atomic unit
    /// (`CRYPTONOTE_DISPLAY_DECIMAL_POINT = 12`, verified against
    /// nerva-project/nerva `cryptonote_config.h`): the wallet RPC reports balances
    /// as integer atomic units, so divide by this to get whole XNV.
    const atomic_per_xnv: f64 = 1_000_000_000_000;

    /// A Nerva (Monero) deterministic restore seed is exactly 25 words.
    pub const seed_word_count = 25;

    const release_base = "https://github.com/nerva-project/nerva/releases/download/v" ++ core_version ++ "/";

    // The per-target bundle "stem" (also the versioned wrapper dir inside the
    // archive) and its format. Mirrors Nerva's release asset names. macOS and
    // Linux ship `.tar.bz2`; Windows ships `.zip`. Arch tags follow Nerva's own
    // naming (`armv8`/`armv7`/`x86_64`/`x64`).
    const Bundle = struct { stem: []const u8, format: install_mod.Format };
    const bundle: ?Bundle = switch (builtin.os.tag) {
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => .{ .stem = "nerva-linux-x86_64-v" ++ core_version, .format = .tar_bz2 },
            .aarch64 => .{ .stem = "nerva-linux-armv8-v" ++ core_version, .format = .tar_bz2 },
            .arm => .{ .stem = "nerva-linux-armv7-v" ++ core_version, .format = .tar_bz2 },
            else => null,
        },
        .macos => switch (builtin.cpu.arch) {
            .x86_64 => .{ .stem = "nerva-macos-x64-v" ++ core_version, .format = .tar_bz2 },
            .aarch64 => .{ .stem = "nerva-macos-armv8-v" ++ core_version, .format = .tar_bz2 },
            else => null,
        },
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => .{ .stem = "nerva-windows-x64-v" ++ core_version, .format = .zip },
            else => null,
        },
        else => null,
    };

    /// The download URL + format for the build target, or null where Nerva
    /// publishes no matching binary (e.g. Linux i686, FreeBSD, Windows x86).
    const download: ?install_mod.Download = if (bundle) |b| .{
        .url = release_base ++ b.stem ++ (if (b.format == .zip) ".zip" else ".tar.bz2"),
        .format = b.format,
    } else null;

    // The versioned wrapper dir the bundle extracts to (the stem). Binaries sit
    // directly inside it, so `bin_subdir` is empty. "" when this target has no
    // bundle (download is null and install bails before using it).
    const extracted_dir = if (bundle) |b| b.stem else "";
    const bin_subdir = "";
    const promote_files = [_][]const u8{ daemon_file, cli_file, wallet_rpc_file };

    // Scratch file the bundle streams to (unique to Nerva). For `.tar.bz2` the
    // installer derives a sibling `.tar` from this name during decompression.
    pub const scratch_file = ".boxwallet-nerva.part";

    /// Quicksync block-hash file. Nerva publishes a `quicksync.raw` (~130 MB)
    /// alongside each release: a precomputed set of the chain's block hashes.
    /// `nervad --quicksync <file>` validates blocks against these during the
    /// initial sync instead of hashing every block itself, cutting a from-scratch
    /// sync from hours to ~20 minutes. It's a pure *accelerator* — it never rewrites
    /// the local DB — so it's safe to keep passing once caught up (the daemon simply
    /// has nothing left to fast-validate). It's plain chain data, identical across
    /// platforms, so unlike the binary bundle it isn't gated on the build target;
    /// it lives at the same release base as the binaries.
    pub const quicksync_file = "quicksync.raw";
    const quicksync_url = release_base ++ quicksync_file;

    /// Build the type-erased `Coin` handle for this instance.
    pub fn coin(self: *Nerva) Coin {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // --- RPC (Monero daemon) ---------------------------------------------

    /// Subset of `get_info`'s result. Monero reports a flat object; `synchronized`
    /// is authoritative for sync state, with `height`/`target_height` as the
    /// fallback (`target_height` is 0 once caught up). Defaults keep the parse
    /// resilient to omitted fields.
    const NervaInfo = struct {
        status: []const u8 = "",
        height: i64 = 0,
        target_height: i64 = 0,
        outgoing_connections_count: i64 = 0,
        incoming_connections_count: i64 = 0,
        synchronized: bool = false,
        mainnet: bool = false,
        testnet: bool = false,
        stagenet: bool = false,
        /// The daemon's own version, e.g. "0.3.0.0-release". Present on 0.3.0.0; the
        /// older 0.2.2.0 omits it, hence the default — an empty value just means the
        /// offline binary probe (`probeInstalledVersion`) remains the version source.
        version: []const u8 = "",
    };

    /// Bound (ms) on a status/stop RPC round-trip. A healthy nervad answers
    /// `get_info` in milliseconds, but a *busy* one — its RPC reply stalled behind
    /// the blockchain lock while it relays across dozens of peers — can take many
    /// seconds, accepting the connection yet not replying. This cap keeps such a
    /// stall from hanging the poll worker (and, through it, the app's quit). It's
    /// deliberately short because liveness no longer rides on this call: a poll
    /// that times out here still detects the daemon as up via the cheap connect
    /// probe (`rpc.daemonReachable`), so the UI shows "running" rather than
    /// "stopped" — the only cost of a timeout is that fresh sync numbers wait for
    /// the next poll once the daemon frees up.
    const status_timeout_ms: u32 = 3000;

    /// Bound (ms) on a wallet-RPC op. A Monero wallet open/create/restore drives an
    /// initial refresh that can legitimately take many seconds, so these get a far
    /// longer cap than the status path — still bounded so a hung wallet service
    /// can't wedge the worker.
    const wallet_timeout_ms: u32 = 60_000;

    /// Budget (ms) to wait for `nerva-wallet-rpc` to become ready — i.e. answer an
    /// authenticated request — before the first wallet op. The service is spawned
    /// detached (see `app.zig`'s `ensureWalletRpc`) and returns immediately, so a
    /// create/restore/open fired straight after can race its startup and get a
    /// spurious `AuthFailed`. Gating on `rpc.moneroWalletReady` closes that window.
    /// Matches the wallet-service wait budget the launch-with-password path uses.
    const wallet_ready_timeout_ms: u32 = 25_000;

    /// Fetch + parse `get_info`. Caller must `deinit` the returned `Parsed`.
    fn fetchInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !std.json.Parsed(models.JsonRpcResponse(NervaInfo)) {
        const raw = try rpc.moneroPost(allocator, auth, "/json_rpc", "{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"get_info\"}", status_timeout_ms);
        defer allocator.free(raw);
        return std.json.parseFromSlice(
            models.JsonRpcResponse(NervaInfo),
            allocator,
            raw,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
    }

    /// Nerva's block-target interval (seconds). A CryptoNote 60-second block —
    /// ~4.3M blocks since the 2018 launch confirm the cadence. Used only to turn
    /// the block gap into a "behind by" estimate; the daemon never reports a tip
    /// timestamp we could use directly.
    const block_target_seconds: i64 = 60;

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
    /// total connections; Nerva is proof-of-work, so `staking_active` is false.
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
            // build suffix is dropped so this lines up with the pinned `core_version`.
            // Empty on a pre-0.3.0.0 daemon, which reports no version at all — the UI
            // then falls back to the marker the binary probe stamped.
            .version = try allocator.dupe(u8, models.trimBuildSuffix(r.version)),
        };
    }

    /// Ask nervad to shut down via Monero's direct `POST /stop_daemon` (not a
    /// `/json_rpc` method).
    pub fn requestStop(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        const reply = try rpc.moneroPost(allocator, auth, "/stop_daemon", "{}", status_timeout_ms);
        allocator.free(reply);
    }

    // --- Mining (in-daemon CPU miner) -------------------------------------
    //
    // Nerva is CPU-mined and nervad carries the miner in-process, driven over
    // Monero's *direct* daemon endpoints (`/mining_status`, `/start_mining`,
    // `/stop_mining` — bare JSON objects with a `status` field, not `/json_rpc`
    // methods; the same transport as `/stop_daemon`). The payout address is the
    // managed wallet's own receive address, supplied by the frontend.

    /// Subset of `/mining_status`'s reply. Defaults keep the parse resilient to
    /// fields an older vintage omits.
    const MiningStatusReply = struct {
        status: []const u8 = "",
        active: bool = false,
        speed: u64 = 0,
        threads_count: u32 = 0,
    };

    /// The bare `{ "status": … }` reply shape of `/start_mining`/`/stop_mining`
    /// — anything but "OK" is the daemon refusing.
    const StatusReply = struct { status: []const u8 = "" };

    /// Live `/mining_status`, normalized. Threads/speed are zeroed when the
    /// miner is idle so a stale last-run figure can't read as current.
    pub fn miningStatus(allocator: std.mem.Allocator, auth: models.CoinAuth) !models.MiningStatus {
        const raw = try rpc.moneroPost(allocator, auth, "/mining_status", "{}", status_timeout_ms);
        defer allocator.free(raw);
        const parsed = try std.json.parseFromSlice(MiningStatusReply, allocator, raw, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        return mapMiningStatus(parsed.value);
    }

    /// `/mining_status` reply → normalized model. Pure, so it's unit-testable
    /// without a daemon.
    fn mapMiningStatus(r: MiningStatusReply) models.MiningStatus {
        return .{
            .active = r.active,
            .threads = if (r.active) r.threads_count else 0,
            .speed = if (r.active) r.speed else 0,
        };
    }

    /// The `/start_mining` request body: rewards to `address`, `threads` CPU
    /// threads, and plain foreground mining — no background/battery heuristics
    /// (BoxWallet targets always-on machines, and the user asked for exactly
    /// this many threads). `mining_affinity` (nervad 0.3.0.0's `KV_SERIALIZE_OPT`
    /// field, off by default) is set so each miner thread is pinned to its own
    /// CPU core — steadier hashrate on the low-spec, dedicated boxes we target.
    /// Split out from `startMining` so it's unit-testable. Caller owns the
    /// returned slice.
    fn startMiningParams(allocator: std.mem.Allocator, address: []const u8, threads: u32) ![]u8 {
        const qaddr = try rpc.jsonQuote(allocator, address);
        defer allocator.free(qaddr);
        return std.fmt.allocPrint(
            allocator,
            "{{\"miner_address\":{s},\"threads_count\":{d},\"do_background_mining\":false,\"ignore_battery\":true,\"mining_affinity\":true}}",
            .{ qaddr, threads },
        );
    }

    /// Ask nervad to start mining. A daemon-side refusal is surfaced as a
    /// specific error, not swallowed (see `expectStatusOk`).
    pub fn startMining(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        address: []const u8,
        threads: u32,
    ) !void {
        const body = try startMiningParams(allocator, address, threads);
        defer allocator.free(body);
        const raw = try rpc.moneroPost(allocator, auth, "/start_mining", body, status_timeout_ms);
        defer allocator.free(raw);
        try expectStatusOk(allocator, raw, error.MiningStartRejected);
    }

    /// Ask nervad to stop mining.
    pub fn stopMining(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        const raw = try rpc.moneroPost(allocator, auth, "/stop_mining", "{}", status_timeout_ms);
        defer allocator.free(raw);
        try expectStatusOk(allocator, raw, error.MiningStopRejected);
    }

    /// Check a direct-endpoint reply's `status`: "OK" passes, "BUSY" (the
    /// daemon is still syncing — mining can't start yet) gets its own error so
    /// the user is told to wait rather than shown a generic failure, and
    /// anything else maps to `reject`.
    fn expectStatusOk(allocator: std.mem.Allocator, raw: []const u8, reject: anyerror) !void {
        const parsed = try std.json.parseFromSlice(StatusReply, allocator, raw, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (std.mem.eql(u8, parsed.value.status, "OK")) return;
        if (std.ascii.eqlIgnoreCase(parsed.value.status, "BUSY")) return error.DaemonStillSyncing;
        return reject;
    }

    // --- Files / paths ---------------------------------------------------

    /// The daemon's default data directory (`~/.nerva`, `%APPDATA%\nerva` on
    /// Windows), where `nerva.conf` and the chain live.
    pub fn dataDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        return conf.dataDir(allocator, home, home_dir, home_dir_win, home_dir_mac);
    }

    /// True if `nervad` (`nervad.exe` on Windows) is already present under
    /// `install_root`.
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, daemon_file);
    }

    /// Ask the installed `nervad` its version by running `nervad --version`, whose
    /// banner reads `NERVA 'Legacy Reborn' (v0.2.2.0-51ae77bda)`.
    ///
    /// Nerva's `get_info` carries no `version` field, so the daemon can never stamp a
    /// version marker over RPC the way the bitcoin forks do. Without this probe a
    /// pre-marker install reads as *up to date* forever — no update badge, and `u`
    /// does nothing — which is exactly how a v0.2.2.0 daemon sat silently through the
    /// v0.3.0.0 (Hard Fork 13) release. The probe also works with the daemon stopped,
    /// and with its RPC wedged behind the blockchain lock mid-sync, which is when
    /// this coin most needs answering.
    ///
    /// Caller owns the returned version string.
    fn probeInstalledVersion(allocator: std.mem.Allocator, install_root: []const u8) anyerror![]const u8 {
        return install_mod.probeBinaryVersion(allocator, install_root, daemon_file, ".nervad.probe");
    }

    /// Download + unpack the Nerva daemon files into `install_root`.
    ///
    /// Streams the bundle to disk (a `.tar.bz2` via the pure-Zig bzip2 decoder, or
    /// a `.zip`), then `promoteAndTidy` lifts `nervad`/`nerva-wallet-cli` out of
    /// the versioned wrapper (binaries are directly inside it, so `bin_subdir` is
    /// empty) and removes the wrapper.
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

    /// Download `quicksync.raw` into `install_root` so the next daemon start can
    /// fast-sync (see `daemonArgv` and the `sync_accelerator` capability). Streamed
    /// straight to disk like any other download — flat memory regardless of the
    /// file's ~130 MB. This is the opt-in path: it runs only when the user accepts
    /// the QuickSync prompt at daemon start, so its failure *is* surfaced (the user
    /// asked for it) — but a *partial* file would be fed to nervad as if complete,
    /// so any leftover is removed before the error propagates.
    fn quicksyncDownload(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        _: []const u8,
        progress: ?install_mod.Progress,
        // QuickSync is ~130 MB and not resumable, so there is nothing to pause
        // into: a stop just means the next attempt starts over.
        _: ?install_mod.Cancel,
    ) anyerror!void {
        install_mod.downloadFile(allocator, quicksync_url, install_root, quicksync_file, progress) catch |err| {
            deleteQuicksync(allocator, install_root);
            return err;
        };
    }

    /// Whether to offer QuickSync before launching nervad: only when the chain
    /// hasn't reached a full sync yet (no `quicksync.done` marker — see
    /// `vtOnSynced`) *and* the file isn't already present (a prior opt-in still
    /// mid-sync, which `daemonArgv` picks up without re-prompting). A pure disk
    /// check, so it runs with the daemon down.
    fn quicksyncShouldOffer(allocator: std.mem.Allocator, install_root: []const u8, _: []const u8) bool {
        if (syncedMarkerExists(allocator, install_root)) return false;
        if (quicksyncExists(allocator, install_root)) return false;
        return true;
    }

    /// The sync-accelerator capability wired into the vtable. `app.zig` calls
    /// `should_offer` before a daemon start and, on the user's yes, runs `download`
    /// on a worker thread, then launches (where `daemonArgv` passes `--quicksync`).
    pub const sync_accelerator: Coin.SyncAccelerator = .{
        .name = "QuickSync",
        .prompt_detail = "Download ~130 MB of precomputed block hashes to sync in ~20 min instead of hours.",
        .should_offer = quicksyncShouldOffer,
        .download = quicksyncDownload,
    };

    /// Marker file written once the chain first reaches a full sync, so QuickSync is
    /// no longer offered on later starts (the heavy lifting is done). It outlives the
    /// quicksync file, which is deleted at the same moment.
    pub const quicksync_done_file = "quicksync.done";

    /// True once the full-sync marker has been written into `install_root`.
    fn syncedMarkerExists(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, quicksync_done_file);
    }

    /// Record that the chain reached a full sync (best-effort). Leaves the marker so
    /// `quicksyncShouldOffer` returns false from now on.
    fn writeSyncedMarker(allocator: std.mem.Allocator, install_root: []const u8) void {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var dir = std.Io.Dir.cwd().openDir(io, install_root, .{}) catch return;
        defer dir.close(io);
        dir.writeFile(io, .{ .sub_path = quicksync_done_file, .data = "synced\n" }) catch {};
    }

    /// True once `quicksync.raw` has been fetched into `install_root`.
    fn quicksyncExists(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, quicksync_file);
    }

    /// Remove a (possibly partial) `quicksync.raw` from `install_root`. Best-effort:
    /// a missing file is fine, and a failure just leaves the next start to fall back
    /// to a normal sync.
    fn deleteQuicksync(allocator: std.mem.Allocator, install_root: []const u8) void {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var dir = std.Io.Dir.cwd().openDir(io, install_root, .{}) catch return;
        defer dir.close(io);
        dir.deleteFile(io, quicksync_file) catch {};
    }

    /// Remove the `._<wrapper>` AppleDouble sibling that Nerva's macOS-built
    /// tarballs carry at the archive root (the matching ones inside the wrapper go
    /// with it when `promoteAndTidy` drops the tree). Best-effort; no-op on the
    /// Windows zip, which has no such files.
    fn cleanupAppleDouble(allocator: std.mem.Allocator, install_root: []const u8) void {
        if (builtin.os.tag == .windows) return;
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var dir = std.Io.Dir.cwd().openDir(io, install_root, .{}) catch return;
        defer dir.close(io);
        dir.deleteFile(io, "._" ++ extracted_dir) catch {};
    }

    /// The canonical `nerva.conf` body. nervad parses this on startup (its
    /// `--config-file` defaults to `<data-dir>/nerva.conf`), so it must contain
    /// only Monero-style options. `rpc-bind-port` is the default RPC port stated
    /// explicitly so it's self-documenting and survives any upstream default change.
    const conf_body = "rpc-bind-port=" ++ rpc_default_port ++ "\n";

    /// Ensure the data dir and `nerva.conf` exist so the status poll's `readAuth`
    /// (which needs the conf present) succeeds.
    ///
    /// Unlike the bitcoin coins, nervad *reads* this file on every startup. The
    /// shared `conf.populate` writes bitcoin keys (`rpcuser`, `server`, …) that
    /// Monero's parser rejects outright (`unrecognised option 'rpcuser'`), so
    /// nervad exits before its RPC ever comes up — which looked like an
    /// unstoppable daemon. So we (over)write the canonical Monero conf instead.
    /// The clobbering write is deliberate: BoxWallet owns this conf and a stale
    /// bitcoin-style one is actively harmful, so prepare is self-healing. The
    /// `rpc-bind-port` is also nervad's default; `readAuth` doesn't recognise that
    /// key and falls back to its defaults (`rpc_default_port`, unauthenticated),
    /// which already match, so the poll/stop path is unaffected.
    pub fn prepareConf(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        try conf.writeConf(io, data_dir, conf_file, conf_body);
    }

    /// Nerva's daemon runs in the foreground of its own process, so it's spawned
    /// detached (with `--non-interactive`) and the status poll confirms it came up
    /// — never the bitcoin `-daemon` fork path.
    pub fn launchMode() Coin.LaunchMode {
        return .foreground;
    }

    /// The daemon's log file under the data dir, whose tail is read for a
    /// startup-failure reason when the daemon dies without saying why on stderr.
    pub fn daemonLogFile() []const u8 {
        return "nerva.log";
    }

    /// The stage nervad is at while it starts, read from `nerva.log` — its RPC
    /// server comes up last, so the log is the only source for the whole
    /// start-up. Shared epee wording; see `warmup.epeeStage`.
    ///
    /// Unlike the rest of the family this only works because `daemonArgv` asks
    /// for it: NERVA's default log categories are
    /// `*:ERROR,…,user:INFO`, which drop the `global:INFO` lines these markers
    /// live on, leaving a completely silent start.
    pub fn warmupStageFromLog(tail: []const u8) []const u8 {
        return warmup.epeeStage(tail);
    }

    /// The log categories nervad is started with, so its start-up is visible.
    ///
    /// NERVA's built-in default is `*:ERROR,net:FATAL,…,user:INFO`, which drops
    /// the `global:INFO` category the init lines are written on — a start logs
    /// literally nothing between the banner and "the daemon will start
    /// synchronizing", so `warmupStageFromLog` would have nothing to read. This
    /// asks for that one category back on top of NERVA's own defaults, verbatim,
    /// so nothing it chose to log (or chose to silence) changes — the log stays as
    /// quiet as NERVA intended, with one category added.
    ///
    /// Verified against nervad v0.3.0.0: `--log-level` takes a category string as
    /// well as a number, and this one yields the full init sequence
    /// (`Initializing core…` → `Loading blockchain from folder …` → `Loading
    /// checkpoints` → `Core initialized OK` → p2p → RPC).
    const log_categories = "*:ERROR,net:FATAL,net.http:FATAL,net.p2p:FATAL," ++
        "net.cn:FATAL,user:INFO,verify:FATAL,stacktrace:INFO,logging:INFO," ++
        "msgwriter:INFO,global:INFO";

    /// `nervad --non-interactive` (so it runs as a server rather than opening its
    /// interactive console) with `--log-level <log_categories>` (see above), plus
    /// `--quicksync <file>` when the quicksync block-hash
    /// file is present (fetched at install) so the first sync is fast. Passing
    /// `--quicksync` once already caught up is harmless — it only ever skips
    /// recomputing hashes the daemon already has — so it's keyed purely off the file
    /// existing, with no sync-state check. Caller owns the returned slice and its
    /// strings.
    pub fn daemonArgv(allocator: std.mem.Allocator, install_root: []const u8, _: []const u8) ![]const []const u8 {
        const path = try std.fs.path.join(allocator, &.{ install_root, daemon_file });
        errdefer allocator.free(path);

        if (quicksyncExists(allocator, install_root)) {
            const qs_path = try std.fs.path.join(allocator, &.{ install_root, quicksync_file });
            errdefer allocator.free(qs_path);
            const argv = try allocator.alloc([]const u8, 6);
            argv[0] = path;
            argv[1] = try allocator.dupe(u8, "--non-interactive");
            argv[2] = try allocator.dupe(u8, "--log-level");
            argv[3] = try allocator.dupe(u8, log_categories);
            argv[4] = try allocator.dupe(u8, "--quicksync");
            argv[5] = qs_path;
            return argv;
        }

        const argv = try allocator.alloc([]const u8, 4);
        argv[0] = path;
        argv[1] = try allocator.dupe(u8, "--non-interactive");
        argv[2] = try allocator.dupe(u8, "--log-level");
        argv[3] = try allocator.dupe(u8, log_categories);
        return argv;
    }

    // --- External wallet (Monero wallet-rpc) -----------------------------
    //
    // Nerva's wallet lives in a *separate* process (`nerva-wallet-rpc`), not the
    // daemon. BoxWallet launches it bound to localhost:`wallet_rpc_port`, keyless
    // (`--disable-rpc-login`, mirroring the daemon's open RPC), pointed at the
    // local daemon, and drives create/restore/open/balance over Monero's wallet
    // `POST /json_rpc`. All funds-sensitive: a wallet is only ever created with a
    // user-supplied password, never silently. See `coin.zig`'s `ExternalWallet`.

    /// The managed wallet directory (`<datadir>/wallets`), where `nerva-wallet-rpc`
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

    /// argv to spawn `nerva-wallet-rpc`, bound to `port` on localhost and pointed
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
    /// `password`. v1 does a full rescan (`restore_height` 0); a restore-height
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

        // Nerva's bundled wallet-rpc is an older Monero that has no
        // `restore_deterministic_wallet` method ("Method not found"), so the wallet
        // is materialized on disk by a one-shot `nerva-wallet-cli
        // --generate-from-json` and then opened over RPC like any other wallet.
        try cliGenerateFromSeed(allocator, install_root, home, password, normalized, detail);
        try walletOpen(allocator, wallet_auth, password, detail);
    }

    /// Restore the managed wallet from `seed` by driving a one-shot
    /// `nerva-wallet-cli --generate-from-json`: the CLI reads the
    /// seed/password/filename from a temporary JSON spec and writes
    /// `BoxWallet`(+`.keys`) into the wallet dir, `--offline` so it never blocks on
    /// a chain sync. The spec carries the secret in plaintext, so it's overwritten
    /// and deleted the instant the call returns. Success is the `.keys` file
    /// appearing on disk — the CLI's exit code is unreliable across Monero vintages,
    /// so on failure its own stderr/stdout is surfaced as the reason.
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
            detail.set(if (why.len > 0) why else "nerva-wallet-cli did not create the wallet");
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
    /// message; matching either is robust across fork/vintage wording changes.
    fn walletIsClosed(err: ?RpcErrObj) bool {
        const e = err orelse return false;
        return e.code == -13 or containsIgnoreCase(e.message, "no wallet");
    }

    /// Map Monero atomic balances to the normalized `WalletBalance`. Pure, so it's
    /// unit-testable without a wallet process.
    fn atomicToBalance(balance: u64, unlocked: u64) models.WalletBalance {
        return .{
            .total = @as(f64, @floatFromInt(balance)) / atomic_per_xnv,
            .available = @as(f64, @floatFromInt(unlocked)) / atomic_per_xnv,
        };
    }

    /// Blocks of slack below the daemon tip within which the wallet counts as
    /// "caught up". Steady-state, the wallet can trail the tip by a block between
    /// the wallet-rpc's periodic auto-refreshes; this margin keeps that from
    /// flickering the "Rescanning…" readout. A genuine restore rescans from height 0
    /// (millions of blocks), so the margin never hides real progress.
    const rescan_done_slack: i64 = 4;

    /// Report how far the wallet's background refresh has scanned a freshly restored
    /// wallet, so the UI can show "Rescanning… X%". `nerva-wallet-rpc` auto-refreshes
    /// an open wallet in the background (see `walletRestoreSeed` — no blocking
    /// refresh is issued), advancing its `get_height` as it goes. The scanned height
    /// is that wallet height (`wallet_auth`); the target is the daemon's chain tip
    /// from `get_info` (`daemon_auth`) — wallet and daemon are separate processes, so
    /// both auths are needed. Returns null when the wallet is within
    /// `rescan_done_slack` of the tip (caught up) or a height isn't known yet, which
    /// clears the indicator. Best-effort: a read error leaves the poll's last value.
    fn walletRescanProgress(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        daemon_auth: models.CoinAuth,
    ) anyerror!?models.RescanProgress {
        var info = try fetchInfo(allocator, daemon_auth);
        defer info.deinit();
        const di = info.value.result orelse return null;
        const tip = @max(di.target_height, di.height);
        // `walletChainHeight` is best-effort and returns 0 when the wallet-rpc can't
        // answer (e.g. no wallet open) — treat that as "nothing to show".
        const scanned = walletChainHeight(allocator, wallet_auth);
        if (scanned <= 0) return null;
        return rescanFrom(scanned, tip);
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
    // These ride the same `nerva-wallet-rpc` process as balance, so the app
    // hands them the wallet endpoint (`extWalletAuth`) and polls them only
    // once the wallet is open.

    /// One `get_transfers` entry (the subset BoxWallet uses). `confirmations`
    /// is absent on Nerva's older wallet-rpc vintage (defaults 0), in which
    /// case it's derived from the wallet height. A coinbase (mined) credit
    /// arrives in the `in` bucket with `type == "block"`.
    const TransferEntry = struct {
        amount: u64 = 0,
        timestamp: i64 = 0,
        height: i64 = 0,
        confirmations: i64 = 0,
        type: []const u8 = "",
        txid: []const u8 = "",
    };

    /// `get_transfers` groups entries by state; direction falls out of the
    /// bucket (`in` received, `out`/`pending` sent, `pool` incoming-unconfirmed).
    const GetTransfersResult = struct {
        in: []TransferEntry = &.{},
        out: []TransferEntry = &.{},
        pending: []TransferEntry = &.{},
        pool: []TransferEntry = &.{},
    };
    const HeightResult = struct { height: i64 = 0 };
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
        var parsed = try walletCall(GetTransfersResult, allocator, wallet_auth, "get_transfers", "{\"in\":true,\"out\":true,\"pending\":true,\"pool\":true}");
        defer parsed.deinit();
        const r = parsed.value.result orelse return error.EmptyRpcResult;

        // Wallet height, to derive confirmations for entries the older
        // wallet-rpc reports without a confirmations field. Best-effort — an
        // unavailable height just leaves those rows at 0 confirmations.
        const tip = walletChainHeight(allocator, wallet_auth);
        return mapTransfers(allocator, r, tip, limit);
    }

    /// The wallet's synced chain height, trying the newer `get_height` name
    /// first and the original `getheight` for older vintages. 0 when neither
    /// answers (best-effort — used only for the confirmations fallback).
    fn walletChainHeight(allocator: std.mem.Allocator, wallet_auth: models.CoinAuth) i64 {
        inline for (.{ "get_height", "getheight" }) |method| {
            if (walletCall(HeightResult, allocator, wallet_auth, method, "{}")) |parsed| {
                var p = parsed;
                defer p.deinit();
                if (p.value.result) |h| {
                    if (h.height > 0) return h.height;
                }
            } else |_| {}
        }
        return 0;
    }

    /// Flatten the four `get_transfers` buckets into normalized `WalletTx`es,
    /// newest-first, capped at `limit`. Split out from `walletTransactions` so
    /// the mapping/ordering is unit-testable without a wallet process.
    fn mapTransfers(allocator: std.mem.Allocator, r: GetTransfersResult, tip: i64, limit: usize) ![]models.WalletTx {
        const total = r.in.len + r.out.len + r.pending.len + r.pool.len;
        const all = try allocator.alloc(models.WalletTx, total);
        defer allocator.free(all);
        var n: usize = 0;
        for (r.in) |e| {
            // A coinbase credit (type "block") was minted by the wallet itself.
            const direction: models.TxDirection = if (std.mem.eql(u8, e.type, "block")) .stake else .received;
            all[n] = mapEntry(e, direction, tip);
            n += 1;
        }
        for (r.out) |e| {
            all[n] = mapEntry(e, .sent, tip);
            n += 1;
        }
        for (r.pending) |e| {
            all[n] = mapEntry(e, .sent, tip);
            n += 1;
        }
        for (r.pool) |e| {
            all[n] = mapEntry(e, .received, tip);
            n += 1;
        }
        std.mem.sort(models.WalletTx, all[0..n], {}, newerFirst);

        const out = try allocator.alloc(models.WalletTx, @min(n, limit));
        @memcpy(out, all[0..out.len]);
        return out;
    }

    /// One entry → the normalized row. Confirmations prefer the entry's own
    /// field; a vintage that omits it falls back to `tip − height` (0 for a
    /// pool/pending entry, whose height is 0).
    fn mapEntry(e: TransferEntry, direction: models.TxDirection, tip: i64) models.WalletTx {
        const confs = if (e.confirmations > 0)
            e.confirmations
        else if (e.height > 0 and tip > e.height)
            tip - e.height
        else
            0;
        var tx: models.WalletTx = .{
            .direction = direction,
            .amount = @as(f64, @floatFromInt(e.amount)) / atomic_per_xnv,
            .time = e.timestamp,
            .confirmations = confs,
        };
        // Copied into the row's own buffer — `e` points into the parsed reply,
        // which is freed before the row is shown.
        tx.setTxid(e.txid);
        return tx;
    }

    /// Sort helper: newest (largest timestamp) first.
    fn newerFirst(_: void, lhs: models.WalletTx, rhs: models.WalletTx) bool {
        return lhs.time > rhs.time;
    }

    /// The open wallet's receive address (`get_address`, account 0). CryptoNote
    /// stealth addressing keeps a reused address private, so the main address
    /// is the stable "current" one; an explicit user-requested rotation asks
    /// for a fresh subaddress (`create_address`) — on a vintage that predates
    /// subaddresses the error propagates and the UI keeps the current address.
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

    /// Send `amount` XNV to `address` via the wallet RPC `transfer`. The wallet
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
            "{{\"destinations\":[{{\"amount\":{d},\"address\":{s}}}],\"get_tx_key\":true}}",
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

    /// Convert a user-entered XNV amount to integer atomic units (rounded to
    /// the nearest atomic). Null for anything unusable — non-finite,
    /// non-positive, or too large for u64 — so a bad amount is rejected before
    /// any RPC.
    fn atomicFromAmount(amount: f64) ?u64 {
        if (!std.math.isFinite(amount) or amount <= 0) return null;
        const scaled = @round(amount * atomic_per_xnv);
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
    /// kills `nerva-wallet-rpc` first — releasing the file locks — and leaves nervad
    /// (and its sync) running; the next create/restore re-creates the dir. Idempotent
    /// — a missing dir is fine; `deleteTree` holds nothing in memory beyond a path.
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

    const vtable: Coin.VTable = .{
        .coin_name = vtCoinName,
        .coin_name_abbrev = vtCoinNameAbbrev,
        .coin_description = vtCoinDescription,
        .coin_color = vtCoinColor,
        .tip_address = vtTipAddress,
        .price_id = vtPriceId,
        .core_version = vtCoreVersion,
        .proof_of_stake = vtProofOfStake,
        .balance_decimals = vtBalanceDecimals,
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
        .warmup_stage_from_log = vtWarmupStageFromLog,
        .daemon_argv = vtDaemonArgv,
        .request_stop = vtRequestStop,
        .wallet_transactions = vtWalletTransactions,
        .wallet_receive_address = vtWalletReceiveAddress,
        .wallet_send = vtWalletSend,
        .mining_status = vtMiningStatus,
        .mining_start = vtMiningStart,
        .mining_stop = vtMiningStop,
        .external_wallet = &external_wallet,
        .on_synced = vtOnSynced,
        .sync_accelerator = &sync_accelerator,
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

    // The mining trio rides the *daemon's* endpoint (the miner lives in
    // nervad), so `app.zig` passes the daemon auth — never the wallet's.
    fn vtMiningStatus(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) anyerror!models.MiningStatus {
        return miningStatus(allocator, auth);
    }
    fn vtMiningStart(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        address: []const u8,
        threads: u32,
    ) anyerror!void {
        return startMining(allocator, auth, address, threads);
    }
    fn vtMiningStop(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) anyerror!void {
        return stopMining(allocator, auth);
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
    fn vtPriceId(_: *anyopaque) []const u8 {
        return price_id;
    }
    fn vtCoreVersion(_: *anyopaque) []const u8 {
        return core_version;
    }
    fn vtProofOfStake(_: *anyopaque) bool {
        return proof_of_stake;
    }
    /// Nerva inherits Monero's 12-decimal atomic unit (see `atomic_per_xnv`).
    fn vtBalanceDecimals(_: *anyopaque) u8 {
        return 12;
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
    fn vtWarmupStageFromLog(_: *anyopaque, tail: []const u8) []const u8 {
        return warmupStageFromLog(tail);
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
    fn vtOnSynced(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        install_root: []const u8,
        _: []const u8,
    ) anyerror!void {
        // The sync is done, so (1) mark it so QuickSync is never offered again for
        // this install, and (2) drop the ~130 MB quicksync file to reclaim the disk
        // and stop `daemonArgv` passing `--quicksync` on later starts. The delete is
        // safe even though the running daemon was launched with the file — it's
        // finished consuming it by the time the chain reads as synced (and on POSIX
        // an unlink leaves the daemon's own handle intact regardless).
        writeSyncedMarker(allocator, install_root);
        deleteQuicksync(allocator, install_root);
    }
};

test "parses get_info into a synced BlockchainState" {
    const allocator = std.testing.allocator;

    // Canned Monero `get_info` reply (subset) — fully synced: target_height 0 and
    // `synchronized` true. Proves the flat parse + height-derived sync without a
    // running nervad.
    const raw =
        \\{"id":"0","jsonrpc":"2.0","result":{"status":"OK","height":1500000,
        \\"target_height":0,"synchronized":true,"outgoing_connections_count":8,
        \\"incoming_connections_count":4,"mainnet":true,"testnet":false}}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(Nerva.NervaInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    const tip = @max(r.target_height, r.height);
    const state: models.BlockchainState = .{
        .chain = try allocator.dupe(u8, "mainnet"),
        .blocks = r.height,
        .headers = tip,
        .verification_progress = 0,
        .synced = r.synchronized or (r.height > 0 and (r.target_height == 0 or r.height >= r.target_height)),
        .network_height = tip,
    };
    defer state.deinit(allocator);

    try std.testing.expectEqualStrings("mainnet", state.chain);
    try std.testing.expectEqual(@as(i64, 1500000), state.blocks);
    try std.testing.expect(state.synced);
}

test "estimateSecondsBehind turns the block gap into a behind-by estimate" {
    // 100 blocks behind at 60s/block → ~6000s behind.
    try std.testing.expectEqual(@as(i64, 6000), Nerva.estimateSecondsBehind(1000, 900, false));

    // Synced → 0, so the frontend shows no "behind by" hint.
    try std.testing.expectEqual(@as(i64, 0), Nerva.estimateSecondsBehind(1000, 1000, true));

    // Caught up by height (target reached) even if the flag lags → still 0.
    try std.testing.expectEqual(@as(i64, 0), Nerva.estimateSecondsBehind(1000, 1000, false));
}

test "a daemon still catching up reads as not synced" {
    // Mid-sync: height behind target_height and not yet synchronized.
    const r: Nerva.NervaInfo = .{ .height = 900_000, .target_height = 1_500_000, .synchronized = false };
    const synced = r.synchronized or (r.height > 0 and (r.target_height == 0 or r.height >= r.target_height));
    try std.testing.expect(!synced);
    try std.testing.expectEqual(@as(i64, 1_500_000), @max(r.target_height, r.height));
}

test "maps get_info into DaemonInfo (connections summed, PoW so no staking)" {
    const allocator = std.testing.allocator;

    const raw =
        \\{"id":"0","jsonrpc":"2.0","result":{"status":"OK","height":1500000,
        \\"target_height":0,"synchronized":true,"outgoing_connections_count":8,
        \\"incoming_connections_count":4,"mainnet":true}}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(Nerva.NervaInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    const info: models.DaemonInfo = .{
        .blocks = r.height,
        .connections = r.outgoing_connections_count + r.incoming_connections_count,
        .staking_active = false,
    };

    try std.testing.expectEqual(@as(i64, 1500000), info.blocks);
    try std.testing.expectEqual(@as(i64, 12), info.connections);
    try std.testing.expect(!info.staking_active);
}

test "platform selection resolves a bundle for the build target" {
    // Where Nerva ships a bundle for the target, the URL carries the version and
    // the wrapper stem, and the extension matches the format (zip on Windows,
    // tar.bz2 elsewhere).
    if (Nerva.download) |dl| {
        try std.testing.expect(std.mem.indexOf(u8, dl.url, "/v" ++ Nerva.core_version ++ "/") != null);
        try std.testing.expect(std.mem.indexOf(u8, dl.url, Nerva.extracted_dir) != null);
        switch (dl.format) {
            .zip => try std.testing.expect(std.mem.endsWith(u8, dl.url, ".zip")),
            .tar_bz2 => try std.testing.expect(std.mem.endsWith(u8, dl.url, ".tar.bz2")),
            .tar_gz => try std.testing.expect(false),
        }
    }

    // Binary names carry `.exe` only on Windows.
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("nervad.exe", Nerva.daemon_file);
    } else {
        try std.testing.expectEqualStrings("nervad", Nerva.daemon_file);
    }
}

test "quicksync URL sits at the same release base as the binaries" {
    // The quicksync file is plain chain data (not platform-gated), so it always
    // resolves — carrying the pinned version and the canonical filename.
    try std.testing.expect(std.mem.indexOf(u8, Nerva.quicksync_url, "/v" ++ Nerva.core_version ++ "/") != null);
    try std.testing.expect(std.mem.endsWith(u8, Nerva.quicksync_url, "/quicksync.raw"));
}

test "daemonArgv adds --quicksync only when the file is present" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-nerva-quicksync-root";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var rd = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer rd.close(io);

    // No quicksync file → `--non-interactive --log-level <categories>`, no
    // quicksync flag. The log level is always passed: without it nervad logs
    // nothing at all during start-up (see `log_categories`).
    {
        const argv = try Nerva.daemonArgv(allocator, root, "");
        defer {
            for (argv) |a| allocator.free(a);
            allocator.free(argv);
        }
        try std.testing.expectEqual(@as(usize, 4), argv.len);
        try std.testing.expectEqualStrings("--log-level", argv[2]);
        // The `global` category is the one the init lines are written on.
        try std.testing.expect(std.mem.indexOf(u8, argv[3], "global:INFO") != null);
        const joined = try std.mem.join(allocator, " ", argv);
        defer allocator.free(joined);
        try std.testing.expect(std.mem.indexOf(u8, joined, "--quicksync") == null);
    }

    // Lay down quicksync.raw and it's threaded in as `--quicksync <abs path>`.
    try rd.writeFile(io, .{ .sub_path = Nerva.quicksync_file, .data = "RAW" });
    {
        const argv = try Nerva.daemonArgv(allocator, root, "");
        defer {
            for (argv) |a| allocator.free(a);
            allocator.free(argv);
        }
        try std.testing.expectEqual(@as(usize, 6), argv.len);
        try std.testing.expectEqualStrings("--log-level", argv[2]);
        try std.testing.expectEqualStrings("--quicksync", argv[4]);
        // The flag's argument is the full path to the file under the install root.
        try std.testing.expect(std.mem.startsWith(u8, argv[5], root));
        try std.testing.expect(std.mem.endsWith(u8, argv[5], Nerva.quicksync_file));
    }
}

test "onSynced removes quicksync, marks done, and stops offering it" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-nerva-onsynced-root";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var rd = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer rd.close(io);
    try rd.writeFile(io, .{ .sub_path = Nerva.quicksync_file, .data = "RAW" });
    try std.testing.expect(Nerva.quicksyncExists(allocator, root));

    // The post-sync hook (via the vtable, as the app calls it) drops the file and
    // writes the done-marker.
    var n: Nerva = .{};
    try n.coin().onSynced(allocator, root, "");
    try std.testing.expect(!Nerva.quicksyncExists(allocator, root));
    try std.testing.expect(Nerva.syncedMarkerExists(allocator, root));

    // A synced install never offers QuickSync again.
    try std.testing.expect(!Nerva.quicksyncShouldOffer(allocator, root, ""));

    // Idempotent: running again is a no-op, not an error.
    try n.coin().onSynced(allocator, root, "");
}

test "quicksyncShouldOffer: only on a fresh, unsynced install without the file" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-nerva-offer-root";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var rd = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer rd.close(io);

    // Fresh install, never synced, no quicksync yet → offer it.
    try std.testing.expect(Nerva.quicksyncShouldOffer(allocator, root, ""));

    // Quicksync already downloaded (a prior opt-in still mid-sync) → don't re-ask;
    // `daemonArgv` will use the existing file.
    try rd.writeFile(io, .{ .sub_path = Nerva.quicksync_file, .data = "RAW" });
    try std.testing.expect(!Nerva.quicksyncShouldOffer(allocator, root, ""));

    // And once the chain is fully synced (marker present), never offer it.
    try rd.deleteFile(io, Nerva.quicksync_file);
    try rd.writeFile(io, .{ .sub_path = Nerva.quicksync_done_file, .data = "synced\n" });
    try std.testing.expect(!Nerva.quicksyncShouldOffer(allocator, root, ""));

    // The capability is wired so the app can reach it.
    var n: Nerva = .{};
    try std.testing.expect(n.coin().syncAccelerator() != null);
    try std.testing.expectEqualStrings("QuickSync", n.coin().syncAccelerator().?.name);
}

test "Nerva wires the offline version probe its RPC can't provide" {
    var n: Nerva = .{};
    const c = n.coin();
    // Nerva's `get_info` reports no `version`, so the version marker can only come
    // from the binary itself. Without this hook a pre-marker install reads as up to
    // date forever — which is how a v0.2.2.0 daemon sat silently through the
    // v0.3.0.0 hard-fork release, showing no update badge.
    try std.testing.expect(c.vtable.installed_version_probe != null);
}

test "coin vtable dispatches to Nerva metadata" {
    var n: Nerva = .{};
    const c = n.coin();
    try std.testing.expectEqualStrings("Nerva", c.coinName());
    try std.testing.expectEqualStrings("XNV", c.coinNameAbbrev());
    try std.testing.expectEqualStrings("#344769", c.coinColor());
    try std.testing.expect(!c.isProofOfStake());
    try std.testing.expectEqualStrings("nerva.conf", c.confFile());
    try std.testing.expectEqualStrings("17566", c.rpcDefaultPort());
    try std.testing.expectEqual(Coin.LaunchMode.foreground, c.launchMode());
    try std.testing.expectEqualStrings("nerva.log", c.daemonLogFile().?);
}

test "walletPath reports the Monero wallet file plus its .keys companion" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var n: Nerva = .{};
    const wf = (try n.coin().walletPath(allocator, "/home/alice")).?;
    defer allocator.free(wf.path);
    defer allocator.free(wf.keys.?);
    try std.testing.expectEqualStrings("/home/alice/.nerva/wallets/BoxWallet", wf.path);
    try std.testing.expectEqualStrings("/home/alice/.nerva/wallets/BoxWallet.keys", wf.keys.?);
}

test "prepareConf writes a Monero-valid conf nervad can parse (no bitcoin keys)" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A throwaway home; prepareConf resolves `<home>/.nerva/nerva.conf` from it,
    // so this stays entirely offline (no real datadir touched).
    const home = "test-nerva-home";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // Pre-seed a poisoned, bitcoin-style conf (what older builds wrote and what
    // crashed nervad) to prove prepare is self-healing — it must be replaced, not
    // appended to.
    {
        const poisoned = try std.fs.path.join(allocator, &.{ home, Nerva.home_dir });
        defer allocator.free(poisoned);
        var pd = try std.Io.Dir.cwd().createDirPathOpen(io, poisoned, .{});
        defer pd.close(io);
        try pd.writeFile(io, .{ .sub_path = Nerva.conf_file, .data = "rpcuser=nervarpc\nserver=1\ndaemon=1\nrpcport=17566\n" });
    }

    try Nerva.prepareConf(allocator, io, home);

    // Read the conf back. nervad parses this on startup, so it must carry only
    // Monero-style options — the bitcoin keys (`rpcuser`/`server`/`daemon`/
    // `rpcport`) it rejects must be absent, and the RPC port present in Monero form.
    const path = try std.fs.path.join(allocator, &.{ home, Nerva.home_dir });
    defer allocator.free(path);
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    var f = try dir.openFile(io, Nerva.conf_file, .{});
    defer f.close(io);
    var rb: [4096]u8 = undefined;
    const n = try f.readPositionalAll(io, &rb, 0);
    const content = rb[0..n];

    try std.testing.expect(std.mem.indexOf(u8, content, "rpc-bind-port=" ++ Nerva.rpc_default_port) != null);
    for ([_][]const u8{ "rpcuser", "rpcpassword", "server", "daemon=", "rpcport" }) |bad| {
        try std.testing.expect(std.mem.indexOf(u8, content, bad) == null);
    }
}

// --- External wallet (Monero wallet-rpc) tests ---------------------------

test "get_balance atomic units map to XNV Total/Available (12 decimals)" {
    const allocator = std.testing.allocator;

    // 1.5 XNV total, 1.0 XNV unlocked, in 1e12 atomic units.
    const raw =
        \\{"id":"0","jsonrpc":"2.0","result":{"balance":1500000000000,"unlocked_balance":1000000000000}}
    ;
    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(Nerva.WalletBalanceResult),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    const bal = Nerva.atomicToBalance(r.balance, r.unlocked_balance);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), bal.total, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), bal.available, 1e-9);
    // Total ahead of available → funds still settling.
    try std.testing.expect(bal.hasPending());
}

test "isValidSeed accepts a 25-word phrase and rejects other counts" {
    // 25 space-separated tokens (content irrelevant — only the count is checked).
    const ok = "a a a a a a a a a a a a a a a a a a a a a a a a a";
    try std.testing.expect(Nerva.isValidSeed(ok));
    // Leading/trailing whitespace is trimmed, internal runs tolerated.
    try std.testing.expect(Nerva.isValidSeed("  " ++ ok ++ "\n"));
    // Too few / too many words fail fast.
    try std.testing.expect(!Nerva.isValidSeed("a a a"));
    try std.testing.expect(!Nerva.isValidSeed(ok ++ " extra"));
    try std.testing.expect(!Nerva.isValidSeed(""));
}

test "normalizeSeed lowercases words and collapses whitespace to single spaces" {
    const allocator = std.testing.allocator;

    // Capitalized first word + newlines + double spaces all clean up to the
    // canonical single-spaced lowercase phrase Monero's decode expects.
    const got = try Nerva.normalizeSeed(allocator, "  Abbey   bacon\nCactus  ");
    defer allocator.free(got);
    try std.testing.expectEqualStrings("abbey bacon cactus", got);

    // An already-clean phrase is returned unchanged.
    const clean = try Nerva.normalizeSeed(allocator, "abbey bacon cactus");
    defer allocator.free(clean);
    try std.testing.expectEqualStrings("abbey bacon cactus", clean);
}

test "walletRpcError maps known Monero messages to specific errors" {
    const E = Nerva.RpcErrObj;
    try std.testing.expect(Nerva.walletRpcError(E{ .code = -8, .message = "Wallet already exists." }, error.WalletRestoreFailed) == error.WalletAlreadyExists);
    try std.testing.expect(Nerva.walletRpcError(E{ .message = "Electrum-style word list failed verification" }, error.WalletRestoreFailed) == error.SeedWordsInvalid);
    try std.testing.expect(Nerva.walletRpcError(E{ .message = "invalid password" }, error.WalletOpenFailed) == error.WrongPassword);
    // Unfamiliar message / no error object → the caller's fallback.
    try std.testing.expect(Nerva.walletRpcError(E{ .message = "something new" }, error.WalletRestoreFailed) == error.WalletRestoreFailed);
    try std.testing.expect(Nerva.walletRpcError(null, error.WalletRestoreFailed) == error.WalletRestoreFailed);
}

test "walletIsClosed flags a -13 / no-wallet-file error so the app reverts to Locked" {
    const E = Nerva.RpcErrObj;
    // Monero's "no wallet open" — by code and by message; either alone suffices.
    try std.testing.expect(Nerva.walletIsClosed(E{ .code = -13, .message = "No wallet file" }));
    try std.testing.expect(Nerva.walletIsClosed(E{ .code = -1, .message = "No wallet file" }));
    try std.testing.expect(Nerva.walletIsClosed(E{ .code = -13, .message = "" }));
    // An unrelated wallet-RPC error must NOT read as closed (that would wrongly
    // lock a working wallet on a transient hiccup).
    try std.testing.expect(!Nerva.walletIsClosed(E{ .code = -32601, .message = "Method not found" }));
    // No error object at all → not closed.
    try std.testing.expect(!Nerva.walletIsClosed(null));
}

test "rescanFrom shows progress mid-scan and clears when caught up or tip unknown" {
    // Mid-scan → a live scanned/target pair the UI renders as "Rescanning… X%".
    const mid = Nerva.rescanFrom(900_000, 1_500_000).?;
    try std.testing.expectEqual(@as(i64, 900_000), mid.scanned);
    try std.testing.expectEqual(@as(i64, 1_500_000), mid.target);
    // Caught up (equal heights) and within-slack (steady-state 1-block lag) → null.
    try std.testing.expectEqual(@as(?models.RescanProgress, null), Nerva.rescanFrom(1_500_000, 1_500_000));
    try std.testing.expectEqual(@as(?models.RescanProgress, null), Nerva.rescanFrom(1_499_999, 1_500_000));
    // Tip not known yet (daemon hasn't answered a height) → null, no divide by zero.
    try std.testing.expectEqual(@as(?models.RescanProgress, null), Nerva.rescanFrom(0, 0));
}

test "walletProcessArgv binds wallet-rpc to localhost and points it at the daemon" {
    const allocator = std.testing.allocator;

    const argv = try Nerva.walletProcessArgv(allocator, "/opt/bw", "/home/alice", Nerva.wallet_rpc_port, "rpcuser123", "rpcpass456");
    defer {
        for (argv) |a| allocator.free(a);
        allocator.free(argv);
    }

    // First arg is the promoted wallet-rpc binary under the install root.
    try std.testing.expect(std.mem.endsWith(u8, argv[0], Nerva.wallet_rpc_file));
    try std.testing.expect(std.mem.startsWith(u8, argv[0], "/opt/bw"));

    // Joined for easy substring assertions on the flags.
    const joined = try std.mem.join(allocator, " ", argv);
    defer allocator.free(joined);
    try std.testing.expect(std.mem.indexOf(u8, joined, "--wallet-dir") != null);
    // The wallet dir is `<datadir>/wallets`.
    try std.testing.expect(std.mem.indexOf(u8, joined, "wallets") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "--rpc-bind-ip 127.0.0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "--rpc-bind-port " ++ Nerva.wallet_rpc_port) != null);
    // Pointed at the local daemon's RPC port.
    try std.testing.expect(std.mem.indexOf(u8, joined, "--daemon-address 127.0.0.1:" ++ Nerva.rpc_default_port) != null);
    // The wallet RPC is locked to the per-session credentials, not keyless.
    try std.testing.expect(std.mem.indexOf(u8, joined, "--rpc-login rpcuser123:rpcpass456") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "--disable-rpc-login") == null);
}

test "walletExists keys off the BoxWallet.keys file on disk" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A throwaway home; walletExists resolves `<home>/.nerva/wallets/BoxWallet.keys`.
    const home = "test-nerva-wallet-home";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // No wallet yet → false.
    try std.testing.expect(!Nerva.walletExists(allocator, home));

    // Lay down the keys file and it flips to true.
    const wallet_dir = try std.fs.path.join(allocator, &.{ home, Nerva.home_dir, "wallets" });
    defer allocator.free(wallet_dir);
    var wd = try std.Io.Dir.cwd().createDirPathOpen(io, wallet_dir, .{});
    defer wd.close(io);
    try wd.writeFile(io, .{ .sub_path = "BoxWallet.keys", .data = "KEYS" });

    try std.testing.expect(Nerva.walletExists(allocator, home));
}

test "walletRemove drops the wallet dir so a replacement can be set up" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-nerva-remove-home";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // Idempotent on a missing wallet — replace before any wallet exists is fine.
    try Nerva.walletRemove(allocator, home);

    // Lay down a full Monero wallet triple, then remove it; walletExists flips back.
    const wallet_dir = try std.fs.path.join(allocator, &.{ home, Nerva.home_dir, "wallets" });
    defer allocator.free(wallet_dir);
    var wd = try std.Io.Dir.cwd().createDirPathOpen(io, wallet_dir, .{});
    defer wd.close(io);
    try wd.writeFile(io, .{ .sub_path = "BoxWallet", .data = "CACHE" });
    try wd.writeFile(io, .{ .sub_path = "BoxWallet.keys", .data = "KEYS" });
    try wd.writeFile(io, .{ .sub_path = "BoxWallet.address.txt", .data = "ADDR" });
    try std.testing.expect(Nerva.walletExists(allocator, home));

    try Nerva.walletRemove(allocator, home);
    try std.testing.expect(!Nerva.walletExists(allocator, home));
}

test "Nerva wires the external-wallet capability" {
    var n: Nerva = .{};
    const c = n.coin();
    try std.testing.expect(c.hasExternalWallet());
    const ew = c.externalWallet().?;
    try std.testing.expect(c.hasExternalWalletProcess());
    try std.testing.expect(c.supportsWalletReplace());
    try std.testing.expectEqualStrings(Nerva.wallet_rpc_port, ew.rpc_port.?());
}

test "parses a get_transfers reply into bucketed TransferEntry lists" {
    const allocator = std.testing.allocator;

    // Canned wallet-rpc reply (subset): one mined credit (type "block"), one
    // plain receive, one outgoing spend. Extra per-entry fields (txid/fee/...)
    // are dropped via ignore_unknown_fields; this older vintage reports no
    // confirmations field, so it defaults to 0.
    const raw =
        \\{"id":"0","jsonrpc":"2.0","result":{"in":[
        \\{"txid":"aa","type":"block","amount":5000000000000,"timestamp":100,"height":1000},
        \\{"txid":"bb","type":"in","amount":2500000000000,"timestamp":200,"height":1400}
        \\],"out":[{"txid":"cc","type":"out","amount":1250000000000,"timestamp":300,"height":1490}]}}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(Nerva.GetTransfersResult),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    try std.testing.expectEqual(@as(usize, 2), r.in.len);
    try std.testing.expectEqual(@as(usize, 1), r.out.len);
    try std.testing.expectEqualStrings("block", r.in[0].type);
    try std.testing.expectEqual(@as(u64, 2500000000000), r.in[1].amount);
    try std.testing.expectEqual(@as(i64, 0), r.in[0].confirmations);
}

test "mapTransfers flattens buckets newest-first with derived confirmations, capped at limit" {
    const allocator = std.testing.allocator;

    var in = [_]Nerva.TransferEntry{
        .{ .type = "block", .amount = 5_000_000_000_000, .timestamp = 100, .height = 1000 }, // mined → stake
        .{ .type = "in", .amount = 2_500_000_000_000, .timestamp = 200, .height = 1400 },
    };
    var out = [_]Nerva.TransferEntry{
        .{ .type = "out", .amount = 1_250_000_000_000, .timestamp = 300, .height = 1490 },
    };
    var pool = [_]Nerva.TransferEntry{
        .{ .amount = 750_000_000_000, .timestamp = 400, .height = 0 }, // incoming, unconfirmed
    };
    const r: Nerva.GetTransfersResult = .{ .in = &in, .out = &out, .pool = &pool };

    const txs = try Nerva.mapTransfers(allocator, r, 1500, 32);
    defer allocator.free(txs);

    try std.testing.expectEqual(@as(usize, 4), txs.len);
    // Newest-first: the pool entry (t=400) leads, the mined credit (t=100) trails.
    try std.testing.expectEqual(models.TxDirection.received, txs[0].direction);
    try std.testing.expectEqual(@as(i64, 0), txs[0].confirmations); // height 0 → unconfirmed
    try std.testing.expectEqual(models.TxDirection.sent, txs[1].direction);
    try std.testing.expectEqual(@as(i64, 10), txs[1].confirmations); // 1500 - 1490
    try std.testing.expectEqual(models.TxDirection.received, txs[2].direction);
    try std.testing.expectEqual(models.TxDirection.stake, txs[3].direction);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), txs[3].amount, 1e-9); // atomic → whole XNV

    // The per-entry confirmations field wins over the derived height gap when a
    // newer vintage reports it.
    var confirmed = [_]Nerva.TransferEntry{
        .{ .type = "in", .amount = 1, .timestamp = 1, .height = 1400, .confirmations = 42 },
    };
    const r2: Nerva.GetTransfersResult = .{ .in = &confirmed };
    const t2 = try Nerva.mapTransfers(allocator, r2, 1500, 32);
    defer allocator.free(t2);
    try std.testing.expectEqual(@as(i64, 42), t2[0].confirmations);

    // The cap keeps only the newest rows.
    const capped = try Nerva.mapTransfers(allocator, r, 1500, 2);
    defer allocator.free(capped);
    try std.testing.expectEqual(@as(usize, 2), capped.len);
    try std.testing.expectEqual(@as(i64, 400), capped[0].time);
    try std.testing.expectEqual(@as(i64, 300), capped[1].time);
}

test "atomicFromAmount converts XNV to atomic units and rejects bad amounts" {
    try std.testing.expectEqual(@as(?u64, 1_500_000_000_000), Nerva.atomicFromAmount(1.5));
    try std.testing.expectEqual(@as(?u64, 1), Nerva.atomicFromAmount(0.000000000001));
    // Zero/negative/non-finite amounts are rejected before any RPC.
    try std.testing.expect(Nerva.atomicFromAmount(0) == null);
    try std.testing.expect(Nerva.atomicFromAmount(-1.0) == null);
    try std.testing.expect(Nerva.atomicFromAmount(std.math.inf(f64)) == null);
    try std.testing.expect(Nerva.atomicFromAmount(std.math.nan(f64)) == null);
    // Amounts that would overflow u64 atomic units are rejected too.
    try std.testing.expect(Nerva.atomicFromAmount(1e30) == null);
}

test "coin vtable exposes transactions, receive address, and send for Nerva" {
    var n: Nerva = .{};
    const c = n.coin();
    try std.testing.expect(c.supportsTransactions());
    try std.testing.expect(c.supportsReceiveAddress());
    try std.testing.expect(c.supportsSend());
}

// --- Mining tests ---------------------------------------------------------

test "parses /mining_status into a normalized MiningStatus" {
    const allocator = std.testing.allocator;

    // Canned direct-endpoint reply (subset) — actively mining on 4 threads.
    // Extra fields (address, bg_* battery knobs) drop via ignore_unknown_fields.
    const raw =
        \\{"status":"OK","active":true,"speed":1250,"threads_count":4,
        \\"address":"NV1abc","do_background_mining":false,"untrusted":false}
    ;
    var parsed = try std.json.parseFromSlice(
        Nerva.MiningStatusReply,
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const ms = Nerva.mapMiningStatus(parsed.value);
    try std.testing.expect(ms.active);
    try std.testing.expectEqual(@as(u32, 4), ms.threads);
    try std.testing.expectEqual(@as(u64, 1250), ms.speed);
}

test "an idle miner reads as inactive with zeroed threads/speed" {
    // Some vintages keep the last-run speed/threads in the reply when idle —
    // the mapping zeroes them so the tab can't show a stale hashrate.
    const ms = Nerva.mapMiningStatus(.{ .status = "OK", .active = false, .speed = 900, .threads_count = 2 });
    try std.testing.expect(!ms.active);
    try std.testing.expectEqual(@as(u32, 0), ms.threads);
    try std.testing.expectEqual(@as(u64, 0), ms.speed);
}

test "startMiningParams builds the /start_mining body (foreground, no battery heuristics, thread affinity)" {
    const allocator = std.testing.allocator;

    const body = try Nerva.startMiningParams(allocator, "NV1abc", 3);
    defer allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"miner_address\":\"NV1abc\",\"threads_count\":3,\"do_background_mining\":false,\"ignore_battery\":true,\"mining_affinity\":true}",
        body,
    );

    // The address is JSON-escaped, so a hostile string can't break the body.
    const quoted = try Nerva.startMiningParams(allocator, "a\"b", 1);
    defer allocator.free(quoted);
    try std.testing.expect(std.mem.indexOf(u8, quoted, "\"miner_address\":\"a\\\"b\"") != null);
}

test "expectStatusOk passes OK and maps BUSY / refusals to specific errors" {
    const allocator = std.testing.allocator;

    try Nerva.expectStatusOk(allocator, "{\"status\":\"OK\"}", error.MiningStartRejected);
    // BUSY = daemon still syncing — its own error so the user knows to wait.
    try std.testing.expectError(
        error.DaemonStillSyncing,
        Nerva.expectStatusOk(allocator, "{\"status\":\"BUSY\"}", error.MiningStartRejected),
    );
    // Any other refusal maps to the caller's reject error.
    try std.testing.expectError(
        error.MiningStartRejected,
        Nerva.expectStatusOk(allocator, "{\"status\":\"Failed, mining not started\"}", error.MiningStartRejected),
    );
}

test "coin vtable exposes the mining capability for Nerva" {
    var n: Nerva = .{};
    try std.testing.expect(n.coin().supportsMining());
}
