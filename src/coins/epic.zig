const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const install_mod = @import("../install.zig");
const rpc = @import("../rpc.zig");
const conf = @import("../conf.zig");
const bip39 = @import("../bip39.zig");
const warmup = @import("../warmup.zig");
const Coin = @import("../coin.zig").Coin;

/// Epic Cash (EPIC) backend — the node daemon plus a managed `epic-wallet`
/// process, so this coin reports chain-sync status the way the rest of BoxWallet
/// does *and* drives the Monero-style external-wallet flow (create returns a seed,
/// restore from seed, unlock with a password, read balance) over the wallet's
/// encrypted Owner API v3 (see the `SecureChannel`/`external_wallet` section below).
/// Built against the Epic 4.x line — the standalone `epic` node 4.0.3 and the
/// `epic-wallet` CLI 4.0.1; the old Go reference targeted 3.x with a different
/// distribution and a (stale, bitcoin-style) RPC, so it isn't a line-by-line port.
///
/// Epic is a MimbleWimble chain (a Grin fork), so it is unlike the bitcoin-core
/// forks the rest of BoxWallet ports — closer in shape to Ergo:
///
///   * **Distribution** — the `epic` node ships as a `.tar.gz` (versioned wrapper
///     dir, no `bin/`) and the `epic-wallet` CLI as a flat `.zip` (binary at the
///     root), both **linux/amd64 only**. Other targets resolve no download
///     (`UnsupportedPlatform`). The node is extracted + promoted; the wallet is
///     extracted into the install root and marked executable (`markExecutable`).
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
    /// Whether the coin is exposed in the nav. False keeps it out of the left
    /// bar entirely (registered but hidden) until it's ready for users.
    pub const live = true;
    pub const coin_name = "Epic Cash";
    pub const coin_name_abbrev = "EPIC";
    /// One-line description shown under the coin name on the detail pane.
    pub const coin_description = "Private, scalable Mimblewimble cryptocurrency.";
    /// Epic brand colour (`#RRGGBB`), for tinting the coin in the frontend.
    pub const coin_color = "#deac55";
    /// This coin's id on the price host, for the USD quote beside its
    /// balance (see `src/price.zig`).
    /// Note the id is `epic-cash`, not the coin name — the host's ids
    /// don't track coin names, so this is verified data, not derived.
    pub const price_id = "epic-cash";
    /// Donation address for BoxWallet development, in Epic's own
    /// currency.
    /// TODO(richard): replace with the real EPIC tip address.
    pub const tip_address = "TODO-EPIC-TIP-ADDRESS-NOT-SET";
    /// Epic is proof-of-work (MimbleWimble) — no wallet staking.
    pub const proof_of_stake = false;

    // The node's bundled version. The live daemon version still comes from
    // `get_status`'s `user_agent`; this is the version the install marker/UI show.
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
    //   * `log_to_file` — on. Epic defaults to stdout only, and BoxWallet launches
    //     the node detached with stdout discarded, so its entire start-up
    //     narration would go nowhere. This is what gives `warmupStageFromLog` (and
    //     the startup-failure reason) something to read.
    //   * `file_log_level` — Info, down from Epic's default of Debug: the file is
    //     only turned on for the handful of lines above, and Debug would spend
    //     rotations' worth of disk on a machine BoxWallet is meant to be light on.
    //     `log_file_path` is deliberately *not* managed — the generator writes it
    //     absolute into the data dir, and a user who moved it chose that.
    const ManagedKey = struct { section: []const u8, key: []const u8, value: []const u8 };
    const managed_conf = [_]ManagedKey{
        .{ .section = "server", .key = "api_http_addr", .value = "\"127.0.0.1:" ++ rpc_default_port ++ "\"" },
        .{ .section = "server", .key = "run_tui", .value = "false" },
        .{ .section = "server.p2p_config", .key = "seeding_type", .value = "\"DNSSeed\"" },
        .{ .section = "server.p2p_config", .key = "peers_preferred", .value = "[\"144.202.75.237:3414\"]" },
        .{ .section = "logging", .key = "log_to_file", .value = "true" },
        .{ .section = "logging", .key = "file_log_level", .value = "\"Info\"" },
    };

    /// The node's log under the data dir, once `log_to_file` above is on. Read for
    /// a startup-failure reason and for the stage the node is at while it loads.
    pub fn daemonLogFile() []const u8 {
        return "epic-server.log";
    }

    /// The stage the Epic node is at while it starts, read from `epic-server.log`.
    ///
    /// Epic's Owner API refuses the connection until the node is up, so — as with
    /// Ergo — nothing can be asked during the load and the log is the only source.
    /// The genesis warm-up and the database resize are the parts that take real
    /// time on a cold start.
    pub fn warmupStageFromLog(tail: []const u8) []const u8 {
        return warmup.lastStage(tail, &epic_markers);
    }

    /// Epic's start-up lines, matched case-insensitively, freshest wins. Taken
    /// from a real `epic server run` on mainnet.
    ///
    /// "Epic node server started." is the end of the start-up and has to be tested
    /// before the "warm up epic node server" needle it shares wording with.
    const epic_markers = [_]warmup.Marker{
        // Up, or going down.
        .{ .needle = "epic node server started", .text = "" },
        .{ .needle = "shutting down", .text = "" },
        .{ .needle = "shutdown complete", .text = "" },
        .{ .needle = "api server has been stopped", .text = "" },
        // Coming up.
        .{ .needle = "this is epic version", .text = "Starting node…" },
        .{ .needle = "starting epic w/o ui", .text = "Starting node…" },
        .{ .needle = "warm up epic node server", .text = "Loading blockchain…" },
        .{ .needle = "resized database", .text = "Loading blockchain…" },
        .{ .needle = "init: saved genesis", .text = "Loading blockchain…" },
        .{ .needle = "starting http node apis server", .text = "Starting API server…" },
    };

    // Epic's MimbleWimble block target is 60s; used to turn the height gap into a
    // rough "behind by" estimate while syncing (the Owner API reports no tip
    // timestamp). An approximation, like Nerva's block-gap estimate.
    const block_target_secs: i64 = 60;

    // --- Node distribution ----------------------------------------------
    //
    // The node is the standalone `EpicCash/epic` 4.0.3 release: a `.tar.gz` that
    // nests `epic` under a versioned wrapper dir (no `bin/`), so it's extracted
    // whole and `promoteAndTidy` lifts the binary to the install root. linux/amd64
    // only (other targets resolve no download → `UnsupportedPlatform`).
    const release_base = "https://github.com/EpicCash/epic/releases/download/v" ++ core_version;
    const extracted_dir = "epic-" ++ core_version ++ "-linux-amd64";
    const bin_subdir = "";
    const promote_files = [_][]const u8{daemon_file};
    // Temp file the node download streams to, unique to Epic so a concurrent install
    // of another coin into the same `~/.boxwallet` root never collides on it.
    pub const scratch_file = ".boxwallet-epic.part";

    /// The node download for the build target, or null where upstream ships no
    /// binary (linux/amd64 only).
    const download: ?install_mod.Download = switch (builtin.os.tag) {
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => .{ .url = release_base ++ "/" ++ extracted_dir ++ ".tar.gz", .format = .tar_gz },
            else => null,
        },
        else => null,
    };

    // --- Wallet (separate `epic-wallet` binary + Owner API) --------------
    //
    // Epic's wallet is its own process, not part of the node — the `epic-wallet`
    // CLI from the standalone `EpicCash/epic-wallet` **v4.0.1** release (matching the
    // node's 4.x line). BoxWallet installs it next to the node, runs
    // `epic-wallet owner_api` bound to localhost:3420, and drives
    // create/restore/open/balance over the **encrypted** Owner API v3 (see
    // `SecureChannel`). All funds-sensitive ops take a user-supplied password and a
    // wallet is never created/opened silently.

    pub const wallet_file = "epic-wallet" ++ exe_suffix;
    // The Owner API port BoxWallet binds `epic-wallet owner_api` to (localhost only).
    pub const wallet_rpc_port = "3420";
    // Owner-API basic-auth username (fixed in epic-wallet; the secret is per-session).
    const wallet_api_username = "epic";
    // Per-session Owner-API basic-auth secret file, written under the wallet top dir
    // before each spawn (overwritten with fresh OS-CSPRNG bytes) so the Owner API is
    // locked to this BoxWallet run — the same per-session model as Nerva's
    // `--rpc-login`, delivered via the file epic-wallet's config points `api_secret`
    // at. Layered under the mandatory ECDH/AES-GCM channel + the open_wallet token.
    const owner_secret_file = ".owner_api_secret";
    // Temp file the recovery phrase is written to so `init -r` can read it as stdin
    // (a regular file, not a pipe — see `runInitRecover`). Holds the seed only
    // momentarily: overwritten + deleted on every path.
    const recover_phrase_file = ".boxwallet-recover.tmp";
    // The node's own foreign-API secret (it generates this on first run). The wallet
    // authenticates to the node with it — `node_api_secret_path` in the wallet config.
    const node_foreign_secret_file = ".foreign_api_secret";
    // The wallet's config, generated next to the node's `epic-server.toml` in the
    // shared `~/.epic/main` top dir.
    const wallet_conf_file = "epic-wallet.toml";
    // Epic is divisible to 1e8 (`EPIC_BASE`, bitcoin-style 8dp); the Owner API
    // reports balances as integer base units, so divide by this for whole EPIC.
    const epic_base: f64 = 100_000_000;

    // epic-wallet's own release (versioned independently of the node). The v4.0.1
    // Linux asset is a `.tar.gz` nesting `epic-wallet` under a single versioned
    // wrapper dir (`./epic-wallet-v4.0.1-linux-amd64/`), so it's extracted with
    // `strip_components = 1` — the binary lands straight in the install root with
    // no wrapper left behind to promote away. (v4.0.0 was a flat `.zip`; the shape
    // changed with the release, hence the strip.) It's marked executable after
    // extraction regardless, so a bundle without the exec bit still runs.
    const wallet_version = "4.0.1";
    const wallet_tag = "v" ++ wallet_version;
    const wallet_release_base = "https://github.com/EpicCash/epic-wallet/releases/download/" ++ wallet_tag;
    pub const wallet_scratch_file = ".boxwallet-epic-wallet.part";
    // Levels of the wallet archive's wrapper dir to drop while untarring.
    const wallet_strip: u32 = 1;

    /// The wallet download for the build target, or null off linux/amd64.
    const wallet_download: ?install_mod.Download = switch (builtin.os.tag) {
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => .{
                .url = wallet_release_base ++ "/epic-wallet-" ++ wallet_tag ++ "-linux-amd64-ubuntu24.04.tar.gz",
                .format = .tar_gz,
            },
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

    /// Mark `install_root/<name>` executable. The wallet bundle doesn't carry the
    /// Unix exec bit reliably, so set it explicitly after extraction.
    fn markExecutable(allocator: std.mem.Allocator, install_root: []const u8, name: []const u8) !void {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var dir = try std.Io.Dir.cwd().openDir(io, install_root, .{});
        defer dir.close(io);
        var f = try dir.openFile(io, name, .{});
        defer f.close(io);
        try f.setPermissions(io, .executable_file);
    }

    /// Install the Epic node + wallet. The node (`epic` 4.0.3) is a `.tar.gz` nested
    /// in a versioned wrapper dir, extracted then promoted to the install root. The
    /// wallet (`epic-wallet` 4.0.1) is a `.tar.gz` whose own wrapper dir is stripped
    /// during extraction, so the binary lands in the install root directly and is
    /// then marked executable. Both stream to disk — flat memory.
    pub fn install(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        const dl = download orelse return error.UnsupportedPlatform;
        try install_mod.downloadAndExtract(allocator, dl.url, dl.format, install_root, scratch_file, 0, progress);
        try install_mod.promoteAndTidy(allocator, install_root, extracted_dir, bin_subdir, &promote_files);

        const wdl = wallet_download orelse return error.UnsupportedPlatform;
        try install_mod.downloadAndExtract(allocator, wdl.url, wdl.format, install_root, wallet_scratch_file, wallet_strip, progress);
        try markExecutable(allocator, install_root, wallet_file);
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

        // Per-key "already emitted in its section" flags, one per key in `keys`
        // (sized at runtime so this serves both the node's `managed_conf` and the
        // wallet's runtime key set). A key can only be matched/written while inside
        // its own section.
        const written = try allocator.alloc(bool, keys.len);
        defer allocator.free(written);
        @memset(written, false);
        var section: []const u8 = ""; // current `[section]` name, without brackets

        var lines = std.mem.splitScalar(u8, input, '\n');
        var first = true;
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // A new section header: before crossing into it, flush any managed keys
            // for the section we're leaving that weren't present (insert them).
            if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                try flushPending(&out.writer, &first, keys, written, section);
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
        try flushPending(&out.writer, &first, keys, written, section);

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

    // --- Encrypted Owner API v3 transport --------------------------------
    //
    // Every Owner-API method except `init_secure_api` is mandatory-encrypted. Each
    // call: (1) `init_secure_api` — send our ephemeral secp256k1 pubkey, get the
    // server's; the shared point's 32-byte x-coordinate is the AES-256 key (grin's
    // scheme). (2) wrap the real JSON-RPC body in an `encrypted_request_v3` envelope
    // (12-byte nonce + base64 of AES-256-GCM(ciphertext‖tag), empty AAD). (3) decrypt
    // the `encrypted_response_v3` reply the same way. Layered over HTTP basic auth
    // (`epic:<.owner_api_secret>`) on 127.0.0.1. Pure std.crypto — no C deps.

    const Secp256k1 = std.crypto.ecc.Secp256k1;
    const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

    /// Generate an ephemeral ECDH keypair: returns our compressed public key as
    /// lowercase hex (66 chars) to send in `init_secure_api`, and writes the secret
    /// scalar to `secret_out` (wipe it after deriving the key). Randomness is the
    /// OS CSPRNG via `io.random`.
    fn clientPubHex(io: std.Io, secret_out: *[32]u8) [66]u8 {
        const secret = Secp256k1.scalar.random(io, .big);
        secret_out.* = secret;
        // base point · secret = our public key; serialize compressed (0x02/0x03 ‖ x).
        const pub_point = Secp256k1.basePoint.mul(secret, .big) catch unreachable;
        return std.fmt.bytesToHex(pub_point.toCompressedSec1(), .lower);
    }

    /// Derive the AES-256 key from our `secret` and the server's compressed pubkey
    /// hex: the x-coordinate of (serverPub · ourSecret), matching the server which
    /// uses the x-coordinate of (ourPub · serverSecret) — the same point.
    fn deriveKey(secret: [32]u8, server_pub_hex: []const u8) ![32]u8 {
        var comp: [33]u8 = undefined;
        const decoded = std.fmt.hexToBytes(&comp, server_pub_hex) catch return error.BadServerKey;
        if (decoded.len != comp.len) return error.BadServerKey;
        const p = Secp256k1.fromSec1(&comp) catch return error.BadServerKey;
        const shared = p.mul(secret, .big) catch return error.BadServerKey;
        return shared.affineCoordinates().x.toBytes(.big);
    }

    /// Seal an inner JSON-RPC `body` into an `encrypted_request_v3` envelope under
    /// `key`. `body` may carry a secret (a password) — the caller wipes it. Caller
    /// owns the returned slice.
    fn sealRequest(allocator: std.mem.Allocator, io: std.Io, key: [32]u8, body: []const u8) ![]u8 {
        var nonce: [12]u8 = undefined;
        io.random(&nonce);

        // ciphertext ‖ tag (grin appends the GCM tag), then base64.
        const combined = try allocator.alloc(u8, body.len + Aes256Gcm.tag_length);
        defer {
            @memset(combined, 0);
            allocator.free(combined);
        }
        var tag: [Aes256Gcm.tag_length]u8 = undefined;
        Aes256Gcm.encrypt(combined[0..body.len], &tag, body, "", nonce, key);
        @memcpy(combined[body.len..], &tag);

        const enc = std.base64.standard.Encoder;
        const b64 = try allocator.alloc(u8, enc.calcSize(combined.len));
        defer allocator.free(b64);
        _ = enc.encode(b64, combined);

        const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
        return std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"encrypted_request_v3\",\"params\":{{\"nonce\":\"{s}\",\"body_enc\":\"{s}\"}}}}",
            .{ nonce_hex, b64 },
        );
    }

    const EncBody = struct { nonce: []const u8 = "", body_enc: []const u8 = "" };

    /// Open an `encrypted_response_v3` reply (`{"result":{"Ok":{nonce,body_enc}}}`)
    /// under `key`, returning the decrypted inner JSON-RPC response. The plaintext
    /// may carry a secret (a seed/balance) — the caller wipes + frees it.
    fn openResponse(allocator: std.mem.Allocator, key: [32]u8, raw: []const u8) ![]u8 {
        const Env = struct { result: ?struct { Ok: ?EncBody = null } = null };
        var parsed = try std.json.parseFromSlice(Env, allocator, raw, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();
        const body = (parsed.value.result orelse return error.SecureChannelFailed).Ok orelse
            return error.SecureChannelFailed;

        var nonce: [12]u8 = undefined;
        const nb = std.fmt.hexToBytes(&nonce, body.nonce) catch return error.SecureChannelFailed;
        if (nb.len != nonce.len) return error.SecureChannelFailed;

        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(body.body_enc) catch return error.SecureChannelFailed;
        if (n < Aes256Gcm.tag_length) return error.SecureChannelFailed;
        const combined = try allocator.alloc(u8, n);
        defer {
            @memset(combined, 0);
            allocator.free(combined);
        }
        dec.decode(combined, body.body_enc) catch return error.SecureChannelFailed;

        const ct_len = combined.len - Aes256Gcm.tag_length;
        var tag: [Aes256Gcm.tag_length]u8 = undefined;
        @memcpy(&tag, combined[ct_len..]);
        const out = try allocator.alloc(u8, ct_len);
        errdefer {
            @memset(out, 0);
            allocator.free(out);
        }
        Aes256Gcm.decrypt(out, combined[0..ct_len], tag, "", nonce, key) catch return error.SecureChannelAuth;
        return out;
    }

    /// POST a raw JSON `body` at the wallet's Owner API and return the response body
    /// (caller frees). Basic-auths with the per-session `.owner_api_secret` cached in
    /// `OwnerSecret` at launch; a 401 surfaces as `error.AuthFailed`.
    fn walletPost(allocator: std.mem.Allocator, io: std.Io, auth: models.CoinAuth, body: []const u8) ![]u8 {
        var client: std.http.Client = .{ .allocator = allocator, .io = io };
        defer client.deinit();

        const url = try std.fmt.allocPrint(allocator, "http://{s}:{s}/v3/owner", .{ auth.ip_address, auth.port });
        defer allocator.free(url);

        // The Owner-API basic-auth secret is the per-session one written to
        // `.owner_api_secret` when the wallet process was launched and cached in
        // `OwnerSecret` (a launch-with-password wallet doesn't carry creds on `auth`).
        // Absent it, the wallet service isn't up yet.
        var sec_buf: [64]u8 = undefined;
        defer @memset(&sec_buf, 0);
        const sec_len = OwnerSecret.get(&sec_buf) orelse return error.WalletServiceNotReady;
        const auth_header = try basicAuthHeader(allocator, wallet_api_username, sec_buf[0..sec_len]);
        defer allocator.free(auth_header);

        var resp: std.Io.Writer.Allocating = .init(allocator);
        defer resp.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .response_writer = &resp.writer,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "authorization", .value = auth_header },
            },
        });
        if (result.status == .unauthorized) return error.AuthFailed;
        return resp.toOwnedSlice();
    }

    /// Run one encrypted Owner-API call: handshake → seal `inner_method`+`params` →
    /// POST → decrypt. Returns the decrypted inner JSON-RPC *response* bytes (caller
    /// wipes + frees — they may carry a seed/balance). `params` is a complete JSON
    /// object literal; any secret inside it (a password) is wiped here after sealing.
    // The Owner API keeps a SINGLE shared ECDH key — whatever the most recent
    // `init_secure_api` established — so two secure calls whose handshakes interleave
    // clobber each other's key and one then fails to decrypt ("Decryption error" →
    // SecureChannelFailed). Serialize every secure call (handshake + encrypted request
    // as one atomic unit) so the wallet open on the setup worker and the balance poll
    // on the poll worker can't race. Nothing nested takes it, so no deadlock; held
    // across HTTP I/O, so waiters `io.sleep` between tries rather than hot-spinning.
    var channel_mutex: std.atomic.Mutex = .unlocked;

    // Diagnostic: the server's raw reply at the step a secure call failed, so the
    // error the UI shows names *why* (a decryption/clobber envelope, a rejected
    // pubkey, or an empty body = bad basic auth) instead of a bare
    // `SecureChannelFailed`. Written only while `channel_mutex` is held, read right
    // after the call returns its error.
    var channel_err: [220]u8 = undefined;
    var channel_err_len: usize = 0;

    fn noteChannelErr(stage: []const u8, raw: []const u8) void {
        var n: usize = 0;
        for (stage) |c| {
            if (n >= channel_err.len) break;
            channel_err[n] = c;
            n += 1;
        }
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        const body = if (trimmed.len == 0) "<empty body — bad basic auth?>" else trimmed;
        for (body) |c| {
            if (n >= channel_err.len) break;
            channel_err[n] = c;
            n += 1;
        }
        channel_err_len = n;
    }

    /// Serialized, lightly-retrying wrapper over `secureRpcOnce`. Holds `channel_mutex`
    /// so no other secure call can swap the server's shared key mid-handshake, and
    /// retries the transient channel errors a couple of times — a freshly-launched
    /// `owner_api` can accept the TCP connection a beat before its secure API is ready,
    /// and any stray clobber is recoverable by re-handshaking. A genuine wallet-level
    /// failure (wrong password) comes back decrypted as an `Err`, not these errors, so
    /// it isn't retried.
    fn secureRpc(
        allocator: std.mem.Allocator,
        io: std.Io,
        auth: models.CoinAuth,
        inner_method: []const u8,
        params: []const u8,
    ) ![]u8 {
        while (!channel_mutex.tryLock()) io.sleep(.fromMilliseconds(5), .awake) catch {};
        defer channel_mutex.unlock();
        channel_err_len = 0;

        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            return secureRpcOnce(allocator, io, auth, inner_method, params) catch |err| {
                if (attempt < 2 and (err == error.SecureChannelFailed or err == error.SecureChannelAuth)) {
                    io.sleep(.fromMilliseconds(200), .awake) catch {};
                    continue;
                }
                return err;
            };
        }
    }

    /// One handshake + encrypted request/response. Run under `channel_mutex` via
    /// `secureRpc`; never call directly.
    fn secureRpcOnce(
        allocator: std.mem.Allocator,
        io: std.Io,
        auth: models.CoinAuth,
        inner_method: []const u8,
        params: []const u8,
    ) ![]u8 {
        // 1. Handshake.
        var secret: [32]u8 = undefined;
        const client_hex = clientPubHex(io, &secret);
        defer @memset(&secret, 0);

        const init_body = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"init_secure_api\",\"params\":{{\"ecdh_pubkey\":\"{s}\"}}}}",
            .{client_hex},
        );
        defer allocator.free(init_body);
        const init_raw = try walletPost(allocator, io, auth, init_body);
        defer allocator.free(init_raw);

        const server_hex = parseOkString(allocator, init_raw) catch |err| {
            noteChannelErr("init_secure_api", init_raw);
            return err;
        };
        defer allocator.free(server_hex);
        var key = try deriveKey(secret, server_hex);
        defer @memset(&key, 0);

        // 2. Seal + POST the real call. The inner body carries the password (if any),
        // so wipe it once sealed.
        const inner = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}",
            .{ inner_method, params },
        );
        defer {
            @memset(inner, 0);
            allocator.free(inner);
        }
        const outer = try sealRequest(allocator, io, key, inner);
        defer allocator.free(outer);
        const resp_raw = try walletPost(allocator, io, auth, outer);
        defer allocator.free(resp_raw);

        // 3. Decrypt the reply.
        return openResponse(allocator, key, resp_raw) catch |err| {
            noteChannelErr("encrypted_request", resp_raw);
            return err;
        };
    }

    /// Parse `{"result":{"Ok":"<string>"}}` (the init handshake + token/seed replies),
    /// returning an owned copy of the string. Errors when `Ok` is absent.
    fn parseOkString(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
        const Env = struct { result: ?struct { Ok: ?[]const u8 = null } = null };
        var parsed = try std.json.parseFromSlice(Env, allocator, raw, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();
        const ok = (parsed.value.result orelse return error.SecureChannelFailed).Ok orelse
            return error.SecureChannelFailed;
        return allocator.dupe(u8, ok);
    }

    /// Best-effort: surface epic-wallet's own failure reason from a decrypted inner
    /// reply (`{"result":{"Err":…}}` or `{"error":…}`) into `detail`, so the UI shows
    /// *why* rather than a bare error name. Bounded copy.
    fn setErrDetail(detail: *Coin.WalletErrSink, inner: []const u8) void {
        const at = std.mem.indexOf(u8, inner, "\"Err\"") orelse
            std.mem.indexOf(u8, inner, "\"error\"") orelse 0;
        detail.set(inner[at..@min(at + 200, inner.len)]);
    }

    /// True if a decrypted inner reply is a success (`{"result":{"Ok":…}}`) rather
    /// than a failure (`{"result":{"Err":…}}` / `{"error":…}`). `create_wallet`
    /// returns `"Ok":null`, so a substring check (not a typed parse) is what tells
    /// success from failure here.
    fn innerSucceeded(inner: []const u8) bool {
        return std.mem.indexOf(u8, inner, "\"Ok\"") != null and
            std.mem.indexOf(u8, inner, "\"Err\"") == null;
    }

    // --- Wallet session token --------------------------------------------
    //
    // `open_wallet` returns a token that handles the now-open wallet; every later
    // read (`retrieve_summary_info`) needs it. The wallet stays open in the
    // owner_api process, so the token is cached here (set by open/create/restore,
    // cleared by lock/remove) and read by the balance poll — guarded by a mutex
    // because setup and the poll run on different threads. The token is a session
    // secret, so it's wiped on clear.
    const Session = struct {
        var mutex: std.atomic.Mutex = .unlocked;
        var token_buf: [128]u8 = undefined;
        var token_len: usize = 0;

        // The spinlock guards only fixed-size in-memory copies (no IO), so the held
        // region is a few instructions — a spin to acquire is fine.
        fn lock() void {
            while (!mutex.tryLock()) std.atomic.spinLoopHint();
        }

        fn set(tok: []const u8) void {
            lock();
            defer mutex.unlock();
            const n = @min(tok.len, token_buf.len);
            @memcpy(token_buf[0..n], tok[0..n]);
            token_len = n;
        }

        /// Copy the cached token into `out`, returning its length, or null when no
        /// wallet is open.
        fn get(out: []u8) ?usize {
            lock();
            defer mutex.unlock();
            if (token_len == 0 or token_len > out.len) return null;
            @memcpy(out[0..token_len], token_buf[0..token_len]);
            return token_len;
        }

        fn clear() void {
            lock();
            defer mutex.unlock();
            @memset(&token_buf, 0);
            token_len = 0;
        }
    };

    // --- Owner-API basic-auth secret -------------------------------------
    //
    // The wallet process is (re)launched per-open (the launch-with-password model),
    // and its Owner API authenticates `epic:<secret>` against the `.owner_api_secret`
    // file it read at startup. BoxWallet draws that secret fresh from the OS CSPRNG on
    // each launch — so another local process can't drive the wallet RPC, which exposes
    // the seed — writes it to the file, and caches it here for `walletPost` (the app
    // doesn't carry it on `auth` for this wallet shape). Set on launch, wiped on
    // remove. Guarded like `Session` because the launch and the balance poll run on
    // different threads.
    const OwnerSecret = struct {
        var mutex: std.atomic.Mutex = .unlocked;
        var buf: [64]u8 = undefined;
        var len: usize = 0;

        fn lock() void {
            while (!mutex.tryLock()) std.atomic.spinLoopHint();
        }

        fn set(secret: []const u8) void {
            lock();
            defer mutex.unlock();
            const n = @min(secret.len, buf.len);
            @memcpy(buf[0..n], secret[0..n]);
            len = n;
        }

        /// Copy the cached secret into `out`, returning its length, or null when no
        /// wallet process has been launched this session.
        fn get(out: []u8) ?usize {
            lock();
            defer mutex.unlock();
            if (len == 0 or len > out.len) return null;
            @memcpy(out[0..len], buf[0..len]);
            return len;
        }

        fn clear() void {
            lock();
            defer mutex.unlock();
            @memset(&buf, 0);
            len = 0;
        }
    };

    // --- Wallet files / paths --------------------------------------------

    /// The wallet's data dir (`<top>/wallet_data`), where `wallet.seed` and the
    /// output db live. `<top>` is the shared `~/.epic/main`. Caller owns the slice.
    fn walletDataDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        const top = try dataDir(allocator, home);
        defer allocator.free(top);
        return std.fs.path.join(allocator, &.{ top, "wallet_data" });
    }

    /// The managed wallet's on-disk location for the Settings tab: `wallet.seed`
    /// under the wallet data dir (no `.keys` companion). Caller owns the strings.
    pub fn walletPath(allocator: std.mem.Allocator, home: []const u8) !?Coin.WalletFile {
        const dir = try walletDataDir(allocator, home);
        defer allocator.free(dir);
        const path = try std.fs.path.join(allocator, &.{ dir, "wallet.seed" });
        return .{ .path = path };
    }

    /// The Owner-API port the wallet process is bound to.
    fn walletRpcPort() []const u8 {
        return wallet_rpc_port;
    }

    /// True if a managed wallet already exists — its `wallet.seed` is the marker.
    fn walletExists(allocator: std.mem.Allocator, home: []const u8) bool {
        const dir = walletDataDir(allocator, home) catch return false;
        defer allocator.free(dir);
        return install_mod.fileExists(allocator, dir, "wallet.seed");
    }

    // --- Wallet runtime prep (config + per-session secret) ----------------

    /// A full default `epic-wallet.toml` with BoxWallet's values baked in: localhost
    /// Owner API on 3420, the node's local API as the sync target, and the secret
    /// paths wired to the files BoxWallet manages. Emits all four sections the
    /// wallet config deserializes — `[wallet]`, `[epicbox]`, `[tor]`, `[logging]` —
    /// so the binary loads it cleanly. Written only when no config is there yet; an
    /// existing (possibly user-edited) config is healed by `patchWalletConf`
    /// instead. Caller owns the slice. (`node_api_secret_path` points at the node's
    /// own `.foreign_api_secret`, the secret the wallet authenticates to the node
    /// with — distinct from the wallet's own `.owner_api_secret`.)
    fn defaultWalletToml(allocator: std.mem.Allocator, top_dir: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator,
            \\[wallet]
            \\chain_type = "Mainnet"
            \\api_listen_interface = "127.0.0.1"
            \\api_listen_port = 3415
            \\owner_api_listen_port = {s}
            \\owner_api_include_foreign = false
            \\api_secret_path = "{s}/{s}"
            \\node_api_secret_path = "{s}/{s}"
            \\check_node_api_http_addr = "http://127.0.0.1:{s}"
            \\data_file_dir = "{s}/wallet_data"
            \\no_commit_cache = false
            \\dark_background_color_scheme = true
            \\
            \\[epicbox]
            \\epicbox_domain = "epicbox.epiccash.com"
            \\epicbox_port = 443
            \\epicbox_protocol_unsecure = false
            \\epicbox_address_index = 0
            \\
            \\[tor]
            \\use_tor_listener = false
            \\socks_proxy_addr = "127.0.0.1:9050"
            \\send_config_dir = "."
            \\
            \\[logging]
            \\log_to_stdout = false
            \\stdout_log_level = "Info"
            \\log_to_file = true
            \\file_log_level = "Info"
            \\log_file_path = "{s}/epic-wallet.log"
            \\log_file_append = true
            \\log_max_size = 16777216
            \\
        , .{ wallet_rpc_port, top_dir, owner_secret_file, top_dir, node_foreign_secret_file, rpc_default_port, top_dir, top_dir });
    }

    /// Heal the keys BoxWallet manages in `epic-wallet.toml` (localhost Owner API on
    /// the expected port, the local node as sync target, the managed secret path),
    /// rewriting only if something changed. Same section-aware patch the node conf
    /// uses; the values are runtime (they embed absolute paths).
    fn patchWalletConf(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, top_dir: []const u8) !void {
        const secret_path = try std.fmt.allocPrint(allocator, "\"{s}/{s}\"", .{ top_dir, owner_secret_file });
        defer allocator.free(secret_path);
        const node_addr = "\"http://127.0.0.1:" ++ rpc_default_port ++ "\"";
        const data_dir_val = try std.fmt.allocPrint(allocator, "\"{s}/wallet_data\"", .{top_dir});
        defer allocator.free(data_dir_val);

        const keys = [_]ManagedKey{
            .{ .section = "wallet", .key = "api_listen_interface", .value = "\"127.0.0.1\"" },
            .{ .section = "wallet", .key = "owner_api_listen_port", .value = wallet_rpc_port },
            .{ .section = "wallet", .key = "check_node_api_http_addr", .value = node_addr },
            .{ .section = "wallet", .key = "api_secret_path", .value = secret_path },
            .{ .section = "wallet", .key = "data_file_dir", .value = data_dir_val },
        };

        var file = try dir.openFile(io, wallet_conf_file, .{});
        const stat = try file.stat(io);
        const size: usize = @intCast(@min(stat.size, 256 * 1024));
        const input = try allocator.alloc(u8, size);
        defer allocator.free(input);
        const n = try file.readPositionalAll(io, input, 0);
        file.close(io);

        const patched = try patchTomlAlloc(allocator, input[0..n], &keys);
        defer allocator.free(patched);
        if (std.mem.eql(u8, patched, input[0..n])) return;
        try dir.writeFile(io, .{ .sub_path = wallet_conf_file, .data = patched });
    }

    /// Ensure `epic-wallet.toml` exists (write the default if not) and heal the keys
    /// BoxWallet manages, creating the top dir if needed. Both the CLI bootstrap
    /// (`init -r` reads `data_file_dir` from it) and the Owner-API launch (the
    /// listener reads the whole config) need it in place. Idempotent.
    fn ensureWalletConfig(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !void {
        const top = try dataDir(allocator, home);
        defer allocator.free(top);

        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, top, .{});
        defer dir.close(io);

        if (dir.access(io, wallet_conf_file, .{})) |_| {} else |_| {
            const tmpl = try defaultWalletToml(allocator, top);
            defer allocator.free(tmpl);
            try dir.writeFile(io, .{ .sub_path = wallet_conf_file, .data = tmpl });
        }
        try patchWalletConf(allocator, io, dir, top);
    }

    /// Draw a fresh per-session Owner-API secret from the OS CSPRNG, write it to
    /// `<top>/.owner_api_secret` (exact bytes, no trailing newline so the basic-auth
    /// header matches what the listener reads), and cache it for `walletPost`. Run on
    /// every wallet-process launch so the RPC (which exposes the seed) is locked to
    /// this BoxWallet run.
    fn writeOwnerSecret(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !void {
        const top = try dataDir(allocator, home);
        defer allocator.free(top);

        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, top, .{});
        defer dir.close(io);

        var secret_buf: [32]u8 = undefined;
        defer @memset(&secret_buf, 0);
        const secret = conf.randomPassword(io, &secret_buf);
        try dir.writeFile(io, .{ .sub_path = owner_secret_file, .data = secret });
        OwnerSecret.set(secret);
    }

    /// argv to (re)launch `epic-wallet owner_api` against the managed wallet, opened
    /// with `wallet_password`. epic-wallet 4.0.1 only starts the Owner-API listener
    /// when (a) a wallet already exists on disk — so create/restore materialize one
    /// via `init -r` first (see `runInitRecover`) — and (b) the wallet password is
    /// supplied at launch; that's why Epic is a launch-with-password wallet rather
    /// than an eagerly-spawned one. `--offline_mode` lets it come up before the node
    /// has finished syncing (it otherwise exits on its startup sync check); `-c <top>`
    /// pins it to the managed config regardless of BoxWallet's cwd (the `owner_api`
    /// subcommand ignores `-t`). The password rides argv only — never disk — matching
    /// the Zano launch-with-password convention. Caller owns the returned slice.
    fn launchServerArgv(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home: []const u8,
        port: []const u8,
        wallet_password: []const u8,
    ) anyerror![]const []const u8 {
        _ = port; // bound via the config's `owner_api_listen_port`, not a flag.

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        try ensureWalletConfig(allocator, io, home);
        try writeOwnerSecret(allocator, io, home);

        const bin = try std.fs.path.join(allocator, &.{ install_root, wallet_file });
        errdefer allocator.free(bin);
        const top = try dataDir(allocator, home);
        errdefer allocator.free(top);
        const pass = try allocator.dupe(u8, wallet_password);
        errdefer allocator.free(pass);

        const argv = try allocator.alloc([]const u8, 7);
        errdefer allocator.free(argv);
        argv[0] = bin;
        argv[1] = try allocator.dupe(u8, "--offline_mode");
        argv[2] = try allocator.dupe(u8, "-p");
        argv[3] = pass;
        argv[4] = try allocator.dupe(u8, "-c");
        argv[5] = top;
        argv[6] = try allocator.dupe(u8, "owner_api");
        return argv;
    }

    /// Materialize the managed wallet on disk from a BIP39 `mnemonic` under
    /// `password` by running `epic-wallet -t <top> -p <pw> init -r` and feeding the
    /// phrase on the child's stdin. This is the only headless path that creates a
    /// wallet: the Owner API can't (its listener won't start until a wallet exists),
    /// and the new-wallet `init` reads its password straight from the TTY. Shared by
    /// restore (the user's phrase) and create (a freshly generated one). The config is
    /// written first (init -r reads `data_file_dir` from it). `detail` carries a
    /// reason on failure.
    ///
    /// The phrase is delivered via a **temp file** handed to the child as stdin, not a
    /// pipe: a pipe write races the app's concurrent TUI event loop and can leave the
    /// child reading EOF with no phrase (epic-wallet then logs "User Cancelled"),
    /// whereas a regular-file stdin is read deterministically by the child regardless
    /// of what the parent's io is doing. The phrase is a secret on disk, so the temp
    /// file is overwritten and deleted on every path (the documented temp-secret
    /// pattern); the password still rides argv only (never disk).
    fn runInitRecover(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home: []const u8,
        password: []const u8,
        mnemonic: []const u8,
        detail: *Coin.WalletErrSink,
    ) !void {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const bin = try std.fs.path.join(allocator, &.{ install_root, wallet_file });
        defer allocator.free(bin);
        const top = try dataDir(allocator, home);
        defer allocator.free(top);

        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, top, .{});
        defer dir.close(io);

        // epic-wallet's `init -r` writes the wallet config itself, and at the default
        // ~/.epic location it refuses to run when `epic-wallet.toml` already exists
        // ("... already exists in the target directory. Please remove it first"). So
        // remove any managed config first; init -r recreates a complete default one
        // (localhost Owner API on 3420 already), which `launchServerArgv`'s
        // `ensureWalletConfig` then heals for our secret/paths before the wallet
        // process is launched. (Don't pre-write it here — that's what tripped the
        // guard.)
        dir.deleteFile(io, wallet_conf_file) catch {};

        // Write the (newline-terminated) phrase to the temp file the child will read
        // as stdin, then wipe + delete it on every exit path — it holds the seed.
        {
            var f = try dir.createFile(io, recover_phrase_file, .{ .truncate = true });
            f.writeStreamingAll(io, mnemonic) catch {};
            f.writeStreamingAll(io, "\n") catch {};
            f.close(io);
        }
        defer {
            if (dir.createFile(io, recover_phrase_file, .{ .truncate = true })) |zf| {
                var zeros: [320]u8 = [_]u8{0} ** 320;
                zf.writeStreamingAll(io, zeros[0..@min(zeros.len, mnemonic.len + 1)]) catch {};
                zf.close(io);
            } else |_| {}
            dir.deleteFile(io, recover_phrase_file) catch {};
        }

        const stdin_file = try dir.openFile(io, recover_phrase_file, .{});

        const argv = [_][]const u8{ bin, "-t", top, "-p", password, "init", "-r" };
        var child = std.process.spawn(io, .{
            .argv = &argv,
            .stdin = .{ .file = stdin_file },
            .stdout = .ignore,
            .stderr = .pipe,
            .create_no_window = builtin.os.tag == .windows,
        }) catch |err| {
            stdin_file.close(io);
            detail.set(@errorName(err));
            return error.WalletRestoreFailed;
        };
        stdin_file.close(io); // the child holds its own dup of the fd

        // Drain stderr — epic-wallet reports a bad phrase there ("Recovery word phrase
        // is invalid.") — so a failed restore is surfaced honestly rather than as a
        // generic message. Bounded read (one short line); reading to EOF also waits out
        // the child's work before `wait`. stdout carries only the (discarded) prompt.
        var errbuf: [512]u8 = undefined;
        var errlen: usize = 0;
        if (child.stderr) |stderr| {
            while (errlen < errbuf.len) {
                const got = stderr.readStreaming(io, &.{errbuf[errlen..]}) catch break;
                if (got == 0) break;
                errlen += got;
            }
            stderr.close(io);
            child.stderr = null;
        }

        const term = child.wait(io) catch |err| {
            detail.set(@errorName(err));
            return error.WalletRestoreFailed;
        };
        const ok = switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
        // The CLI exits 0 and writes `wallet_data/wallet.seed` on success; a bad
        // phrase, a checksum mismatch, or a pre-existing wallet leaves it absent.
        if (!ok or !walletExists(allocator, home)) {
            const why = std.mem.trim(u8, errbuf[0..errlen], " \t\r\n");
            detail.set(if (why.len > 0) why else "epic-wallet could not initialize the wallet from the recovery phrase");
            return error.WalletRestoreFailed;
        }
    }

    /// argv for a full repair scan: `epic-wallet -t <top> -p <pw> scan`. Pulled out
    /// (like `launchServerArgv`/`daemonArgv`) so the command shape is unit-testable
    /// without a wallet. The password rides argv only — never disk — matching the
    /// launch-with-password convention. Caller owns the returned slice + strings.
    fn scanArgv(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home: []const u8,
        password: []const u8,
    ) ![]const []const u8 {
        const bin = try std.fs.path.join(allocator, &.{ install_root, wallet_file });
        errdefer allocator.free(bin);
        const top = try dataDir(allocator, home);
        errdefer allocator.free(top);
        const pass = try allocator.dupe(u8, password);
        errdefer allocator.free(pass);

        const argv = try allocator.alloc([]const u8, 6);
        errdefer allocator.free(argv);
        argv[0] = bin;
        argv[1] = try allocator.dupe(u8, "-t");
        argv[2] = top;
        argv[3] = try allocator.dupe(u8, "-p");
        argv[4] = pass;
        argv[5] = try allocator.dupe(u8, "scan");
        return argv;
    }

    /// Rebuild a freshly-restored wallet's output set from the live node by running
    /// `epic-wallet … scan` (the documented recovery step). A wallet materialized by
    /// `init -r` holds only its seed — no outputs — so its balance reads zero until
    /// the chain is scanned and the seed's existing outputs are restored. This is
    /// Epic's analogue of Ergo's rescan-on-restore; but Epic has no async/background
    /// scan (`scan` blocks until done), so it runs **synchronously** here, and
    /// **before** the owner_api is launched so nothing else holds the wallet's
    /// database. The scan must reach the node (no `--offline_mode`); a node that's
    /// unreachable/unsynced is surfaced honestly via `detail`.
    ///
    /// epic-wallet's log4rs writes to **stdout** (not stderr), and the failing
    /// `ERROR …` line trails a multi-line INFO banner, so we pipe stdout and keep its
    /// **tail** (a bounded ring), then lift the last `ERROR` line out of it (see
    /// `scanErrLine`). The password rides argv only.
    fn runScan(
        allocator: std.mem.Allocator,
        io: std.Io,
        install_root: []const u8,
        home: []const u8,
        password: []const u8,
        detail: *Coin.WalletErrSink,
    ) !void {
        const argv = try scanArgv(allocator, install_root, home, password);
        defer {
            for (argv) |s| allocator.free(s);
            allocator.free(argv);
        }

        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
            .create_no_window = builtin.os.tag == .windows,
        }) catch |err| {
            detail.set(@errorName(err));
            return error.WalletRescanFailed;
        };

        // Drain stdout keeping only the tail: when the buffer fills, drop the older
        // half and keep reading, so the trailing `ERROR` line survives the INFO
        // banner ahead of it. Reading to EOF also waits out the scan before `wait`.
        var buf: [1024]u8 = undefined;
        var len: usize = 0;
        if (child.stdout) |stdout| {
            while (true) {
                if (len == buf.len) {
                    const keep = buf.len / 2;
                    std.mem.copyForwards(u8, buf[0..keep], buf[buf.len - keep ..]);
                    len = keep;
                }
                const got = stdout.readStreaming(io, &.{buf[len..]}) catch break;
                if (got == 0) break;
                len += got;
            }
            stdout.close(io);
            child.stdout = null;
        }

        const term = child.wait(io) catch |err| {
            detail.set(@errorName(err));
            return error.WalletRescanFailed;
        };
        const ok = switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!ok) {
            const why = scanErrLine(buf[0..len]);
            detail.set(if (why.len > 0) why else "epic-wallet could not scan the chain — make sure the Epic daemon is running and synced, then restore again");
            return error.WalletRescanFailed;
        }
    }

    /// Pull the actionable reason out of captured `epic-wallet scan` output: the last
    /// `ERROR …` line (e.g. "Failed to check node sync status: … error sending
    /// request" when the node is down), with the `<timestamp> ERROR ` prefix stripped
    /// so the user sees just the message. Returns "" when there's no ERROR line (the
    /// caller then uses a generic fallback). Pure — unit-testable without a wallet.
    fn scanErrLine(out: []const u8) []const u8 {
        var best: []const u8 = "";
        var it = std.mem.splitScalar(u8, out, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (std.mem.indexOf(u8, t, "ERROR") != null) best = t;
        }
        if (best.len == 0) return "";
        // Drop everything up to and including the "ERROR " marker → keep the message.
        if (std.mem.indexOf(u8, best, "ERROR ")) |i|
            return std.mem.trim(u8, best[i + "ERROR ".len ..], " \t\r");
        return best;
    }

    // --- Wallet ops over the encrypted Owner API -------------------------

    /// Run one encrypted Owner-API call and require success; on a wallet-level error
    /// (`Err`) the daemon's reason is copied into `detail` and `fail` returned. The
    /// decrypted inner reply is returned on success (caller wipes + frees).
    fn runWalletRpc(
        allocator: std.mem.Allocator,
        io: std.Io,
        auth: models.CoinAuth,
        method: []const u8,
        params: []const u8,
        detail: *Coin.WalletErrSink,
        fail: anyerror,
    ) ![]u8 {
        const r = secureRpc(allocator, io, auth, method, params) catch |err| {
            // Surface the server's raw reply at the failing step so the UI shows why
            // the secure channel broke rather than a bare error name.
            if (channel_err_len > 0) detail.set(channel_err[0..channel_err_len]);
            return err;
        };
        if (!innerSucceeded(r)) {
            setErrDetail(detail, r);
            @memset(r, 0);
            allocator.free(r);
            return fail;
        }
        return r;
    }

    /// `open_wallet` with `pw_q` (already JSON-escaped) and cache the returned token
    /// so the balance poll can read the now-open wallet. Shared by open/create/restore.
    fn openAndCacheToken(
        allocator: std.mem.Allocator,
        io: std.Io,
        auth: models.CoinAuth,
        pw_q: []const u8,
        detail: *Coin.WalletErrSink,
    ) !void {
        // `pw_q` is a complete JSON string token — `jsonQuote` already includes the
        // surrounding quotes — so embed it bare (`:{s}`), not wrapped in more quotes,
        // or the inner JSON is malformed (`""pw""`) and the daemon rejects the
        // decrypted body as invalid JSON.
        const params = try std.fmt.allocPrint(allocator, "{{\"name\":null,\"password\":{s}}}", .{pw_q});
        defer {
            @memset(params, 0);
            allocator.free(params);
        }
        const r = try runWalletRpc(allocator, io, auth, "open_wallet", params, detail, error.WalletOpenFailed);
        defer {
            @memset(r, 0);
            allocator.free(r);
        }
        const token = try parseOkString(allocator, r);
        defer {
            @memset(token, 0);
            allocator.free(token);
        }
        Session.set(token);
    }

    /// Generate a fresh 24-word BIP39 recovery phrase from the OS CSPRNG and
    /// materialize the wallet from it via `init -r` — the headless create path (the
    /// Owner API can't bootstrap a wallet and the new-wallet `init` needs a TTY; see
    /// `runInitRecover`). `epicCreate` then reads the phrase back over the Owner API
    /// for the user to back up. The generated phrase is wiped here once restored.
    /// Wired as the wallet's `cli_create`: the app runs this, launches the wallet
    /// process, then calls `create` to read the seed.
    fn epicCliCreate(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home: []const u8,
        password: []const u8,
        detail: *Coin.WalletErrSink,
    ) anyerror!void {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();

        var seed_buf: [bip39.max_mnemonic_len]u8 = undefined;
        defer @memset(&seed_buf, 0);
        const mnemonic = bip39.generate(threaded.io(), 24, &seed_buf) catch |err| {
            detail.set(@errorName(err));
            return error.WalletCreateFailed;
        };
        runInitRecover(allocator, install_root, home, password, mnemonic, detail) catch
            return error.WalletCreateFailed;
    }

    /// Read the just-created wallet's 24-word recovery phrase back over the Owner API
    /// (`get_mnemonic`) so the UI can show it for backup, then open it so the balance
    /// polls immediately. The wallet was materialized by `epicCliCreate` (BIP39
    /// generate → `init -r`) before the Owner-API process was launched, so there's no
    /// `create_wallet` call here — the Owner API can't run without an existing wallet.
    fn epicCreate(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        password: []const u8,
        detail: *Coin.WalletErrSink,
    ) anyerror!models.Seed {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const pw_q = try rpc.jsonQuote(allocator, password);
        defer {
            @memset(pw_q, 0);
            allocator.free(pw_q);
        }

        // `pw_q` already carries its surrounding quotes (see `openAndCacheToken`).
        const gm_params = try std.fmt.allocPrint(allocator, "{{\"name\":null,\"password\":{s}}}", .{pw_q});
        defer {
            @memset(gm_params, 0);
            allocator.free(gm_params);
        }
        const r2 = try runWalletRpc(allocator, io, auth, "get_mnemonic", gm_params, detail, error.WalletCreateFailed);
        defer {
            @memset(r2, 0);
            allocator.free(r2);
        }
        const phrase = try parseOkString(allocator, r2);
        defer {
            @memset(phrase, 0);
            allocator.free(phrase);
        }
        const seed = models.Seed.from(phrase);

        // Open it now so the wallet is ready and its balance polls immediately.
        try openAndCacheToken(allocator, io, auth, pw_q, detail);
        return seed;
    }

    /// Restore a wallet from a mnemonic `seed` under `password` via `init -r` (the
    /// app launches the wallet process and opens it next). The seed is normalized
    /// (lowercase + collapse whitespace) per the restore convention and the working
    /// copy wiped. `auth` is unused — restore is a CLI bootstrap, not an Owner-API
    /// call (the Owner API can't run until the wallet it would create exists).
    fn epicRestore(
        allocator: std.mem.Allocator,
        _: models.CoinAuth,
        install_root: []const u8,
        home: []const u8,
        password: []const u8,
        seed: []const u8,
        detail: *Coin.WalletErrSink,
    ) anyerror!void {
        const normalized = try models.normalizeSeedWords(allocator, seed);
        defer {
            @memset(normalized, 0);
            allocator.free(normalized);
        }
        try runInitRecover(allocator, install_root, home, password, normalized, detail);

        // `init -r` writes only the seed; the wallet has no output set yet. The app
        // launches the owner_api and opens the wallet next, and the balance poll's
        // `retrieve_summary_info` (refresh_from_node) recovers the seed's outputs as
        // the node serves them — so the balance fills in once the node is fully
        // synced. We additionally run an explicit `scan` here to *front-load* that
        // recovery while nothing else holds the wallet open (before the owner_api
        // launches), so a synced node shows the balance immediately on restore.
        //
        // This scan is **best-effort**: it hard-refuses on a node that isn't fully
        // synced ("Node is currently syncing…"), which is the common state right
        // after install. A restore must not fail for that — `init -r` genuinely
        // restored the wallet, and the refresh path above recovers the funds once the
        // node catches up. So swallow any scan error; the user sees the node's sync
        // progress in the daemon panel. See `runScan`.
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        ensureWalletConfig(allocator, io, home) catch {};
        runScan(allocator, io, install_root, home, password, detail) catch {
            // Non-fatal — clear any reason the scan left in the sink so it can't be
            // mistaken for a restore failure by the caller.
            detail.set("");
        };
    }

    /// Open the existing wallet with `password` (caching its token), so its balance
    /// can be read.
    fn epicOpen(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        password: []const u8,
        detail: *Coin.WalletErrSink,
    ) anyerror!void {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const pw_q = try rpc.jsonQuote(allocator, password);
        defer {
            @memset(pw_q, 0);
            allocator.free(pw_q);
        }
        try openAndCacheToken(allocator, threaded.io(), auth, pw_q, detail);
    }

    /// Lock the wallet: `close_wallet` zeroizes the open seed in the owner_api
    /// process, then the cached token is dropped. On failure the wallet stays open
    /// (honestly reported) and the token is kept.
    fn epicLock(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        detail: *Coin.WalletErrSink,
    ) anyerror!void {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const r = try runWalletRpc(allocator, threaded.io(), auth, "close_wallet", "{\"name\":null}", detail, error.WalletLockFailed);
        @memset(r, 0);
        allocator.free(r);
        Session.clear();
    }

    /// Remove the managed wallet's on-disk artifacts (the `wallet_data` tree) so a
    /// new one can be created/restored in its place, and drop any cached token.
    fn epicRemove(allocator: std.mem.Allocator, home: []const u8) anyerror!void {
        Session.clear();
        OwnerSecret.clear();
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const dir = try walletDataDir(allocator, home);
        defer allocator.free(dir);
        try std.Io.Dir.cwd().deleteTree(threaded.io(), dir);
    }

    /// The open wallet's balances, from `retrieve_summary_info` (needs the cached
    /// token). Amounts are integer base units (1e8 per EPIC) as strings; `available`
    /// is the spendable figure, `total` the grand total (so it leads while funds
    /// settle). Errors `error.WalletLocked` when no wallet is open.
    fn epicBalance(allocator: std.mem.Allocator, auth: models.CoinAuth) anyerror!models.WalletBalance {
        var token_buf: [128]u8 = undefined;
        const tn = Session.get(&token_buf) orelse return error.WalletLocked;

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();

        const params = try std.fmt.allocPrint(
            allocator,
            "{{\"token\":\"{s}\",\"refresh_from_node\":true,\"minimum_confirmations\":1}}",
            .{token_buf[0..tn]},
        );
        defer allocator.free(params);

        const r = try secureRpc(allocator, threaded.io(), auth, "retrieve_summary_info", params);
        defer {
            @memset(r, 0);
            allocator.free(r);
        }
        if (!innerSucceeded(r)) return error.WalletBalanceFailed;
        return parseSummaryInfo(allocator, r);
    }

    /// Amounts a `retrieve_summary_info` reports (as integer-base-unit strings).
    const Amounts = struct {
        amount_currently_spendable: []const u8 = "0",
        total: []const u8 = "0",
    };

    /// Map a decrypted `retrieve_summary_info` reply — `{"result":{"Ok":[<bool>,
    /// {amounts…}]}}` — into a normalized balance (whole EPIC). Pulled out as a pure
    /// function so the parse is unit-testable without a wallet.
    fn parseSummaryInfo(allocator: std.mem.Allocator, inner: []const u8) !models.WalletBalance {
        const Env = struct {
            result: ?struct { Ok: ?struct { bool, Amounts } = null } = null,
        };
        var parsed = try std.json.parseFromSlice(Env, allocator, inner, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();
        const ok = (parsed.value.result orelse return error.WalletBalanceFailed).Ok orelse
            return error.WalletBalanceFailed;
        const amounts = ok[1];
        const spendable = std.fmt.parseInt(u64, amounts.amount_currently_spendable, 10) catch 0;
        const total = std.fmt.parseInt(u64, amounts.total, 10) catch 0;
        return .{
            .available = @as(f64, @floatFromInt(spendable)) / epic_base,
            .total = @as(f64, @floatFromInt(total)) / epic_base,
        };
    }

    // --- Transactions (Owner API `retrieve_txs`) --------------------------
    //
    // MimbleWimble has no on-chain addresses and its transactions are built
    // *interactively* (a slate exchanged between sender and receiver — over a
    // listener or an epicbox relay), so BoxWallet can't offer a fire-and-forget
    // Send or a Receive address for Epic; those tabs keep their placeholder.
    // The wallet's own transaction log, however, is honest data the Owner API
    // reports directly — so the Transactions tab is live.

    /// One `retrieve_txs` TxLogEntry (the subset BoxWallet uses). Amounts are
    /// integer-base-unit strings; `creation_ts` is an RFC-3339 timestamp;
    /// `confirmed` is the only settlement state the wallet reports (no count).
    const TxLogEntry = struct {
        tx_type: []const u8 = "",
        creation_ts: []const u8 = "",
        confirmed: bool = false,
        amount_credited: []const u8 = "0",
        amount_debited: []const u8 = "0",
    };

    /// Stand-in confirmation count for a `confirmed` entry — the wallet reports
    /// settlement only as a boolean, so a settled transaction is given a value
    /// safely past any frontend's "settled" threshold and an unsettled one 0.
    const confirmed_sentinel: i64 = 9999;

    /// The open wallet's most recent transactions, newest-first, via the Owner
    /// API's `retrieve_txs` (needs the cached token — `error.WalletLocked` when
    /// no wallet is open, same as the balance read). The reply spans the whole
    /// tx log, but only the `limit` newest normalized rows survive; the
    /// decrypted reply is wiped before free like every Owner-API buffer.
    fn epicTransactions(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        limit: usize,
    ) anyerror![]models.WalletTx {
        var token_buf: [128]u8 = undefined;
        const tn = Session.get(&token_buf) orelse return error.WalletLocked;

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();

        const params = try std.fmt.allocPrint(
            allocator,
            "{{\"token\":\"{s}\",\"refresh_from_node\":true,\"tx_id\":null,\"tx_slate_id\":null}}",
            .{token_buf[0..tn]},
        );
        defer allocator.free(params);

        const r = try secureRpc(allocator, threaded.io(), auth, "retrieve_txs", params);
        defer {
            @memset(r, 0);
            allocator.free(r);
        }
        if (!innerSucceeded(r)) return error.WalletTransactionsFailed;
        return parseTxLog(allocator, r, limit);
    }

    /// Map a decrypted `retrieve_txs` reply — `{"result":{"Ok":[<bool>,
    /// [entries…]]}}` — into normalized `WalletTx`es, newest-first, capped at
    /// `limit`. Cancelled entries are dropped. Pulled out as a pure function so
    /// the parse is unit-testable without a wallet.
    fn parseTxLog(allocator: std.mem.Allocator, inner: []const u8, limit: usize) ![]models.WalletTx {
        const Env = struct {
            result: ?struct { Ok: ?struct { bool, []TxLogEntry } = null } = null,
        };
        var parsed = try std.json.parseFromSlice(Env, allocator, inner, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();
        const ok = (parsed.value.result orelse return error.WalletTransactionsFailed).Ok orelse
            return error.WalletTransactionsFailed;
        const entries = ok[1];

        const all = try allocator.alloc(models.WalletTx, entries.len);
        defer allocator.free(all);
        var n: usize = 0;
        for (entries) |e| {
            const direction = directionFromTxType(e.tx_type) orelse continue;
            const credited = std.fmt.parseInt(u64, e.amount_credited, 10) catch 0;
            const debited = std.fmt.parseInt(u64, e.amount_debited, 10) catch 0;
            // The wallet's net movement: a receive credits more than it debits, a
            // send the reverse (the difference includes the fee).
            const net = if (credited >= debited) credited - debited else debited - credited;
            all[n] = .{
                .direction = direction,
                .amount = @as(f64, @floatFromInt(net)) / epic_base,
                .time = parseRfc3339(e.creation_ts) orelse 0,
                .confirmations = if (e.confirmed) confirmed_sentinel else 0,
            };
            n += 1;
        }
        std.mem.sort(models.WalletTx, all[0..n], {}, newerFirst);

        const out = try allocator.alloc(models.WalletTx, @min(n, limit));
        @memcpy(out, all[0..out.len]);
        return out;
    }

    /// Map a TxLogEntry's `tx_type` (grin's TxLogEntryType names) to the
    /// normalized direction. A `ConfirmedCoinbase` was mined by the wallet
    /// itself; cancelled entries have no direction (null — dropped).
    fn directionFromTxType(tx_type: []const u8) ?models.TxDirection {
        if (std.mem.eql(u8, tx_type, "TxReceived")) return .received;
        if (std.mem.eql(u8, tx_type, "TxSent")) return .sent;
        if (std.mem.eql(u8, tx_type, "ConfirmedCoinbase")) return .stake;
        return null;
    }

    /// Sort helper: newest (largest timestamp) first.
    fn newerFirst(_: void, lhs: models.WalletTx, rhs: models.WalletTx) bool {
        return lhs.time > rhs.time;
    }

    /// Parse the leading `YYYY-MM-DDTHH:MM:SS` of an RFC-3339 timestamp into
    /// unix seconds (UTC). The wallet serializes `creation_ts` with fractional
    /// seconds and a `Z` suffix, both ignored. Null on malformed input.
    fn parseRfc3339(ts: []const u8) ?i64 {
        if (ts.len < 19) return null;
        if (ts[4] != '-' or ts[7] != '-' or (ts[10] != 'T' and ts[10] != ' ') or ts[13] != ':' or ts[16] != ':') return null;
        const year = std.fmt.parseInt(i64, ts[0..4], 10) catch return null;
        const month = std.fmt.parseInt(i64, ts[5..7], 10) catch return null;
        const day = std.fmt.parseInt(i64, ts[8..10], 10) catch return null;
        const hour = std.fmt.parseInt(i64, ts[11..13], 10) catch return null;
        const minute = std.fmt.parseInt(i64, ts[14..16], 10) catch return null;
        const second = std.fmt.parseInt(i64, ts[17..19], 10) catch return null;
        if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 60) return null;
        return daysFromCivil(year, month, day) * 86_400 + hour * 3_600 + minute * 60 + second;
    }

    /// Days since the unix epoch for a civil (proleptic Gregorian) date —
    /// Howard Hinnant's `days_from_civil` algorithm.
    fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
        const y = if (m <= 2) y_in - 1 else y_in;
        const era = @divFloor(y, 400);
        const yoe = y - era * 400;
        const mp = @mod(m + 9, 12);
        const doy = @divFloor(153 * mp + 2, 5) + d - 1;
        const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
        return era * 146_097 + doe - 719_468;
    }

    /// Count whitespace-separated words in a seed phrase (for picking the restore
    /// `mnemonic_length`). The daemon does the real validation.
    fn wordCount(seed: []const u8) usize {
        var it = std.mem.tokenizeAny(u8, seed, " \t\r\n");
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        return n;
    }

    /// Epic's external (process-backed) wallet capability. epic-wallet 4.0.1 only
    /// starts its Owner-API listener against an existing wallet and with the password
    /// at launch, so it's a **launch-with-password** wallet (like Zano): the process
    /// is (re)launched per-open via `launch_server_argv`, and a wallet is first
    /// materialized on disk by a CLI `init -r` — `cli_create` for create (a generated
    /// BIP39 phrase) and `restore_seed` for restore (the user's). Open/lock/balance
    /// then run over the encrypted Owner API.
    pub const external_wallet: Coin.ExternalWallet = .{
        .rpc_port = walletRpcPort,
        .launch_server_argv = launchServerArgv,
        .cli_create = epicCliCreate,
        .exists = walletExists,
        .create = epicCreate,
        .restore_seed = epicRestore,
        .open = epicOpen,
        .lock = epicLock,
        .remove = epicRemove,
        .balance = epicBalance,
        // Epic/grin generate a 24-word phrase by default; 12 is also accepted.
        .seed_word_counts = &.{ 24, 12 },
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
        .daemon_log_file = vtDaemonLogFile,
        .warmup_stage_from_log = vtWarmupStageFromLog,
        .daemon_argv = vtDaemonArgv,
        .request_stop = vtRequestStop,
        .wallet_path = vtWalletPath,
        // Only transactions: MimbleWimble transactions are interactive slate
        // exchanges, so there is no fire-and-forget Send or on-chain Receive
        // address to offer (see the `retrieve_txs` section above) — those tabs
        // keep their placeholder.
        .wallet_transactions = vtWalletTransactions,
        .external_wallet = &external_wallet,
    };

    // Rides the wallet process's encrypted Owner API: `app.zig` passes
    // `extWalletAuth()` and calls it only once the wallet is open.
    fn vtWalletTransactions(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        limit: usize,
    ) anyerror![]models.WalletTx {
        return epicTransactions(allocator, wallet_auth, limit);
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
        return prepareConf(allocator, io, install_root, home);
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

test "node download resolves to the 4.0.3 tar.gz only on linux/amd64" {
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

test "patchTomlAlloc turns the node's file log on without touching its path" {
    const allocator = std.testing.allocator;
    // The `[logging]` block `epic server config` generates, verbatim: file
    // logging off, Debug level, and an absolute path already inside the data dir.
    const input =
        \\[logging]
        \\log_to_stdout = true
        \\stdout_log_level = "INFO"
        \\log_to_file = false
        \\file_log_level = "DEBUG"
        \\log_file_path = "/home/u/.epic/main/epic-server.log"
        \\log_max_size = 16777216
        \\
    ;
    const out = try Epic.patchTomlAlloc(allocator, input, &Epic.managed_conf);
    defer allocator.free(out);

    // Without this the node's whole start-up goes to a stdout we discard.
    try std.testing.expect(std.mem.indexOf(u8, out, "log_to_file = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "log_to_file = false") == null);
    // Debug would cost rotations of disk for the handful of lines we want.
    try std.testing.expect(std.mem.indexOf(u8, out, "file_log_level = \"Info\"") != null);
    // Where the node puts its log is the node's business — and it's already the
    // data dir, where `daemonLogFile` looks.
    try std.testing.expect(std.mem.indexOf(u8, out, "log_file_path = \"/home/u/.epic/main/epic-server.log\"") != null);
    // Unmanaged keys in the section survive untouched.
    try std.testing.expect(std.mem.indexOf(u8, out, "log_max_size = 16777216") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "log_to_stdout = true") != null);
}

test "the node's start-up stage is read from epic-server.log" {
    // Verbatim from a live `epic server run`, in order.
    const warming =
        \\2026-08-13 20:18:27.923 INFO This is Epic version 4.0.3 (git v4.0.3)
        \\2026-08-13 20:18:28.923 INFO Starting EPIC w/o UI...
        \\2026-08-13 20:18:28.936 INFO Warm up Epic node server from genesis(454018a56d86), ...
        \\
    ;
    try std.testing.expectEqualStrings("Loading blockchain…", Epic.warmupStageFromLog(warming));

    try std.testing.expectEqualStrings("Starting API server…", Epic.warmupStageFromLog(warming ++
        "2026-08-13 20:18:29.117 INFO Starting HTTP Node APIs server at 127.0.0.1:3413.\n"));

    // "Epic node server started." ends the start-up — and has to beat the
    // "warm up epic node server" needle it shares wording with.
    try std.testing.expectEqualStrings("", Epic.warmupStageFromLog(warming ++
        "2026-08-13 20:18:29.119 INFO Epic node server started.\n"));

    // A stopped node is not a starting one.
    try std.testing.expectEqualStrings("", Epic.warmupStageFromLog(
        \\2026-08-13 20:18:59.486 WARN Shutting down...
        \\2026-08-13 20:19:00.487 WARN Shutdown complete.
        \\
    ));

    // Steady-state peer traffic says nothing about a start-up.
    try std.testing.expectEqualStrings("", Epic.warmupStageFromLog(
        "2026-08-13 20:18:45.442 INFO Asking 89.58.53.79:3414 for more peers.\n",
    ));
}

test "coin vtable dispatches to Epic metadata and the external wallet" {
    const allocator = std.testing.allocator;
    var epic: Epic = .{};
    const c = epic.coin();
    try std.testing.expectEqualStrings("Epic Cash", c.coinName());
    try std.testing.expectEqualStrings("EPIC", c.coinNameAbbrev());
    try std.testing.expectEqualStrings("#deac55", c.coinColor());
    try std.testing.expectEqualStrings("4.0.3", c.coreVersion());
    try std.testing.expect(!c.isProofOfStake());
    try std.testing.expectEqualStrings("3413", c.rpcDefaultPort());
    try std.testing.expectEqual(Coin.LaunchMode.foreground, c.launchMode());
    // Epic logs to stdout by default (which we discard); `managed_conf` turns the
    // file on so there's something under the data dir to read.
    try std.testing.expectEqualStrings("epic-server.log", c.daemonLogFile().?);
    // Epic drives a launch-with-password external wallet, backed by a separate
    // `epic-wallet owner_api` process the app (re)launches per-open with the password
    // (it won't serve without one). (The bitcoin-style in-daemon hooks —
    // `wallet_security_state`/`wallet_balance` — stay unused: balance flows through
    // the external wallet's own `balance`.)
    try std.testing.expect(c.hasExternalWallet());
    try std.testing.expect(c.hasExternalWalletProcess());
    try std.testing.expect(c.walletLaunchesWithPassword());
    try std.testing.expect(c.supportsSeedRestore());
    try std.testing.expect(c.supportsWalletReplace());
    try std.testing.expect(!c.supportsWallet());
    try std.testing.expect(!c.supportsBalance());
    const ew = c.externalWallet().?;
    try std.testing.expectEqualStrings(Epic.wallet_rpc_port, ew.rpc_port.?());
    try std.testing.expectEqualSlices(usize, &.{ 24, 12 }, c.seedWordCounts());
    // The Settings tab now points at the managed wallet.seed.
    const wf = (try c.walletPath(allocator, "/home/alice")).?;
    defer allocator.free(wf.path);
    defer if (wf.keys) |k| allocator.free(k);
    try std.testing.expect(std.mem.endsWith(u8, wf.path, "wallet.seed"));
    try std.testing.expect(wf.keys == null);
}

// --- Encrypted Owner API tests -------------------------------------------

test "ECDH derives the same AES key on both sides of the handshake" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Two ephemeral keypairs stand in for the client (us) and the server: each
    // derives the key from its own secret + the other's public key, and they must
    // agree (this is exactly the init_secure_api exchange).
    var sec_client: [32]u8 = undefined;
    const pub_client = Epic.clientPubHex(io, &sec_client);
    var sec_server: [32]u8 = undefined;
    const pub_server = Epic.clientPubHex(io, &sec_server);

    const key_client = try Epic.deriveKey(sec_client, &pub_server);
    const key_server = try Epic.deriveKey(sec_server, &pub_client);
    try std.testing.expectEqualSlices(u8, &key_client, &key_server);

    // A real shared point, not a degenerate all-zero key.
    var nonzero = false;
    for (key_client) |b| {
        if (b != 0) nonzero = true;
    }
    try std.testing.expect(nonzero);

    // A malformed server key is rejected, not silently keyed.
    try std.testing.expectError(error.BadServerKey, Epic.deriveKey(sec_client, "not-hex"));
}

test "encrypted_request_v3 seal round-trips through openResponse under one key" {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();

    var key: [32]u8 = undefined;
    for (&key, 0..) |*k, i| k.* = @intCast(i);

    const plaintext = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"open_wallet\",\"params\":{\"password\":\"hunter2\"}}";
    const req = try Epic.sealRequest(a, threaded.io(), key, plaintext);
    defer a.free(req);
    // The sealed request carries the method + a {nonce, body_enc} params object.
    try std.testing.expect(std.mem.indexOf(u8, req, "encrypted_request_v3") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "hunter2") == null); // ciphertext, not cleartext

    // Re-shape its params as a server response envelope and decrypt it back.
    const ReqEnv = struct { params: Epic.EncBody };
    var p = try std.json.parseFromSlice(ReqEnv, a, req, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer p.deinit();
    const resp = try std.fmt.allocPrint(
        a,
        "{{\"result\":{{\"Ok\":{{\"nonce\":\"{s}\",\"body_enc\":\"{s}\"}}}}}}",
        .{ p.value.params.nonce, p.value.params.body_enc },
    );
    defer a.free(resp);
    const got = try Epic.openResponse(a, key, resp);
    defer a.free(got);
    try std.testing.expectEqualStrings(plaintext, got);

    // A wrong key fails the GCM tag rather than returning garbage.
    var bad_key = key;
    bad_key[0] +%= 1;
    try std.testing.expectError(error.SecureChannelAuth, Epic.openResponse(a, bad_key, resp));
}

test "parseOkString and innerSucceeded read the Ok/Err envelope" {
    const a = std.testing.allocator;
    const ok = try Epic.parseOkString(a, "{\"id\":1,\"jsonrpc\":\"2.0\",\"result\":{\"Ok\":\"d096b3cb\"}}");
    defer a.free(ok);
    try std.testing.expectEqualStrings("d096b3cb", ok);
    // create_wallet succeeds with a null Ok; a failure carries Err.
    try std.testing.expect(Epic.innerSucceeded("{\"result\":{\"Ok\":null}}"));
    try std.testing.expect(!Epic.innerSucceeded("{\"result\":{\"Err\":{\"GenericError\":\"bad password\"}}}"));
    try std.testing.expectError(error.SecureChannelFailed, Epic.parseOkString(a, "{\"result\":{\"Err\":\"x\"}}"));
}

test "parseSummaryInfo maps base units to whole EPIC (8 decimals)" {
    // 1.5 EPIC spendable, 2.4 EPIC total, in 1e8 base units.
    const inner =
        \\{"id":1,"jsonrpc":"2.0","result":{"Ok":[true,{
        \\"amount_currently_spendable":"150000000","total":"240000000",
        \\"amount_awaiting_confirmation":"90000000","amount_immature":"0"}]}}
    ;
    const bal = try Epic.parseSummaryInfo(std.testing.allocator, inner);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), bal.available, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.4), bal.total, 1e-9);
    // Total leads available, so the UI shows funds still settling.
    try std.testing.expect(bal.hasPending());
}

