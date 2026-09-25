const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const install_mod = @import("../install.zig");
const rpc = @import("../rpc.zig");
const money = @import("../money.zig");
const conf = @import("../conf.zig");
const bip39 = @import("../bip39.zig");
const warmup = @import("../warmup.zig");
const ttypass = @import("../ttypass.zig");
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

    // --- Node source: our daemon, or someone else's node -----------------
    //
    // Epic's wallet is a separate process that reaches a node over HTTP, and it
    // does not care whose node that is: `check_node_api_http_addr` in
    // `epic-wallet.toml` is the whole of the coupling. So the user gets the
    // choice — download and validate the chain here, or point the wallet at a
    // node that already has it.
    //
    // The choice is stored in **BoxWallet's own** `boxwallet.conf` under the
    // install root, not in `~/.epic/main`: that directory is the node's, shared
    // with whatever else the machine runs, and BoxWallet deliberately writes
    // nothing there a plain node wouldn't.
    //
    // What a remote node costs is not hidden from the user — see
    // `Coin.remote_node_caution`, which both front-ends show beside the choice.
    // It lives on the capability rather than here because it is a fact about
    // using someone else's node, not a fact about Epic.

    /// BoxWallet's own setting key. Empty/absent = our managed daemon.
    pub const node_setting_key = "epic_node";

    /// The port a bare host falls back to — the same one the node serves its APIs
    /// on locally, so `my-node.example` and `http://my-node.example:3413` mean the
    /// same thing and the user needn't know the number.
    const node_default_port = rpc_default_port;

    /// The node suggested when someone picks "a node someone else runs" without
    /// one in mind: Epic's own community node. It **prefills the field** and
    /// nothing more — Epic still starts out on its own daemon, and the user
    /// confirms this address (or replaces it) before a single query leaves the
    /// machine. Making it the out-of-the-box destination instead would be
    /// choosing, on the user's behalf, who gets to watch their wallet.
    ///
    /// Spelled out in full rather than as a bare host, because **both** halves
    /// are load-bearing and neither is what `normalizeNodeUrl` would assume:
    ///
    ///   * `node.epiccash.com`, not `epiccash.com` — the apex is the website and
    ///     has 3413 closed. A bare-host default pointed at it connects to
    ///     nothing.
    ///   * `https`, not the `http` a bare host defaults to — this node sits
    ///     behind nginx, which answers a plain HTTP request on 3413 with
    ///     `400 The plain HTTP request was sent to HTTPS port`.
    ///
    /// Verified against the live node: `get_tip` over HTTPS returns a height.
    /// The default stays explicit so neither assumption has to hold for it.
    pub const default_remote_node = "https://node.epiccash.com:3413";

    /// Shown under the node address field. Both halves are real shapes: a
    /// public node over https, and one on your own network by bare IP, which
    /// `normalizeNodeUrl` fills out to `http://…:3413`.
    pub const node_address_example = "e.g. https://node.epiccash.com:3413, or 192.168.1.20 for a node on your own network (port 3413 is assumed)";

    /// The node source for this session, cached so the poll workers — which are
    /// handed a `CoinAuth` and no install root — can ask without touching disk
    /// every couple of seconds. Mirrors `OwnerSecret`'s shape.
    ///
    /// Primed by `refreshNodeSource`, which the front-ends call through
    /// `Coin.node_source` (the TUI from its poll worker, the GUI from the C ABI).
    /// Until something has primed it the answer is "our own daemon" — the
    /// conservative default: BoxWallet talks to localhost, which is either right
    /// or simply unreachable, and never silently ships a wallet's queries to a
    /// stranger.
    const NodeSource = struct {
        var mutex: std.atomic.Mutex = .unlocked;
        var buf: [Coin.node_url_max]u8 = undefined;
        var len: usize = 0;

        fn lock() void {
            while (!mutex.tryLock()) std.atomic.spinLoopHint();
        }

        fn set(url: []const u8) void {
            lock();
            defer mutex.unlock();
            const n = @min(url.len, buf.len);
            @memcpy(buf[0..n], url[0..n]);
            len = n;
        }

        /// Copy the cached URL into `out`, returning its length — 0 for our own
        /// daemon. `out` shorter than the stored URL also reads as 0 rather than
        /// handing back a truncated host to connect to.
        fn get(out: []u8) usize {
            lock();
            defer mutex.unlock();
            if (len == 0 or len > out.len) return 0;
            @memcpy(out[0..len], buf[0..len]);
            return len;
        }
    };

    /// Normalize a user-supplied node address into the base URL epic-wallet takes,
    /// written into `out`. Pure, so the whole grammar is unit-testable.
    ///
    /// Accepts `host`, `host:port`, or either with an `http://`/`https://` scheme,
    /// and fills in the scheme (`http://`) and port (`3413`) when they're left off.
    /// Rejects anything with a path, query or fragment, an empty host, a port
    /// that isn't a number, whitespace or control bytes, and anything that won't
    /// fit `out` — a URL this code can't state exactly is one it won't connect to.
    ///
    /// The scheme is *not* upgraded to https on the caller's behalf: Epic node
    /// APIs are plain HTTP unless someone has put a proxy in front, and silently
    /// rewriting it would fail every ordinary node with a confusing error.
    pub fn normalizeNodeUrl(raw: []const u8, out: []u8) ![]const u8 {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidNodeUrl;
        for (trimmed) |c| {
            if (c <= ' ' or c == 0x7f) return error.InvalidNodeUrl;
        }

        // Split off the scheme, defaulting to http.
        var rest = trimmed;
        var scheme: []const u8 = "http://";
        if (std.ascii.startsWithIgnoreCase(trimmed, "http://")) {
            scheme = "http://";
            rest = trimmed["http://".len..];
        } else if (std.ascii.startsWithIgnoreCase(trimmed, "https://")) {
            scheme = "https://";
            rest = trimmed["https://".len..];
        } else if (std.mem.indexOf(u8, trimmed, "://") != null) {
            return error.InvalidNodeUrl; // some other protocol entirely
        }

        // A single trailing slash is a courtesy; anything more is a path we'd be
        // guessing at, and the API endpoint is appended by `foreignCall`.
        if (rest.len > 0 and rest[rest.len - 1] == '/') rest = rest[0 .. rest.len - 1];
        if (std.mem.indexOfAny(u8, rest, "/?#") != null) return error.InvalidNodeUrl;
        if (rest.len == 0) return error.InvalidNodeUrl;

        // Host and optional port. A bracketed IPv6 literal keeps its brackets and
        // only the colon *after* them counts as the port separator.
        var host = rest;
        var port: []const u8 = node_default_port;
        if (rest[0] == '[') {
            const close = std.mem.indexOfScalar(u8, rest, ']') orelse return error.InvalidNodeUrl;
            host = rest[0 .. close + 1];
            const after = rest[close + 1 ..];
            if (after.len > 0) {
                if (after[0] != ':') return error.InvalidNodeUrl;
                port = after[1..];
            }
        } else if (std.mem.lastIndexOfScalar(u8, rest, ':')) |i| {
            host = rest[0..i];
            port = rest[i + 1 ..];
        }
        if (host.len == 0 or std.mem.eql(u8, host, "[]")) return error.InvalidNodeUrl;
        if (port.len == 0) return error.InvalidNodeUrl;
        for (port) |c| {
            if (!std.ascii.isDigit(c)) return error.InvalidNodeUrl;
        }
        _ = std.fmt.parseInt(u16, port, 10) catch return error.InvalidNodeUrl;

        return std.fmt.bufPrint(out, "{s}{s}:{s}", .{ scheme, host, port }) catch
            error.InvalidNodeUrl;
    }

    /// Read the stored node source from `boxwallet.conf` into `out`, refresh the
    /// session cache, and return it — empty for our own daemon.
    ///
    /// A stored value that no longer normalizes (hand-edited, or truncated) reads
    /// as **local** rather than as an error: the fallback is the node BoxWallet
    /// controls, which is the safe end of a setting it can't make sense of.
    pub fn refreshNodeSource(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        out: []u8,
    ) []const u8 {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();

        const stored = conf.readValue(
            allocator,
            threaded.io(),
            install_root,
            conf.settings_file,
            node_setting_key,
        ) catch null;
        defer if (stored) |v| allocator.free(v);

        const url = if (stored) |v| normalizeNodeUrl(v, out) catch "" else "";
        NodeSource.set(url);
        return url;
    }

    /// Persist the node source. An empty `url` restores our managed daemon;
    /// anything else must normalize (`error.InvalidNodeUrl` if it doesn't) and is
    /// stored in its normalized form, so what the Settings tab reads back is
    /// exactly what the wallet will be pointed at.
    ///
    /// The wallet config is re-pointed here rather than at the next launch: the
    /// running `epic-wallet` reads it at start-up, so the caller restarts the
    /// wallet process for the change to take effect — but the file must already
    /// be right when it does.
    pub fn setNodeSource(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home: []const u8,
        url: []const u8,
    ) !void {
        var buf: [Coin.node_url_max]u8 = undefined;
        const value = if (std.mem.trim(u8, url, " \t\r\n").len == 0)
            ""
        else
            try normalizeNodeUrl(url, &buf);

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        try conf.setValue(allocator, io, install_root, conf.settings_file, node_setting_key, value);
        NodeSource.set(value);

        // Point the wallet at the newly-chosen node now, so a wallet process
        // started later this session picks it up. Best-effort: the wallet config
        // is also healed on every launch (`ensureWalletConfig`), which is the
        // path that matters if this one can't run.
        ensureWalletConfig(allocator, io, home) catch {};
    }

    /// The node this coin is currently pointed at, from the session cache —
    /// empty for our own daemon. Allocation-free, so the poll path can ask it.
    fn nodeUrl(out: []u8) []const u8 {
        return out[0..NodeSource.get(out)];
    }

    /// Whether BoxWallet runs the node for this coin. The daemon lifecycle — the
    /// launch, the Start/Stop affordance, the warm-up narration, the conf we
    /// manage — hangs off this being true.
    pub fn usesLocalDaemon() bool {
        var buf: [Coin.node_url_max]u8 = undefined;
        return nodeUrl(&buf).len == 0;
    }

    // --- Epicbox server (the payment relay) --------------------------------
    //
    // Payments travel between wallets through an Epicbox server: the sender
    // posts a slate to the receiver's mailbox there, the receiver's listener
    // picks it up, signs it and posts it back. Epic's own public server is the
    // default; anyone can run one. Which one this wallet uses lives in
    // `epic-wallet.toml` `[epicbox]` (`epicbox_domain` / `epicbox_port`), and it
    // is also the `@domain` half of the wallet's Epicbox address — so changing
    // it changes the address payers must use.
    //
    // A chosen server is stored in `boxwallet.conf` (like the node) and written
    // into the wallet config on every launch, because a create or restore
    // regenerates that config from epic-wallet's defaults. With **no** choice
    // stored, BoxWallet leaves `[epicbox]` alone: that config sits in the shared
    // `~/.epic/main`, and a server someone set there by hand is theirs. Picking
    // the standard server in Settings is the one time BoxWallet writes the
    // default back — because the user just asked for exactly that.
    //
    // Only secure (`wss`) servers: `epicbox_protocol_unsecure` would carry
    // payment slates in the clear, and is always written false.

    /// BoxWallet's own setting key. Empty/absent = leave the wallet config's
    /// `[epicbox]` as it is (epic-wallet's default: Epic's server).
    pub const relay_setting_key = "epic_epicbox";
    /// Epic's public Epicbox server — epic-wallet's own default.
    pub const default_relay_host = "epicbox.epiccash.com";
    const relay_default_port: u16 = 443;
    const relay_max = Coin.relay_max;

    /// Shown under the server field so nobody has to guess the shape.
    pub const relay_example = "e.g. epicbox.epiccash.com, or relay.example.com:8443 (port 443 is assumed; https:// is fine)";
    /// What changing the server means, shown beside that choice.
    pub const relay_note =
        "Payments to you are collected from this server, so your Epicbox address " ++
        "changes to end in its name — give payers the new one. Whoever runs it can " ++
        "see when payments arrive for you and hold them back, but can't take them.";

    /// Normalize a user-supplied Epicbox server into `host` (port 443) or
    /// `host:port`, written into `out`. Pure.
    ///
    /// Accepts an optional `wss://` or `https://` — people paste a web link far
    /// more often than a websocket one, and both mean the secure connection
    /// Epicbox always uses. `ws://` and `http://` are refused with
    /// `error.InsecureRelayAddress` (see above), so the user is told *why*;
    /// any other scheme is `error.InvalidRelayAddress`. The host is letters,
    /// digits and dots only — the grammar
    /// epic-wallet's own address regex allows after the `@`, so a server
    /// outside it would hand out an address no Epic wallet can send to. The
    /// port must be a non-zero number. Lower-cased, since DNS is.
    pub fn normalizeRelay(raw: []const u8, out: []u8) ![]const u8 {
        var rest = std.mem.trim(u8, raw, " \t\r\n");
        if (std.ascii.startsWithIgnoreCase(rest, "wss://")) {
            rest = rest["wss://".len..];
        } else if (std.ascii.startsWithIgnoreCase(rest, "https://")) {
            rest = rest["https://".len..];
        } else if (std.ascii.startsWithIgnoreCase(rest, "ws://") or std.ascii.startsWithIgnoreCase(rest, "http://")) {
            return error.InsecureRelayAddress;
        }
        if (std.mem.indexOf(u8, rest, "://") != null) return error.InvalidRelayAddress;
        if (rest.len > 0 and rest[rest.len - 1] == '/') rest = rest[0 .. rest.len - 1];

        var host = rest;
        var port: u16 = relay_default_port;
        if (std.mem.lastIndexOfScalar(u8, rest, ':')) |i| {
            host = rest[0..i];
            port = std.fmt.parseInt(u16, rest[i + 1 ..], 10) catch return error.InvalidRelayAddress;
            if (port == 0) return error.InvalidRelayAddress;
        }
        if (host.len == 0 or host[0] == '.' or host[host.len - 1] == '.') return error.InvalidRelayAddress;
        for (host) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '.') return error.InvalidRelayAddress;
        }

        var lower: [relay_max]u8 = undefined;
        if (host.len > lower.len) return error.InvalidRelayAddress;
        const h = std.ascii.lowerString(&lower, host);
        return (if (port == relay_default_port)
            std.fmt.bufPrint(out, "{s}", .{h})
        else
            std.fmt.bufPrint(out, "{s}:{d}", .{ h, port })) catch error.InvalidRelayAddress;
    }

    /// Split a normalized server into the `[epicbox]` values. Pure.
    fn relayParts(norm: []const u8) struct { host: []const u8, port: u16 } {
        if (std.mem.lastIndexOfScalar(u8, norm, ':')) |i| {
            return .{ .host = norm[0..i], .port = std.fmt.parseInt(u16, norm[i + 1 ..], 10) catch relay_default_port };
        }
        return .{ .host = norm, .port = relay_default_port };
    }

    /// The server a wallet config's `[epicbox]` names, normalized into `out`,
    /// or "" when it names none (or one we can't state exactly) — epic-wallet
    /// then uses its default. Only live lines inside `[epicbox]` count. Pure.
    fn relayFromToml(input: []const u8, out: []u8) []const u8 {
        var section: []const u8 = "";
        var domain: []const u8 = "";
        var port: []const u8 = "";
        var lines = std.mem.splitScalar(u8, input, '\n');
        while (lines.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len >= 2 and t[0] == '[' and t[t.len - 1] == ']') {
                section = t[1 .. t.len - 1];
                continue;
            }
            if (t.len == 0 or t[0] == '#' or !std.mem.eql(u8, section, "epicbox")) continue;
            const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
            const key = std.mem.trim(u8, t[0..eq], " \t");
            const val = std.mem.trim(u8, t[eq + 1 ..], " \t\"");
            if (std.mem.eql(u8, key, "epicbox_domain")) domain = val;
            if (std.mem.eql(u8, key, "epicbox_port")) port = val;
        }
        if (domain.len == 0) return "";
        var joined: [relay_max + 8]u8 = undefined;
        const raw = (if (port.len > 0)
            std.fmt.bufPrint(&joined, "{s}:{s}", .{ domain, port })
        else
            std.fmt.bufPrint(&joined, "{s}", .{domain})) catch return "";
        return normalizeRelay(raw, out) catch "";
    }

    /// The server BoxWallet has been told to use, normalized into `out`, or ""
    /// for none stored (or one that no longer normalizes — then the wallet
    /// config is left alone rather than rewritten with a guess).
    fn storedRelay(allocator: std.mem.Allocator, io: std.Io, install_root: []const u8, out: []u8) []const u8 {
        const v = conf.readValue(allocator, io, install_root, conf.settings_file, relay_setting_key) catch return "";
        const stored = v orelse return "";
        defer allocator.free(stored);
        if (std.mem.trim(u8, stored, " \t").len == 0) return "";
        return normalizeRelay(stored, out) catch "";
    }

    /// The Epicbox server this wallet actually uses, for Settings — normalized
    /// into `out`, or "" for Epic's standard one. BoxWallet's stored choice if
    /// there is one (it's written into the wallet config at launch), else what
    /// the wallet config itself says, so a server set there by hand is shown
    /// rather than papered over as "standard".
    pub fn relaySource(allocator: std.mem.Allocator, install_root: []const u8, home: []const u8, out: []u8) []const u8 {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const stored = storedRelay(allocator, io, install_root, out);
        const found = if (stored.len > 0) stored else blk: {
            const top = dataDir(allocator, home) catch break :blk "";
            defer allocator.free(top);
            var dir = std.Io.Dir.cwd().openDir(io, top, .{}) catch break :blk "";
            defer dir.close(io);
            var buf: [16 * 1024]u8 = undefined;
            const input = dir.readFile(io, wallet_conf_file, &buf) catch break :blk "";
            break :blk relayFromToml(input, out);
        };
        return if (std.mem.eql(u8, found, default_relay_host)) "" else found;
    }

    /// Choose the Epicbox server. Empty `value` means Epic's standard server:
    /// the stored choice is cleared and `[epicbox]` written back to the
    /// default now, since that's what was asked for. Anything else must
    /// normalize (`error.InvalidRelayAddress`, or `error.InsecureRelayAddress`
    /// for a plain-text one) and is stored, then written into
    /// the wallet config — and again on every launch. The wallet process reads
    /// its config at start-up, so the caller restarts it for this to apply.
    pub fn setRelaySource(allocator: std.mem.Allocator, install_root: []const u8, home: []const u8, value: []const u8) !void {
        var buf: [relay_max]u8 = undefined;
        const norm = if (std.mem.trim(u8, value, " \t\r\n").len == 0) "" else try normalizeRelay(value, &buf);

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        try conf.setValue(allocator, io, install_root, conf.settings_file, relay_setting_key, norm);

        // Custom: `ensureWalletConfig` reads the stored value back and writes it.
        // Standard: this is the one write of the default.
        const top = try dataDir(allocator, home);
        defer allocator.free(top);
        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, top, .{});
        defer dir.close(io);
        if (norm.len == 0) {
            if (dir.access(io, wallet_conf_file, .{})) |_| {
                try patchRelayKeys(allocator, io, dir, default_relay_host);
            } else |_| {}
        } else {
            try ensureWalletConfig(allocator, io, home);
        }
    }

    /// Write `relay` (normalized) into the wallet config's `[epicbox]`,
    /// secure-only. Rewrites the file only if something changed.
    fn patchRelayKeys(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, relay: []const u8) !void {
        const parts = relayParts(relay);
        const domain_val = try std.fmt.allocPrint(allocator, "\"{s}\"", .{parts.host});
        defer allocator.free(domain_val);
        const port_val = try std.fmt.allocPrint(allocator, "{d}", .{parts.port});
        defer allocator.free(port_val);
        const keys = [_]ManagedKey{
            .{ .section = "epicbox", .key = "epicbox_domain", .value = domain_val },
            .{ .section = "epicbox", .key = "epicbox_port", .value = port_val },
            .{ .section = "epicbox", .key = "epicbox_protocol_unsecure", .value = "false" },
        };
        try patchWalletFileKeys(allocator, io, dir, &keys);
    }

    // --- Foreign API (a node we don't run) --------------------------------
    //
    // The Owner API `get_status` the local path uses is, by design, not exposed
    // by a node run for other people: it is the *operator's* view (peers, sync
    // phase, shutdown). What a public node serves is the Foreign API, and the
    // only thing there that describes the chain is `get_tip` — a height. So that
    // is all the remote path claims, and `status.zig` has a branch that says so
    // rather than padding the missing figures with zeros.

    /// A Foreign-API `get_tip` reply. Same Grin `{"Ok": …}` nesting as the Owner
    /// API's; every field but the height is ignored (`total_difficulty` doesn't
    /// fit an i64 on every chain, and nothing here needs it).
    const TipEnvelope = struct {
        result: ?TipResult = null,
    };
    const TipResult = struct {
        Ok: ?Tip = null,
    };

    /// How long a remote node gets to accept a TCP connection before it counts
    /// as unreachable. Generous for an internet round trip and short enough that
    /// a poll tick can't wedge: the kernel's own SYN timeout is around two
    /// minutes, and a status worker stuck in one stops the UI dead and hangs the
    /// app's shutdown behind it.
    const node_connect_timeout_ms: u32 = 4000;

    /// Split a normalized base URL (`scheme://host:port`) into its host and
    /// port for the reachability probe. Pure; only ever fed `normalizeNodeUrl`
    /// output, so the shape is guaranteed — but it refuses anything else rather
    /// than guessing.
    fn splitHostPort(base_url: []const u8) !struct { host: []const u8, port: u16 } {
        const sep = std.mem.indexOf(u8, base_url, "://") orelse return error.InvalidNodeUrl;
        const rest = base_url[sep + 3 ..];
        const colon = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return error.InvalidNodeUrl;
        const host = rest[0..colon];
        if (host.len == 0) return error.InvalidNodeUrl;
        return .{
            .host = host,
            .port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch return error.InvalidNodeUrl,
        };
    }

    /// POST `get_tip` at a node's Foreign API and return its height.
    ///
    /// Unauthenticated: a node published for other people's wallets doesn't gate
    /// its Foreign API, and we have no secret for one that does — a 401 is
    /// surfaced as `error.AuthFailed` so the user is told that, rather than the
    /// node simply appearing dead.
    fn foreignTip(allocator: std.mem.Allocator, base_url: []const u8) !i64 {
        // Bounded connect first, because the fetch below has none. A node on the
        // internet can answer a connection with silence rather than a refusal,
        // and `std.http.Client` would then sit in the kernel's ~2-minute SYN
        // retry — long enough that the status worker never returns a frame (so
        // the UI shows nothing happening) and the app's shutdown, which joins
        // that worker, hangs behind it. Ask a question with a deadline first.
        const ep = try splitHostPort(base_url);
        if (!rpc.endpointReachable(allocator, ep.host, ep.port, node_connect_timeout_ms))
            return error.NodeUnreachable;

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();

        var client: std.http.Client = .{ .allocator = allocator, .io = threaded.io() };
        defer client.deinit();

        const url = try std.fmt.allocPrint(allocator, "{s}/v2/foreign", .{base_url});
        defer allocator.free(url);

        var body: std.Io.Writer.Allocating = .init(allocator);
        defer body.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"get_tip\",\"params\":[]}",
            .response_writer = &body.writer,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
        if (result.status == .unauthorized) return error.AuthFailed;
        if (result.status != .ok) return error.DaemonNotReady;

        return parseTipHeight(allocator, body.written());
    }

    /// Pull the height out of a `get_tip` body. Split from the transport so the
    /// parse is unit-testable against a recorded reply.
    fn parseTipHeight(allocator: std.mem.Allocator, raw: []const u8) !i64 {
        var parsed = try std.json.parseFromSlice(TipEnvelope, allocator, raw, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const tip = (parsed.value.result orelse return error.DaemonNotReady).Ok orelse
            return error.DaemonNotReady;
        if (tip.height <= 0) return error.DaemonNotReady;
        return tip.height;
    }

    /// The remote node's chain, as much of it as the Foreign API will say.
    ///
    /// `blocks`/`headers`/`network_height` are all the one height it reports:
    /// there is no local chain being caught up, so the wallet's view of the tip
    /// *is* the tip, and the sync bars have nothing to fill toward. `synced` is
    /// true on that basis — it means "no download of ours is outstanding", which
    /// is the truth — and the status line reads "Using a remote node" rather than
    /// "Synced" so the word is never taken for a claim about the remote itself.
    ///
    /// `tip_time`/`seconds_behind` are deliberately left at their "unavailable"
    /// values: `get_tip` carries no timestamp, and inventing one from a block
    /// target would put a made-up figure where the UI shows a fact.
    fn remoteBlockchainState(
        allocator: std.mem.Allocator,
        base_url: []const u8,
    ) !models.BlockchainState {
        const height = try foreignTip(allocator, base_url);
        return .{
            .chain = try allocator.dupe(u8, "mainnet"),
            .blocks = height,
            .headers = height,
            .verification_progress = 1,
            .synced = true,
            .network_height = height,
        };
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
    ///
    /// Pointed at someone else's node there is no Owner API to ask, and the
    /// Foreign API reports a height and nothing else — see
    /// `remoteBlockchainState`, which says only that.
    pub fn blockchainState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.BlockchainState {
        var url_buf: [Coin.node_url_max]u8 = undefined;
        const remote = nodeUrl(&url_buf);
        if (remote.len != 0) return remoteBlockchainState(allocator, remote);

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
    ///
    /// Pointed at someone else's node, only the height is knowable: peer count
    /// and the running version are the operator's view, which the Foreign API
    /// doesn't serve. Both are left at their "unknown" values (0 and empty)
    /// rather than guessed, and `status.zig`'s remote branch keeps the front-ends
    /// from narrating the zero as "waiting for peers".
    pub fn daemonInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.DaemonInfo {
        var url_buf: [Coin.node_url_max]u8 = undefined;
        const remote = nodeUrl(&url_buf);
        if (remote.len != 0) return .{
            .blocks = try foreignTip(allocator, remote),
            .connections = 0,
            .staking_active = false,
            .version = try allocator.dupe(u8, ""),
        };

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
        // Nothing of ours to configure when the node belongs to someone else:
        // `epic-server.toml` and `.api_secret` describe a daemon BoxWallet runs,
        // and writing either into the shared `~/.epic/main` for a node that will
        // never start would be leaving settings behind for somebody else's.
        // (The *wallet* config still gets pointed at the remote — that happens on
        // the wallet's own launch path, `ensureWalletConfig`.)
        var url_buf: [Coin.node_url_max]u8 = undefined;
        _ = refreshNodeSource(allocator, install_root, &url_buf);
        if (!usesLocalDaemon()) return;

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
        return apiPost(allocator, io, auth, "/v3/owner", body);
    }

    /// POST at `path` on the wallet process's API port — the Owner API, or the
    /// Foreign API it also serves (`--run_foreign`, see `launchServerArgv`), which
    /// takes the same basic auth. Caller frees the response body.
    fn apiPost(allocator: std.mem.Allocator, io: std.Io, auth: models.CoinAuth, path: []const u8, body: []const u8) ![]u8 {
        var client: std.http.Client = .{ .allocator = allocator, .io = io };
        defer client.deinit();

        const url = try std.fmt.allocPrint(allocator, "http://{s}:{s}{s}", .{ auth.ip_address, auth.port, path });
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
    /// Owner API on 3420, the chosen node as the sync target, and the secret
    /// paths wired to the files BoxWallet manages. Emits all four sections the
    /// wallet config deserializes — `[wallet]`, `[epicbox]`, `[tor]`, `[logging]` —
    /// so the binary loads it cleanly. Written only when no config is there yet; an
    /// existing (possibly user-edited) config is healed by `patchWalletConf`
    /// instead. Caller owns the slice.
    ///
    /// `node_addr`/`node_secret_path` come from `walletNodeKeys`: our own node
    /// plus its `.foreign_api_secret` (the secret the wallet authenticates to the
    /// node with — distinct from the wallet's own `.owner_api_secret`), or a
    /// remote node and no secret at all.
    fn defaultWalletToml(
        allocator: std.mem.Allocator,
        top_dir: []const u8,
        node_addr: []const u8,
        node_secret_path: []const u8,
    ) ![]u8 {
        return std.fmt.allocPrint(allocator,
            \\[wallet]
            \\chain_type = "Mainnet"
            \\api_listen_interface = "127.0.0.1"
            \\api_listen_port = 3415
            \\owner_api_listen_port = {s}
            \\owner_api_include_foreign = false
            \\api_secret_path = "{s}/{s}"
            \\node_api_secret_path = "{s}"
            \\check_node_api_http_addr = "{s}"
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
        , .{ wallet_rpc_port, top_dir, owner_secret_file, node_secret_path, node_addr, top_dir, top_dir });
    }

    /// Where the wallet should look for a node, and which secret (if any) it
    /// should authenticate with — the two `epic-wallet.toml` keys that differ
    /// between running our own node and using someone else's.
    ///
    /// Our own node: its loopback address, and the `.foreign_api_secret` it
    /// generates on first run. Someone else's: their base URL, and **no** secret
    /// — we have none for a node we don't run, and a node published for other
    /// people's wallets doesn't ask for one. The empty path is how the wallet
    /// spells "no secret": it reads the first line of the named file and treats
    /// one it can't open as absent, which is what an empty path always is.
    ///
    /// Both strings come back already TOML-quoted, ready to be a `ManagedKey`
    /// value, and owned by `allocator` — a home directory can be arbitrarily
    /// deep, and a fixed buffer that overflowed would fail the whole config heal
    /// over a long path.
    const WalletNodeKeys = struct {
        addr: []const u8,
        secret_path: []const u8,

        fn deinit(self: WalletNodeKeys, allocator: std.mem.Allocator) void {
            allocator.free(self.addr);
            allocator.free(self.secret_path);
        }
    };

    fn walletNodeKeys(allocator: std.mem.Allocator, top_dir: []const u8) !WalletNodeKeys {
        // One read of the cache: `remote` and the address it implies have to come
        // from the same answer, or a change landing between two reads could pair a
        // remote address with the local secret.
        var url_buf: [Coin.node_url_max]u8 = undefined;
        const remote = nodeUrl(&url_buf);

        const addr = if (remote.len != 0)
            try std.fmt.allocPrint(allocator, "\"{s}\"", .{remote})
        else
            try std.fmt.allocPrint(allocator, "\"http://127.0.0.1:{s}\"", .{rpc_default_port});
        errdefer allocator.free(addr);

        const secret_path = if (remote.len != 0)
            try allocator.dupe(u8, "\"\"")
        else
            try std.fmt.allocPrint(allocator, "\"{s}/{s}\"", .{ top_dir, node_foreign_secret_file });

        return .{ .addr = addr, .secret_path = secret_path };
    }

    /// Heal the keys BoxWallet manages in `epic-wallet.toml` (localhost Owner API on
    /// the expected port, the chosen node as sync target, the managed secret paths),
    /// rewriting only if something changed. Same section-aware patch the node conf
    /// uses; the values are runtime (they embed absolute paths).
    ///
    /// `check_node_api_http_addr` and `node_api_secret_path` are managed **as a
    /// pair**, and both in both directions: switching to a remote node has to
    /// clear the local secret, and switching back has to put it there again.
    /// Leaving either behind would point the wallet at one node while handing it
    /// the other's credential.
    fn patchWalletConf(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, top_dir: []const u8) !void {
        const secret_path = try std.fmt.allocPrint(allocator, "\"{s}/{s}\"", .{ top_dir, owner_secret_file });
        defer allocator.free(secret_path);
        const data_dir_val = try std.fmt.allocPrint(allocator, "\"{s}/wallet_data\"", .{top_dir});
        defer allocator.free(data_dir_val);

        const node = try walletNodeKeys(allocator, top_dir);
        defer node.deinit(allocator);

        const keys = [_]ManagedKey{
            .{ .section = "wallet", .key = "api_listen_interface", .value = "\"127.0.0.1\"" },
            .{ .section = "wallet", .key = "owner_api_listen_port", .value = wallet_rpc_port },
            .{ .section = "wallet", .key = "check_node_api_http_addr", .value = node.addr },
            .{ .section = "wallet", .key = "node_api_secret_path", .value = node.secret_path },
            .{ .section = "wallet", .key = "api_secret_path", .value = secret_path },
            .{ .section = "wallet", .key = "data_file_dir", .value = data_dir_val },
        };
        try patchWalletFileKeys(allocator, io, dir, &keys);
    }

    /// Set `keys` in `dir`'s `epic-wallet.toml`, rewriting it only if something
    /// changed.
    fn patchWalletFileKeys(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, keys: []const ManagedKey) !void {
        var file = try dir.openFile(io, wallet_conf_file, .{});
        const stat = try file.stat(io);
        const size: usize = @intCast(@min(stat.size, 256 * 1024));
        const input = try allocator.alloc(u8, size);
        defer allocator.free(input);
        const n = try file.readPositionalAll(io, input, 0);
        file.close(io);

        const patched = try patchTomlAlloc(allocator, input[0..n], keys);
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
            // Unquoted here: the template puts its own quotes around each value.
            const node = try walletNodeKeys(allocator, top);
            defer node.deinit(allocator);
            const tmpl = try defaultWalletToml(
                allocator,
                top,
                std.mem.trim(u8, node.addr, "\""),
                std.mem.trim(u8, node.secret_path, "\""),
            );
            defer allocator.free(tmpl);
            try dir.writeFile(io, .{ .sub_path = wallet_conf_file, .data = tmpl });
        }
        try patchWalletConf(allocator, io, dir, top);

        // A server chosen in Settings, re-applied every time: a create or
        // restore regenerates this file with epic-wallet's default.
        const install_root = try install_mod.installRoot(allocator, home);
        defer allocator.free(install_root);
        var relay_buf: [relay_max]u8 = undefined;
        const relay = storedRelay(allocator, io, install_root, &relay_buf);
        if (relay.len > 0) try patchRelayKeys(allocator, io, dir, relay);
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
    /// subcommand ignores `-t`). The password is typed at the process's `Password:`
    /// prompt on a private terminal (`pass_on_tty`, via `external_wallet
    /// .password_prompt`), never put in argv — where any local user could read it for
    /// the whole unlocked session — nor on disk. Only where that isn't possible
    /// (Windows) does it ride argv as `-p`. Caller owns the returned slice.
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
        cacheEpicboxIndex(allocator, io, top);
        // `--run_foreign` also serves the Foreign API on the same localhost port,
        // behind the same secret: it's how a slate file is signed (`receive_tx`).
        // The flag rather than `owner_api_include_foreign` in the shared config,
        // which another app using `~/.epic/main` would pick up too.
        return walletArgv(allocator, bin, top, wallet_password, &.{ "owner_api", "--run_foreign" });
    }

    /// Whether epic-wallet gets its password on a private terminal (`ttypass`)
    /// rather than as `-p <password>` in argv. Every command BoxWallet runs with a
    /// password — `owner_api`, `listen`, `init -r`, `scan` — goes the same way.
    const pass_on_tty = ttypass.supported;

    /// What epic-wallet prints when it asks for the password on its terminal
    /// ("Password: "; "New Password: " / "Confirm Password: " for `init`).
    const password_prompt = "Password: ";

    /// `<bin> --offline_mode [-p <pw>] -c <top> <tail…>` — the `-p` only where the
    /// password can't go on a terminal (`pass_on_tty`). Takes ownership of `bin`
    /// and `top`. Caller owns the returned slice and every string in it.
    fn walletArgv(
        allocator: std.mem.Allocator,
        bin: []const u8,
        top: []const u8,
        wallet_password: []const u8,
        tail: []const []const u8,
    ) ![]const []const u8 {
        const head = if (pass_on_tty) 4 else 6;
        const argv = try allocator.alloc([]const u8, head + tail.len);
        errdefer allocator.free(argv);
        argv[0] = bin;
        argv[1] = try allocator.dupe(u8, "--offline_mode");
        var i: usize = 2;
        if (!pass_on_tty) {
            argv[2] = try allocator.dupe(u8, "-p");
            argv[3] = try allocator.dupe(u8, wallet_password);
            i = 4;
        }
        argv[i] = try allocator.dupe(u8, "-c");
        argv[i + 1] = top;
        for (tail, 0..) |t, j| argv[head + j] = try allocator.dupe(u8, t);
        return argv;
    }

    /// argv for the Epicbox listener: `epic-wallet --offline_mode -p <pw> -c <top>
    /// listen -m epicbox`, the process that signs incoming payments and finalizes
    /// outgoing ones while the wallet is unlocked. It runs beside `owner_api` on
    /// the same wallet (both hold it open without trouble) and reads the same
    /// managed config, which `launchServerArgv` has just ensured. It connects out
    /// to the relay (wss, port 443), so it binds no port of its own.
    ///
    /// `--offline_mode` for the same reason as the server: without it the listener
    /// exits at once when the node is unreachable or still syncing — which is
    /// every unlock before our own node has caught up. The password reaches it the
    /// way it reaches the server (`pass_on_tty`). Caller owns the returned slice.
    fn listenerArgv(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home: []const u8,
        wallet_password: []const u8,
    ) anyerror![]const []const u8 {
        const bin = try std.fs.path.join(allocator, &.{ install_root, wallet_file });
        errdefer allocator.free(bin);
        const top = try dataDir(allocator, home);
        errdefer allocator.free(top);
        return walletArgv(allocator, bin, top, wallet_password, &.{ "listen", "-m", "epicbox" });
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
    /// pattern). The password is typed twice ("New Password:" / "Confirm
    /// Password:") on a private terminal (`runCli`) — never argv, never disk.
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
        defer stdin_file.close(io);

        // epic-wallet reports a bad phrase on stderr ("Recovery word phrase is
        // invalid."), so capture it to surface a failed restore honestly. stdout is
        // discarded: `init -r` echoes the phrase back on it.
        var errbuf: [512]u8 = undefined;
        const tail: []const []const u8 = if (pass_on_tty) &.{ "init", "-r" } else &.{ "-p", password, "init", "-r" };
        var argv_buf: [8][]const u8 = undefined;
        argv_buf[0] = bin;
        argv_buf[1] = "-t";
        argv_buf[2] = top;
        @memcpy(argv_buf[3..][0..tail.len], tail);
        const run = runCli(allocator, io, dir, argv_buf[0 .. 3 + tail.len], stdin_file, .stderr, password, 2, &errbuf) catch |err| {
            detail.set(@errorName(err));
            return error.WalletRestoreFailed;
        };
        const errlen = run.captured;
        const ok = run.ok;
        // The CLI exits 0 and writes `wallet_data/wallet.seed` on success; a bad
        // phrase, a checksum mismatch, or a pre-existing wallet leaves it absent.
        if (!ok or !walletExists(allocator, home)) {
            const why = std.mem.trim(u8, errbuf[0..errlen], " \t\r\n");
            detail.set(if (why.len > 0) why else "epic-wallet could not initialize the wallet from the recovery phrase");
            return error.WalletRestoreFailed;
        }
    }

    /// argv for a full repair scan: `epic-wallet -t <top> scan`, with `-p <pw>` only
    /// where the password can't be typed on a terminal (`pass_on_tty`). Pulled out
    /// (like `launchServerArgv`/`daemonArgv`) so the command shape is unit-testable
    /// without a wallet. Caller owns the returned slice + strings.
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

        const argv = try allocator.alloc([]const u8, if (pass_on_tty) 4 else 6);
        errdefer allocator.free(argv);
        argv[0] = bin;
        argv[1] = try allocator.dupe(u8, "-t");
        argv[2] = top;
        if (!pass_on_tty) {
            argv[3] = try allocator.dupe(u8, "-p");
            argv[4] = try allocator.dupe(u8, password);
        }
        argv[argv.len - 1] = try allocator.dupe(u8, "scan");
        return argv;
    }

    /// Which stream `runCli` keeps: the one the command reports failure on.
    const CliCapture = enum { stdout, stderr };

    /// How a `runCli` command ended: whether it exited 0, and how many bytes of
    /// the captured stream's tail were copied back.
    const CliRun = struct { ok: bool, captured: usize };

    /// Run one epic-wallet command to completion. The password is typed at its
    /// `Password:` prompt(s) on a private terminal (`ttypass`) where possible — it
    /// is then absent from `argv`; elsewhere `argv` already carries `-p`. The
    /// `capture` stream goes to a scratch file in `dir`, the other to /dev/null,
    /// and the tail of what was captured is copied into `tail` (the file is
    /// deleted before returning). A command that dies before asking is reported
    /// as not ok, with what it printed.
    fn runCli(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        argv: []const []const u8,
        stdin: ?std.Io.File,
        capture: CliCapture,
        password: []const u8,
        prompts: u8,
        tail: []u8,
    ) !CliRun {
        const cap_name = ".boxwallet-cli.out";
        var cap = try dir.createFile(io, cap_name, .{ .read = true, .truncate = true });
        defer {
            cap.close(io);
            dir.deleteFile(io, cap_name) catch {};
        }
        const out: ?std.Io.File = if (capture == .stdout) cap else null;
        const err: ?std.Io.File = if (capture == .stderr) cap else null;

        const ok = if (pass_on_tty) blk: {
            var sp = ttypass.spawn(allocator, .{
                .argv = argv,
                .stdin = stdin,
                .stdout = out,
                .stderr = err,
                .secret = password,
                .prompt = password_prompt,
                .answers = prompts,
                // `scan` checks the node before it asks — without
                // `--offline_mode` that can take a while on a slow one.
                .timeout_ms = 90_000,
            }) catch |e| switch (e) {
                error.ExitedBeforePrompt => break :blk false,
                else => return e,
            };
            defer sp.tty.close();
            const term = try sp.child.wait(io);
            break :blk term == .exited and term.exited == 0;
        } else blk: {
            const as_io = struct {
                fn f(file: ?std.Io.File) std.process.SpawnOptions.StdIo {
                    return if (file) |x| .{ .file = x } else .ignore;
                }
            }.f;
            var child = try std.process.spawn(io, .{
                .argv = argv,
                .stdin = as_io(stdin),
                .stdout = as_io(out),
                .stderr = as_io(err),
                .create_no_window = builtin.os.tag == .windows,
            });
            const term = try child.wait(io);
            break :blk term == .exited and term.exited == 0;
        };

        const size = (cap.stat(io) catch return .{ .ok = ok, .captured = 0 }).size;
        const off = if (size > tail.len) size - tail.len else 0;
        const n = cap.readPositionalAll(io, tail, off) catch 0;
        return .{ .ok = ok, .captured = n };
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
    /// `ERROR …` line trails a multi-line INFO banner, so stdout is captured and only
    /// its **tail** read back, then the last `ERROR` line lifted out of it (see
    /// `scanErrLine`). The password is typed on a private terminal (`runCli`).
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
        const top = try dataDir(allocator, home);
        defer allocator.free(top);
        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, top, .{});
        defer dir.close(io);

        // Only the tail matters: the failing `ERROR` line comes last, after the
        // INFO banner.
        var buf: [1024]u8 = undefined;
        const run = runCli(allocator, io, dir, argv, null, .stdout, password, 1, &buf) catch |err| {
            detail.set(@errorName(err));
            return error.WalletRescanFailed;
        };
        const len = run.captured;
        const ok = run.ok;
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

    // --- Wallet backup: the seed words and the wallet.seed file ------------
    //
    // An Epic wallet's portable file is `wallet_data/wallet.seed`: the wallet's
    // BIP39 entropy encrypted under the wallet password — PBKDF2-HMAC-SHA512
    // (100 rounds, 32-byte key) into ChaCha20-Poly1305, stored as hex JSON
    // (`encrypted_seed` = ciphertext‖tag, `salt`, `nonce`). Grin's scheme,
    // checked against epic-wallet 4.0.0's own output (the fixture in the tests).
    // It restores exactly what the seed words do: the outputs come back from a
    // chain scan; the local transaction log and labels do not. A password
    // change (`change_password`) re-encrypts it, so a backup keeps the password
    // it was taken under.

    /// Upper bound on a wallet.seed we'll read — a real one is ~200 bytes, so
    /// anything bigger isn't one.
    const seed_file_max = 1024;
    const seed_file_name = "wallet.seed";
    const seed_kdf_rounds = 100;
    const SeedAead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

    /// Owner-only on POSIX: the file is encrypted, but its only protection is
    /// then the password's strength, so it shouldn't be readable by other
    /// users. Windows has no mode bits; the profile directory's ACL covers it.
    const private_file_perms: std.Io.File.Permissions =
        if (builtin.os.tag == .windows) .default_file else @enumFromInt(0o600);

    /// Check `bytes` is a wallet.seed and, when `password` is given, that it
    /// decrypts under it — so a file import refuses a wrong file or password
    /// *before* anything is written, rather than leaving an unopenable wallet
    /// behind. `error.NotAWalletSeedFile` / `error.WrongPassword`. Pure.
    fn checkSeedFile(allocator: std.mem.Allocator, bytes: []const u8, password: ?[]const u8) !void {
        var plain: [seed_entropy_max]u8 = undefined;
        defer @memset(&plain, 0);
        _ = try decryptSeedFile(allocator, bytes, password, &plain);
    }

    /// Largest entropy a wallet.seed holds (24 words).
    const seed_entropy_max = 32;

    /// Parse wallet.seed `bytes` and, when `password` is given, decrypt its
    /// entropy into `out` and return it (empty when `password` is null — a shape
    /// check only). The entropy is the wallet's secret: the caller wipes `out`.
    /// `error.NotAWalletSeedFile` / `error.WrongPassword`. Pure.
    fn decryptSeedFile(allocator: std.mem.Allocator, bytes: []const u8, password: ?[]const u8, out: *[seed_entropy_max]u8) ![]const u8 {
        const Raw = struct { encrypted_seed: []const u8 = "", salt: []const u8 = "", nonce: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Raw, allocator, bytes, .{ .ignore_unknown_fields = true }) catch
            return error.NotAWalletSeedFile;
        defer parsed.deinit();

        var salt_buf: [64]u8 = undefined;
        var nonce_buf: [SeedAead.nonce_length]u8 = undefined;
        var ct_buf: [seed_entropy_max + SeedAead.tag_length]u8 = undefined;
        const salt = std.fmt.hexToBytes(&salt_buf, parsed.value.salt) catch return error.NotAWalletSeedFile;
        const nonce = std.fmt.hexToBytes(&nonce_buf, parsed.value.nonce) catch return error.NotAWalletSeedFile;
        const ct = std.fmt.hexToBytes(&ct_buf, parsed.value.encrypted_seed) catch return error.NotAWalletSeedFile;
        // 16 bytes is the smallest BIP39 entropy (12 words).
        if (salt.len == 0 or nonce.len != nonce_buf.len or ct.len < 16 + SeedAead.tag_length)
            return error.NotAWalletSeedFile;

        const pw = password orelse return out[0..0];
        var key: [SeedAead.key_length]u8 = undefined;
        defer @memset(&key, 0);
        std.crypto.pwhash.pbkdf2(&key, pw, salt, seed_kdf_rounds, std.crypto.auth.hmac.sha2.HmacSha512) catch
            return error.NotAWalletSeedFile;
        const body = ct[0 .. ct.len - SeedAead.tag_length];
        const tag = ct[body.len..][0..SeedAead.tag_length].*;
        SeedAead.decrypt(out[0..body.len], body, tag, "", nonce_buf, key) catch {
            @memset(out, 0);
            return error.WrongPassword;
        };
        return out[0..body.len];
    }

    /// Read a wallet.seed-sized file at `path` into `buf`. Anything larger
    /// than `buf` isn't a wallet.seed.
    fn readSeedFile(io: std.Io, path: []const u8, buf: []u8) ![]u8 {
        var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.WalletFileNotFound;
        defer f.close(io);
        const len = f.length(io) catch return error.WalletFileNotFound;
        if (len > buf.len) return error.NotAWalletSeedFile;
        const n = try f.readPositionalAll(io, buf[0..@intCast(len)], 0);
        return buf[0..n];
    }

    /// Show the wallet's recovery phrase again, for "Show recovery seed":
    /// decrypt wallet.seed with the password just typed and spell its entropy
    /// as BIP39 words — what epic-wallet's own `get_mnemonic` does, but without
    /// needing its process, so it works on a locked wallet as well as an open
    /// one. A wrong password fails the decryption: `error.WrongPassword`, with
    /// nothing shown.
    fn epicShowSeed(
        allocator: std.mem.Allocator,
        _: models.CoinAuth,
        home: []const u8,
        password: []const u8,
        detail: *Coin.WalletErrSink,
    ) anyerror!models.Seed {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const dir = try walletDataDir(allocator, home);
        defer allocator.free(dir);
        const path = try std.fs.path.join(allocator, &.{ dir, seed_file_name });
        defer allocator.free(path);

        var buf: [seed_file_max]u8 = undefined;
        defer @memset(&buf, 0);
        const bytes = readSeedFile(io, path, &buf) catch |err| {
            if (err == error.WalletFileNotFound) detail.set("There's no Epic wallet here yet.");
            return err;
        };
        var entropy: [seed_entropy_max]u8 = undefined;
        defer @memset(&entropy, 0);
        const ent = decryptSeedFile(allocator, bytes, password, &entropy) catch |err| {
            if (err == error.NotAWalletSeedFile) detail.set("This wallet's wallet.seed isn't in a format BoxWallet can read.");
            return err;
        };
        var words: [bip39.max_mnemonic_len]u8 = undefined;
        defer @memset(&words, 0);
        return models.Seed.from(try bip39.fromEntropy(ent, &words));
    }

    /// Copy the managed wallet.seed to `dest_path` (a fresh timestamped name
    /// under the install root — see `extwallet.backupFile`). Read-only on the
    /// wallet dir; the backup is created owner-only and never overwrites an
    /// existing file. A copy that `epicRestoreFile` wouldn't accept isn't a
    /// backup, so a wallet.seed in a format we don't recognize is refused
    /// rather than copied.
    fn epicBackupFile(
        allocator: std.mem.Allocator,
        home: []const u8,
        dest_path: []const u8,
        detail: *Coin.WalletErrSink,
    ) anyerror!void {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const dir = try walletDataDir(allocator, home);
        defer allocator.free(dir);
        const src = try std.fs.path.join(allocator, &.{ dir, seed_file_name });
        defer allocator.free(src);

        var buf: [seed_file_max]u8 = undefined;
        defer @memset(&buf, 0);
        const bytes = readSeedFile(io, src, &buf) catch |err| {
            if (err == error.WalletFileNotFound) detail.set("There's no Epic wallet to back up yet.");
            return err;
        };
        checkSeedFile(allocator, bytes, null) catch |err| {
            detail.set("This wallet's wallet.seed isn't in a format BoxWallet can restore, so it wasn't copied.");
            return err;
        };

        var f = try std.Io.Dir.cwd().createFile(io, dest_path, .{ .exclusive = true, .permissions = private_file_perms });
        f.writeStreamingAll(io, bytes) catch |err| {
            // Don't leave a truncated backup that looks like a good one.
            f.close(io);
            std.Io.Dir.cwd().deleteFile(io, dest_path) catch {};
            return err;
        };
        f.close(io);
    }

    /// Import a wallet.seed backup (`src_path`) as the managed wallet. The
    /// password is checked against the file first (`checkSeedFile`), so a wrong
    /// file or password is refused with nothing written. Never adopts over what
    /// is already there: a wallet.seed is someone's wallet, and a wallet
    /// database without one holds another wallet's records. `setupWithPassword`
    /// then launches the wallet on it and opens it; the best-effort scan below
    /// front-loads finding its funds, exactly as the seed restore does.
    fn epicRestoreFile(
        allocator: std.mem.Allocator,
        _: models.CoinAuth,
        home: []const u8,
        src_path: []const u8,
        password: []const u8,
        detail: *Coin.WalletErrSink,
    ) anyerror!void {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var buf: [seed_file_max]u8 = undefined;
        defer @memset(&buf, 0);
        const bytes = readSeedFile(io, src_path, &buf) catch |err| {
            detail.set(if (err == error.NotAWalletSeedFile)
                "That isn't an Epic wallet file. Choose a wallet.seed, or a BoxWallet .seed backup."
            else
                "Couldn't read that file.");
            return err;
        };
        checkSeedFile(allocator, bytes, password) catch |err| {
            if (err == error.NotAWalletSeedFile)
                detail.set("That isn't an Epic wallet file. Choose a wallet.seed, or a BoxWallet .seed backup.");
            return err;
        };

        const dir_path = try walletDataDir(allocator, home);
        defer allocator.free(dir_path);
        if (install_mod.fileExists(allocator, dir_path, seed_file_name)) return error.WalletAlreadyExists;
        if (install_mod.fileExists(allocator, dir_path, "db")) {
            detail.set("Epic's wallet_data folder already holds a wallet database. Move it aside first, so its records aren't mixed into this wallet.");
            return error.WalletDataInUse;
        }

        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
        defer dir.close(io);
        var f = dir.createFile(io, seed_file_name, .{ .exclusive = true, .permissions = private_file_perms }) catch |err| switch (err) {
            error.PathAlreadyExists => return error.WalletAlreadyExists,
            else => return err,
        };
        f.writeStreamingAll(io, bytes) catch |err| {
            // Ours, and unusable half-written — remove it so the menu doesn't
            // then offer to unlock a wallet that can't open.
            f.close(io);
            dir.deleteFile(io, seed_file_name) catch {};
            return err;
        };
        f.close(io);

        // Best-effort, as in `epicRestore`: a node still syncing refuses the
        // scan, and the balance refresh recovers the outputs once it catches up.
        const install_root = try install_mod.installRoot(allocator, home);
        defer allocator.free(install_root);
        ensureWalletConfig(allocator, io, home) catch {};
        runScan(allocator, io, install_root, home, password, detail) catch detail.set("");
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

        // The same confirmation count a send requires, so "available" is what a
        // send will actually spend.
        const params = try std.fmt.allocPrint(
            allocator,
            "{{\"token\":\"{s}\",\"refresh_from_node\":true,\"minimum_confirmations\":{d}}}",
            .{ token_buf[0..tn], min_confirmations },
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

    // --- Receive address (Owner API `get_public_address`) -----------------
    //
    // MimbleWimble has no on-chain addresses; what a sender needs instead is the
    // wallet's **Epicbox address**, `<pubkey>@<relay domain>`: the relay mailbox
    // they post their slate to, for this wallet to pick up, sign and send back.
    // The key is derived from the seed at `[epicbox] epicbox_address_index`, so
    // it's fixed per wallet — there is no "new address" to mint, and `force_new`
    // returns the same one (as with Zano's single address). The front-ends don't
    // offer one (`receive_address_fixed_note`): changing the index would move the
    // listener off the address people already have, stranding their payments at
    // the relay until it listens there again.
    //
    // A payment only completes while an Epicbox listener runs for this wallet.
    // Until one does, the relay holds the slate (seen delivered after minutes
    // offline) and the sender's coins stay locked — not lost.

    /// The `epicbox_address_index` the wallet was launched with, read from
    /// `epic-wallet.toml` by `launchServerArgv` — the only wallet hook that knows
    /// the home dir. The listener derives its address from the same key, so
    /// asking for index 0 regardless would show a user who changed it an address
    /// nobody is listening on.
    var epicbox_index: std.atomic.Value(u32) = .init(0);

    /// The longest address this coin hands back. Both front-ends cache it in a
    /// fixed buffer (the TUI's is 128 bytes and truncates to fit) and an address
    /// cut short is someone else's address, so a longer one is refused instead.
    const epicbox_address_max = 128;

    /// `[epicbox] epicbox_address_index` from a wallet config, or 0 — epic-wallet's
    /// own default — when it's absent or unreadable. Only a live `key = value`
    /// line inside `[epicbox]` counts: a commented-out one, or the same key in
    /// another section, isn't what the wallet will use.
    fn epicboxIndexFromToml(input: []const u8) u32 {
        var section: []const u8 = "";
        var lines = std.mem.splitScalar(u8, input, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                section = trimmed[1 .. trimmed.len - 1];
                continue;
            }
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            if (!std.mem.eql(u8, section, "epicbox")) continue;
            const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            if (!std.mem.eql(u8, std.mem.trim(u8, trimmed[0..eq], " \t"), "epicbox_address_index")) continue;
            var value = trimmed[eq + 1 ..];
            if (std.mem.indexOfScalar(u8, value, '#')) |h| value = value[0..h];
            return std.fmt.parseInt(u32, std.mem.trim(u8, value, " \t"), 10) catch 0;
        }
        return 0;
    }

    /// Read the configured Epicbox index from `<top>/epic-wallet.toml` into
    /// `epicbox_index`. A config that can't be read leaves the default (0) — the
    /// launch that follows would fail on it anyway, and say why.
    fn cacheEpicboxIndex(allocator: std.mem.Allocator, io: std.Io, top: []const u8) void {
        var dir = std.Io.Dir.cwd().openDir(io, top, .{}) catch return;
        defer dir.close(io);
        var file = dir.openFile(io, wallet_conf_file, .{}) catch return;
        defer file.close(io);
        const stat = file.stat(io) catch return;
        const size: usize = @intCast(@min(stat.size, 256 * 1024));
        const input = allocator.alloc(u8, size) catch return;
        defer allocator.free(input);
        const n = file.readPositionalAll(io, input, 0) catch return;
        epicbox_index.store(epicboxIndexFromToml(input[0..n]), .release);
    }

    /// The wallet's Epicbox address via the Owner API's `get_public_address`
    /// (needs the cached token — `error.WalletLocked` when no wallet is open).
    /// `force_new` is ignored: see the section note. Caller owns the slice.
    fn epicReceiveAddress(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        force_new: bool,
    ) anyerror![]const u8 {
        _ = force_new;
        var token_buf: [128]u8 = undefined;
        const tn = Session.get(&token_buf) orelse return error.WalletLocked;

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();

        const params = try std.fmt.allocPrint(
            allocator,
            "{{\"token\":\"{s}\",\"derivation_index\":{d}}}",
            .{ token_buf[0..tn], epicbox_index.load(.acquire) },
        );
        defer allocator.free(params);

        const r = try secureRpc(allocator, threaded.io(), auth, "get_public_address", params);
        defer {
            @memset(r, 0);
            allocator.free(r);
        }
        if (!innerSucceeded(r)) return error.WalletReceiveAddressFailed;
        return parsePublicAddress(allocator, r);
    }

    /// Map a decrypted `get_public_address` reply — `{"result":{"Ok":{"domain",
    /// "port","public_key"}}}` — to the address a sender types:
    /// `<public_key>@<domain>`, plus `:<port>` unless it's the default 443
    /// (epic-wallet's own spelling). Each part is held to the character set
    /// epic-wallet's address parser accepts, so what BoxWallet shows is always
    /// something a sender's wallet will take — anything else is refused, not
    /// passed along. Pure, so it's testable without a wallet.
    fn parsePublicAddress(allocator: std.mem.Allocator, inner: []const u8) ![]const u8 {
        const Addr = struct {
            domain: []const u8 = "",
            port: ?u16 = null,
            public_key: []const u8 = "",
        };
        const Env = struct { result: ?struct { Ok: ?Addr = null } = null };
        var parsed = try std.json.parseFromSlice(Env, allocator, inner, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();
        const addr = (parsed.value.result orelse return error.WalletReceiveAddressFailed).Ok orelse
            return error.WalletReceiveAddressFailed;

        // A base58 public key of exactly 52 characters; a domain of letters,
        // digits and dots — the two groups of epic-wallet's address regex.
        const base58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
        if (addr.public_key.len != 52) return error.BadEpicboxAddress;
        for (addr.public_key) |ch| {
            if (std.mem.indexOfScalar(u8, base58, ch) == null) return error.BadEpicboxAddress;
        }
        if (addr.domain.len == 0) return error.BadEpicboxAddress;
        for (addr.domain) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '.') return error.BadEpicboxAddress;
        }

        const out = if (addr.port == null or addr.port.? == 443)
            try std.fmt.allocPrint(allocator, "{s}@{s}", .{ addr.public_key, addr.domain })
        else
            try std.fmt.allocPrint(allocator, "{s}@{s}:{d}", .{ addr.public_key, addr.domain, addr.port.? });
        if (out.len > epicbox_address_max) {
            allocator.free(out);
            return error.BadEpicboxAddress;
        }
        return out;
    }

    // --- Send (Owner API `init_send_tx` over Epicbox) ----------------------
    //
    // A MimbleWimble send is a conversation, not a broadcast: the sender posts a
    // slate to the receiver's Epicbox mailbox, the receiver's wallet signs it and
    // posts it back, and the sender's wallet finalizes it and hands it to a node.
    // `init_send_tx` with `send_args.method = "epicbox"` does the first leg itself
    // — building the slate, posting it over a connection of its own that it closes
    // straight after, then locking the inputs so they can't be spent twice. The
    // rest is the Epicbox listener's job (see `listenerArgv`), which is why a
    // "sent" here means *on its way*, and completes on its own while the wallet
    // stays unlocked. If the receiver is offline the relay holds the slate.

    /// Confirmations an output needs before it can be spent — epic-wallet's own
    /// default, and the figure the balance read uses too, so the "available"
    /// amount is exactly what a send will agree to spend.
    const min_confirmations = 10;

    /// Whole EPIC → the wallet's integer base units (1e8 per EPIC), or null for an
    /// amount that isn't a positive number that fits.
    fn baseUnitsFromAmount(amount: f64) ?u64 {
        if (!std.math.isFinite(amount) or amount <= 0) return null;
        const scaled = @round(amount * epic_base);
        if (scaled < 1 or scaled >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return null;
        return @intFromFloat(scaled);
    }

    /// Whether `addr` is an Epicbox address a send can go to: epic-wallet's own
    /// shape — `[epicbox://]<52 base58>[@<domain>[:<port>]]` — **and** a key whose
    /// base58check checksum and mainnet version bytes hold. The checksum is what
    /// catches a mistyped or half-pasted address here, with a plain reason, rather
    /// than as a library error after the wallet has already started building the
    /// transaction.
    fn isEpicboxAddress(addr: []const u8) bool {
        var rest = addr;
        if (std.mem.startsWith(u8, rest, "epicbox://")) rest = rest["epicbox://".len..];
        const at = std.mem.indexOfScalar(u8, rest, '@') orelse rest.len;
        if (!epicboxKeyValid(rest[0..at])) return false;
        if (at == rest.len) return true;

        const host = rest[at + 1 ..];
        const colon = std.mem.indexOfScalar(u8, host, ':') orelse host.len;
        const domain = host[0..colon];
        if (domain.len == 0) return false;
        for (domain) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '.') return false;
        if (colon == host.len) return true;
        const port = host[colon + 1 ..];
        _ = std.fmt.parseInt(u16, port, 10) catch return false;
        return true;
    }

    /// A 52-character base58check Epicbox key: version `[1, 0]` (mainnet) + a
    /// 33-byte compressed public key + a 4-byte double-SHA256 checksum.
    fn epicboxKeyValid(key: []const u8) bool {
        const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
        if (key.len != 52) return false;
        // Big-endian base58 → bytes. 52 base58 digits need at most 39 bytes.
        var buf: [40]u8 = [_]u8{0} ** 40;
        for (key) |ch| {
            var carry: u32 = @intCast(std.mem.indexOfScalar(u8, alphabet, ch) orelse return false);
            var i: usize = buf.len;
            while (i > 0) {
                i -= 1;
                carry += @as(u32, buf[i]) * 58;
                buf[i] = @truncate(carry);
                carry >>= 8;
            }
            if (carry != 0) return false;
        }
        // Version (2) + key (33) + checksum (4) = 39 bytes; the leading byte of
        // the 40-byte buffer must be empty.
        if (buf[0] != 0) return false;
        const decoded = buf[1..];
        if (decoded[0] != 1 or decoded[1] != 0) return false;
        const Sha256 = std.crypto.hash.sha2.Sha256;
        var h1: [32]u8 = undefined;
        Sha256.hash(decoded[0..35], &h1, .{});
        var h2: [32]u8 = undefined;
        Sha256.hash(&h1, &h2, .{});
        return std.mem.eql(u8, h2[0..4], decoded[35..39]);
    }

    /// Send `amount` EPIC to the Epicbox `address` from the open wallet, with
    /// `note` (may be empty) as the slate message. A rejection the user needs to
    /// read — a bad address, too little spendable, the wallet's own refusal —
    /// comes back as `.failed` with a sentence; transport failures (no wallet
    /// open, the service down) are errors, as for every other coin's send.
    fn epicSend(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        address: []const u8,
        amount: f64,
        note: []const u8,
    ) anyerror!models.SendResult {
        const addr = std.mem.trim(u8, address, " \t\r\n");
        if (!isEpicboxAddress(addr)) return .{ .failed = not_an_address };
        const units = baseUnitsFromAmount(amount) orelse return .{ .failed = "invalid amount" };
        const r = try initSendTx(allocator, auth, addr, units, note, .send);
        defer {
            @memset(r, 0);
            allocator.free(r);
        }
        return parseSendReply(allocator, r);
    }

    /// What sending `amount` to `address` would cost: the same `init_send_tx`
    /// with `estimate_only`, which selects the inputs and prices the transaction
    /// without building or sending anything. The address is checked here too, so
    /// a bad one is caught before the confirm step rather than after it.
    fn epicSendFee(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        address: []const u8,
        amount: f64,
    ) anyerror!models.FeeEstimate {
        const addr = std.mem.trim(u8, address, " \t\r\n");
        if (!isEpicboxAddress(addr)) return .{ .failed = not_an_address };
        const units = baseUnitsFromAmount(amount) orelse return .{ .failed = "invalid amount" };
        const r = try initSendTx(allocator, auth, addr, units, "", .estimate);
        defer {
            @memset(r, 0);
            allocator.free(r);
        }
        return feeFromEstimate(allocator, r);
    }

    /// A decrypted `estimate_only` reply as a `FeeEstimate`.
    fn feeFromEstimate(allocator: std.mem.Allocator, r: []const u8) !models.FeeEstimate {
        if (try sendRefusal(allocator, r)) |why| return .{ .failed = why };
        const fee = parseSlateFee(allocator, r) orelse
            return .{ .failed = "The wallet didn't say what the fee would be." };
        return .{ .fee = fee };
    }

    const not_an_address = "That isn't an Epicbox address — check it was copied in full.";

    /// `init_send_tx` for real over Epicbox, priced only, or built for a slate
    /// file (no `send_args`: nothing is posted, and nothing is locked until
    /// `tx_lock_outputs`).
    const InitSendMode = enum { send, estimate, file };

    /// One `init_send_tx` over the secure channel, returning the decrypted reply
    /// (caller wipes + frees). `.estimate` sets `estimate_only` **and** sends no
    /// `send_args`: the wallet goes on to post the slate whenever `send_args` is
    /// present, so an estimate that carried them would be a send.
    ///
    /// A non-empty `note` becomes the slate's `message`: the wallet signs it as
    /// the sender's participant message, the receiver's wallet keeps it with the
    /// transaction, and both logs report it (`TxLogEntry.messages`). It travels
    /// with the slate over Epicbox — MimbleWimble has no on-chain memo.
    fn initSendTx(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        addr: []const u8,
        units: u64,
        note: []const u8,
        mode: InitSendMode,
    ) ![]u8 {
        var token_buf: [128]u8 = undefined;
        const tn = Session.get(&token_buf) orelse return error.WalletLocked;

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();

        const addr_q = try rpc.jsonQuote(allocator, addr);
        defer allocator.free(addr_q);
        const send_args = switch (mode) {
            .send => try std.fmt.allocPrint(
                allocator,
                "{{\"method\":\"epicbox\",\"dest\":{s},\"finalize\":true,\"post_tx\":true,\"fluff\":false}}",
                .{addr_q},
            ),
            .estimate, .file => try allocator.dupe(u8, "null"),
        };
        defer allocator.free(send_args);
        const message = if (note.len > 0) try rpc.jsonQuote(allocator, note) else try allocator.dupe(u8, "null");
        defer allocator.free(message);
        const params = try std.fmt.allocPrint(
            allocator,
            "{{\"token\":\"{s}\",\"args\":{{\"src_acct_name\":null,\"amount\":\"{d}\"," ++
                "\"minimum_confirmations\":{d},\"max_outputs\":500,\"num_change_outputs\":1," ++
                "\"selection_strategy_is_use_all\":false,\"message\":{s},\"target_slate_version\":null," ++
                "\"payment_proof_recipient_address\":null,\"ttl_blocks\":null," ++
                "\"send_args\":{s},\"estimate_only\":{s}}}}}",
            .{ token_buf[0..tn], units, min_confirmations, message, send_args, if (mode == .estimate) "true" else "false" },
        );
        defer allocator.free(params);

        return secureRpc(allocator, threaded.io(), auth, "init_send_tx", params);
    }

    /// The fee (whole EPIC) from a successful `init_send_tx` reply's slate —
    /// `"fee":"800000"` in base units — or null if it isn't there.
    fn parseSlateFee(allocator: std.mem.Allocator, inner: []const u8) ?f64 {
        const Env = struct { result: ?struct { Ok: ?struct { fee: []const u8 = "" } = null } = null };
        var parsed = std.json.parseFromSlice(Env, allocator, inner, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return null;
        defer parsed.deinit();
        const slate = (parsed.value.result orelse return null).Ok orelse return null;
        const units = std.fmt.parseInt(u64, slate.fee, 10) catch return null;
        return @as(f64, @floatFromInt(units)) / epic_base;
    }

    /// Map a decrypted `init_send_tx` reply to a `SendResult`. Success carries the
    /// slate id (the handle the transaction list shows) and what happens next; a
    /// refusal carries `sendRefusal`'s sentence. Pure, so the mapping is testable
    /// without a wallet. Strings are allocated with `allocator` (the caller's
    /// arena).
    fn parseSendReply(allocator: std.mem.Allocator, inner: []const u8) !models.SendResult {
        if (try sendRefusal(allocator, inner)) |why| return .{ .failed = why };
        const Env = struct { result: ?struct { Ok: ?struct { id: []const u8 = "" } = null } = null };
        var parsed = std.json.parseFromSlice(Env, allocator, inner, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return .{ .failed = unreadable_reply };
        defer parsed.deinit();
        const id = (parsed.value.result orelse return .{ .failed = unreadable_reply }).Ok orelse
            return .{ .failed = unreadable_reply };
        if (id.id.len == 0) return .{ .failed = unreadable_reply };
        return .{ .ok = try std.fmt.allocPrint(
            allocator,
            "{s}. It completes on its own once the receiver accepts it, while this wallet stays unlocked.",
            .{id.id},
        ) };
    }

    const unreadable_reply = "The wallet gave an answer BoxWallet couldn't read.";

    /// Null when an `init_send_tx` reply is a success (`result.Ok`); otherwise
    /// the refusal as a sentence — `NotEnoughFunds` spelled out with the wallet's
    /// own figures, anything else the wallet's message verbatim.
    fn sendRefusal(allocator: std.mem.Allocator, inner: []const u8) !?[]const u8 {
        const Env = struct {
            result: ?struct { Ok: ?std.json.Value = null } = null,
            @"error": ?struct { message: []const u8 = "" } = null,
        };
        var parsed = std.json.parseFromSlice(Env, allocator, inner, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return unreadable_reply;
        defer parsed.deinit();
        if (parsed.value.result) |res| if (res.Ok) |ok| if (ok != .null) return null;

        const msg = if (parsed.value.@"error") |e| e.message else "";
        if (std.mem.startsWith(u8, msg, "NotEnoughFunds:")) {
            const Funds = struct { available_disp: []const u8 = "?", needed_disp: []const u8 = "?" };
            if (std.json.parseFromSlice(Funds, allocator, std.mem.trim(u8, msg["NotEnoughFunds:".len..], " "), .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            })) |funds| {
                defer funds.deinit();
                return try std.fmt.allocPrint(
                    allocator,
                    "Not enough spendable EPIC: {s} available, {s} needed including the fee. Received funds need {d} confirmations before they can be sent.",
                    .{ money.trimTrailingZeros(funds.value.available_disp), money.trimTrailingZeros(funds.value.needed_disp), min_confirmations },
                );
            } else |_| {}
        }
        if (msg.len == 0) return "The wallet refused the send without saying why.";
        return try allocator.dupe(u8, msg[0..@min(msg.len, 240)]);
    }

    // --- Slate files (`Coin.SlateFiles`) ---------------------------------
    //
    // The same three legs as an Epicbox payment, carried by hand. The sender
    // builds the slate (`init_send_tx` with no `send_args`) and locks the coins
    // it spends (`tx_lock_outputs`); the receiver signs it (`receive_tx`, on the
    // Foreign API `owner_api --run_foreign` serves) and returns the response;
    // the sender finalizes that (`finalize_tx`) and broadcasts it (`post_tx`).
    // A slate holds nothing secret — commitments, public nonces and signatures;
    // each side's private half stays in its own wallet database.
    //
    // What a file *is* is never taken on trust from the front-end: `process`
    // re-reads and re-classifies the file itself, against this wallet's own
    // transaction log, and refuses if that no longer matches what the user was
    // shown.

    /// Largest slate file read. A slate is a few KB; one spending the most
    /// inputs `init_send_tx` allows is still well under this.
    const slate_max_bytes = 1024 * 1024;

    /// Slates this session has finalized and broadcast. The wallet's log can't
    /// tell those apart from sends still waiting for their reply: both read
    /// `TxSentCreated`, with the kernel excess and stored tx already set at lock
    /// time (seen live), until the network is seen to have it. A file send can
    /// wait hours for its reply, so it's past `cancel_min_age_s` the moment it's
    /// finalized — and cancelling what's been broadcast leaves the balance wrong
    /// until a rescan. So remember it here: such a row reads as in the mempool,
    /// isn't offered for cancelling, and its response isn't offered for
    /// finalizing again. In memory only — by the time an app restart forgets it,
    /// it has normally confirmed (and the wallet, having dropped the send's
    /// private context at finalize, refuses a second finalize anyway).
    const Finalized = struct {
        const cap = 16;
        var ids: [cap][36]u8 = undefined;
        var len: usize = 0;
        var next: usize = 0;
        var lock: std.atomic.Mutex = .unlocked;

        fn add(id: []const u8) void {
            if (id.len != 36) return;
            while (!lock.tryLock()) std.atomic.spinLoopHint();
            defer lock.unlock();
            ids[next] = id[0..36].*;
            next = (next + 1) % cap;
            if (len < cap) len += 1;
        }

        fn has(id: []const u8) bool {
            if (id.len != 36) return false;
            while (!lock.tryLock()) std.atomic.spinLoopHint();
            defer lock.unlock();
            for (ids[0..len]) |*known| if (std.mem.eql(u8, known, id)) return true;
            return false;
        }

        /// Rows for sends finalized this session: in the mempool, not cancellable.
        fn apply(rows: []models.WalletTx) void {
            for (rows) |*r| {
                if (r.direction != .sent or !r.stage.waitingForCounterparty()) continue;
                if (!has(r.txid())) continue;
                r.stage = .in_mempool;
                r.cancellable = false;
            }
        }
    };

    pub const slate_files: Coin.SlateFiles = .{
        // Replies named as the epic-wallet CLI names them (`x.tx.response`);
        // Epic's GUI wallet suggests `finalize_x.tx`, which is recognised too.
        .other_reply_prefix = "finalize_",
        .fee = epicSlateFee,
        .send = epicSlateSend,
        .inspect = epicSlateInspect,
        .process = epicSlateProcess,
    };

    fn epicSlateFee(allocator: std.mem.Allocator, auth: models.CoinAuth, amount: f64) anyerror!models.FeeEstimate {
        const units = baseUnitsFromAmount(amount) orelse return .{ .failed = "invalid amount" };
        const r = try initSendTx(allocator, auth, "", units, "", .estimate);
        defer {
            @memset(r, 0);
            allocator.free(r);
        }
        return feeFromEstimate(allocator, r);
    }

    /// Build the send, write `<out_dir>/<slate id>.tx`, lock the coins. The file
    /// is written *before* the lock (as `.part`, renamed after), so a send whose
    /// file couldn't be saved never ties up any coins; a lock that fails takes
    /// the file away again.
    fn epicSlateSend(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        amount: f64,
        note: []const u8,
        out_dir: []const u8,
    ) anyerror!models.SendResult {
        const units = baseUnitsFromAmount(amount) orelse return .{ .failed = "invalid amount" };
        var token_buf: [128]u8 = undefined;
        const tn = Session.get(&token_buf) orelse return error.WalletLocked;

        const r = try initSendTx(allocator, auth, "", units, note, .file);
        defer {
            @memset(r, 0);
            allocator.free(r);
        }
        if (try sendRefusal(allocator, r)) |why| return .{ .failed = why };

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const slate = okSlate(a, r) orelse return .{ .failed = unreadable_reply };
        const id = slateId(slate) orelse return .{ .failed = unreadable_reply };
        const text = try jsonText(a, slate);

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var dir = std.Io.Dir.cwd().openDir(io, out_dir, .{}) catch
            return .{ .failed = try std.fmt.allocPrint(allocator, "Couldn't open {s} to save the slate in.", .{out_dir}) };
        defer dir.close(io);
        const name = try std.fmt.allocPrint(a, "{s}.{s}", .{ id, slate_files.extension });
        const part = try std.fmt.allocPrint(a, "{s}.part", .{name});
        dir.writeFile(io, .{ .sub_path = part, .data = text }) catch
            return .{ .failed = try std.fmt.allocPrint(allocator, "Couldn't save the slate in {s}.", .{out_dir}) };

        const params = try std.fmt.allocPrint(
            a,
            "{{\"token\":\"{s}\",\"slate\":{s},\"participant_id\":0,\"addr_to\":null}}",
            .{ token_buf[0..tn], text },
        );
        const lr = secureRpc(allocator, io, auth, "tx_lock_outputs", params) catch |err| {
            dir.deleteFile(io, part) catch {};
            return err;
        };
        defer {
            @memset(lr, 0);
            allocator.free(lr);
        }
        if (!innerSucceeded(lr)) {
            dir.deleteFile(io, part) catch {};
            return .{ .failed = (try sendRefusal(allocator, lr)) orelse "The wallet couldn't set the coins aside for this send." };
        }
        dir.rename(part, dir, name, io) catch {
            // Locked but not where the user will look. It's still cancellable like
            // any unanswered send, so say where it is and how to undo it.
            return .{ .failed = try std.fmt.allocPrint(
                allocator,
                "The coins are set aside, but the slate is still named {s} in {s}. Rename it to {s}, or cancel the send from Transactions.",
                .{ part, out_dir, name },
            ) };
        };
        return .{ .ok = try std.fs.path.join(allocator, &.{ out_dir, name }) };
    }

    fn epicSlateInspect(allocator: std.mem.Allocator, auth: models.CoinAuth, path: []const u8) anyerror!models.SlateInfo {
        var info: models.SlateInfo = .{};
        const text = readSlateFile(allocator, path, &info) orelse return info;
        defer allocator.free(text);
        try classifySlate(allocator, auth, text, &info);
        return info;
    }

    fn epicSlateProcess(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        path: []const u8,
        expect: models.SlateKind,
    ) anyerror!models.SendResult {
        // The very bytes acted on are the ones classified here, not whatever the
        // front-end inspected a moment ago.
        var info: models.SlateInfo = .{};
        const text = readSlateFile(allocator, path, &info) orelse
            return .{ .failed = try allocator.dupe(u8, info.reason()) };
        defer allocator.free(text);
        try classifySlate(allocator, auth, text, &info);
        if (info.kind == .unusable) return .{ .failed = try allocator.dupe(u8, info.reason()) };
        if (info.kind != expect or expect == .unusable)
            return .{ .failed = "The file has changed since it was opened. Open it again." };

        return switch (expect) {
            .receive => receiveSlate(allocator, auth, text, path),
            .finalize => finalizeSlate(allocator, auth, text, info.id()),
            .unusable => unreachable,
        };
    }

    /// Read a slate file (bounded), or null with `info` refused saying why.
    /// Caller frees.
    fn readSlateFile(allocator: std.mem.Allocator, path: []const u8, info: *models.SlateInfo) ?[]u8 {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        return std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, allocator, .limited(slate_max_bytes)) catch |err| {
            info.refuse(switch (err) {
                error.FileNotFound => "That file doesn't exist any more.",
                error.StreamTooLong => "That file is far too big to be a slate.",
                error.IsDir => "That's a folder, not a slate file.",
                else => "That file couldn't be read.",
            });
            return null;
        };
    }

    /// Fill `info` from the slate `text`: its amount, fee, id and note, and what
    /// it is for this wallet — decided by how many participants have signed it
    /// and by what this wallet's own log says about the same slate id.
    fn classifySlate(allocator: std.mem.Allocator, auth: models.CoinAuth, text: []const u8, info: *models.SlateInfo) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const shape = parseSlateShape(a, text) orelse return info.refuse("That isn't an Epic slate file.");
        info.amount = shape.amount;
        info.fee = shape.fee;
        info.setId(shape.id);
        info.setNote(shape.note);

        var log = try slateLog(a, auth, shape.id);
        if (log.sent_open and Finalized.has(shape.id)) {
            log.sent_open = false;
            log.sent_done = true;
        }
        info.kind = slateVerdict(shape.participants, log) orelse return info.refuse(slateRefusal(shape.participants, log));
    }

    /// The parts of a slate `classifySlate` needs. Amounts in whole coins.
    const SlateShape = struct {
        id: []const u8,
        amount: f64,
        fee: f64,
        participants: usize,
        note: []const u8,
    };

    /// Read a V2/V3 slate's id, amount, fee, signers and first message; null if
    /// it isn't one. Epic writes amounts as base-unit strings; numbers are
    /// accepted too. Pure, for testing.
    fn parseSlateShape(a: std.mem.Allocator, text: []const u8) ?SlateShape {
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return null;
        if (v != .object) return null;
        const id = slateId(v) orelse return null;
        const amount = baseUnitsValue(v.object.get("amount") orelse return null) orelse return null;
        const fee = baseUnitsValue(v.object.get("fee") orelse return null) orelse return null;
        const pd = v.object.get("participant_data") orelse return null;
        if (pd != .array) return null;
        var note: []const u8 = "";
        for (pd.array.items) |p| {
            if (p != .object) return null;
            if (note.len == 0) if (p.object.get("message")) |m| if (m == .string) {
                note = m.string;
            };
        }
        return .{
            .id = id,
            .amount = @as(f64, @floatFromInt(amount)) / epic_base,
            .fee = @as(f64, @floatFromInt(fee)) / epic_base,
            .participants = pd.array.items.len,
            .note = note,
        };
    }

    fn baseUnitsValue(v: std.json.Value) ?u64 {
        return switch (v) {
            .string => |t| std.fmt.parseInt(u64, t, 10) catch null,
            .integer => |n| if (n >= 0) @intCast(n) else null,
            else => null,
        };
    }

    /// What this wallet's log says about one slate id: the entry types present.
    const SlateLog = struct {
        sent_open: bool = false, // TxSentCreated, unconfirmed: waiting for the reply
        sent_done: bool = false, // TxSent / TxSentMempool: already finalized
        sent_cancelled: bool = false,
        received: bool = false, // any TxReceived*, not cancelled
        received_cancelled: bool = false,
    };

    fn slateLog(a: std.mem.Allocator, auth: models.CoinAuth, id: []const u8) !SlateLog {
        var token_buf: [128]u8 = undefined;
        const tn = Session.get(&token_buf) orelse return error.WalletLocked;
        var threaded: std.Io.Threaded = .init(a, .{});
        defer threaded.deinit();
        // `isUuid` came first (`slateId`), so the id is safe to splice in.
        const params = try std.fmt.allocPrint(
            a,
            "{{\"token\":\"{s}\",\"refresh_from_node\":false,\"tx_id\":null,\"tx_slate_id\":\"{s}\"," ++
                "\"limit\":10,\"offset\":0,\"sort_order\":\"desc\"}}",
            .{ token_buf[0..tn], id },
        );
        const r = try secureRpc(a, threaded.io(), auth, "retrieve_txs", params);
        defer @memset(r, 0);
        if (!innerSucceeded(r)) return error.WalletTransactionsFailed;
        return parseSlateLog(a, r);
    }

    /// Fold a `retrieve_txs` reply into a `SlateLog`. Pure, for testing.
    fn parseSlateLog(a: std.mem.Allocator, inner: []const u8) !SlateLog {
        const Paged = struct { result: ?struct { Ok: ?struct { txs: []const TxLogEntry = &.{} } = null } = null };
        const v = try std.json.parseFromSliceLeaky(Paged, a, inner, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        const txs = ((v.result orelse return error.WalletTransactionsFailed).Ok orelse return error.WalletTransactionsFailed).txs;
        var log: SlateLog = .{};
        for (txs) |e| {
            const t = e.tx_type;
            if (std.mem.eql(u8, t, "TxSentCreated")) {
                if (e.confirmed) log.sent_done = true else log.sent_open = true;
            } else if (std.mem.eql(u8, t, "TxSent") or std.mem.eql(u8, t, "TxSentMempool")) {
                log.sent_done = true;
            } else if (std.mem.eql(u8, t, "TxSentCancelled")) {
                log.sent_cancelled = true;
            } else if (std.mem.eql(u8, t, "TxReceivedCancelled")) {
                log.received_cancelled = true;
            } else if (std.mem.startsWith(u8, t, "TxReceived")) {
                log.received = true;
            }
        }
        return log;
    }

    /// What to do with a slate signed by `participants` sides, given this
    /// wallet's log for it; null when nothing can be (see `slateRefusal`).
    fn slateVerdict(participants: usize, log: SlateLog) ?models.SlateKind {
        return switch (participants) {
            // A fresh payment, from someone else, not yet taken.
            1 => if (!log.sent_open and !log.sent_done and !log.sent_cancelled and
                !log.received and !log.received_cancelled) .receive else null,
            // The reply to a send of ours that's still waiting for it.
            2 => if (log.sent_open and !log.sent_done and !log.sent_cancelled) .finalize else null,
            else => null,
        };
    }

    /// Why `slateVerdict` said no, in the user's terms.
    fn slateRefusal(participants: usize, log: SlateLog) []const u8 {
        if (participants == 1) {
            if (log.sent_open or log.sent_done or log.sent_cancelled)
                return "This is your own send. Give this file to the person you're paying, and open the reply file they send back.";
            if (log.received) return "You've already received this payment. Send the sender the reply file you made then.";
            return "You cancelled this payment when it was received, so it can't be taken again.";
        }
        if (participants == 2) {
            if (log.sent_done) return "This payment has already been completed.";
            if (log.sent_cancelled) return "You cancelled this send, so it can't be completed.";
            if (log.received or log.received_cancelled)
                return "This is the reply you made to someone else's payment. Send it back to them to finish it.";
            return "This isn't the reply to a send from this wallet.";
        }
        return "That slate isn't one this wallet can use.";
    }

    /// Sign an incoming payment and write the reply next to the file, named as
    /// epic-wallet's `receive` names it (`<name>.response`). Created, never
    /// overwritten.
    fn receiveSlate(allocator: std.mem.Allocator, auth: models.CoinAuth, text: []const u8, path: []const u8) !models.SendResult {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const out_path = try replyPath(allocator, path);
        errdefer allocator.free(out_path);
        if (std.Io.Dir.cwd().access(io, out_path, .{})) |_| {
            return .{ .failed = try std.fmt.allocPrint(allocator, "{s} already exists. Move it out of the way first.", .{out_path}) };
        } else |_| {}

        // Epic's `receive_tx` takes a fourth argument Grin's doesn't (the
        // sender's address, for Epicbox); a file has none to give.
        const body = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"receive_tx\",\"params\":[{s},null,null,null]}}", .{text});
        const raw = try apiPost(a, io, auth, "/v2/foreign", body);
        if (try sendRefusal(a, raw)) |why| return .{ .failed = try allocator.dupe(u8, why) };
        const slate = okSlate(a, raw) orelse return .{ .failed = unreadable_reply };
        const signed = try jsonText(a, slate);

        var f = std.Io.Dir.cwd().createFile(io, out_path, .{ .exclusive = true }) catch
            return .{ .failed = try std.fmt.allocPrint(allocator, "The payment was signed, but {s} couldn't be written.", .{out_path}) };
        defer f.close(io);
        f.writeStreamingAll(io, signed) catch
            return .{ .failed = try std.fmt.allocPrint(allocator, "The payment was signed, but {s} couldn't be written.", .{out_path}) };
        return .{ .ok = out_path };
    }

    /// Finalize the receiver's reply and broadcast it.
    fn finalizeSlate(allocator: std.mem.Allocator, auth: models.CoinAuth, text: []const u8, id: []const u8) !models.SendResult {
        var token_buf: [128]u8 = undefined;
        const tn = Session.get(&token_buf) orelse return error.WalletLocked;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const fp = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\",\"slate\":{s}}}", .{ token_buf[0..tn], text });
        const fr = try secureRpc(a, io, auth, "finalize_tx", fp);
        defer @memset(fr, 0);
        if (try sendRefusal(a, fr)) |why| {
            if (alreadyFinalized(why)) {
                // Finalized before — by this app in an earlier session, or by
                // another. Remember it, so the row stops reading as waiting.
                Finalized.add(id);
                return .{ .failed = already_finished };
            }
            return .{ .failed = try allocator.dupe(u8, why) };
        }
        const done = okSlate(a, fr) orelse return .{ .failed = unreadable_reply };
        const tx = done.object.get("tx") orelse return .{ .failed = unreadable_reply };

        const pp = try std.fmt.allocPrint(a, "{{\"token\":\"{s}\",\"tx\":{s},\"fluff\":false}}", .{ token_buf[0..tn], try jsonText(a, tx) });
        const pr = try secureRpc(a, io, auth, "post_tx", pp);
        defer @memset(pr, 0);
        // Finalized: from here on it must not read as a send still waiting —
        // whether or not the post below goes through.
        Finalized.add(id);
        if (!innerSucceeded(pr)) {
            const why = (try sendRefusal(a, pr)) orelse "no reason given";
            return .{ .failed = try std.fmt.allocPrint(allocator, "The payment was finalized but the network didn't take it: {s}", .{why}) };
        }
        return .{ .ok = "Sent. It's on its way to the network." };
    }

    /// Where the reply to the slate at `path` goes: beside it, as
    /// `<path><reply_suffix>`. Caller owns the path.
    fn replyPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ path, slate_files.reply_suffix });
    }

    const already_finished = "This send was already finished — the payment is on its way to the network, or already in a block. Nothing was sent twice.";

    /// Whether a `finalize_tx` refusal means it was finalized before: the wallet
    /// drops a send's private context when it finalizes it, so a second attempt
    /// finds nothing ("NotFoundErr: Slate id: [...]", seen live).
    fn alreadyFinalized(why: []const u8) bool {
        return std.mem.startsWith(u8, why, "NotFoundErr");
    }

    /// `result.Ok` of a decrypted reply, when it's a slate (an object with an id).
    fn okSlate(a: std.mem.Allocator, inner: []const u8) ?std.json.Value {
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, inner, .{}) catch return null;
        if (v != .object) return null;
        const res = v.object.get("result") orelse return null;
        if (res != .object) return null;
        const ok = res.object.get("Ok") orelse return null;
        if (ok != .object or slateId(ok) == null) return null;
        return ok;
    }

    /// A slate's id, if it has a well-formed one.
    fn slateId(slate: std.json.Value) ?[]const u8 {
        const id = slate.object.get("id") orelse return null;
        if (id != .string or !isUuid(id.string)) return null;
        return id.string;
    }

    fn jsonText(a: std.mem.Allocator, v: std.json.Value) ![]const u8 {
        var w: std.Io.Writer.Allocating = .init(a);
        try std.json.Stringify.value(v, .{}, &w.writer);
        return w.written();
    }

    // --- Transactions (Owner API `retrieve_txs`) --------------------------
    //
    // MimbleWimble transactions are built *interactively* (a slate exchanged
    // between sender and receiver — over a listener or an epicbox relay). The
    // wallet's own transaction log is honest data the Owner API reports
    // directly — so the Transactions tab is live.

    /// One `retrieve_txs` TxLogEntry (the subset BoxWallet uses). Amounts are
    /// integer-base-unit strings; `creation_ts` is an RFC-3339 timestamp;
    /// `confirmed` is the only settlement state the wallet reports (no count).
    /// `tx_slate_id` is the handle the transaction is known by on both sides —
    /// and what `cancel_tx` takes.
    const TxLogEntry = struct {
        tx_type: []const u8 = "",
        creation_ts: []const u8 = "",
        confirmed: bool = false,
        amount_credited: []const u8 = "0",
        amount_debited: []const u8 = "0",
        tx_slate_id: ?[]const u8 = null,
        /// The other side's Epicbox address: the recipient of a send, the
        /// sender of a receive — the CLI's "From/To Address".
        ///
        /// This and `messages` are read as loose JSON values rather than typed
        /// fields: they're extras, and a shape this code didn't expect must
        /// cost the row its address or note, never the whole list.
        public_addr: ?std.json.Value = null,
        /// The slate's participant messages — where a sender's note lives:
        /// `{"messages":[{"message":"…",…},…]}`.
        messages: ?std.json.Value = null,

        fn address(self: TxLogEntry) []const u8 {
            const v = self.public_addr orelse return "";
            return if (v == .string) v.string else "";
        }

        /// The first non-empty participant message: the sender's note, whichever
        /// side of the transaction this wallet was on.
        fn note(self: TxLogEntry) []const u8 {
            const pm = self.messages orelse return "";
            if (pm != .object) return "";
            const list = pm.object.get("messages") orelse return "";
            if (list != .array) return "";
            for (list.array.items) |m| {
                if (m != .object) continue;
                const text = m.object.get("message") orelse continue;
                if (text == .string and text.string.len > 0) return text.string;
            }
            return "";
        }
    };

    /// Stand-in confirmation count for a `confirmed` entry — the wallet reports
    /// settlement only as a boolean, so a settled transaction is given a value
    /// safely past any frontend's "settled" threshold and an unsettled one 0.
    const confirmed_sentinel: i64 = 9999;

    /// How old an unfinished send must be before it's offered for cancelling.
    ///
    /// A send the wallet has *posted* still reads `TxSentCreated` until the
    /// listener sees it in the mempool — up to ~4 minutes — and cancelling one
    /// then would free inputs the network is about to spend and forget the
    /// change output until a rescan. Nothing is lost, but the balance is wrong
    /// until then. Past this age a posted send has long since been marked (or
    /// mined), so what's still `TxSentCreated` is one the receiver never
    /// answered: exactly the send there is to cancel.
    const cancel_min_age_s: i64 = 10 * 60;

    /// The open wallet's most recent transactions, newest-first, via the Owner
    /// API's `retrieve_txs` (needs the cached token — `error.WalletLocked` when
    /// no wallet is open, same as the balance read). The wallet pages the log
    /// itself — 4.x *requires* `limit`/`offset`/`sort_order` — so only the
    /// `limit` newest entries ever cross the wire. The decrypted reply is wiped
    /// before free like every Owner-API buffer.
    fn epicTransactions(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        limit: usize,
    ) anyerror![]models.WalletTx {
        var token_buf: [128]u8 = undefined;
        const tn = Session.get(&token_buf) orelse return error.WalletLocked;

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const params = try std.fmt.allocPrint(
            allocator,
            "{{\"token\":\"{s}\",\"refresh_from_node\":true,\"tx_id\":null,\"tx_slate_id\":null," ++
                "\"limit\":{d},\"offset\":0,\"sort_order\":\"desc\"}}",
            .{ token_buf[0..tn], limit },
        );
        defer allocator.free(params);

        const r = try secureRpc(allocator, io, auth, "retrieve_txs", params);
        defer {
            @memset(r, 0);
            allocator.free(r);
        }
        if (!innerSucceeded(r)) return error.WalletTransactionsFailed;
        const rows = try parseTxLog(allocator, r, limit, std.Io.Clock.real.now(io).toSeconds());
        Finalized.apply(rows);
        return rows;
    }

    /// Map a decrypted `retrieve_txs` reply into normalized `WalletTx`es,
    /// newest-first, capped at `limit`. Takes both shapes the wallet has used:
    /// 4.x's `{"Ok":{"pager":…,"txs":[…]}}` and the older `{"Ok":[<bool>,
    /// [entries…]]}`. Cancelled entries are dropped. `now` (unix seconds) decides
    /// which unfinished sends are old enough to cancel. Pure, so the parse is
    /// unit-testable without a wallet.
    fn parseTxLog(allocator: std.mem.Allocator, inner: []const u8, limit: usize, now: i64) ![]models.WalletTx {
        const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };
        const Paged = struct { result: ?struct { Ok: ?struct { txs: []const TxLogEntry = &.{} } = null } = null };
        const Tuple = struct { result: ?struct { Ok: ?struct { bool, []TxLogEntry } = null } = null };

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const entries: []const TxLogEntry = if (std.json.parseFromSliceLeaky(Paged, arena.allocator(), inner, opts)) |v|
            ((v.result orelse return error.WalletTransactionsFailed).Ok orelse return error.WalletTransactionsFailed).txs
        else |_| blk: {
            const v = try std.json.parseFromSliceLeaky(Tuple, arena.allocator(), inner, opts);
            const ok = (v.result orelse return error.WalletTransactionsFailed).Ok orelse
                return error.WalletTransactionsFailed;
            break :blk ok[1];
        };

        const all = try allocator.alloc(models.WalletTx, entries.len);
        defer allocator.free(all);
        var n: usize = 0;
        for (entries) |e| {
            const kind = txKind(e.tx_type) orelse continue;
            const credited = std.fmt.parseInt(u64, e.amount_credited, 10) catch 0;
            const debited = std.fmt.parseInt(u64, e.amount_debited, 10) catch 0;
            // The wallet's net movement: a receive credits more than it debits, a
            // send the reverse (the difference includes the fee).
            const net = if (credited >= debited) credited - debited else debited - credited;
            const time = parseRfc3339(e.creation_ts) orelse 0;
            all[n] = .{
                .direction = kind.direction,
                .amount = @as(f64, @floatFromInt(net)) / epic_base,
                .time = time,
                .confirmations = if (e.confirmed) confirmed_sentinel else 0,
                .stage = if (e.confirmed) .none else kind.stage,
            };
            if (e.tx_slate_id) |id| all[n].setTxid(id);
            all[n].setNote(e.note());
            all[n].setAddress(e.address());
            // An Epicbox send always records who it went to; one with no
            // address went as a slate file, and its reply comes back by hand.
            if (all[n].stage == .awaiting_counterparty and kind.direction == .sent and all[n].address_len == 0)
                all[n].stage = .awaiting_reply_file;
            all[n].cancellable = !e.confirmed and kind.stage == .awaiting_counterparty and
                kind.direction == .sent and all[n].txid_len > 0 and
                time > 0 and now - time >= cancel_min_age_s;
            n += 1;
        }
        std.mem.sort(models.WalletTx, all[0..n], {}, newerFirst);

        const out = try allocator.alloc(models.WalletTx, @min(n, limit));
        @memcpy(out, all[0..out.len]);
        return out;
    }

    /// Cancel the unfinished send whose slate id is `slate_id` via the Owner
    /// API's `cancel_tx`: the wallet drops it and unlocks the inputs it had
    /// reserved, so they're spendable again. Only offered for rows
    /// `parseTxLog` marked `cancellable` (see `cancel_min_age_s`). If the
    /// receiver answers later, the reply finds nothing to finalize, so the
    /// payment can't complete behind the user's back. A refusal comes back as
    /// `.failed` with the wallet's reason.
    fn epicCancelTx(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        slate_id: []const u8,
    ) anyerror!models.SendResult {
        if (!isUuid(slate_id)) return .{ .failed = "That isn't a transaction this wallet can cancel." };

        var token_buf: [128]u8 = undefined;
        const tn = Session.get(&token_buf) orelse return error.WalletLocked;

        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();

        const params = try std.fmt.allocPrint(
            allocator,
            "{{\"token\":\"{s}\",\"tx_id\":null,\"tx_slate_id\":\"{s}\"}}",
            .{ token_buf[0..tn], slate_id },
        );
        defer allocator.free(params);

        const r = try secureRpc(allocator, threaded.io(), auth, "cancel_tx", params);
        defer {
            @memset(r, 0);
            allocator.free(r);
        }
        return parseCancelReply(allocator, r);
    }

    /// Map a decrypted `cancel_tx` reply: `{"result":{"Ok":null}}` is success;
    /// anything else carries the wallet's own message. Pure, for testing.
    fn parseCancelReply(allocator: std.mem.Allocator, inner: []const u8) !models.SendResult {
        if (innerSucceeded(inner))
            return .{ .ok = "The coins it had set aside are spendable again." };
        const Env = struct { @"error": ?struct { message: []const u8 = "" } = null };
        var parsed = std.json.parseFromSlice(Env, allocator, inner, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return .{ .failed = unreadable_reply };
        defer parsed.deinit();
        const msg = if (parsed.value.@"error") |e| e.message else "";
        if (msg.len == 0) return .{ .failed = "The wallet refused to cancel it without saying why." };
        return .{ .failed = try allocator.dupe(u8, msg[0..@min(msg.len, 240)]) };
    }

    /// A slate id as the wallet writes it: 36 characters, lowercase or
    /// uppercase hex in 8-4-4-4-12 groups. Checked before it's spliced into a
    /// request.
    fn isUuid(s: []const u8) bool {
        if (s.len != 36) return false;
        for (s, 0..) |ch, i| {
            if (i == 8 or i == 13 or i == 18 or i == 23) {
                if (ch != '-') return false;
            } else if (!std.ascii.isHex(ch)) return false;
        }
        return true;
    }

    /// A `tx_type` (epic-wallet's TxLogEntryType names), normalized: which way
    /// the money moved, and — while unconfirmed — where it is. Cancelled entries
    /// (and any type this doesn't know) are null, and dropped.
    fn txKind(tx_type: []const u8) ?struct { direction: models.TxDirection, stage: models.TxStage } {
        const eql = std.mem.eql;
        if (eql(u8, tx_type, "TxReceived")) return .{ .direction = .received, .stage = .none };
        if (eql(u8, tx_type, "TxSent")) return .{ .direction = .sent, .stage = .none };
        if (eql(u8, tx_type, "ConfirmedCoinbase")) return .{ .direction = .stake, .stage = .none };
        // Made, not yet seen by the network: the receiver hasn't answered, or it
        // was only just posted.
        if (eql(u8, tx_type, "TxSentCreated")) return .{ .direction = .sent, .stage = .awaiting_counterparty };
        if (eql(u8, tx_type, "TxSentMempool")) return .{ .direction = .sent, .stage = .in_mempool };
        if (eql(u8, tx_type, "TxReceivedMempool")) return .{ .direction = .received, .stage = .in_mempool };
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
    /// then run over the encrypted Owner API. Backups come both ways, locked or
    /// open: the seed words again (`show_seed`, decrypted from wallet.seed with
    /// the password), and the encrypted wallet.seed as a file (`backup_file`),
    /// which `restore_file` takes back after checking the password against it.
    pub const external_wallet: Coin.ExternalWallet = .{
        .rpc_port = walletRpcPort,
        .launch_server_argv = launchServerArgv,
        .listener_argv = listenerArgv,
        .listener_name = "Epicbox listener",
        // Both processes are given their password at a terminal prompt, never in
        // argv (see `pass_on_tty`); empty where that isn't possible.
        .password_prompt = if (pass_on_tty) password_prompt else "",
        .cli_create = epicCliCreate,
        .exists = walletExists,
        .create = epicCreate,
        .restore_seed = epicRestore,
        .restore_file = epicRestoreFile,
        .show_seed = epicShowSeed,
        .backup_file = epicBackupFile,
        .backup_file_ext = ".seed",
        // Read from wallet.seed with the password, not from the wallet process.
        .show_seed_when_locked = true,
        .relay_source = relaySource,
        .set_relay_source = setRelaySource,
        .relay_name = "Epicbox server",
        .relay_default = default_relay_host,
        .relay_example = relay_example,
        .relay_note = relay_note,
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
        // Transactions; the Epicbox address as the Receive tab's address; and
        // Send over Epicbox (see the `get_public_address` / `init_send_tx`
        // sections above) — a send the Epicbox listener then completes.
        .wallet_transactions = vtWalletTransactions,
        .wallet_receive_address = vtWalletReceiveAddress,
        // One per wallet (see the Receive address section): a "new" one would
        // be the same address.
        .receive_address_fixed_note = "This wallet has one Epicbox address. It doesn't change, and it's fine to reuse.",
        .wallet_send = vtWalletSend,
        .wallet_send_note = vtWalletSendNote,
        .send_note_max = models.tx_note_max,
        .wallet_send_fee = vtWalletSendFee,
        .wallet_cancel_tx = vtWalletCancelTx,
        .slate_files = &slate_files,
        // A send here is on its way, not done — the listener completes it — and
        // what comes back is the slate id.
        .send_ok_label = "Sent — waiting for the receiver. Slate:",
        .external_wallet = &external_wallet,
        // Epic's wallet reaches its node over plain HTTP and doesn't care whose
        // node it is, so the user gets the choice — ours, or one that already
        // has the chain. The only coin wired for this; see `Coin.node_source`
        // for why it's two flat hooks rather than a capability struct.
        .node_source = vtNodeSource,
        .set_node_source = vtSetNodeSource,
        .node_default_remote = default_remote_node,
        .node_address_example = node_address_example,
    };

    fn vtNodeSource(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        install_root: []const u8,
        buf: []u8,
    ) []const u8 {
        return refreshNodeSource(allocator, install_root, buf);
    }

    fn vtSetNodeSource(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home_dir: []const u8,
        url: []const u8,
    ) anyerror!void {
        return setNodeSource(allocator, install_root, home_dir, url);
    }

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

    // Same wallet-process auth as the transactions hook.
    fn vtWalletReceiveAddress(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        force_new: bool,
    ) anyerror![]const u8 {
        return epicReceiveAddress(allocator, wallet_auth, force_new);
    }

    // Same wallet-process auth as the transactions hook.
    fn vtWalletSend(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        address: []const u8,
        amount: f64,
    ) anyerror!models.SendResult {
        return epicSend(allocator, wallet_auth, address, amount, "");
    }

    fn vtWalletSendNote(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        address: []const u8,
        amount: f64,
        note: []const u8,
    ) anyerror!models.SendResult {
        return epicSend(allocator, wallet_auth, address, amount, note);
    }

    fn vtWalletCancelTx(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        txid: []const u8,
    ) anyerror!models.SendResult {
        return epicCancelTx(allocator, wallet_auth, txid);
    }

    fn vtWalletSendFee(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        wallet_auth: models.CoinAuth,
        address: []const u8,
        amount: f64,
    ) anyerror!models.FeeEstimate {
        return epicSendFee(allocator, wallet_auth, address, amount);
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
    const toml = try Epic.defaultWalletToml(
        a,
        "/home/alice/.epic/main",
        "http://127.0.0.1:3413",
        "/home/alice/.epic/main/.foreign_api_secret",
    );
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
    // `epic-wallet --offline_mode -c <top> owner_api`: a wallet that only serves
    // the password typed at its prompt, brought up before the node syncs, pinned to
    // the managed config dir. The password is nowhere on its command line.
    const top = try Epic.dataDir(a, home);
    defer a.free(top);
    try expectWalletArgv(argv, top, &.{ "owner_api", "--run_foreign" });

    // A non-empty per-session secret was written verbatim (no trailing newline), and
    // the config was generated + healed to localhost.
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

test "listenerArgv builds `epic-wallet --offline_mode -c <top> listen -m epicbox`" {
    const a = std.testing.allocator;
    const argv = try Epic.listenerArgv(a, "/opt/bw", "/home/u", "walletpw9");
    defer {
        for (argv) |s| a.free(s);
        a.free(argv);
    }
    // Offline mode, or it exits the moment the node is unreachable or syncing; the
    // same managed config dir the Owner-API server is pinned to.
    const top = try Epic.dataDir(a, "/home/u");
    defer a.free(top);
    try expectWalletArgv(argv, top, &.{ "listen", "-m", "epicbox" });
}

/// `<bin> --offline_mode [-p walletpw9] -c <top> <tail…>`: the `-p` pair only
/// where the password can't be typed on a terminal — and where it can, the
/// password appears in no argument at all.
fn expectWalletArgv(argv: []const []const u8, top: []const u8, tail: []const []const u8) !void {
    try std.testing.expect(std.mem.endsWith(u8, argv[0], Epic.wallet_file));
    try std.testing.expectEqualStrings("--offline_mode", argv[1]);
    var i: usize = 2;
    if (!Epic.pass_on_tty) {
        try std.testing.expectEqualStrings("-p", argv[2]);
        try std.testing.expectEqualStrings("walletpw9", argv[3]);
        i = 4;
    } else {
        for (argv) |arg| try std.testing.expect(std.mem.indexOf(u8, arg, "walletpw9") == null);
    }
    try std.testing.expectEqualStrings("-c", argv[i]);
    try std.testing.expectEqualStrings(top, argv[i + 1]);
    try std.testing.expectEqual(i + 2 + tail.len, argv.len);
    for (tail, argv[i + 2 ..]) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "Epic runs its Epicbox listener while unlocked" {
    var e: Epic = .{};
    const c = e.coin();
    try std.testing.expect(c.walletHasListener());
    try std.testing.expectEqualStrings("Epicbox listener", c.externalWallet().?.listener_name);
}

test "launchServerArgv caches the Epicbox index an existing config already sets" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-epic-wallet-epicbox-index-home";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer Epic.epicbox_index.store(0, .release);

    // A config the user (or another app) already set up with index 2: the heal
    // leaves `[epicbox]` alone, and the address asked for must match it.
    const top = try Epic.dataDir(a, home);
    defer a.free(top);
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, top, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = Epic.wallet_conf_file, .data = "[wallet]\n[epicbox]\nepicbox_address_index = 2\n" });

    const argv = try Epic.launchServerArgv(a, "/opt/bw", home, Epic.wallet_rpc_port, "walletpw9");
    defer {
        for (argv) |s| a.free(s);
        a.free(argv);
    }
    try std.testing.expectEqual(@as(u32, 2), Epic.epicbox_index.load(.acquire));
}

test "scanArgv builds `epic-wallet -t <top> scan` for the recovery scan" {
    const a = std.testing.allocator;
    const argv = try Epic.scanArgv(a, "/opt/bw", "/home/alice", "walletpw9");
    defer {
        for (argv) |s| a.free(s);
        a.free(argv);
    }
    // `epic-wallet -t <top> scan`: a full repair scan pinned to the managed data
    // dir (no `--offline_mode` — it must reach the node to restore outputs). The
    // password is typed at its prompt; `-p <pw>` only where it can't be.
    try std.testing.expectEqual(@as(usize, if (Epic.pass_on_tty) 4 else 6), argv.len);
    try std.testing.expect(std.mem.endsWith(u8, argv[0], Epic.wallet_file));
    try std.testing.expectEqualStrings("-t", argv[1]);
    const top = try Epic.dataDir(a, "/home/alice");
    defer a.free(top);
    try std.testing.expectEqualStrings(top, argv[2]);
    if (Epic.pass_on_tty) {
        for (argv) |arg| try std.testing.expect(std.mem.indexOf(u8, arg, "walletpw9") == null);
    } else {
        try std.testing.expectEqualStrings("-p", argv[3]);
        try std.testing.expectEqualStrings("walletpw9", argv[4]);
    }
    try std.testing.expectEqualStrings("scan", argv[argv.len - 1]);
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

test "parseTxLog reads the older tuple reply newest-first, dropping cancelled entries" {
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

    const txs = try Epic.parseTxLog(allocator, inner, 32, 0);
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
    const capped = try Epic.parseTxLog(allocator, inner, 1, 0);
    defer allocator.free(capped);
    try std.testing.expectEqual(@as(usize, 1), capped.len);
    try std.testing.expectEqual(models.TxDirection.sent, capped[0].direction);
}

test "parseTxLog reads 4.x's paged reply: stages, slate ids, and what can be cancelled" {
    const allocator = std.testing.allocator;

    // The shape epic-wallet 4.x returned for wallet B in the spike (subset of
    // fields): a send the receiver never answered, a send in the mempool, a
    // confirmed send and receive, and a cancelled send that must be dropped.
    const inner =
        \\{"id":1,"jsonrpc":"2.0","result":{"Ok":{"pager":{"limit":20,"offset":0,"records_read":5,"sort_order":"desc","total_records":5},"refresh_from_node":true,"txs":[
        \\{"id":4,"tx_type":"TxSentCreated","tx_slate_id":"19763226-1dd5-4b89-bf76-d03978a92cd4","creation_ts":"2026-09-23T18:23:00Z","confirmed":false,"amount_credited":"2400000","amount_debited":"4200000","public_addr":"esXh3H6asayjCMuyGDepZuhX6pQ7B7w6wyGnXLDcK3cBNMC93B5k@epicbox.epiccash.com"},
        \\{"id":3,"tx_type":"TxSentMempool","tx_slate_id":"aaaaaaaa-1dd5-4b89-bf76-d03978a92cd4","creation_ts":"2026-09-23T18:20:00Z","confirmed":false,"amount_credited":"0","amount_debited":"1000000"},
        \\{"id":2,"tx_type":"TxSentCancelled","tx_slate_id":"bbbbbbbb-1dd5-4b89-bf76-d03978a92cd4","creation_ts":"2026-09-23T18:10:00Z","confirmed":false,"amount_credited":"0","amount_debited":"1000000"},
        \\{"id":1,"tx_type":"TxSent","tx_slate_id":"45ac41a0-7812-47ca-baa6-0021c2e8db0d","creation_ts":"2026-09-23T17:50:00Z","confirmed":true,"amount_credited":"4200000","amount_debited":"10000000"},
        \\{"id":0,"tx_type":"TxReceived","tx_slate_id":"f75efd84-31cd-429a-bb9c-756a640d8cea","creation_ts":"2026-09-23T17:19:00Z","confirmed":true,"amount_credited":"10000000","amount_debited":"0"}
        \\]}}}
    ;
    const created = Epic.parseRfc3339("2026-09-23T18:23:00Z").?;

    // Five minutes on: the unanswered send isn't cancellable yet — it could be
    // one that was only just posted.
    {
        const txs = try Epic.parseTxLog(allocator, inner, 32, created + 5 * 60);
        defer allocator.free(txs);
        try std.testing.expectEqual(@as(usize, 4), txs.len);
        try std.testing.expectEqual(models.TxStage.awaiting_counterparty, txs[0].stage);
        try std.testing.expectEqualStrings("19763226-1dd5-4b89-bf76-d03978a92cd4", txs[0].txid());
        try std.testing.expectApproxEqAbs(@as(f64, 0.018), txs[0].amount, 1e-9);
        try std.testing.expect(!txs[0].cancellable);
        try std.testing.expectEqual(models.TxStage.in_mempool, txs[1].stage);
        try std.testing.expect(!txs[1].cancellable);
        // Confirmed rows carry no stage, whatever their type.
        try std.testing.expectEqual(models.TxStage.none, txs[2].stage);
        try std.testing.expect(txs[2].confirmations > 0);
        try std.testing.expectEqual(models.TxDirection.received, txs[3].direction);
    }
    // Ten minutes on it is — and it's the only one.
    {
        const txs = try Epic.parseTxLog(allocator, inner, 32, created + 10 * 60);
        defer allocator.free(txs);
        try std.testing.expect(txs[0].cancellable);
        for (txs[1..]) |t| try std.testing.expect(!t.cancellable);
    }
    // A send with no counterparty address went as a slate file: it says it's
    // waiting for the reply *file*, and is cancellable on the same terms.
    {
        const file_send =
            \\{"result":{"Ok":{"txs":[{"tx_type":"TxSentCreated","tx_slate_id":"65a93004-bb00-42f4-b51a-727da3783ed7","creation_ts":"2026-09-23T18:23:00Z","confirmed":false,"amount_credited":"0","amount_debited":"1","public_addr":null}]}}}
        ;
        const txs = try Epic.parseTxLog(allocator, file_send, 32, created + 10 * 60);
        defer allocator.free(txs);
        try std.testing.expectEqual(models.TxStage.awaiting_reply_file, txs[0].stage);
        try std.testing.expect(txs[0].cancellable);
    }

}

test "parseTxLog carries the slate message as the row's note, made safe to show" {
    const allocator = std.testing.allocator;
    // The sender's message is participant 0's; the receiver's side is empty. A
    // row with no messages at all (null) has no note.
    const inner =
        \\{"id":1,"jsonrpc":"2.0","result":{"Ok":{"pager":{},"txs":[
        \\{"tx_type":"TxReceived","tx_slate_id":"f75efd84-31cd-429a-bb9c-756a640d8cea","creation_ts":"2026-09-23T17:19:00Z","confirmed":true,"amount_credited":"10000000","amount_debited":"0",
        \\ "messages":{"messages":[{"id":"0","public_key":"02ab","message":"rent \u001b[2J for May","message_sig":"cd"},{"id":"1","public_key":"03ef","message":null,"message_sig":null}]}},
        \\{"tx_type":"TxSent","tx_slate_id":"45ac41a0-7812-47ca-baa6-0021c2e8db0d","creation_ts":"2026-09-23T17:10:00Z","confirmed":true,"amount_credited":"0","amount_debited":"10000000","messages":null,
        \\ "public_addr":"esXBF4QgPnTk64M1ky2DeBTCvKXNBwKp3mfnHTbzAKU2wagigz6J@epicbox.epiccash.com"}
        \\]}}}
    ;
    const txs = try Epic.parseTxLog(allocator, inner, 32, 0);
    defer allocator.free(txs);
    try std.testing.expectEqual(@as(usize, 2), txs.len);
    try std.testing.expectEqualStrings("rent [2J for May", txs[0].note());
    try std.testing.expectEqualStrings("", txs[1].note());
    // An unexpected shape costs the row its extras, not the list its rows.
    {
        const odd =
            \\{"result":{"Ok":{"txs":[{"tx_type":"TxReceived","creation_ts":"2026-09-23T17:19:00Z","confirmed":true,
            \\ "amount_credited":"1","amount_debited":"0","public_addr":{"x":1},"messages":[1,2]}]}}}
        ;
        const odd_txs = try Epic.parseTxLog(allocator, odd, 32, 0);
        defer allocator.free(odd_txs);
        try std.testing.expectEqual(@as(usize, 1), odd_txs.len);
        try std.testing.expectEqualStrings("", odd_txs[0].address());
        try std.testing.expectEqualStrings("", odd_txs[0].note());
    }
    // Who it went to — the CLI's "From/To Address"; absent, nothing.
    try std.testing.expectEqualStrings("esXBF4QgPnTk64M1ky2DeBTCvKXNBwKp3mfnHTbzAKU2wagigz6J@epicbox.epiccash.com", txs[1].address());
    try std.testing.expectEqualStrings("", txs[0].address());
}

test "a note rides the Epic send; one too long is refused, not dropped" {
    var e: Epic = .{};
    const c = e.coin();
    try std.testing.expectEqual(models.tx_note_max, c.sendNoteMax());
    const long = "x" ** (models.tx_note_max + 1);
    const res = try c.walletSendNote(std.testing.allocator, .{ .rpc_user = "", .rpc_password = "", .ip_address = "", .port = "" }, "addr", 1, long);
    try std.testing.expectEqualStrings("The note is too long.", res.failed);
}

test "parseSlateShape reads a V3 slate's id, amounts, signers and note" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The fields epic-wallet 4.0 writes (subset), as the spike's slate had them.
    const slate =
        \\{"version_info":{"version":3,"orig_version":3,"block_header_version":6},"num_participants":2,
        \\ "id":"438032f8-9083-4092-942e-fa9189c8b826","tx":{},"amount":"1000000","fee":"800000","height":"3724902",
        \\ "lock_height":"0","ttl_cutoff_height":null,"payment_proof":null,
        \\ "participant_data":[{"id":"0","public_blind_excess":"02ab","public_nonce":"03cd","part_sig":null,"message":"slate file spike","message_sig":"ef"}]}
    ;
    const shape = Epic.parseSlateShape(a, slate).?;
    try std.testing.expectEqualStrings("438032f8-9083-4092-942e-fa9189c8b826", shape.id);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), shape.amount, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.008), shape.fee, 1e-12);
    try std.testing.expectEqual(@as(usize, 1), shape.participants);
    try std.testing.expectEqualStrings("slate file spike", shape.note);

    // Not a slate: no id, a bad id, no participant data, not JSON.
    try std.testing.expect(Epic.parseSlateShape(a, "{\"amount\":\"1\",\"fee\":\"1\",\"participant_data\":[]}") == null);
    try std.testing.expect(Epic.parseSlateShape(a, "{\"id\":\"nope\",\"amount\":\"1\",\"fee\":\"1\",\"participant_data\":[]}") == null);
    try std.testing.expect(Epic.parseSlateShape(a, "{\"id\":\"438032f8-9083-4092-942e-fa9189c8b826\",\"amount\":\"1\",\"fee\":\"1\"}") == null);
    try std.testing.expect(Epic.parseSlateShape(a, "wallet.dat bytes") == null);
}

