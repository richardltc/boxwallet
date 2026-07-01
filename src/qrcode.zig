const std = @import("std");

/// Pure-Zig QR Code encoder, ported from Project Nayuki's QR Code generator
/// library (MIT License — https://github.com/nayuki/QR-Code-generator,
/// `c/qrcodegen.c`/`.h`). Scoped down from the full spec to what a wallet
/// receive-address QR needs: **byte mode only** (mixed-case base58/bech32
/// address text — QR's numeric/alphanumeric modes don't cover lowercase
/// letters, and kanji mode is irrelevant here), but the full version range
/// (1-40) and all four error-correction levels are kept, since those tables
/// aren't what makes a full port large.
///
/// Correctness was cross-checked during development against the actual
/// Nayuki C reference (compiled locally) by comparing module matrices for
/// representative inputs byte-for-byte — see the golden-fixture tests below.

/// Error-correction level. Numeric values match the C reference's
/// `qrcodegen_Ecc` and the ECC-table row indices below — don't reorder.
pub const Ecc = enum(u2) {
    low = 0,
    medium = 1,
    quartile = 2,
    high = 3,
};

pub const version_min: u8 = 1;
pub const version_max: u8 = 40;

/// A generated QR Code: `size` modules per side, with the modules bit-packed
/// into `buf` in the same layout as the C reference (`buf[0]` = size,
/// `buf[1..]` = row-major bits, MSB-first per byte) — kept identical so the
/// port could be cross-checked against the reference byte-for-byte. Owns
/// `buf`; call `deinit`.
pub const Qr = struct {
    allocator: std.mem.Allocator,
    buf: []u8,

    pub fn size(self: Qr) u16 {
        return self.buf[0];
    }

    /// Whether the module at (x, y) is dark. Out-of-bounds reads as light
    /// (false), matching `qrcodegen_getModule`.
    pub fn get(self: Qr, x: i32, y: i32) bool {
        const sz: i32 = self.buf[0];
        if (x < 0 or x >= sz or y < 0 or y >= sz) return false;
        return getModuleBounded(self.buf, x, y);
    }

    pub fn deinit(self: Qr) void {
        self.allocator.free(self.buf);
    }
};

/// Encode `text` (raw bytes — byte-mode segment) at error-correction level
/// `ecl`, auto-selecting the smallest version (1..40) that fits and the
/// lowest-penalty of the 8 mask patterns. Mirrors `qrcodegen_encodeText`'s
/// default behavior: after picking the minimum version, silently upgrades to
/// a higher ECC level for free if the data still fits that same version
/// (`boostEcl = true` in the reference) — more error tolerance at no size
/// cost.
pub fn encodeText(allocator: std.mem.Allocator, text: []const u8, ecl: Ecc) !Qr {
    if (text.len == 0) return error.EmptyText;

    var qrcode_buf: [buffer_len_max]u8 = undefined;
    var temp_buf: [buffer_len_max]u8 = undefined;

    // Find the minimal version that fits the data at the requested ECC level.
    var version: u8 = version_min;
    var data_used_bits: i32 = 0;
    while (true) {
        const data_capacity_bits = getNumDataCodewords(version, ecl) * 8;
        if (getTotalBitsByte(text.len, version)) |bits| {
            if (bits <= data_capacity_bits) {
                data_used_bits = bits;
                break;
            }
        }
        if (version >= version_max) return error.DataTooLong;
        version += 1;
    }

    // Boost the ECC level for free if the data still fits this version at a
    // higher level (tries medium, quartile, high in order; the last one that
    // still fits wins — capacity only shrinks as the level rises, so this
    // never lowers below the requested level).
    var final_ecl = ecl;
    inline for ([_]Ecc{ .medium, .quartile, .high }) |candidate| {
        if (data_used_bits <= getNumDataCodewords(version, candidate) * 8) final_ecl = candidate;
    }

    const buf_len = bufferLenForVersion(version);
    @memset(qrcode_buf[0..buf_len], 0);
    var bit_len: i32 = 0;
    appendBitsToBuffer(0b0100, 4, qrcode_buf[0..], &bit_len); // byte-mode indicator
    appendBitsToBuffer(@intCast(text.len), @intCast(numCharCountBitsByte(version)), qrcode_buf[0..], &bit_len);
    for (text) |byte| appendBitsToBuffer(byte, 8, qrcode_buf[0..], &bit_len);
    std.debug.assert(bit_len == data_used_bits);

    // Terminator, then pad to a byte boundary.
    const data_capacity_bits = getNumDataCodewords(version, final_ecl) * 8;
    var terminator_bits = data_capacity_bits - bit_len;
    if (terminator_bits > 4) terminator_bits = 4;
    appendBitsToBuffer(0, @intCast(terminator_bits), qrcode_buf[0..], &bit_len);
    appendBitsToBuffer(0, @intCast(@mod(8 - @mod(bit_len, 8), 8)), qrcode_buf[0..], &bit_len);
    std.debug.assert(@mod(bit_len, 8) == 0);

    // Pad with alternating bytes until data capacity is reached.
    var pad_byte: u8 = 0xEC;
    while (bit_len < data_capacity_bits) {
        appendBitsToBuffer(pad_byte, 8, qrcode_buf[0..], &bit_len);
        pad_byte ^= 0xEC ^ 0x11;
    }

    // Compute ECC + interleave, then draw all modules.
    addEccAndInterleave(qrcode_buf[0..buf_len], version, final_ecl, temp_buf[0..]);
    initializeFunctionModules(version, qrcode_buf[0..]);
    drawCodewords(temp_buf[0..], @divTrunc(getNumRawDataModules(version), 8), qrcode_buf[0..]);
    drawLightFunctionModules(qrcode_buf[0..], version);
    initializeFunctionModules(version, temp_buf[0..]); // temp_buf becomes the function-module mask

    // Auto-select the mask with the lowest penalty score.
    var best_mask: u3 = 0;
    var min_penalty: i64 = std.math.maxInt(i64);
    var m: u3 = 0;
    while (true) {
        applyMask(temp_buf[0..], qrcode_buf[0..], m);
        drawFormatBits(final_ecl, m, qrcode_buf[0..]);
        const penalty = getPenaltyScore(qrcode_buf[0..]);
        if (penalty < min_penalty) {
            best_mask = m;
            min_penalty = penalty;
        }
        applyMask(temp_buf[0..], qrcode_buf[0..], m); // undo (XOR is its own inverse)
        if (m == 7) break;
        m += 1;
    }
    applyMask(temp_buf[0..], qrcode_buf[0..], best_mask);
    drawFormatBits(final_ecl, best_mask, qrcode_buf[0..]);

    const final_len = bufferLenForVersion(version);
    const out = try allocator.alloc(u8, final_len);
    @memcpy(out, qrcode_buf[0..final_len]);
    return .{ .allocator = allocator, .buf = out };
}