test "wordCount counts whitespace-separated seed words" {
    try std.testing.expectEqual(@as(usize, 3), Epic.wordCount("  alpha   beta\tgamma\n"));
    try std.testing.expectEqual(@as(usize, 24), Epic.wordCount("a b c d e f g h i j k l m n o p q r s t u v w x"));
}

test "wallet download resolves to the 4.0.1 tarball only on linux/amd64" {
    if (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
        const dl = Epic.wallet_download orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(install_mod.Format.tar_gz, dl.format);
        try std.testing.expect(std.mem.indexOf(
            u8,
            dl.url,
            "/" ++ Epic.wallet_tag ++ "/epic-wallet-v4.0.1-linux-amd64-ubuntu24.04.tar.gz",
        ) != null);
        // The wrapper dir is dropped while untarring, so `epic-wallet` lands in the
        // install root — nothing to promote afterwards.
        try std.testing.expectEqual(@as(u32, 1), Epic.wallet_strip);
    } else {
        try std.testing.expect(Epic.wallet_download == null);
    }
}

test "defaultWalletToml bakes in all four sections + managed Owner-API/node values" {
    const a = std.testing.allocator;
    const toml = try Epic.defaultWalletToml(a, "/home/alice/.epic/main");
    defer a.free(toml);
    // All four config sections present, so the wallet binary deserializes it.
    try std.testing.expect(std.mem.indexOf(u8, toml, "[wallet]") != null);
    try std.testing.expect(std.mem.indexOf(u8, toml, "[epicbox]") != null);
    try std.testing.expect(std.mem.indexOf(u8, toml, "[tor]") != null);
    try std.testing.expect(std.mem.indexOf(u8, toml, "[logging]") != null);
    // Managed values.
    try std.testing.expect(std.mem.indexOf(u8, toml, "owner_api_listen_port = 3420") != null);
    try std.testing.expect(std.mem.indexOf(u8, toml, "api_listen_interface = \"127.0.0.1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toml, "check_node_api_http_addr = \"http://127.0.0.1:3413\"") != null);
    // The wallet's own owner-API secret vs the node's foreign-API secret.
    try std.testing.expect(std.mem.indexOf(u8, toml, "api_secret_path = \"/home/alice/.epic/main/.owner_api_secret\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toml, "node_api_secret_path = \"/home/alice/.epic/main/.foreign_api_secret\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toml, "data_file_dir = \"/home/alice/.epic/main/wallet_data\"") != null);
}

