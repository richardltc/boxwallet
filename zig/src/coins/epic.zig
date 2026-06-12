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
///   * **Auth** — the Owner API requires HTTP basic auth (`epic:<secret>`). The
///     secret lives in `~/.epic/main/.api_secret`: BoxWallet pre-seeds a fixed
///     one before first launch (see `prepareConf`), but the daemon generates its
///     own random secret if it ever runs without that seed. So each call *reads
///     the secret from the file* (`apiSecret`) and authenticates with whatever is
///     there, falling back to the built-in fixed value only if the file can't be
///     read. Authenticating against the file — rather than assuming the fixed
///     value — is what stops a daemon-owned random secret from 401-ing every
///     status poll. Shipping a fixed fallback is acceptable for the same reason
///     as Ergo's api_key: the API is bound to 127.0.0.1.
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

    // Fixed Owner-API secret BoxWallet pre-seeds into `~/.epic/main/.api_secret`
    // when none exists (see `prepareConf`), and the fallback `apiSecret` uses if
    // the file can't be read. The *live* auth secret is whatever the file holds —
    // the daemon generates its own random one if it first ran unseeded. Acceptable
    // to ship a fixed fallback because the API binds to 127.0.0.1 only (same
    // rationale as Ergo's fixed api_key). The daemon reads only the first line.
    const api_secret = "BoxWalletEpicLocalApiSecret";
    const secret_file = ".api_secret";

    // The node's server config. BoxWallet doesn't write it from scratch — the
    // daemon generates a full default via `epic server config` — but it patches a
    // handful of keys (see `managed_conf`) to keep the node safe and well-seeded.
    pub const conf_file = "epic-server.toml";

    // The keys BoxWallet enforces in `epic-server.toml` on every launch (idempotent
    // self-heal). Each is set within its `[section]`, replacing an existing line
    // (commented or not) or inserted at the section's end if missing:
    //   * `api_http_addr` — pin the node/Owner API to localhost. Critical: the
    //     fixed-secret auth is only acceptable because the API never leaves
    //     127.0.0.1, so we heal a `0.0.0.0` someone may have pasted in.
    //   * `run_tui` — off; BoxWallet launches the node detached with no terminal,
    //     and the ncurses TUI without a TTY takes the process down.
    //   * `seeding_type` — DNSSeed: empirically the only mode that keeps automatic
    //     peer discovery (List pins static IPs and disables DNS). See the seeding
    //     test notes.
    //   * `peers_preferred` — a curated, known-live node dialed *in addition* to
    //     DNS (preferred peers are merged with the seed set regardless of mode), as
    //     a reliability hedge if DNS resolution ever fails. Not a replacement for
    //     discovery — just a fallback.
    const ManagedKey = struct { section: []const u8, key: []const u8, value: []const u8 };
    const managed_conf = [_]ManagedKey{
        .{ .section = "server", .key = "api_http_addr", .value = "\"127.0.0.1:" ++ rpc_default_port ++ "\"" },
        .{ .section = "server", .key = "run_tui", .value = "false" },
        .{ .section = "server.p2p_config", .key = "seeding_type", .value = "\"DNSSeed\"" },
        .{ .section = "server.p2p_config", .key = "peers_preferred", .value = "[\"144.202.75.237:3414\"]" },
    };

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
        /// The node's self-reported agent, e.g. "MW/Epic 4.0.3" — the version is
        /// the token after the last space (see `derive`).
        user_agent: []const u8 = "",
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
        /// The node version parsed out of `user_agent`, in a fixed buffer so
        /// `derive` stays allocation-free and the bytes survive the parsed JSON
        /// being freed. Empty when the agent had none.
        version_buf: [32]u8 = undefined,
        version_len: usize = 0,

        fn version(self: *const Derived) []const u8 {
            return self.version_buf[0..self.version_len];
        }
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

        // Version is the token after the last space in the user agent ("MW/Epic
        // 4.0.3" → "4.0.3"); copied into the fixed buffer so it doesn't dangle into
        // the soon-to-be-freed JSON.
        var d: Derived = .{
            .synced = synced,
            .blocks = tip,
            .headers = headers,
            .network = network,
            .connections = st.connections,
            .seconds_behind = seconds_behind,
        };
        const ua = st.user_agent;
        const start = if (std.mem.lastIndexOfScalar(u8, ua, ' ')) |i| i + 1 else 0;
        const ver = ua[start..];
        // Only adopt it if it looks like a version (leading digit), so a malformed
        // or version-less agent reads as "unknown" rather than printing garbage.
        if (ver.len > 0 and std.ascii.isDigit(ver[0])) {
            d.version_len = @min(ver.len, d.version_buf.len);
            @memcpy(d.version_buf[0..d.version_len], ver[0..d.version_len]);
        }
        return d;
    }

    /// Parse the significant part of a `.api_secret` file: the trimmed first line.
    /// The daemon reads only the first line, so a trailing newline (and anything
    /// after it) is ignored. Pure, so the parse is unit-testable on its own.
    fn parseSecret(bytes: []const u8) []const u8 {
        const eol = std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
        return std.mem.trim(u8, bytes[0..eol], " \t\r");
    }

    /// Read the daemon's Owner-API secret from `<data_dir>/.api_secret`, returning
    /// an owned copy of the first line. Errors if `data_dir` is empty or the file
    /// is missing/unreadable/empty. Bounded to a small buffer (the secret is short
    /// and only the first line matters).
    fn readSecretAt(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8) ![]u8 {
        if (data_dir.len == 0) return error.NoDataDir;

        var dir = try std.Io.Dir.cwd().openDir(io, data_dir, .{});
        defer dir.close(io);
        var f = try dir.openFile(io, secret_file, .{});
        defer f.close(io);

        var buf: [256]u8 = undefined;
        const n = try f.readPositionalAll(io, &buf, 0);
        const line = parseSecret(buf[0..n]);
        if (line.len == 0) return error.EmptySecret;
        return allocator.dupe(u8, line);
    }

    /// The Owner-API secret to authenticate with: whatever `<data_dir>/.api_secret`
    /// holds (the daemon's own random secret or BoxWallet's pre-seed), falling back
    /// to the built-in fixed secret when the file can't be read. `data_dir` rides
    /// in on `CoinAuth` (filled by `conf.readAuth`). Caller owns the returned slice.
    fn apiSecret(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8) ![]u8 {
        return readSecretAt(allocator, io, data_dir) catch try allocator.dupe(u8, api_secret);
    }

    /// POST a JSON-RPC `method` (no params) at the local Owner API and return the
    /// raw response body. Caller owns the returned slice. Builds the basic-auth
    /// header from the secret in `<data_dir>/.api_secret`; a 401 surfaces as
    /// `error.AuthFailed`.
    fn ownerCall(allocator: std.mem.Allocator, method: []const u8, data_dir: []const u8) ![]u8 {
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

        const secret = try apiSecret(allocator, threaded.io(), data_dir);
        defer allocator.free(secret);
        const auth_header = try basicAuthHeader(allocator, rpc_default_username, secret);
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

    /// Fetch + parse `get_status`, returning the normalized `Derived` view. Reads
    /// the Owner-API secret from `auth.data_dir` (filled by `conf.readAuth`).
    fn fetchStatus(allocator: std.mem.Allocator, data_dir: []const u8) !Derived {
        const raw = try ownerCall(allocator, "get_status", data_dir);
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
    /// a peer-height comparison. Only `auth.data_dir` is used — to locate the
    /// Owner-API secret; the host/port are fixed at 127.0.0.1:3413.
    pub fn blockchainState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.BlockchainState {
        const d = try fetchStatus(allocator, auth.data_dir);
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
    /// `staking_active` is always false. Only `auth.data_dir` is used — to locate
    /// the Owner-API secret.
    pub fn daemonInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.DaemonInfo {
        const d = try fetchStatus(allocator, auth.data_dir);
        return .{
            .blocks = d.blocks,
            .connections = d.connections,
            .staking_active = false,
            // `d.version()` points into `d`'s own buffer; dupe it onto `allocator`.
            .version = try allocator.dupe(u8, d.version()),
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

    /// Prepare Epic's config before launch. Idempotent; creates the data dir if
    /// absent. Three steps:
    ///   1. Seed the Owner-API secret (`.api_secret`) if missing — never clobber a
    ///      daemon-/user-owned secret.
    ///   2. Ensure `epic-server.toml` exists, generating a default via
    ///      `epic server config` on the very first launch (the daemon would
    ///      otherwise only create it during `server run`).
    ///   3. Patch the handful of keys BoxWallet manages (`managed_conf`) — safe
    ///      localhost API, headless launch, healthy seeding.
    /// Steps 2–3 are best-effort: if the binary can't generate a config (or the
    /// patch fails), `server run` still writes its own default, so launch isn't
    /// blocked. `io` is the caller's blocking io.
    pub fn prepareConf(
        allocator: std.mem.Allocator,
        io: std.Io,
        install_root: []const u8,
        home: []const u8,
    ) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);

        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
        defer dir.close(io);

        // 1. Seed the secret only when absent (the daemon/user owns its own).
        if (dir.access(io, secret_file, .{})) |_| {} else |_| {
            // The daemon reads only the first line; a trailing newline is harmless.
            try dir.writeFile(io, .{ .sub_path = secret_file, .data = api_secret ++ "\n" });
        }

        // 2–3. Best-effort: never let a config hiccup block the daemon launch.
        ensureAndPatchConf(allocator, io, install_root, data_dir, dir) catch {};
    }

    /// Generate `epic-server.toml` if it's not there yet, then patch the managed
    /// keys into it. Split out from `prepareConf` so the orchestration is clear and
    /// the whole thing can be swallowed as best-effort.
    fn ensureAndPatchConf(
        allocator: std.mem.Allocator,
        io: std.Io,
        install_root: []const u8,
        data_dir: []const u8,
        dir: std.Io.Dir,
    ) !void {
        if (dir.access(io, conf_file, .{})) |_| {} else |_| {
            try generateConf(allocator, io, install_root, data_dir);
        }
        try patchConf(allocator, io, dir);
    }

    /// Run `epic server config` to drop a full default `epic-server.toml` into
    /// `data_dir`. The subcommand writes the file into its working directory, so
    /// the child's cwd is set to `data_dir`. Waits for it to finish; a non-zero
    /// exit isn't fatal here — the caller's patch step (or `server run`) handles a
    /// missing file.
    fn generateConf(
        allocator: std.mem.Allocator,
        io: std.Io,
        install_root: []const u8,
        data_dir: []const u8,
    ) !void {
        const bin = try std.fs.path.join(allocator, &.{ install_root, daemon_file });
        defer allocator.free(bin);

        const argv = [_][]const u8{ bin, "server", "config" };
        var child = try std.process.spawn(io, .{
            .argv = &argv,
            .cwd = .{ .path = data_dir },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        _ = try child.wait(io);
    }

    /// Read `epic-server.toml`, apply the managed keys, and rewrite it only if the
    /// content actually changed (so a steady-state launch touches nothing). The
    /// file is tiny, so it's read whole through one bounded buffer — within the
    /// memory budget, and the same pattern `conf.populate` uses.
    fn patchConf(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
        var file = try dir.openFile(io, conf_file, .{});
        const stat = try file.stat(io);
        const size: usize = @intCast(@min(stat.size, 256 * 1024));
        const input = try allocator.alloc(u8, size);
        defer allocator.free(input);
        const n = try file.readPositionalAll(io, input, 0);
        file.close(io);

        const patched = try patchTomlAlloc(allocator, input[0..n], &managed_conf);
        defer allocator.free(patched);

        if (std.mem.eql(u8, patched, input[0..n])) return; // already in the desired state
        try dir.writeFile(io, .{ .sub_path = conf_file, .data = patched });
    }

    /// Apply `keys` to a TOML document, returning the patched text (caller owns it).
    /// Pure — no IO — so the section-aware logic is unit-testable.
    ///
    /// For each managed key, within its `[section]`: replace the first line setting
    /// that key (whether live or commented-out), drop any later duplicate of it,
    /// and if the section never set it, insert it at the section's end. Every other
    /// line — comments, blank lines, unmanaged keys, other sections — is preserved
    /// verbatim. A key is only matched while the parser is inside that key's
    /// section, so identically-named keys in other sections are left alone.
    fn patchTomlAlloc(
        allocator: std.mem.Allocator,
        input: []const u8,
        keys: []const ManagedKey,
    ) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();

        // Per-key "already emitted in its section" flags, bounded to the managed
        // set. A key can only be matched/written while inside its own section.
        var written = [_]bool{false} ** managed_conf.len;
        var section: []const u8 = ""; // current `[section]` name, without brackets

        var lines = std.mem.splitScalar(u8, input, '\n');
        var first = true;
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // A new section header: before crossing into it, flush any managed keys
            // for the section we're leaving that weren't present (insert them).
            if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                try flushPending(&out.writer, &first, keys, &written, section);
                section = trimmed[1 .. trimmed.len - 1];
                try emitLine(&out.writer, &first, line);
                continue;
            }

            // Does this line set one of the managed keys for the current section?
            if (lineKey(trimmed)) |k| {
                if (matchKey(keys, section, k)) |idx| {
                    if (!written[idx]) {
                        try emitKeyLine(&out.writer, &first, keys[idx]);
                        written[idx] = true;
                    }
                    continue; // replaced (or dropped as a duplicate)
                }
            }

            try emitLine(&out.writer, &first, line);
        }
        // Flush any keys still pending in the final section.
        try flushPending(&out.writer, &first, keys, &written, section);

        return out.toOwnedSlice();
    }

    /// Insert every managed key for `section` that hasn't been written yet.
    fn flushPending(
        w: *std.Io.Writer,
        first: *bool,
        keys: []const ManagedKey,
        written: []bool,
        section: []const u8,
    ) !void {
        for (keys, 0..) |mk, i| {
            if (!written[i] and std.mem.eql(u8, mk.section, section)) {
                try emitKeyLine(w, first, mk);
                written[i] = true;
            }
        }
    }

    /// The managed-key index whose section+key matches, or null. The key name is
    /// compared case-sensitively (TOML keys are).
    fn matchKey(keys: []const ManagedKey, section: []const u8, key: []const u8) ?usize {
        for (keys, 0..) |mk, i| {
            if (std.mem.eql(u8, mk.section, section) and std.mem.eql(u8, mk.key, key)) return i;
        }
        return null;
    }

    /// The key name a line assigns, or null if it isn't a `key = value` line. A
    /// single leading `#` (a commented-out setting) is tolerated so we can revive
    /// and set a key the daemon left commented; prose comments have no `=` and read
    /// as null.
    fn lineKey(trimmed: []const u8) ?[]const u8 {
        var s = trimmed;
        if (s.len > 0 and s[0] == '#') s = std.mem.trimStart(u8, s[1..], " \t");
        const eq = std.mem.indexOfScalar(u8, s, '=') orelse return null;
        return std.mem.trim(u8, s[0..eq], " \t");
    }

    /// Emit a line verbatim, joining segments with `\n` *between* them (a separator
    /// before every line but the first). Splitting on `\n` and rejoining this way
    /// reproduces the input faithfully — including whether it ended with a newline.
    fn emitLine(w: *std.Io.Writer, first: *bool, line: []const u8) !void {
        if (!first.*) try w.writeByte('\n');
        try w.writeAll(line);
        first.* = false;
    }

    /// Emit a managed key's canonical `key = value`, using the same separator-before
    /// join as `emitLine` so inserted/replaced lines splice in cleanly.
    fn emitKeyLine(w: *std.Io.Writer, first: *bool, mk: ManagedKey) !void {
        if (!first.*) try w.writeByte('\n');
        try w.print("{s} = {s}", .{ mk.key, mk.value });
        first.* = false;
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
        install_root: []const u8,
        home: []const u8,
    ) anyerror!void {
        return prepareConf(allocator, io, install_root, home);
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
    try std.testing.expectEqualStrings("MW/Epic 4.0.3", st.user_agent);

    const d = Epic.derive(st);
    try std.testing.expect(!d.synced);
    try std.testing.expectEqual(@as(i64, 300000), d.blocks);
    try std.testing.expectEqual(@as(i64, 371553), d.network);
    // The version is the token after the last space of the user agent.
    try std.testing.expectEqualStrings("4.0.3", d.version());
}

test "derive reads an empty version when the user agent has no version token" {
    // A version-less / malformed agent reads as unknown (not "epic"/garbage).
    const st: Epic.Status = .{ .connections = 1, .sync_status = "no_sync", .tip = .{ .height = 5 }, .user_agent = "epic" };
    try std.testing.expectEqualStrings("", Epic.derive(st).version());
    const st2: Epic.Status = .{ .user_agent = "" };
    try std.testing.expectEqualStrings("", Epic.derive(st2).version());
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
    // No real epic binary under this root, so the generate/patch step is a
    // best-effort no-op here (swallowed) — this test exercises only the secret.
    const install_root = "test-epic-conf-root";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // First pass writes the fixed secret.
    try Epic.prepareConf(allocator, io, install_root, home);

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
    try Epic.prepareConf(allocator, io, install_root, home);
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

test "parseSecret takes the trimmed first line of the secret file" {
    // A daemon-written secret with a trailing newline — the common case the old
    // hardcoded-secret path got wrong.
    try std.testing.expectEqualStrings("nsJCAOlpo7yqPMWvwiPh", Epic.parseSecret("nsJCAOlpo7yqPMWvwiPh\n"));
    // CRLF + a stray second line: only the first line counts, surrounding space trims.
    try std.testing.expectEqualStrings("abc123", Epic.parseSecret("  abc123 \r\nignored second line\n"));
    // No trailing newline at all is fine.
    try std.testing.expectEqualStrings("solo", Epic.parseSecret("solo"));
    // An empty/whitespace first line yields empty, so the caller falls back.
    try std.testing.expectEqualStrings("", Epic.parseSecret("\nsomething"));
    try std.testing.expectEqualStrings("", Epic.parseSecret("   \n"));
}

test "readSecretAt reads a daemon-generated secret from disk, errors when absent" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const data_dir = "test-epic-secret-dir";
    std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};

    // No data dir / file yet → an error (the caller falls back to the fixed one).
    try std.testing.expectError(error.FileNotFound, Epic.readSecretAt(allocator, io, data_dir));
    // An empty data dir short-circuits before touching the filesystem.
    try std.testing.expectError(error.NoDataDir, Epic.readSecretAt(allocator, io, ""));

    // Seed a daemon-style random secret (with a trailing newline) and read it back
    // verbatim — this is the case the old hardcoded-secret path 401'd on.
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = Epic.secret_file, .data = "nsJCAOlpo7yqPMWvwiPh\n" });

    const got = try Epic.readSecretAt(allocator, io, data_dir);
    defer allocator.free(got);
    try std.testing.expectEqualStrings("nsJCAOlpo7yqPMWvwiPh", got);

    // An empty secret file is treated as unusable (the daemon would reject it too).
    try dir.writeFile(io, .{ .sub_path = Epic.secret_file, .data = "\n" });
    try std.testing.expectError(error.EmptySecret, Epic.readSecretAt(allocator, io, data_dir));
}

