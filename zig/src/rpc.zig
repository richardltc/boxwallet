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
        "{{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"{s}\",\"params\":[]}}",
        .{method},
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

test "basic auth header is correctly base64-encoded" {
    const allocator = std.testing.allocator;
    const header = try basicAuthHeader(allocator, "nexarpc", "secret");
    defer allocator.free(header);
    // base64("nexarpc:secret") == "bmV4YXJwYzpzZWNyZXQ="
    try std.testing.expectEqualStrings("Basic bmV4YXJwYzpzZWNyZXQ=", header);
}
