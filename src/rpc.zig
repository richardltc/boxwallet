const std = @import("std");
const builtin = @import("builtin");
const models = @import("models.zig");

/// Perform a JSON-RPC POST against a coin daemon and return the raw response
/// body. Caller owns the returned slice.
///
/// Matches the Go backend's request shape: a `text/plain` body carrying the
/// JSON-RPC 1.0 envelope, with HTTP basic auth. bitcoin-derived daemons return
/// the RPC error (if any) inside the body even on non-2xx status, so we hand
/// the body back regardless of status and let the caller parse it — except for
/// 401, which means the credentials are wrong and there is nothing to parse.
pub fn call(
    allocator: std.mem.Allocator,
    auth: models.CoinAuth,
    method: []const u8,
) ![]u8 {
    return callParams(allocator, auth, method, "[]");
}

/// Like `call`, but with an explicit JSON `params` array (e.g. `["BoxWallet"]`
/// for `createwallet`/`loadwallet`). `params` is spliced verbatim into the
/// request body, so the caller is responsible for it being valid JSON.
pub fn callParams(
    allocator: std.mem.Allocator,
    auth: models.CoinAuth,
    method: []const u8,
    params: []const u8,
) ![]u8 {
    // 0.16's std.http.Client runs on the new std.Io interface. A blocking
    // thread-pool backed Io is the simplest backend for a CLI/TUI.
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();

    var client: std.http.Client = .{ .allocator = allocator, .io = threaded.io() };
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://{s}:{s}", .{ auth.ip_address, auth.port });
    defer allocator.free(url);

    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"{s}\",\"params\":{s}}}",
        .{ method, params },
    );
    defer allocator.free(payload);

    const auth_header = try basicAuthHeader(allocator, auth.rpc_user, auth.rpc_password);
    defer allocator.free(auth_header);

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .response_writer = &body.writer,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain" },
            .{ .name = "authorization", .value = auth_header },
        },
    });

    if (result.status == .unauthorized) return error.AuthFailed;

    return body.toOwnedSlice();
}

/// Issue `method` with `params` and succeed only if the daemon reports no error
/// (`"error":null` in the reply). Used for fire-and-forget wallet commands
/// (`encryptwallet`, `walletpassphrase`, `walletlock`) where we don't need the
/// result, only whether it worked. Mirrors `ensureWallet`'s string-check
/// approach — no full parse, so memory stays flat (one bounded reply buffer,
/// freed on return). A failure (wrong passphrase, warm-up `-28`, a transport
/// error) surfaces as `error.RpcCallFailed`.
pub fn callExpectOk(
    allocator: std.mem.Allocator,
    auth: models.CoinAuth,
    method: []const u8,
    params: []const u8,
) !void {
    const reply = try callParams(allocator, auth, method, params);
    defer allocator.free(reply);
    if (std.mem.indexOf(u8, reply, "\"error\":null") != null) return;
    return error.RpcCallFailed;
}

/// Probe a bitcoin-derived daemon for its warm-up phase: call `method` and scan
/// the reply for the "-28 in warm-up" phase string the daemon emits before its
/// RPC is live (e.g. "Verifying blocks…"). `method` should be one the daemon
/// supports (`getinfo` / `getnetworkinfo`), so a normal (post-warm-up) reply
/// carries none of the phase strings and reads as `.none`. Memory stays flat —
/// one bounded reply buffer, freed on return, only the resulting enum kept.
pub fn loadingPhase(
    allocator: std.mem.Allocator,
    auth: models.CoinAuth,
    method: []const u8,
) !models.LoadingPhase {
    const reply = try call(allocator, auth, method);
    defer allocator.free(reply);
    return scanLoadingPhase(reply);
}

/// Classify a daemon reply body into a warm-up `LoadingPhase` by the phase string
/// it carries, mirroring the Go installers' substring checks. The more specific
/// phases are tested before `loading`, since a warm-up message like "Loading
/// block index…" only carries "Loading" while the others are distinct words.
pub fn scanLoadingPhase(body: []const u8) models.LoadingPhase {
    if (std.mem.indexOf(u8, body, "Rescanning") != null) return .rescanning;
    if (std.mem.indexOf(u8, body, "Rewinding") != null) return .rewinding;
    if (std.mem.indexOf(u8, body, "Verifying") != null) return .verifying;
    if (std.mem.indexOf(u8, body, "Calculating money supply") != null) return .calculating;
    if (std.mem.indexOf(u8, body, "Loading") != null) return .loading;
    return .none;
}

/// JSON-escape `s` and wrap it in double quotes, returning e.g. `"a\"b"`. Used to
/// splice a user-supplied passphrase into an RPC params array safely — a raw
/// passphrase containing `"` or `\` would otherwise produce malformed JSON (or
/// worse, let the input break out of the string). Caller owns the returned slice.
pub fn jsonQuote(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.encodeJsonString(s, .{}, &out.writer);
    return out.toOwnedSlice();
}

/// Call `method` and parse the `result` field into `T`.
/// Caller must `deinit` the returned `Parsed` to free everything.
pub fn callParsed(
    comptime T: type,
    allocator: std.mem.Allocator,
    auth: models.CoinAuth,
    method: []const u8,
) !std.json.Parsed(models.JsonRpcResponse(T)) {
    return callParsedParams(T, allocator, auth, method, "[]");
}

