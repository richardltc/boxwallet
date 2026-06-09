const std = @import("std");
const zz = @import("zigzag");
const App = @import("app.zig").App;

/// Entry point for the BoxWallet Nexa TUI slice.
///
/// 0.16 hands `main` a `std.process.Init` carrying the allocator, io, and
/// environment — exactly what ZigZag's `Program` needs.
pub fn main(init: std.process.Init) !void {
    var program = try zz.Program(App).init(init.gpa, init.io, init.environ_map);
    defer program.deinit();
    try program.run();
}

// Offline unit tests live in the backend modules (no daemon, no TUI needed).
test {
    std.testing.refAllDecls(@This());
    _ = @import("rpc.zig");
    _ = @import("install.zig");
    _ = @import("disk.zig");
    _ = @import("memory.zig");
    _ = @import("conf.zig");
    _ = @import("coins/nexa.zig");
    _ = @import("coins/divi.zig");
    _ = @import("coins/ergo.zig");
    _ = @import("app.zig");
}