test "a slate is received, finalized, or refused — by its signers and this wallet's log" {
    const V = Epic.slateVerdict;
    // A fresh payment from someone else: receive it.
    try std.testing.expectEqual(models.SlateKind.receive, V(1, .{}).?);
    // Our own outgoing slate, opened by mistake: never "receive" it.
    try std.testing.expect(V(1, .{ .sent_open = true }) == null);
    try std.testing.expectStringStartsWith(Epic.slateRefusal(1, .{ .sent_open = true }), "This is your own send");
    // Already received once.
    try std.testing.expect(V(1, .{ .received = true }) == null);

    // The reply to our waiting send: finalize it.
    try std.testing.expectEqual(models.SlateKind.finalize, V(2, .{ .sent_open = true }).?);
    // …but not one already completed, cancelled, or never ours.
    try std.testing.expect(V(2, .{ .sent_open = true, .sent_done = true }) == null);
    try std.testing.expect(V(2, .{ .sent_cancelled = true }) == null);
    try std.testing.expectStringStartsWith(Epic.slateRefusal(2, .{ .sent_cancelled = true }), "You cancelled this send");
    try std.testing.expect(V(2, .{}) == null);
    try std.testing.expectStringStartsWith(Epic.slateRefusal(2, .{}), "This isn't the reply");
    // Our own response to someone else's payment isn't ours to finalize.
    try std.testing.expect(V(2, .{ .received = true }) == null);
    try std.testing.expectStringStartsWith(Epic.slateRefusal(2, .{ .received = true }), "This is the reply you made");
    // Anything else is no slate we know.
    try std.testing.expect(V(3, .{}) == null);
}

