const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const rpc = @import("../rpc.zig");
const install_mod = @import("../install.zig");
const conf = @import("../conf.zig");
const warmup = @import("../warmup.zig");
const Coin = @import("../coin.zig").Coin;

/// Zano (ZANO) backend. Ported from `cmd/cli/cmd/coins/zano/zano.go`.
///
/// Zano is a CryptoNote-family hybrid PoW/PoS coin, so it differs from the
/// bitcoin-core forks in two ways the rest of BoxWallet's coins don't:
///
///   * **Distribution** — the Linux build ships as a self-extracting `.AppImage`
///     (an ELF with an embedded squashfs), not a tar.gz/zip the streaming
///     extractor handles. `install` downloads it to disk, marks it executable,
///     and runs `<appimage> --appimage-extract` (no FUSE needed) to unpack
///     `squashfs-root/`, then promotes `zanod`/`simplewallet` out of
///     `squashfs-root/usr/bin/` — mirroring the Go installer. Windows ships a
///     normal `.zip` (binaries at the archive root next to their runtime DLLs),
///     stream-extracted whole into a `zano/` subdir.
///   * **RPC** — Zano's daemon has no `getblockchaininfo`/`getpeerinfo`; a single
///     `getinfo` carries everything. Sync is derived from `height` vs
///     `max_net_seen_height` (the network tip), and the peer count from the
///     connection counts. (The Go reference left this half-wired to the bitcoin
///     structs; this maps the real `getinfo` fields instead.) Like other
///     CryptoNote daemons (cf. Nerva), the daemon RPC is **not** the bitcoin
///     transport: `getinfo` is a `POST /json_rpc` method (keyless on localhost),
///     not a JSON-RPC 1.0 call to root — so it goes through `rpc.moneroPost`.
///
/// Linux x86_64 installs the AppImage; Windows x64 installs the official `.zip`.
/// macOS ships only a `.dmg`, not wired, so it resolves no download
/// (`UnsupportedPlatform`).
pub const Zano = struct {
    /// Whether the coin is exposed in the nav. False keeps it out of the left
    /// bar entirely (registered but hidden) until it's ready for users.
    pub const live = true;
    pub const coin_name = "Zano";
    pub const coin_name_abbrev = "ZANO";
    /// One-line description shown under the coin name on the detail pane.
    pub const coin_description = "Privacy chain with confidential assets and hybrid PoW/PoS.";
    /// Zano brand colour (`#RRGGBB`), for tinting the coin in the frontend.
    pub const coin_color = "#274cff";
    /// This coin's id on the price host, for the USD quote beside its
    /// balance (see `src/price.zig`).
    pub const price_id = "zano";
    /// Donation address for BoxWallet development, in Zano's own
    /// currency.
    /// TODO(richard): replace with the real ZANO tip address.
    pub const tip_address = "ZxDHvWyQwKqi8ApBPhn3r9AnkRzBarAPCZvDkGQRnyPjjZs8WHL4PyfXyMipiJPTh6L8PHCp9LqNmMLp9NakETqL2gfpn92WP";
    /// Zano is a hybrid PoW/PoS coin — it exposes a staking status.
    pub const proof_of_stake = true;
    pub const conf_file = "zano.conf";
    // Note the capital Z — Zano's POSIX data dir is `~/.Zano`, not `~/.zano`.
    pub const home_dir = ".Zano";
    /// Windows data dir name, under the **roaming** `%APPDATA%` — Zano does not
    /// follow its CryptoNote cousins here: `zanod --help` states
    /// `--data-dir arg (=C:\Users\<user>\AppData\Roaming/Zano)`, where Monero,
    /// Nerva and Salvium all name `%ProgramData%`. Hence `.roaming` in `dataDir`.
    pub const home_dir_win = "ZANO";
    /// Which Windows directory that name hangs off — see the note above for why
    /// Zano is roaming while the rest of the CryptoNote family is not, and
    /// `conf.WinBase` for what the choice decides.
    pub const home_dir_win_base: conf.WinBase = .roaming;
    /// macOS data dir name. `null` means macOS uses the **POSIX** path
    /// (`~/.Zano`) rather than a `Library/Application Support`
    /// dir — Monero and its forks are explicit that it's "Unix & Mac:
    /// ~/.CRYPTONOTE_NAME", unlike the bitcoin-derived coins. Not an oversight:
    /// pointing this at a Library dir would orphan an existing wallet on macOS.
    pub const home_dir_mac: ?[]const u8 = null;
    pub const rpc_default_username = "zanorpc";
    pub const rpc_default_port = "11211";
    pub const core_version = "2.2.1.502";

    // Binary names. Windows appends `.exe`; Linux uses the bare names. Zano's CLI
    // is `simplewallet`, and there's no `*-tx` helper (unlike the bitcoin coins).
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    pub const daemon_file = "zanod" ++ exe_suffix;
    pub const cli_file = "simplewallet" ++ exe_suffix;

    /// Port BoxWallet binds the managed `simplewallet` RPC server to (localhost
    /// only). Kept clear of the daemon's RPC (11211) and the nearby P2P port so a
    /// running daemon and an open wallet never collide.
    pub const wallet_rpc_port = "11233";

    /// The single managed wallet's filename, inside the wallet dir. Fixed so
    /// `walletExists` is a pure disk check and the RPC server is always launched
    /// against the same file. Zano stores a wallet as one file (no Monero-style
    /// `.keys` companion).
    const wallet_name = "BoxWallet";

    /// Zano's atomic unit: 1 ZANO = 10^12 atomic units
    /// (`CRYPTONOTE_DISPLAY_DECIMAL_POINT = 12`), so wallet-RPC integer balances are
    /// divided by this to get whole ZANO.
    const atomic_per_zano: f64 = 1_000_000_000_000;

    /// Bound (ms) on a wallet-RPC op. A wallet's first balance read after opening can
    /// trail an initial refresh, so this is far longer than the daemon status cap —
    /// still bounded so a hung wallet service can't wedge the worker.
    const wallet_timeout_ms: u32 = 60_000;

    // build.zano.org filenames embed an opaque build hash in brackets (URL-encoded
    // `%5B…%5D`), and the server exposes no directory index or "latest" alias — so
    // the URL can't be derived from the version alone. Bumping the version means
    // looking up the new hashed filename, which the GitHub release page publishes
    // in its PGP-signed notes (GitHub hosts no assets itself) — e.g.
    // https://github.com/hyle-team/zano/releases/tag/2.2.1.502. This is the latest
    // stable `release`-channel build.
    //
    // The hash must be bumped in lockstep with `core_version`: the two are spliced
    // into one filename, and a mismatched pair resolves to a 404 rather than to the
    // wrong build.
    const appimage_build_hash = "76a791c";
    const appimage_url = "https://build.zano.org/builds/zano-linux-x64-release-v" ++
        core_version ++ "%5B" ++ appimage_build_hash ++ "%5D.AppImage";
    // Windows ships an official .zip (same build hash) carrying zanod.exe /
    // simplewallet.exe at the archive root, next to the runtime DLLs they load.
    const win_zip_url = "https://build.zano.org/builds/zano-win-x64-release-v" ++
        core_version ++ "%5B" ++ appimage_build_hash ++ "%5D.zip";

    /// Download URL for the build target, or null where Zano ships no daemon
    /// bundle BoxWallet can install: the Linux x86_64 AppImage, or the Windows x64
    /// zip. macOS ships only a `.dmg`, not wired.
    const download_url: ?[]const u8 = switch (builtin.os.tag) {
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => appimage_url,
            else => null,
        },
        .windows => win_zip_url,
        else => null,
    };

    // Install layout. The AppImage lands here as a file, then `--appimage-extract`
    // unpacks it to `squashfs-root/`, with the binaries under `usr/bin/`. Only
    // `zanod`/`simplewallet` are kept at the install root; the rest is discarded.
    const appimage_file = "zano-" ++ core_version ++ ".AppImage";
    const extracted_dir = "squashfs-root";
    const bin_subdir = "usr/bin";
    const promote_files = [_][]const u8{ daemon_file, cli_file };

    // Windows keeps the extracted zip whole in this subdir of the install root
    // (like Ergo's node bundle): zanod.exe can't be separated from its sibling
    // runtime DLLs, and isolating its ~470 files keeps them out of the shared root.
    const win_subdir = "zano";
    // Scratch file the Windows zip streams to, unique to Zano so a concurrent
    // install of another coin doesn't collide on it. (The Linux AppImage uses
    // `appimage_file` as its on-disk name.)
    pub const scratch_file = ".boxwallet-zano.part";

    /// Raw `getinfo` result — the subset BoxWallet's status poll uses. Zano's
    /// daemon returns a JSON-RPC envelope (`{ "result": { … } }`) with a flat info
    /// object; heights and connection counts drive sync/peers, and `pos_allowed`
    /// reports whether proof-of-stake is active on the network. Defaults keep the
    /// parse resilient to omitted fields.
    const ZanoGetInfo = struct {
        height: i64 = 0,
        max_net_seen_height: i64 = 0,
        synchronized_connections_count: i64 = 0,
        outgoing_connections_count: i64 = 0,
        incoming_connections_count: i64 = 0,
        pos_allowed: bool = false,
        status: []const u8 = "",
        /// The daemon's software version (e.g. "2.1.17.469"), from `getinfo`.
        version: []const u8 = "",
        /// Unix seconds of the local tip block, feeding `BlockchainState.tip_time`
        /// (the "block date / how far behind" hint while syncing). Only populated
        /// when `getinfo` is asked for it — see `getinfo_flags`.
        last_block_timestamp: i64 = 0,
    };

    /// The `getinfo` `flags` bit BoxWallet asks for. Zano gates most of `getinfo`'s
    /// payload behind this bitmask: called with no `params` the daemon returns
    /// heights and peer counts but a zeroed `last_block_timestamp`, so the sync hint
    /// would never render.
    ///
    /// Upstream names this bit `COMMAND_RPC_GET_INFO_FLAG_POS_DIFFICULTY`, but it
    /// also fills in the last-block fields we're actually after — it's the cheapest
    /// bit that yields `last_block_timestamp` (only `..._TOTAL_COINS`, 0x400, does
    /// so too). It costs the same as the bare call, unlike the expensive extras
    /// (hashrate, output stats, performance counters) behind the other bits — so the
    /// status poll asks for exactly this one and nothing more.
    const getinfo_flags = 0x1;

    /// Bound (ms) on a status/stop RPC round-trip. A healthy zanod answers
    /// `getinfo` in milliseconds, but a *busy* one (its reply stalled behind the
    /// blockchain lock while relaying across peers) can take seconds, accepting the
    /// connection yet not replying. This cap keeps such a stall from hanging the
    /// poll worker — liveness rides on the cheap connect probe, not this call, so a
    /// timeout just defers fresh numbers to the next poll. Mirrors Nerva.
    const status_timeout_ms: u32 = 3000;

    /// Fetch + parse `getinfo`. Caller must `deinit` the returned `Parsed`.
    ///
    /// Zano is a CryptoNote daemon: `getinfo` is a `POST /json_rpc` method, not a
    /// bitcoin-style JSON-RPC 1.0 call to root, so it goes through `moneroPost`
    /// (the daemon RPC is keyless on localhost — an empty user skips the digest
    /// handshake). The reply is the JSON-RPC envelope `{ "result": { … } }`.
    ///
    /// `params.flags` asks for the last-block fields on top of the default payload
    /// (see `getinfo_flags`); an older daemon that predates `flags` simply
    /// ignores it and leaves `last_block_timestamp` at 0, which the frontend treats
    /// as "no tip timestamp".
    fn fetchInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !std.json.Parsed(models.JsonRpcResponse(ZanoGetInfo)) {
        const body = std.fmt.comptimePrint(
            "{{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"getinfo\",\"params\":{{\"flags\":{d}}}}}",
            .{getinfo_flags},
        );
        const raw = try rpc.moneroPost(allocator, auth, "/json_rpc", body, status_timeout_ms);
        defer allocator.free(raw);
        return std.json.parseFromSlice(
            models.JsonRpcResponse(ZanoGetInfo),
            allocator,
            raw,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
    }

    /// Build the type-erased `Coin` handle for this instance.
    pub fn coin(self: *Zano) Coin {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Live `getinfo`, normalized for a frontend. Zano has no
    /// `getblockchaininfo`/`verificationprogress`, so sync is derived from the
    /// local `height` vs the network tip (`max_net_seen_height`): caught up once
    /// the local height reaches a known tip. The tip also feeds the Headers bar.
    pub fn blockchainState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.BlockchainState {
        var parsed = try fetchInfo(allocator, auth);
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return mapInfo(allocator, r);
    }

    /// Map a parsed `getinfo` onto the normalized `BlockchainState`. Split out from
    /// `blockchainState` so the mapping is unit-testable without a running zanod.
    fn mapInfo(allocator: std.mem.Allocator, r: ZanoGetInfo) !models.BlockchainState {
        const tip = @max(r.max_net_seen_height, r.height);
        return .{
            // getinfo carries no chain name; Zano installs mainnet here.
            .chain = try allocator.dupe(u8, "mainnet"),
            .blocks = r.height,
            .headers = tip,
            .verification_progress = if (tip > 0)
                @as(f64, @floatFromInt(r.height)) / @as(f64, @floatFromInt(tip))
            else
                0,
            .synced = r.height > 0 and r.max_net_seen_height > 0 and r.height >= r.max_net_seen_height,
            .network_height = r.max_net_seen_height,
            // Timestamp of the block being synced; the frontend derives "how far
            // behind" from `now − tip_time`. 0 when the daemon hasn't reported one
            // (fresh chain, or a build predating `getinfo`'s `flags`), which the
            // frontend reads as "unavailable" and simply omits the hint.
            .tip_time = r.last_block_timestamp,
        };
    }

    /// Live `getinfo`, normalized for a frontend. The peer count is the daemon's
    /// total connections (outgoing + incoming). `staking_active` reflects the
    /// daemon's `pos_allowed` — i.e. proof-of-stake is active on the network;
    /// whether *this* wallet is staking lives in the wallet RPC, which the
    /// status poll (daemon-only) doesn't reach.
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
            .staking_active = r.pos_allowed,
            // `version` points into `parsed`; dupe it onto `allocator`.
            .version = try allocator.dupe(u8, r.version),
        };
    }

    /// The daemon's default data directory (`~/.Zano`), where `zano.conf` lives.
    pub fn dataDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        return conf.dataDir(allocator, home, home_dir, home_dir_win, home_dir_mac, home_dir_win_base);
    }

    /// The daemon binary's path *relative to the install root*. Linux promotes
    /// `zanod` to the root; Windows keeps `zanod.exe` under the `zano/` bundle
    /// subdir, beside the DLLs it loads.
    const daemon_rel = if (builtin.os.tag == .windows) win_subdir ++ "/" ++ daemon_file else daemon_file;

    /// True if the daemon binary is present.
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, daemon_rel);
    }

    /// Absolute path of the installed daemon. Linux promotes `zanod` to the install
    /// root; Windows keeps `zanod.exe` under the `zano/` bundle subdir, beside the
    /// DLLs it loads. Caller owns the returned path.
    fn daemonPath(allocator: std.mem.Allocator, install_root: []const u8) ![]u8 {
        return if (builtin.os.tag == .windows)
            std.fs.path.join(allocator, &.{ install_root, win_subdir, daemon_file })
        else
            std.fs.path.join(allocator, &.{ install_root, daemon_file });
    }

    /// Ask the installed `zanod` its version by running `zanod --version`.
    ///
    /// Zano's `getinfo` reports no `version` field, so the daemon can never stamp a
    /// version marker over RPC the way the bitcoin forks do — a pre-marker install
    /// would stay silently un-updatable. Probing the binary closes that gap, and it
    /// works with the daemon stopped.
    ///
    /// Caller owns the returned version string.
    fn probeInstalledVersion(allocator: std.mem.Allocator, install_root: []const u8) anyerror![]const u8 {
        return install_mod.probeBinaryVersion(allocator, install_root, daemon_rel, ".zanod.probe");
    }

    /// Zano's `--version` banner reads `Zano v2.2.1.502[76a791c]` (simplewallet
    /// prefixes an extra word) — the shared banner parser's shape. Aliased so the
    /// parse stays covered from Zano's own tests.
    const parseVersionOutput = install_mod.parseVersionBanner;

    /// Download + unpack the Zano daemon files into `install_root`, optionally
    /// reporting progress.
    ///
    /// Unlike the bitcoin coins (a streamed tar.gz/zip), Zano's Linux build is a
    /// self-extracting AppImage: it's saved to disk, marked executable, and run
    /// with `--appimage-extract` to unpack `squashfs-root/` in place — then
    /// `promoteAndTidy` lifts `zanod`/`simplewallet` out of
    /// `squashfs-root/usr/bin/` and discards the rest, leaving `zanod` where
    /// `isInstalled` looks for it.
    pub fn install(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        const url = download_url orelse return error.UnsupportedPlatform;

        if (builtin.os.tag == .windows) {
            // Windows ships a flat .zip — zanod.exe/simplewallet.exe sit at the
            // archive root next to the DLLs they load — so stream-extract it whole
            // into the `zano/` bundle subdir (no promote: the binaries can't be
            // split from their DLLs). The streaming zip extractor keeps memory flat
            // despite the ~200MB bundle.
            const dest = try std.fs.path.join(allocator, &.{ install_root, win_subdir });
            defer allocator.free(dest);
            try install_mod.downloadAndExtract(allocator, url, .zip, dest, scratch_file, 0, progress);
            return;
        }

        // 1. Stream the AppImage to disk (flat memory; never held in RAM).
        try install_mod.downloadFile(allocator, url, install_root, appimage_file, progress);

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var dir = try std.Io.Dir.cwd().openDir(io, install_root, .{});
        defer dir.close(io);

        // Signal extraction has begun so the UI swaps the download bar for its
        // spinner. `Progress`' fields are public; its reporter method isn't, so
        // call through `func`/`ctx` directly.
        if (progress) |p| p.func(p.ctx, .extract, 0, 0);

        // 2. Mark the AppImage executable, then run `--appimage-extract`, which
        //    unpacks the embedded squashfs into `<install_root>/squashfs-root/`.
        //    That subcommand needs no FUSE (unlike *running* the AppImage), so it
        //    works headless. Output is discarded to keep memory flat. The child's
        //    cwd is the install root (via the dir handle) so squashfs-root lands
        //    there; argv[0] is "./<file>", resolved relative to that cwd.
        {
            var f = try dir.openFile(io, appimage_file, .{});
            defer f.close(io);
            try f.setPermissions(io, .executable_file);
        }
        const argv0 = try std.fmt.allocPrint(allocator, "./{s}", .{appimage_file});
        defer allocator.free(argv0);
        var child = try std.process.spawn(io, .{
            .argv = &.{ argv0, "--appimage-extract" },
            .cwd = .{ .dir = dir },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        switch (try child.wait(io)) {
            .exited => |code| if (code != 0) return error.AppImageExtractFailed,
            else => return error.AppImageExtractFailed,
        }

        // 3. Promote the binaries out of squashfs-root/usr/bin, drop the rest of
        //    the extracted tree, and delete the now-spent AppImage.
        try install_mod.promoteAndTidy(allocator, install_root, extracted_dir, bin_subdir, &promote_files);
        dir.deleteFile(io, appimage_file) catch {};
    }

    /// Ensure the data dir and `zano.conf` exist with RPC creds. zanod doesn't
    /// read this conf unless launched with `--config-file` (BoxWallet launches it
    /// bare), but writing it keeps the shared `readAuth` path uniform across coins
    /// and creates the data dir. A standard `key=value` conf.
    pub fn prepareConf(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        _ = try conf.populate(allocator, io, data_dir, conf_file, rpc_default_username, rpc_default_port);
    }

    /// Zano's daemon runs in the foreground of its own process (it doesn't fork
    /// like bitcoin's `-daemon`), so it's spawned detached and the status poll
    /// confirms it came up.
    pub fn launchMode() Coin.LaunchMode {
        return .foreground;
    }

    /// The daemon's log file under the data dir, whose tail is read for a
    /// startup-failure reason when the daemon dies without saying why on stderr.
    pub fn daemonLogFile() []const u8 {
        return "zanod.log";
    }

    /// The stage zanod is at while it starts, read from `zanod.log`. Zano logs
    /// these at its default level — no flag needed — but writes the file to
    /// `--log-dir`, which `daemonArgv` has to point at the data dir for this (and
    /// the startup-failure reason) to find it at all.
    ///
    /// Zano binds its RPC port early but only *starts* serving after the core is
    /// initialized, so a probe still can't see the load; the log can. Shared epee
    /// wording (Zano capitalises differently — "Core rpc server started ok" —
    /// which `warmup.epeeStage` matches case-insensitively).
    pub fn warmupStageFromLog(tail: []const u8) []const u8 {
        return warmup.epeeStage(tail);
    }

    /// The full launch command: `zanod --no-console --log-dir <datadir>`. Caller
    /// owns the returned slice and every string in it.
    ///
    /// `--log-dir` is not cosmetic. Left to itself zanod writes `zanod.log` beside
    /// its *binary* (the install root), while everything that reads a daemon log —
    /// the startup-failure reason and `warmupStageFromLog` — looks under the data
    /// dir, where `daemonLogFile` says it is. Pointing it there is what makes both
    /// work, and puts the log with the chain it describes.
    ///
    /// `--no-predownload` is deliberately omitted: it would disable Zano's
    /// bootstrap-snapshot download and force a full P2P sync of the whole chain,
    /// which is glacially slow on the low-spec hardware BoxWallet targets. Letting
    /// predownload run gives a fresh node a recent DB to start from.
    pub fn daemonArgv(allocator: std.mem.Allocator, install_root: []const u8, home: []const u8) ![]const []const u8 {
        const path = try daemonPath(allocator, install_root);
        errdefer allocator.free(path);
        const data_dir = try dataDir(allocator, home);
        errdefer allocator.free(data_dir);
        const argv = try allocator.alloc([]const u8, 4);
        argv[0] = path;
        argv[1] = try allocator.dupe(u8, "--no-console");
        argv[2] = try allocator.dupe(u8, "--log-dir");
        argv[3] = data_dir;
        return argv;
    }

    // No requestStop: unlike Monero forks (Nerva/Salvium), zanod exposes **no**
    // shutdown RPC — its RPC server has no `/stop_daemon` URI handler and no
    // `/json_rpc` stop method (only `stop_mining`). So the vtable leaves
    // `request_stop` null and app.zig stops zanod by terminating the process
    // (SIGTERM, which lets it flush its LMDB chain DB). See `Coin.hasRpcStop`.

    // --- External wallet (Zano simplewallet) -----------------------------
    //
    // Zano's wallet lives in a separate process (`simplewallet`), like Nerva's — but
    // its RPC model is fundamentally different. `simplewallet --rpc-bind-port …` can
    // only serve the **one** wallet it was launched on (`--wallet-file … --password
    // …`); it exposes no create/open/restore over RPC (only `getbalance`,
    // `get_restore_info`, …). So BoxWallet can't keep one idle, password-less RPC
    // process around the way it does for Nerva — instead it (re)launches the server
    // per-open with the wallet file + password (`launch_server_argv`), and creating a
    // wallet is a one-shot `--generate-new-wallet` CLI run (`cli_create`) before the
    // server is started. The wallet RPC is keyless on localhost (`simplewallet` has
    // no `--rpc-login`), matching the daemon's own localhost-only RPC. All
    // funds-sensitive: a wallet is only ever created/opened with a user-supplied
    // password, never silently. See `coin.zig`'s `ExternalWallet`.

    /// The managed wallet directory (`<datadir>/wallets`), where the `BoxWallet`
    /// wallet file is created and opened. Caller owns the slice.
    fn walletDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        return std.fs.path.join(allocator, &.{ data_dir, "wallets" });
    }

    /// Port the wallet process is bound to — its RPC endpoint, distinct from the
    /// daemon's. The lifecycle in `app.zig` builds a keyless `wallet_auth` from this.
    fn walletRpcPort() []const u8 {
        return wallet_rpc_port;
    }

    /// True if the managed `BoxWallet` wallet file already exists on disk. A pure
    /// disk check, so the UI can decide "set up" vs "unlock" without a running
    /// process.
    fn walletExists(allocator: std.mem.Allocator, home: []const u8) bool {
        const dir = walletDir(allocator, home) catch return false;
        defer allocator.free(dir);
        return install_mod.fileExists(allocator, dir, wallet_name);
    }

    /// Resolve the `simplewallet` binary path (the `zano/` bundle subdir on Windows,
    /// the install root elsewhere — mirroring `daemonArgv`). Caller owns the slice.
    fn cliPath(allocator: std.mem.Allocator, install_root: []const u8) ![]const u8 {
        return if (builtin.os.tag == .windows)
            std.fs.path.join(allocator, &.{ install_root, win_subdir, cli_file })
        else
            std.fs.path.join(allocator, &.{ install_root, cli_file });
    }

    /// argv to launch `simplewallet` as an RPC server against the managed wallet
    /// file, opened with `wallet_password`, bound to localhost:`port` and pointed at
    /// the local daemon. Setting `--rpc-bind-port` switches simplewallet into server
    /// mode (no interactive console). The wallet RPC is keyless on localhost — Zano
    /// `simplewallet` exposes no `--rpc-login`, so the 127.0.0.1 bind is the
    /// protection, as it is for the daemon. Caller owns the slice and its strings.
    ///
    /// Note the password rides the argv (Zano's own exchange-integration guide opens
    /// the wallet the same way), so it's visible to other local users via `ps`. That
    /// matches the trust boundary already in force here — the keyless localhost RPC
    /// means any local user could drive the open wallet regardless — so it adds no
    /// exposure beyond it. (`--password-file` would avoid the `ps` leak but, in the
    /// Monero lineage Zano forks from, conflicts with `--rpc-bind-port`.)
    fn launchServerArgv(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home: []const u8,
        port: []const u8,
        wallet_password: []const u8,
    ) anyerror![]const []const u8 {
        const path = try cliPath(allocator, install_root);
        errdefer allocator.free(path);
        const dir = try walletDir(allocator, home);
        defer allocator.free(dir);
        const wallet_path = try std.fs.path.join(allocator, &.{ dir, wallet_name });
        defer allocator.free(wallet_path);

        const wallet_arg = try std.fmt.allocPrint(allocator, "--wallet-file={s}", .{wallet_path});
        errdefer allocator.free(wallet_arg);
        const pass_arg = try std.fmt.allocPrint(allocator, "--password={s}", .{wallet_password});
        errdefer allocator.free(pass_arg);
        const port_arg = try std.fmt.allocPrint(allocator, "--rpc-bind-port={s}", .{port});
        errdefer allocator.free(port_arg);
        const daemon_arg = try std.fmt.allocPrint(allocator, "--daemon-address=127.0.0.1:{s}", .{rpc_default_port});
        errdefer allocator.free(daemon_arg);

        const argv = try allocator.alloc([]const u8, 6);
        errdefer allocator.free(argv);
        argv[0] = path;
        argv[1] = wallet_arg;
        argv[2] = pass_arg;
        argv[3] = try allocator.dupe(u8, "--rpc-bind-ip=127.0.0.1");
        argv[4] = port_arg;
        argv[5] = daemon_arg;
        return argv;
    }

    /// One-shot `simplewallet --generate-new-wallet=<file> --password=<pw>` to
    /// materialize the managed wallet file (no RPC server — the app launches that
    /// next). Without `--rpc-bind-port` simplewallet would drop to its interactive
    /// console after generating, so stdin is closed (it reads EOF and exits) and a
    /// timeout backstops any vintage that lingers. Success is the wallet file
    /// appearing on disk; on failure the CLI's own stderr/stdout is surfaced.
    fn cliCreate(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home: []const u8,
        password: []const u8,
        detail: *Coin.WalletErrSink,
    ) anyerror!void {
        const dir = try walletDir(allocator, home);
        defer allocator.free(dir);

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        // Ensure the wallet dir exists so simplewallet can write into it.
        var dd = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
        dd.close(io);

        const wallet_path = try std.fs.path.join(allocator, &.{ dir, wallet_name });
        defer allocator.free(wallet_path);
        const cli = try cliPath(allocator, install_root);
        defer allocator.free(cli);

        const gen_arg = try std.fmt.allocPrint(allocator, "--generate-new-wallet={s}", .{wallet_path});
        defer allocator.free(gen_arg);
        const pass_arg = try std.fmt.allocPrint(allocator, "--password={s}", .{password});
        defer allocator.free(pass_arg);

        const argv = [_][]const u8{ cli, gen_arg, pass_arg };
        const res = std.process.run(allocator, io, .{
            .argv = &argv,
            .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(120), .clock = .awake } },
        }) catch |err| {
            detail.set(@errorName(err));
            return error.WalletCreateFailed;
        };
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);

        if (!install_mod.fileExists(allocator, dir, wallet_name)) {
            const why = std.mem.trim(u8, if (res.stderr.len > 0) res.stderr else res.stdout, " \t\r\n");
            detail.set(if (why.len > 0) why else "simplewallet did not create the wallet");
            return error.WalletCreateFailed;
        }
    }

    /// Import an existing Zano wallet file (browsed to) as the managed `BoxWallet`.
    /// A Zano wallet is a single file, so it's copied straight in (the app launches
    /// the server against it and confirms the password next). Streamed in bounded
    /// chunks rather than slurped, so a wallet with a large tx cache stays flat in
    /// memory. The destination is overwritten if present (the caller gates this
    /// behind the create/restore menu, only shown when no managed wallet exists).
    fn walletRestoreFile(
        allocator: std.mem.Allocator,
        _: models.CoinAuth,
        home: []const u8,
        src_path: []const u8,
        _: []const u8,
        _: *Coin.WalletErrSink,
    ) anyerror!void {
        const dest_dir = try walletDir(allocator, home);
        defer allocator.free(dest_dir);
        try copyFileStreaming(allocator, src_path, dest_dir, wallet_name);
    }

    /// Stream-copy the file at absolute `src_path` into `dest_dir` as `dest_name`,
    /// creating `dest_dir` if needed. Bounded buffer (no whole-file slurp), so a
    /// large wallet file copies at flat memory.
    fn copyFileStreaming(
        allocator: std.mem.Allocator,
        src_path: []const u8,
        dest_dir: []const u8,
        dest_name: []const u8,
    ) !void {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const src_dir = std.fs.path.dirname(src_path) orelse ".";
        const src_base = std.fs.path.basename(src_path);
        var sd = std.Io.Dir.cwd().openDir(io, src_dir, .{}) catch return error.WalletFileNotFound;
        defer sd.close(io);
        var src = sd.openFile(io, src_base, .{}) catch return error.WalletFileNotFound;
        defer src.close(io);

        var dd = try std.Io.Dir.cwd().createDirPathOpen(io, dest_dir, .{});
        defer dd.close(io);
        var dst = try dd.createFile(io, dest_name, .{ .truncate = true });
        defer dst.close(io);

        var buf: [64 * 1024]u8 = undefined;
        var off: u64 = 0;
        while (true) {
            const n = try src.readPositionalAll(io, &buf, off);
            if (n == 0) break;
            try dst.writePositionalAll(io, buf[0..n], off);
            off += n;
            if (n < buf.len) break;
        }
    }

    // Wallet-RPC result subsets. `getbalance` reports atomic-unit integers for the
    // native coin (whitelisted assets ride a `balances` array we ignore);
    // `get_restore_info` returns the wallet's mnemonic for the create-time display.
    const WalletBalanceResult = struct { balance: u64 = 0, unlocked_balance: u64 = 0 };
    const RestoreInfoResult = struct { seed_phrase: []const u8 = "" };

    /// The `error` half of a Zano wallet-RPC reply, present in place of `result` when
    /// an op fails. Its `message` is surfaced so the user sees a real reason.
    const RpcErrObj = struct { code: i64 = 0, message: []const u8 = "" };

    /// JSON-RPC envelope keeping the `error` object (unlike the shared
    /// `models.JsonRpcResponse`, which drops it) so wallet ops can report why.
    fn WalletEnvelope(comptime T: type) type {
        return struct { result: ?T = null, @"error": ?RpcErrObj = null };
    }

    /// POST a wallet-RPC `method` with a raw JSON `params` object and parse
    /// `result`/`error`. Keyless on localhost (empty user → `moneroPost` skips the
    /// digest handshake). Caller `deinit`s the `Parsed`.
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
        // `.alloc_always` so parsed strings (the seed phrase, error message) survive
        // `raw` being freed.
        return std.json.parseFromSlice(
            WalletEnvelope(T),
            allocator,
            raw,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
    }

    /// Read the freshly-generated wallet's mnemonic (after `cli_create` + the server
    /// launch) for the user to write down. The unsecured seed (no seed-password) is
    /// returned by `get_restore_info` with an empty `seed_password`. This is the
    /// `create` hook: the file already exists and the server is up by the time it
    /// runs, so it's purely the seed read-back.
    fn walletCreate(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        _: []const u8,
        detail: *Coin.WalletErrSink,
    ) anyerror!models.Seed {
        var parsed = try walletCall(RestoreInfoResult, allocator, wallet_auth, "get_restore_info", "{\"seed_password\":\"\"}");
        defer parsed.deinit();
        const r = parsed.value.result orelse {
            if (parsed.value.@"error") |e| detail.set(e.message);
            return error.WalletCreateFailed;
        };
        if (r.seed_phrase.len == 0) return error.WalletCreateFailed;
        return models.Seed.from(r.seed_phrase);
    }

    /// Confirm the just-launched wallet server has the wallet open, by reading its
    /// balance. The `open` hook runs *after* `launchWalletServer` has started the
    /// server with the password (a wrong password makes the server exit before
    /// binding, so that path already failed); a clean `getbalance` here proves the
    /// wallet is open and serving.
    fn walletOpen(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        _: []const u8,
        detail: *Coin.WalletErrSink,
    ) anyerror!void {
        var parsed = try walletCall(WalletBalanceResult, allocator, wallet_auth, "getbalance", "{}");
        defer parsed.deinit();
        if (parsed.value.result == null) {
            if (parsed.value.@"error") |e| detail.set(e.message);
            return error.WalletOpenFailed;
        }
    }

    /// Read the open wallet's native ZANO balance. `balance` is the total (includes
    /// locked/unconfirmed); `unlocked_balance` is spendable now — the Total /
    /// Available split the frontend renders.
    fn walletBalance(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
    ) anyerror!models.WalletBalance {
        var parsed = try walletCall(WalletBalanceResult, allocator, wallet_auth, "getbalance", "{}");
        defer parsed.deinit();
        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return atomicToBalance(r.balance, r.unlocked_balance);
    }

    /// Map Zano atomic balances to the normalized `WalletBalance`. Pure, so it's
    /// unit-testable without a wallet process.
    fn atomicToBalance(balance: u64, unlocked: u64) models.WalletBalance {
        return .{
            .total = @as(f64, @floatFromInt(balance)) / atomic_per_zano,
            .available = @as(f64, @floatFromInt(unlocked)) / atomic_per_zano,
        };
    }

    // --- Transactions / receive / send (wallet RPC) ----------------------
    //
    // These ride the same per-open `simplewallet` server as balance, so the app
    // hands them the wallet endpoint (`extWalletAuth`) and polls them only once
    // the wallet is open.

    /// One `get_recent_txs_and_info` transfer entry (the subset BoxWallet
    /// uses). `is_income` marks money arriving; `is_mining` marks a coinbase —
    /// on Zano's PoS chain that's a staked block reward. `is_service` marks
    /// housekeeping transactions (asset ops etc.) with no displayable amount.
    /// `height` is 0 while unconfirmed.
    const RecentTxEntry = struct {
        amount: u64 = 0,
        timestamp: i64 = 0,
        height: i64 = 0,
        is_income: bool = false,
        is_mining: bool = false,
        is_service: bool = false,
        tx_hash: []const u8 = "",
    };

    /// `get_recent_txs_and_info`'s provision info (subset): the wallet's synced
    /// height, for deriving confirmations. The field really is spelled
    /// `curent_height` upstream.
    const ProvisionInfo = struct { curent_height: i64 = 0 };

    const RecentTxsResult = struct {
        transfers: []RecentTxEntry = &.{},
        pi: ProvisionInfo = .{},
    };
    const AddressResult = struct { address: []const u8 = "" };
    const TransferResult = struct { tx_hash: []const u8 = "" };

    /// Zano's standard transaction fee, in atomic units (0.01 ZANO — the
    /// network's fixed minimum, `TX_DEFAULT_FEE` upstream). `transfer` requires
    /// an explicit fee.
    const default_fee_atomic: u64 = 10_000_000_000;

    /// Decoys per input for `transfer`. Zano's post-Zarcanum outputs use 15+.
    const default_mixin = 15;

    /// The open wallet's most recent transactions, newest-first, via
    /// `get_recent_txs_and_info` — which already returns newest-first (default
    /// order `FROM_END_TO_BEGIN`) and takes a `count` cap, so only `limit`
    /// entries ever cross the wire.
    fn walletTransactions(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        limit: usize,
    ) anyerror![]models.WalletTx {
        const params = try std.fmt.allocPrint(
            allocator,
            "{{\"count\":{d},\"offset\":0,\"update_provision_info\":true}}",
            .{limit},
        );
        defer allocator.free(params);
        var parsed = try walletCall(RecentTxsResult, allocator, wallet_auth, "get_recent_txs_and_info", params);
        defer parsed.deinit();
        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return mapRecentTxs(allocator, r.transfers, r.pi.curent_height, limit);
    }

    /// Map the (already newest-first) transfer entries to normalized
    /// `WalletTx`es, dropping service/zero-amount housekeeping entries.
    /// Confirmations derive from the wallet height (`tip − height`, 0 while
    /// unconfirmed). Split out so the mapping is unit-testable without a
    /// wallet process.
    fn mapRecentTxs(allocator: std.mem.Allocator, transfers: []const RecentTxEntry, tip: i64, limit: usize) ![]models.WalletTx {
        var count: usize = 0;
        for (transfers) |e| {
            if (!(e.is_service or e.amount == 0)) count += 1;
        }

        var out = try allocator.alloc(models.WalletTx, @min(count, limit));
        var n: usize = 0;
        for (transfers) |e| {
            if (n == out.len) break;
            if (e.is_service or e.amount == 0) continue;
            const direction: models.TxDirection = if (e.is_mining)
                .stake // a coinbase on Zano's PoS chain is a staked block reward
            else if (e.is_income)
                .received
            else
                .sent;
            out[n] = .{
                .direction = direction,
                .amount = @as(f64, @floatFromInt(e.amount)) / atomic_per_zano,
                .time = e.timestamp,
                .confirmations = if (e.height > 0 and tip > e.height) tip - e.height else 0,
            };
            // Copied into the row's own buffer — `transfers` points into the
            // parsed reply, which is freed as soon as this returns.
            out[n].setTxid(e.tx_hash);
            n += 1;
        }
        return out;
    }

    /// The open wallet's receive address (`getaddress`). A Zano wallet has one
    /// stealth address for its lifetime (no subaddresses over this RPC), and
    /// CryptoNote stealth addressing keeps reuse private — so `force_new` still
    /// returns the same address rather than erroring the Receive tab's rotate
    /// key.
    fn walletReceiveAddress(
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        force_new: bool,
    ) anyerror![]const u8 {
        _ = force_new;
        var parsed = try walletCall(AddressResult, allocator, wallet_auth, "getaddress", "{}");
        defer parsed.deinit();
        const r = parsed.value.result orelse return error.EmptyRpcResult;
        if (r.address.len == 0) return error.EmptyRpcResult;
        return allocator.dupe(u8, r.address); // parsed.deinit() frees its arena below us
    }

    /// Send `amount` ZANO to `address` via the wallet RPC `transfer`, with the
    /// network's standard fee and mixin. The wallet does its own address
    /// validation and balance check — `SendResult` carries whichever of those
    /// (or the success tx hash) came back, verbatim. The amount is converted to
    /// integer atomic units before splicing.
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
            "{{\"destinations\":[{{\"amount\":{d},\"address\":{s}}}],\"fee\":{d},\"mixin\":{d}}}",
            .{ atomic, addr_q, default_fee_atomic, default_mixin },
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

    /// Convert a user-entered ZANO amount to integer atomic units (rounded to
    /// the nearest atomic). Null for anything unusable — non-finite,
    /// non-positive, or too large for u64 — so a bad amount is rejected before
    /// any RPC.
    fn atomicFromAmount(amount: f64) ?u64 {
        if (!std.math.isFinite(amount) or amount <= 0) return null;
        const scaled = @round(amount * atomic_per_zano);
        if (scaled >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return null;
        return @intFromFloat(scaled);
    }

    /// Restore-from-seed is deferred: Zano's `--restore-wallet` prompts for the seed
    /// interactively with no non-interactive flag, so BoxWallet doesn't offer it yet
    /// (the setup menu hides it via `supports_seed_restore = false`). The hook stays
    /// wired to satisfy the interface; it's never reached.
    fn walletRestoreSeedUnsupported(
        _: std.mem.Allocator,
        _: models.CoinAuth,
        _: []const u8,
        _: []const u8,
        _: []const u8,
        _: []const u8,
        _: *Coin.WalletErrSink,
    ) anyerror!void {
        return error.Unsupported;
    }

    /// Remove the managed wallet so a different one can be created/restored in its
    /// place — the destructive in-app "Replace wallet". Drops the whole
    /// `<datadir>/wallets` dir (the single `BoxWallet` file and any companions), so
    /// `walletExists` reports false next. The caller (`app.zig`) stops the per-open
    /// `simplewallet` first — releasing the file lock — and leaves the daemon (and
    /// its sync) running; the next create/restore re-creates the dir. Idempotent — a
    /// missing dir is fine; `deleteTree` holds nothing in memory beyond a path.
    fn walletRemove(allocator: std.mem.Allocator, home: []const u8) anyerror!void {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const dir = try walletDir(allocator, home);
        defer allocator.free(dir);
        try std.Io.Dir.cwd().deleteTree(threaded.io(), dir);
    }

    /// The external-wallet capability wired into the vtable. Unlike Nerva's, this is
    /// a launch-with-password wallet (`launch_server_argv` + `cli_create`), so the
    /// app relaunches `simplewallet` per-open rather than keeping one idle process.
    pub const external_wallet: Coin.ExternalWallet = .{
        .rpc_port = walletRpcPort,
        .launch_server_argv = launchServerArgv,
        .cli_create = cliCreate,
        .supports_seed_restore = false,
        .exists = walletExists,
        .create = walletCreate,
        .restore_seed = walletRestoreSeedUnsupported,
        .restore_file = walletRestoreFile,
        .open = walletOpen,
        .remove = walletRemove,
        .balance = walletBalance,
        .seed_word_counts = &.{ 26, 25, 24 },
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
        .is_installed = vtIsInstalled,
        // Zano's `getinfo` carries no `version` field, so the marker can only be
        // stamped by asking the binary itself (see `probeInstalledVersion`).
        .installed_version_probe = vtProbeInstalledVersion,
        .install = vtInstall,
        .prepare_conf = vtPrepareConf,
        .launch_mode = vtLaunchMode,
        .daemon_log_file = vtDaemonLogFile,
        .warmup_stage_from_log = vtWarmupStageFromLog,
        .daemon_argv = vtDaemonArgv,
        // No `.request_stop`: zanod exposes no shutdown RPC, so app.zig stops it
        // by terminating the process (see the requestStop note above).
        .wallet_transactions = vtWalletTransactions,
        .wallet_receive_address = vtWalletReceiveAddress,
        .wallet_send = vtWalletSend,
        .external_wallet = &external_wallet,
    };

    // The three hooks below ride the wallet server's endpoint: for an
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
    fn vtPriceId(_: *anyopaque) []const u8 {
        return price_id;
    }
    fn vtCoreVersion(_: *anyopaque) []const u8 {
        return core_version;
    }
    fn vtProofOfStake(_: *anyopaque) bool {
        return proof_of_stake;
    }
    /// Zano inherits the CryptoNote 12-decimal atomic unit (see `atomic_per_zano`).
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
};

