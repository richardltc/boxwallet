//! Mnemonic-seed handling shared by both front-ends: counting and indexing the
//! words, and picking the positions for the backup quiz.
//!
//! The quiz is the check standing between someone and a mis-transcribed
//! mnemonic. It is the last moment a wrong word can be caught, and after that
//! the funds are gone with no recourse — so both front-ends must ask it the same
//! way. They didn't: the GUI carried its own C++ `countWords`, its own word
//! lookup, and picked the positions from `std::mt19937` seeded by
//! `std::random_device`, while the TUI used the OS CSPRNG.
//!
//! Nothing here allocates or holds a seed. Callers own the words and are
//! responsible for wiping them (`@memset(..., 0)`) — see the secrets contract at
//! the foot of `include/boxwallet.h`. These functions only *read* the string they
//! are handed, so a caller can pass a bounded buffer and wipe it afterwards
//! without anything having escaped.

const std = @import("std");

/// How many positions the backup quiz asks about.
pub const verify_positions = 3;

/// Count whitespace-separated tokens in `s` — the live word count shown under a
/// seed-entry field, so the user can see how many of the expected words they've
/// entered without counting by hand.
pub fn countWords(s: []const u8) usize {
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

/// The `n`-th (1-based) whitespace-separated word of `s`, or "" if out of range.
/// Renders the numbered seed, and checks the backup-verification answers.
pub fn nthWord(s: []const u8, n: usize) []const u8 {
    if (n == 0) return "";
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
    var i: usize = 0;
    while (it.next()) |word| {
        i += 1;
        if (i == n) return word;
    }
    return "";
}

/// Whether `answer` is the word at 1-based `pos` of `words`, ignoring
/// surrounding whitespace and case.
///
/// Case-insensitive because BIP39-style wordlists are lowercase but people type
/// with a capital, and rejecting "Abandon" for "abandon" would fail someone who
/// copied their seed down correctly. The comparison reads both strings in place,
/// so nothing is copied and there is nothing to wipe.
pub fn wordMatches(words: []const u8, pos: usize, answer: []const u8) bool {
    const want = nthWord(words, pos);
    if (want.len == 0) return false;
    const got = std.mem.trim(u8, answer, " \t\r\n");
    if (got.len != want.len) return false;
    return std.ascii.eqlIgnoreCase(want, got);
}

/// Pick up to `verify_positions` distinct 1-based positions in `[1, word_count]`
/// for the backup quiz, written into `out` and returned by count (fewer than
/// three only for an unusually short seed). Returns 0 when there are no words.
///
/// Bytes come from `io.random` — the OS CSPRNG, as `conf.randomPassword` uses.
/// The choice isn't security-sensitive, but there's no reason to make it
/// predictable, and a userspace PRNG seeded from the clock certainly is.
pub fn pickVerifyPositions(io: std.Io, word_count: usize, out: *[verify_positions]usize) usize {
    if (word_count == 0) return 0;
    const want = @min(@as(usize, verify_positions), word_count);
    var n: usize = 0;
    while (n < want) {
        var b: [1]u8 = undefined;
        io.random(&b);
        const pos = @as(usize, b[0] % word_count) + 1; // 1..word_count
        var dup = false;
        for (out[0..n]) |p| {
            if (p == pos) dup = true;
        }
        if (!dup) {
            out[n] = pos;
            n += 1;
        }
    }
    return n;
}

/// Whether `n` is one of this wallet's valid restore-seed word counts (drives a
/// seed-entry counter's "looks right" state).
pub fn countAccepted(counts: []const usize, n: usize) bool {
    for (counts) |c| if (c == n) return true;
    return false;
}

/// Render the valid seed word counts as "a, b or c" (canonical first) into
/// `buf`, for a seed-entry prompt. Callers pass a `[64]u8`.
pub fn joinCounts(buf: []u8, counts: []const usize) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    for (counts, 0..) |c, i| {
        if (i != 0) w.writeAll(if (i == counts.len - 1) " or " else ", ") catch return w.buffered();
        w.print("{d}", .{c}) catch return w.buffered();
    }
    return w.buffered();
}

test "countWords and nthWord agree on the same tokenization" {
    const words = "alpha bravo charlie delta";
    try std.testing.expectEqual(@as(usize, 4), countWords(words));
    try std.testing.expectEqualStrings("alpha", nthWord(words, 1));
    try std.testing.expectEqualStrings("delta", nthWord(words, 4));
    // Out of range, both ends.
    try std.testing.expectEqualStrings("", nthWord(words, 0));
    try std.testing.expectEqualStrings("", nthWord(words, 5));

    // A pasted seed with ragged whitespace still counts and indexes correctly —
    // this is how a seed arrives when someone copies it out of a document.
    const ragged = "  alpha\tbravo \n charlie  ";
    try std.testing.expectEqual(@as(usize, 3), countWords(ragged));
    try std.testing.expectEqualStrings("charlie", nthWord(ragged, 3));
    try std.testing.expectEqual(@as(usize, 0), countWords("   "));
}

test "wordMatches accepts the right word regardless of case or padding" {
    const words = "abandon ability able about";
    try std.testing.expect(wordMatches(words, 2, "ability"));
    // Typed with a capital, or with the whitespace a paste drags along.
    try std.testing.expect(wordMatches(words, 2, "Ability"));
    try std.testing.expect(wordMatches(words, 2, "  ability  "));
    // Wrong word, wrong position, and a prefix that must not pass.
    try std.testing.expect(!wordMatches(words, 2, "able"));
    try std.testing.expect(!wordMatches(words, 3, "ability"));
    try std.testing.expect(!wordMatches(words, 2, "abilit"));
    try std.testing.expect(!wordMatches(words, 2, ""));
    // Out of range never matches, however plausible the answer looks.
    try std.testing.expect(!wordMatches(words, 9, "abandon"));
    try std.testing.expect(!wordMatches("", 1, ""));
}

test "the quiz picks distinct in-range positions, and copes with a short seed" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var out: [verify_positions]usize = undefined;
    // Repeated, because the distinctness bug this guards against is a collision
    // that only shows up on some draws.
    var round: usize = 0;
    while (round < 200) : (round += 1) {
        const n = pickVerifyPositions(io, 25, &out);
        try std.testing.expectEqual(@as(usize, 3), n);
        for (out[0..n]) |p| {
            try std.testing.expect(p >= 1 and p <= 25);
        }
        try std.testing.expect(out[0] != out[1]);
        try std.testing.expect(out[0] != out[2]);
        try std.testing.expect(out[1] != out[2]);
    }

    // A seed shorter than the quiz asks about yields fewer positions rather than
    // looping forever looking for a third distinct one.
    try std.testing.expectEqual(@as(usize, 2), pickVerifyPositions(io, 2, &out));
    try std.testing.expectEqual(@as(usize, 1), pickVerifyPositions(io, 1, &out));
    try std.testing.expectEqual(@as(usize, 0), pickVerifyPositions(io, 0, &out));
}

test "countAccepted and joinCounts describe a wallet's accepted lengths" {
    try std.testing.expect(countAccepted(&.{25}, 25));
    try std.testing.expect(!countAccepted(&.{25}, 24));
    try std.testing.expect(countAccepted(&.{ 15, 12, 24 }, 12));

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("25", joinCounts(&buf, &.{25}));
    try std.testing.expectEqualStrings("15 or 12", joinCounts(&buf, &.{ 15, 12 }));
    try std.testing.expectEqualStrings("15, 12 or 24", joinCounts(&buf, &.{ 15, 12, 24 }));
}
