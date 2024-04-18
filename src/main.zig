const std = @import("std");
const Interpreter = @import("Interpreter.zig").Interpreter;
const Lujo = @import("Lujo.zig");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var alloc = arena.allocator();

const GB = 1024 * 1024 * 1024;

pub fn main() !void {
    var stdout = std.io.getStdOut().writer();
    var stderr = std.io.getStdErr().writer();
    var args = try std.process.argsAlloc(alloc);

    if (args.len != 2) {
        try stdout.print("Usage: {s} file\n", .{args[0]});
        return;
    }

    const filePath = args[1];
    _ = Lujo.interpretFile(filePath) catch |err| switch (err) {
        error.FileTooBig => try stderr.print("File {s} is too big to open entirely in RAM\n", .{filePath}),
        error.InputOutput => try stderr.print("I/O error when opening file {s}\n", .{filePath}),
        error.AccessDenied => try stderr.print("Access denied. Cannot open file {s}\n", .{filePath}),
        error.FileNotFound => try stderr.print("File {s} not found\n", .{filePath}),
        error.IsDir => try stderr.print("File expected. {s} is a directory\n", .{filePath}),
        else => try stderr.print("Cannot open file {s}\n", .{filePath})
    };
}