/// Like `callParsed`, but with an explicit JSON `params` array (e.g. `[123]` for
/// `getblockhash`). `params` is spliced verbatim, so the caller is responsible
/// for it being valid JSON. See `callParsed` for the `.alloc_always` rationale.
pub fn callParsedParams(
    comptime T: type,
    allocator: std.mem.Allocator,
    auth: models.CoinAuth,
    method: []const u8,
    params: []const u8,
) !std.json.Parsed(models.JsonRpcResponse(T)) {
    const raw = try callParams(allocator, auth, method, params);
    defer allocator.free(raw);

    // `.alloc_always` is essential here: we free `raw` on return, so the parsed
    // string fields must be copied into the `Parsed` arena rather than left
    // referencing `raw`. The slice-input default (`.alloc_if_needed`) would leave
    // unescaped strings pointing into the freed buffer — a use-after-free the
    // caller can't see (integer fields survive, strings dangle).
    return std.json.parseFromSlice(
        models.JsonRpcResponse(T),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
}

/// Estimate the network's best block height across connected peers (via
/// `getpeerinfo`). This is the tip a syncing node is catching up to —
/// `getblockchaininfo` reports only the local `headers`/`blocks`, not the
/// target. Returns 0 when there are no peers (or none report a height), so
/// callers can fall back to local heights.
///
/// Per peer we take the max of `startingheight` (its tip when it connected) and
/// `synced_headers` (our header progress against it), then the max across peers.
/// `startingheight` is what keeps the estimate honest on a *fresh* sync:
/// `synced_headers` tracks our own download, so early on it equals our local
/// header count and would peg the Headers bar at 100%. `synced_headers` is still
/// folded in because it eventually climbs past the connect-time tip as the chain
/// grows during a long sync.
///
/// The peer array is parsed into a minimal `[]PeerInfo` (every other field
/// dropped via `ignore_unknown_fields`) and freed on return — only the single
/// resulting height is kept, so memory stays flat regardless of peer count.
pub fn networkHeight(
    allocator: std.mem.Allocator,
    auth: models.CoinAuth,
) !i64 {
    var parsed = try callParsed([]models.PeerInfo, allocator, auth, "getpeerinfo");
    defer parsed.deinit();

    const peers = parsed.value.result orelse return 0;
    var max: i64 = 0;
    for (peers) |p| {
        max = @max(max, @max(p.startingheight, p.synced_headers));
    }
    return max;
}

/// Ensure a wallet named `name` is loaded on a Bitcoin-Core 0.21+ daemon,
/// creating it on first run.
///
/// These daemons no longer auto-create a default wallet, and they auto-load only
/// the *unnamed* legacy wallet — so a named wallet must be loaded explicitly on
/// every fresh daemon start, and created the very first time. We therefore try
/// `loadwallet` first and fall back to `createwallet` (which also loads it).
/// Idempotent: an already-loaded or already-existing wallet reads as success.
///
/// Returns success only once a load or create is *confirmed*; otherwise it
/// returns `error.WalletNotReady` so the caller retries on the next poll. This
/// matters during daemon warm-up, when Core answers every RPC with an HTTP-200
/// `-28 "Loading…"` error — without the confirmation check we'd wrongly mark the
/// wallet ready and never actually create it. A transport failure (daemon not up)
/// propagates the underlying error, also a retry.
pub fn ensureWallet(
    allocator: std.mem.Allocator,
    auth: models.CoinAuth,
    name: []const u8,
) !void {
    const params = try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{name});
    defer allocator.free(params);

    // 1. Try to load an existing wallet. A clean load (`"error":null`) or an
    //    already-loaded wallet → done.
    {
        const load = try callParams(allocator, auth, "loadwallet", params);
        defer allocator.free(load);
        if (std.mem.indexOf(u8, load, "\"error\":null") != null) return;
        if (std.mem.indexOf(u8, load, "already loaded") != null) return;
    }

    // 2. Couldn't load it (most likely it doesn't exist yet) — create it, which
    //    also loads it. Only a confirmed success (`"error":null`) counts; anything
    //    else (warm-up `-28`, a transient error) is a retry.
    const create = try callParams(allocator, auth, "createwallet", params);
    defer allocator.free(create);
    if (std.mem.indexOf(u8, create, "\"error\":null") != null) return;

    return error.WalletNotReady;
}

// --- Bitcoin-family wallet RPC helpers -------------------------------------
//
// The transactions / receive-address / send surface is the same JSON-RPC shape
// on every bitcoin-derived daemon (`listtransactions` / `getnewaddress` & co /
// `sendtoaddress`), so — like `ensureWallet` and `networkHeight` above — the
// mechanics live here once and each coin calls in with its own parameters: its
// category→direction map (stake/mint categories differ per fork), its amount
// denomination (Nexa is 2dp, everyone else 8dp), and which address-RPC
// generation its daemon speaks (accounts-era vs label-based).

/// One bitcoin-style `listtransactions` entry (the subset BoxWallet uses).
pub const ListTxEntry = struct {
    category: []const u8 = "",
    amount: f64 = 0,
    time: i64 = 0,
    confirmations: i64 = 0,
};

/// The wallet's most recent transactions, newest-first, via
/// `listtransactions "*" <limit> 0`. Every bitcoin-derived daemon returns the
/// window oldest-to-newest (upstream `rpcwallet.cpp` builds it ascending), so
/// the result is reversed here. `dir_fn` is the coin's own category map;
/// entries it maps to null (`"move"`, unknown categories) are dropped.
pub fn walletTransactions(
    allocator: std.mem.Allocator,
    auth: models.CoinAuth,
    limit: usize,
    dir_fn: *const fn ([]const u8) ?models.TxDirection,
) ![]models.WalletTx {
    const params = try std.fmt.allocPrint(allocator, "[\"*\",{d},0]", .{limit});
    defer allocator.free(params);
    var parsed = try callParsedParams([]ListTxEntry, allocator, auth, "listtransactions", params);
    defer parsed.deinit();

    const raw = parsed.value.result orelse return error.EmptyRpcResult;
    return mapListTransactions(allocator, raw, dir_fn);
}

/// Reverse `raw` (oldest-to-newest, as the daemon returns it) into newest-first
/// `WalletTx`es, mapping each `category` via `dir_fn` and dropping entries with
/// no mapped direction. Split out from `walletTransactions` so the
/// mapping/ordering logic is unit-testable without a live RPC call. Two passes
/// (count, then fill) so the returned slice is allocated at its exact final
/// length — callers free exactly what was allocated.
pub fn mapListTransactions(
    allocator: std.mem.Allocator,
    raw: []const ListTxEntry,
    dir_fn: *const fn ([]const u8) ?models.TxDirection,
) ![]models.WalletTx {
    var count: usize = 0;
    for (raw) |r| {
        if (dir_fn(r.category) != null) count += 1;
    }

    var out = try allocator.alloc(models.WalletTx, count);
    var n: usize = 0;
    var i = raw.len;
    while (i > 0) {
        i -= 1;
        const direction = dir_fn(raw[i].category) orelse continue;
        out[n] = .{
            .direction = direction,
            // A "send" amount arrives negated (ValueFromAmount(-nDebit) upstream);
            // `direction` carries the sign for the frontend.
            .amount = @abs(raw[i].amount),
            .time = raw[i].time,
            .confirmations = raw[i].confirmations,
        };
        n += 1;
    }
    return out;
}

