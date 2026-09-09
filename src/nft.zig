//! Non-fungible token **data bundles**: fetch one, prove it is the file the
//! chain committed to, and unpack the two small parts a front-end actually
//! shows.
//!
//! This module is deliberately coin-agnostic. It knows nothing about group
//! identifiers, addresses or RPC — a coin hands it a URL and the 32-byte hash
//! its chain commits to, and gets back `models.NftMeta`. Nexa is the only
//! caller today (`src/coins/nexa.zig` derives both from a token's subgroup
//! identifier), but nothing here is Nexa-shaped.
//!
//! **The hash check is the point.** An NFT bundle is fetched over plain HTTP
//! from whatever host the issuer named, so the bytes are not trustworthy on
//! arrival. The chain commits to the double-SHA256 of the file, so a downloaded
//! bundle is only that NFT if it hashes to the committed value. A mismatch is
//! an error here, never a "close enough" — a front-end must never present
//! unverified bytes as the chain's artwork.
//!
//! Memory stays flat, per the project's memory rule: the bundle streams to a
//! scratch file on disk (bundles run to tens of MB), the hash is computed in
//! fixed chunks over that file, and only the entries we want are inflated —
//! the multi-megabyte full-resolution and owner-only media are skipped
//! entirely rather than unpacked and then ignored. Nothing larger than a
//! 64 KB buffer is ever resident.

const std = @import("std");
const models = @import("models.zig");
const install = @import("install.zig");

/// The bundle entries this module unpacks, in the order a card image is
/// preferred. `info.json` is the metadata; `cardf` is the front of the card —
/// the thumbnail the NFT specification tells wallets to show. `public` is the
/// full-resolution work, used only when a bundle ships no front card.
///
/// Everything else in a bundle (the back card, owner-only media, application
/// payloads) is left in the archive. That is what keeps a 27 MB NFT from
/// costing 27 MB of disk per view.
const info_entry = "info.json";

/// Extensions the NFT specification allows for card art, most-preferred first.
/// A bundle names its card `cardf.<ext>`, so the entry name is one of these
/// stems crossed with one of these extensions.
const card_extensions = [_][]const u8{
    ".png", ".jpg", ".jpeg", ".gif", ".apng", ".webp", ".svg", ".avif",
};

/// Card stems in preference order: the front card first, the full-resolution
/// work as the fallback for a bundle that ships no card.
const card_stems = [_][]const u8{ "cardf", "public" };

/// The largest single entry this module will inflate out of a bundle. Card art
/// is capped at 2 MB by the specification and `info.json` is a few hundred
/// bytes; anything claiming to be far larger is either not what it says it is
/// or not worth the disk, and is skipped.
const max_entry_bytes: u64 = 8 * 1024 * 1024;

pub const Error = error{
    /// The downloaded bytes did not hash to the value the chain commits to.
    /// The bundle is not this NFT: refuse it rather than showing it.
    HashMismatch,
    /// The bundle downloaded and verified, but carried no `info.json` — it does
    /// not follow the NFT data format.
    NotAnNftBundle,
};

/// Fetch, verify and unpack the NFT data bundle at `url`.
///
/// `expected` is the double-SHA256 the chain commits to (for Nexa, the subgroup
/// identifier's trailing 32 bytes). `cache_root` is a directory BoxWallet owns;
/// each NFT gets its own subdirectory under it, named by the hex of `expected`,
/// so a second view costs no network at all.
///
/// The scratch bundle is deleted once unpacked, on every path — the extracted
/// `info.json` plus one card image is all that is kept.
pub fn fetchBundle(
    allocator: std.mem.Allocator,
    url: []const u8,
    cache_root: []const u8,
    expected: [32]u8,
) !models.NftMeta {
    var hex: [64]u8 = undefined;
    toHex(&hex, &expected);

    const dir_path = try std.fs.path.join(allocator, &.{ cache_root, &hex });
    defer allocator.free(dir_path);

    // A previous fetch already proved these bytes: the directory only ever gets
    // its entries after the hash matched, so a cache hit is a verified hit.
    if (readCached(allocator, dir_path)) |cached| return cached;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bundle_name = "bundle.zip";
    try install.downloadFile(allocator, url, dir_path, bundle_name, null);

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    // The bundle is scratch: it has served its purpose the moment the wanted
    // entries are out, and it is the only large thing here.
    defer dir.deleteFile(io, bundle_name) catch {};

    if (!try fileMatchesDoubleSha256(io, dir, bundle_name, expected)) {
        // Leave nothing behind that a later run could mistake for a cache hit.
        dir.deleteFile(io, info_entry) catch {};
        return Error.HashMismatch;
    }

    try unpackWanted(io, dir, bundle_name);

    var meta = try readInfoJson(allocator, io, dir);
    meta.verified = true;
    try setCardPath(allocator, io, dir, dir_path, &meta);
    return meta;
}