test "parseSlateLog folds a slate id's log entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const open =
        \\{"result":{"Ok":{"pager":{},"txs":[{"tx_type":"TxSentCreated","confirmed":false}]}}}
    ;
    try std.testing.expect((try Epic.parseSlateLog(a, open)).sent_open);
    const cancelled_rx =
        \\{"result":{"Ok":{"pager":{},"txs":[{"tx_type":"TxReceivedCancelled","confirmed":false}]}}}
    ;
    const l = try Epic.parseSlateLog(a, cancelled_rx);
    try std.testing.expect(l.received_cancelled and !l.received);
    const none =
        \\{"result":{"Ok":{"pager":{},"txs":[]}}}
    ;
    try std.testing.expectEqual(Epic.SlateLog{}, try Epic.parseSlateLog(a, none));
}

test "a send finalized from its slate this session isn't offered for cancelling" {
    const id = "65a93004-bb00-42f4-b51a-727da3783ed7";
    var rows = [_]models.WalletTx{
        .{ .direction = .sent, .amount = 0.018, .time = 1, .confirmations = 0, .stage = .awaiting_counterparty, .cancellable = true },
        .{ .direction = .sent, .amount = 0.018, .time = 1, .confirmations = 0, .stage = .awaiting_counterparty, .cancellable = true },
    };
    rows[0].setTxid(id);
    rows[1].setTxid("aaaaaaaa-bb00-42f4-b51a-727da3783ed7");
    Epic.Finalized.apply(&rows);
    // Nothing remembered yet: both still waiting.
    try std.testing.expect(rows[0].cancellable and rows[1].cancellable);

    Epic.Finalized.add(id);
    Epic.Finalized.apply(&rows);
    try std.testing.expectEqual(models.TxStage.in_mempool, rows[0].stage);
    try std.testing.expect(!rows[0].cancellable);
    // Another send is untouched.
    try std.testing.expect(rows[1].cancellable);
    try std.testing.expect(Epic.Finalized.has(id));
    try std.testing.expect(!Epic.Finalized.has("not-an-id"));
}

