const std = @import("std");
const linux = std.os.linux;

const saturn = @import("saturn");
const Signal = saturn.Signal;
const AsyncIo = saturn.AsyncIo(512);
const Executor = saturn.TaskExecutor(512);


pub fn main() !void {
    var gpa_mem = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa_mem.deinit() == .ok);
    // const heap = gpa_mem.allocator();

    try Signal.init();
    Signal.Linux.signal(linux.SIG.INT, Signal.register);
    Signal.Linux.signal(linux.SIG.TERM, Signal.register);

    try Executor.init(null, true);
    defer Executor.deinit();

    try AsyncIo.init(true);
    defer AsyncIo.deinit();


    try AsyncIo.timeout(res, null, .{
        .ts = linux.timespec {.sec = 5, .nsec = 0}
    });

    try AsyncIo.eventLoop();

    Executor.iso().condition.broadcast();
    Signal.terminate(@as(i64, Executor.iso().worker));
}

fn res(cqe_res: i32, userdata: ?*anyopaque) void {
    _ = userdata;
    std.debug.print("res: {}\n", .{cqe_res});
}