test "parses getinfo into a synced BlockchainState (height caught up to the tip)" {
    const allocator = std.testing.allocator;

    // Canned daemon reply (subset) — a fully-synced node: local height matches the
    // network tip. Proves the flat-object parse + height-derived sync without a
    // running zanod.
    const raw =
        \\{"id":"0","jsonrpc":"2.0","result":{"height":2500000,
        \\"max_net_seen_height":2500000,"synchronized_connections_count":8,
        \\"outgoing_connections_count":8,"incoming_connections_count":2,
        \\"pos_allowed":true,"status":"OK","last_block_timestamp":1781007756}}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(Zano.ZanoGetInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const state = try Zano.mapInfo(allocator, parsed.value.result.?);
    defer state.deinit(allocator);

    try std.testing.expectEqualStrings("mainnet", state.chain);
    try std.testing.expectEqual(@as(i64, 2500000), state.blocks);
    try std.testing.expectEqual(@as(i64, 2500000), state.network_height);
    try std.testing.expect(state.synced);
    try std.testing.expectEqual(@as(i64, 1781007756), state.tip_time);
}

test "the tip block timestamp drives the sync hint, and is 0 when getinfo omits it" {
    const allocator = std.testing.allocator;

    // Mid-sync, with the last-block flag honoured: the tip timestamp rides through
    // to `tip_time`, so the frontend can render "<block date>  N years behind".
    const syncing = try Zano.mapInfo(allocator, .{
        .height = 3_720_712,
        .max_net_seen_height = 3_765_109,
        .last_block_timestamp = 1_781_007_756,
    });
    defer syncing.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 1_781_007_756), syncing.tip_time);
    try std.testing.expect(!syncing.synced);
    // `seconds_behind` stays unsupplied: the frontend derives it from `now − tip_time`.
    try std.testing.expectEqual(@as(i64, -1), syncing.seconds_behind);

    // A daemon that never filled the field in (fresh chain, or a build predating
    // `getinfo`'s `flags`) leaves `tip_time` at 0 — read as "no hint", not as 1970.
    const quiet = try Zano.mapInfo(allocator, .{ .height = 1, .max_net_seen_height = 2 });
    defer quiet.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 0), quiet.tip_time);
}