test "patchTomlAlloc heals a wallet config's interface/port to localhost" {
    const a = std.testing.allocator;
    // A config that binds the Owner API to all interfaces — must be healed back to
    // localhost (the secret-based auth is only safe on 127.0.0.1).
    const input =
        \\[wallet]
        \\api_listen_interface = "0.0.0.0"
        \\owner_api_listen_port = 9999
        \\
    ;
    const keys = [_]Epic.ManagedKey{
        .{ .section = "wallet", .key = "api_listen_interface", .value = "\"127.0.0.1\"" },
        .{ .section = "wallet", .key = "owner_api_listen_port", .value = Epic.wallet_rpc_port },
    };
    const out = try Epic.patchTomlAlloc(a, input, &keys);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "api_listen_interface = \"127.0.0.1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0.0.0.0") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "owner_api_listen_port = 3420") != null);
}

test "launchServerArgv prepares the config + per-session secret and builds owner_api argv" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-epic-wallet-runtime-home";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    const argv = try Epic.launchServerArgv(a, "/opt/bw", home, Epic.wallet_rpc_port, "walletpw9");
    defer {
        for (argv) |s| a.free(s);
        a.free(argv);
    }
    // `epic-wallet --offline_mode -p <pw> -c <top> owner_api`: a wallet that only
    // serves the password handed to it at launch, brought up before the node syncs,
    // pinned to the managed config dir.
    try std.testing.expectEqual(@as(usize, 7), argv.len);
    try std.testing.expect(std.mem.endsWith(u8, argv[0], Epic.wallet_file));
    try std.testing.expectEqualStrings("--offline_mode", argv[1]);
    try std.testing.expectEqualStrings("-p", argv[2]);
    try std.testing.expectEqualStrings("walletpw9", argv[3]);
    try std.testing.expectEqualStrings("-c", argv[4]);
    try std.testing.expectEqualStrings("owner_api", argv[6]);

    // A non-empty per-session secret was written verbatim (no trailing newline), and
    // the config was generated + healed to localhost.
    const top = try Epic.dataDir(a, home);
    defer a.free(top);
    try std.testing.expectEqualStrings(top, argv[5]);
    var dir = try std.Io.Dir.cwd().openDir(io, top, .{});
    defer dir.close(io);

    var sf = try dir.openFile(io, Epic.owner_secret_file, .{});
    defer sf.close(io);
    var sbuf: [64]u8 = undefined;
    const sn = try sf.readPositionalAll(io, &sbuf, 0);
    try std.testing.expect(sn > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, sbuf[0..sn], '\n') == null);

    var cf = try dir.openFile(io, Epic.wallet_conf_file, .{});
    defer cf.close(io);
    var cbuf: [4096]u8 = undefined;
    const cn = try cf.readPositionalAll(io, &cbuf, 0);
    try std.testing.expect(std.mem.indexOf(u8, cbuf[0..cn], "owner_api_listen_port = 3420") != null);
    try std.testing.expect(std.mem.indexOf(u8, cbuf[0..cn], "api_listen_interface = \"127.0.0.1\"") != null);
}

