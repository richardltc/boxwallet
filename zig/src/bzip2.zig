//! Streaming bzip2 *decompressor* (decode only), pure Zig — Zig 0.16's stdlib has
//! gzip/xz/zstd/lzma but no bzip2, and some coins (Nerva) ship their Linux/macOS
//! bundles as `.tar.bz2`. `decompress` pulls compressed bytes from a
//! `std.Io.Reader` and writes the decoded stream to a `std.Io.Writer`, one bzip2
//! block at a time, so peak memory is bounded by the block size (a few MB for the
//! usual 900k blocks) regardless of total archive size — in keeping with the
//! project's flat-memory rule.
//!
//! Implements the standard bzip2 pipeline in reverse: Huffman decode → MTF + RLE2
//! → inverse Burrows–Wheeler transform → RLE1, with per-block and stream CRC
//! verification. The deprecated "randomised" block mode (never emitted by any
//! bzip2 since 0.9.5) is rejected rather than supported.

const std = @import("std");

pub const Error = error{
    BadMagic,
    BadBlockMagic,
    UnsupportedRandomized,
    BadBlockSize,
    BlockOverflow,
    BadHuffmanCode,
    BadCrc,
    Corrupt,
};

/// Decompress a whole bzip2 stream read from `input` into `output`. Allocates a
/// few block-sized working buffers up front (sized from the stream's block-size
/// byte) and frees them on return.
pub fn decompress(
    gpa: std.mem.Allocator,
    input: *std.Io.Reader,
    output: *std.Io.Writer,
) !void {
    var d = try Decoder.init(gpa, input);
    defer d.deinit(gpa);
    try d.run(output);
}

// bzip2's CRC-32 is the MSB-first variant (poly 0x04C11DB7, no input/output
// reflection) — distinct from the reflected CRC used by gzip/zlib. Table built at
// comptime.
const crc_table: [256]u32 = blk: {
    @setEvalBranchQuota(20000);
    var t: [256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = @as(u32, i) << 24;
        for (0..8) |_| {
            c = if (c & 0x80000000 != 0) (c << 1) ^ 0x04C11DB7 else c << 1;
        }
        t[i] = c;
    }
    break :blk t;
};