test "height behind the network tip reads as not synced" {
    // Mid-sync: the local height trails the highest height seen from peers.
    const r: Zano.ZanoGetInfo = .{ .height = 1_000_000, .max_net_seen_height = 2_500_000 };
    try std.testing.expect(!(r.height > 0 and r.max_net_seen_height > 0 and r.height >= r.max_net_seen_height));
    try std.testing.expectEqual(@as(i64, 2_500_000), r.max_net_seen_height);
}

test "maps getinfo into DaemonInfo (connections summed, staking from pos_allowed)" {
    const allocator = std.testing.allocator;

    const raw =
        \\{"id":"0","jsonrpc":"2.0","result":{"height":2500000,
        \\"max_net_seen_height":2500000,"synchronized_connections_count":8,
        \\"outgoing_connections_count":8,"incoming_connections_count":2,
        \\"pos_allowed":true,"status":"OK"}}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(Zano.ZanoGetInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    const info: models.DaemonInfo = .{
        .blocks = r.height,
        .connections = r.outgoing_connections_count + r.incoming_connections_count,
        .staking_active = r.pos_allowed,
    };

    try std.testing.expectEqual(@as(i64, 2500000), info.blocks);
    try std.testing.expectEqual(@as(i64, 10), info.connections);
    try std.testing.expect(info.staking_active);
}

test "platform selection: Linux x86_64 gets the AppImage, Windows the zip" {
    switch (builtin.os.tag) {
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => {
                try std.testing.expect(Zano.download_url != null);
                const url = Zano.download_url.?;
                try std.testing.expect(std.mem.endsWith(u8, url, ".AppImage"));
                try std.testing.expect(std.mem.indexOf(u8, url, Zano.core_version) != null);
            },
            else => try std.testing.expect(Zano.download_url == null),
        },
        .windows => {
            try std.testing.expect(Zano.download_url != null);
            const url = Zano.download_url.?;
            try std.testing.expect(std.mem.endsWith(u8, url, ".zip"));
            try std.testing.expect(std.mem.indexOf(u8, url, Zano.core_version) != null);
        },
        else => try std.testing.expect(Zano.download_url == null),
    }
}

