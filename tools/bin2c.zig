//! Build helper: emit a C header embedding a binary file as a byte array, so an
//! asset (here the monospace font TTF) is baked into the GUI binary with no
//! runtime file dependency.
//!
//! Usage: bin2c <input-file> <output.h>
//! Emits: static const unsigned char mono_font[] = { … };
//!        static const unsigned long mono_font_len = N;

const std = @import("std");
const Io = std.Io;

pub fn main(process: std.process.Init) !void {
    const gpa = process.gpa;
    const io = process.io;

    var args = std.process.Args.Iterator.init(process.minimal.args);
    _ = args.next(); // argv[0]
    const in_path = args.next() orelse return error.MissingInput;
    const out_path = args.next() orelse return error.MissingOutput;

    const dir = Io.Dir.cwd();
    const data = try dir.readFileAlloc(io, in_path, gpa, .unlimited);
    defer gpa.free(data);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try out.appendSlice(gpa, "static const unsigned char mono_font[] = {");
    for (data, 0..) |byte, i| {
        if (i % 20 == 0) try out.appendSlice(gpa, "\n");
        var tmp: [8]u8 = undefined;
        try out.appendSlice(gpa, try std.fmt.bufPrint(&tmp, "{d},", .{byte}));
    }
    try out.appendSlice(gpa, "\n};\nstatic const unsigned long mono_font_len = ");
    var tmp: [24]u8 = undefined;
    try out.appendSlice(gpa, try std.fmt.bufPrint(&tmp, "{d}", .{data.len}));
    try out.appendSlice(gpa, ";\n");

    try dir.writeFile(io, .{ .sub_path = out_path, .data = out.items });
}