test "a second finalize is reported as already finished, not as wallet internals" {
    try std.testing.expect(Epic.alreadyFinalized("NotFoundErr: Slate id: [65, a9, 30, 4, bb, 0, 42, f4, b5, 1a, 72, 7d, a3, 78, 3e, d7]"));
    try std.testing.expect(!Epic.alreadyFinalized("NotEnoughFunds: {}"));
}

test "a reply is named like epic-wallet's CLI names it, beside the payment file" {
    const a = std.testing.allocator;
    const p = try Epic.replyPath(a, "/home/u/Downloads/65a93004-bb00-42f4-b51a-727da3783ed7.tx");
    defer a.free(p);
    try std.testing.expectEqualStrings("/home/u/Downloads/65a93004-bb00-42f4-b51a-727da3783ed7.tx.response", p);
    const bare = try Epic.replyPath(a, "pay.tx");
    defer a.free(bare);
    try std.testing.expectEqualStrings("pay.tx.response", bare);

    // What a "pick their reply" browser shows: ours (and the CLI's), and the
    // name Epic's GUI wallet suggests.
    const sf = &Epic.slate_files;
    try std.testing.expect(sf.isReplyName("finalize_65a93004-bb00-42f4-b51a-727da3783ed7.tx"));
    try std.testing.expect(sf.isReplyName("65a93004-bb00-42f4-b51a-727da3783ed7.tx.response"));
    try std.testing.expect(!sf.isReplyName("65a93004-bb00-42f4-b51a-727da3783ed7.tx"));
    try std.testing.expect(!sf.isReplyName("finalize_notes.txt"));
    try std.testing.expect(!sf.isReplyName("wallet.dat"));

    // And what a "receive a payment file" browser shows: payments, not replies.
    try std.testing.expect(sf.isPaymentName("65a93004-bb00-42f4-b51a-727da3783ed7.tx"));
    try std.testing.expect(!sf.isPaymentName("65a93004-bb00-42f4-b51a-727da3783ed7.tx.response"));
    try std.testing.expect(!sf.isPaymentName("finalize_65a93004-bb00-42f4-b51a-727da3783ed7.tx"));
    try std.testing.expect(!sf.isPaymentName("holiday.jpg"));
}