test "parseVersionOutput lifts the bare version out of zanod's --version banner" {
    // The real banners, verbatim (zanod 2.2.1.502 / 2.1.15.457, and simplewallet,
    // which prefixes an extra word before the `v`).
    try std.testing.expectEqualStrings("2.2.1.502", Zano.parseVersionOutput("Zano v2.2.1.502[76a791c]\n").?);
    try std.testing.expectEqualStrings("2.1.15.457", Zano.parseVersionOutput("Zano v2.1.15.457[8621a68]\n").?);
    try std.testing.expectEqualStrings(
        "2.2.1.502",
        Zano.parseVersionOutput("Zano simplewallet v2.2.1.502[76a791c]\n").?,
    );

    // The build hash is dropped, so a freshly-installed binary's banner yields
    // exactly the pinned `core_version` — the whole point of parsing rather than
    // storing the banner, since the marker is compared against it verbatim.
    const banner = "Zano v" ++ Zano.core_version ++ "[76a791c]";
    const v = Zano.parseVersionOutput(banner).?;
    try std.testing.expect(std.mem.indexOfScalar(u8, v, '[') == null);
    try std.testing.expectEqualStrings(Zano.core_version, v);

    // Only the first line is considered.
    try std.testing.expectEqualStrings("1.2.3", Zano.parseVersionOutput("Zano v1.2.3\nnoise v9.9.9\n").?);
    // A trailing dot never survives into the version.
    try std.testing.expectEqualStrings("1.2", Zano.parseVersionOutput("Zano v1.2.").?);

    // Nothing version-shaped: the caller treats null as "version unknown" rather
    // than stamping a bogus marker.
    try std.testing.expect(Zano.parseVersionOutput("") == null);
    try std.testing.expect(Zano.parseVersionOutput("Zano\n") == null);
    // Digits not preceded by `v` aren't a version (guards against a stray banner
    // word like a year or a PID being mistaken for one).
    try std.testing.expect(Zano.parseVersionOutput("Zano 2026 build\n") == null);
}