// --- sizing --------------------------------------------------------------

fn bufferLenForVersion(v: u8) usize {
    const n: i32 = @as(i32, v) * 4 + 17;
    return @intCast(@divTrunc(n * n + 7, 8) + 1);
}
const buffer_len_max = bufferLenForVersion(version_max);
const reed_solomon_degree_max = 30;

// --- bit buffer ------------------------------------------------------------

/// Appends the low `num_bits` bits of `val` to `buffer` (MSB-first), growing
/// `bit_len`. Requires `0 <= num_bits <= 16`.
fn appendBitsToBuffer(val: u32, num_bits: u5, buffer: []u8, bit_len: *i32) void {
    var i: i32 = @as(i32, num_bits) - 1;
    while (i >= 0) : (i -= 1) {
        const bit: u32 = (val >> @intCast(i)) & 1;
        const byte_idx: usize = @intCast(@divTrunc(bit_len.*, 8));
        const shift: u3 = @intCast(7 - @mod(bit_len.*, 8));
        buffer[byte_idx] |= @as(u8, @intCast(bit)) << shift;
        bit_len.* += 1;
    }
}

// --- version/ECC tables ----------------------------------------------------

// Index 0 is unused padding (illegal value), matching the reference so the
// version-indexed lookups below line up 1:1 with the spec's version numbers.
const ecc_codewords_per_block = [4][41]i8{
    .{ -1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 }, // Low
    .{ -1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28 }, // Medium
    .{ -1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 }, // Quartile
    .{ -1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 }, // High
};

const num_error_correction_blocks = [4][41]i8{
    .{ -1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25 }, // Low
    .{ -1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49 }, // Medium
    .{ -1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68 }, // Quartile
    .{ -1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81 }, // High
};

const penalty_n1: i64 = 3;
const penalty_n2: i64 = 3;
const penalty_n3: i64 = 40;
const penalty_n4: i64 = 10;

fn getNumRawDataModules(ver: u8) i32 {
    const v: i32 = ver;
    var result: i32 = (16 * v + 128) * v + 64;
    if (ver >= 2) {
        const num_align: i32 = @divTrunc(v, 7) + 2;
        result -= (25 * num_align - 10) * num_align - 55;
        if (ver >= 7) result -= 36;
    }
    return result;
}

fn getNumDataCodewords(version: u8, ecl: Ecc) i32 {
    const e: usize = @intFromEnum(ecl);
    const v: usize = version;
    return @divTrunc(getNumRawDataModules(version), 8) -
        @as(i32, ecc_codewords_per_block[e][v]) * @as(i32, num_error_correction_blocks[e][v]);
}

// --- byte-mode segment sizing ----------------------------------------------

/// Character-count field width (bits) for a byte-mode segment at `version` —
/// 8 bits for versions 1-9, 16 bits for versions 10-40.
fn numCharCountBitsByte(version: u8) i32 {
    return if (version < 10) 8 else 16;
}

fn calcSegmentBitLengthByte(num_chars: usize) ?i32 {
    if (num_chars > std.math.maxInt(i16)) return null;
    const result: i64 = @as(i64, @intCast(num_chars)) * 8;
    if (result > std.math.maxInt(i16)) return null;
    return @intCast(result);
}

