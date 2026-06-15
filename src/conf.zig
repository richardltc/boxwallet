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
        // Carry the data dir so a coin can locate an out-of-band credential file
        // (e.g. Epic's `.api_secret`) that isn't part of the `key=value` conf.
        .data_dir = try allocator.dupe(u8, data_dir),
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

/// Ensure the coin's conf carries the settings BoxWallet needs to drive the
/// daemon over RPC: an `rpcuser`, a generated `rpcpassword`, `server=1`, and
/// `rpcport`. Without these a daemon falls back to cookie auth (or no RPC at
/// all), which BoxWallet can't use — the symptom that left Nexa unmanageable
/// while Divi (whose conf already had creds) worked.
///
/// An enabled `daemon=…` line is *removed* if present: BoxWallet supplies
/// `-daemon` on the launch command line itself (POSIX) and spawns the daemon
/// detached on Windows, so it never needs it in the conf — and leaving it there
/// breaks the coin's own Qt GUI (which can't daemonize) and the Windows daemon
/// (no `-daemon` support), so neither could share the file. A user's explicit
/// `daemon=0` is left untouched.
///
/// Existing values are preserved — a user's own password/port stay put — and
/// only missing keys are appended, so the conf's comments and ordering survive.
/// The data dir and conf are created if absent. Returns true if anything was
/// written (a key added or a `daemon` line stripped). The conf is a tiny
/// `key=value` file, read whole through one bounded buffer and rewritten only
/// when something changed.
pub fn populate(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    conf_file: []const u8,
    default_user: []const u8,
    default_port: []const u8,
) !bool {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
    defer dir.close(io);

    // Slurp the current conf if it exists; absent means every key is missing.
    var content: []const u8 = "";
    var content_owned = false;
    if (dir.openFile(io, conf_file, .{})) |file| {
        defer file.close(io);
        const stat = try file.stat(io);
        const size: usize = @intCast(@min(stat.size, 64 * 1024));
        const data = try allocator.alloc(u8, size);
        const n = try file.readPositionalAll(io, data, 0);
        content = data[0..n];
        content_owned = true;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    defer if (content_owned) allocator.free(content);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    // Copy the conf forward verbatim, dropping any enabled `daemon` line (see the
    // doc comment for why). A removal counts as a change so the file is rewritten.
    var wrote = try stripDaemon(&out.writer, content);

    // Start appends on a fresh line so a conf without a trailing newline stays valid.
    const so_far = out.written();
    if (so_far.len > 0 and so_far[so_far.len - 1] != '\n') try out.writer.writeByte('\n');

    if (!hasKey(content, "rpcuser")) {
        try out.writer.print("rpcuser={s}\n", .{default_user});
        wrote = true;
    }
    if (!hasKey(content, "rpcpassword")) {
        var pw_buf: [20]u8 = undefined;
        try out.writer.print("rpcpassword={s}\n", .{randomPassword(&pw_buf)});
        wrote = true;
    }
    if (!hasKey(content, "server")) {
        try out.writer.writeAll("server=1\n");
        wrote = true;
    }
    if (!hasKey(content, "rpcport")) {
        try out.writer.print("rpcport={s}\n", .{default_port});
        wrote = true;
    }

    if (wrote) try dir.writeFile(io, .{ .sub_path = conf_file, .data = out.written() });
    return wrote;
}

/// Rewrite `conf_file` under `data_dir` to exactly `body`, creating the dir if
/// absent and replacing any existing file. Unlike `populate`'s careful append-
/// only merge, this is a clobbering write for coins whose daemon parses the conf
/// itself and owns it outright — there's nothing user-authored to preserve, and
/// a stale/incompatible file is actively harmful (e.g. nervad rejecting bitcoin
/// keys), so the canonical content must win. Self-healing: a bad conf is
/// overwritten on the next prepare.
pub fn writeConf(
    io: std.Io,
    data_dir: []const u8,
    conf_file: []const u8,
    body: []const u8,
) !void {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = conf_file, .data = body });
}