/// The wallet's receive address on an **accounts-era** daemon (Divi, Nexa —
/// pre-0.17 wallet RPC). `force_new` false reads the stable "current" address
/// via `getaccountaddress ""` (which upstream silently rotates once it's been
/// paid); true mints a fresh key via `getnewaddress` (no params, so the default
/// account/address type applies on every such daemon) — only ever called on an
/// explicit user-requested rotation, never polled. Caller owns the result.
pub fn receiveAddressAccount(
    allocator: std.mem.Allocator,
    auth: models.CoinAuth,
    force_new: bool,
) ![]const u8 {
    const method: []const u8 = if (force_new) "getnewaddress" else "getaccountaddress";
    const params: []const u8 = if (force_new) "[]" else "[\"\"]";
    var parsed = try callParsedParams([]const u8, allocator, auth, method, params);
    defer parsed.deinit();
    const addr = parsed.value.result orelse return error.EmptyRpcResult;
    return allocator.dupe(u8, addr); // parsed.deinit() frees its arena below us
}

/// Per-address value in a `getaddressesbylabel` reply — only the keys (the
/// addresses) matter, so the object is parsed into the smallest struct that
/// keeps memory flat.
const LabeledAddressInfo = struct { purpose: []const u8 = "" };

/// The wallet's receive address on a **label-based** daemon (Bitcoin Core 0.17+
/// forks, which removed the accounts API and with it any "current address"
/// RPC). BoxWallet recreates the stable-current-address semantics with a marker
/// label: the address under `label` is the current one.
///
///   * `force_new` false: return the address holding `label`, minting the first
///     one (`getnewaddress <label>`) on a fresh wallet (`getaddressesbylabel`
///     answers -11 / no result until then).
///   * `force_new` true (explicit user-requested rotation): move any previous
///     address off the marker label first (`setlabel <addr> ""` — the old
///     address still belongs to the wallet and stays spendable/watched; the
///     label is only BoxWallet's "current" pointer), then mint a fresh labelled
///     one. Keeping exactly one address under the label is what makes the
///     "current" read stable across sessions even after rotations.
///
/// Caller owns the result.
pub fn receiveAddressLabeled(
    allocator: std.mem.Allocator,
    auth: models.CoinAuth,
    force_new: bool,
    label: []const u8,
) ![]const u8 {
    const label_q = try jsonQuote(allocator, label);
    defer allocator.free(label_q);
    const label_params = try std.fmt.allocPrint(allocator, "[{s}]", .{label_q});
    defer allocator.free(label_params);

    if (!force_new) {
        var parsed = try callParsedParams(std.json.ArrayHashMap(LabeledAddressInfo), allocator, auth, "getaddressesbylabel", label_params);
        defer parsed.deinit();
        if (parsed.value.result) |labeled| {
            const addrs = labeled.map.keys();
            if (addrs.len > 0) return allocator.dupe(u8, addrs[0]);
        }
        // No labelled address yet (fresh wallet answers error -11) — fall
        // through and mint the first one.
    } else {
        // Best-effort: a failed relabel only means an extra address keeps the
        // marker label; the fresh mint below still becomes a valid current.
        var parsed = callParsedParams(std.json.ArrayHashMap(LabeledAddressInfo), allocator, auth, "getaddressesbylabel", label_params) catch null;
        if (parsed) |*p| {
            defer p.deinit();
            if (p.value.result) |labeled| {
                for (labeled.map.keys()) |addr| {
                    const addr_q = try jsonQuote(allocator, addr);
                    defer allocator.free(addr_q);
                    const sp = try std.fmt.allocPrint(allocator, "[{s},\"\"]", .{addr_q});
                    defer allocator.free(sp);
                    callExpectOk(allocator, auth, "setlabel", sp) catch {};
                }
            }
        }
    }

    var parsed = try callParsedParams([]const u8, allocator, auth, "getnewaddress", label_params);
    defer parsed.deinit();
    const addr = parsed.value.result orelse return error.EmptyRpcResult;
    return allocator.dupe(u8, addr);
}

/// Send `amount` to `address` via `sendtoaddress`. The daemon does its own
/// address validation, lock-state check, and balance check — `SendResult`
/// carries whichever of those (or the success txid) came back, verbatim,
/// rather than collapsing a rejected send into a generic error. `decimals` is
/// the coin's amount denomination (8 for the bitcoin-lineage coins, 2 for
/// Nexa, whose daemon parses amounts as fixed-point with 2 places and rejects
/// anything finer).
pub fn sendToAddress(
    allocator: std.mem.Allocator,
    auth: models.CoinAuth,
    address: []const u8,
    amount: f64,
    decimals: u8,
) !models.SendResult {
    const addr_q = try jsonQuote(allocator, address);
    defer allocator.free(addr_q);
    var amount_buf: [64]u8 = undefined;
    const params = try std.fmt.allocPrint(allocator, "[{s},{s}]", .{ addr_q, formatAmountFixed(&amount_buf, amount, decimals) });
    defer allocator.free(params);

    var parsed = try callParsedParams([]const u8, allocator, auth, "sendtoaddress", params);
    defer parsed.deinit();
    if (parsed.value.result) |txid| return .{ .ok = try allocator.dupe(u8, txid) };
    if (parsed.value.@"error") |e| return .{ .failed = try allocator.dupe(u8, e.message) };
    return .{ .failed = "no response from daemon" };
}

