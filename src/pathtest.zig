//! Path assertions for tests, independent of the host's separator.
//!
//! Path-building code uses `std.fs.path.join`, which emits the *host's*
//! separator — `/` on Linux and macOS, `\` on Windows. That is exactly right in
//! production (a Windows daemon wants a Windows path), but it means a test that
//! writes its expectation as `"/home/alice/.bitmonero"` passes on two platforms
//! and fails on the third, having found nothing wrong.
//!
//! It's a real trap rather than a theoretical one: a fair number of these tests
//! deliberately resolve paths for a *simulated* OS (`dataDirFor(…, .linux)` run
//! on a Windows host), so the expectation can't simply be written in the host's
//! separator either. Comparing with both sides normalized to `/` is what lets
//! one expectation mean the same thing everywhere.
//!
//! Use these instead of `expectEqualStrings` whenever the value under test is a
//! filesystem path. Comparisons that are *about* the separator (`sep_str`
//! itself, an archive path parsed with `\` on a POSIX host) must keep using the
//! plain assertions — normalizing there would erase the thing being tested.

const std = @import("std");

/// Longest path these helpers will normalize. Test paths are short by
/// construction; refusing an over-long one keeps this allocation-free without
/// silently truncating and comparing the wrong string.
const max_path = 1024;

/// Copy `path` into `buf` with every `\` turned into `/`.
fn normalize(buf: []u8, path: []const u8) ![]const u8 {
    if (path.len > buf.len) return error.PathTooLongForTest;
    @memcpy(buf[0..path.len], path);
    std.mem.replaceScalar(u8, buf[0..path.len], '\\', '/');
    return buf[0..path.len];
}

/// `expectEqualStrings` for two paths, compared as if both used `/`.
pub fn expectEqual(expected: []const u8, actual: []const u8) !void {
    var ebuf: [max_path]u8 = undefined;
    var abuf: [max_path]u8 = undefined;
    try std.testing.expectEqualStrings(
        try normalize(&ebuf, expected),
        try normalize(&abuf, actual),
    );
}

/// Assert `actual` ends with `suffix`, both compared as if they used `/`.
pub fn expectEndsWith(actual: []const u8, suffix: []const u8) !void {
    var abuf: [max_path]u8 = undefined;
    var sbuf: [max_path]u8 = undefined;
    const a = try normalize(&abuf, actual);
    const s = try normalize(&sbuf, suffix);
    if (std.mem.endsWith(u8, a, s)) return;
    std.debug.print("expected a path ending in '{s}', found '{s}'\n", .{ s, a });
    return error.TestExpectedEndsWith;
}

/// Assert `needle` appears in `haystack`, both compared as if they used `/`.
/// `haystack` may be a whole joined command line, not just one path.
pub fn expectContains(haystack: []const u8, needle: []const u8) !void {
    var hbuf: [max_path]u8 = undefined;
    var nbuf: [max_path]u8 = undefined;
    const h = try normalize(&hbuf, haystack);
    const n = try normalize(&nbuf, needle);
    if (std.mem.indexOf(u8, h, n) != null) return;
    std.debug.print("expected '{s}' to contain '{s}'\n", .{ h, n });
    return error.TestExpectedContains;
}

test "comparisons ignore which separator the host produced" {
    try expectEqual("/home/alice/.bitmonero", "/home/alice\\.bitmonero");
    try expectEqual("C:\\Users\\alice\\AppData", "C:/Users/alice/AppData");
    try expectEndsWith("C:\\bw\\jre\\bin\\java.exe", "jre/bin/java.exe");
    try expectContains("--wallet-file=C:\\x\\wallets\\BoxWallet --pw=y", "wallets/BoxWallet");

    // Still a real comparison: normalizing separators must not make everything
    // match everything.
    try std.testing.expectError(error.TestExpectedEndsWith, expectEndsWith("a/b/java.exe", "bin/java.exe"));
    try std.testing.expectError(error.TestExpectedContains, expectContains("a/b", "c/d"));
}

test "a path too long to normalize is an error, not a truncated comparison" {
    const long = "/" ** (max_path + 1);
    try std.testing.expectError(error.PathTooLongForTest, expectEqual("/", long));
}
