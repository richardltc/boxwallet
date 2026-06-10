const std = @import("std");
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
    const raw = try call(allocator, auth, method);
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

/// Estimate the network's best block height as the maximum `synced_headers`
/// reported across connected peers (via `getpeerinfo`). This is the tip a
/// syncing node is catching up to — `getblockchaininfo` reports only the local
/// `headers`/`blocks`, not the target. Returns 0 when there are no peers (or
/// none report a height), so callers can fall back to local heights.
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
        if (p.synced_headers > max) max = p.synced_headers;
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

test "network height is the max synced_headers across peers" {
    // Canned getpeerinfo (subset of the real per-peer fields) — proves the parse
    // + max that `networkHeight` performs, without a running daemon. Peers report
    // differing heights; the highest is the network tip estimate.
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
        if (p.synced_headers > max) max = p.synced_headers;
    }
    try std.testing.expectEqual(@as(usize, 3), peers.len);
    try std.testing.expectEqual(@as(i64, 4071173), max);
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
        if (p.synced_headers > max) max = p.synced_headers;
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

test "basic auth header is correctly base64-encoded" {
    const allocator = std.testing.allocator;
    const header = try basicAuthHeader(allocator, "nexarpc", "secret");
    defer allocator.free(header);
    // base64("nexarpc:secret") == "bmV4YXJwYzpzZWNyZXQ="
    try std.testing.expectEqualStrings("Basic bmV4YXJwYzpzZWNyZXQ=", header);
}
