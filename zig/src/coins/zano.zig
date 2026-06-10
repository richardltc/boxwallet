const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const rpc = @import("../rpc.zig");
const install_mod = @import("../install.zig");
const conf = @import("../conf.zig");
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
///     structs; this maps the real `getinfo` fields instead.)
///
/// Linux x86_64 installs the AppImage; Windows x64 installs the official `.zip`.
/// macOS ships only a `.dmg`, not wired, so it resolves no download
/// (`UnsupportedPlatform`).
pub const Zano = struct {
    pub const coin_name = "Zano";
    pub const coin_name_abbrev = "ZANO";
    /// Zano brand colour (`#RRGGBB`), for tinting the coin in the frontend.
    pub const coin_color = "#274cff";
    /// Zano is a hybrid PoW/PoS coin — it exposes a staking status.
    pub const proof_of_stake = true;
    pub const conf_file = "zano.conf";
    // Note the capital Z — Zano's POSIX data dir is `~/.Zano`, not `~/.zano`.
    pub const home_dir = ".Zano";
    pub const home_dir_win = "ZANO";
    pub const rpc_default_username = "zanorpc";
    pub const rpc_default_port = "11211";
    pub const core_version = "2.1.17.469";

    // Binary names. Windows appends `.exe`; Linux uses the bare names. Zano's CLI
    // is `simplewallet`, and there's no `*-tx` helper (unlike the bitcoin coins).
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    pub const daemon_file = "zanod" ++ exe_suffix;
    pub const cli_file = "simplewallet" ++ exe_suffix;

    // build.zano.org filenames embed an opaque build hash in brackets (URL-encoded
    // `%5B…%5D`), and the server exposes no directory index or "latest" alias — so
    // the URL can't be derived from the version alone. Bumping the version means
    // looking up the new hashed filename, which the GitHub release page publishes
    // in its PGP-signed notes (GitHub hosts no assets itself) — e.g.
    // https://github.com/hyle-team/zano/releases/tag/2.1.17.469. This is the latest
    // stable `release`-channel build.
    const appimage_build_hash = "1b1cc03";
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
    };

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
        var parsed = try rpc.callParsed(ZanoGetInfo, allocator, auth, "getinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
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
        var parsed = try rpc.callParsed(ZanoGetInfo, allocator, auth, "getinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return .{
            .blocks = r.height,
            .connections = r.outgoing_connections_count + r.incoming_connections_count,
            .staking_active = r.pos_allowed,
        };
    }

    /// The daemon's default data directory (`~/.Zano`), where `zano.conf` lives.
    pub fn dataDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        return conf.dataDir(allocator, home, home_dir, home_dir_win);
    }

    /// True if the daemon binary is present. Linux promotes `zanod` to the install
    /// root; Windows keeps `zanod.exe` under the `zano/` bundle subdir.
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        const sub = if (builtin.os.tag == .windows) win_subdir ++ "/" ++ daemon_file else daemon_file;
        return install_mod.fileExists(allocator, install_root, sub);
    }

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

    /// The full launch command: `zanod --no-console --no-predownload` (mirrors the
    /// Go `StartDaemon`). Caller owns the returned slice and every string in it.
    pub fn daemonArgv(allocator: std.mem.Allocator, install_root: []const u8, _: []const u8) ![]const []const u8 {
        const path = if (builtin.os.tag == .windows)
            try std.fs.path.join(allocator, &.{ install_root, win_subdir, daemon_file })
        else
            try std.fs.path.join(allocator, &.{ install_root, daemon_file });
        errdefer allocator.free(path);
        const argv = try allocator.alloc([]const u8, 3);
        argv[0] = path;
        argv[1] = try allocator.dupe(u8, "--no-console");
        argv[2] = try allocator.dupe(u8, "--no-predownload");
        return argv;
    }

    /// Ask zanod to shut down via the CryptoNote JSON-RPC `stop_daemon`.
    pub fn requestStop(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        const reply = try rpc.call(allocator, auth, "stop_daemon");
        allocator.free(reply);
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

test "parses getinfo into a synced BlockchainState (height caught up to the tip)" {
    const allocator = std.testing.allocator;

    // Canned daemon reply (subset) — a fully-synced node: local height matches the
    // network tip. Proves the flat-object parse + height-derived sync without a
    // running zanod.
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
    const tip = @max(r.max_net_seen_height, r.height);
    const state: models.BlockchainState = .{
        .chain = try allocator.dupe(u8, "mainnet"),
        .blocks = r.height,
        .headers = tip,
        .verification_progress = 0,
        .synced = r.height > 0 and r.max_net_seen_height > 0 and r.height >= r.max_net_seen_height,
        .network_height = r.max_net_seen_height,
    };
    defer state.deinit(allocator);

    try std.testing.expectEqualStrings("mainnet", state.chain);
    try std.testing.expectEqual(@as(i64, 2500000), state.blocks);
    try std.testing.expectEqual(@as(i64, 2500000), state.network_height);
    try std.testing.expect(state.synced);
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

test "coin vtable dispatches to Zano metadata" {
    var z: Zano = .{};
    const c = z.coin();
    try std.testing.expectEqualStrings("Zano", c.coinName());
    try std.testing.expectEqualStrings("ZANO", c.coinNameAbbrev());
    try std.testing.expectEqualStrings("#274cff", c.coinColor());
    try std.testing.expect(c.isProofOfStake());
    try std.testing.expectEqualStrings("zano.conf", c.confFile());
    try std.testing.expectEqualStrings("zanod", c.daemonFile());
    try std.testing.expectEqualStrings("11211", c.rpcDefaultPort());
    try std.testing.expectEqual(Coin.LaunchMode.foreground, c.launchMode());
}
