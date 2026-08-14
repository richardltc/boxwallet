//! Wallet-file mechanics shared by the bitcoin-family coins: telling a
//! `dumpwallet` **text** key dump from a binary wallet file, and the
//! daemon-stopped restore that swaps a user-supplied wallet file into the data
//! dir.
//!
//! Every coin whose daemon has no `importwallet` (SpiderByte), or whose users
//! carry a wallet over from another install (BitcoinZ, ReddCoin), needs the same
//! swap: reject a bad source, move the current wallet aside so a mistaken
//! restore stays recoverable, then stream the new file into place. That's
//! mechanics, not coin knowledge, so it lives here once and each coin calls in
//! with its own destination directory and file name — ReddCoin's Core-22 wallet
//! sits in a named sub-directory (`<data_dir>/BoxWallet/wallet.dat`) while the
//! others keep theirs at the top of the data dir.
//!
//! The daemon holds its wallet file open while running, so **the caller stops
//! the daemon before calling `restoreOffline` and restarts it after** (the
//! offline-restore orchestration in `app.zig` / `capi.zig`); nothing here takes
//! auth or touches RPC.

const std = @import("std");
const builtin = @import("builtin");

/// The header every bitcoin-family `dumpwallet` file opens with — upstream
/// `rpcdump.cpp` writes "# Wallet dump created by <Coin> v…", so the prefix up
/// to the coin name is common to all of them (verified against bitcoinzd 2.2.0
/// and reddcoind 4.22.9).
pub const dump_header_prefix = "# Wallet dump created by";

/// True if the file at `path` opens with a `dumpwallet` header — i.e. it's a
/// text key dump `importwallet` can actually read, not a binary wallet file (or
/// anything else). Only the first bytes are read, so this stays cheap and flat
/// regardless of file size. Unreadable/missing reads as false: the caller then
/// refuses rather than handing the daemon a file it will silently skip. Leading
/// blank lines are tolerated; the header need only be first.
pub fn looksLikeKeyDump(allocator: std.mem.Allocator, path: []const u8) bool {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir_path = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return false;
    defer dir.close(io);
    var f = dir.openFile(io, base, .{}) catch return false;
    defer f.close(io);

    // Short reads are normal (a dump smaller than the buffer) — the count comes
    // back, no end-of-stream error to handle.
    var buf: [512]u8 = undefined;
    const n = f.readPositionalAll(io, &buf, 0) catch return false;
    const head = std.mem.trimStart(u8, buf[0..n], " \t\r\n");
    return std.mem.startsWith(u8, head, dump_header_prefix);
}

/// Replace `<dest_dir>/<wallet_file>` with the wallet file at `src_path`, with
/// the daemon stopped.
///
/// Safety, in the order it happens — nothing is touched until the source has
/// passed every check:
///
///   1. A **text key dump** picked by mistake is refused (`IsAWalletKeyDump`).
///      That's the *other* restore's input; copied over a wallet file it leaves
///      the daemon unable to open the result.
///   2. A missing or **empty** source is refused (`WalletFileNotFound` /
///      `EmptyWalletFile`).
///   3. The current wallet file, if any, is moved aside to a timestamped
///      `<wallet_file>.bak-<ns>` sibling, so a wrong-file restore never destroys
///      the wallet that was there — it stays recoverable.
///
/// The copy is streamed (`copyFile`), so a large BDB wallet costs a fixed buffer
/// rather than its own size in RAM.
pub fn restoreOffline(
    allocator: std.mem.Allocator,
    dest_dir: []const u8,
    wallet_file: []const u8,
    src_path: []const u8,
) !void {
    if (looksLikeKeyDump(allocator, src_path)) return error.IsAWalletKeyDump;

    // Self-contained blocking IO — the file work is bounded and this takes no
    // `io` from the caller (mirrors the coins' other file-level hooks).
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Open the source via (dir, basename) so an absolute picker path works the
    // same way the conf code opens files.
    const src_dir = std.fs.path.dirname(src_path) orelse ".";
    const src_base = std.fs.path.basename(src_path);
    var sd = std.Io.Dir.cwd().openDir(io, src_dir, .{}) catch return error.WalletFileNotFound;
    defer sd.close(io);

    // Reject an empty/missing source before touching the current wallet.
    const src_stat = sd.statFile(io, src_base, .{}) catch return error.WalletFileNotFound;
    if (src_stat.size == 0) return error.EmptyWalletFile;

    var dd = try std.Io.Dir.cwd().createDirPathOpen(io, dest_dir, .{});
    defer dd.close(io);

    // Preserve the current wallet (if present) as a timestamped backup. A
    // missing current wallet is fine — that's a restore into a fresh data dir.
    if (dd.statFile(io, wallet_file, .{})) |_| {
        const ns = std.Io.Timestamp.now(io, .real).toNanoseconds();
        const bak = try std.fmt.allocPrint(allocator, "{s}.bak-{d}", .{ wallet_file, ns });
        defer allocator.free(bak);
        try dd.rename(wallet_file, dd, bak, io);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    try sd.copyFile(src_base, dd, wallet_file, io, .{});
}

test "looksLikeKeyDump separates a dumpwallet text file from a binary wallet file" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-walletfile-dumpsniff";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer dir.close(io);

    // Real headers, as bitcoinzd 2.2.0 and reddcoind 4.22.9 write them.
    try dir.writeFile(io, .{
        .sub_path = "btcz.txt",
        .data = "# Wallet dump created by BitcoinZ v2.2.0-ge90047d4a\n# * Created on 2026-07-18T10:54:39Z\n",
    });
    try dir.writeFile(io, .{
        .sub_path = "rdd.txt",
        .data = "# Wallet dump created by Reddcoin v4.22.9\n# * Created on 2026-08-14T14:07:49Z\n",
    });
    // A binary wallet.dat: BDB's magic, no header. This is the file that made
    // importwallet report success while importing nothing.
    try dir.writeFile(io, .{ .sub_path = "wallet.dat", .data = "\x00\x00\x00\x00\x62\x31\x05\x00\xff\xfe\x00binary" });
    // Leading blank lines are fine; the header need only come first.
    try dir.writeFile(io, .{ .sub_path = "padded.txt", .data = "\n\n# Wallet dump created by Reddcoin v4.22.9\n" });

    const cases = [_]struct { name: []const u8, dump: bool }{
        .{ .name = "btcz.txt", .dump = true },
        .{ .name = "rdd.txt", .dump = true },
        .{ .name = "padded.txt", .dump = true },
        .{ .name = "wallet.dat", .dump = false },
        // Unreadable reads as "not a dump" — the caller refuses rather than
        // handing the daemon a file it would silently skip.
        .{ .name = "nope.txt", .dump = false },
    };
    for (cases) |c| {
        const p = try std.fs.path.join(allocator, &.{ root, c.name });
        defer allocator.free(p);
        try std.testing.expectEqual(c.dump, looksLikeKeyDump(allocator, p));
    }
}