test "patchTomlAlloc replaces in-section keys, inserts missing ones, preserves the rest" {
    const allocator = std.testing.allocator;
    // A miniature epic-server.toml: [server] already sets api_http_addr (to a bad
    // 0.0.0.0) and run_tui; [server.p2p_config] sets seeding_type but has no
    // peers_preferred. A same-named key in an unrelated section must be untouched.
    const input =
        \\# header comment
        \\[server]
        \\api_http_addr = "0.0.0.0:3413"
        \\run_tui = true
        \\chain_type = "Mainnet"
        \\
        \\[server.p2p_config]
        \\host = "0.0.0.0"
        \\seeding_type = "List"
        \\capabilities = "PEER_LIST"
        \\
        \\[other]
        \\seeding_type = "leave me"
        \\
    ;
    const out = try Epic.patchTomlAlloc(allocator, input, &Epic.managed_conf);
    defer allocator.free(out);

    // api_http_addr healed to localhost; run_tui forced off; seeding_type → DNSSeed.
    try std.testing.expect(std.mem.indexOf(u8, out, "api_http_addr = \"127.0.0.1:3413\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0.0.0.0:3413") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "run_tui = false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "run_tui = true") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "seeding_type = \"DNSSeed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "seeding_type = \"List\"") == null);
    // peers_preferred inserted into the p2p section.
    try std.testing.expect(std.mem.indexOf(u8, out, "peers_preferred = [\"144.202.75.237:3414\"]") != null);
    // Unmanaged content preserved, including the same-named key in [other].
    try std.testing.expect(std.mem.indexOf(u8, out, "# header comment") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "chain_type = \"Mainnet\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "capabilities = \"PEER_LIST\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "seeding_type = \"leave me\"") != null);

    // Idempotent: patching the already-patched output changes nothing.
    const out2 = try Epic.patchTomlAlloc(allocator, out, &Epic.managed_conf);
    defer allocator.free(out2);
    try std.testing.expectEqualStrings(out, out2);
}

test "patchTomlAlloc revives a commented-out key and drops duplicates" {
    const allocator = std.testing.allocator;
    // run_tui is present only as a commented example; seeding_type appears twice.
    const input =
        \\[server]
        \\#run_tui = true
        \\[server.p2p_config]
        \\seeding_type = "List"
        \\seeding_type = "List"
        \\
    ;
    const out = try Epic.patchTomlAlloc(allocator, input, &Epic.managed_conf);
    defer allocator.free(out);

    // The commented run_tui became a real, enforced line (exactly once).
    try std.testing.expect(std.mem.indexOf(u8, out, "run_tui = false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "#run_tui") == null);
    // The duplicate seeding_type collapsed to a single canonical line.
    try std.testing.expect(std.mem.count(u8, out, "seeding_type =") == 1);
    try std.testing.expect(std.mem.indexOf(u8, out, "seeding_type = \"DNSSeed\"") != null);
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