fn getTotalBitsByte(num_chars: usize, version: u8) ?i32 {
    const bit_length = calcSegmentBitLengthByte(num_chars) orelse return null;
    const ccbits = numCharCountBitsByte(version);
    if (num_chars >= (@as(usize, 1) << @intCast(ccbits))) return null;
    const result: i64 = 4 + ccbits + bit_length;
    if (result > std.math.maxInt(i16)) return null;
    return @intCast(result);
}

// --- Reed-Solomon ECC --------------------------------------------------

/// Product of two GF(2^8/0x11D) field elements (Russian peasant multiplication).
fn reedSolomonMultiply(x: u8, y: u8) u8 {
    var z: u8 = 0;
    var i: i32 = 7;
    while (i >= 0) : (i -= 1) {
        const carry: u8 = z >> 7;
        z = (z << 1) ^ (carry * 0x1D);
        const ybit: u8 = (y >> @intCast(i)) & 1;
        z ^= ybit * x;
    }
    return z;
}

/// Computes the Reed-Solomon ECC generator polynomial of `degree` into
/// `result[0..degree]` (coefficients highest-to-lowest power, leading 1 term
/// implicit).
fn reedSolomonComputeDivisor(degree: u8, result: []u8) void {
    @memset(result[0..degree], 0);
    result[degree - 1] = 1;
    var root: u8 = 1;
    var i: u32 = 0;
    while (i < degree) : (i += 1) {
        var j: u32 = 0;
        while (j < degree) : (j += 1) {
            result[j] = reedSolomonMultiply(result[j], root);
            if (j + 1 < degree) result[j] ^= result[j + 1];
        }
        root = reedSolomonMultiply(root, 0x02);
    }
}

/// Remainder of `data` divided by the `degree`-degree `generator` polynomial,
/// stored in `result[0..degree]`.
fn reedSolomonComputeRemainder(data: []const u8, generator: []const u8, degree: u8, result: []u8) void {
    @memset(result[0..degree], 0);
    for (data) |b| {
        const factor = b ^ result[0];
        var k: u32 = 0;
        while (k < @as(u32, degree) - 1) : (k += 1) result[k] = result[k + 1];
        result[degree - 1] = 0;
        var j: u32 = 0;
        while (j < degree) : (j += 1) result[j] ^= reedSolomonMultiply(generator[j], factor);
    }
}

/// Appends ECC to each block of `data[0..dataLen]` (`data[dataLen..]` is
/// clobbered as scratch), then interleaves the blocks' bytes into `result`.
fn addEccAndInterleave(data: []u8, version: u8, ecl: Ecc, result: []u8) void {
    const e: usize = @intFromEnum(ecl);
    const v: usize = version;
    const num_blocks: i32 = num_error_correction_blocks[e][v];
    const block_ecc_len: i32 = ecc_codewords_per_block[e][v];
    const raw_codewords = @divTrunc(getNumRawDataModules(version), 8);
    const data_len: i32 = getNumDataCodewords(version, ecl);
    const num_short_blocks = num_blocks - @rem(raw_codewords, num_blocks);
    const short_block_data_len = @divTrunc(raw_codewords, num_blocks) - block_ecc_len;

    var rsdiv: [reed_solomon_degree_max]u8 = undefined;
    const becl: usize = @intCast(block_ecc_len);
    reedSolomonComputeDivisor(@intCast(block_ecc_len), rsdiv[0..becl]);

    var dat_pos: i32 = 0;
    var i: i32 = 0;
    while (i < num_blocks) : (i += 1) {
        const dat_len: i32 = short_block_data_len + (if (i < num_short_blocks) @as(i32, 0) else 1);
        const dat_slice = data[@intCast(dat_pos)..@intCast(dat_pos + dat_len)];
        const ecc_slice = data[@intCast(data_len)..@intCast(data_len + block_ecc_len)];
        reedSolomonComputeRemainder(dat_slice, rsdiv[0..becl], @intCast(block_ecc_len), ecc_slice);

        var j: i32 = 0;
        var k: i32 = i;
        while (j < dat_len) : (j += 1) {
            if (j == short_block_data_len) k -= num_short_blocks;
            result[@intCast(k)] = dat_slice[@intCast(j)];
            k += num_blocks;
        }
        j = 0;
        k = data_len + i;
        while (j < block_ecc_len) : (j += 1) {
            result[@intCast(k)] = ecc_slice[@intCast(j)];
            k += num_blocks;
        }
        dat_pos += dat_len;
    }
}

// --- module grid primitives --------------------------------------------

fn getBit(x: i32, i: u5) bool {
    return ((x >> i) & 1) != 0;
}

fn getModuleBounded(qrcode: []const u8, x: i32, y: i32) bool {
    const qrsize: i32 = qrcode[0];
    const index: i32 = y * qrsize + x;
    const byte_idx: usize = @intCast(@divTrunc(index, 8) + 1);
    const bit_idx: u5 = @intCast(@mod(index, 8));
    return getBit(qrcode[byte_idx], bit_idx);
}

