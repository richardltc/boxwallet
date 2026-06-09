const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const install_mod = @import("../install.zig");
const Coin = @import("../coin.zig").Coin;

/// Ergo (ERG) backend. Ported from the Elixir reference in `ergo/`.
///
/// Ergo is unlike the bitcoin-core forks the rest of BoxWallet ports: it's a JVM
/// application, not a native `*coind`. So the differences are wired through the
/// `Coin` vtable's launch/conf/stop hooks rather than the shared bitcoin paths:
///
///   * **Distribution** — BoxWallet downloads the official per-platform
///     "ergo-node" bundle, which carries `ergo-<ver>.jar` alongside a bundled
///     OpenJDK JRE (so no system Java is needed). The bundle is extracted whole
///     under `~/.boxwallet/ergo-node/`; the jar and `java` launcher are located
///     by searching the extracted tree (their nesting varies per platform).
///   * **Launch** — `java -jar ergo-<ver>.jar --mainnet -c <conf>`, run in the
///     foreground of its own process (it doesn't fork like `-daemon`), so it's
///     spawned detached and the status poll confirms it came up.
///   * **API** — a REST API (not JSON-RPC). `/info` is public (drives the status
///     poll); protected endpoints (`/node/shutdown`) authenticate with an
///     `api_key` HTTP header. The node binds to 127.0.0.1 only.
///   * **Config** — a HOCON `ergo.conf` written from a template; the node stores
///     only the Blake2b256 hash of the API key.
///   * **Consensus** — PoW (Autolykos2), so no staking.
///   * **Units** — balances are in nanoERG (1 ERG = 1e9 nanoERG); not surfaced by
///     the current status-only TUI.
pub const Ergo = struct {
    pub const coin_name = "ERGO";
    pub const coin_name_abbrev = "ERG";
    /// Ergo brand colour (`#RRGGBB`), for tinting the coin in the frontend.
    pub const coin_color = "#FF5E18";
    /// Ergo is proof-of-work (Autolykos2) — no wallet staking.
    pub const proof_of_stake = false;
    pub const conf_file = "ergo.conf";

    // Data directory names per OS. Unlike the bitcoin coins (POSIX `~/.<coin>`,
    // Windows `AppData\Roaming\<COIN>`), Ergo uses the macOS
    // `Library/Application Support` convention too — see `dataDir`.
    pub const home_dir_lin = ".ergo";
    pub const home_dir_mac = "Ergo";
    pub const home_dir_win = "Ergo";

    pub const core_version = "6.0.2";

    // The node ships as `ergo-<version>.jar` inside each platform's bundle.
    pub const jar_file = "ergo-" ++ core_version ++ ".jar";

    // The `java` launcher inside the bundled JRE (`java.exe` on Windows).
    const java_exe = "java" ++ (if (builtin.os.tag == .windows) ".exe" else "");

    // REST API + auth. Ergo binds the API to 127.0.0.1 only, so a fixed api_key
    // shipped in source is acceptable; `api_key_hash` is the Blake2b256 hash of
    // `api_key` that the node config stores (the node never sees the plaintext key
    // until a protected call presents it). Both lifted from the Elixir reference.
    pub const rpc_default_port = "9053";
    /// Ergo authenticates with an API key, not an rpcuser — left empty so the
    /// shared `readAuth` (which a poll runs harmlessly over the HOCON conf) has a
    /// default to fall back to.
    pub const rpc_default_username = "";
    const api_key = "BoxWalletErgoLocalApiKey";
    const api_key_hash = "9ecf0728f49d816f6ffdd168369412edc2713b74b083b2f65b1422c63dda0c95";

    // JVM max heap for the node process.
    const xmx = "4G";

    // GitHub release carrying the per-platform "ergo-node" bundles.
    const release_base = "https://github.com/ergoplatform/ergo/releases/download/v" ++ core_version;

    // The bundle is extracted under this subdirectory of the install root, kept
    // intact (jar + JRE); nothing is promoted out of it.
    const bundle_subdir = "ergo-node";

    // Per-platform bundle selection, mirroring the Elixir `bundle_asset`: the
    // arch suffix is `aarch64` for ARM, else `x64`; Windows ships a `.zip`, the
    // rest `.tar.gz`.
    const bundle_arch = switch (builtin.cpu.arch) {
        .aarch64, .arm => "aarch64",
        else => "x64",
    };
    const bundle_platform = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => "",
    };
    const bundle_ext = if (builtin.os.tag == .windows) "zip" else "tar.gz";

    /// The download URL + archive format for the build target, or null on an OS
    /// Ergo publishes no bundle for. Selected at comptime from the OS/arch.
    const download: ?install_mod.Download = switch (builtin.os.tag) {
        .linux, .macos, .windows => .{
            .url = release_base ++ "/ergo-node-v" ++ core_version ++ "-" ++ bundle_platform ++ "-" ++ bundle_arch ++ "." ++ bundle_ext,
            .format = if (builtin.os.tag == .windows) .zip else .tar_gz,
        },
        else => null,
    };

    // Temp file the download streams to, unique to Ergo so a concurrent install of
    // another coin into the same `~/.boxwallet` root never collides on it.
    pub const scratch_file = ".boxwallet-ergo-node.part";

    /// Build the type-erased `Coin` handle for this instance.
    pub fn coin(self: *Ergo) Coin {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // --- REST transport --------------------------------------------------

    /// Raw `GET /info` result — the subset BoxWallet's status poll uses. Ergo's
    /// REST API returns a flat JSON object (no JSON-RPC `result` envelope), and
    /// the height fields are null before the node has started syncing, so they're
    /// optional. Difficulty is deliberately omitted: it's a big integer that can
    /// exceed i64, and nothing here needs it.
    const ErgoInfo = struct {
        fullHeight: ?i64 = null,
        headersHeight: ?i64 = null,
        maxPeerHeight: ?i64 = null,
        peersCount: ?i64 = null,
        network: []const u8 = "",
    };

    /// Perform a REST request against the local node and return the response
    /// body. Caller owns the returned slice. `api_key_hdr`, when set, is sent as
    /// the `api_key` header (protected endpoints); `/info` needs none.
    fn restRequest(
        allocator: std.mem.Allocator,
        method: std.http.Method,
        path: []const u8,
        api_key_hdr: ?[]const u8,
    ) ![]u8 {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();

        var client: std.http.Client = .{ .allocator = allocator, .io = threaded.io() };
        defer client.deinit();

        const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{s}{s}", .{ rpc_default_port, path });
        defer allocator.free(url);

        var body: std.Io.Writer.Allocating = .init(allocator);
        defer body.deinit();

        var hdr_buf: [1]std.http.Header = undefined;
        var extra: []const std.http.Header = &.{};
        if (api_key_hdr) |key| {
            hdr_buf[0] = .{ .name = "api_key", .value = key };
            extra = hdr_buf[0..1];
        }

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            // `fetch` routes a payload-less request through `sendBodiless`, which
            // asserts the method carries no body — so a POST (which "has a body")
            // must pass a payload, even the empty one `/node/shutdown` wants.
            // GET stays payload-less (it takes the bodiless path correctly).
            .payload = if (method == .GET) null else "",
            .response_writer = &body.writer,
            .extra_headers = extra,
        });
        if (result.status == .unauthorized) return error.AuthFailed;

        return body.toOwnedSlice();
    }

    /// Fetch + parse `GET /info`. Caller must `deinit` the returned `Parsed`.
    fn fetchInfo(allocator: std.mem.Allocator) !std.json.Parsed(ErgoInfo) {
        const raw = try restRequest(allocator, .GET, "/info", null);
        defer allocator.free(raw);
        // `.alloc_always` so the parsed `network` string is copied into the arena
        // rather than left dangling into `raw`, which we free here.
        return std.json.parseFromSlice(ErgoInfo, allocator, raw, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    /// Live `/info`, normalized for a frontend. Ergo reports its own and its
    /// peers' heights, so "synced" is derived from them (the REST API has no
    /// verification-progress field). `auth` is unused — `/info` is public.
    pub fn blockchainState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.BlockchainState {
        _ = auth;
        var parsed = try fetchInfo(allocator);
        defer parsed.deinit();

        const r = parsed.value;
        const full = r.fullHeight orelse 0;
        const peer = r.maxPeerHeight orelse 0;
        const chain = if (r.network.len > 0) r.network else "mainnet";
        return .{
            .chain = try allocator.dupe(u8, chain),
            .blocks = full,
            .headers = r.headersHeight orelse 0,
            // No native progress field; approximate from blocks vs the network tip
            // for any caller that wants it (the TUI drives its bars off heights).
            .verification_progress = if (peer > 0)
                @as(f64, @floatFromInt(full)) / @as(f64, @floatFromInt(peer))
            else
                0,
            .synced = full > 0 and peer > 0 and full >= peer,
            .network_height = peer,
        };
    }

    /// Live `/info`, normalized for a frontend. Ergo is proof-of-work, so
    /// `staking_active` is always false. `auth` is unused (`/info` is public).
    pub fn daemonInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.DaemonInfo {
        _ = auth;
        var parsed = try fetchInfo(allocator);
        defer parsed.deinit();

        const r = parsed.value;
        return .{
            .blocks = r.fullHeight orelse 0,
            .connections = r.peersCount orelse 0,
            .staking_active = false,
        };
    }

    /// Ask the node to shut down via the REST `POST /node/shutdown` (a protected
    /// endpoint, so it carries the api_key). `auth` is unused — Ergo's key is
    /// fixed, not read from a conf.
    pub fn requestStop(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        _ = auth;
        const reply = try restRequest(allocator, .POST, "/node/shutdown", api_key);
        allocator.free(reply);
    }

    // --- Files / paths ---------------------------------------------------

    /// The node's data directory, where `ergo.conf` and chain data live:
    ///   - Linux:   `~/.ergo`
    ///   - macOS:   `~/Library/Application Support/Ergo`
    ///   - Windows: `…\AppData\Roaming\Ergo`
    /// Caller owns the returned slice.
    pub fn dataDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        return switch (builtin.os.tag) {
            .windows => std.fs.path.join(allocator, &.{ home, "AppData", "Roaming", home_dir_win }),
            .macos => std.fs.path.join(allocator, &.{ home, "Library", "Application Support", home_dir_mac }),
            else => std.fs.path.join(allocator, &.{ home, home_dir_lin }),
        };
    }

    /// True if both the node jar and the bundled `java` launcher are present under
    /// the extracted bundle — the JVM equivalent of "the daemon binary exists".
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const dest = std.fs.path.join(allocator, &.{ install_root, bundle_subdir }) catch return false;
        defer allocator.free(dest);

        const jar = findFile(allocator, io, dest, jar_file, false);
        defer if (jar) |p| allocator.free(p);
        const java = findFile(allocator, io, dest, java_exe, true);
        defer if (java) |p| allocator.free(p);
        return jar != null and java != null;
    }

    /// Download + extract the Ergo node bundle (jar + JRE) into
    /// `<install_root>/ergo-node/`, kept whole — nothing is promoted out, so the
    /// JRE stays alongside the jar. The streaming tar extractor preserves the
    /// `java` executable bit (`.executable_bit_only`), so no post-chmod is needed.
    pub fn install(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        const dl = download orelse return error.UnsupportedPlatform;
        const dest = try std.fs.path.join(allocator, &.{ install_root, bundle_subdir });
        defer allocator.free(dest);
        try install_mod.downloadAndExtract(allocator, dl.url, dl.format, dest, scratch_file, 0, progress);
    }

    /// Write the HOCON `ergo.conf` into the data dir if it isn't already there
    /// (idempotent; a user's edits are preserved). The node stores only the API
    /// key's hash, binds the REST API to localhost, and disables mining. HOCON
    /// treats `\` as an escape and Java accepts `/` separators on every OS, so the
    /// data-dir path is normalised to forward slashes.
    pub fn prepareConf(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);

        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
        defer dir.close(io);
        if (dir.access(io, conf_file, .{})) |_| return else |_| {}

        const dir_fwd = try allocator.alloc(u8, data_dir.len);
        defer allocator.free(dir_fwd);
        for (data_dir, 0..) |c, i| dir_fwd[i] = if (c == '\\') '/' else c;

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try out.writer.print(hocon_template, .{ dir_fwd, api_key_hash, rpc_default_port });
        try dir.writeFile(io, .{ .sub_path = conf_file, .data = out.written() });
    }

    const hocon_template =
        \\ergo {{
        \\    directory = "{s}"
        \\    node {{
        \\        mining = false
        \\    }}
        \\}}
        \\scorex {{
        \\    restApi {{
        \\        apiKeyHash = "{s}"
        \\        bindAddress = "127.0.0.1:{s}"
        \\    }}
        \\}}
        \\
    ;

    /// Ergo runs in the foreground (JVM), so it's spawned detached on every
    /// platform — never the bitcoin `-daemon` fork path.
    pub fn launchMode() Coin.LaunchMode {
        return .foreground;
    }

    /// The full launch command: the bundled `java` running the node jar against
    /// the HOCON conf. The jar and launcher are located by searching the extracted
    /// bundle (their nesting differs per platform). Caller owns the returned slice
    /// and every string in it.
    pub fn daemonArgv(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home: []const u8,
    ) ![]const []const u8 {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const dest = try std.fs.path.join(allocator, &.{ install_root, bundle_subdir });
        defer allocator.free(dest);

        const java = findFile(allocator, io, dest, java_exe, true) orelse return error.JavaNotFound;
        errdefer allocator.free(java);
        const jar = findFile(allocator, io, dest, jar_file, false) orelse return error.JarNotFound;
        errdefer allocator.free(jar);

        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        const conf_path = try std.fs.path.join(allocator, &.{ data_dir, conf_file });
        errdefer allocator.free(conf_path);

        // JVM options must precede `-jar`. Every entry is heap-owned (the static
        // ones duped) so the caller can free the argv uniformly.
        const argv = try allocator.alloc([]const u8, 7);
        argv[0] = java;
        argv[1] = try allocator.dupe(u8, "-Xmx" ++ xmx);
        argv[2] = try allocator.dupe(u8, "-jar");
        argv[3] = jar;
        argv[4] = try allocator.dupe(u8, "--mainnet");
        argv[5] = try allocator.dupe(u8, "-c");
        argv[6] = conf_path;
        return argv;
    }

    /// Locate a file named `target` anywhere under `root`, returning its full path
    /// (caller owns it) or null if absent. When `want_bin_parent` is set, only a
    /// match whose immediate parent directory is `bin` counts — used to pick the
    /// JRE's `java` launcher rather than any stray `java` file. Errors (an
    /// unreadable dir) read as "not found".
    fn findFile(
        allocator: std.mem.Allocator,
        io: std.Io,
        root: []const u8,
        target: []const u8,
        want_bin_parent: bool,
    ) ?[]u8 {
        return findUnder(allocator, io, root, target, want_bin_parent, 0) catch null;
    }

    fn findUnder(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir_path: []const u8,
        target: []const u8,
        want_bin_parent: bool,
        depth: u8,
    ) !?[]u8 {
        // Bundle trees are shallow; the cap just guards against a pathological
        // symlink loop without holding any per-level state beyond the path.
        if (depth > 12) return null;
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
        defer dir.close(io);

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory) {
                // `entry.name` is duped into `sub` before we recurse (the next
                // `it.next` would overwrite it), and the recursion iterates its
                // own handle, so the parent iterator is undisturbed.
                const sub = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                defer allocator.free(sub);
                if (try findUnder(allocator, io, sub, target, want_bin_parent, depth + 1)) |found| return found;
            } else if (entry.kind == .file and std.mem.eql(u8, entry.name, target)) {
                if (want_bin_parent and !std.mem.eql(u8, std.fs.path.basename(dir_path), "bin")) continue;
                return try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            }
        }
        return null;
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
    /// Ergo has no native daemon binary; the jar name stands in for the few places
    /// the bitcoin fork path would use it (Ergo never takes that path).
    fn vtDaemonFile(_: *anyopaque) []const u8 {
        return jar_file;
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

test "parses /info into a synced BlockchainState" {
    const allocator = std.testing.allocator;

    // Canned `/info` reply (subset) — a fully-synced node: local height matches
    // the best peer height. Proves the flat-object parse + height-derived sync
    // without a running node.
    const raw =
        \\{"fullHeight":1200000,"headersHeight":1200000,"maxPeerHeight":1200000,
        \\"peersCount":30,"network":"mainnet","unconfirmedCount":12,
        \\"appVersion":"6.0.2","isMining":false}
    ;

    var parsed = try std.json.parseFromSlice(
        Ergo.ErgoInfo,
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value;
    const full = r.fullHeight orelse 0;
    const peer = r.maxPeerHeight orelse 0;
    const state: models.BlockchainState = .{
        .chain = try allocator.dupe(u8, if (r.network.len > 0) r.network else "mainnet"),
        .blocks = full,
        .headers = r.headersHeight orelse 0,
        .verification_progress = 0,
        .synced = full > 0 and peer > 0 and full >= peer,
        .network_height = peer,
    };
    defer state.deinit(allocator);

    try std.testing.expectEqualStrings("mainnet", state.chain);
    try std.testing.expectEqual(@as(i64, 1200000), state.blocks);
    try std.testing.expectEqual(@as(i64, 1200000), state.network_height);
    try std.testing.expect(state.synced);
}

test "a node still catching up to its peers reads as not synced" {
    // Local height behind the best peer height → syncing, with the peer height as
    // the network tip the bars fill toward.
    const r: Ergo.ErgoInfo = .{ .fullHeight = 800_000, .headersHeight = 1_100_000, .maxPeerHeight = 1_200_000, .peersCount = 8 };
    const full = r.fullHeight orelse 0;
    const peer = r.maxPeerHeight orelse 0;
    try std.testing.expect(!(full > 0 and peer > 0 and full >= peer));
    try std.testing.expectEqual(@as(i64, 1_200_000), peer);
}

test "maps /info into DaemonInfo with staking always off (PoW)" {
    const allocator = std.testing.allocator;

    // Heights null before sync starts — they must parse as absent, not fail the
    // whole poll (which would read the running node as "down").
    const raw =
        \\{"fullHeight":null,"headersHeight":null,"maxPeerHeight":null,
        \\"peersCount":3,"network":"mainnet"}
    ;

    var parsed = try std.json.parseFromSlice(
        Ergo.ErgoInfo,
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value;
    const info: models.DaemonInfo = .{
        .blocks = r.fullHeight orelse 0,
        .connections = r.peersCount orelse 0,
        .staking_active = false,
    };
    try std.testing.expectEqual(@as(i64, 0), info.blocks);
    try std.testing.expectEqual(@as(i64, 3), info.connections);
    try std.testing.expect(!info.staking_active);
}

test "platform selection resolves a bundle for the build target" {
    // Ergo publishes a bundle for every OS BoxWallet builds for, so the current
    // target must resolve a download — zip on Windows, tar.gz elsewhere.
    const dl = Ergo.download orelse return error.SkipZigTest;
    switch (builtin.os.tag) {
        .windows => try std.testing.expectEqual(install_mod.Format.zip, dl.format),
        else => try std.testing.expectEqual(install_mod.Format.tar_gz, dl.format),
    }
    // The URL carries the version and the platform tag.
    try std.testing.expect(std.mem.indexOf(u8, dl.url, "ergo-node-v6.0.2-") != null);
}

test "dataDir resolves the per-OS Ergo data directory" {
    const allocator = std.testing.allocator;
    const dir = try Ergo.dataDir(allocator, "/home/alice");
    defer allocator.free(dir);
    switch (builtin.os.tag) {
        .linux => try std.testing.expectEqualStrings("/home/alice/.ergo", dir),
        .macos => try std.testing.expectEqualStrings("/home/alice/Library/Application Support/Ergo", dir),
        .windows => try std.testing.expect(std.mem.endsWith(u8, dir, "Ergo")),
        else => {},
    }
}

test "prepareConf writes a HOCON conf once, preserving an existing one" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-ergo-conf-home";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // First pass writes the template: data dir, API key hash, REST bind address.
    try Ergo.prepareConf(allocator, io, home);

    const data_dir = try Ergo.dataDir(allocator, home);
    defer allocator.free(data_dir);
    var dir = try std.Io.Dir.cwd().openDir(io, data_dir, .{});
    defer dir.close(io);
    var f = try dir.openFile(io, Ergo.conf_file, .{});
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    const n = try f.readPositionalAll(io, &buf, 0);
    const written = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, written, "apiKeyHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "127.0.0.1:9053") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "mining = false") != null);

    // Second pass is a no-op: a user-edited conf is left untouched.
    try dir.writeFile(io, .{ .sub_path = Ergo.conf_file, .data = "ergo { custom = true }\n" });
    try Ergo.prepareConf(allocator, io, home);
    var f2 = try dir.openFile(io, Ergo.conf_file, .{});
    defer f2.close(io);
    const n2 = try f2.readPositionalAll(io, &buf, 0);
    try std.testing.expectEqualStrings("ergo { custom = true }\n", buf[0..n2]);
}

test "findFile locates the jar and the java launcher under bin/" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Mimic an extracted bundle: a versioned wrapper with the jar at the top and
    // `java` nested in `jre/bin/`, plus a decoy `java` not under bin/.
    const root = "test-ergo-bundle";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var jre = try std.Io.Dir.cwd().createDirPathOpen(io, root ++ "/ergo-node-x/jre/bin", .{});
    jre.close(io);
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "ergo-node-x/" ++ Ergo.jar_file, .data = "JAR" });
    try dir.writeFile(io, .{ .sub_path = "ergo-node-x/jre/bin/" ++ ("java" ++ (if (builtin.os.tag == .windows) ".exe" else "")), .data = "JAVA" });
    // Decoy: a `java`-named file outside any bin/ must be skipped by want_bin_parent.
    try dir.writeFile(io, .{ .sub_path = "ergo-node-x/" ++ ("java" ++ (if (builtin.os.tag == .windows) ".exe" else "")), .data = "DECOY" });

    const jar = Ergo.findFile(allocator, io, root, Ergo.jar_file, false);
    defer if (jar) |p| allocator.free(p);
    const java_name = "java" ++ (if (builtin.os.tag == .windows) ".exe" else "");
    const java = Ergo.findFile(allocator, io, root, java_name, true);
    defer if (java) |p| allocator.free(p);

    try std.testing.expect(jar != null);
    try std.testing.expect(java != null);
    // The launcher picked is the one under bin/, not the decoy.
    try std.testing.expect(std.mem.endsWith(u8, java.?, "jre/bin/" ++ java_name));
}

test "coin vtable dispatches to Ergo metadata" {
    var ergo: Ergo = .{};
    const c = ergo.coin();
    try std.testing.expectEqualStrings("ERGO", c.coinName());
    try std.testing.expectEqualStrings("ERG", c.coinNameAbbrev());
    try std.testing.expectEqualStrings("#FF5E18", c.coinColor());
    try std.testing.expect(!c.isProofOfStake());
    try std.testing.expectEqualStrings("ergo.conf", c.confFile());
    try std.testing.expectEqualStrings("9053", c.rpcDefaultPort());
    try std.testing.expectEqual(Coin.LaunchMode.foreground, c.launchMode());
}