/// Read a single `key=value` setting from `conf_file` under `data_dir`, returning
/// the (allocator-owned) value, or null when the conf or the key is absent. The
/// conf is scanned line by line through a fixed buffer — never slurped whole —
/// like `readAuth`. Used for settings BoxWallet exposes/reads back individually
/// (e.g. a coin's `prune` target). The last occurrence wins, mirroring how a
/// bitcoin daemon takes the final value of a repeated key.
pub fn readValue(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    conf_file: []const u8,
    key: []const u8,
) !?[]const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, data_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(io);

    var file = dir.openFile(io, conf_file, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);

    var found: ?[]const u8 = null;
    errdefer if (found) |f| allocator.free(f);

    var buf: [8 * 1024]u8 = undefined;
    var fr = file.reader(io, &buf);
    while (try fr.interface.takeDelimiter('\n')) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), key)) continue;
        // Each `takeDelimiter` slice is overwritten by the next read, so dup the
        // value out now; a later occurrence frees the earlier one and wins.
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const dup = try allocator.dupe(u8, val);
        if (found) |f| allocator.free(f);
        found = dup;
    }
    return found;
}

/// Set `key=value` in `conf_file` under `data_dir`, replacing an existing
/// (non-comment) line for `key` in place or appending one if absent; every other
/// line — comments, blank lines, ordering, line endings — is preserved. The data
/// dir and conf are created if missing. For settings BoxWallet owns the value of
/// (e.g. a coin's `prune` target chosen at first start). The conf is a tiny file,
/// read whole through one bounded buffer and rewritten once.
pub fn setValue(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    conf_file: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
    defer dir.close(io);

    var content: []const u8 = "";
    var content_owned = false;
    if (dir.openFile(io, conf_file, .{})) |file| {
        defer file.close(io);
        const stat = try file.stat(io);
        const size: usize = @intCast(@min(stat.size, 64 * 1024));
        const data = try allocator.alloc(u8, size);
        const n = try file.readPositionalAll(io, data, 0);
        content = data[0..n];
        content_owned = true;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    defer if (content_owned) allocator.free(content);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    // Copy lines forward verbatim, swapping the first matching key line for the
    // new value. Preserves original line endings on every untouched line.
    var replaced = false;
    var i: usize = 0;
    while (i < content.len) {
        const nl = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
        const end = if (nl < content.len) nl + 1 else nl;
        const line = std.mem.trim(u8, content[i..nl], " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=');
        const is_key = !replaced and line.len > 0 and line[0] != '#' and eq != null and
            std.mem.eql(u8, std.mem.trim(u8, line[0..eq.?], " \t"), key);
        if (is_key) {
            try out.writer.print("{s}={s}\n", .{ key, value });
            replaced = true;
        } else {
            try out.writer.writeAll(content[i..end]);
        }
        i = end;
    }
    if (!replaced) {
        const so_far = out.written();
        if (so_far.len > 0 and so_far[so_far.len - 1] != '\n') try out.writer.writeByte('\n');
        try out.writer.print("{s}={s}\n", .{ key, value });
    }

    try dir.writeFile(io, .{ .sub_path = conf_file, .data = out.written() });
}

/// Copy `content` into `w`, dropping any line that *enables* `daemon` (a truthy
/// `daemon=…`). Returns true if such a line was removed, so the caller knows to
/// rewrite the conf. Everything else — comments, blank lines, ordering, other
/// keys, and the original line endings — is preserved byte-for-byte; an explicit
/// `daemon=0` is kept.
fn stripDaemon(w: *std.Io.Writer, content: []const u8) !bool {
    var removed = false;
    var i: usize = 0;
    while (i < content.len) {
        const nl = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
        const end = if (nl < content.len) nl + 1 else nl; // include the '\n' if present
        const line = std.mem.trim(u8, content[i..nl], " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=');
        const drop = line.len > 0 and line[0] != '#' and eq != null and
            std.mem.eql(u8, std.mem.trim(u8, line[0..eq.?], " \t"), "daemon") and
            isEnabled(std.mem.trim(u8, line[eq.? + 1 ..], " \t"));
        if (drop) {
            removed = true;
        } else {
            try w.writeAll(content[i..end]);
        }
        i = end;
    }
    return removed;
}

/// Bitcoin-conf truthiness for a boolean value (`1`/`true`/`yes`/`on`).
fn isEnabled(val: []const u8) bool {
    return std.mem.eql(u8, val, "1") or
        std.ascii.eqlIgnoreCase(val, "true") or
        std.ascii.eqlIgnoreCase(val, "yes") or
        std.ascii.eqlIgnoreCase(val, "on");
}

/// True if `content` has a non-comment line whose key (left of `=`) is `key`.
fn hasKey(content: []const u8, key: []const u8) bool {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), key)) return true;
    }
    return false;
}