fn setModuleBounded(qrcode: []u8, x: i32, y: i32, is_dark: bool) void {
    const qrsize: i32 = qrcode[0];
    const index: i32 = y * qrsize + x;
    const byte_idx: usize = @intCast(@divTrunc(index, 8) + 1);
    const bit_idx: u3 = @intCast(@mod(index, 8));
    if (is_dark) {
        qrcode[byte_idx] |= (@as(u8, 1) << bit_idx);
    } else {
        qrcode[byte_idx] &= ~(@as(u8, 1) << bit_idx);
    }
}

fn setModuleUnbounded(qrcode: []u8, x: i32, y: i32, is_dark: bool) void {
    const qrsize: i32 = qrcode[0];
    if (x >= 0 and x < qrsize and y >= 0 and y < qrsize) setModuleBounded(qrcode, x, y, is_dark);
}

fn fillRectangle(left: i32, top: i32, width: i32, height: i32, qrcode: []u8) void {
    var dy: i32 = 0;
    while (dy < height) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < width) : (dx += 1) setModuleBounded(qrcode, left + dx, top + dy, true);
    }
}

/// Ascending alignment-pattern positions for `version` into `result[0..N]`,
/// returning N (0..7). Both axes use the same list.
fn getAlignmentPatternPositions(version: u8, result: *[7]u8) u8 {
    if (version == 1) return 0;
    const v: i32 = version;
    const num_align: i32 = @divTrunc(v, 7) + 2;
    const step: i32 = @divTrunc(v * 8 + num_align * 3 + 5, num_align * 4 - 4) * 2;
    var i: i32 = num_align - 1;
    var pos: i32 = v * 4 + 10;
    while (i >= 1) : ({
        i -= 1;
        pos -= step;
    }) {
        result[@intCast(i)] = @intCast(pos);
    }
    result[0] = 6;
    return @intCast(num_align);
}

/// Clears `qrcode` to `version`'s size (all-light) then marks every function
/// module (finders, timing, alignment, version blocks) dark. The first pass
/// before the real light/dark pattern is drawn on top.
fn initializeFunctionModules(version: u8, qrcode: []u8) void {
    const qrsize: i32 = @as(i32, version) * 4 + 17;
    const total_bytes: usize = @intCast(@divTrunc(qrsize * qrsize + 7, 8) + 1);
    @memset(qrcode[0..total_bytes], 0);
    qrcode[0] = @intCast(qrsize);

    fillRectangle(6, 0, 1, qrsize, qrcode);
    fillRectangle(0, 6, qrsize, 1, qrcode);

    fillRectangle(0, 0, 9, 9, qrcode);
    fillRectangle(qrsize - 8, 0, 8, 9, qrcode);
    fillRectangle(0, qrsize - 8, 9, 8, qrcode);

    var align_pat_pos: [7]u8 = undefined;
    const num_align = getAlignmentPatternPositions(version, &align_pat_pos);
    var i: u8 = 0;
    while (i < num_align) : (i += 1) {
        var j: u8 = 0;
        while (j < num_align) : (j += 1) {
            if ((i == 0 and j == 0) or (i == 0 and j == num_align - 1) or (i == num_align - 1 and j == 0)) continue;
            fillRectangle(@as(i32, align_pat_pos[i]) - 2, @as(i32, align_pat_pos[j]) - 2, 5, 5, qrcode);
        }
    }

    if (version >= 7) {
        fillRectangle(qrsize - 11, 0, 3, 6, qrcode);
        fillRectangle(0, qrsize - 11, 6, 3, qrcode);
    }
}

/// Draws the light timing/finder/alignment/version pixels (and the version
/// blocks' dark bits) onto a grid whose function modules were pre-marked dark
/// by `initializeFunctionModules`. Doesn't draw format bits.
fn drawLightFunctionModules(qrcode: []u8, version: u8) void {
    const qrsize: i32 = qrcode[0];

    var i: i32 = 7;
    while (i < qrsize - 7) : (i += 2) {
        setModuleBounded(qrcode, 6, i, false);
        setModuleBounded(qrcode, i, 6, false);
    }

    var dy: i32 = -4;
    while (dy <= 4) : (dy += 1) {
        var dx: i32 = -4;
        while (dx <= 4) : (dx += 1) {
            const dist = @max(@abs(dx), @abs(dy));
            if (dist == 2 or dist == 4) {
                setModuleUnbounded(qrcode, 3 + dx, 3 + dy, false);
                setModuleUnbounded(qrcode, qrsize - 4 + dx, 3 + dy, false);
                setModuleUnbounded(qrcode, 3 + dx, qrsize - 4 + dy, false);
            }
        }
    }

    var align_pat_pos: [7]u8 = undefined;
    const num_align = getAlignmentPatternPositions(version, &align_pat_pos);
    var ai: u8 = 0;
    while (ai < num_align) : (ai += 1) {
        var aj: u8 = 0;
        while (aj < num_align) : (aj += 1) {
            if ((ai == 0 and aj == 0) or (ai == 0 and aj == num_align - 1) or (ai == num_align - 1 and aj == 0)) continue;
            var ddy: i32 = -1;
            while (ddy <= 1) : (ddy += 1) {
                var ddx: i32 = -1;
                while (ddx <= 1) : (ddx += 1) {
                    setModuleBounded(qrcode, @as(i32, align_pat_pos[ai]) + ddx, @as(i32, align_pat_pos[aj]) + ddy, ddx == 0 and ddy == 0);
                }
            }
        }
    }

    if (version >= 7) {
        var rem: i32 = version;
        var bi: u32 = 0;
        while (bi < 12) : (bi += 1) rem = (rem << 1) ^ (@divTrunc(rem, 2048) * 0x1F25);
        const bits: i32 = (@as(i32, version) << 12) | rem;

        var ri: i32 = 0;
        while (ri < 6) : (ri += 1) {
            var rj: i32 = 0;
            while (rj < 3) : (rj += 1) {
                const k = qrsize - 11 + rj;
                const bit_idx: i32 = ri * 3 + rj;
                const dark = getBit(bits, @intCast(bit_idx));
                setModuleBounded(qrcode, k, ri, dark);
                setModuleBounded(qrcode, ri, k, dark);
            }
        }
    }
}

