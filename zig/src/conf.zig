const std = @import("std");
const builtin = @import("builtin");
const models = @import("models.zig");

/// Resolve a coin daemon's default data directory — where it writes its `.conf`
/// and chain data when started without an explicit `-datadir`. Mirrors a
/// bitcoin-derived daemon's platform default:
///   - POSIX:   `<home>/<posix_name>`                 e.g. `~/.divi`
///   - Windows: `<home>/AppData/Roaming/<win_name>`   e.g. `…\Roaming\DIVI`
///
/// `home_dir` is the process home directory; the caller owns the returned slice.
pub fn dataDir(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    posix_name: []const u8,
    win_name: []const u8,
) ![]const u8 {
    return if (comptime builtin.os.tag == .windows)
        std.fs.path.join(allocator, &.{ home_dir, "AppData", "Roaming", win_name })
    else
        std.fs.path.join(allocator, &.{ home_dir, posix_name });
}

/// Build RPC connection details for a coin daemon by reading its `conf_file`
/// from `data_dir` (e.g. `~/.divi/divi.conf`). The conf is a small `key=value`
/// file; we pull `rpcuser`/`rpcpassword`/`rpcport` and fall back to the supplied
/// defaults (and `127.0.0.1`) for anything it omits.
///
/// The conf is scanned line by line through a fixed 8 KiB buffer — never read
/// whole into memory — keeping with the project's flat-memory rule. All four
/// returned `CoinAuth` strings are owned by `allocator`; release them with
/// `freeAuth`.
pub fn readAuth(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    conf_file: []const u8,
    default_user: []const u8,
    default_port: []const u8,
) !models.CoinAuth {
    // Seed every field with an owned default so `freeAuth` can release them
    // uniformly and a conf that omits a key still yields a usable value.
    var auth: models.CoinAuth = .{
        .rpc_user = try allocator.dupe(u8, default_user),
        .rpc_password = try allocator.dupe(u8, ""),
        .ip_address = try allocator.dupe(u8, "127.0.0.1"),
        .port = try allocator.dupe(u8, default_port),
    };
    errdefer freeAuth(allocator, auth);

    var dir = try std.Io.Dir.cwd().openDir(io, data_dir, .{});
    defer dir.close(io);

    var file = try dir.openFile(io, conf_file, .{});
    defer file.close(io);

    // Each `takeDelimiter` returns a slice into `buf` that the next call
    // overwrites, so any value we keep is duped out immediately.
    var buf: [8 * 1024]u8 = undefined;
    var fr = file.reader(io, &buf);
    while (try fr.interface.takeDelimiter('\n')) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");

        const slot: ?*[]const u8 =
            if (std.mem.eql(u8, key, "rpcuser")) &auth.rpc_user else if (std.mem.eql(u8, key, "rpcpassword")) &auth.rpc_password else if (std.mem.eql(u8, key, "rpcport")) &auth.port else null;
        if (slot) |s| {
            const dup = try allocator.dupe(u8, val);
            allocator.free(s.*);
            s.* = dup;
        }
    }

    return auth;
}

/// Free the four strings owned by a `CoinAuth` built by `readAuth`.
pub fn freeAuth(allocator: std.mem.Allocator, auth: models.CoinAuth) void {
    allocator.free(auth.rpc_user);
    allocator.free(auth.rpc_password);
    allocator.free(auth.ip_address);
    allocator.free(auth.port);
}

test "dataDir builds the coin home under the process home (posix)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const dir = try dataDir(allocator, "/home/alice", ".divi", "DIVI");
    defer allocator.free(dir);
    try std.testing.expectEqualStrings("/home/alice/.divi", dir);
}

test "readAuth parses rpc creds from a conf and falls back to defaults" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "test-conf-out";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var d = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
    defer d.close(io);
    // A typical conf: comments and blank lines, rpcuser/rpcpassword/rpcport set,
    // plus unrelated keys that must be ignored. rpcport is intentionally omitted
    // to exercise the default fallback.
    try d.writeFile(io, .{ .sub_path = "divi.conf", .data =
        \\# divi.conf
        \\rpcuser=divirpc
        \\rpcpassword=UOE7xXiT3MIAagYjNt5B
        \\daemon=1
        \\server=1
        \\
    });

    const auth = try readAuth(allocator, io, dir, "divi.conf", "fallbackuser", "51473");
    defer freeAuth(allocator, auth);

    try std.testing.expectEqualStrings("divirpc", auth.rpc_user);
    try std.testing.expectEqualStrings("UOE7xXiT3MIAagYjNt5B", auth.rpc_password);
    try std.testing.expectEqualStrings("127.0.0.1", auth.ip_address);
    // rpcport absent → default kept.
    try std.testing.expectEqualStrings("51473", auth.port);
}

test "readAuth keeps defaults when the conf omits everything" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "test-conf-empty-out";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var d = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
    defer d.close(io);
    try d.writeFile(io, .{ .sub_path = "x.conf", .data = "# nothing useful here\n" });

    const auth = try readAuth(allocator, io, dir, "x.conf", "defuser", "1234");
    defer freeAuth(allocator, auth);

    try std.testing.expectEqualStrings("defuser", auth.rpc_user);
    try std.testing.expectEqualStrings("", auth.rpc_password);
    try std.testing.expectEqualStrings("1234", auth.port);
}