/// Format `amount` as a fixed `decimals`-place decimal string (never scientific
/// notation) for splicing into an RPC params array — split out as a pure helper
/// so the formatting is unit-testable without a live daemon. Returns a slice
/// into `buf` (callers pass a `[64]u8`, ample for any sane amount); a value too
/// large to format falls back to "0", which every daemon rejects as a too-small
/// amount rather than sending anything unintended.
pub fn formatAmountFixed(buf: []u8, amount: f64, decimals: u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.printFloat(amount, .{ .mode = .decimal, .precision = decimals }) catch return "0";
    return w.buffered();
}

/// Cheap TCP liveness probe for a daemon's RPC endpoint. A successful connect
/// proves the daemon is bound and accepting connections — i.e. *up* — regardless
/// of whether it answers an RPC promptly. This is the distinction that matters
/// for a daemon under load: a healthy node accepts the connection instantly yet
/// can stall an RPC *reply* for several seconds (e.g. Nerva serializing
/// `get_info` behind its blockchain lock while relaying across dozens of peers),
/// whereas a genuinely stopped daemon refuses the connection outright. So a
/// status fetch that times out while this probe still succeeds means "up but
/// busy", not "down" — letting the UI hold the daemon at "running" rather than
/// flipping it to "stopped" on a transient stall.
///
/// Localhost-only (the daemon binds 127.0.0.1), so the connect returns
/// immediately — accepted (daemon up) or `ConnectionRefused` (down) — with no
/// slow path that would need a timeout. (A connect *timeout* isn't even
/// available here: the 0.16 threaded `Io` backend panics on
/// `netConnectIpPosix with timeout`, and a loopback connect never blocks long
/// enough to want one.) Best-effort: anything that isn't a clean connect reads
/// as not reachable.
pub fn daemonReachable(allocator: std.mem.Allocator, auth: models.CoinAuth) bool {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const port = std.fmt.parseInt(u16, auth.port, 10) catch return false;
    const addr = std.Io.net.IpAddress.parseIp4(auth.ip_address, port) catch return false;
    const stream = addr.connect(io, .{ .mode = .stream }) catch return false;
    stream.close(io);
    return true;
}

/// Build an `Authorization: Basic <base64(user:password)>` header value.
fn basicAuthHeader(allocator: std.mem.Allocator, user: []const u8, password: []const u8) ![]u8 {
    const creds = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ user, password });
    defer allocator.free(creds);

    const enc = std.base64.standard.Encoder;
    const b64 = try allocator.alloc(u8, enc.calcSize(creds.len));
    defer allocator.free(b64);
    _ = enc.encode(b64, creds);

    return std.fmt.allocPrint(allocator, "Basic {s}", .{b64});
}

// --- Monero-family wallet/daemon HTTP transport ---------------------------
//
// Monero-derived coins (Nerva, Salvium) talk a plain HTTP/1.1 `POST` to a local
// `json_rpc`/`stop_daemon` endpoint, and their *wallet* RPC enforces **HTTP
// Digest** auth (`monero-wallet-rpc --rpc-login user:pass`) — basic auth is not
// accepted. `moneroPost` is the one transport for both: it bounds every blocking
// send/recv with a timeout (so a daemon that accepts but never answers fails fast
// instead of hanging), and transparently answers a `401` Digest challenge when
// credentials are present. The daemon RPC is keyless, so an empty `auth.rpc_user`
// just skips the digest handshake.

const MoneroExchange = struct { status: u16, www_authenticate: ?[]u8, body: []u8 };

/// POST `payload` to `path` on `auth`'s endpoint, answering a Digest challenge
/// when `auth.rpc_user` is set. `timeout_ms` bounds each blocking socket op on
/// POSIX. Returns the raw response body (caller owns it); `401` after the retry
/// (or with no usable challenge) is `error.AuthFailed`.
pub fn moneroPost(
    allocator: std.mem.Allocator,
    auth: models.CoinAuth,
    path: []const u8,
    payload: []const u8,
    timeout_ms: u32,
) ![]u8 {
    const first = try moneroExchange(allocator, auth, path, payload, timeout_ms, null);

    // No auth required (daemon RPC), or a non-401 reply: hand the body back as-is,
    // mirroring the bitcoin-style "parse the body regardless of status" contract.
    if (first.status != 401 or auth.rpc_user.len == 0) {
        if (first.www_authenticate) |w| allocator.free(w);
        if (first.status == 401) {
            allocator.free(first.body);
            return error.AuthFailed;
        }
        return first.body;
    }

    // Authenticated wallet RPC: compute the Digest response and retry once with a
    // fresh nonce (Monero challenges every request, so there's no nonce to reuse).
    allocator.free(first.body);
    const challenge = first.www_authenticate orelse return error.AuthFailed;
    defer allocator.free(challenge);

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const av = (try digestAuthValue(allocator, threaded.io(), challenge, auth.rpc_user, auth.rpc_password, "POST", path)) orelse
        return error.AuthFailed;
    defer allocator.free(av);

    const second = try moneroExchange(allocator, auth, path, payload, timeout_ms, av);
    if (second.www_authenticate) |w| allocator.free(w);
    if (second.status == 401) {
        allocator.free(second.body);
        return error.AuthFailed;
    }
    return second.body;
}

