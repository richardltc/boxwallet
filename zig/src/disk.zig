//! Filesystem capacity for the volume that holds a given path, reported as a
//! used/total byte pair for the UI's "Disk" bar.
//!
//! Intentionally allocation-free and bounded: a single fixed `statfs` (POSIX) /
//! `GetDiskFreeSpaceEx` (Windows) call into a stack struct — nothing that scales
//! with the filesystem's size or contents. The bar is polled on a slow cadence
//! (~30s), so this never rides the per-frame path.
//!
//! Cross-platform per the project rule: Linux and macOS read the POSIX `statfs`
//! block counts; Windows asks `GetDiskFreeSpaceExW`. A platform we can't query
//! (or a path that doesn't resolve — e.g. the install root before its first
//! install) yields null, which the UI renders as an empty bar rather than a
//! wrong figure — the same graceful-off-Linux degradation as `processAlive` and
//! `localOffsetSeconds` in `app.zig`.

const std = @import("std");
const builtin = @import("builtin");

/// A volume's capacity in bytes: how much is in use out of the total. `used` is
/// `total - free` over the whole filesystem (reserved blocks included), so the
/// ratio reads as "how full is the disk" rather than df's user-available figure.
pub const Usage = struct {
    used: u64,
    total: u64,

    /// Used fraction as a 0..100 percentage, 0 when the total is unknown.
    pub fn percent(self: Usage) f64 {
        if (self.total == 0) return 0;
        return @as(f64, @floatFromInt(self.used)) / @as(f64, @floatFromInt(self.total)) * 100.0;
    }
};

/// Capacity of the filesystem that contains `path`, or null if it can't be
/// resolved on this platform / for this path.
pub fn usage(path: []const u8) ?Usage {
    return switch (builtin.os.tag) {
        .linux => usageLinux(path),
        .macos => usageDarwin(path),
        .windows => usageWindows(path),
        else => null,
    };
}

/// Build a `Usage` from a block size and total/free block counts, guarding the
/// subtraction so a momentary `free > blocks` can't underflow.
fn fromBlocks(bsize: u64, blocks: u64, bfree: u64) Usage {
    const total = blocks * bsize;
    const free = bfree * bsize;
    return .{ .used = total -| free, .total = total };
}

// --- Linux ------------------------------------------------------------------

const linux = std.os.linux;

/// The 64-bit Linux `struct statfs` (statfs(2)). Only the block fields are read;
/// the rest are named for documentation and correct padding. 32-bit ABIs use a
/// different layout (statfs64), so the query is limited to 64-bit pointers —
/// elsewhere it returns null rather than decoding the struct wrongly.
const StatfsLinux = extern struct {
    f_type: i64,
    f_bsize: i64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_namelen: i64,
    f_frsize: i64,
    f_flags: i64,
    f_spare: [4]i64,
};

fn usageLinux(path: []const u8) ?Usage {
    if (@sizeOf(usize) != 8) return null;
    const path_z = std.posix.toPosixPath(path) catch return null;
    var st: StatfsLinux = undefined;
    const rc = linux.syscall2(.statfs, @intFromPtr(&path_z), @intFromPtr(&st));
    if (linux.errno(rc) != .SUCCESS) return null;
    return fromBlocks(@intCast(@max(st.f_bsize, 0)), st.f_blocks, st.f_bfree);
}

// --- macOS ------------------------------------------------------------------

/// Darwin `struct statfs` (sys/mount.h — the 64-bit-inode variant, the only one
/// on modern macOS). libSystem is always linked on Darwin, so the libc `statfs`
/// symbol resolves without an explicit `-lc`.
const StatfsDarwin = extern struct {
    f_bsize: u32,
    f_iosize: i32,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_owner: u32,
    f_type: u32,
    f_flags: u32,
    f_fssubtype: u32,
    f_fstypename: [16]u8,
    f_mntonname: [1024]u8,
    f_mntfromname: [1024]u8,
    f_flags_ext: u32,
    f_reserved: [7]u32,
};

extern "c" fn statfs(path: [*:0]const u8, buf: *StatfsDarwin) c_int;

fn usageDarwin(path: []const u8) ?Usage {
    const path_z = std.posix.toPosixPath(path) catch return null;
    var st: StatfsDarwin = undefined;
    if (statfs(&path_z, &st) != 0) return null;
    return fromBlocks(st.f_bsize, st.f_blocks, st.f_bfree);
}

// --- Windows ----------------------------------------------------------------

const windows = std.os.windows;

extern "kernel32" fn GetDiskFreeSpaceExW(
    lpDirectoryName: ?[*:0]const u16,
    lpFreeBytesAvailableToCaller: ?*u64,
    lpTotalNumberOfBytes: ?*u64,
    lpTotalNumberOfFreeBytes: ?*u64,
) callconv(.winapi) c_int;

fn usageWindows(path: []const u8) ?Usage {
    // The install root's path is short, so a modest stack buffer is ample; a
    // path that somehow overruns it is treated as unresolvable (null) rather
    // than spending a 64 KiB PATH_MAX_WIDE buffer on every poll.
    var wbuf: [512:0]u16 = undefined;
    const n = std.unicode.wtf8ToWtf16Le(&wbuf, path) catch return null;
    if (n >= wbuf.len) return null;
    wbuf[n] = 0;

    var total: u64 = 0;
    var free: u64 = 0;
    if (GetDiskFreeSpaceExW(wbuf[0..n :0].ptr, null, &total, &free) == 0) return null;
    return .{ .used = total -| free, .total = total };
}

test "usage reports a plausible figure for the root filesystem" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // "/" always exists and is mounted, so a 64-bit Linux host must return a
    // non-null capacity with used within total and a sane percentage.
    const u = usage("/") orelse return error.SkipZigTest;
    try std.testing.expect(u.total > 0);
    try std.testing.expect(u.used <= u.total);
    try std.testing.expect(u.percent() >= 0 and u.percent() <= 100);
}

test "a path that doesn't exist yields null, not a bogus figure" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try std.testing.expect(usage("/no/such/path/boxwallet-disk-test") == null);
}

test "percent is 0 when the total is unknown and exact at the endpoints" {
    try std.testing.expectEqual(@as(f64, 0), (Usage{ .used = 5, .total = 0 }).percent());
    try std.testing.expectEqual(@as(f64, 0), (Usage{ .used = 0, .total = 100 }).percent());
    try std.testing.expectEqual(@as(f64, 100), (Usage{ .used = 100, .total = 100 }).percent());
    try std.testing.expectEqual(@as(f64, 25), (Usage{ .used = 1, .total = 4 }).percent());
}