/// Draws both copies of the format bits for `ecl`/`mask`, overwriting
/// whatever was there before (unlike `drawLightFunctionModules`, which may
/// skip already-dark modules).
fn drawFormatBits(ecl: Ecc, mask: u3, qrcode: []u8) void {
    const table = [4]i32{ 1, 0, 3, 2 };
    const data: i32 = (table[@intFromEnum(ecl)] << 3) | @as(i32, mask);
    var rem: i32 = data;
    var i: u32 = 0;
    while (i < 10) : (i += 1) rem = (rem << 1) ^ (@divTrunc(rem, 512) * 0x537);
    const bits: i32 = ((data << 10) | rem) ^ 0x5412;

    var bi: i32 = 0;
    while (bi <= 5) : (bi += 1) setModuleBounded(qrcode, 8, bi, getBit(bits, @intCast(bi)));
    setModuleBounded(qrcode, 8, 7, getBit(bits, 6));
    setModuleBounded(qrcode, 8, 8, getBit(bits, 7));
    setModuleBounded(qrcode, 7, 8, getBit(bits, 8));
    bi = 9;
    while (bi < 15) : (bi += 1) setModuleBounded(qrcode, 14 - bi, 8, getBit(bits, @intCast(bi)));

    const qrsize: i32 = qrcode[0];
    bi = 0;
    while (bi < 8) : (bi += 1) setModuleBounded(qrcode, qrsize - 1 - bi, 8, getBit(bits, @intCast(bi)));
    bi = 8;
    while (bi < 15) : (bi += 1) setModuleBounded(qrcode, 8, qrsize - 15 + bi, getBit(bits, @intCast(bi)));
    setModuleBounded(qrcode, 8, qrsize - 8, true);
}

/// Draws `data`'s bits into the non-function modules, in the QR zigzag scan
/// order (column pairs, right to left, alternating up/down, skipping the
/// vertical timing column).
fn drawCodewords(data: []const u8, data_len: i32, qrcode: []u8) void {
    const qrsize: i32 = qrcode[0];
    var i: i32 = 0;
    var right: i32 = qrsize - 1;
    while (right >= 1) : (right -= 2) {
        if (right == 6) right = 5;
        var vert: i32 = 0;
        while (vert < qrsize) : (vert += 1) {
            var j: i32 = 0;
            while (j < 2) : (j += 1) {
                const x = right - j;
                const upward = @mod(right + 1, 4) < 2; // ((right + 1) & 2) == 0
                const y = if (upward) qrsize - 1 - vert else vert;
                if (!getModuleBounded(qrcode, x, y) and i < data_len * 8) {
                    const byte_val: i32 = data[@intCast(@divTrunc(i, 8))];
                    const dark = getBit(byte_val, @intCast(7 - @mod(i, 8)));
                    setModuleBounded(qrcode, x, y, dark);
                    i += 1;
                }
            }
        }
    }
}

/// XORs the non-function modules with mask pattern `mask`. Calling this
/// twice with the same mask undoes it (XOR is its own inverse).
fn applyMask(function_modules: []const u8, qrcode: []u8, mask: u3) void {
    const qrsize: i32 = qrcode[0];
    var y: i32 = 0;
    while (y < qrsize) : (y += 1) {
        var x: i32 = 0;
        while (x < qrsize) : (x += 1) {
            if (getModuleBounded(function_modules, x, y)) continue;
            const invert = switch (mask) {
                0 => @mod(x + y, 2) == 0,
                1 => @mod(y, 2) == 0,
                2 => @mod(x, 3) == 0,
                3 => @mod(x + y, 3) == 0,
                4 => @mod(@divTrunc(x, 3) + @divTrunc(y, 2), 2) == 0,
                5 => @mod(x * y, 2) + @mod(x * y, 3) == 0,
                6 => @mod(@mod(x * y, 2) + @mod(x * y, 3), 2) == 0,
                7 => @mod(@mod(x + y, 2) + @mod(x * y, 3), 2) == 0,
            };
            const val = getModuleBounded(qrcode, x, y);
            setModuleBounded(qrcode, x, y, val != invert);
        }
    }
}