/// One HTTP round-trip for `moneroPost`. `authorization`, when given, is sent as
/// the `Authorization` header value. Returns the status, any `WWW-Authenticate`
/// value (owned), and the body (owned) — it never turns a `401` into an error so
/// the caller can drive the digest retry.
fn moneroExchange(
    allocator: std.mem.Allocator,
    auth: models.CoinAuth,
    path: []const u8,
    payload: []const u8,
    timeout_ms: u32,
    authorization: ?[]const u8,
) !MoneroExchange {
    if (builtin.os.tag == .windows)
        return moneroExchangeWindows(allocator, auth, path, payload, authorization);

    const posix = std.posix;

    const ip = parseIp4(auth.ip_address) catch return error.InvalidRpcAddress;
    const port = std.fmt.parseInt(u16, auth.port, 10) catch return error.InvalidRpcAddress;

    const sock_rc = posix.system.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    if (posix.errno(sock_rc) != .SUCCESS) return error.RpcConnectFailed;
    const sock: posix.socket_t = @intCast(sock_rc);
    defer _ = posix.system.close(sock);

    const tv = posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};

    var addr: posix.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = ip,
    };
    if (posix.errno(posix.system.connect(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.in))) != .SUCCESS)
        return error.RpcConnectFailed;

    const auth_line = if (authorization) |a|
        try std.fmt.allocPrint(allocator, "Authorization: {s}\r\n", .{a})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(auth_line);

    const req = try std.fmt.allocPrint(
        allocator,
        "POST {s} HTTP/1.1\r\nHost: {s}:{s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n{s}Connection: close\r\n\r\n{s}",
        .{ path, auth.ip_address, auth.port, payload.len, auth_line, payload },
    );
    defer allocator.free(req);
    try sockWriteAll(sock, req);

    const max_response = 1 << 20;
    var resp: std.Io.Writer.Allocating = .init(allocator);
    defer resp.deinit();
    var buf: [4096]u8 = undefined;
    var header_end: ?usize = null;
    var content_len: ?usize = null;
    var status: u16 = 0;
    var www: ?[]u8 = null;
    errdefer if (www) |w| allocator.free(w);
    while (true) {
        const n = posix.read(sock, &buf) catch |err| switch (err) {
            error.WouldBlock => return error.Timeout,
            else => return error.RpcReadFailed,
        };
        if (n == 0) break;
        try resp.writer.writeAll(buf[0..n]);
        if (resp.written().len > max_response) return error.ResponseTooLarge;
        if (header_end == null) {
            if (std.mem.indexOf(u8, resp.written(), "\r\n\r\n")) |idx| {
                header_end = idx + 4;
                const head = resp.written()[0..idx];
                status = statusCode(head);
                content_len = parseContentLength(head);
                if (headerValue(head, "www-authenticate")) |v| www = try allocator.dupe(u8, v);
            }
        }
        if (header_end) |he| if (content_len) |cl| {
            if (resp.written().len - he >= cl) break;
        };
    }

    const he = header_end orelse return error.RpcReadFailed;
    const all = resp.written();
    const body = if (content_len) |cl| all[he..@min(he + cl, all.len)] else all[he..];
    return .{ .status = status, .www_authenticate = www, .body = try allocator.dupe(u8, body) };
}

/// `std.http.Client` round-trip — the Windows path for `moneroExchange` (raw
/// POSIX sockets there would need `WSAStartup`). No socket timeout (the request
/// is tiny localhost JSON), but it reads the status + headers so digest works.
fn moneroExchangeWindows(
    allocator: std.mem.Allocator,
    auth: models.CoinAuth,
    path: []const u8,
    payload: []const u8,
    authorization: ?[]const u8,
) !MoneroExchange {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();

    var client: std.http.Client = .{ .allocator = allocator, .io = threaded.io() };
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://{s}:{s}{s}", .{ auth.ip_address, auth.port, path });
    defer allocator.free(url);
    const uri = try std.Uri.parse(url);

    var extra: [2]std.http.Header = undefined;
    var nh: usize = 0;
    extra[nh] = .{ .name = "content-type", .value = "application/json" };
    nh += 1;
    if (authorization) |a| {
        extra[nh] = .{ .name = "authorization", .value = a };
        nh += 1;
    }

    var req = try client.request(.POST, uri, .{ .extra_headers = extra[0..nh] });
    defer req.deinit();

    const body_buf = try allocator.dupe(u8, payload);
    defer allocator.free(body_buf);
    try req.sendBodyComplete(body_buf);

    var redirect_buffer: [4096]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    const status: u16 = @intFromEnum(response.head.status);

    var www: ?[]u8 = null;
    errdefer if (www) |w| allocator.free(w);
    {
        var it = response.head.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "www-authenticate")) {
                www = try allocator.dupe(u8, h.value);
                break;
            }
        }
    }

    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    while (true) {
        _ = reader.stream(&out.writer, .limited(64 * 1024)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return error.RpcReadFailed,
        };
        if (out.written().len > (1 << 20)) return error.ResponseTooLarge;
    }
    return .{ .status = status, .www_authenticate = www, .body = try out.toOwnedSlice() };
}

/// Write every byte of `bytes` to the socket, looping over partial writes and
/// retrying `EINTR`. A send that blocks past `SO_SNDTIMEO` surfaces as `EAGAIN`.
fn sockWriteAll(sock: std.posix.socket_t, bytes: []const u8) !void {
    const posix = std.posix;
    var i: usize = 0;
    while (i < bytes.len) {
        const rc = posix.system.write(sock, bytes.ptr + i, bytes.len - i);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const w: usize = @intCast(rc);
                if (w == 0) return error.RpcWriteFailed;
                i += w;
            },
            .INTR => continue,
            .AGAIN => return error.Timeout,
            else => return error.RpcWriteFailed,
        }
    }
}

/// Parse a dotted-quad IPv4 into a network-order `u32` for `sockaddr.in.addr`.
fn parseIp4(s: []const u8) !u32 {
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    for (&octets) |*o| {
        const part = it.next() orelse return error.InvalidIp;
        o.* = std.fmt.parseInt(u8, part, 10) catch return error.InvalidIp;
    }
    if (it.next() != null) return error.InvalidIp;
    return @bitCast(octets);
}

/// The numeric status from an HTTP status line ("HTTP/1.1 200 OK" → 200); 0 if
/// it can't be parsed.
fn statusCode(header: []const u8) u16 {
    const line_end = std.mem.indexOfScalar(u8, header, '\r') orelse header.len;
    var it = std.mem.tokenizeScalar(u8, header[0..line_end], ' ');
    _ = it.next(); // HTTP/1.1
    const code = it.next() orelse return 0;
    return std.fmt.parseInt(u16, code, 10) catch 0;
}

/// The value of header `name` from a CRLF-delimited response header block.
fn headerValue(header: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name))
            return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

