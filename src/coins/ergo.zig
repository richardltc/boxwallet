const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const install_mod = @import("../install.zig");
const rpc = @import("../rpc.zig");
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
    /// Whether the coin is exposed in the nav. False keeps it out of the left
    /// bar entirely (registered but hidden) until it's ready for users.
    pub const live = true;
    pub const coin_name = "Ergo";
    pub const coin_name_abbrev = "ERG";
    /// One-line description shown under the coin name on the detail pane.
    pub const coin_description = "Proof-of-work platform for secure, contract-based money.";
    /// Ergo brand colour (`#RRGGBB`), for tinting the coin in the frontend.
    pub const coin_color = "#FF5E18";
    /// This coin's id on the price host, for the USD quote beside its
    /// balance (see `src/price.zig`).
    pub const price_id = "ergo";
    /// Donation address for BoxWallet development, in Ergo's own
    /// currency.
    /// TODO(richard): replace with the real ERG tip address.
    pub const tip_address = "TODO-ERG-TIP-ADDRESS-NOT-SET";
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
        /// The node's software version (e.g. "6.0.2"), from `/info`'s `appVersion`.
        appVersion: []const u8 = "",
    };

    /// A REST response: the HTTP status and the body (caller owns `body`). Wallet
    /// ops inspect `status` to tell success from a 4xx (whose body carries Ergo's
    /// error JSON), so they use `restCall` directly rather than `restRequest`.
    const RestResponse = struct {
        status: std.http.Status,
        body: []u8,
    };

    /// Perform a REST request against the local node and return the status + body.
    /// `api_key_hdr`, when set, is sent as the `api_key` header (protected
    /// endpoints); `/info` needs none. `json_body`, when set, is sent as the
    /// request payload with a JSON content-type (the wallet POSTs); GET ignores it.
    /// Caller owns `body`.
    fn restCall(
        allocator: std.mem.Allocator,
        method: std.http.Method,
        path: []const u8,
        api_key_hdr: ?[]const u8,
        json_body: ?[]const u8,
    ) !RestResponse {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();

        var client: std.http.Client = .{ .allocator = allocator, .io = threaded.io() };
        defer client.deinit();

        const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{s}{s}", .{ rpc_default_port, path });
        defer allocator.free(url);

        var body: std.Io.Writer.Allocating = .init(allocator);
        defer body.deinit();

        const has_json = method != .GET and json_body != null;
        var hdr_buf: [2]std.http.Header = undefined;
        var nh: usize = 0;
        if (api_key_hdr) |key| {
            hdr_buf[nh] = .{ .name = "api_key", .value = key };
            nh += 1;
        }
        if (has_json) {
            hdr_buf[nh] = .{ .name = "Content-Type", .value = "application/json" };
            nh += 1;
        }

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            // `fetch` routes a payload-less request through `sendBodiless`, which
            // asserts the method carries no body — so a POST (which "has a body")
            // must pass a payload, even the empty one `/node/shutdown` wants.
            // GET stays payload-less (it takes the bodiless path correctly).
            .payload = if (method == .GET) null else (json_body orelse ""),
            .response_writer = &body.writer,
            .extra_headers = hdr_buf[0..nh],
        });

        return .{ .status = result.status, .body = try body.toOwnedSlice() };
    }

    /// Perform a REST request and return the body, mapping a 401 to `AuthFailed`.
    /// For the status-agnostic callers (`/info`, balances, shutdown). Caller owns
    /// the returned slice.
    fn restRequest(
        allocator: std.mem.Allocator,
        method: std.http.Method,
        path: []const u8,
        api_key_hdr: ?[]const u8,
    ) ![]u8 {
        const resp = try restCall(allocator, method, path, api_key_hdr, null);
        if (resp.status == .unauthorized) {
            allocator.free(resp.body);
            return error.AuthFailed;
        }
        return resp.body;
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
            // `appVersion` points into `parsed`; dupe it onto `allocator`.
            .version = try allocator.dupe(u8, r.appVersion),
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

    // --- Wallet management + balance -------------------------------------
    //
    // Ergo's wallet is *in-daemon*: the node exposes it over the same REST API
    // (`/wallet/*`, behind the api_key, 127.0.0.1 only). Its setup model is the
    // Monero shape — create returns a mnemonic to back up, restore from seed,
    // unlock/lock with a password — so it plugs into the shared external-wallet
    // setup UI via `external_wallet` below, with no separate wallet process
    // (`process_argv`/`rpc_port` left null). The `auth` passed to these hooks is
    // the daemon's endpoint, but Ergo authenticates with its fixed api_key, so the
    // hooks ignore it.

    /// Subset of `GET /wallet/status` — whether the wallet exists and is unlocked,
    /// plus the last height the wallet has scanned to. `isInitialized`/`isUnlocked`
    /// must both hold before the balance endpoints answer with real figures;
    /// `walletHeight` drives the rescan-progress indicator (it resets to 0 and
    /// climbs after a rescan-from-0).
    const ErgoWalletStatus = struct {
        isInitialized: bool = false,
        isUnlocked: bool = false,
        walletHeight: i64 = 0,
    };

    /// `POST /wallet/init` result — the freshly-generated mnemonic to display.
    const ErgoWalletInit = struct {
        mnemonic: []const u8 = "",
    };

    /// Ergo's REST error body (`{"error":400,"reason":"…","detail":"…"}`). `detail`
    /// is the human-readable cause when present; `reason` is the fallback.
    const ErgoError = struct {
        reason: []const u8 = "",
        detail: []const u8 = "",
    };

    /// Subset of the `/wallet/balances*` endpoints: the Ergo amount in nanoErg
    /// (1 ERG = 1e9 nanoErg). The `assets` array (native tokens) is ignored.
    const ErgoWalletBalance = struct {
        balance: i64 = 0,
    };

    /// nanoErg per ERG — Ergo's REST API reports balances in the base unit.
    const nano_per_erg: f64 = 1_000_000_000;

    /// Read `GET /wallet/status` (localhost, behind the api_key) into its
    /// init/unlock flags. The shared probe behind `walletExists`, the balance
    /// gate, and the idempotent unlock paths — Ergo's REST API has no other way to
    /// learn whether the wallet is initialized/unlocked. Caller gets a value copy;
    /// nothing to free.
    fn walletStatus(allocator: std.mem.Allocator) !ErgoWalletStatus {
        const raw = try restRequest(allocator, .GET, "/wallet/status", api_key);
        defer allocator.free(raw);
        var parsed = try std.json.parseFromSlice(ErgoWalletStatus, allocator, raw, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        return parsed.value;
    }

    /// Fetch + parse one `/wallet/balances*` endpoint, returning its nanoErg total.
    fn fetchErgBalance(allocator: std.mem.Allocator, path: []const u8) !i64 {
        const raw = try restRequest(allocator, .GET, path, api_key);
        defer allocator.free(raw);
        var parsed = try std.json.parseFromSlice(ErgoWalletBalance, allocator, raw, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        return parsed.value.balance;
    }

    /// Read the wallet's balances over REST. `available` is the confirmed balance
    /// (`/wallet/balances`); `total` is the confirmed-plus-unconfirmed projection
    /// (`/wallet/balances/withUnconfirmed`), which already folds in mempool
    /// transactions — so it moves the moment funds are seen. Both are nanoErg
    /// integers, converted to whole ERG. Errors `WalletUnavailable` when the wallet
    /// is missing or locked (so the frontend simply hides the lines rather than
    /// reading a misleading 0). `auth` is unused — Ergo authenticates with its
    /// fixed api_key.
    pub fn walletBalance(allocator: std.mem.Allocator, auth: models.CoinAuth) anyerror!models.WalletBalance {
        _ = auth;

        // A locked or uninitialized wallet can't report a balance; the endpoints
        // would 400. Gate on the status so we never surface a phantom 0.
        {
            const st = try walletStatus(allocator);
            if (!st.isInitialized or !st.isUnlocked) return error.WalletUnavailable;
        }

        const confirmed = try fetchErgBalance(allocator, "/wallet/balances");
        const with_unconfirmed = try fetchErgBalance(allocator, "/wallet/balances/withUnconfirmed");
        return .{
            .available = @as(f64, @floatFromInt(confirmed)) / nano_per_erg,
            .total = @as(f64, @floatFromInt(with_unconfirmed)) / nano_per_erg,
        };
    }

    /// Record the node's failure reason from a non-2xx wallet reply into `detail`
    /// (so the UI shows the real cause, not a bare error name) and return `err`.
    /// `body` is the REST response body; an unparseable one just leaves `detail`
    /// empty. Never logs/stores the request — only the node's error text.
    fn failWallet(
        allocator: std.mem.Allocator,
        detail: *Coin.WalletErrSink,
        body: []const u8,
        err: anyerror,
    ) anyerror {
        if (std.json.parseFromSlice(ErgoError, allocator, body, .{ .ignore_unknown_fields = true })) |parsed| {
            defer parsed.deinit();
            const msg = if (parsed.value.detail.len > 0) parsed.value.detail else parsed.value.reason;
            if (msg.len > 0) detail.set(msg);
        } else |_| {}
        return err;
    }

    /// Whether the node already has an initialized wallet — read from
    /// `GET /wallet/status` (localhost only; the daemon is always up before the UI
    /// offers the wallet menu). A failed read (node down) reads as "no wallet",
    /// which is harmless: the menu can't open without a running daemon anyway.
    /// `home_dir` is unused — the wallet lives in the node, not a path we stat.
    pub fn walletExists(allocator: std.mem.Allocator, home_dir: []const u8) bool {
        _ = home_dir;
        const resp = restCall(allocator, .GET, "/wallet/status", api_key, null) catch return false;
        defer allocator.free(resp.body);
        if (resp.status != .ok) return false;
        var st = std.json.parseFromSlice(ErgoWalletStatus, allocator, resp.body, .{ .ignore_unknown_fields = true }) catch return false;
        defer st.deinit();
        return st.value.isInitialized;
    }

    /// Create a new wallet under `password` via `POST /wallet/init`, returning the
    /// node-generated mnemonic for the user to back up (Ergo leaves the new wallet
    /// unlocked). The request body and the mnemonic-bearing reply hold secrets, so
    /// both are wiped before the buffers are freed. `auth` is unused (fixed api_key).
    pub fn walletCreate(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        password: []const u8,
        detail: *Coin.WalletErrSink,
    ) anyerror!models.Seed {
        _ = auth;
        const qpw = try rpc.jsonQuote(allocator, password);
        defer wipeFree(allocator, qpw);
        const body = try std.fmt.allocPrint(allocator, "{{\"pass\":{s},\"mnemonicPass\":\"\"}}", .{qpw});
        defer wipeFree(allocator, body);

        const resp = try restCall(allocator, .POST, "/wallet/init", api_key, body);
        // The reply carries the mnemonic — wipe it once copied into the Seed.
        defer wipeFree(allocator, resp.body);
        if (resp.status != .ok) return failWallet(allocator, detail, resp.body, error.WalletCreateFailed);

        var parsed = try std.json.parseFromSlice(ErgoWalletInit, allocator, resp.body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        return models.Seed.from(parsed.value.mnemonic);
    }

    /// Restore a wallet from a mnemonic `seed` under `password` via
    /// `POST /wallet/restore`, then unlock it so the balance shows immediately.
    /// `install_root`/`home_dir` are unused (no CLI shell-out — the node restores
    /// over REST). Secret-bearing buffers are wiped before free.
    pub fn walletRestoreSeed(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        install_root: []const u8,
        home_dir: []const u8,
        password: []const u8,
        seed: []const u8,
        detail: *Coin.WalletErrSink,
    ) anyerror!void {
        _ = install_root;
        _ = home_dir;
        const qpw = try rpc.jsonQuote(allocator, password);
        defer wipeFree(allocator, qpw);
        // Normalize the seed (lowercase + collapse whitespace) so a pasted phrase
        // with stray case/spacing still restores — see the convention on
        // `models.normalizeSeedWords` and `Coin.ExternalWallet.restore_seed`.
        const normalized = try models.normalizeSeedWords(allocator, seed);
        defer wipeFree(allocator, normalized);
        const qseed = try rpc.jsonQuote(allocator, normalized);
        defer wipeFree(allocator, qseed);
        const body = try std.fmt.allocPrint(
            allocator,
            "{{\"pass\":{s},\"mnemonic\":{s},\"mnemonicPass\":\"\",\"usePre1627KeyDerivation\":false}}",
            .{ qpw, qseed },
        );
        defer wipeFree(allocator, body);

        const resp = try restCall(allocator, .POST, "/wallet/restore", api_key, body);
        defer allocator.free(resp.body);
        if (resp.status != .ok) return failWallet(allocator, detail, resp.body, error.WalletRestoreFailed);

        // Restore initializes and normally leaves the wallet unlocked, so unlocking
        // again would draw a 400 "Wallet already unlocked". `walletOpen` is gated on
        // the status, so it's a no-op when the node already has it open and only
        // unlocks if restore left it locked — polling reads the (rescanning) balance
        // straight away either way.
        try walletOpen(allocator, auth, password, detail);

        // Ergo's node scans only *forward* from the restore height, so an imported
        // seed's existing funds are never found without an explicit full rescan.
        // Trigger one from genesis (`fromHeight:0`); the node resets the wallet's
        // scan pointer and rescans in the background (this POST returns at once).
        // The wallet must be unlocked first (done above) for the node to derive keys.
        const rescan = try restCall(allocator, .POST, "/wallet/rescan", api_key, rescan_body);
        defer allocator.free(rescan.body);
        if (rescan.status != .ok) return failWallet(allocator, detail, rescan.body, error.WalletRescanFailed);
    }

    /// Rescan request body — a full scan from genesis (`fromHeight:0`) so a restored
    /// seed's entire history is re-scanned.
    const rescan_body = "{\"fromHeight\":0}";

    /// Unlock the wallet with `password` via `POST /wallet/unlock`. Idempotent: if
    /// the node already reports the wallet unlocked, returns success without calling
    /// unlock (which would 400 with "Wallet already unlocked") — so restore's
    /// follow-up unlock and a stray explicit Unlock both settle cleanly. A wrong
    /// password still fails with a distinct error, so this doesn't mask a bad
    /// password. `auth` unused.
    pub fn walletOpen(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        password: []const u8,
        detail: *Coin.WalletErrSink,
    ) anyerror!void {
        _ = auth;
        // Already unlocked → nothing to do. A failed status read falls through to the
        // unlock attempt (which surfaces the real error).
        if (walletStatus(allocator)) |st| {
            if (st.isUnlocked) return;
        } else |_| {}

        const qpw = try rpc.jsonQuote(allocator, password);
        defer wipeFree(allocator, qpw);
        const body = try std.fmt.allocPrint(allocator, "{{\"pass\":{s}}}", .{qpw});
        defer wipeFree(allocator, body);

        const resp = try restCall(allocator, .POST, "/wallet/unlock", api_key, body);
        defer allocator.free(resp.body);
        if (resp.status != .ok) return failWallet(allocator, detail, resp.body, error.WalletOpenFailed);
    }

    /// Re-lock the wallet via `GET /wallet/lock` (Ergo's lock endpoint is a GET and
    /// takes no body, unlike init/restore/unlock which are POSTs). `auth` unused.
    pub fn walletLock(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        detail: *Coin.WalletErrSink,
    ) anyerror!void {
        _ = auth;
        const resp = try restCall(allocator, .GET, "/wallet/lock", api_key, null);
        defer allocator.free(resp.body);
        if (resp.status != .ok) return failWallet(allocator, detail, resp.body, error.WalletLockFailed);
    }

    /// Whether the node currently has the wallet unlocked — read from
    /// `GET /wallet/status`. The Ergo node outlives the app, so an app restart leaves
    /// a previously-unlocked wallet unlocked at the node; this lets the UI re-adopt
    /// that state (resuming balance + rescan polling) rather than misreport "Locked".
    /// Not an unlock — it only reports state, and never touches the password. `auth`
    /// unused (fixed api_key).
    pub fn walletIsOpen(allocator: std.mem.Allocator, auth: models.CoinAuth) anyerror!bool {
        _ = auth;
        const st = try walletStatus(allocator);
        return st.isInitialized and st.isUnlocked;
    }

    /// Below this many blocks behind the tip we treat the wallet as "caught up" and
    /// report no rescan, so the routine 1-2 block lag of normal forward sync doesn't
    /// flash a spurious "Rescanning…" indicator. A real rescan-from-0 starts ~1.5M
    /// blocks behind, far past this.
    const rescan_done_slack: i64 = 32;

    /// Report wallet rescan progress, or null when the wallet isn't meaningfully
    /// rescanning. After a restore we kick off a rescan-from-0 (see
    /// `walletRestoreSeed`); the node resets `walletHeight` to 0 and scans up toward
    /// the chain tip, so progress is `walletHeight / fullHeight`. Null when the
    /// wallet is locked/uninitialized, the tip height isn't known yet, or the wallet
    /// is within `rescan_done_slack` of the tip (caught up). Both auths are unused:
    /// Ergo's wallet and node are one process, reached with the fixed api_key, so
    /// the scanned height and the tip both come from `fetchInfo`/`walletStatus`.
    /// Best-effort: any read error propagates to the caller, which treats it as "no
    /// progress info this tick".
    pub fn walletRescanProgress(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        daemon_auth: models.CoinAuth,
    ) anyerror!?models.RescanProgress {
        _ = auth;
        _ = daemon_auth;
        const st = try walletStatus(allocator);
        if (!st.isInitialized or !st.isUnlocked) return null;

        var info = try fetchInfo(allocator);
        defer info.deinit();
        const full = info.value.fullHeight orelse 0;
        if (full <= 0) return null;

        // Caught up (or scanning the last few blocks of normal forward sync) → no
        // rescan to show.
        if (st.walletHeight >= full - rescan_done_slack) return null;
        return .{ .scanned = st.walletHeight, .target = full };
    }

    // --- Receive address + send (REST wallet) -----------------------------
    //
    // Both ride the node's own REST wallet, authenticated with the fixed
    // api_key and gated by the app on the wallet being open. Transaction history
    // rides it too, but indirectly: the node's `/wallet/transactions` entries
    // carry no timestamp and their inputs no values, so an honest amount/date
    // can't come from that endpoint alone — each wallet tx is re-read through the
    // extra index instead (see the transaction-history section below).

    /// `GET /wallet/deriveNextKey` result — the freshly-derived address.
    const ErgoDeriveNext = struct {
        address: []const u8 = "",
    };

    /// The wallet's receive address. `force_new` false returns the **last**
    /// entry of `GET /wallet/addresses` — the most recently derived key, i.e.
    /// the current address, stable across sessions; true derives a fresh key
    /// (`GET /wallet/deriveNextKey`), which then becomes that last entry.
    /// `auth` unused (fixed api_key).
    pub fn walletReceiveAddress(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        force_new: bool,
    ) anyerror![]const u8 {
        _ = auth;
        if (force_new) {
            const raw = try restRequest(allocator, .GET, "/wallet/deriveNextKey", api_key);
            defer allocator.free(raw);
            var parsed = try std.json.parseFromSlice(ErgoDeriveNext, allocator, raw, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
            defer parsed.deinit();
            if (parsed.value.address.len == 0) return error.EmptyRpcResult;
            return allocator.dupe(u8, parsed.value.address);
        }

        const raw = try restRequest(allocator, .GET, "/wallet/addresses", api_key);
        defer allocator.free(raw);
        var parsed = try std.json.parseFromSlice([][]const u8, allocator, raw, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        defer parsed.deinit();
        const addrs = parsed.value;
        if (addrs.len == 0) return error.EmptyRpcResult;
        return allocator.dupe(u8, addrs[addrs.len - 1]);
    }

    /// Send `amount` ERG to `address` via `POST /wallet/payment/send` (a
    /// one-element PaymentRequest array; `value` is nanoErg). The node does its
    /// own address validation and balance check — `SendResult` carries its
    /// failure `detail`/`reason` (or the success tx id) verbatim. Requires the
    /// wallet unlocked, which the node itself enforces.
    pub fn walletSend(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        address: []const u8,
        amount: f64,
    ) anyerror!models.SendResult {
        _ = auth;
        const nano = nanoFromAmount(amount) orelse return .{ .failed = "invalid amount" };
        const addr_q = try rpc.jsonQuote(allocator, address);
        defer allocator.free(addr_q);
        const body = try std.fmt.allocPrint(
            allocator,
            "[{{\"address\":{s},\"value\":{d},\"assets\":[]}}]",
            .{ addr_q, nano },
        );
        defer allocator.free(body);

        const resp = try restCall(allocator, .POST, "/wallet/payment/send", api_key, body);
        defer allocator.free(resp.body);
        if (resp.status == .ok) {
            // The reply is the new transaction's id as a bare JSON string.
            if (std.json.parseFromSlice([]const u8, allocator, resp.body, .{ .allocate = .alloc_always })) |parsed| {
                defer parsed.deinit();
                return .{ .ok = try allocator.dupe(u8, parsed.value) };
            } else |_| {
                return .{ .ok = try allocator.dupe(u8, std.mem.trim(u8, resp.body, " \"\r\n")) };
            }
        }
        // A rejected send carries Ergo's error JSON — surface its real reason.
        if (std.json.parseFromSlice(ErgoError, allocator, resp.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always })) |parsed| {
            defer parsed.deinit();
            const msg = if (parsed.value.detail.len > 0) parsed.value.detail else parsed.value.reason;
            if (msg.len > 0) return .{ .failed = try allocator.dupe(u8, msg) };
        } else |_| {}
        return .{ .failed = "wallet request failed" };
    }

    /// Convert a user-entered ERG amount to integer nanoErg (rounded to the
    /// nearest nanoErg). Null for anything unusable — non-finite, non-positive,
    /// or too large for the API's int64 value — so a bad amount is rejected
    /// before any request.
    fn nanoFromAmount(amount: f64) ?i64 {
        if (!std.math.isFinite(amount) or amount <= 0) return null;
        const scaled = @round(amount * nano_per_erg);
        if (scaled >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return null;
        return @intFromFloat(scaled);
    }

    // --- Wallet transaction history (extra index) ------------------------
    //
    // Ergo's plain `/wallet/transactions` lists the wallet's txs but carries no
    // timestamp and its inputs are bare box references with no value, so an
    // honest sent-amount/date can't be derived from it alone. Instead each
    // wallet tx is read back through the node's **extra index**
    // (`GET /blockchain/transaction/byId`, enabled by `extraIndex` in the conf),
    // which returns the block timestamp and every input/output valued and
    // addressed — enough to compute the net effect on the wallet exactly.

    /// One entry of `GET /wallet/transactions` — only the fields we order and
    /// resolve by. The heavy inputs/outputs arrays are ignored: their inputs
    /// carry no value anyway, which is why we re-read via the index below.
    const ErgoWalletTxRef = struct {
        id: []const u8 = "",
        inclusionHeight: i64 = 0,
    };

    /// One box of an indexed transaction: the base58 `address` it pays to and
    /// its nanoErg `value`. Present on both inputs and outputs once `extraIndex`
    /// is on — the plain wallet endpoint gives neither for inputs.
    const ErgoIndexedBox = struct {
        address: []const u8 = "",
        value: i64 = 0,
    };

    /// Subset of `IndexedErgoTransaction` (`GET /blockchain/transaction/byId`):
    /// the block `timestamp` (unix ms), the confirmation count, and the valued
    /// inputs/outputs (full boxes here, not the bare references the wallet
    /// endpoint returns).
    const ErgoIndexedTx = struct {
        timestamp: i64 = 0,
        numConfirmations: i64 = 0,
        inputs: []const ErgoIndexedBox = &.{},
        outputs: []const ErgoIndexedBox = &.{},
    };

    /// `GET /blockchain/indexedHeight` — how far the extra index has processed
    /// (`indexedHeight`) against the node's block height (`fullHeight`). Built
    /// during sync, so on a node that synced before `extraIndex` was turned on it
    /// lags and must catch up.
    const ErgoIndexedHeight = struct {
        indexedHeight: i64 = 0,
        fullHeight: i64 = 0,
    };

    /// How far the extra index may trail the chain tip and still count as ready —
    /// a couple of blocks of slack for the gap between a block arriving and the
    /// indexer processing it, without ever showing a partial history.
    const index_ready_slack: i64 = 2;

    /// Fetch `GET /blockchain/indexedHeight`. Errors `IndexUnavailable` when the
    /// endpoint 404s, which is how a node with `extraIndex` off presents.
    fn fetchIndexedHeight(allocator: std.mem.Allocator) !ErgoIndexedHeight {
        const resp = try restCall(allocator, .GET, "/blockchain/indexedHeight", api_key, null);
        defer allocator.free(resp.body);
        if (resp.status != .ok) return error.IndexUnavailable;
        var parsed = try std.json.parseFromSlice(ErgoIndexedHeight, allocator, resp.body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        return parsed.value;
    }

    /// Fetch one indexed transaction by id. Errors `TxNotIndexed` on a non-200
    /// (e.g. an unconfirmed tx not yet in the index) so the caller can skip it.
    /// Caller must `deinit` the returned `Parsed`.
    fn fetchIndexedTx(allocator: std.mem.Allocator, id: []const u8) !std.json.Parsed(ErgoIndexedTx) {
        const path = try std.fmt.allocPrint(allocator, "/blockchain/transaction/byId/{s}", .{id});
        defer allocator.free(path);
        const resp = try restCall(allocator, .GET, path, api_key, null);
        defer allocator.free(resp.body);
        if (resp.status != .ok) return error.TxNotIndexed;
        return std.json.parseFromSlice(ErgoIndexedTx, allocator, resp.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    }

    /// True if `addr` is one of the wallet's own addresses.
    fn isWalletAddr(addr: []const u8, wallet_addrs: []const []const u8) bool {
        for (wallet_addrs) |w| {
            if (std.mem.eql(u8, addr, w)) return true;
        }
        return false;
    }

    /// Normalize one indexed transaction to a `WalletTx` against the wallet's
    /// address set. The net effect on the wallet is `Σ(our outputs) − Σ(our
    /// inputs)` in nanoErg: received when ≥ 0 (money in), sent otherwise (a
    /// spend, whose change output back to us is already netted off). The
    /// magnitude is shown in whole ERG; `timestamp` is unix ms → seconds.
    fn walletTxFromIndexed(tx: ErgoIndexedTx, wallet_addrs: []const []const u8) models.WalletTx {
        var net: i64 = 0; // nanoErg
        for (tx.outputs) |o| {
            if (isWalletAddr(o.address, wallet_addrs)) net += o.value;
        }
        for (tx.inputs) |in| {
            if (isWalletAddr(in.address, wallet_addrs)) net -= in.value;
        }
        const net_erg = @as(f64, @floatFromInt(net)) / nano_per_erg;
        return .{
            .direction = if (net >= 0) .received else .sent,
            .amount = @abs(net_erg),
            .time = @divTrunc(tx.timestamp, 1000),
            .confirmations = tx.numConfirmations,
        };
    }

    /// The wallet's most recent transactions, newest-first, normalized to
    /// `WalletTx`. Reads the wallet's tx-id list (`/wallet/transactions`) and its
    /// address set (`/wallet/addresses`), then resolves each of the newest
    /// `limit` ids through the extra index for an exact valued + dated row (see
    /// the section note above). Gated on the index being present and caught up:
    /// while it's still building — or if `extraIndex` is off entirely — this
    /// returns an error so the tab shows nothing rather than a partial or guessed
    /// history. `auth` is unused (fixed api_key).
    pub fn walletTransactions(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        limit: usize,
    ) anyerror![]models.WalletTx {
        _ = auth;

        // Gate: the per-tx lookups below need a present, caught-up index.
        const ih = try fetchIndexedHeight(allocator);
        if (ih.fullHeight <= 0 or ih.indexedHeight < ih.fullHeight - index_ready_slack)
            return error.IndexNotReady;

        // The wallet's own addresses — to tell which boxes are ours.
        const addrs_raw = try restRequest(allocator, .GET, "/wallet/addresses", api_key);
        defer allocator.free(addrs_raw);
        var addrs_parsed = try std.json.parseFromSlice([]const []const u8, allocator, addrs_raw, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        defer addrs_parsed.deinit();
        const wallet_addrs = addrs_parsed.value;

        // The wallet's tx ids + heights. A transient full read (the endpoint has
        // no server-side count), parsed down to just the id/height we order by;
        // only `limit` of them are resolved through the index below.
        const list_raw = try restRequest(allocator, .GET, "/wallet/transactions", api_key);
        defer allocator.free(list_raw);
        var list_parsed = try std.json.parseFromSlice([]ErgoWalletTxRef, allocator, list_raw, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        defer list_parsed.deinit();
        const refs = list_parsed.value;

        // Newest first, by inclusion height.
        std.mem.sort(ErgoWalletTxRef, refs, {}, struct {
            fn lessThan(_: void, a: ErgoWalletTxRef, b: ErgoWalletTxRef) bool {
                return a.inclusionHeight > b.inclusionHeight;
            }
        }.lessThan);

        const out = try allocator.alloc(models.WalletTx, limit);
        var n: usize = 0;
        for (refs) |ref| {
            if (n >= limit) break;
            if (ref.id.len == 0) continue;
            // An unconfirmed tx isn't in the index yet → skip; it appears once
            // it's mined (the tab refreshes every poll).
            var parsed = fetchIndexedTx(allocator, ref.id) catch continue;
            defer parsed.deinit();
            out[n] = walletTxFromIndexed(parsed.value, wallet_addrs);
            n += 1;
        }
        return out[0..n];
    }

    /// Overwrite a secret-bearing buffer with zeros before freeing it, so a
    /// password/seed/mnemonic doesn't linger in freed heap.
    fn wipeFree(allocator: std.mem.Allocator, buf: []u8) void {
        @memset(buf, 0);
        allocator.free(buf);
    }

    /// Remove the node's wallet so a different one can be created/restored — the
    /// in-app "Replace wallet". Deletes `<dataDir>/wallet` (the `keystore` secret
    /// plus the `registry`/`storage` scan DBs), so `/wallet/status` reports
    /// `isInitialized:false` on the next start. The node caches the secret in
    /// memory, so the caller (app.zig) stops the daemon before this and restarts it
    /// after; deleting at runtime alone wouldn't take effect. Idempotent — a missing
    /// wallet dir is fine. `deleteTree` holds nothing in memory beyond a path.
    pub fn walletRemove(allocator: std.mem.Allocator, home: []const u8) anyerror!void {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        const wallet_dir = try std.fs.path.join(allocator, &.{ data_dir, "wallet" });
        defer allocator.free(wallet_dir);

        try std.Io.Dir.cwd().deleteTree(io, wallet_dir);
    }

    /// The external-wallet capability, backed by the in-daemon REST wallet (no
    /// separate process — `process_argv`/`rpc_port` null). `restore_file` is null:
    /// Ergo has no portable wallet file, so the setup menu omits that choice.
    const external_wallet: Coin.ExternalWallet = .{
        .exists = walletExists,
        .create = walletCreate,
        .restore_seed = walletRestoreSeed,
        .open = walletOpen,
        .lock = walletLock,
        .remove = walletRemove,
        .balance = walletBalance,
        .rescan_progress = walletRescanProgress,
        .is_open = walletIsOpen,
        // Ergo generates a 15-word BIP39 mnemonic, but the node accepts a standard
        // 12- or 24-word phrase too (e.g. imported from another wallet).
        .seed_word_counts = &.{ 15, 12, 24 },
    };

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
        \\        // Build the extra index (address/box/tx) during sync, so the
        \\        // Transactions tab can read each wallet tx back valued + dated
        \\        // via `/blockchain/*`. On a fresh install it costs no separate
        \\        // phase — the index is built as blocks are applied; the price is
        \\        // a larger DB and a little more indexing work per block.
        \\        extraIndex = true
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
        .coin_description = vtCoinDescription,
        .coin_color = vtCoinColor,
        .tip_address = vtTipAddress,
        .price_id = vtPriceId,
        .core_version = vtCoreVersion,
        .proof_of_stake = vtProofOfStake,
        .has_header_presync = vtHasHeaderPresync,
        .balance_decimals = vtBalanceDecimals,
        .conf_file = vtConfFile,
        .daemon_file = vtDaemonFile,
        .daemon_process_cmdline = vtDaemonProcessCmdline,
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
        // Reads each wallet tx back through the node's extra index for an exact
        // valued + dated row (see `walletTransactions`); gated on the index being
        // caught up, else the tab stays empty rather than showing partial data.
        .wallet_transactions = vtWalletTransactions,
        .wallet_receive_address = vtWalletReceiveAddress,
        .wallet_send = vtWalletSend,
        // Ergo's wallet is in-daemon (REST) but Monero-shaped (create → mnemonic,
        // restore, unlock/lock), so it rides the external-wallet setup flow rather
        // than the bitcoin in-daemon wallet hooks. Balance flows through
        // `external_wallet.balance`, gated on the wallet being open.
        .external_wallet = &external_wallet,
    };

    // Receive/send ride the node's REST wallet: `app.zig` calls them only once
    // the wallet is open; the passed auth is unused (fixed api_key).
    fn vtWalletReceiveAddress(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        force_new: bool,
    ) anyerror![]const u8 {
        return walletReceiveAddress(allocator, auth, force_new);
    }
    fn vtWalletSend(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        address: []const u8,
        amount: f64,
    ) anyerror!models.SendResult {
        return walletSend(allocator, auth, address, amount);
    }
    fn vtWalletTransactions(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        limit: usize,
    ) anyerror![]models.WalletTx {
        return walletTransactions(allocator, auth, limit);
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
    /// Ergo isn't bitcoin-derived and has no headers pre-synchronization pass —
    /// it commits every header as it arrives. Its `headersHeight` therefore
    /// tracks the tip and only creeps forward a block at a time once caught up,
    /// which the frontend's stalled-header inference would otherwise misread as
    /// a presync freeze for the whole (long) full-block download.
    fn vtHasHeaderPresync(_: *anyopaque) bool {
        return false;
    }
    /// ERG balances are denominated to 9 decimal places (1 ERG = 1e9 nanoERG, see
    /// `nano_per_erg`).
    fn vtBalanceDecimals(_: *anyopaque) u8 {
        return 9;
    }
    fn vtConfFile(_: *anyopaque) []const u8 {
        return conf_file;
    }
    /// Ergo has no native daemon binary; the jar name stands in for the few places
    /// the bitcoin fork path would use it (Ergo never takes that path).
    fn vtDaemonFile(_: *anyopaque) []const u8 {
        return jar_file;
    }
    /// The node is a jar, not an executable: the process the OS sees is `java`,
    /// so liveness has to match the command line instead. The versioned jar name
    /// is what makes it ours and not some other JVM on the machine.
    fn vtDaemonProcessCmdline(_: *anyopaque) []const u8 {
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
    try std.testing.expectEqualStrings("Ergo", c.coinName());
    try std.testing.expectEqualStrings("ERG", c.coinNameAbbrev());
    try std.testing.expectEqualStrings("#FF5E18", c.coinColor());
    try std.testing.expect(!c.isProofOfStake());
    try std.testing.expectEqualStrings("ergo.conf", c.confFile());
    try std.testing.expectEqualStrings("9053", c.rpcDefaultPort());
    try std.testing.expectEqual(Coin.LaunchMode.foreground, c.launchMode());
    try std.testing.expectEqual(@as(?[]const u8, null), c.daemonLogFile());
    // Ergo drives the external-wallet setup flow, backed by the in-daemon REST
    // wallet (so no separate process), and reports balance through it — not via the
    // standalone `wallet_balance`/bitcoin `wallet_security_state` hooks.
    try std.testing.expect(c.hasExternalWallet());
    try std.testing.expect(!c.hasExternalWalletProcess());
    try std.testing.expect(!c.supportsBalance());
    try std.testing.expect(!c.supportsWallet());
    // No portable wallet file, so the setup menu omits "restore from file".
    try std.testing.expect(c.externalWallet().?.restore_file == null);
    try std.testing.expect(c.externalWallet().?.lock != null);
    // 15-word node mnemonic canonical, but 12/24 also accepted on restore.
    try std.testing.expectEqualSlices(usize, &.{ 15, 12, 24 }, c.seedWordCounts());
    // Node-internal wallet — no discrete file for the Settings tab to list.
    try std.testing.expect((try c.walletPath(std.testing.allocator, "/home/alice")) == null);
}

test "parses /wallet/init mnemonic into a Seed" {
    const allocator = std.testing.allocator;
    // The node's reply to a successful create. The mnemonic is copied into the
    // fixed Seed buffer (never the heap).
    var parsed = try std.json.parseFromSlice(
        Ergo.ErgoWalletInit,
        allocator,
        "{\"mnemonic\":\"abandon ability able about above absent absorb abstract\"}",
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    const seed = models.Seed.from(parsed.value.mnemonic);
    try std.testing.expectEqualStrings("abandon ability able about above absent absorb abstract", seed.slice());
}

test "wallet request bodies JSON-escape the password and seed" {
    const allocator = std.testing.allocator;

    // A password with characters that must be escaped in JSON (quote, backslash):
    // a naive interpolation would produce invalid JSON / let the value break out.
    const qpw = try rpc.jsonQuote(allocator, "p\"a\\ss");
    defer allocator.free(qpw);
    const unlock_body = try std.fmt.allocPrint(allocator, "{{\"pass\":{s}}}", .{qpw});
    defer allocator.free(unlock_body);
    try std.testing.expectEqualStrings("{\"pass\":\"p\\\"a\\\\ss\"}", unlock_body);

    // The restore body carries both pass and the (quoted) mnemonic plus the fixed
    // flags, and stays well-formed.
    const qseed = try rpc.jsonQuote(allocator, "word one two");
    defer allocator.free(qseed);
    const restore_body = try std.fmt.allocPrint(
        allocator,
        "{{\"pass\":{s},\"mnemonic\":{s},\"mnemonicPass\":\"\",\"usePre1627KeyDerivation\":false}}",
        .{ qpw, qseed },
    );
    defer allocator.free(restore_body);
    try std.testing.expect(std.mem.indexOf(u8, restore_body, "\"mnemonic\":\"word one two\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, restore_body, "\"usePre1627KeyDerivation\":false") != null);
}

test "a failed wallet reply surfaces the node's reason into the sink" {
    const allocator = std.testing.allocator;
    var sink: Coin.WalletErrSink = .{};
    // Ergo's 400 body: prefer `detail`, falling back to `reason`.
    const body = "{\"error\":400,\"reason\":\"Bad request\",\"detail\":\"wrong password\"}";
    const err = Ergo.failWallet(allocator, &sink, body, error.WalletOpenFailed);
    try std.testing.expectError(error.WalletOpenFailed, @as(anyerror!void, err));
    try std.testing.expectEqualStrings("wrong password", sink.slice());
}

test "walletRemove deletes the node wallet dir and is a no-op when absent" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-ergo-walletremove-home";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    const data_dir = try Ergo.dataDir(allocator, home);
    defer allocator.free(data_dir);
    const wallet_dir = try std.fs.path.join(allocator, &.{ data_dir, "wallet" });
    defer allocator.free(wallet_dir);
    const keystore = try std.fs.path.join(allocator, &.{ wallet_dir, "keystore" });
    defer allocator.free(keystore);

    // Mimic an initialized wallet: <dataDir>/wallet/keystore/<secret>.json
    var kd = try std.Io.Dir.cwd().createDirPathOpen(io, keystore, .{});
    try kd.writeFile(io, .{ .sub_path = "secret.json", .data = "{}" });
    kd.close(io);

    // Present, then removed, then a second remove is a harmless no-op.
    try std.Io.Dir.cwd().access(io, wallet_dir, .{});
    try Ergo.walletRemove(allocator, home);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, wallet_dir, .{}));
    try Ergo.walletRemove(allocator, home);
}

test "restore seed is normalized (lowercased, whitespace collapsed)" {
    const allocator = std.testing.allocator;
    // A messy paste: capitalized words, tabs/newlines, leading/trailing and doubled
    // spaces — restore must reduce it to the canonical space-joined lowercase form.
    const messy = "  Abandon\tABILITY\n able   about  ";
    const norm = try models.normalizeSeedWords(allocator, messy);
    defer allocator.free(norm);
    try std.testing.expectEqualStrings("abandon ability able about", norm);
}

test "parses /wallet/balances nanoErg into whole-ERG available/total" {
    const allocator = std.testing.allocator;

    // Confirmed 12 ERG; the with-unconfirmed projection adds 3 ERG of incoming
    // mempool funds (15 ERG). Amounts arrive as nanoErg integers (1 ERG = 1e9).
    var confirmed = try std.json.parseFromSlice(
        Ergo.ErgoWalletBalance,
        allocator,
        "{\"height\":1000,\"balance\":12000000000,\"assets\":[]}",
        .{ .ignore_unknown_fields = true },
    );
    defer confirmed.deinit();
    var with_unconf = try std.json.parseFromSlice(
        Ergo.ErgoWalletBalance,
        allocator,
        "{\"height\":1000,\"balance\":15000000000,\"assets\":[]}",
        .{ .ignore_unknown_fields = true },
    );
    defer with_unconf.deinit();

    const bal: models.WalletBalance = .{
        .available = @as(f64, @floatFromInt(confirmed.value.balance)) / Ergo.nano_per_erg,
        .total = @as(f64, @floatFromInt(with_unconf.value.balance)) / Ergo.nano_per_erg,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), bal.available, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), bal.total, 1e-9);
    try std.testing.expect(bal.hasPending());
}

test "a locked or uninitialized wallet reports as unavailable" {
    // The status gate: balances are only fetched when both flags are true.
    const allocator = std.testing.allocator;
    const cases = .{
        .{ "{\"isInitialized\":false,\"isUnlocked\":false}", false },
        .{ "{\"isInitialized\":true,\"isUnlocked\":false}", false },
        .{ "{\"isInitialized\":true,\"isUnlocked\":true}", true },
    };
    inline for (cases) |c| {
        var st = try std.json.parseFromSlice(
            Ergo.ErgoWalletStatus,
            allocator,
            c[0],
            .{ .ignore_unknown_fields = true },
        );
        defer st.deinit();
        const usable = st.value.isInitialized and st.value.isUnlocked;
        try std.testing.expectEqual(c[1], usable);
    }
}

test "the idempotent-unlock gate skips unlocking an already-unlocked wallet" {
    // `walletOpen`/`walletRestoreSeed` short-circuit when the node reports the
    // wallet unlocked, avoiding the spurious 400 "Wallet already unlocked" that
    // made a successful restore look like a failure. The gate is just this flag
    // (the live unlock call can't run offline), so assert the predicate directly.
    const allocator = std.testing.allocator;
    const cases = .{
        // Already unlocked → skip the unlock call (success, no-op).
        .{ "{\"isInitialized\":true,\"isUnlocked\":true}", true },
        // Initialized but locked → proceed to unlock.
        .{ "{\"isInitialized\":true,\"isUnlocked\":false}", false },
    };
    inline for (cases) |c| {
        var st = try std.json.parseFromSlice(
            Ergo.ErgoWalletStatus,
            allocator,
            c[0],
            .{ .ignore_unknown_fields = true },
        );
        defer st.deinit();
        // `walletOpen` returns early iff `isUnlocked`.
        try std.testing.expectEqual(c[1], st.value.isUnlocked);
    }
}

test "/wallet/status parses walletHeight for rescan progress" {
    const allocator = std.testing.allocator;
    // A wallet partway through a rescan: scanned to height 500000, ignoring the
    // change address and error fields we don't model.
    var st = try std.json.parseFromSlice(
        Ergo.ErgoWalletStatus,
        allocator,
        "{\"isInitialized\":true,\"isUnlocked\":true,\"changeAddress\":\"9f...\",\"walletHeight\":500000,\"error\":\"\"}",
        .{ .ignore_unknown_fields = true },
    );
    defer st.deinit();
    try std.testing.expectEqual(@as(i64, 500000), st.value.walletHeight);
}

test "rescan-progress threshold hides normal forward-sync lag, shows a real rescan" {
    // `walletRescanProgress` returns null when within `rescan_done_slack` of the
    // tip (routine 1-2 block lag) and a `{scanned,target}` when meaningfully behind
    // (a rescan-from-0). The live status/info reads can't run offline, so assert the
    // height predicate the function applies. Mirrors `walletRescanProgress`.
    const slack = Ergo.rescan_done_slack;
    const Case = struct { wallet: i64, full: i64, rescanning: bool };
    const cases = [_]Case{
        // Mid-rescan, far behind → show progress.
        .{ .wallet = 500_000, .full = 1_200_000, .rescanning = true },
        // One block behind (normal sync) → no indicator.
        .{ .wallet = 1_199_999, .full = 1_200_000, .rescanning = false },
        // Exactly at the slack edge → still counts as caught up.
        .{ .wallet = 1_200_000 - slack, .full = 1_200_000, .rescanning = false },
        // Just past the slack edge → a rescan to surface.
        .{ .wallet = 1_200_000 - slack - 1, .full = 1_200_000, .rescanning = true },
    };
    for (cases) |c| {
        const rescanning = c.full > 0 and c.wallet < c.full - slack;
        try std.testing.expectEqual(c.rescanning, rescanning);
    }
}

test "the rescan body requests a full scan from genesis" {
    const allocator = std.testing.allocator;
    const Body = struct { fromHeight: i64 = -1 };
    var parsed = try std.json.parseFromSlice(Body, allocator, Ergo.rescan_body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 0), parsed.value.fromHeight);
}

test "parses /wallet/addresses and picks the last (current) address" {
    const allocator = std.testing.allocator;

    // The node returns every derived address, oldest first — the last entry is
    // the most recently derived, i.e. the current receive address.
    const raw =
        \\["9f4QF8AD1nQ3nJahQVkMj8hFSVVzVom77b52JU7EW71Zexg6N8v","9hFxq2XJUxwWfvyDLLZCtxguDvKyPvSQiZbxvvV5f6t9r4gDsFs"]
    ;
    var parsed = try std.json.parseFromSlice([][]const u8, allocator, raw, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const addrs = parsed.value;
    try std.testing.expectEqual(@as(usize, 2), addrs.len);
    try std.testing.expectEqualStrings("9hFxq2XJUxwWfvyDLLZCtxguDvKyPvSQiZbxvvV5f6t9r4gDsFs", addrs[addrs.len - 1]);
}

test "parses /wallet/deriveNextKey into the freshly-derived address" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"derivationPath":"m/44'/429'/0'/0/2","address":"9etm7ZuqiJj3rQCsPYT6nSmYAe3hCbVVFtQpM8SIMcqvtWpHtNv"}
    ;
    var parsed = try std.json.parseFromSlice(Ergo.ErgoDeriveNext, allocator, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("9etm7ZuqiJj3rQCsPYT6nSmYAe3hCbVVFtQpM8SIMcqvtWpHtNv", parsed.value.address);
}

test "nanoFromAmount converts ERG to nanoErg and rejects bad amounts" {
    try std.testing.expectEqual(@as(?i64, 1_500_000_000), Ergo.nanoFromAmount(1.5));
    try std.testing.expectEqual(@as(?i64, 1), Ergo.nanoFromAmount(0.000000001));
    try std.testing.expect(Ergo.nanoFromAmount(0) == null);
    try std.testing.expect(Ergo.nanoFromAmount(-1.0) == null);
    try std.testing.expect(Ergo.nanoFromAmount(std.math.inf(f64)) == null);
    try std.testing.expect(Ergo.nanoFromAmount(1e30) == null);
}

test "payment/send replies parse: bare txid string on success, ErgoError on rejection" {
    const allocator = std.testing.allocator;

    // Success: the new transaction id as a bare JSON string.
    {
        var parsed = try std.json.parseFromSlice([]const u8, allocator, "\"b4bb32f1f0f2a3c9\"", .{ .allocate = .alloc_always });
        defer parsed.deinit();
        try std.testing.expectEqualStrings("b4bb32f1f0f2a3c9", parsed.value);
    }
    // Rejection: Ergo's error JSON, whose detail carries the human reason.
    {
        const raw =
            \\{"error":400,"reason":"bad.request","detail":"Bad request Not enough boxes to assemble a transaction"}
        ;
        var parsed = try std.json.parseFromSlice(Ergo.ErgoError, allocator, raw, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqualStrings("Bad request Not enough boxes to assemble a transaction", parsed.value.detail);
    }
}

test "coin vtable exposes receive + send + transaction history for Ergo" {
    var e: Ergo = .{};
    const c = e.coin();
    try std.testing.expect(c.supportsReceiveAddress());
    try std.testing.expect(c.supportsSend());
    // History is derived by re-reading each wallet tx through the node's extra
    // index (valued + dated), so the Transactions tab shows live data.
    try std.testing.expect(c.supportsTransactions());
}

test "walletTxFromIndexed nets our outputs against our inputs" {
    const ours_a = "9fRAWhdxEsTcdb8PhGNrZfwqa7h4o9Wpad";
    const ours_b = "9hHDQb26AjnJUXxcqriqY1mnhpLuUeC";
    const theirs = "9gKDVmfsA6J4b7kX8rVmn6Kv2SYb5sZ";
    const wallet: []const []const u8 = &.{ ours_a, ours_b };

    // A plain receive: one output pays 5 ERG to us, and the tx has no input of
    // ours (someone else's boxes funded it). Net = +5 ERG, received.
    {
        const tx: Ergo.ErgoIndexedTx = .{
            .timestamp = 1_700_000_000_000, // ms
            .numConfirmations = 12,
            .inputs = &.{.{ .address = theirs, .value = 5_000_000_000 }},
            .outputs = &.{.{ .address = ours_a, .value = 5_000_000_000 }},
        };
        const wtx = Ergo.walletTxFromIndexed(tx, wallet);
        try std.testing.expectEqual(models.TxDirection.received, wtx.direction);
        try std.testing.expectApproxEqAbs(@as(f64, 5.0), wtx.amount, 1e-9);
        try std.testing.expectEqual(@as(i64, 1_700_000_000), wtx.time); // ms → s
        try std.testing.expectEqual(@as(i64, 12), wtx.confirmations);
    }

    // A send: we spend a 10 ERG input of ours, pay 3 ERG to a stranger, and take
    // 6.9 ERG change back (0.1 ERG fee to a non-wallet miner box). Net to us =
    // 6.9 − 10 = −3.1 ERG (the payment plus fee), sent.
    {
        const tx: Ergo.ErgoIndexedTx = .{
            .timestamp = 1_700_000_500_000,
            .numConfirmations = 1,
            .inputs = &.{.{ .address = ours_a, .value = 10_000_000_000 }},
            .outputs = &.{
                .{ .address = theirs, .value = 3_000_000_000 },
                .{ .address = ours_b, .value = 6_900_000_000 }, // change back to us
                .{ .address = theirs, .value = 100_000_000 }, // miner fee box
            },
        };
        const wtx = Ergo.walletTxFromIndexed(tx, wallet);
        try std.testing.expectEqual(models.TxDirection.sent, wtx.direction);
        try std.testing.expectApproxEqAbs(@as(f64, 3.1), wtx.amount, 1e-9);
        try std.testing.expectEqual(@as(i64, 1), wtx.confirmations);
    }
}

test "walletTxFromIndexed parses an indexed-tx JSON body and ignores unknown fields" {
    const allocator = std.testing.allocator;
    const ours = "9fRAWhdxEsTcdb8PhGNrZfwqa7h4o9Wpad";
    const wallet: []const []const u8 = &.{ours};

    // Trimmed shape of `/blockchain/transaction/byId` — extra fields (boxId,
    // ergoTree, assets, spendingHeight, blockId, globalIndex, …) must be ignored.
    const raw =
        \\{"id":"abc","blockId":"deadbeef","inclusionHeight":100,"timestamp":1700000000000,
        \\ "numConfirmations":7,"globalIndex":42,"size":300,
        \\ "inputs":[{"boxId":"i0","value":8000000000,"address":"9gKDVmfsA6J4b7kX8rVmn6Kv2SYb5sZ","ergoTree":"00"}],
        \\ "outputs":[{"boxId":"o0","value":7500000000,"address":"9fRAWhdxEsTcdb8PhGNrZfwqa7h4o9Wpad","ergoTree":"00","assets":[]},
        \\            {"boxId":"o1","value":500000000,"address":"9gKDVmfsA6J4b7kX8rVmn6Kv2SYb5sZ","ergoTree":"00"}]}
    ;
    var parsed = try std.json.parseFromSlice(Ergo.ErgoIndexedTx, allocator, raw, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer parsed.deinit();

    // Not ours in: 0; ours out: 7.5 ERG → received 7.5.
    const wtx = Ergo.walletTxFromIndexed(parsed.value, wallet);
    try std.testing.expectEqual(models.TxDirection.received, wtx.direction);
    try std.testing.expectApproxEqAbs(@as(f64, 7.5), wtx.amount, 1e-9);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), wtx.time);
    try std.testing.expectEqual(@as(i64, 7), wtx.confirmations);
}

test "the extra-index readiness gate holds until the index catches up" {
    // While the index lags the tip by more than the slack, the tab must stay
    // empty rather than read from a partial index; once within slack, it's ready.
    const slack = Ergo.index_ready_slack;
    const cases = .{
        .{ Ergo.ErgoIndexedHeight{ .indexedHeight = 0, .fullHeight = 0 }, false }, // not synced
        .{ Ergo.ErgoIndexedHeight{ .indexedHeight = 500, .fullHeight = 1000 }, false }, // catching up
        .{ Ergo.ErgoIndexedHeight{ .indexedHeight = 1000 - slack, .fullHeight = 1000 }, true }, // within slack
        .{ Ergo.ErgoIndexedHeight{ .indexedHeight = 1000, .fullHeight = 1000 }, true }, // caught up
    };
    inline for (cases) |c| {
        const ih = c[0];
        const ready = ih.fullHeight > 0 and ih.indexedHeight >= ih.fullHeight - slack;
        try std.testing.expectEqual(c[1], ready);
    }
}

test "Ergo identifies its daemon process by command line, not by name" {
    // The node is a jar: `java -jar ergo-<ver>.jar` runs as `java`, so a liveness
    // check against `daemonFile()` matches nothing and the GUI reads a healthy,
    // still-starting node as stopped. The needle has to be the versioned jar —
    // specific enough that another JVM on the machine can't answer for us.
    var e: Ergo = .{};
    const needle = e.coin().daemonProcessCmdline() orelse
        return error.ErgoMustMatchByCmdline;
    try std.testing.expectEqualStrings(Ergo.jar_file, needle);
    try std.testing.expect(std.mem.endsWith(u8, needle, ".jar"));
    // Not the bare interpreter, which every other Java program shares.
    try std.testing.expect(!std.mem.eql(u8, needle, "java"));
}

test "a coin whose daemon runs under its own name declares no cmdline match" {
    // The hook is the exception, not the rule: the default must stay null so
    // every ordinary coin keeps matching by process name.
    const Nexa = @import("nexa.zig").Nexa;
    var n: Nexa = .{};
    try std.testing.expect(n.coin().daemonProcessCmdline() == null);
}

test "Ergo declares no headers pre-synchronization pass" {
    // Ergo isn't bitcoin-derived: it commits every header as it arrives, so the
    // frontend's Core-only "stalled committed headers → presync" inference must
    // never fire for it. Wiring this off is what keeps a node with headers at the
    // tip and blocks still downloading from reading as "Pre-synching headers…".
    var e: Ergo = .{};
    try std.testing.expect(!e.coin().hasHeaderPresync());
}