test "Epic pays by slate file" {
    var e: Epic = .{};
    try std.testing.expect(e.coin().supportsSlateFiles());
    try std.testing.expectEqualStrings("tx", e.coin().slateFiles().?.extension);
}

test "parseCancelReply and isUuid: a cancel is only ever of a real slate id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try Epic.parseCancelReply(a, "{\"id\":1,\"jsonrpc\":\"2.0\",\"result\":{\"Ok\":null}}")) == .ok);
    const refused = try Epic.parseCancelReply(a, "{\"error\":{\"code\":-32099,\"message\":\"TransactionDoesntExist\"},\"id\":1}");
    try std.testing.expectEqualStrings("TransactionDoesntExist", refused.failed);

    try std.testing.expect(Epic.isUuid("19763226-1dd5-4b89-bf76-d03978a92cd4"));
    try std.testing.expect(!Epic.isUuid("19763226-1dd5-4b89-bf76-d03978a92cd"));
    try std.testing.expect(!Epic.isUuid("19763226x1dd5-4b89-bf76-d03978a92cd4"));
    try std.testing.expect(!Epic.isUuid("19763226-1dd5-4b89-bf76-d03978a92c\"}"));

    var e: Epic = .{};
    try std.testing.expect(e.coin().supportsCancelTx());
}