test "Zano wires the offline version probe its RPC can't provide" {
    var z: Zano = .{};
    const c = z.coin();
    // Zano's `getinfo` reports no `version`, so the marker can only come from the
    // binary — the probe hook must be wired or a pre-marker install stays silent.
    try std.testing.expect(c.vtable.installed_version_probe != null);
}

test "coin vtable dispatches to Zano metadata" {
    var z: Zano = .{};
    const c = z.coin();
    try std.testing.expectEqualStrings("Zano", c.coinName());
    try std.testing.expectEqualStrings("ZANO", c.coinNameAbbrev());
    try std.testing.expectEqualStrings("#274cff", c.coinColor());
    try std.testing.expect(c.isProofOfStake());
    try std.testing.expectEqualStrings("zano.conf", c.confFile());
    try std.testing.expectEqualStrings("zanod" ++ Zano.exe_suffix, c.daemonFile());
    try std.testing.expectEqualStrings("11211", c.rpcDefaultPort());
    try std.testing.expectEqual(Coin.LaunchMode.foreground, c.launchMode());
    try std.testing.expectEqualStrings("zanod.log", c.daemonLogFile().?);
    // zanod exposes no shutdown RPC, so the vtable leaves request_stop null and
    // app.zig stops it by killing the process.
    try std.testing.expect(!c.hasRpcStop());
    // Zano balances render to 12 decimals (CryptoNote atomic unit).
    try std.testing.expectEqual(@as(u8, 12), c.balanceDecimals());
    // BoxWallet manages no fixed wallet file for Zano, so the Settings tab shows
    // an em-dash rather than a path.
    try std.testing.expect((try c.walletPath(std.testing.allocator, "/home/alice")) == null);
}

