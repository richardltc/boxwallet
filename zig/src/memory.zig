//! System physical-memory usage (used vs total bytes) for the UI's memory
//! sparkline.
//!
//! Like `disk.zig`, this is allocation-free and bounded — a small fixed read /
//! one syscall into a stack struct, nothing that scales with anything — so it's
//! safe to sample inline on the UI thread on a short cadence.
//!
//! Cross-platform per the project rule, each using the platform's accurate
//! "available" figure (reclaimable cache counted as free, matching the system's
//! own monitors) rather than a naive free-pages count:
//!   - Linux:   /proc/meminfo `MemTotal` / `MemAvailable`.
//!   - Windows: `GlobalMemoryStatusEx` (`ullTotalPhys` / `ullAvailPhys`).
//!   - macOS:   `sysctl hw.memsize` + Mach `host_statistics64` (vm_statistics64);
//!              the macOS "memory-pressure" model makes "used" approximate.
//! A platform we can't query (or an unreadable source) yields null, which the UI
//! treats as a dropped sample — the same graceful degradation as `disk.zig`.

const std = @import("std");
const builtin = @import("builtin");

/// Physical memory in bytes: how much is in use out of the total. `used` is
/// `total - available`, where "available" is the OS's reclaimable-aware free
/// figure, so the ratio matches what the platform's own monitor reports.
pub const Usage = struct {
    used: u64,
    total: u64,

    /// Used fraction as a 0..100 percentage, 0 when the total is unknown.
    pub fn percent(self: Usage) f64 {
        if (self.total == 0) return 0;
        return @as(f64, @floatFromInt(self.used)) / @as(f64, @floatFromInt(self.total)) * 100.0;
    }
};

/// Current physical-memory usage, or null if it can't be resolved on this
/// platform / from its source this round.
pub fn usage() ?Usage {
    return switch (builtin.os.tag) {
        .linux => usageLinux(),
        .macos => usageDarwin(),
        .windows => usageWindows(),
        else => null,
    };
}

// --- Linux ------------------------------------------------------------------

const linux = std.os.linux;

fn usageLinux() ?Usage {
    // /proc/meminfo's first handful of lines carry MemTotal then MemAvailable,
    // both in kB. A small fixed read covers them with room to spare; we never
    // hold the whole file. MemAvailable is the kernel's reclaimable-cache-aware
    // estimate (what `free`'s "available" column shows), so used = total - it
    // tracks real pressure rather than counting page cache as used.
    var buf: [2048]u8 = undefined;
    const n = readFirst("/proc/meminfo", &buf) orelse return null;
    const text = buf[0..n];
    const total_kb = fieldKb(text, "MemTotal:") orelse return null;
    const avail_kb = fieldKb(text, "MemAvailable:") orelse return null;
    const total = total_kb *| 1024;
    const avail = avail_kb *| 1024;
    return .{ .used = total -| avail, .total = total };
}