test "txKind maps epic-wallet's TxLogEntryType names" {
    try std.testing.expectEqual(models.TxDirection.received, Epic.txKind("TxReceived").?.direction);
    try std.testing.expectEqual(models.TxDirection.sent, Epic.txKind("TxSent").?.direction);
    // A coinbase the wallet mined itself.
    try std.testing.expectEqual(models.TxDirection.stake, Epic.txKind("ConfirmedCoinbase").?.direction);
    try std.testing.expectEqual(models.TxStage.awaiting_counterparty, Epic.txKind("TxSentCreated").?.stage);
    try std.testing.expectEqual(models.TxStage.in_mempool, Epic.txKind("TxSentMempool").?.stage);
    try std.testing.expectEqual(models.TxStage.in_mempool, Epic.txKind("TxReceivedMempool").?.stage);
    // Cancelled entries have no direction — dropped.
    try std.testing.expect(Epic.txKind("TxReceivedCancelled") == null);
    try std.testing.expect(Epic.txKind("TxSentCancelled") == null);
    try std.testing.expect(Epic.txKind("something-unknown") == null);
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

test "coin vtable exposes transactions, the Epicbox receive address, and send" {
    var e: Epic = .{};
    const c = e.coin();
    try std.testing.expect(c.supportsTransactions());
    try std.testing.expect(c.supportsReceiveAddress());
    try std.testing.expect(c.supportsSend());
}

test "baseUnitsFromAmount converts whole EPIC to 1e8 base units, refusing nonsense" {
    try std.testing.expectEqual(@as(?u64, 10_000_000), Epic.baseUnitsFromAmount(0.1));
    try std.testing.expectEqual(@as(?u64, 500_000_000), Epic.baseUnitsFromAmount(5));
    try std.testing.expectEqual(@as(?u64, 1), Epic.baseUnitsFromAmount(0.00000001));
    // Zero, negative, below one base unit, NaN/inf: not an amount.
    try std.testing.expectEqual(@as(?u64, null), Epic.baseUnitsFromAmount(0));
    try std.testing.expectEqual(@as(?u64, null), Epic.baseUnitsFromAmount(-1));
    try std.testing.expectEqual(@as(?u64, null), Epic.baseUnitsFromAmount(0.000000001));
    try std.testing.expectEqual(@as(?u64, null), Epic.baseUnitsFromAmount(std.math.nan(f64)));
    try std.testing.expectEqual(@as(?u64, null), Epic.baseUnitsFromAmount(std.math.inf(f64)));
}

test "isEpicboxAddress accepts epic-wallet's forms and catches a mistyped key" {
    const key = "esXBF4QgPnTk64M1ky2DeBTCvKXNBwKp3mfnHTbzAKU2wagigz6J";
    try std.testing.expect(Epic.isEpicboxAddress(key ++ "@epicbox.epiccash.com"));
    try std.testing.expect(Epic.isEpicboxAddress(key));
    try std.testing.expect(Epic.isEpicboxAddress("epicbox://" ++ key ++ "@epicbox.epiccash.com:443"));
    try std.testing.expect(Epic.isEpicboxAddress("esaA6Jg7qBKgufT4C58HucCcW9h3zVY39G5eVPNrNc38J69h9YHP@epicbox.epiccash.com"));

    // One character wrong: the checksum catches it — the same address
    // epic-wallet refused with "Invalid base58 checksum".
    try std.testing.expect(!Epic.isEpicboxAddress("esXBF4QgPnTk64M1ky2DeBTCvKXNBwKp3mfnHTbzAKU2wagigz6X@epicbox.epiccash.com"));
    // Cut short, not base58, an http URL, a bad domain or port.
    try std.testing.expect(!Epic.isEpicboxAddress("esXBF4QgPnTk64M1ky2DeBTCvKXNBwKp3mfnHTbzAKU2wagig@epicbox.epiccash.com"));
    try std.testing.expect(!Epic.isEpicboxAddress("es0BF4QgPnTk64M1ky2DeBTCvKXNBwKp3mfnHTbzAKU2wagigz6J"));
    try std.testing.expect(!Epic.isEpicboxAddress("http://127.0.0.1:3415"));
    try std.testing.expect(!Epic.isEpicboxAddress(key ++ "@"));
    try std.testing.expect(!Epic.isEpicboxAddress(key ++ "@evil.example/path"));
    try std.testing.expect(!Epic.isEpicboxAddress(key ++ "@epicbox.epiccash.com:99999"));
    try std.testing.expect(!Epic.isEpicboxAddress(""));
}

test "the fee quote is read off the estimate's slate, and a success isn't a refusal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The shape `init_send_tx` returned for `estimate_only` in the spike: the
    // selected input as `amount`, the fee in base units.
    const est =
        \\{"id":1,"jsonrpc":"2.0","result":{"Ok":{"amount":"500000000","fee":"800000"}}}
    ;
    try std.testing.expectEqual(@as(?f64, 0.008), Epic.parseSlateFee(a, est));
    try std.testing.expect((try Epic.sendRefusal(a, est)) == null);
    try std.testing.expectEqual(@as(?f64, null), Epic.parseSlateFee(a, "{\"result\":{\"Ok\":{}}}"));
    try std.testing.expect((try Epic.sendRefusal(a, "{\"result\":{\"Ok\":null}}")) != null);
}