// --- External wallet (Zano simplewallet) tests ---------------------------

test "Zano wires a launch-with-password external wallet" {
    var z: Zano = .{};
    const c = z.coin();
    try std.testing.expect(c.hasExternalWallet());
    try std.testing.expect(c.hasExternalWalletProcess());
    // Distinct from Nerva: the wallet process is (re)launched per-open with the
    // password, not spawned once eagerly.
    try std.testing.expect(c.walletLaunchesWithPassword());
    // Restore-from-seed is deferred (Zano's is interactive-only upstream).
    try std.testing.expect(!c.supportsSeedRestore());

    const ew = c.externalWallet().?;
    try std.testing.expectEqualStrings(Zano.wallet_rpc_port, ew.rpc_port.?());
    // The launch-with-password hooks are set; the eager `process_argv` is not.
    try std.testing.expect(ew.launch_server_argv != null);
    try std.testing.expect(ew.cli_create != null);
    try std.testing.expect(ew.process_argv == null);
    // Replace-wallet is wired so the setup menu can offer it.
    try std.testing.expect(c.supportsWalletReplace());
    // 26-word canonical seed, with 25/24 accepted for older wallets.
    try std.testing.expectEqual(@as(usize, 26), c.seedWordCounts()[0]);
    try std.testing.expectEqual(@as(usize, 3), c.seedWordCounts().len);
}