const Decoder = struct {
    input: *std.Io.Reader,

    // MSB-first bit buffer.
    bit_buf: u64 = 0,
    bit_n: u6 = 0,

    block_size: usize, // 100_000 * level

    // Block working memory (allocated to `block_size`).
    ll8: []u8, // MTF/RLE2 output bytes (the BWT "last column")
    tt: []u32, // inverse-BWT permutation

    unzftab: [256]u32 = undefined, // byte frequencies for the current block
    cftab: [256]u32 = undefined,

    // Mapping table: which byte values occur in the block.
    seq_to_unseq: [256]u8 = undefined,
    n_in_use: usize = 0,

    // Huffman group tables (≤6 groups, code lengths ≤23, alphabet ≤258).
    n_groups: usize = 0,
    n_selectors: usize = 0,
    selector: [18002]u8 = undefined,
    limit: [6][24]u32 = undefined,
    base: [6][24]u32 = undefined,
    perm: [6][258]u16 = undefined,
    min_lens: [6]u5 = undefined,

    combined_crc: u32 = 0,

    fn init(gpa: std.mem.Allocator, input: *std.Io.Reader) !Decoder {
        var self: Decoder = .{
            .input = input,
            .block_size = 0,
            .ll8 = &.{},
            .tt = &.{},
        };
        // Stream header: 'B' 'Z' 'h' <level '1'..'9'>.
        if (try self.byte() != 'B' or try self.byte() != 'Z' or try self.byte() != 'h')
            return Error.BadMagic;
        const level = try self.byte();
        if (level < '1' or level > '9') return Error.BadBlockSize;
        self.block_size = @as(usize, level - '0') * 100_000;

        self.ll8 = try gpa.alloc(u8, self.block_size);
        errdefer gpa.free(self.ll8);
        self.tt = try gpa.alloc(u32, self.block_size);
        return self;
    }

    fn deinit(self: *Decoder, gpa: std.mem.Allocator) void {
        gpa.free(self.ll8);
        gpa.free(self.tt);
    }

    fn byte(self: *Decoder) !u8 {
        return self.input.takeByte();
    }

    // Read `count` bits (1..32) MSB-first.
    fn bits(self: *Decoder, count: u6) !u32 {
        while (self.bit_n < count) {
            const b = try self.input.takeByte();
            self.bit_buf = (self.bit_buf << 8) | b;
            self.bit_n += 8;
        }
        self.bit_n -= count;
        const mask: u64 = (@as(u64, 1) << count) - 1;
        return @intCast((self.bit_buf >> self.bit_n) & mask);
    }

    fn bit(self: *Decoder) !u1 {
        return @intCast(try self.bits(1));
    }

    fn run(self: *Decoder, output: *std.Io.Writer) !void {
        while (true) {
            const magic = (@as(u48, try self.bits(24)) << 24) | try self.bits(24);
            switch (magic) {
                0x314159265359 => try self.decodeBlock(output), // block
                0x177245385090 => { // end of stream
                    const stored = try self.bits(32);
                    if (stored != self.combined_crc) return Error.BadCrc;
                    return;
                },
                else => return Error.BadBlockMagic,
            }
        }
    }

    fn decodeBlock(self: *Decoder, output: *std.Io.Writer) !void {
        const block_crc = try self.bits(32);
        if (try self.bit() != 0) return Error.UnsupportedRandomized;
        const orig_ptr = try self.bits(24);

        try self.readMappingTable();
        try self.readSelectors();
        try self.readHuffmanTables();
        const nblock = try self.decodeMtfValues();
        if (orig_ptr >= nblock) return Error.Corrupt;

        // Inverse Burrows–Wheeler. cftab[c] = index of the first row beginning
        // with byte c; tt is filled so that following it from orig_ptr walks the
        // original (RLE1-encoded) byte order.
        self.cftab[0] = 0;
        for (1..256) |i| self.cftab[i] = self.unzftab[i - 1];
        for (1..256) |i| self.cftab[i] += self.cftab[i - 1];
        for (0..nblock) |i| {
            const ch = self.ll8[i];
            self.tt[self.cftab[ch]] = @intCast(i);
            self.cftab[ch] += 1;
        }

        // Walk the BWT to recover the RLE1 stream, undo RLE1, and emit. CRC is
        // computed over the final (post-RLE1) bytes. Output is staged in a small
        // buffer so the writer sees chunks, not bytes.
        var crc: u32 = 0xFFFFFFFF;
        var stage: [8192]u8 = undefined;
        var sp: usize = 0;

        var t_pos: u32 = self.tt[orig_ptr];
        var remaining = nblock;

        // RLE1 state: a run of 4 equal bytes is followed by a length byte giving
        // how many *additional* copies follow.
        var prev: i32 = -1;
        var rle_run: u32 = 0;

        while (remaining > 0) {
            const b = self.ll8[t_pos];
            t_pos = self.tt[t_pos];
            remaining -= 1;

            if (rle_run == 4) {
                // `b` is the repeat count for the preceding 4-byte run.
                const rb: u8 = @intCast(prev);
                var k: u32 = 0;
                while (k < b) : (k += 1) {
                    crc = (crc << 8) ^ crc_table[((crc >> 24) ^ rb) & 0xFF];
                    stage[sp] = rb;
                    sp += 1;
                    if (sp == stage.len) {
                        try output.writeAll(&stage);
                        sp = 0;
                    }
                }
                rle_run = 0;
                prev = -1;
                continue;
            }

            if (@as(i32, b) == prev) rle_run += 1 else {
                rle_run = 1;
                prev = b;
            }

            crc = (crc << 8) ^ crc_table[((crc >> 24) ^ b) & 0xFF];
            stage[sp] = b;
            sp += 1;
            if (sp == stage.len) {
                try output.writeAll(&stage);
                sp = 0;
            }
        }
        if (sp > 0) try output.writeAll(stage[0..sp]);

        crc = ~crc;
        if (crc != block_crc) return Error.BadCrc;
        self.combined_crc = std.math.rotl(u32, self.combined_crc, 1) ^ crc;
    }

    fn readMappingTable(self: *Decoder) !void {
        const in_use16 = try self.bits(16);
        var in_use: [256]bool = [_]bool{false} ** 256;
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            if (in_use16 & (@as(u32, 0x8000) >> @intCast(i)) != 0) {
                const bitmap = try self.bits(16);
                var j: usize = 0;
                while (j < 16) : (j += 1) {
                    if (bitmap & (@as(u32, 0x8000) >> @intCast(j)) != 0) in_use[i * 16 + j] = true;
                }
            }
        }
        self.n_in_use = 0;
        for (0..256) |k| {
            if (in_use[k]) {
                self.seq_to_unseq[self.n_in_use] = @intCast(k);
                self.n_in_use += 1;
            }
        }
        if (self.n_in_use == 0) return Error.Corrupt;
    }

    fn readSelectors(self: *Decoder) !void {
        self.n_groups = try self.bits(3);
        if (self.n_groups < 2 or self.n_groups > 6) return Error.Corrupt;
        self.n_selectors = try self.bits(15);
        if (self.n_selectors == 0 or self.n_selectors > self.selector.len) return Error.Corrupt;

        // Selectors are MTF-coded over the group indices.
        var pos: [6]u8 = undefined;
        for (0..self.n_groups) |i| pos[i] = @intCast(i);
        for (0..self.n_selectors) |i| {
            var j: usize = 0;
            while (try self.bit() == 1) {
                j += 1;
                if (j >= self.n_groups) return Error.Corrupt;
            }
            const tmp = pos[j];
            while (j > 0) : (j -= 1) pos[j] = pos[j - 1];
            pos[0] = tmp;
            self.selector[i] = tmp;
        }
    }

    fn readHuffmanTables(self: *Decoder) !void {
        const alpha_size = self.n_in_use + 2;
        for (0..self.n_groups) |g| {
            var len: [258]u5 = undefined;
            var curr: i32 = @intCast(try self.bits(5));
            for (0..alpha_size) |s| {
                while (true) {
                    if (curr < 1 or curr > 20) return Error.BadHuffmanCode;
                    if (try self.bit() == 0) break;
                    if (try self.bit() == 0) curr += 1 else curr -= 1;
                }
                len[s] = @intCast(curr);
            }
            self.buildTable(g, &len, alpha_size);
        }
    }

    // Build the canonical bzip2 decode tables (limit/base/perm) for group `g`.
    fn buildTable(self: *Decoder, g: usize, len: *const [258]u5, alpha_size: usize) void {
        var min_len: u5 = 23;
        var max_len: u5 = 0;
        for (0..alpha_size) |s| {
            if (len[s] > max_len) max_len = len[s];
            if (len[s] < min_len) min_len = len[s];
        }
        self.min_lens[g] = min_len;

        var pp: usize = 0;
        var i: u5 = min_len;
        while (i <= max_len) : (i += 1) {
            for (0..alpha_size) |s| {
                if (len[s] == i) {
                    self.perm[g][pp] = @intCast(s);
                    pp += 1;
                }
            }
        }

        var base: [24]u32 = [_]u32{0} ** 24;
        for (0..alpha_size) |s| base[len[s] + 1] += 1;
        for (1..24) |k| base[k] += base[k - 1];

        var limit: [24]u32 = [_]u32{0} ** 24;
        var vec: u32 = 0;
        i = min_len;
        while (i <= max_len) : (i += 1) {
            vec += base[i + 1] - base[i];
            limit[i] = vec - 1;
            vec <<= 1;
        }
        i = min_len + 1;
        while (i <= max_len) : (i += 1) {
            base[i] = ((limit[i - 1] + 1) << 1) - base[i];
        }
        self.limit[g] = limit;
        self.base[g] = base;
    }

    // Decode one Huffman symbol from group `g`.
    fn getSymbol(self: *Decoder, g: usize) !u16 {
        var zn: u5 = self.min_lens[g];
        var zvec: u32 = try self.bits(zn);
        while (true) {
            if (zn > 20) return Error.BadHuffmanCode;
            if (zvec <= self.limit[g][zn]) break;
            zn += 1;
            zvec = (zvec << 1) | try self.bit();
        }
        const idx = zvec - self.base[g][zn];
        if (idx >= 258) return Error.BadHuffmanCode;
        return self.perm[g][idx];
    }

    // Huffman + MTF + RLE2 → the BWT last column in `ll8`, returning its length.
    fn decodeMtfValues(self: *Decoder) !usize {
        const eob: u16 = @intCast(self.n_in_use + 1);
        @memset(self.unzftab[0..256], 0);

        // MTF list over the in-use symbol indices.
        var yy: [256]u8 = undefined;
        for (0..self.n_in_use) |i| yy[i] = @intCast(i);

        var group_no: usize = 0;
        var group_pos: usize = 0;
        var cur_group: usize = 0;

        const nextSym = struct {
            fn f(d: *Decoder, gn: *usize, gp: *usize, cg: *usize) !u16 {
                if (gp.* == 0) {
                    if (gn.* >= d.n_selectors) return Error.Corrupt;
                    cg.* = d.selector[gn.*];
                    gn.* += 1;
                    gp.* = 50;
                }
                gp.* -= 1;
                return d.getSymbol(cg.*);
            }
        }.f;

        var nblock: usize = 0;
        var run_len: u32 = 0;
        var run_bit: u5 = 0;
        var sym = try nextSym(self, &group_no, &group_pos, &cur_group);

        while (true) {
            if (sym == 0 or sym == 1) { // RUNA / RUNB
                // Accumulate a run length in bijective base-2.
                run_len += (@as(u32, sym) + 1) << run_bit;
                run_bit += 1;
                sym = try nextSym(self, &group_no, &group_pos, &cur_group);
                continue;
            }

            // Flush any pending zero-run (a run of the front MTF byte).
            if (run_len > 0) {
                const b = self.seq_to_unseq[yy[0]];
                self.unzftab[b] += run_len;
                if (nblock + run_len > self.block_size) return Error.BlockOverflow;
                @memset(self.ll8[nblock .. nblock + run_len], b);
                nblock += run_len;
                run_len = 0;
                run_bit = 0;
            }

            if (sym == eob) break;

            // A literal: MTF index is sym-1; move that entry to the front.
            var idx: usize = sym - 1;
            const b = self.seq_to_unseq[yy[idx]];
            self.unzftab[b] += 1;
            const tmp = yy[idx];
            while (idx > 0) : (idx -= 1) yy[idx] = yy[idx - 1];
            yy[0] = tmp;

            if (nblock + 1 > self.block_size) return Error.BlockOverflow;
            self.ll8[nblock] = b;
            nblock += 1;

            sym = try nextSym(self, &group_no, &group_pos, &cur_group);
        }
        return nblock;
    }
};

