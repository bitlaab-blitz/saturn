const std = @import("std");
const linux = std.os.linux;

const utils = @import("./core/utils.zig");
const Signal = @import("./core/signal.zig");

const saturn = @import("saturn");
const Executor = saturn.TaskExecutor(512);

const uring = @import("./core/uring.zig");


pub fn main() !void {
    utils.targetPlatform(std.Target.Os.Tag.linux);
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    try Signal.init();
    Signal.Linux.signal(linux.SIG.INT, Signal.register);
    Signal.Linux.signal(linux.SIG.TERM, Signal.register);

    try uring.AsyncIo(512).init(true);


    try Executor(1024).init(2, true);

    try Executor(1024).submit(foo, null);

    std.time.sleep(std.time.ms_per_s);

    Signal.Linux.signalEmit(linux.SIG.TERM);
    Executor(1024).iso().condition.broadcast();

    std.time.sleep(std.time.ms_per_s);

    Signal.terminate(@as(i64, Executor(1024).iso().worker));
}

fn foo(args: ?*anyopaque) void {
    _ = args;
    std.debug.print("hello, world!\n", .{});
}