/// The `Content-Length` value from a response header block, or null if absent.
fn parseContentLength(header: []const u8) ?usize {
    if (headerValue(header, "content-length")) |v|
        return std.fmt.parseInt(usize, v, 10) catch null;
    return null;
}

// --- HTTP Digest auth (RFC 2617) ------------------------------------------

/// Build an `Authorization: Digest …` header value answering `challenge` (the
/// raw `WWW-Authenticate` value). Generates a random client nonce from the OS
/// CSPRNG. Returns null when `challenge` isn't a usable Digest challenge. Caller
/// owns the result.
fn digestAuthValue(
    allocator: std.mem.Allocator,
    io: std.Io,
    challenge: []const u8,
    user: []const u8,
    password: []const u8,
    method: []const u8,
    uri: []const u8,
) !?[]u8 {
    var raw: [8]u8 = undefined;
    io.random(&raw);
    const cnonce = std.fmt.bytesToHex(raw, .lower);
    return buildDigest(allocator, challenge, user, password, method, uri, cnonce[0..]);
}

/// The deterministic core of `digestAuthValue` (explicit `cnonce` for testing).
fn buildDigest(
    allocator: std.mem.Allocator,
    challenge: []const u8,
    user: []const u8,
    password: []const u8,
    method: []const u8,
    uri: []const u8,
    cnonce: []const u8,
) !?[]u8 {
    if (!std.ascii.startsWithIgnoreCase(std.mem.trimStart(u8, challenge, " "), "digest")) return null;
    const realm = digestParam(challenge, "realm") orelse return null;
    const nonce = digestParam(challenge, "nonce") orelse return null;
    const opaque_val = digestParam(challenge, "opaque");
    const use_qop = if (digestParam(challenge, "qop")) |q| containsToken(q, "auth") else false;

    const ha1 = try md5Hex(allocator, "{s}:{s}:{s}", .{ user, realm, password });
    const ha2 = try md5Hex(allocator, "{s}:{s}", .{ method, uri });
    const nc = "00000001";

    const opaque_tail = if (opaque_val) |o|
        try std.fmt.allocPrint(allocator, ", opaque=\"{s}\"", .{o})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(opaque_tail);

    if (use_qop) {
        const response = try md5Hex(allocator, "{s}:{s}:{s}:{s}:{s}:{s}", .{ ha1[0..], nonce, nc, cnonce, "auth", ha2[0..] });
        return try std.fmt.allocPrint(
            allocator,
            "Digest username=\"{s}\", realm=\"{s}\", nonce=\"{s}\", uri=\"{s}\", algorithm=MD5, qop=auth, nc={s}, cnonce=\"{s}\", response=\"{s}\"{s}",
            .{ user, realm, nonce, uri, nc, cnonce, response[0..], opaque_tail },
        );
    }

    const response = try md5Hex(allocator, "{s}:{s}:{s}", .{ ha1[0..], nonce, ha2[0..] });
    return try std.fmt.allocPrint(
        allocator,
        "Digest username=\"{s}\", realm=\"{s}\", nonce=\"{s}\", uri=\"{s}\", response=\"{s}\"{s}",
        .{ user, realm, nonce, uri, response[0..], opaque_tail },
    );
}