test "scanArgv builds `epic-wallet -t <top> -p <pw> scan` for the recovery scan" {
    const a = std.testing.allocator;
    const argv = try Epic.scanArgv(a, "/opt/bw", "/home/alice", "walletpw9");
    defer {
        for (argv) |s| a.free(s);
        a.free(argv);
    }
    // `epic-wallet -t <top> -p <pw> scan`: a full repair scan pinned to the managed
    // data dir, opened with the wallet password (no `--offline_mode` — it must reach
    // the node to restore outputs).
    try std.testing.expectEqual(@as(usize, 6), argv.len);
    try std.testing.expect(std.mem.endsWith(u8, argv[0], Epic.wallet_file));
    try std.testing.expectEqualStrings("-t", argv[1]);
    const top = try Epic.dataDir(a, "/home/alice");
    defer a.free(top);
    try std.testing.expectEqualStrings(top, argv[2]);
    try std.testing.expectEqualStrings("-p", argv[3]);
    try std.testing.expectEqualStrings("walletpw9", argv[4]);
    try std.testing.expectEqualStrings("scan", argv[5]);
}

test "scanErrLine lifts the last ERROR line (sans timestamp) from scan output" {
    // epic-wallet logs to stdout; the failing ERROR trails an INFO banner.
    const out =
        "2026-06-24 15:55:28.049 INFO log4rs is initialized\n" ++
        "2026-06-24 15:55:28.049 INFO Connecting to the node: http://127.0.0.1:3413 ...\n" ++
        "2026-06-24 15:55:28.050 ERROR Failed to check node sync status: error sending request\n" ++
        "2026-06-24 15:55:28.050 WARN Set --offline_mode to proceed without a synced node\n";
    try std.testing.expectEqualStrings(
        "Failed to check node sync status: error sending request",
        Epic.scanErrLine(out),
    );
    // No ERROR line → empty, so the caller falls back to a generic message.
    try std.testing.expectEqualStrings("", Epic.scanErrLine("INFO all good\nWARN minor\n"));
}

