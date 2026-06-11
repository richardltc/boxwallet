const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const install_mod = @import("../install.zig");
const Coin = @import("../coin.zig").Coin;

/// Epic Cash (EPIC) backend — the node daemon only (no wallet yet), so this
/// coin reports chain-sync status the way the rest of BoxWallet does and nothing
/// more. Built fresh against Epic 4.0.3 (released 2026-06-10); the old Go
/// reference targeted 3.x with a different distribution and a (stale, bitcoin-
/// style) RPC, so it isn't a line-by-line port.
///
/// Epic is a MimbleWimble chain (a Grin fork), so it is unlike the bitcoin-core
/// forks the rest of BoxWallet ports — closer in shape to Ergo:
///
///   * **Distribution** — upstream publishes a single `epic` node binary, and
///     only for **linux/amd64** as of 4.0.3. Other targets resolve no download
///     (`UnsupportedPlatform`). The `.tar.gz` nests the binary under a versioned
///     wrapper dir (no `bin/`), which `promoteAndTidy` lifts to the install root.
///   * **Launch** — `epic server run`, run in the foreground of its own process
///     (it doesn't fork like a bitcoin `-daemon`), so it's spawned detached and
///     the status poll confirms it came up.
///   * **API** — a JSON-RPC 2.0 **Owner API** at `127.0.0.1:3413/v2/owner`. Its
///     `get_status` method drives the poll: it reports `sync_status`, peer
///     `connections`, the chain `tip`, and (while syncing) a `sync_info` with the
///     current/highest heights. The node binds the API to localhost only.
///   * **Auth** — the Owner API requires HTTP basic auth (`epic:<secret>`, the
///     secret read from `~/.epic/main/.api_secret`). BoxWallet pre-seeds that
///     file with a fixed secret before first launch so the auth is deterministic
///     (the daemon only generates a random secret when the file is absent).
///     Shipping a fixed secret is acceptable for the same reason as Ergo's
///     api_key: the API is bound to 127.0.0.1.
///   * **Consensus** — proof-of-work, so no staking.
///   * **Stop** — the Owner API exposes no shutdown method, so the node is
///     stopped by sending it SIGTERM (Linux-only, which is the only target Epic
///     installs on).
pub const Epic = struct {
    pub const coin_name = "Epic Cash";
    pub const coin_name_abbrev = "EPIC";
    /// Epic brand colour (`#RRGGBB`), for tinting the coin in the frontend.
    pub const coin_color = "#deac55";
    /// Epic is proof-of-work (MimbleWimble) — no wallet staking.
    pub const proof_of_stake = false;

    pub const core_version = "4.0.3";

    // `.exe` on Windows (a future target); Epic ships only linux/amd64 today.
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    pub const daemon_file = "epic" ++ exe_suffix;

    // Epic stores its config + chain data under a home-relative `.epic/<chain>`
    // (Grin convention), not the platform AppData dir — mainnet is `~/.epic/main`.
    pub const home_subdir = ".epic";
    pub const chain_dir = "main";

    // The node serves both the Owner and Foreign JSON-RPC APIs on this localhost
    // port on mainnet (P2P is 3414). We only call the Owner API's get_status.
    pub const rpc_default_port = "3413";
    /// Epic's Owner API authenticates with username `epic` + the api secret, not
    /// an rpcuser/rpcpassword conf — left as the basic-auth username for the few
    /// shared paths that read it; the poll uses the fixed header below.
    pub const rpc_default_username = "epic";

    // Fixed Owner-API secret BoxWallet seeds into `~/.epic/main/.api_secret` and
    // authenticates with. Acceptable to ship because the API binds to 127.0.0.1
    // only (same rationale as Ergo's fixed api_key). The daemon reads only the
    // first line of the secret file.
    const api_secret = "BoxWalletEpicLocalApiSecret";
    const secret_file = ".api_secret";

    // Epic's MimbleWimble block target is 60s; used to turn the height gap into a
    // rough "behind by" estimate while syncing (the Owner API reports no tip
    // timestamp). An approximation, like Nerva's block-gap estimate.
    const block_target_secs: i64 = 60;

    // GitHub release carrying the node binary.
    const release_base = "https://github.com/EpicCash/epic/releases/download/v" ++ core_version;

    // The `.tar.gz` wraps the binary in `epic-<ver>-linux-amd64/` with no `bin/`
    // subdir, so promote lifts `epic` straight out of the wrapper.
    const extracted_dir = "epic-" ++ core_version ++ "-linux-amd64";
    const bin_subdir = "";
    const promote_files = [_][]const u8{daemon_file};

    // Temp file the download streams to, unique to Epic so a concurrent install of
    // another coin into the same `~/.boxwallet` root never collides on it.
    pub const scratch_file = ".boxwallet-epic.part";

    /// The download URL + archive format for the build target, or null on a
    /// target Epic publishes no binary for. As of 4.0.3 that's linux/amd64 only.
    const download: ?install_mod.Download = switch (builtin.os.tag) {
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => .{ .url = release_base ++ "/" ++ extracted_dir ++ ".tar.gz", .format = .tar_gz },
            else => null,
        },
        else => null,
    };

    /// Build the type-erased `Coin` handle for this instance.
    pub fn coin(self: *Epic) Coin {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // --- Owner API transport ---------------------------------------------

    /// JSON-RPC 2.0 envelope for an Owner API reply. Grin/Epic wraps the method's
    /// `Result` in `{"Ok": …}` (or `{"Err": …}`) inside `result`, so a successful
    /// `get_status` is `{"result":{"Ok":{…Status…}}}`. A null `Ok` (an `Err`, or
    /// an unexpected shape) reads as "no usable status".
    const StatusEnvelope = struct {
        result: ?StatusResult = null,
    };
    const StatusResult = struct {
        Ok: ?Status = null,
    };

    /// The subset of the Owner API `get_status` result BoxWallet uses. Defaults
    /// keep the parse resilient to fields the daemon omits. `connections` is a
    /// JSON number (the Rust `Status.connections: u32`); `sync_info` is absent
    /// (serde skips it) outside the active sync phases.
    const Status = struct {
        connections: i64 = 0,
        sync_status: []const u8 = "",
        tip: Tip = .{},
        sync_info: ?SyncInfo = null,
    };
    const Tip = struct {
        height: i64 = 0,
    };
    const SyncInfo = struct {
        current_height: i64 = 0,
        highest_height: i64 = 0,
    };

    /// Normalized view of a `get_status`, derived once and shared by
    /// `blockchainState`/`daemonInfo`. Pulled out as a pure function so the
    /// mapping is unit-testable without a running node.
    const Derived = struct {
        synced: bool,
        blocks: i64,
        headers: i64,
        network: i64,
        connections: i64,
        seconds_behind: i64,
    };

    /// Map a raw `get_status` into normalized sync figures.
    ///   - `blocks`  — the accepted chain tip (`tip.height`).
    ///   - `headers` — download progress toward the network tip: `sync_info`'s
    ///     `current_height` while syncing (header/body download), else the tip.
    ///   - `network` — the target height: `sync_info`'s `highest_height` while
    ///     syncing, else the tip.
    ///   - `synced`  — `sync_status == "no_sync"` *and* we have peers and a tip.
    ///     The peer gate matters: a freshly-started node with no peers also reads
    ///     `no_sync` (Grin's initial state), which must not be mistaken for caught
    ///     up.
    ///   - `seconds_behind` — the height gap × the 60s block target (0 when synced
    ///     or the target isn't known yet).
    fn derive(st: Status) Derived {
        const tip = st.tip.height;
        var headers = tip;
        var network = tip;
        if (st.sync_info) |si| {
            headers = @max(si.current_height, tip);
            network = @max(si.highest_height, tip);
        }
        const synced = std.mem.eql(u8, st.sync_status, "no_sync") and st.connections > 0 and tip > 0;
        const gap = network - tip;
        const seconds_behind: i64 = if (synced or gap <= 0) 0 else gap * block_target_secs;
        return .{
            .synced = synced,
            .blocks = tip,
            .headers = headers,
            .network = network,
            .connections = st.connections,
            .seconds_behind = seconds_behind,
        };
    }

    /// POST a JSON-RPC `method` (no params) at the local Owner API and return the
    /// raw response body. Caller owns the returned slice. Carries the fixed basic-
    /// auth header; a 401 surfaces as `error.AuthFailed`.
    fn ownerCall(allocator: std.mem.Allocator, method: []const u8) ![]u8 {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();

        var client: std.http.Client = .{ .allocator = allocator, .io = threaded.io() };
        defer client.deinit();

        const url = "http://127.0.0.1:" ++ rpc_default_port ++ "/v2/owner";

        const payload = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":[]}}",
            .{method},
        );
        defer allocator.free(payload);

        const auth_header = try basicAuthHeader(allocator, rpc_default_username, api_secret);
        defer allocator.free(auth_header);

        var body: std.Io.Writer.Allocating = .init(allocator);
        defer body.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .response_writer = &body.writer,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "authorization", .value = auth_header },
            },
        });
        if (result.status == .unauthorized) return error.AuthFailed;

        return body.toOwnedSlice();
    }

    /// Fetch + parse `get_status`, returning the normalized `Derived` view.
    fn fetchStatus(allocator: std.mem.Allocator) !Derived {
        const raw = try ownerCall(allocator, "get_status");
        defer allocator.free(raw);
        var parsed = try std.json.parseFromSlice(StatusEnvelope, allocator, raw, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const st = (parsed.value.result orelse return error.DaemonNotReady).Ok orelse
            return error.DaemonNotReady;
        return derive(st);
    }

    /// Live `get_status`, normalized for the frontend. Epic reports its sync phase
    /// and the network tip directly, so "synced" comes from the daemon rather than
    /// a peer-height comparison. `auth` is unused — the Owner API auth is fixed.
    pub fn blockchainState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.BlockchainState {
        _ = auth;
        const d = try fetchStatus(allocator);
        return .{
            // BoxWallet runs mainnet only; the Owner API doesn't echo the chain.
            .chain = try allocator.dupe(u8, "mainnet"),
            .blocks = d.blocks,
            .headers = d.headers,
            .verification_progress = if (d.network > 0)
                @as(f64, @floatFromInt(d.blocks)) / @as(f64, @floatFromInt(d.network))
            else
                0,
            .synced = d.synced,
            .network_height = d.network,
            // No tip timestamp from get_status; supply the gap-derived estimate
            // directly (the frontend prefers `seconds_behind` over `tip_time`).
            .seconds_behind = d.seconds_behind,
        };
    }

    /// Live `get_status`, normalized for the frontend. Epic is proof-of-work, so
    /// `staking_active` is always false. `auth` is unused (fixed Owner API auth).
    pub fn daemonInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.DaemonInfo {
        _ = auth;
        const d = try fetchStatus(allocator);
        return .{
            .blocks = d.blocks,
            .connections = d.connections,
            .staking_active = false,
        };
    }

    /// The Owner API has no shutdown method, so stop the node by sending it
    /// SIGTERM. Linux-only — Epic installs only on linux/amd64 — and a no-op
    /// elsewhere so the code stays cross-platform. The caller's probe loop then
    /// confirms the daemon went down. `auth` is unused.
    pub fn requestStop(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        _ = auth;
        if (builtin.os.tag != .linux) return;

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var proc = std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch return;
        defer proc.close(io);

        var it = proc.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory or entry.name.len == 0 or !std.ascii.isDigit(entry.name[0])) continue;
            const pid = std.fmt.parseInt(std.posix.pid_t, entry.name, 10) catch continue;

            // Match our node precisely: the process command is `epic` and its
            // cmdline carries the `server` subcommand we launched it with — so a
            // bystander process merely named "epic" isn't signalled.
            if (!isEpicServer(io, proc, entry.name)) continue;
            std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        }
    }

    /// True if `/proc/<pid>` is an Epic node we launched: its `comm` is `epic`
    /// and its `cmdline` contains the `server` subcommand. Best-effort — any IO
    /// hiccup reads as "not a match" so we never signal the wrong process.
    fn isEpicServer(io: std.Io, proc: std.Io.Dir, pid_name: []const u8) bool {
        var path_buf: [40]u8 = undefined;

        const comm_path = std.fmt.bufPrint(&path_buf, "{s}/comm", .{pid_name}) catch return false;
        var cf = proc.openFile(io, comm_path, .{}) catch return false;
        defer cf.close(io);
        var cbuf: [64]u8 = undefined;
        const cn = cf.readPositionalAll(io, &cbuf, 0) catch return false;
        if (!std.mem.eql(u8, std.mem.trim(u8, cbuf[0..cn], " \t\r\n"), "epic")) return false;

        const cl_path = std.fmt.bufPrint(&path_buf, "{s}/cmdline", .{pid_name}) catch return false;
        var lf = proc.openFile(io, cl_path, .{}) catch return false;
        defer lf.close(io);
        // cmdline is NUL-separated argv; "server" appears as a standalone arg.
        var lbuf: [4096]u8 = undefined;
        const ln = lf.readPositionalAll(io, &lbuf, 0) catch return false;
        return std.mem.indexOf(u8, lbuf[0..ln], "server") != null;
    }

    // --- Files / paths ---------------------------------------------------

    /// The node's data directory, where `epic-server.toml`, `.api_secret`, and the
    /// chain data live: `<home>/.epic/main` on every platform (Epic uses a home-
    /// relative dir, not the platform AppData root). Caller owns the returned slice.
    pub fn dataDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &.{ home, home_subdir, chain_dir });
    }

    /// True if the `epic` node binary is present under `install_root`.
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, daemon_file);
    }

    /// Download + unarchive the Epic node binary into `install_root`. The archive
    /// nests `epic` under a versioned wrapper dir (no `bin/`), so it's extracted
    /// whole (`strip = 0`) and `promoteAndTidy` lifts the binary to the root.
    pub fn install(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        const dl = download orelse return error.UnsupportedPlatform;
        try install_mod.downloadAndExtract(allocator, dl.url, dl.format, install_root, scratch_file, 0, progress);
        try install_mod.promoteAndTidy(allocator, install_root, extracted_dir, bin_subdir, &promote_files);
    }

    /// Pre-seed the Owner API secret before first launch so BoxWallet's fixed
    /// basic-auth header works. The data dir is created if absent; the secret file
    /// is written only when missing, so the daemon's own (or a user's) secret is
    /// never clobbered. The node generates the rest of `epic-server.toml` itself
    /// on first run. `io` is the caller's blocking io. Idempotent.
    pub fn prepareConf(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);

        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
        defer dir.close(io);

        // Present already → leave it (the daemon, or the user, owns its secret).
        if (dir.access(io, secret_file, .{})) |_| return else |_| {}
        // The daemon reads only the first line; a trailing newline is harmless.
        try dir.writeFile(io, .{ .sub_path = secret_file, .data = api_secret ++ "\n" });
    }

    /// Epic's node runs in the foreground of its own process (no bitcoin `-daemon`
    /// fork), so it's spawned detached on every platform.
    pub fn launchMode() Coin.LaunchMode {
        return .foreground;
    }

    /// The launch command: `epic server run`. No `--config_file` — the node finds
    /// (or generates) `~/.epic/main/epic-server.toml` on its own, and pointing
    /// `--config_file` at a not-yet-created file would error. Caller owns the
    /// returned slice and every string in it.
    pub fn daemonArgv(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home: []const u8,
    ) ![]const []const u8 {
        _ = home;
        const bin = try std.fs.path.join(allocator, &.{ install_root, daemon_file });
        errdefer allocator.free(bin);

        const argv = try allocator.alloc([]const u8, 3);
        argv[0] = bin;
        argv[1] = try allocator.dupe(u8, "server");
        argv[2] = try allocator.dupe(u8, "run");
        return argv;
    }

    /// Build an `Authorization: Basic <base64(user:secret)>` header value. Caller
    /// owns the returned slice. (Mirrors `rpc.zig`'s private helper; Epic's
    /// transport is self-contained on the Owner API path rather than the shared
    /// bitcoin JSON-RPC.)
    fn basicAuthHeader(allocator: std.mem.Allocator, user: []const u8, secret: []const u8) ![]u8 {
        const creds = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ user, secret });
        defer allocator.free(creds);

        const enc = std.base64.standard.Encoder;
        const b64 = try allocator.alloc(u8, enc.calcSize(creds.len));
        defer allocator.free(b64);
        _ = enc.encode(b64, creds);

        return std.fmt.allocPrint(allocator, "Basic {s}", .{b64});
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
    /// Epic has no bitcoin-style `key=value` conf BoxWallet writes; the node owns
    /// `epic-server.toml`. The name is still surfaced for the few generic places
    /// that show it.
    fn vtConfFile(_: *anyopaque) []const u8 {
        return "epic-server.toml";
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

test "derive maps a fully-synced get_status to synced with no backlog" {
    // no_sync + peers + a tip → caught up. sync_info is absent when synced.
    const st: Epic.Status = .{ .connections = 8, .sync_status = "no_sync", .tip = .{ .height = 371553 } };
    const d = Epic.derive(st);
    try std.testing.expect(d.synced);
    try std.testing.expectEqual(@as(i64, 371553), d.blocks);
    try std.testing.expectEqual(@as(i64, 371553), d.network);
    try std.testing.expectEqual(@as(i64, 0), d.seconds_behind);
}

test "derive treats no_sync with no peers as not yet synced" {
    // A freshly-started node reports no_sync before it has any peers; without the
    // peer gate this would falsely read as caught up.
    const st: Epic.Status = .{ .connections = 0, .sync_status = "no_sync", .tip = .{ .height = 12 } };
    try std.testing.expect(!Epic.derive(st).synced);
}

test "derive maps a header-sync get_status to a sync target and backlog" {
    // Mid header-sync: tip still low, sync_info carries the download progress
    // (current_height) and the target (highest_height).
    const st: Epic.Status = .{
        .connections = 8,
        .sync_status = "header_sync",
        .tip = .{ .height = 100 },
        .sync_info = .{ .current_height = 50_000, .highest_height = 371_553 },
    };
    const d = Epic.derive(st);
    try std.testing.expect(!d.synced);
    try std.testing.expectEqual(@as(i64, 100), d.blocks);
    try std.testing.expectEqual(@as(i64, 50_000), d.headers); // download progress
    try std.testing.expectEqual(@as(i64, 371_553), d.network); // target tip
    // (371553 - 100) blocks × 60s.
    try std.testing.expectEqual(@as(i64, (371_553 - 100) * 60), d.seconds_behind);
}

test "fetchStatus-shaped JSON parses through the Ok envelope" {
    const allocator = std.testing.allocator;
    // The Owner API wraps the method's Result in {"Ok": …} inside `result`.
    const raw =
        \\{"id":1,"jsonrpc":"2.0","result":{"Ok":{
        \\"protocol_version":2,"user_agent":"MW/Epic 4.0.3","connections":8,
        \\"tip":{"height":300000,"last_block_pushed":"00001d","prev_block_to_last":"000002","total_difficulty":1127628411943045},
        \\"sync_status":"body_sync","sync_info":{"current_height":300000,"highest_height":371553}
        \\}}}
    ;
    var parsed = try std.json.parseFromSlice(Epic.StatusEnvelope, allocator, raw, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const st = parsed.value.result.?.Ok.?;
    try std.testing.expectEqual(@as(i64, 8), st.connections);
    try std.testing.expectEqualStrings("body_sync", st.sync_status);
    try std.testing.expectEqual(@as(i64, 300000), st.tip.height);
    try std.testing.expectEqual(@as(i64, 371553), st.sync_info.?.highest_height);

    const d = Epic.derive(st);
    try std.testing.expect(!d.synced);
    try std.testing.expectEqual(@as(i64, 300000), d.blocks);
    try std.testing.expectEqual(@as(i64, 371553), d.network);
}

test "an Err / empty Owner result yields no usable status" {
    const allocator = std.testing.allocator;
    // result present but Ok absent (an Err reply, or warm-up) → null Ok.
    const raw = "{\"id\":1,\"jsonrpc\":\"2.0\",\"result\":{\"Err\":\"not ready\"}}";
    var parsed = try std.json.parseFromSlice(Epic.StatusEnvelope, allocator, raw, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.result.?.Ok == null);
}

test "platform selection resolves a download only on linux/amd64" {
    // Epic publishes only a linux/amd64 binary as of 4.0.3.
    if (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
        const dl = Epic.download orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(install_mod.Format.tar_gz, dl.format);
        try std.testing.expect(std.mem.indexOf(u8, dl.url, "epic-4.0.3-linux-amd64.tar.gz") != null);
    } else {
        try std.testing.expect(Epic.download == null);
    }
}

test "dataDir resolves ~/.epic/main" {
    const allocator = std.testing.allocator;
    const dir = try Epic.dataDir(allocator, "/home/alice");
    defer allocator.free(dir);
    const expected = "/home/alice/" ++ Epic.home_subdir ++ "/" ++ Epic.chain_dir;
    if (builtin.os.tag != .windows) try std.testing.expectEqualStrings(expected, dir);
}

test "prepareConf seeds the api secret once, preserving an existing one" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-epic-conf-home";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // First pass writes the fixed secret.
    try Epic.prepareConf(allocator, io, home);

    const data_dir = try Epic.dataDir(allocator, home);
    defer allocator.free(data_dir);
    var dir = try std.Io.Dir.cwd().openDir(io, data_dir, .{});
    defer dir.close(io);
    var f = try dir.openFile(io, Epic.secret_file, .{});
    defer f.close(io);
    var buf: [256]u8 = undefined;
    const n = try f.readPositionalAll(io, &buf, 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], Epic.api_secret) != null);

    // Second pass is a no-op: a daemon-/user-generated secret is left untouched.
    try dir.writeFile(io, .{ .sub_path = Epic.secret_file, .data = "someothersecret\n" });
    try Epic.prepareConf(allocator, io, home);
    var f2 = try dir.openFile(io, Epic.secret_file, .{});
    defer f2.close(io);
    const n2 = try f2.readPositionalAll(io, &buf, 0);
    try std.testing.expectEqualStrings("someothersecret\n", buf[0..n2]);
}