/// Hex-encoded MD5 of an `allocPrint`-formatted string.
fn md5Hex(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![32]u8 {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(s, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Extract a `key=value` parameter from a Digest challenge. Handles quoted
/// (`realm="x"`) and bare (`qop=auth`) values, matching `key` only at a token
/// boundary so e.g. `nonce` doesn't also match a longer key.
fn digestParam(challenge: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, challenge, i, key)) |pos| {
        i = pos + key.len;
        if (pos != 0) {
            const prev = challenge[pos - 1];
            if (prev != ' ' and prev != ',') continue;
        }
        var j = pos + key.len;
        while (j < challenge.len and challenge[j] == ' ') j += 1;
        if (j >= challenge.len or challenge[j] != '=') continue;
        j += 1;
        while (j < challenge.len and challenge[j] == ' ') j += 1;
        if (j < challenge.len and challenge[j] == '"') {
            j += 1;
            const end = std.mem.indexOfScalarPos(u8, challenge, j, '"') orelse return null;
            return challenge[j..end];
        }
        var end = j;
        while (end < challenge.len and challenge[end] != ',' and challenge[end] != ' ') end += 1;
        return challenge[j..end];
    }
    return null;
}

/// Whether comma-separated `list` contains the exact token `token`.
fn containsToken(list: []const u8, token: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |t| if (std.mem.eql(u8, std.mem.trim(u8, t, " "), token)) return true;
    return false;
}

test "buildDigest matches the RFC 2617 §3.5 worked example" {
    const challenge =
        "Digest realm=\"testrealm@host.com\", qop=\"auth,auth-int\", " ++
        "nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\", " ++
        "opaque=\"5ccc069c403ebaf9f0171e9517f40e41\"";
    const v = (try buildDigest(
        std.testing.allocator,
        challenge,
        "Mufasa",
        "Circle Of Life",
        "GET",
        "/dir/index.html",
        "0a4f113b",
    )).?;
    defer std.testing.allocator.free(v);

    try std.testing.expect(std.mem.indexOf(u8, v, "response=\"6629fae49393a05397450978507c4ef1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "qop=auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "opaque=\"5ccc069c403ebaf9f0171e9517f40e41\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "nc=00000001") != null);
}

test "buildDigest rejects a non-Digest challenge" {
    try std.testing.expect((try buildDigest(std.testing.allocator, "Basic realm=\"x\"", "u", "p", "POST", "/json_rpc", "abc")) == null);
}

test "digestParam reads quoted and bare values at token boundaries" {
    const c = "Digest qop=auth, realm=\"r\", nonce=\"abc\", noncekey=\"zzz\"";
    try std.testing.expectEqualStrings("auth", digestParam(c, "qop").?);
    try std.testing.expectEqualStrings("r", digestParam(c, "realm").?);
    try std.testing.expectEqualStrings("abc", digestParam(c, "nonce").?);
}

test "callParsed's alloc_always keeps strings valid after the source is freed" {
    // Regression guard: `callParsed` frees the raw HTTP body before returning the
    // parsed value, so the parse must copy strings into the `Parsed` arena. With
    // the slice default (`.alloc_if_needed`) an unescaped string would dangle
    // into the freed body — integer fields survive, strings read as garbage. We
    // reproduce that lifetime here (dupe → parse → scribble + free → read).
    const allocator = std.testing.allocator;
    const Body = struct { name: []const u8 = "", n: i64 = 0 };

    const raw = try allocator.dupe(u8, "{\"result\":{\"name\":\"Staking Active\",\"n\":29}}");
    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(Body),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    // Overwrite then free the source: a copy in the arena is unaffected; a
    // reference into `raw` would now read 'X's.
    @memset(raw, 'X');
    allocator.free(raw);

    try std.testing.expectEqualStrings("Staking Active", parsed.value.result.?.name);
    try std.testing.expectEqual(@as(i64, 29), parsed.value.result.?.n);
}

test "network height is the max of startingheight/synced_headers across peers" {
    // Canned getpeerinfo (subset of the real per-peer fields) — proves the parse
    // + max that `networkHeight` performs, without a running daemon. Peers report
    // differing heights; the highest is the network tip estimate. Here the chain
    // is fully synced so `synced_headers` has overtaken each `startingheight`.
    const allocator = std.testing.allocator;
    const raw =
        \\{"result":[
        \\{"id":1,"addr":"1.2.3.4:51472","startingheight":4034443,"synced_headers":4071170,"synced_blocks":4071170},
        \\{"id":2,"addr":"5.6.7.8:51472","startingheight":4061479,"synced_headers":4071173,"synced_blocks":4071173},
        \\{"id":3,"addr":"9.9.9.9:51472","synced_headers":4071168}
        \\],"error":null,"id":"boxwallet"}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse([]models.PeerInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const peers = parsed.value.result.?;
    var max: i64 = 0;
    for (peers) |p| {
        max = @max(max, @max(p.startingheight, p.synced_headers));
    }
    try std.testing.expectEqual(@as(usize, 3), peers.len);
    try std.testing.expectEqual(@as(i64, 4071173), max);
}

test "fresh sync: network tip comes from startingheight, not lagging synced_headers" {
    // A node that just started from an empty datadir: peers advertise a tip near
    // 18.65M via `startingheight`, but `synced_headers` still tracks our own near-
    // zero header download. Using `synced_headers` alone would peg the Headers bar
    // at ~100% from the first poll; the peer's `startingheight` is the real target.
    const allocator = std.testing.allocator;
    const raw =
        \\{"result":[
        \\{"id":1,"addr":"1.2.3.4:12024","startingheight":18650123,"synced_headers":1042,"synced_blocks":1040},
        \\{"id":2,"addr":"5.6.7.8:12024","startingheight":18650118,"synced_headers":1042,"synced_blocks":1040}
        \\],"error":null,"id":"boxwallet"}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse([]models.PeerInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const peers = parsed.value.result.?;
    var max: i64 = 0;
    for (peers) |p| {
        max = @max(max, @max(p.startingheight, p.synced_headers));
    }
    try std.testing.expectEqual(@as(i64, 18650123), max);
}

test "no peers yields a zero network height" {
    const allocator = std.testing.allocator;
    const raw = "{\"result\":[],\"error\":null,\"id\":\"boxwallet\"}";

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse([]models.PeerInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const peers = parsed.value.result.?;
    var max: i64 = 0;
    for (peers) |p| {
        max = @max(max, @max(p.startingheight, p.synced_headers));
    }
    try std.testing.expectEqual(@as(usize, 0), peers.len);
    try std.testing.expectEqual(@as(i64, 0), max);
}

test "scanLoadingPhase classifies the daemon warm-up message" {
    // The bitcoin-derived "-28 in warm-up" replies carry a phase string; each maps
    // to its phase, more-specific phases winning over the generic "Loading".
    try std.testing.expectEqual(models.LoadingPhase.loading, scanLoadingPhase(
        "{\"result\":null,\"error\":{\"code\":-28,\"message\":\"Loading block index...\"}}",
    ));
    try std.testing.expectEqual(models.LoadingPhase.verifying, scanLoadingPhase(
        "{\"error\":{\"code\":-28,\"message\":\"Verifying blocks...\"}}",
    ));
    try std.testing.expectEqual(models.LoadingPhase.rescanning, scanLoadingPhase(
        "{\"error\":{\"code\":-28,\"message\":\"Rescanning...\"}}",
    ));
    try std.testing.expectEqual(models.LoadingPhase.rewinding, scanLoadingPhase(
        "{\"error\":{\"code\":-28,\"message\":\"Rewinding blocks if needed...\"}}",
    ));
    try std.testing.expectEqual(models.LoadingPhase.calculating, scanLoadingPhase(
        "{\"error\":{\"code\":-28,\"message\":\"RPC in warm-up: Calculating money supply...\"}}",
    ));
    // A normal (post-warm-up) reply carries none of the phase strings.
    try std.testing.expectEqual(models.LoadingPhase.none, scanLoadingPhase(
        "{\"result\":{\"connections\":8,\"version\":80006},\"error\":null}",
    ));
}

test "jsonQuote escapes a passphrase so it can't break out of the params array" {
    const allocator = std.testing.allocator;

    // A plain passphrase is just wrapped in quotes.
    {
        const q = try jsonQuote(allocator, "hunter2");
        defer allocator.free(q);
        try std.testing.expectEqualStrings("\"hunter2\"", q);
    }
    // Embedded quotes and backslashes are escaped, so splicing into
    // `["<pw>",0]` stays valid JSON rather than terminating the string early.
    {
        const q = try jsonQuote(allocator, "a\"b\\c");
        defer allocator.free(q);
        try std.testing.expectEqualStrings("\"a\\\"b\\\\c\"", q);
    }
}

test "daemonReachable reads an unparseable endpoint as not reachable" {
    // The guard clauses must fail closed before any socket work: a malformed
    // address or port can't be probed, so it reads as down rather than erroring.
    // (The connect path itself needs a live listener and is exercised by the app.)
    const allocator = std.testing.allocator;
    try std.testing.expect(!daemonReachable(allocator, .{
        .ip_address = "not-an-ip",
        .port = "17566",
        .rpc_user = "",
        .rpc_password = "",
    }));
    try std.testing.expect(!daemonReachable(allocator, .{
        .ip_address = "127.0.0.1",
        .port = "not-a-port",
        .rpc_user = "",
        .rpc_password = "",
    }));
}

test "formatAmountFixed is a fixed decimal at the coin's denomination, never scientific" {
    var buf: [64]u8 = undefined;
    // 8dp — the bitcoin-lineage denomination.
    try std.testing.expectEqualStrings("0.10000000", formatAmountFixed(&buf, 0.1, 8));
    try std.testing.expectEqualStrings("1.50000000", formatAmountFixed(&buf, 1.5, 8));
    try std.testing.expectEqualStrings("1234567.00000000", formatAmountFixed(&buf, 1_234_567, 8));
    // 2dp — Nexa's denomination (its daemon rejects finer precision).
    try std.testing.expectEqualStrings("0.10", formatAmountFixed(&buf, 0.1, 2));
    try std.testing.expectEqualStrings("1234567.00", formatAmountFixed(&buf, 1_234_567, 2));
}

/// Minimal category map for the mapListTransactions test — the real per-coin
/// maps live in the coin files with their own tests.
fn testDirFromCategory(category: []const u8) ?models.TxDirection {
    if (std.mem.eql(u8, category, "receive")) return .received;
    if (std.mem.eql(u8, category, "send")) return .sent;
    if (std.mem.eql(u8, category, "generate")) return .stake;
    return null;
}

test "mapListTransactions reverses to newest-first, maps categories, drops unmapped, and takes abs(amount)" {
    const allocator = std.testing.allocator;

    // The daemon returns oldest-to-newest; a "send" amount already arrives
    // negated (ValueFromAmount(-nDebit) upstream).
    const raw = [_]ListTxEntry{
        .{ .category = "generate", .amount = 5.0, .time = 100, .confirmations = 500 }, // oldest
        .{ .category = "receive", .amount = 2.5, .time = 200, .confirmations = 10 },
        .{ .category = "move", .amount = 1.0, .time = 250, .confirmations = 10 }, // dropped: unmapped
        .{ .category = "send", .amount = -1.25, .time = 300, .confirmations = 1 }, // newest
    };

    const txs = try mapListTransactions(allocator, &raw, testDirFromCategory);
    defer allocator.free(txs);

    // "move" dropped, so 4 raw entries → 3 mapped, newest-first.
    try std.testing.expectEqual(@as(usize, 3), txs.len);
    try std.testing.expectEqual(models.TxDirection.sent, txs[0].direction);
    try std.testing.expectApproxEqAbs(@as(f64, 1.25), txs[0].amount, 1e-9);
    try std.testing.expectEqual(@as(i64, 300), txs[0].time);
    try std.testing.expectEqual(models.TxDirection.received, txs[1].direction);
    try std.testing.expectEqual(models.TxDirection.stake, txs[2].direction);
    try std.testing.expectEqual(@as(i64, 500), txs[2].confirmations);
}

test "parses a listtransactions reply into ListTxEntry entries" {
    const allocator = std.testing.allocator;

    // A canned reply shaped like a bitcoin-core listtransactions result, with the
    // fields BoxWallet doesn't use (address/label/txid/...) dropped via
    // ignore_unknown_fields.
    const raw =
        \\{"result":[
        \\{"address":"bc1qabc","category":"receive","amount":2.5,"label":"","confirmations":10,"time":200},
        \\{"address":"bc1qdef","category":"send","amount":-1.25,"fee":-0.0001,"confirmations":1,"time":300}
        \\],"error":null,"id":"boxwallet"}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse([]ListTxEntry),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expectEqualStrings("receive", r[0].category);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), r[0].amount, 1e-9);
    try std.testing.expectEqualStrings("send", r[1].category);
    try std.testing.expectApproxEqAbs(@as(f64, -1.25), r[1].amount, 1e-9);
}

test "parses a getaddressesbylabel reply (dynamic address keys) and its -11 miss" {
    const allocator = std.testing.allocator;

    // The current labelled address is the object key — dynamic, so it parses via
    // std.json.ArrayHashMap rather than a fixed struct.
    {
        const raw =
            \\{"result":{"bc1qcurrentaddress":{"purpose":"receive"}},"error":null,"id":"boxwallet"}
        ;
        var parsed = try std.json.parseFromSlice(
            models.JsonRpcResponse(std.json.ArrayHashMap(LabeledAddressInfo)),
            allocator,
            raw,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        defer parsed.deinit();
        const addrs = parsed.value.result.?.map.keys();
        try std.testing.expectEqual(@as(usize, 1), addrs.len);
        try std.testing.expectEqualStrings("bc1qcurrentaddress", addrs[0]);
    }

    // A fresh wallet answers error -11 ("No addresses with label ..."): result is
    // null, which receiveAddressLabeled treats as "mint the first one".
    {
        const raw =
            \\{"result":null,"error":{"code":-11,"message":"No addresses with label boxwallet-receive"},"id":"boxwallet"}
        ;
        var parsed = try std.json.parseFromSlice(
            models.JsonRpcResponse(std.json.ArrayHashMap(LabeledAddressInfo)),
            allocator,
            raw,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        defer parsed.deinit();
        try std.testing.expect(parsed.value.result == null);
        try std.testing.expectEqual(@as(i64, -11), parsed.value.@"error".?.code);
    }
}

test "basic auth header is correctly base64-encoded" {
    const allocator = std.testing.allocator;
    const header = try basicAuthHeader(allocator, "nexarpc", "secret");
    defer allocator.free(header);
    // base64("nexarpc:secret") == "bmV4YXJwYzpzZWNyZXQ="
    try std.testing.expectEqualStrings("Basic bmV4YXJwYzpzZWNyZXQ=", header);
}