test "walletRemove drops the wallet dir so a replacement can be set up" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-zano-remove-home";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // Idempotent on a missing wallet — replace before any wallet exists is fine.
    try Zano.walletRemove(allocator, home);

    // Lay down the single Zano wallet file, then remove it; walletExists flips back.
    // Located with `walletDir`, not by hand: the managed wallet hangs off the
    // *data dir*, which is `<home>/.Zano` only on POSIX — on Windows it's
    // `<home>/AppData/Roaming/ZANO`. A hand-built POSIX path put the fixture
    // where `walletExists` was never going to look.
    const wallet_dir = try Zano.walletDir(allocator, home);
    defer allocator.free(wallet_dir);
    var wd = try std.Io.Dir.cwd().createDirPathOpen(io, wallet_dir, .{});
    defer wd.close(io);
    try wd.writeFile(io, .{ .sub_path = "BoxWallet", .data = "WALLET" });
    try std.testing.expect(Zano.walletExists(allocator, home));

    try Zano.walletRemove(allocator, home);
    try std.testing.expect(!Zano.walletExists(allocator, home));
}

test "launchServerArgv runs simplewallet as a localhost RPC server for the wallet" {
    const allocator = std.testing.allocator;

    const argv = try Zano.launchServerArgv(allocator, "/opt/bw", "/home/alice", Zano.wallet_rpc_port, "hunter2");
    defer {
        for (argv) |a| allocator.free(a);
        allocator.free(argv);
    }

    // First arg is the simplewallet binary under the install root.
    try std.testing.expect(std.mem.endsWith(u8, argv[0], Zano.cli_file));
    try std.testing.expect(std.mem.startsWith(u8, argv[0], "/opt/bw"));

    const joined = try std.mem.join(allocator, " ", argv);
    defer allocator.free(joined);
    // Opens the managed wallet file with the supplied password.
    try std.testing.expect(std.mem.indexOf(u8, joined, "--wallet-file=") != null);
    // The wallet path is joined with the host's separator; matched on '/'.
    try @import("../pathtest.zig").expectContains(joined, "wallets/BoxWallet");
    try std.testing.expect(std.mem.indexOf(u8, joined, "--password=hunter2") != null);
    // Server mode, bound to localhost on the wallet port, pointed at the daemon.
    try std.testing.expect(std.mem.indexOf(u8, joined, "--rpc-bind-ip=127.0.0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "--rpc-bind-port=" ++ Zano.wallet_rpc_port) != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "--daemon-address=127.0.0.1:11211") != null);
    // No --rpc-login: Zano simplewallet has none; the localhost bind is the guard.
    try std.testing.expect(std.mem.indexOf(u8, joined, "--rpc-login") == null);
}

test "getbalance atomic units map to ZANO Total/Available (12 decimals)" {
    const allocator = std.testing.allocator;

    // 1.5 ZANO total, 1.0 ZANO unlocked, in 1e12 atomic units.
    const raw =
        \\{"id":"0","jsonrpc":"2.0","result":{"balance":1500000000000,"unlocked_balance":1000000000000}}
    ;
    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(Zano.WalletBalanceResult),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    const bal = Zano.atomicToBalance(r.balance, r.unlocked_balance);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), bal.total, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), bal.available, 1e-9);
    // Total ahead of available → funds still settling.
    try std.testing.expect(bal.hasPending());
}