test "daemonArgv builds `epic server run` with the install-root binary" {
    const allocator = std.testing.allocator;
    const argv = try Epic.daemonArgv(allocator, "/home/alice/.boxwallet", "/home/alice");
    defer {
        for (argv) |s| allocator.free(s);
        allocator.free(argv);
    }
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expect(std.mem.endsWith(u8, argv[0], Epic.daemon_file));
    try std.testing.expectEqualStrings("server", argv[1]);
    try std.testing.expectEqualStrings("run", argv[2]);
}

test "basicAuthHeader base64-encodes epic:<secret>" {
    const allocator = std.testing.allocator;
    const header = try Epic.basicAuthHeader(allocator, "epic", "secret");
    defer allocator.free(header);
    // base64("epic:secret") == "ZXBpYzpzZWNyZXQ="
    try std.testing.expectEqualStrings("Basic ZXBpYzpzZWNyZXQ=", header);
}

test "coin vtable dispatches to Epic metadata, no wallet" {
    var epic: Epic = .{};
    const c = epic.coin();
    try std.testing.expectEqualStrings("Epic Cash", c.coinName());
    try std.testing.expectEqualStrings("EPIC", c.coinNameAbbrev());
    try std.testing.expectEqualStrings("#deac55", c.coinColor());
    try std.testing.expectEqualStrings("4.0.3", c.coreVersion());
    try std.testing.expect(!c.isProofOfStake());
    try std.testing.expectEqualStrings("3413", c.rpcDefaultPort());
    try std.testing.expectEqual(Coin.LaunchMode.foreground, c.launchMode());
    // Node only — no wallet, no balance.
    try std.testing.expect(!c.supportsWallet());
    try std.testing.expect(!c.supportsBalance());
}
