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

    return std.json.parseFromSlice(
        models.JsonRpcResponse(T),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
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

test "basic auth header is correctly base64-encoded" {
    const allocator = std.testing.allocator;
    const header = try basicAuthHeader(allocator, "nexarpc", "secret");
    defer allocator.free(header);
    // base64("nexarpc:secret") == "bmV4YXJwYzpzZWNyZXQ="
    try std.testing.expectEqualStrings("Basic bmV4YXJwYzpzZWNyZXQ=", header);
}