test "get_restore_info parse yields the seed phrase for create-time display" {
    const allocator = std.testing.allocator;

    const raw =
        \\{"id":"0","jsonrpc":"2.0","result":{"seed_phrase":"abbey bacon cactus delta","is_auditable":false}}
    ;
    var parsed = try std.json.parseFromSlice(
        Zano.WalletEnvelope(Zano.RestoreInfoResult),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("abbey bacon cactus delta", parsed.value.result.?.seed_phrase);
    try std.testing.expect(parsed.value.@"error" == null);
}

test "walletExists keys off the BoxWallet file on disk" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A throwaway home; walletExists resolves `<datadir>/wallets/BoxWallet`,
    // where the data dir is `<home>/.Zano` on POSIX and
    // `<home>/AppData/Roaming/ZANO` on Windows.
    const home = "test-zano-wallet-home";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // No wallet yet → false.
    try std.testing.expect(!Zano.walletExists(allocator, home));

    // Lay down the wallet file and it flips to true. Same resolver the code
    // under test uses, so the fixture lands where it actually looks.
    const wallet_dir = try Zano.walletDir(allocator, home);
    defer allocator.free(wallet_dir);
    var wd = try std.Io.Dir.cwd().createDirPathOpen(io, wallet_dir, .{});
    defer wd.close(io);
    try wd.writeFile(io, .{ .sub_path = "BoxWallet", .data = "WALLET" });

    try std.testing.expect(Zano.walletExists(allocator, home));
}

test "restore-from-file streams an external wallet file in as the managed wallet" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-zano-restore-home";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // A source wallet file outside the managed dir.
    var hd = try std.Io.Dir.cwd().createDirPathOpen(io, home, .{});
    defer hd.close(io);
    try hd.writeFile(io, .{ .sub_path = "mywallet.zan", .data = "ZANOWALLETBYTES" });
    const src = try std.fs.path.join(allocator, &.{ home, "mywallet.zan" });
    defer allocator.free(src);

    // Import it; the bytes land at `<datadir>/wallets/BoxWallet` — resolved, not
    // hardcoded, since the data dir is per-platform.
    try Zano.walletRestoreFile(allocator, undefined, home, src, "pw", undefined);
    try std.testing.expect(Zano.walletExists(allocator, home));

    const wallet_dir = try Zano.walletDir(allocator, home);
    defer allocator.free(wallet_dir);
    var dd = try std.Io.Dir.cwd().openDir(io, wallet_dir, .{});
    defer dd.close(io);
    var f = try dd.openFile(io, "BoxWallet", .{});
    defer f.close(io);
    var buf: [64]u8 = undefined;
    const n = try f.readPositionalAll(io, &buf, 0);
    try std.testing.expectEqualStrings("ZANOWALLETBYTES", buf[0..n]);
}

test "parses a get_recent_txs_and_info reply (transfers + provision info)" {
    const allocator = std.testing.allocator;

    // Canned reply (subset): a staked block reward (is_mining), an incoming
    // payment, an outgoing spend still in the pool (height 0), and a service
    // entry the mapper drops. Note upstream's `curent_height` spelling.
    const raw =
        \\{"id":"0","jsonrpc":"2.0","result":{"pi":{"balance":1,"curent_height":2000,
        \\"transfer_entries_count":3,"transfers_count":3,"unlocked_balance":1},
        \\"transfers":[
        \\{"amount":1250000000000,"timestamp":400,"height":0,"is_income":false,"is_mining":false,"is_service":false},
        \\{"amount":2500000000000,"timestamp":300,"height":1990,"is_income":true,"is_mining":false,"is_service":false},
        \\{"amount":0,"timestamp":250,"height":1985,"is_income":false,"is_mining":false,"is_service":true},
        \\{"amount":5000000000000,"timestamp":100,"height":1000,"is_income":true,"is_mining":true,"is_service":false}
        \\]}}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(Zano.RecentTxsResult),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    try std.testing.expectEqual(@as(usize, 4), r.transfers.len);
    try std.testing.expectEqual(@as(i64, 2000), r.pi.curent_height);

    const txs = try Zano.mapRecentTxs(allocator, r.transfers, r.pi.curent_height, 32);
    defer allocator.free(txs);

    // Service entry dropped; order preserved (the RPC already returns
    // newest-first); confirmations derived from the wallet height.
    try std.testing.expectEqual(@as(usize, 3), txs.len);
    try std.testing.expectEqual(models.TxDirection.sent, txs[0].direction);
    try std.testing.expectEqual(@as(i64, 0), txs[0].confirmations); // height 0 → unconfirmed
    try std.testing.expectEqual(models.TxDirection.received, txs[1].direction);
    try std.testing.expectEqual(@as(i64, 10), txs[1].confirmations); // 2000 - 1990
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), txs[1].amount, 1e-9);
    try std.testing.expectEqual(models.TxDirection.stake, txs[2].direction);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), txs[2].amount, 1e-9);
}

test "mapRecentTxs caps at limit" {
    const allocator = std.testing.allocator;
    const transfers = [_]Zano.RecentTxEntry{
        .{ .amount = 1, .timestamp = 300, .height = 1999, .is_income = true },
        .{ .amount = 2, .timestamp = 200, .height = 1998, .is_income = true },
        .{ .amount = 3, .timestamp = 100, .height = 1997, .is_income = true },
    };
    const txs = try Zano.mapRecentTxs(allocator, &transfers, 2000, 2);
    defer allocator.free(txs);
    try std.testing.expectEqual(@as(usize, 2), txs.len);
    try std.testing.expectEqual(@as(i64, 300), txs[0].time);
    try std.testing.expectEqual(@as(i64, 200), txs[1].time);
}

test "atomicFromAmount converts ZANO to 12-decimal atomic units and rejects bad amounts" {
    try std.testing.expectEqual(@as(?u64, 1_500_000_000_000), Zano.atomicFromAmount(1.5));
    try std.testing.expectEqual(@as(?u64, 1), Zano.atomicFromAmount(0.000000000001));
    try std.testing.expect(Zano.atomicFromAmount(0) == null);
    try std.testing.expect(Zano.atomicFromAmount(-1.0) == null);
    try std.testing.expect(Zano.atomicFromAmount(std.math.inf(f64)) == null);
    try std.testing.expect(Zano.atomicFromAmount(1e30) == null);
}

test "daemonArgv points zanod's log at the data dir" {
    const allocator = std.testing.allocator;
    const argv = try Zano.daemonArgv(allocator, "/opt/bw", "/home/u");
    defer {
        for (argv) |s| allocator.free(s);
        allocator.free(argv);
    }

    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("--no-console", argv[1]);
    // Load-bearing: left to itself zanod writes `zanod.log` beside its binary,
    // where neither the startup-failure reason nor `warmupStageFromLog` — both of
    // which look under the data dir — would ever find it.
    try std.testing.expectEqualStrings("--log-dir", argv[2]);
    const data_dir = try Zano.dataDir(allocator, "/home/u");
    defer allocator.free(data_dir);
    try std.testing.expectEqualStrings(data_dir, argv[3]);
}

test "coin vtable exposes transactions, receive address, and send for Zano" {
    var z: Zano = .{};
    const c = z.coin();
    try std.testing.expect(c.supportsTransactions());
    try std.testing.expect(c.supportsReceiveAddress());
    try std.testing.expect(c.supportsSend());
}