test "parseTxLog maps a retrieve_txs reply newest-first, dropping cancelled entries" {
    const allocator = std.testing.allocator;

    // A decrypted retrieve_txs inner reply (subset): a mined coinbase, a
    // confirmed receive, an unconfirmed send (fee folded into the debit), and a
    // cancelled receive that must be dropped. Amounts are 1e8-base strings.
    const inner =
        \\{"id":1,"jsonrpc":"2.0","result":{"Ok":[true,[
        \\{"id":0,"tx_type":"ConfirmedCoinbase","creation_ts":"2026-01-01T00:00:00.000000000Z","confirmed":true,"amount_credited":"1600000000","amount_debited":"0"},
        \\{"id":1,"tx_type":"TxReceived","creation_ts":"2026-01-02T12:30:00.5Z","confirmed":true,"amount_credited":"250000000","amount_debited":"0"},
        \\{"id":2,"tx_type":"TxReceivedCancelled","creation_ts":"2026-01-03T00:00:00Z","confirmed":false,"amount_credited":"100000000","amount_debited":"0"},
        \\{"id":3,"tx_type":"TxSent","creation_ts":"2026-01-04T08:00:00Z","confirmed":false,"amount_credited":"0","amount_debited":"125000000"}
        \\]]}}
    ;

    const txs = try Epic.parseTxLog(allocator, inner, 32);
    defer allocator.free(txs);

    // Cancelled entry dropped, the rest newest-first.
    try std.testing.expectEqual(@as(usize, 3), txs.len);
    try std.testing.expectEqual(models.TxDirection.sent, txs[0].direction);
    try std.testing.expectApproxEqAbs(@as(f64, 1.25), txs[0].amount, 1e-9);
    try std.testing.expectEqual(@as(i64, 0), txs[0].confirmations); // unconfirmed
    try std.testing.expectEqual(models.TxDirection.received, txs[1].direction);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), txs[1].amount, 1e-9);
    try std.testing.expect(txs[1].confirmations > 0); // settled (boolean → sentinel)
    try std.testing.expectEqual(models.TxDirection.stake, txs[2].direction);
    try std.testing.expectApproxEqAbs(@as(f64, 16.0), txs[2].amount, 1e-9);

    // The cap keeps only the newest rows.
    const capped = try Epic.parseTxLog(allocator, inner, 1);
    defer allocator.free(capped);
    try std.testing.expectEqual(@as(usize, 1), capped.len);
    try std.testing.expectEqual(models.TxDirection.sent, capped[0].direction);
}