/// Lower is better. Penalizes long runs, 2x2 blocks, finder-like patterns,
/// and an imbalanced dark/light ratio — used to pick the best of the 8 masks.
fn getPenaltyScore(qrcode: []const u8) i64 {
    const qrsize: i32 = qrcode[0];
    var result: i64 = 0;

    var y: i32 = 0;
    while (y < qrsize) : (y += 1) {
        var run_color = false;
        var run_x: i32 = 0;
        var run_history = [_]i32{0} ** 7;
        var x: i32 = 0;
        while (x < qrsize) : (x += 1) {
            if (getModuleBounded(qrcode, x, y) == run_color) {
                run_x += 1;
                if (run_x == 5) result += penalty_n1 else if (run_x > 5) result += 1;
            } else {
                finderPenaltyAddHistory(run_x, &run_history, qrsize);
                if (!run_color) result += @as(i64, finderPenaltyCountPatterns(&run_history)) * penalty_n3;
                run_color = getModuleBounded(qrcode, x, y);
                run_x = 1;
            }
        }
        result += @as(i64, finderPenaltyTerminateAndCount(run_color, run_x, &run_history, qrsize)) * penalty_n3;
    }

    var x2: i32 = 0;
    while (x2 < qrsize) : (x2 += 1) {
        var run_color = false;
        var run_y: i32 = 0;
        var run_history = [_]i32{0} ** 7;
        var y2: i32 = 0;
        while (y2 < qrsize) : (y2 += 1) {
            if (getModuleBounded(qrcode, x2, y2) == run_color) {
                run_y += 1;
                if (run_y == 5) result += penalty_n1 else if (run_y > 5) result += 1;
            } else {
                finderPenaltyAddHistory(run_y, &run_history, qrsize);
                if (!run_color) result += @as(i64, finderPenaltyCountPatterns(&run_history)) * penalty_n3;
                run_color = getModuleBounded(qrcode, x2, y2);
                run_y = 1;
            }
        }
        result += @as(i64, finderPenaltyTerminateAndCount(run_color, run_y, &run_history, qrsize)) * penalty_n3;
    }

    var by: i32 = 0;
    while (by < qrsize - 1) : (by += 1) {
        var bx: i32 = 0;
        while (bx < qrsize - 1) : (bx += 1) {
            const color = getModuleBounded(qrcode, bx, by);
            if (color == getModuleBounded(qrcode, bx + 1, by) and
                color == getModuleBounded(qrcode, bx, by + 1) and
                color == getModuleBounded(qrcode, bx + 1, by + 1))
            {
                result += penalty_n2;
            }
        }
    }

    var dark: i64 = 0;
    var dy2: i32 = 0;
    while (dy2 < qrsize) : (dy2 += 1) {
        var dx2: i32 = 0;
        while (dx2 < qrsize) : (dx2 += 1) {
            if (getModuleBounded(qrcode, dx2, dy2)) dark += 1;
        }
    }
    const total: i64 = @as(i64, qrsize) * @as(i64, qrsize);
    const diff: i64 = dark * 20 - total * 10;
    const abs_diff: i64 = if (diff < 0) -diff else diff;
    const k: i64 = @divTrunc(abs_diff + total - 1, total) - 1;
    result += k * penalty_n4;
    return result;
}

fn finderPenaltyCountPatterns(run_history: *const [7]i32) i32 {
    const n = run_history[1];
    const core = n > 0 and run_history[2] == n and run_history[3] == n * 3 and run_history[4] == n and run_history[5] == n;
    var count: i32 = 0;
    if (core and run_history[0] >= n * 4 and run_history[6] >= n) count += 1;
    if (core and run_history[6] >= n * 4 and run_history[0] >= n) count += 1;
    return count;
}

fn finderPenaltyTerminateAndCount(current_run_color: bool, current_run_length_in: i32, run_history: *[7]i32, qrsize: i32) i32 {
    var current_run_length = current_run_length_in;
    if (current_run_color) {
        finderPenaltyAddHistory(current_run_length, run_history, qrsize);
        current_run_length = 0;
    }
    current_run_length += qrsize;
    finderPenaltyAddHistory(current_run_length, run_history, qrsize);
    return finderPenaltyCountPatterns(run_history);
}

fn finderPenaltyAddHistory(current_run_length_in: i32, run_history: *[7]i32, qrsize: i32) void {
    var current_run_length = current_run_length_in;
    if (run_history[0] == 0) current_run_length += qrsize;
    var i: usize = 6;
    while (i >= 1) : (i -= 1) run_history[i] = run_history[i - 1];
    run_history[0] = current_run_length;
}

// --- tests -------------------------------------------------------------