/// Re-read an already-unpacked bundle from the cache. Returns null when this
/// NFT has not been fetched yet (or its unpack was interrupted), which sends
/// the caller down the download path.
fn readCached(allocator: std.mem.Allocator, dir_path: []const u8) ?models.NftMeta {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return null;
    defer dir.close(io);

    var meta = readInfoJson(allocator, io, dir) catch return null;
    meta.verified = true;
    setCardPath(allocator, io, dir, dir_path, &meta) catch {};
    return meta;
}

/// Whether `name` in `dir` hashes to `expected` under SHA256(SHA256(bytes)) —
/// the double hash the NFT specification commits to. Streams the file in fixed
/// chunks, so a 50 MB bundle costs one 64 KB buffer.
fn fileMatchesDoubleSha256(
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
    expected: [32]u8,
) !bool {
    var f = try dir.openFile(io, name, .{});
    defer f.close(io);

    var rbuf: [64 * 1024]u8 = undefined;
    var fr = f.reader(io, &rbuf);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try fr.interface.readSliceShort(&chunk);
        if (n == 0) break;
        hasher.update(chunk[0..n]);
    }
    const first = hasher.finalResult();

    var second: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&first, &second, .{});

    // Constant-time is pointless here (both values are public), but a plain
    // equality on the whole digest is what makes this a real check.
    return std.mem.eql(u8, &second, &expected);
}

/// Inflate just `info.json` and the best card image out of the bundle, into the
/// same directory. Every other entry is stepped over without being decompressed
/// — `std.zip`'s iterator reads the central directory, so skipping an entry
/// costs a seek rather than a decode.
fn unpackWanted(io: std.Io, dir: std.Io.Dir, bundle_name: []const u8) !void {
    var archive = try dir.openFile(io, bundle_name, .{});
    defer archive.close(io);

    var rbuf: [64 * 1024]u8 = undefined;
    var ar = archive.reader(io, &rbuf);

    var iter = try std.zip.Iterator.init(&ar);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    // The stem index of the card unpacked so far, so a later `public` never
    // displaces an earlier `cardf` regardless of the archive's ordering.
    var best_stem: ?usize = null;

    while (try iter.next()) |entry| {
        if (entry.filename_len > name_buf.len) continue;
        if (entry.uncompressed_size > max_entry_bytes) continue;

        const name = try entryName(&ar, entry, &name_buf);
        const wanted = if (std.mem.eql(u8, name, info_entry)) info: {
            break :info true;
        } else if (cardStemIndex(name)) |stem| card: {
            if (best_stem) |b| if (b <= stem) break :card false;
            best_stem = stem;
            break :card true;
        } else false;
        if (!wanted) continue;

        // Only ever an exact match against the allowlist above, so no entry
        // name can escape the directory however the archive spells it.
        var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
        entry.extract(&ar, .{ .allow_backslashes = true }, &filename_buf, dir) catch continue;
    }
}

/// Read one entry's filename out of the central directory record the iterator
/// just walked past. `std.zip`'s `Entry` carries the name's length and offset
/// but not the name itself, and the extractor only reads it on the way to
/// writing the file — which is exactly what we are trying to avoid doing for
/// entries we don't want.
fn entryName(
    ar: *std.Io.File.Reader,
    entry: std.zip.Iterator.Entry,
    buf: []u8,
) ![]const u8 {
    const name = buf[0..entry.filename_len];
    try ar.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
    try ar.interface.readSliceAll(name);
    return name;
}

/// Which card stem `name` is, or null when it is not card art at all. Lower is
/// better: 0 is the front card, 1 the full-resolution fallback.
fn cardStemIndex(name: []const u8) ?usize {
    for (card_stems, 0..) |stem, i| {
        if (name.len <= stem.len) continue;
        if (!std.mem.eql(u8, name[0..stem.len], stem)) continue;
        const ext = name[stem.len..];
        for (card_extensions) |allowed| {
            if (std.ascii.eqlIgnoreCase(ext, allowed)) return i;
        }
    }
    return null;
}

/// Point `meta.card_path` at whichever card image is on disk, or leave it empty
/// when the bundle shipped none. Checked in preference order so a bundle
/// carrying both a front card and a full-resolution work shows the card.
fn setCardPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    dir_path: []const u8,
    meta: *models.NftMeta,
) !void {
    for (card_stems) |stem| {
        for (card_extensions) |ext| {
            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ stem, ext }) catch continue;
            var f = dir.openFile(io, name, .{}) catch continue;
            f.close(io);

            const full = try std.fs.path.join(allocator, &.{ dir_path, name });
            defer allocator.free(full);
            meta.setCardPath(full);
            return;
        }
    }
}

