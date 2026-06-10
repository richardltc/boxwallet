const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const install_mod = @import("../install.zig");
const conf = @import("../conf.zig");
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
    pub const coin_name = "Nerva";
    pub const coin_name_abbrev = "XNV";
    /// Nerva brand colour (`#RRGGBB`), for tinting the coin in the frontend.
    pub const coin_color = "#344769";
    /// Nerva is proof-of-work (CPU-mined, Monero-derived) — no wallet staking.
    pub const proof_of_stake = false;
    pub const conf_file = "nerva.conf";

    // Data dir names. Monero forks use `~/.<name>` on Linux *and* macOS (not the
    // macOS Library convention) and `%APPDATA%\<name>` on Windows — exactly what
    // the shared `conf.dataDir(posix, win)` produces.
    pub const home_dir = ".nerva";
    pub const home_dir_win = "nerva";

    /// Unauthenticated by default; a value is kept only so the shared conf/readAuth
    /// path has a username to write (the daemon ignores it).
    pub const rpc_default_username = "nervarpc";
    pub const rpc_default_port = "17566";
    pub const core_version = "0.2.2.0";

    // Binary names. Windows appends `.exe`. The wallet CLI is `nerva-wallet-cli`;
    // there's no `*-tx` helper. (A `nerva-wallet-rpc` also ships but BoxWallet
    // doesn't drive the wallet, so it isn't promoted.)
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    pub const daemon_file = "nervad" ++ exe_suffix;
    pub const cli_file = "nerva-wallet-cli" ++ exe_suffix;

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
    const promote_files = [_][]const u8{ daemon_file, cli_file };

    // Scratch file the bundle streams to (unique to Nerva). For `.tar.bz2` the
    // installer derives a sibling `.tar` from this name during decompression.
    pub const scratch_file = ".boxwallet-nerva.part";

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
    };

    /// POST `payload` to `path` on the local daemon and return the response body.
    /// Caller owns the slice. No basic auth — Nerva's daemon RPC is open by
    /// default (like Ergo's keyless REST).
    fn httpPost(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        path: []const u8,
        payload: []const u8,
    ) ![]u8 {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();

        var client: std.http.Client = .{ .allocator = allocator, .io = threaded.io() };
        defer client.deinit();

        const url = try std.fmt.allocPrint(allocator, "http://{s}:{s}{s}", .{ auth.ip_address, auth.port, path });
        defer allocator.free(url);

        var body: std.Io.Writer.Allocating = .init(allocator);
        defer body.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .response_writer = &body.writer,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
        if (result.status == .unauthorized) return error.AuthFailed;

        return body.toOwnedSlice();
    }

    /// Fetch + parse `get_info`. Caller must `deinit` the returned `Parsed`.
    fn fetchInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !std.json.Parsed(models.JsonRpcResponse(NervaInfo)) {
        const raw = try httpPost(allocator, auth, "/json_rpc", "{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"get_info\"}");
        defer allocator.free(raw);
        return std.json.parseFromSlice(
            models.JsonRpcResponse(NervaInfo),
            allocator,
            raw,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
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
        return .{
            .chain = try allocator.dupe(u8, chain),
            .blocks = r.height,
            .headers = tip,
            .verification_progress = if (tip > 0)
                @as(f64, @floatFromInt(r.height)) / @as(f64, @floatFromInt(tip))
            else
                0,
            .synced = r.synchronized or (r.height > 0 and (r.target_height == 0 or r.height >= r.target_height)),
            .network_height = tip,
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
        };
    }

    /// Ask nervad to shut down via Monero's direct `POST /stop_daemon` (not a
    /// `/json_rpc` method).
    pub fn requestStop(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        const reply = try httpPost(allocator, auth, "/stop_daemon", "{}");
        allocator.free(reply);
    }

    // --- Files / paths ---------------------------------------------------

    /// The daemon's default data directory (`~/.nerva`, `%APPDATA%\nerva` on
    /// Windows), where `nerva.conf` and the chain live.
    pub fn dataDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        return conf.dataDir(allocator, home, home_dir, home_dir_win);
    }

    /// True if `nervad` (`nervad.exe` on Windows) is already present under
    /// `install_root`.
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, daemon_file);
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

    /// `nervad --non-interactive` (so it runs as a server rather than opening its
    /// interactive console). Caller owns the returned slice and its strings.
    pub fn daemonArgv(allocator: std.mem.Allocator, install_root: []const u8, _: []const u8) ![]const []const u8 {
        const path = try std.fs.path.join(allocator, &.{ install_root, daemon_file });
        errdefer allocator.free(path);
        const argv = try allocator.alloc([]const u8, 2);
        argv[0] = path;
        argv[1] = try allocator.dupe(u8, "--non-interactive");
        return argv;
    }

    // --- vtable plumbing -------------------------------------------------

    const vtable: Coin.VTable = .{
        .coin_name = vtCoinName,
        .coin_name_abbrev = vtCoinNameAbbrev,
        .coin_color = vtCoinColor,
        .core_version = vtCoreVersion,
        .proof_of_stake = vtProofOfStake,
        .conf_file = vtConfFile,
        .daemon_file = vtDaemonFile,
        .rpc_default_port = vtRpcDefaultPort,
        .rpc_default_username = vtRpcDefaultUsername,
        .blockchain_state = vtBlockchainState,
        .daemon_info = vtDaemonInfo,
        .data_dir = vtDataDir,
        .is_installed = vtIsInstalled,
        .install = vtInstall,
        .prepare_conf = vtPrepareConf,
        .launch_mode = vtLaunchMode,
        .daemon_argv = vtDaemonArgv,
        .request_stop = vtRequestStop,
    };

    fn vtCoinName(_: *anyopaque) []const u8 {
        return coin_name;
    }
    fn vtCoinNameAbbrev(_: *anyopaque) []const u8 {
        return coin_name_abbrev;
    }
    fn vtCoinColor(_: *anyopaque) []const u8 {
        return coin_color;
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
        home: []const u8,
    ) anyerror!void {
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