test "getNumRawDataModules matches known values" {
    // Version 1: 26*26 - 3*finder(8x8 incl separator, minus overlaps) ... use
    // the reference's own documented range/behavior instead of re-deriving:
    // result is in [208, 29648] for all valid versions.
    var v: u8 = version_min;
    while (v <= version_max) : (v += 1) {
        const r = getNumRawDataModules(v);
        try std.testing.expect(r >= 208 and r <= 29648);
    }
    // Version 1 has no alignment patterns and no version blocks: 21*21 grid.
    // Known correct value (matches the C reference and the QR spec table).
    try std.testing.expectEqual(@as(i32, 208), getNumRawDataModules(1));
}

test "getNumDataCodewords is positive and within raw codeword bounds for every version/ecl" {
    var v: u8 = version_min;
    while (v <= version_max) : (v += 1) {
        const raw = @divTrunc(getNumRawDataModules(v), 8);
        inline for ([_]Ecc{ .low, .medium, .quartile, .high }) |ecl| {
            const d = getNumDataCodewords(v, ecl);
            try std.testing.expect(d > 0 and d <= raw);
        }
    }
}

test "reedSolomonMultiply matches known GF(256) products" {
    // 0 is absorbing.
    try std.testing.expectEqual(@as(u8, 0), reedSolomonMultiply(0, 200));
    try std.testing.expectEqual(@as(u8, 0), reedSolomonMultiply(200, 0));
    // 1 is identity.
    try std.testing.expectEqual(@as(u8, 200), reedSolomonMultiply(1, 200));
    // Multiplication is commutative in this field.
    try std.testing.expectEqual(reedSolomonMultiply(0x53, 0xCA), reedSolomonMultiply(0xCA, 0x53));
}

test "reedSolomonComputeRemainder against the compiled Nayuki reference" {
    // Message codewords for "Hello World" at version 1, degree-13 ECC block
    // (16 data codewords -> 13 ECC codewords). Expected divisor/remainder
    // generated by calling the actual reference's `reedSolomonComputeDivisor`/
    // `reedSolomonComputeRemainder` directly (built with `-DQRCODEGEN_TEST`
    // to expose the normally-static functions) — not from memory.
    const data = [_]u8{ 0x10, 0x20, 0x0C, 0x56, 0x61, 0x80, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11 };
    var divisor: [13]u8 = undefined;
    reedSolomonComputeDivisor(13, &divisor);
    const expected_divisor = [_]u8{ 0x89, 0x49, 0xE3, 0x11, 0xB1, 0x11, 0x34, 0x0D, 0x2E, 0x2B, 0x53, 0x84, 0x78 };
    try std.testing.expectEqualSlices(u8, &expected_divisor, &divisor);

    var remainder: [13]u8 = undefined;
    reedSolomonComputeRemainder(&data, &divisor, 13, &remainder);
    const expected_remainder = [_]u8{ 0x8F, 0x4A, 0x4D, 0xF9, 0xBD, 0x0F, 0x18, 0xE0, 0x25, 0x0D, 0x91, 0xBE, 0x4A };
    try std.testing.expectEqualSlices(u8, &expected_remainder, &remainder);
}

test "getAlignmentPatternPositions: none for version 1, symmetric endpoints otherwise" {
    var buf: [7]u8 = undefined;
    try std.testing.expectEqual(@as(u8, 0), getAlignmentPatternPositions(1, &buf));

    const n = getAlignmentPatternPositions(7, &buf);
    try std.testing.expect(n >= 2);
    try std.testing.expectEqual(@as(u8, 6), buf[0]); // always starts at 6
    try std.testing.expectEqual(@as(u8, 7 * 4 + 10), buf[n - 1]); // last = version*4+10
}

test "encodeText rejects empty text" {
    try std.testing.expectError(error.EmptyText, encodeText(std.testing.allocator, "", .medium));
}

test "encodeText picks a small version for a short address and produces a valid-looking grid" {
    const addr = "XmM8G6mfvJvqfxLnf78EE7oGDwtvfxKz9y"; // 35 chars, matches a SpiderByte-shaped address
    const qr = try encodeText(std.testing.allocator, addr, .medium);
    defer qr.deinit();

    // Cross-checked against the compiled Nayuki C reference for this exact
    // input/ECC combination: version 3 -> 29x29.
    try std.testing.expectEqual(@as(u16, 29), qr.size());

    // Structural invariants: the three finder patterns' centers are dark,
    // and the module just outside each finder (the separator) is light.
    try std.testing.expect(qr.get(3, 3)); // top-left finder center
    try std.testing.expect(qr.get(qr.size() - 4, 3)); // top-right finder center
    try std.testing.expect(qr.get(3, qr.size() - 4)); // bottom-left finder center
    try std.testing.expect(!qr.get(7, 7)); // separator, top-left
}

