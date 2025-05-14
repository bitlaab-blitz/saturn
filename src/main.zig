const std = @import("std");
const linux = std.os.linux;

const tpool = @import("./core/tpool.zig");
const Executor = tpool.Executor;

const Signal = @import("./core/signal.zig");

pub fn main() !void {
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    try Signal.init();
    Signal.Linux.signal(linux.SIG.INT, Signal.register);
    Signal.Linux.signal(linux.SIG.TERM, Signal.register);


    try Executor(1024).init(null);

    try Executor(1024).submit(foo, null);
}

fn foo(args: ?*anyopaque) void {
    _ = args;
    std.debug.print("hello, world!\n", .{});
}