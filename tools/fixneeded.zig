//! Build helper: rewrite an ELF's `DT_NEEDED` for `libslint_cpp.so` from the
//! absolute path the linker baked in (the vendored `.so` has no `SONAME`, so
//! lld records the full path it was found at) down to the bare basename, so a
//! distributed bundle resolves it via the exe's `$ORIGIN` rpath instead of a
//! path that only exists on the build machine.
//!
//! The fix is a single 8-byte edit: `DT_NEEDED`'s value is an offset into the
//! dynamic string table, and "libslint_cpp.so" is the null-terminated *tail* of
//! the existing "/…/libslint_cpp.so" string — so we just advance the offset to
//! that tail. No string-table resizing, no new entries. We write only those 8
//! bytes back (positionally), so the file's executable bit is preserved.
//! x86-64 / little-endian ELF64 only (the one target this bundle is built for).
//!
//! Usage: fixneeded <path-to-elf>

const std = @import("std");
const Io = std.Io;

const SHT_DYNAMIC = 6;
const DT_NULL = 0;
const DT_NEEDED = 1;
const target_basename = "libslint_cpp.so";

pub fn main(process: std.process.Init) !void {
    const gpa = process.gpa;
    const io = process.io;

    var args = std.process.Args.Iterator.init(process.minimal.args);
    _ = args.next(); // argv[0]
    const path = args.next() orelse return error.MissingPathArg;

    const dir = Io.Dir.cwd();
    const data = try dir.readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(data);

    if (data.len < 64 or !std.mem.eql(u8, data[0..4], "\x7fELF")) return error.NotElf;
    if (data[4] != 2 or data[5] != 1) return error.NotElf64Le; // 64-bit, little-endian

    const e_shoff = rd64(data, 0x28);
    const e_shentsize = rd16(data, 0x3a);
    const e_shnum = rd16(data, 0x3c);

    // Locate the dynamic section and its linked string table.
    var dyn_off: u64 = 0;
    var dyn_size: u64 = 0;
    var dyn_link: u32 = 0;
    var sh: usize = 0;
    while (sh < e_shnum) : (sh += 1) {
        const base = e_shoff + @as(u64, sh) * e_shentsize;
        if (rd32(data, base + 0x04) == SHT_DYNAMIC) {
            dyn_off = rd64(data, base + 0x18);
            dyn_size = rd64(data, base + 0x20);
            dyn_link = rd32(data, base + 0x28);
            break;
        }
    }
    if (dyn_size == 0) return error.NoDynamicSection;

    const strtab_base = e_shoff + @as(u64, dyn_link) * e_shentsize;
    const dynstr_off = rd64(data, strtab_base + 0x18);

    // Walk the dynamic entries (16 bytes each) for the DT_NEEDED we care about,
    // recording the file offset of its value word and the corrected value.
    var patch_off: u64 = 0;
    var patch_val: u64 = 0;
    var found = false;
    var i: u64 = 0;
    while (i + 16 <= dyn_size) : (i += 16) {
        const ent = dyn_off + i;
        const tag = rd64(data, ent);
        if (tag == DT_NULL) break;
        if (tag != DT_NEEDED) continue;

        const val = rd64(data, ent + 8);
        const str = cstr(data, @intCast(dynstr_off + val));
        if (std.mem.indexOfScalar(u8, str, '/') != null and
            std.mem.endsWith(u8, str, target_basename))
        {
            patch_off = ent + 8;
            patch_val = val + (str.len - target_basename.len);
            found = true;
            break;
        }
    }
    if (!found) return error.NeededNotFound;

    // Write back just the corrected 8-byte offset (preserves file permissions).
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, patch_val, .little);
    const file = try dir.openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);
    try file.writePositionalAll(io, &buf, patch_off);
}

fn rd16(d: []const u8, off: u64) u16 {
    return std.mem.readInt(u16, d[@intCast(off)..][0..2], .little);
}
fn rd32(d: []const u8, off: u64) u32 {
    return std.mem.readInt(u32, d[@intCast(off)..][0..4], .little);
}
fn rd64(d: []const u8, off: u64) u64 {
    return std.mem.readInt(u64, d[@intCast(off)..][0..8], .little);
}
fn cstr(d: []const u8, off: usize) []const u8 {
    const end = std.mem.indexOfScalarPos(u8, d, off, 0) orelse d.len;
    return d[off..end];
}
