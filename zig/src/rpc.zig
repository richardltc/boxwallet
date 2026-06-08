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

test "basic auth header is correctly base64-encoded" {
    const allocator = std.testing.allocator;
    const header = try basicAuthHeader(allocator, "nexarpc", "secret");
    defer allocator.free(header);
    // base64("nexarpc:secret") == "bmV4YXJwYzpzZWNyZXQ="
    try std.testing.expectEqualStrings("Basic bmV4YXJwYzpzZWNyZXQ=", header);
}