/// Read up to `buf.len` bytes from the start of `path` via raw syscalls (no Io
/// handle, no allocation), returning the byte count or null on any failure. One
/// `read` is enough for the proc fields we want — they sit in the first page.
fn readFirst(path: [*:0]const u8, buf: []u8) ?usize {
    const fd_rc = linux.open(path, .{}, 0);
    if (linux.errno(fd_rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);

    const n = linux.read(fd, buf.ptr, buf.len);
    if (linux.errno(n) != .SUCCESS) return null;
    return n;
}

/// Parse the integer value (in kB) that follows `key` (which includes the
/// trailing colon, e.g. "MemTotal:") in a /proc/meminfo-style buffer. Null if
/// the key isn't present or no number follows it.
fn fieldKb(text: []const u8, key: []const u8) ?u64 {
    const idx = std.mem.indexOf(u8, text, key) orelse return null;
    var rest = text[idx + key.len ..];
    var i: usize = 0;
    while (i < rest.len and (rest[i] == ' ' or rest[i] == '\t')) : (i += 1) {}
    rest = rest[i..];
    var j: usize = 0;
    while (j < rest.len and rest[j] >= '0' and rest[j] <= '9') : (j += 1) {}
    if (j == 0) return null;
    return std.fmt.parseInt(u64, rest[0..j], 10) catch null;
}

// --- macOS ------------------------------------------------------------------

/// Darwin `struct vm_statistics64` (mach/vm_statistics.h). Only a handful of
/// page counts are read; the rest are named so the layout — and the derived
/// `HOST_VM_INFO64_COUNT` (its size in `integer_t` units) — matches the kernel.
const VMStatistics64 = extern struct {
    free_count: u32,
    active_count: u32,
    inactive_count: u32,
    wire_count: u32,
    zero_fill_count: u64,
    reactivations: u64,
    pageins: u64,
    pageouts: u64,
    faults: u64,
    cow_faults: u64,
    lookups: u64,
    hits: u64,
    purges: u64,
    purgeable_count: u32,
    speculative_count: u32,
    decompressions: u64,
    compressions: u64,
    swapins: u64,
    swapouts: u64,
    slid_count: u32,
    throttled_count: u32,
    external_page_count: u32,
    internal_page_count: u32,
    total_uncompressed_pages_in_compressor: u64,
};

const HOST_VM_INFO64 = 4;

extern "c" fn mach_host_self() c_uint;
extern "c" fn host_statistics64(
    host_priv: c_uint,
    flavor: c_int,
    host_info_out: *VMStatistics64,
    host_info_out_cnt: *c_uint,
) c_int;
extern "c" fn sysctlbyname(
    name: [*:0]const u8,
    oldp: ?*anyopaque,
    oldlenp: ?*usize,
    newp: ?*anyopaque,
    newlen: usize,
) c_int;

fn usageDarwin() ?Usage {
    // Total physical RAM is a plain sysctl.
    var total: u64 = 0;
    var total_len: usize = @sizeOf(u64);
    if (sysctlbyname("hw.memsize", &total, &total_len, null, 0) != 0 or total == 0) return null;

    // Page size (4 KiB on Intel, 16 KiB on Apple Silicon — never hard-code it).
    var page_size: c_int = 0;
    var ps_len: usize = @sizeOf(c_int);
    if (sysctlbyname("hw.pagesize", &page_size, &ps_len, null, 0) != 0 or page_size <= 0) return null;
    const ps: u64 = @intCast(page_size);

    var vm: VMStatistics64 = undefined;
    var count: c_uint = @sizeOf(VMStatistics64) / @sizeOf(c_int);
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, &vm, &count) != 0) return null;

    // Approximate the system's reclaimable-aware "available": free pages plus
    // the reclaimable pools (inactive/speculative/purgeable), mirroring how
    // Linux's MemAvailable counts cache as free. macOS's pressure model makes
    // this an estimate, but it tracks Activity Monitor far better than free
    // pages alone (which would count all cache as used).
    const avail_pages: u64 =
        @as(u64, vm.free_count) +
        @as(u64, vm.inactive_count) +
        @as(u64, vm.speculative_count) +
        @as(u64, vm.purgeable_count);
    const avail = avail_pages *| ps;
    return .{ .used = total -| avail, .total = total };
}

// --- Windows ----------------------------------------------------------------

/// Win32 `MEMORYSTATUSEX`. `dwLength` must be set to its own size before the
/// call; we read the physical-memory totals.
const MemoryStatusEx = extern struct {
    dwLength: u32,
    dwMemoryLoad: u32,
    ullTotalPhys: u64,
    ullAvailPhys: u64,
    ullTotalPageFile: u64,
    ullAvailPageFile: u64,
    ullTotalVirtual: u64,
    ullAvailVirtual: u64,
    ullAvailExtendedVirtual: u64,
};

extern "kernel32" fn GlobalMemoryStatusEx(buffer: *MemoryStatusEx) callconv(.winapi) c_int;

fn usageWindows() ?Usage {
    var st: MemoryStatusEx = undefined;
    st.dwLength = @sizeOf(MemoryStatusEx);
    if (GlobalMemoryStatusEx(&st) == 0) return null;
    // ullAvailPhys is the system's available figure (free + reclaimable
    // standby), so used = total - available matches Task Manager.
    return .{ .used = st.ullTotalPhys -| st.ullAvailPhys, .total = st.ullTotalPhys };
}

test "usage reports a plausible figure for system RAM" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const u = usage() orelse return error.SkipZigTest;
    try std.testing.expect(u.total > 0);
    try std.testing.expect(u.used <= u.total);
    try std.testing.expect(u.percent() >= 0 and u.percent() <= 100);
}

test "fieldKb parses /proc/meminfo-style lines and ignores misses" {
    const sample =
        "MemTotal:       16331216 kB\n" ++
        "MemFree:          512344 kB\n" ++
        "MemAvailable:    9876543 kB\n";
    try std.testing.expectEqual(@as(u64, 16331216), fieldKb(sample, "MemTotal:").?);
    try std.testing.expectEqual(@as(u64, 9876543), fieldKb(sample, "MemAvailable:").?);
    try std.testing.expect(fieldKb(sample, "SwapTotal:") == null);
}

test "percent is 0 when the total is unknown and exact at the endpoints" {
    try std.testing.expectEqual(@as(f64, 0), (Usage{ .used = 5, .total = 0 }).percent());
    try std.testing.expectEqual(@as(f64, 0), (Usage{ .used = 0, .total = 100 }).percent());
    try std.testing.expectEqual(@as(f64, 100), (Usage{ .used = 100, .total = 100 }).percent());
    try std.testing.expectEqual(@as(f64, 50), (Usage{ .used = 2, .total = 4 }).percent());
}
