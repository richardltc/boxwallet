//! BoxWallet's own identity: the release version and brand colour that both
//! front-ends, the self-updater and the release assets all read.
//!
//! This lives apart from `app.zig` because `capi.zig` cannot import that:
//! `app.zig` pulls in ZigZag, and the GUI links the core as a static library
//! with no TUI in it. Before this module the GUI simply hardcoded the version
//! string in `app.slint`, which is exactly the kind of copy that goes stale one
//! release later and tells the user they're running something they aren't.

const std = @import("std");

/// The release version. **This is the constant to bump when cutting a release**
/// (see CLAUDE.md): `zig build release` names its assets from it and
/// `update.zig` compares against it, so the TUI's Home pane, the GUI's Home page
/// and the updater can't disagree about what's running.
pub const app_version = "0.8.14";

/// The brand hex used for the "BoxWallet" wording in both front-ends.
pub const brand_color = "#7ca071";

/// What each front-end calls itself. They differ deliberately — a bug report
/// reading "BoxWallet TUI v0.8.4" says which one it came from.
pub const tui_name = "BoxWallet TUI";
pub const gui_name = "BoxWallet";

test "the version is a plain dotted release number" {
    // The updater compares these lexically component-by-component and the release
    // step bakes them into asset names, so a stray "v" prefix or a trailing
    // "-dev" would silently break both.
    try std.testing.expect(app_version.len > 0);
    try std.testing.expect(app_version[0] >= '0' and app_version[0] <= '9');
    var dots: usize = 0;
    for (app_version) |ch| {
        if (ch == '.') {
            dots += 1;
            continue;
        }
        try std.testing.expect(ch >= '0' and ch <= '9');
    }
    try std.testing.expectEqual(@as(usize, 2), dots);
}

test "the brand colour is a full six-digit hex" {
    try std.testing.expectEqual(@as(usize, 7), brand_color.len);
    try std.testing.expectEqual(@as(u8, '#'), brand_color[0]);
    for (brand_color[1..]) |ch| {
        try std.testing.expect((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'));
    }
}