test "Epic quotes a send's fee and names what a send returns" {
    var e: Epic = .{};
    const c = e.coin();
    try std.testing.expect(c.supportsSendFee());
    try std.testing.expect(std.mem.indexOf(u8, c.sendOkLabel(), "Slate") != null);
}

test "parseSendReply: success names the slate and what happens next" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try Epic.parseSendReply(a,
        \\{"id":1,"jsonrpc":"2.0","result":{"Ok":{"id":"f75efd84-31cd-429a-bb9c-756a640d8cea","amount":"10000000","fee":"800000"}}}
    );
    try std.testing.expect(r == .ok);
    try std.testing.expect(std.mem.startsWith(u8, r.ok, "f75efd84-31cd-429a-bb9c-756a640d8cea"));
    try std.testing.expect(std.mem.indexOf(u8, r.ok, "once the receiver accepts it") != null);
}

test "parseSendReply: refusals read as sentences, with the wallet's own figures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The exact reply epic-wallet gave for a send larger than the wallet holds.
    const funds = try Epic.parseSendReply(a,
        \\{"error":{"code":-32099,"message":"NotEnoughFunds: {\"available\":20000000,\"available_disp\":\"0.20000000\",\"needed\":100300000,\"needed_disp\":\"1.00300000\"}"},"id":1,"jsonrpc":"2.0"}
    );
    try std.testing.expect(funds == .failed);
    try std.testing.expect(std.mem.indexOf(u8, funds.failed, "0.2 available, 1.003 needed including the fee") != null);
    try std.testing.expect(std.mem.indexOf(u8, funds.failed, "10 confirmations") != null);

    // Anything else: the wallet's own words.
    const bad = try Epic.parseSendReply(a,
        \\{"error":{"code":-32099,"message":"LibWallet: LibWallet Error: Invalid base58 checksum"},"id":1,"jsonrpc":"2.0"}
    );
    try std.testing.expectEqualStrings("LibWallet: LibWallet Error: Invalid base58 checksum", bad.failed);

    // Nothing usable at all still says something.
    try std.testing.expect((try Epic.parseSendReply(a, "{}")) == .failed);
    try std.testing.expect((try Epic.parseSendReply(a, "not json")) == .failed);
}

test "parsePublicAddress spells the Epicbox address the way a sender types it" {
    const a = std.testing.allocator;
    const key = "esXBF4QgPnTk64M1ky2DeBTCvKXNBwKp3mfnHTbzAKU2wagigz6J";

    // The default port is left off, exactly as epic-wallet prints it.
    const plain = try Epic.parsePublicAddress(a,
        \\{"id":1,"jsonrpc":"2.0","result":{"Ok":{"domain":"epicbox.epiccash.com","port":443,"public_key":"esXBF4QgPnTk64M1ky2DeBTCvKXNBwKp3mfnHTbzAKU2wagigz6J"}}}
    );
    defer a.free(plain);
    try std.testing.expectEqualStrings(key ++ "@epicbox.epiccash.com", plain);

    // Any other port has to travel with the address, or the sender posts to the
    // wrong relay port.
    const custom = try Epic.parsePublicAddress(a,
        \\{"result":{"Ok":{"domain":"relay.example","port":8443,"public_key":"esXBF4QgPnTk64M1ky2DeBTCvKXNBwKp3mfnHTbzAKU2wagigz6J"}}}
    );
    defer a.free(custom);
    try std.testing.expectEqualStrings(key ++ "@relay.example:8443", custom);
}

test "parsePublicAddress refuses anything a sender's wallet wouldn't parse" {
    const a = std.testing.allocator;
    // An Err reply.
    try std.testing.expectError(error.WalletReceiveAddressFailed, Epic.parsePublicAddress(a,
        \\{"result":{"Err":{"GenericError":"no wallet"}}}
    ));
    // A key that isn't 52 base58 characters ('0' isn't base58).
    try std.testing.expectError(error.BadEpicboxAddress, Epic.parsePublicAddress(a,
        \\{"result":{"Ok":{"domain":"epicbox.epiccash.com","port":443,"public_key":"es0BF4QgPnTk64M1ky2DeBTCvKXNBwKp3mfnHTbzAKU2wagigz6J"}}}
    ));
    try std.testing.expectError(error.BadEpicboxAddress, Epic.parsePublicAddress(a,
        \\{"result":{"Ok":{"domain":"epicbox.epiccash.com","port":443,"public_key":"esXBF4"}}}
    ));
    // A domain with characters outside the parser's set, or none at all.
    try std.testing.expectError(error.BadEpicboxAddress, Epic.parsePublicAddress(a,
        \\{"result":{"Ok":{"domain":"evil.example/x","port":443,"public_key":"esXBF4QgPnTk64M1ky2DeBTCvKXNBwKp3mfnHTbzAKU2wagigz6J"}}}
    ));
    try std.testing.expectError(error.BadEpicboxAddress, Epic.parsePublicAddress(a,
        \\{"result":{"Ok":{"domain":"","port":443,"public_key":"esXBF4QgPnTk64M1ky2DeBTCvKXNBwKp3mfnHTbzAKU2wagigz6J"}}}
    ));
    // Longer than a front-end can hold without truncating it.
    const long_domain = "a" ** 80;
    try std.testing.expectError(error.BadEpicboxAddress, Epic.parsePublicAddress(a, "{\"result\":{\"Ok\":{\"domain\":\"" ++ long_domain ++
        "\",\"port\":443,\"public_key\":\"esXBF4QgPnTk64M1ky2DeBTCvKXNBwKp3mfnHTbzAKU2wagigz6J\"}}}"));
}

test "epicboxIndexFromToml reads only a live key inside [epicbox]" {
    // Absent: epic-wallet's default.
    try std.testing.expectEqual(@as(u32, 0), Epic.epicboxIndexFromToml("[wallet]\nchain_type = \"Mainnet\"\n"));
    // Set, with a trailing comment and CRLF endings.
    try std.testing.expectEqual(@as(u32, 3), Epic.epicboxIndexFromToml(
        "[wallet]\r\nx = 1\r\n[epicbox]\r\nepicbox_domain = \"epicbox.epiccash.com\"\r\nepicbox_address_index = 3 # mine\r\n",
    ));
    // Commented out, or in another section: not what the wallet uses.
    try std.testing.expectEqual(@as(u32, 0), Epic.epicboxIndexFromToml("[epicbox]\n# epicbox_address_index = 7\n"));
    try std.testing.expectEqual(@as(u32, 0), Epic.epicboxIndexFromToml("[tor]\nepicbox_address_index = 7\n[epicbox]\n"));
    // Garbage reads as the default rather than a wrong index.
    try std.testing.expectEqual(@as(u32, 0), Epic.epicboxIndexFromToml("[epicbox]\nepicbox_address_index = -1\n"));
    // The template BoxWallet writes.
    const tmpl = try Epic.defaultWalletToml(std.testing.allocator, "/top", "http://127.0.0.1:3413", "");
    defer std.testing.allocator.free(tmpl);
    try std.testing.expectEqual(@as(u32, 0), Epic.epicboxIndexFromToml(tmpl));
}

test "normalizeNodeUrl fills in the scheme and the API port" {
    var buf: [Coin.node_url_max]u8 = undefined;
    // A bare host is the likeliest thing a user pastes.
    try std.testing.expectEqualStrings("http://node.example:3413", try Epic.normalizeNodeUrl("node.example", &buf));
    // Either half may already be there.
    try std.testing.expectEqualStrings("http://node.example:3413", try Epic.normalizeNodeUrl("http://node.example", &buf));
    try std.testing.expectEqualStrings("http://node.example:3500", try Epic.normalizeNodeUrl("node.example:3500", &buf));
    try std.testing.expectEqualStrings("https://node.example:443", try Epic.normalizeNodeUrl("https://node.example:443", &buf));
    // https is kept, never invented: Epic node APIs are plain HTTP unless the
    // operator put a proxy in front, and an upgrade would fail every plain node.
    try std.testing.expectEqualStrings("http://1.2.3.4:3413", try Epic.normalizeNodeUrl("1.2.3.4", &buf));
    // Surrounding whitespace and one trailing slash are a paste, not a mistake.
    try std.testing.expectEqualStrings("http://node.example:3413", try Epic.normalizeNodeUrl("  node.example/ \n", &buf));
    // IPv6 keeps its brackets; only the colon after them is the port separator.
    try std.testing.expectEqualStrings("http://[::1]:3413", try Epic.normalizeNodeUrl("[::1]", &buf));
    try std.testing.expectEqualStrings("http://[::1]:3500", try Epic.normalizeNodeUrl("[::1]:3500", &buf));
}

test "normalizeNodeUrl refuses anything it can't state exactly" {
    var buf: [Coin.node_url_max]u8 = undefined;
    const bad = [_][]const u8{
        "", "   ", // nothing to connect to
        "/", "://", ":3413", // no host
        "node.example/v2/foreign", // a path we'd be guessing at
        "node.example?x=1", "node.example#f",
        "ftp://node.example", // not a protocol the wallet speaks
        "node.example:", "node.example:abc", "node.example:99999", // not a port
        "node example", "node.example\t3413", // whitespace inside
        "[::1", // unterminated literal
    };
    for (bad) |raw| {
        try std.testing.expectError(error.InvalidNodeUrl, Epic.normalizeNodeUrl(raw, &buf));
    }

    // Longer than the shared bound: refused outright rather than clipped to a
    // host that resolves somewhere else entirely.
    var long: [Coin.node_url_max + 32]u8 = undefined;
    @memset(&long, 'a');
    try std.testing.expectError(error.InvalidNodeUrl, Epic.normalizeNodeUrl(&long, &buf));
}

test "parseTipHeight reads the height out of a Foreign-API get_tip" {
    const a = std.testing.allocator;
    // Recorded verbatim from `node.epiccash.com:3413`, trimmed only in height.
    // Note `total_difficulty`: an *object*, one entry per proof-of-work, not the
    // single number a Grin node returns. Parsing only `height` (with unknown
    // fields ignored) is what makes that a non-event — a struct that tried to
    // read it as an integer would fail on every reply this node sends.
    const body =
        \\{"id":1,"jsonrpc":"2.0","result":{"Ok":{
        \\"height":3721651,
        \\"last_block_pushed":"6bb3e8dbebbe525f01acc1220f4c613af027a85a222bc7dc2b3c45944fccf2cd",
        \\"prev_block_to_last":"7927d2fda6b636b6efc98bcab7599311cf946c333f8684f6e40e2f73e25118bc",
        \\"total_difficulty":{"cuckaroo":29197286864,"cuckatoo":123914158912427,
        \\"progpow":8122885763517649584,"randomx":4574035486086225}}}}
    ;
    try std.testing.expectEqual(@as(i64, 3721651), try Epic.parseTipHeight(a, body));

    // An `Err`, a height of zero, and a body that isn't a reply at all are all
    // "this node has no chain to tell us about" rather than a parse crash.
    try std.testing.expectError(error.DaemonNotReady, Epic.parseTipHeight(a, "{\"result\":{\"Err\":\"boom\"}}"));
    try std.testing.expectError(error.DaemonNotReady, Epic.parseTipHeight(a, "{\"result\":{\"Ok\":{\"height\":0}}}"));
    try std.testing.expectError(error.DaemonNotReady, Epic.parseTipHeight(a, "{}"));
}