test "directionFromTxType maps grin TxLogEntryType names" {
    try std.testing.expectEqual(models.TxDirection.received, Epic.directionFromTxType("TxReceived").?);
    try std.testing.expectEqual(models.TxDirection.sent, Epic.directionFromTxType("TxSent").?);
    // A coinbase the wallet mined itself.
    try std.testing.expectEqual(models.TxDirection.stake, Epic.directionFromTxType("ConfirmedCoinbase").?);
    // Cancelled entries have no direction — dropped.
    try std.testing.expect(Epic.directionFromTxType("TxReceivedCancelled") == null);
    try std.testing.expect(Epic.directionFromTxType("TxSentCancelled") == null);
    try std.testing.expect(Epic.directionFromTxType("something-unknown") == null);
}

test "parseRfc3339 converts the wallet's creation_ts to unix seconds" {
    // Epoch and a known round-trip (2026-01-02T12:30:00Z = 1767357000).
    try std.testing.expectEqual(@as(?i64, 0), Epic.parseRfc3339("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(?i64, 1767357000), Epic.parseRfc3339("2026-01-02T12:30:00.987654321Z"));
    // Leap-day handling (2024-02-29T00:00:00Z = 1709164800).
    try std.testing.expectEqual(@as(?i64, 1709164800), Epic.parseRfc3339("2024-02-29T00:00:00Z"));
    // Malformed inputs read as null (the row shows no date rather than garbage).
    try std.testing.expect(Epic.parseRfc3339("") == null);
    try std.testing.expect(Epic.parseRfc3339("2026-13-01T00:00:00Z") == null);
    try std.testing.expect(Epic.parseRfc3339("garbage-not-a-date!!") == null);
}

test "coin vtable exposes transactions but no send/receive for Epic (interactive MimbleWimble)" {
    var e: Epic = .{};
    const c = e.coin();
    try std.testing.expect(c.supportsTransactions());
    // Slate-exchange transactions can't be a fire-and-forget RPC, and there is
    // no on-chain receive address — both tabs keep their placeholder.
    try std.testing.expect(!c.supportsSend());
    try std.testing.expect(!c.supportsReceiveAddress());
}