/// Fill `buf` with a random alphanumeric password (mirrors the Go `rand.String`),
/// returning it as a slice. Bytes come from the OS entropy source; on a platform
/// without one we fall back to a seeded PRNG — fine for a local rpcpassword (the
/// Go reference uses non-crypto `math/rand` here too).
fn randomPassword(buf: []u8) []const u8 {
    const charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    var raw: [64]u8 = undefined;
    std.debug.assert(buf.len <= raw.len);
    const from_os = builtin.os.tag == .linux and
        std.os.linux.getrandom(&raw, buf.len, 0) == buf.len;
    if (!from_os) {
        var prng = std.Random.DefaultPrng.init(@intFromPtr(buf.ptr));
        prng.random().bytes(raw[0..buf.len]);
    }
    for (buf, 0..) |*c, i| c.* = charset[raw[i] % charset.len];
    return buf;
}

/// Free the four strings owned by a `CoinAuth` built by `readAuth`.
pub fn freeAuth(allocator: std.mem.Allocator, auth: models.CoinAuth) void {
    allocator.free(auth.rpc_user);
    allocator.free(auth.rpc_password);
    allocator.free(auth.ip_address);
    allocator.free(auth.port);
    allocator.free(auth.data_dir);
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

test "populate appends missing creds and settings, then readAuth reads them back" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "test-conf-populate-out";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    // A comments-only conf, like a freshly-created nexa.conf: no creds at all.
    var d = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
    d.writeFile(io, .{ .sub_path = "nexa.conf", .data = "# NEXA config\n" }) catch {};
    d.close(io);

    const wrote = try populate(allocator, io, dir, "nexa.conf", "nexarpc", "7227");
    try std.testing.expect(wrote);

    const auth = try readAuth(allocator, io, dir, "nexa.conf", "fallbackuser", "1111");
    defer freeAuth(allocator, auth);

    // rpcuser falls to the coin default, rpcport is written, and a non-empty
    // random password was generated.
    try std.testing.expectEqualStrings("nexarpc", auth.rpc_user);
    try std.testing.expectEqualStrings("7227", auth.port);
    try std.testing.expectEqual(@as(usize, 20), auth.rpc_password.len);

    // The original comment is preserved (append-only, not a rewrite from scratch).
    var rb: [4096]u8 = undefined;
    var f = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer f.close(io);
    var cf = try f.openFile(io, "nexa.conf", .{});
    defer cf.close(io);
    const n = try cf.readPositionalAll(io, &rb, 0);
    try std.testing.expect(std.mem.indexOf(u8, rb[0..n], "# NEXA config") != null);
    try std.testing.expect(std.mem.indexOf(u8, rb[0..n], "server=1") != null);

    // Idempotent: a second pass finds everything present and writes nothing.
    try std.testing.expect(!try populate(allocator, io, dir, "nexa.conf", "nexarpc", "7227"));
}

test "populate preserves existing creds rather than overwriting them" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "test-conf-populate-keep-out";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var d = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
    d.writeFile(io, .{ .sub_path = "divi.conf", .data =
        \\rpcuser=divirpc
        \\rpcpassword=keepme
        \\
    }) catch {};
    d.close(io);

    _ = try populate(allocator, io, dir, "divi.conf", "shouldnotwin", "51473");

    const auth = try readAuth(allocator, io, dir, "divi.conf", "x", "0");
    defer freeAuth(allocator, auth);
    try std.testing.expectEqualStrings("divirpc", auth.rpc_user);
    try std.testing.expectEqualStrings("keepme", auth.rpc_password);
}