test "restoreOffline swaps the wallet in, preserving the old one" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-walletfile-restore";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    // A nested destination, as ReddCoin's Core-22 named wallet dir is — the
    // path is created if it isn't there.
    const dest = root ++ "/data/BoxWallet";
    var dd = try std.Io.Dir.cwd().createDirPathOpen(io, dest, .{});
    defer dd.close(io);
    try dd.writeFile(io, .{ .sub_path = "wallet.dat", .data = "OLD-WALLET" });

    var src = try std.Io.Dir.cwd().createDirPathOpen(io, root ++ "/backups", .{});
    defer src.close(io);
    try src.writeFile(io, .{ .sub_path = "wallet.dat", .data = "NEW-WALLET" });

    const good = root ++ "/backups/wallet.dat";
    try restoreOffline(allocator, dest, "wallet.dat", good);

    // The backup is now the live wallet…
    {
        const cur = try dd.readFileAlloc(io, "wallet.dat", allocator, .limited(64));
        defer allocator.free(cur);
        try std.testing.expectEqualStrings("NEW-WALLET", cur);
    }
    // …and the previous one was kept aside intact, not destroyed. Iterating
    // needs a handle opened for it (`.iterate = true`).
    {
        var idir = try std.Io.Dir.cwd().openDir(io, dest, .{ .iterate = true });
        defer idir.close(io);
        var it = idir.iterate();
        var found_bak = false;
        while (try it.next(io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "wallet.dat.bak-")) continue;
            const old = try dd.readFileAlloc(io, entry.name, allocator, .limited(64));
            defer allocator.free(old);
            try std.testing.expectEqualStrings("OLD-WALLET", old);
            found_bak = true;
        }
        try std.testing.expect(found_bak);
    }
}

test "restoreOffline refuses a key dump, an empty file, and a missing file" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-walletfile-refuse";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const dest = root ++ "/data";
    var dd = try std.Io.Dir.cwd().createDirPathOpen(io, dest, .{});
    defer dd.close(io);
    try dd.writeFile(io, .{ .sub_path = "wallet.dat", .data = "LIVE-WALLET" });

    var src = try std.Io.Dir.cwd().createDirPathOpen(io, root ++ "/backups", .{});
    defer src.close(io);
    try src.writeFile(io, .{ .sub_path = "dump.txt", .data = "# Wallet dump created by Reddcoin v4.22.9\n" });
    try src.writeFile(io, .{ .sub_path = "empty.dat", .data = "" });

    try std.testing.expectError(
        error.IsAWalletKeyDump,
        restoreOffline(allocator, dest, "wallet.dat", root ++ "/backups/dump.txt"),
    );
    try std.testing.expectError(
        error.EmptyWalletFile,
        restoreOffline(allocator, dest, "wallet.dat", root ++ "/backups/empty.dat"),
    );
    try std.testing.expectError(
        error.WalletFileNotFound,
        restoreOffline(allocator, dest, "wallet.dat", root ++ "/backups/nope.dat"),
    );

    // Every refusal happened before anything was touched: the live wallet is
    // still the live wallet, and nothing was moved aside.
    const cur = try dd.readFileAlloc(io, "wallet.dat", allocator, .limited(64));
    defer allocator.free(cur);
    try std.testing.expectEqualStrings("LIVE-WALLET", cur);

    var idir = try std.Io.Dir.cwd().openDir(io, dest, .{ .iterate = true });
    defer idir.close(io);
    var it = idir.iterate();
    while (try it.next(io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, "wallet.dat.bak-"));
    }
}