test "walletNodeKeys pairs each node with its own credential, never the other's" {
    const a = std.testing.allocator;
    const top = "/home/alice/.epic/main";
    defer Epic.NodeSource.set("");

    // Our own node: loopback, authenticated with the foreign secret it generates.
    Epic.NodeSource.set("");
    const local = try Epic.walletNodeKeys(a, top);
    defer local.deinit(a);
    try std.testing.expectEqualStrings("\"http://127.0.0.1:3413\"", local.addr);
    try std.testing.expectEqualStrings("\"/home/alice/.epic/main/.foreign_api_secret\"", local.secret_path);

    // Someone else's: their URL, and no secret — we have none for a node we
    // don't run, and handing over the local one would be both useless and wrong.
    Epic.NodeSource.set("http://node.example:3413");
    const remote = try Epic.walletNodeKeys(a, top);
    defer remote.deinit(a);
    try std.testing.expectEqualStrings("\"http://node.example:3413\"", remote.addr);
    try std.testing.expectEqualStrings("\"\"", remote.secret_path);
}

test "the wallet config is re-pointed in both directions, secret and all" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-epic-node-source-home";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer {
        std.Io.Dir.cwd().deleteTree(io, home) catch {};
        Epic.NodeSource.set("");
    }

    const top = try Epic.dataDir(a, home);
    defer a.free(top);

    const read = struct {
        fn conf(alloc: std.mem.Allocator, i: std.Io, dir_path: []const u8) ![]u8 {
            var dir = try std.Io.Dir.cwd().openDir(i, dir_path, .{});
            defer dir.close(i);
            var f = try dir.openFile(i, Epic.wallet_conf_file, .{});
            defer f.close(i);
            const buf = try alloc.alloc(u8, 8 * 1024);
            errdefer alloc.free(buf);
            const n = try f.readPositionalAll(i, buf, 0);
            return alloc.realloc(buf, n);
        }
    }.conf;

    // Born pointing at our own node.
    Epic.NodeSource.set("");
    try Epic.ensureWalletConfig(a, io, home);
    {
        const text = try read(a, io, top);
        defer a.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "check_node_api_http_addr = \"http://127.0.0.1:3413\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, ".foreign_api_secret\"") != null);
    }

    // Switched to a remote: the address moves *and* the local secret goes, so
    // the wallet can't be left presenting one node's credential to another.
    Epic.NodeSource.set("http://node.example:3413");
    try Epic.ensureWalletConfig(a, io, home);
    {
        const text = try read(a, io, top);
        defer a.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "check_node_api_http_addr = \"http://node.example:3413\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "node_api_secret_path = \"\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, ".foreign_api_secret") == null);
        // Everything else BoxWallet manages is untouched by the switch.
        try std.testing.expect(std.mem.indexOf(u8, text, "owner_api_listen_port = 3420") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "api_listen_interface = \"127.0.0.1\"") != null);
    }

    // And back again — the healing has to work in both directions, or a user who
    // changes their mind is left with a wallet that can't authenticate locally.
    Epic.NodeSource.set("");
    try Epic.ensureWalletConfig(a, io, home);
    {
        const text = try read(a, io, top);
        defer a.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "check_node_api_http_addr = \"http://127.0.0.1:3413\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, ".foreign_api_secret\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "node_api_secret_path = \"\"") == null);
    }
}

test "the node choice round-trips through boxwallet.conf, normalized" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-epic-node-choice-root";
    const home = "test-epic-node-choice-home";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer {
        std.Io.Dir.cwd().deleteTree(io, root) catch {};
        std.Io.Dir.cwd().deleteTree(io, home) catch {};
        Epic.NodeSource.set("");
    }

    var buf: [Coin.node_url_max]u8 = undefined;
    // Nothing stored yet: our own daemon.
    try std.testing.expectEqualStrings("", Epic.refreshNodeSource(a, root, &buf));
    try std.testing.expect(Epic.usesLocalDaemon());

    // What's stored is the *normalized* form, so the Settings tab reads back
    // exactly what the wallet was pointed at.
    try Epic.setNodeSource(a, root, home, "  node.example  ");
    try std.testing.expectEqualStrings("http://node.example:3413", Epic.refreshNodeSource(a, root, &buf));
    try std.testing.expect(!Epic.usesLocalDaemon());

    // A URL the coin can't use is refused, and leaves the stored one alone —
    // a typo must not silently strand the wallet on no node at all.
    try std.testing.expectError(error.InvalidNodeUrl, Epic.setNodeSource(a, root, home, "ftp://nope"));
    try std.testing.expectEqualStrings("http://node.example:3413", Epic.refreshNodeSource(a, root, &buf));

    // Empty restores our own daemon.
    try Epic.setNodeSource(a, root, home, "");
    try std.testing.expectEqualStrings("", Epic.refreshNodeSource(a, root, &buf));
    try std.testing.expect(Epic.usesLocalDaemon());
}

test "a stored value that no longer parses falls back to our own node" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-epic-node-garbage-root";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer {
        std.Io.Dir.cwd().deleteTree(io, root) catch {};
        Epic.NodeSource.set("");
    }

    // Hand-edited into something meaningless. The safe end of a setting we can't
    // read is the node BoxWallet controls — never a half-parsed host.
    try conf.setValue(a, io, root, conf.settings_file, Epic.node_setting_key, "not a url/at all");

    var buf: [Coin.node_url_max]u8 = undefined;
    try std.testing.expectEqualStrings("", Epic.refreshNodeSource(a, root, &buf));
    try std.testing.expect(Epic.usesLocalDaemon());
}

test "the suggested node normalizes to a usable address" {
    // Whatever is suggested has to survive the same grammar a typed one does —
    // a default the coin would then refuse is worse than no default.
    var buf: [Coin.node_url_max]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://node.epiccash.com:3413",
        try Epic.normalizeNodeUrl(Epic.default_remote_node, &buf),
    );

    // Both halves survive normalization unchanged. If either were dropped the
    // default would reach nothing: the apex has 3413 closed, and the node's
    // nginx rejects plain HTTP on it with a 400.
    try std.testing.expect(std.mem.startsWith(u8, Epic.default_remote_node, "https://"));
    try std.testing.expect(std.mem.indexOf(u8, Epic.default_remote_node, "node.epiccash.com") != null);
}

test "the suggested node is not the configured one" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-epic-node-default-root";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer {
        std.Io.Dir.cwd().deleteTree(io, root) catch {};
        Epic.NodeSource.set("");
    }

    // The whole point of it being a prefill: a fresh install is on its own
    // daemon, and nothing reaches the suggested node until someone picks it. If
    // this ever fails, BoxWallet has started shipping wallet queries to a third
    // party that nobody chose.
    var buf: [Coin.node_url_max]u8 = undefined;
    try std.testing.expectEqualStrings("", Epic.refreshNodeSource(a, root, &buf));
    try std.testing.expect(Epic.usesLocalDaemon());
}

test "splitHostPort takes a normalized URL apart for the reachability probe" {
    const ep = try Epic.splitHostPort("https://node.epiccash.com:3413");
    try std.testing.expectEqualStrings("node.epiccash.com", ep.host);
    try std.testing.expectEqual(@as(u16, 3413), ep.port);

    const plain = try Epic.splitHostPort("http://127.0.0.1:3413");
    try std.testing.expectEqualStrings("127.0.0.1", plain.host);

    // Anything that isn't the normalized shape is refused rather than guessed
    // at — the probe would otherwise dial whatever a bad split produced.
    try std.testing.expectError(error.InvalidNodeUrl, Epic.splitHostPort("node.epiccash.com"));
    try std.testing.expectError(error.InvalidNodeUrl, Epic.splitHostPort("https://:3413"));
    try std.testing.expectError(error.InvalidNodeUrl, Epic.splitHostPort(""));
}

// A wallet.seed written by epic-wallet 4.0.0 itself (`init -r`) for the public
// BIP39 test vector "abandon ×23 art" under the password "testpass" — no real
// wallet. Pins the encryption scheme `checkSeedFile` assumes to what the binary
// actually writes (its entropy decrypts to 32 zero bytes).
const test_seed_file =
    \\{
    \\  "encrypted_seed": "421998131e531650e69503716af0529d117330ef595b1c98357c130440d10d020b9356c4ceae4de6e51962d026129209",
    \\  "salt": "deef49a32fcb689a",
    \\  "nonce": "205f8b8a63b0a49ccca60d77"
    \\}
;

test "checkSeedFile opens epic-wallet's own wallet.seed with its password, and only that" {
    const a = std.testing.allocator;
    try Epic.checkSeedFile(a, test_seed_file, "testpass");
    try Epic.checkSeedFile(a, test_seed_file, null); // shape only
    try std.testing.expectError(error.WrongPassword, Epic.checkSeedFile(a, test_seed_file, "testpas"));
    try std.testing.expectError(error.WrongPassword, Epic.checkSeedFile(a, test_seed_file, ""));
}

test "checkSeedFile refuses anything that isn't a wallet.seed" {
    const a = std.testing.allocator;
    const bad = [_][]const u8{
        "",
        "not json",
        "{}",
        // A key dump, a Monero wallet — any JSON without the three fields.
        "{\"seed\":\"abandon abandon\"}",
        // Tag only: no entropy under it.
        "{\"encrypted_seed\":\"0b9356c4ceae4de6e51962d026129209\",\"salt\":\"deef49a32fcb689a\",\"nonce\":\"205f8b8a63b0a49ccca60d77\"}",
        // Nonce the wrong length for ChaCha20-Poly1305.
        "{\"encrypted_seed\":\"421998131e531650e69503716af0529d117330ef595b1c98357c130440d10d020b9356c4ceae4de6e51962d026129209\",\"salt\":\"deef49a32fcb689a\",\"nonce\":\"205f8b8a\"}",
        // Not hex.
        "{\"encrypted_seed\":\"zz\",\"salt\":\"deef49a32fcb689a\",\"nonce\":\"205f8b8a63b0a49ccca60d77\"}",
    };
    for (bad) |b| try std.testing.expectError(error.NotAWalletSeedFile, Epic.checkSeedFile(a, b, "testpass"));
}

test "the seed shown again is the words the wallet was made from" {
    // The fixture's wallet came from the BIP39 vector "abandon ×23 art", so
    // that is exactly what reading it back must give — and nothing for a wrong
    // password.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const home = "test-epic-wallet-showseed-home";
    cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, home) catch {};
    const no_auth: models.CoinAuth = .{ .rpc_user = "", .rpc_password = "", .ip_address = "127.0.0.1", .port = Epic.wallet_rpc_port };
    var sink: Coin.WalletErrSink = .{};

    // No wallet yet: an honest "nothing here", not a password complaint.
    try std.testing.expectError(error.WalletFileNotFound, Epic.epicShowSeed(a, no_auth, home, "testpass", &sink));

    const wd = try Epic.walletDataDir(a, home);
    defer a.free(wd);
    {
        var d = try cwd.createDirPathOpen(io, wd, .{});
        defer d.close(io);
        try d.writeFile(io, .{ .sub_path = Epic.seed_file_name, .data = test_seed_file });
    }

    var seed = try Epic.epicShowSeed(a, no_auth, home, "testpass", &sink);
    defer @memset(&seed.buf, 0);
    try std.testing.expectEqualStrings(
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art",
        seed.slice(),
    );
    try std.testing.expectError(error.WrongPassword, Epic.epicShowSeed(a, no_auth, home, "testpas", &sink));
}

test "a wallet.seed backup restores, and nothing is overwritten on either side" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    // The file import is a disk op; it never talks to the wallet.
    const no_auth: models.CoinAuth = .{ .rpc_user = "", .rpc_password = "", .ip_address = "127.0.0.1", .port = Epic.wallet_rpc_port };
    const home = "test-epic-wallet-backup-home";
    const other = "test-epic-wallet-backup-other";
    cwd.deleteTree(io, home) catch {};
    cwd.deleteTree(io, other) catch {};
    defer cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, other) catch {};

    // A wallet on disk, as `init -r` leaves it.
    const wd = try Epic.walletDataDir(a, home);
    defer a.free(wd);
    {
        var d = try cwd.createDirPathOpen(io, wd, .{});
        defer d.close(io);
        try d.writeFile(io, .{ .sub_path = Epic.seed_file_name, .data = test_seed_file });
    }

    // Back it up.
    var sink: Coin.WalletErrSink = .{};
    try cwd.createDirPath(io, other);
    const dest = other ++ "/epic-wallet-backup-1.seed";
    try Epic.epicBackupFile(a, home, dest, &sink);
    var got_buf: [Epic.seed_file_max]u8 = undefined;
    const got = try Epic.readSeedFile(io, dest, &got_buf);
    try std.testing.expectEqualStrings(test_seed_file, got);
    // Owner-only: the file's protection is the password alone.
    var bf = try cwd.openFile(io, dest, .{});
    const st = try bf.stat(io);
    bf.close(io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
    // A second backup to the same name refuses rather than overwrites.
    try std.testing.expectError(error.PathAlreadyExists, Epic.epicBackupFile(a, home, dest, &sink));

    // Restoring over the wallet that's there is refused, whatever the password.
    try std.testing.expectError(error.WalletAlreadyExists, Epic.epicRestoreFile(a, no_auth, home, dest, "testpass", &sink));

    // With the wallet gone: a wrong password or a wrong file writes nothing.
    try cwd.deleteTree(io, wd);
    try std.testing.expectError(error.WrongPassword, Epic.epicRestoreFile(a, no_auth, home, dest, "nope", &sink));
    try std.testing.expect(!Epic.walletExists(a, home));
    const junk = other ++ "/notes.txt";
    try cwd.writeFile(io, .{ .sub_path = junk, .data = "hello" });
    try std.testing.expectError(error.NotAWalletSeedFile, Epic.epicRestoreFile(a, no_auth, home, junk, "testpass", &sink));
    try std.testing.expect(!Epic.walletExists(a, home));

    // A wallet database left without its seed belongs to some other wallet.
    {
        var d = try cwd.createDirPathOpen(io, wd, .{});
        defer d.close(io);
        try d.createDirPath(io, "db");
    }
    try std.testing.expectError(error.WalletDataInUse, Epic.epicRestoreFile(a, no_auth, home, dest, "testpass", &sink));
    try cwd.deleteTree(io, wd);

    // The right password puts the identical file back. (The follow-up scan
    // finds no epic-wallet under this home and is skipped, as it's best-effort.)
    try Epic.epicRestoreFile(a, no_auth, home, dest, "testpass", &sink);
    try std.testing.expect(Epic.walletExists(a, home));
    const seed_path = try std.fs.path.join(a, &.{ wd, Epic.seed_file_name });
    defer a.free(seed_path);
    const back = try Epic.readSeedFile(io, seed_path, &got_buf);
    try std.testing.expectEqualStrings(test_seed_file, back);
}

test "normalizeRelay takes a host or host:port, secure only, in epic-wallet's address grammar" {
    var buf: [Coin.relay_max]u8 = undefined;
    try std.testing.expectEqualStrings("epicbox.epiccash.com", try Epic.normalizeRelay("epicbox.epiccash.com", &buf));
    // Port 443 is the default, so it's dropped; any other is kept.
    try std.testing.expectEqualStrings("epicbox.epiccash.com", try Epic.normalizeRelay("  wss://EpicBox.EpicCash.com:443/ ", &buf));
    try std.testing.expectEqualStrings("relay.example.com:8443", try Epic.normalizeRelay("relay.example.com:8443", &buf));
    // A pasted web link means the same secure server.
    try std.testing.expectEqualStrings("epicbox.epiccash.com", try Epic.normalizeRelay("https://epicbox.epiccash.com/", &buf));
    try std.testing.expectEqualStrings("relay.example.com:8443", try Epic.normalizeRelay("HTTPS://relay.example.com:8443", &buf));
    // Plain-text ones get their own reason: slates would travel in the clear.
    try std.testing.expectError(error.InsecureRelayAddress, Epic.normalizeRelay("ws://relay.example.com", &buf));
    try std.testing.expectError(error.InsecureRelayAddress, Epic.normalizeRelay("http://relay.example.com", &buf));
    const bad = [_][]const u8{
        "",
        "ftp://relay.example.com",
        "my-relay.example.com", // epic-wallet's address regex has no '-'
        "relay.example.com:0",
        "relay.example.com:99999",
        "relay.example.com:port",
        "relay.example.com/path",
        ".relay.example.com",
        "user@relay.example.com",
    };
    for (bad) |b| try std.testing.expectError(error.InvalidRelayAddress, Epic.normalizeRelay(b, &buf));
}

test "relayFromToml reads the live [epicbox] server and nothing else" {
    var buf: [Coin.relay_max]u8 = undefined;
    try std.testing.expectEqualStrings("relay.example.com:8443", Epic.relayFromToml(
        "[wallet]\nepicbox_domain = \"wrong.example\"\n[epicbox]\n# epicbox_domain = \"old.example\"\nepicbox_domain = \"relay.example.com\"\nepicbox_port = 8443\n",
        &buf,
    ));
    try std.testing.expectEqualStrings("epicbox.epiccash.com", Epic.relayFromToml("[epicbox]\nepicbox_domain = \"epicbox.epiccash.com\"\nepicbox_port = 443\n", &buf));
    try std.testing.expectEqualStrings("", Epic.relayFromToml("[wallet]\n", &buf));
}

test "a chosen Epicbox server survives the config being regenerated; the standard one is written back once" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const home = "test-epic-relay-home";
    cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, home) catch {};
    // BoxWallet's settings live under the install root this home resolves to.
    const root = try install_mod.installRoot(a, home);
    defer a.free(root);
    const top = try Epic.dataDir(a, home);
    defer a.free(top);

    var buf: [Coin.relay_max]u8 = undefined;
    // Nothing chosen, no config: the standard server.
    try std.testing.expectEqualStrings("", Epic.relaySource(a, root, home, &buf));

    // A server set by hand in the shared config is shown as it is, and a
    // launch with nothing chosen in BoxWallet leaves it alone.
    try cwd.createDirPath(io, top);
    try cwd.createDirPath(io, root);
    try Epic.ensureWalletConfig(a, io, home);
    {
        var d = try cwd.openDir(io, top, .{});
        defer d.close(io);
        try Epic.patchRelayKeys(a, io, d, "hand.example.org:9000");
    }
    try Epic.ensureWalletConfig(a, io, home);
    try std.testing.expectEqualStrings("hand.example.org:9000", Epic.relaySource(a, root, home, &buf));

    // Choosing one in Settings writes it, and it comes back after the config
    // is regenerated from scratch (as a create or restore does).
    try Epic.setRelaySource(a, root, home, "relay.example.com:8443");
    {
        var d = try cwd.openDir(io, top, .{});
        defer d.close(io);
        try d.deleteFile(io, Epic.wallet_conf_file);
    }
    try Epic.ensureWalletConfig(a, io, home);
    try std.testing.expectEqualStrings("relay.example.com:8443", Epic.relaySource(a, root, home, &buf));
    {
        var d = try cwd.openDir(io, top, .{});
        defer d.close(io);
        var tb: [16 * 1024]u8 = undefined;
        const toml = try d.readFile(io, Epic.wallet_conf_file, &tb);
        try std.testing.expect(std.mem.indexOf(u8, toml, "epicbox_domain = \"relay.example.com\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, toml, "epicbox_port = 8443") != null);
        try std.testing.expect(std.mem.indexOf(u8, toml, "epicbox_protocol_unsecure = false") != null);
    }

    // A refused address changes nothing.
    try std.testing.expectError(error.InsecureRelayAddress, Epic.setRelaySource(a, root, home, "ws://plain.example"));
    try std.testing.expectEqualStrings("relay.example.com:8443", Epic.relaySource(a, root, home, &buf));

    // Back to the standard server: written into the config, not just forgotten.
    try Epic.setRelaySource(a, root, home, "");
    try std.testing.expectEqualStrings("", Epic.relaySource(a, root, home, &buf));
}