// Golden fixture generated by compiling Project Nayuki's actual reference
// implementation (`qrcodegen.c`/`.h`) with `gcc -O2` and running
// `./dump_qr "XmM8G6mfvJvqfxLnf78EE7oGDwtvfxKz9y" M`, which calls
// `qrcodegen_encodeText` and dumps `qrcodegen_getModule(x, y)` for every cell
// — not hand-derived. The input is a SpiderByte-shaped address (mixed-case,
// 35 chars): deliberately NOT alphanumeric-QR-mode-eligible (it has lowercase
// letters), so the reference's own automatic mode selection also falls back
// to byte mode — matching what this port always uses — rather than silently
// picking alphanumeric mode and producing a fixture this byte-mode-only port
// could never match. Row-major, '1' = dark, '0' = light.
const golden_addr_size: i32 = 29;
const golden_addr =
    "11111110111101110111101111111" ++
    "10000010100011001010001000001" ++
    "10111010011110001010101011101" ++
    "10111010100010110000101011101" ++
    "10111010001100101101101011101" ++
    "10000010010101011111101000001" ++
    "11111110101010101010101111111" ++
    "00000000110110011110000000000" ++
    "10110111000001011011001001011" ++
    "10100000010011110010111110101" ++
    "01101010011101001110010000100" ++
    "10011100001010001001100000011" ++
    "10100011101110101100000100001" ++
    "10010000110110111110011001100" ++
    "10110011101111000111000010111" ++
    "10001101101000110000010110000" ++
    "11100110101110111011010011011" ++
    "00001100100010111010001100000" ++
    "10011010111011110000101000100" ++
    "00101100100001110101000111100" ++
    "01000011001011110111111111100" ++
    "00000000101010001001100011100" ++
    "11111110111110101011101011110" ++
    "10000010100101111001100010000" ++
    "10111010001100000100111110110" ++
    "10111010111101001100010101101" ++
    "10111010111001101110000101101" ++
    "10000010011000010010101001010" ++
    "11111110111001111011101001010";

test "encodeText golden matrix matches the compiled Nayuki reference exactly" {
    // Generated via `gcc -O2 qrcodegen.c dump_qr.c -o dump_qr &&
    // ./dump_qr "XmM8G6mfvJvqfxLnf78EE7oGDwtvfxKz9y" M` against the actual
    // upstream C reference (project root untouched; scratch tooling only) —
    // this is the strongest correctness check available without a live phone
    // scan: bit-for-bit identical to the canonical implementation for a real
    // address-shaped input, not just "looks plausible."
    const text = "XmM8G6mfvJvqfxLnf78EE7oGDwtvfxKz9y";
    const qr = try encodeText(std.testing.allocator, text, .medium);
    defer qr.deinit();
    try std.testing.expectEqual(@as(u16, golden_addr_size), qr.size());

    var y: i32 = 0;
    var idx: usize = 0;
    while (y < golden_addr_size) : (y += 1) {
        var x: i32 = 0;
        while (x < golden_addr_size) : (x += 1) {
            const expected = golden_addr[idx] == '1';
            try std.testing.expectEqual(expected, qr.get(x, y));
            idx += 1;
        }
    }
}

// Golden fixture generated the same way, via `./dump_qr "sp1der" L` —
// requests `.low`, but the reference (verified with a debug print inside
// `qrcodegen_encodeSegmentsAdvanced`) actually boosts to `.high` for this
// short input, since the data still fits version 1's HIGH-level capacity.
// Exercises the `boostEcl` upgrade path bit-for-bit, not just structurally.
const golden_boost_size: i32 = 21;
const golden_boost =
    "111111100010101111111" ++
    "100000100111101000001" ++
    "101110100100001011101" ++
    "101110100101101011101" ++
    "101110101100101011101" ++
    "100000100100001000001" ++
    "111111101010101111111" ++
    "000000001111000000000" ++
    "001100111000111010000" ++
    "001100010100001100111" ++
    "100101110100010111011" ++
    "110101001111001000001" ++
    "011010100110010011000" ++
    "000000001001110001010" ++
    "111111101101001011000" ++
    "100000100110100111101" ++
    "101110100000100001111" ++
    "101110101000100101010" ++
    "101110101100001000100" ++
    "100000100001001100001" ++
    "111111100001111110100";

test "encodeText golden matrix exercises the boostEcl upgrade path" {
    // Requesting `.low` but the reference silently boosts to `.high` here —
    // if this port's boost logic diverged from the reference (wrong
    // direction, wrong condition, off-by-one in the candidate loop), this
    // fixture would show a completely different mask/module pattern, not
    // just a few flipped bits, since the ECC codeword count itself would
    // differ.
    const text = "sp1der";
    const qr = try encodeText(std.testing.allocator, text, .low);
    defer qr.deinit();
    try std.testing.expectEqual(@as(u16, golden_boost_size), qr.size());

    var y: i32 = 0;
    var idx: usize = 0;
    while (y < golden_boost_size) : (y += 1) {
        var x: i32 = 0;
        while (x < golden_boost_size) : (x += 1) {
            const expected = golden_boost[idx] == '1';
            try std.testing.expectEqual(expected, qr.get(x, y));
            idx += 1;
        }
    }
}