/// Parse the bundle's `info.json` into the normalized metadata. The document is
/// a few hundred bytes by design, so it is read whole — bounded by
/// `max_info_bytes` so a hostile bundle can't turn this into an allocation.
fn readInfoJson(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !models.NftMeta {
    const max_info_bytes = 64 * 1024;

    var f = dir.openFile(io, info_entry, .{}) catch return Error.NotAnNftBundle;
    defer f.close(io);

    var rbuf: [4096]u8 = undefined;
    var fr = f.reader(io, &rbuf);
    const text = try fr.interface.allocRemaining(allocator, .limited(max_info_bytes));
    defer allocator.free(text);

    return parseInfoJson(allocator, text);
}

/// Fold an `info.json` document into `models.NftMeta`. Split out from the file
/// read so it is testable from a literal, and tolerant by design: a bundle with
/// a missing or wrongly-typed field yields an empty string for that field
/// rather than failing the whole NFT, since the artwork is still the artwork.
pub fn parseInfoJson(allocator: std.mem.Allocator, text: []const u8) !models.NftMeta {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch {
        return Error.NotAnNftBundle;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return Error.NotAnNftBundle,
    };

    var meta: models.NftMeta = .{};
    meta.setTitle(stringField(obj, "title"));
    meta.setAuthor(stringField(obj, "author"));
    meta.setSeries(stringField(obj, "series"));
    meta.setCategory(stringField(obj, "category"));
    meta.setInfo(stringField(obj, "info"));
    meta.setLicense(stringField(obj, "license"));
    return meta;
}

/// One string field out of the document, or empty when absent or not a string.
fn stringField(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

/// Lowercase hex of `bytes` into `out`, which must be exactly twice as long.
pub fn toHex(out: []u8, bytes: []const u8) void {
    std.debug.assert(out.len == bytes.len * 2);
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0f];
    }
}

test "parseInfoJson folds the specification's fields and tolerates the rest" {
    const doc =
        \\{
        \\  "niftyVer":"2.0",
        \\  "title": "#2",
        \\  "series":"Macro World",
        \\  "author": "Gidra363",
        \\  "keywords": [ "" ],
        \\  "category":"Nexa ",
        \\  "appuri": "",
        \\  "info": "",
        \\  "data" : {},
        \\  "license": ""
        \\}
    ;
    const meta = try parseInfoJson(std.testing.allocator, doc);
    try std.testing.expectEqualStrings("#2", meta.title());
    try std.testing.expectEqualStrings("Gidra363", meta.author());
    try std.testing.expectEqualStrings("Macro World", meta.series());
    try std.testing.expectEqualStrings("Nexa ", meta.category());
    try std.testing.expectEqualStrings("", meta.info());
    // Not yet proven against the chain's hash — only `fetchBundle` sets this.
    try std.testing.expect(!meta.verified);
}

test "parseInfoJson ignores a field of the wrong type rather than failing" {
    const meta = try parseInfoJson(std.testing.allocator,
        \\{"title": 42, "author": "Someone"}
    );
    try std.testing.expectEqualStrings("", meta.title());
    try std.testing.expectEqualStrings("Someone", meta.author());
}

test "parseInfoJson rejects a document that isn't an object" {
    try std.testing.expectError(
        Error.NotAnNftBundle,
        parseInfoJson(std.testing.allocator, "[1,2,3]"),
    );
    try std.testing.expectError(
        Error.NotAnNftBundle,
        parseInfoJson(std.testing.allocator, "not json at all"),
    );
}

test "cardStemIndex prefers the front card and rejects everything else" {
    try std.testing.expectEqual(@as(?usize, 0), cardStemIndex("cardf.png"));
    try std.testing.expectEqual(@as(?usize, 0), cardStemIndex("cardf.WEBP"));
    try std.testing.expectEqual(@as(?usize, 1), cardStemIndex("public.mp4") orelse 1);
    try std.testing.expectEqual(@as(?usize, 1), cardStemIndex("public.jpg"));
    // The back card and owner-only media are not card art we unpack.
    try std.testing.expectEqual(@as(?usize, null), cardStemIndex("cardb.png"));
    try std.testing.expectEqual(@as(?usize, null), cardStemIndex("owner.png"));
    try std.testing.expectEqual(@as(?usize, null), cardStemIndex("info.json"));
    // A path that merely starts with a stem must not pass as card art.
    try std.testing.expectEqual(@as(?usize, null), cardStemIndex("cardf.png/../evil"));
}

test "toHex renders the digest the cache directory is named for" {
    var out: [8]u8 = undefined;
    toHex(&out, &[_]u8{ 0x03, 0x68, 0xe9, 0x93 });
    try std.testing.expectEqualStrings("0368e993", &out);
}