test "populate strips an enabled daemon line, preserving the rest" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "test-conf-daemon-strip-out";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    // A conf an older BoxWallet (or the user) left carrying daemon=1, with a
    // comment and creds to prove the rest of the file survives the rewrite.
    var d = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
    d.writeFile(io, .{ .sub_path = "divi.conf", .data =
        \\# divi.conf
        \\rpcuser=divirpc
        \\rpcpassword=keepme
        \\daemon=1
        \\server=1
        \\
    }) catch {};
    d.close(io);

    // Removing the daemon line counts as a change → wrote=true, file rewritten.
    try std.testing.expect(try populate(allocator, io, dir, "divi.conf", "x", "51473"));

    var rb: [4096]u8 = undefined;
    var f = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer f.close(io);
    var cf = try f.openFile(io, "divi.conf", .{});
    defer cf.close(io);
    const n = try cf.readPositionalAll(io, &rb, 0);
    const out = rb[0..n];
    try std.testing.expect(std.mem.indexOf(u8, out, "daemon=1") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# divi.conf") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "rpcpassword=keepme") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "server=1") != null);

    // Idempotent now: nothing left to strip or add.
    try std.testing.expect(!try populate(allocator, io, dir, "divi.conf", "x", "51473"));
}

test "populate leaves an explicit daemon=0 in place" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "test-conf-daemon-keep-out";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    // Everything BoxWallet needs is already present and daemon is *disabled*, so
    // there's nothing to add and nothing to strip — populate is a no-op.
    var d = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
    d.writeFile(io, .{ .sub_path = "divi.conf", .data = "rpcuser=u\nrpcpassword=p\nserver=1\nrpcport=51473\ndaemon=0\n" }) catch {};
    d.close(io);

    try std.testing.expect(!try populate(allocator, io, dir, "divi.conf", "x", "51473"));

    var rb: [4096]u8 = undefined;
    var f = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer f.close(io);
    var cf = try f.openFile(io, "divi.conf", .{});
    defer cf.close(io);
    const n = try cf.readPositionalAll(io, &rb, 0);
    try std.testing.expect(std.mem.indexOf(u8, rb[0..n], "daemon=0") != null);
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

test "readValue returns null for a missing conf or missing key, the value when present" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "test-conf-readvalue-out";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    // No conf at all → null (no error).
    try std.testing.expect((try readValue(allocator, io, dir, "litecoin.conf", "prune")) == null);

    var d = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
    defer d.close(io);
    try d.writeFile(io, .{ .sub_path = "litecoin.conf", .data =
        \\# litecoin.conf
        \\rpcuser=ltc
        \\prune=5000
        \\
    });

    const present = try readValue(allocator, io, dir, "litecoin.conf", "prune");
    defer if (present) |p| allocator.free(p);
    try std.testing.expectEqualStrings("5000", present.?);

    // A key the conf omits → null.
    try std.testing.expect((try readValue(allocator, io, dir, "litecoin.conf", "txindex")) == null);
}

test "setValue replaces an existing key in place and appends a missing one" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "test-conf-setvalue-out";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var d = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
    d.writeFile(io, .{ .sub_path = "litecoin.conf", .data =
        \\# litecoin.conf
        \\prune=2000
        \\rpcuser=ltc
        \\
    }) catch {};
    d.close(io);

    // Replace prune in place; the comment, ordering, and other keys survive.
    try setValue(allocator, io, dir, "litecoin.conf", "prune", "10000");
    {
        const v = try readValue(allocator, io, dir, "litecoin.conf", "prune");
        defer if (v) |p| allocator.free(p);
        try std.testing.expectEqualStrings("10000", v.?);
        const u = try readValue(allocator, io, dir, "litecoin.conf", "rpcuser");
        defer if (u) |p| allocator.free(p);
        try std.testing.expectEqualStrings("ltc", u.?);
    }

    // A key not present is appended.
    try setValue(allocator, io, dir, "litecoin.conf", "txindex", "1");
    const t = try readValue(allocator, io, dir, "litecoin.conf", "txindex");
    defer if (t) |p| allocator.free(p);
    try std.testing.expectEqualStrings("1", t.?);
}

test "setValue creates the conf (and dir) when absent" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "test-conf-setvalue-fresh-out";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try setValue(allocator, io, dir, "litecoin.conf", "prune", "0");
    const v = try readValue(allocator, io, dir, "litecoin.conf", "prune");
    defer if (v) |p| allocator.free(p);
    try std.testing.expectEqualStrings("0", v.?);
}