test "round-trips data the system bzip2 produced" {
    // Build a corpus with runs, repeats and varied bytes (exercises RLE1, RLE2,
    // MTF and multi-group Huffman), compress it with the system `bzip2`, then
    // decode it here and compare. Skips cleanly if `bzip2` isn't installed.
    const gpa = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var original: std.ArrayList(u8) = .empty;
    defer original.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(0x9e3779b97f4a7c15);
    const rnd = prng.random();
    for (0..20000) |i| {
        // Mix long identical runs (RLE1), repeated small alphabets, and noise.
        if (i % 97 < 30) {
            try original.append(gpa, 'A');
        } else if (i % 5 == 0) {
            try original.append(gpa, @intCast('a' + (i % 7)));
        } else {
            try original.append(gpa, rnd.int(u8));
        }
    }

    // Compress via the system bzip2: write the corpus to a temp file (run() has no
    // stdin), then `bzip2 -c -9 <file>` to stdout.
    const tmp = "test-bzip2-input.bin";
    std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = original.items });
    defer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

    const child = std.process.run(gpa, io, .{
        .argv = &.{ "bzip2", "-c", "-9", tmp },
        .stdout_limit = .limited(1 << 20),
    }) catch return error.SkipZigTest;
    defer gpa.free(child.stdout);
    defer gpa.free(child.stderr);
    switch (child.term) {
        .exited => |c| if (c != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    var in = std.Io.Reader.fixed(child.stdout);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try decompress(gpa, &in, &out.writer);

    try std.testing.expectEqualSlices(u8, original.items, out.written());
}

test "round-trips a multi-block stream (combined-CRC path)" {
    // ~300 KB compressed at level 1 (100k blocks) spans several blocks, so this
    // exercises the block loop and the rot-left/xor combined-CRC the single-block
    // corpus above doesn't. Skips if `bzip2` isn't installed.
    const gpa = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var original: std.ArrayList(u8) = .empty;
    defer original.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(0x1234567890abcdef);
    const rnd = prng.random();
    for (0..300_000) |i| {
        if (i % 11 == 0) try original.append(gpa, 'Z') else try original.append(gpa, rnd.int(u8));
    }

    const tmp = "test-bzip2-multiblock.bin";
    std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = original.items });
    defer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

    const child = std.process.run(gpa, io, .{
        .argv = &.{ "bzip2", "-c", "-1", tmp },
        .stdout_limit = .limited(2 << 20),
    }) catch return error.SkipZigTest;
    defer gpa.free(child.stdout);
    defer gpa.free(child.stderr);
    switch (child.term) {
        .exited => |c| if (c != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    var in = std.Io.Reader.fixed(child.stdout);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try decompress(gpa, &in, &out.writer);

    try std.testing.expectEqualSlices(u8, original.items, out.written());
}

test "rejects a stream without the BZh magic" {
    const gpa = std.testing.allocator;
    var in = std.Io.Reader.fixed("not a bzip2 stream at all");
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.testing.expectError(Error.BadMagic, decompress(gpa, &in, &out.writer));
}
