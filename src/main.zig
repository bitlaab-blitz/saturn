const std = @import("std");
const linux = std.os.linux;

const saturn = @import("saturn");
const Signal = saturn.Signal;
const AsyncIo = saturn.AsyncIo(512);
const Executor = saturn.TaskExecutor(512);


pub fn main() !void {
    try Signal.init();
    Signal.Linux.signal(linux.SIG.INT, Signal.register);
    Signal.Linux.signal(linux.SIG.TERM, Signal.register);

    var gpa_mem = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa_mem.deinit() == .ok);
    const heap = gpa_mem.allocator();


    try Executor.init(null, true);
    defer Executor.deinit();

    try AsyncIo.init(true);
    defer AsyncIo.deinit();

    const todo = try std.fs.cwd().openFile("./TODO.md", .{});
    const buff = try heap.alloc(u8, 1024);
    defer heap.free(buff);

    try AsyncIo.read(res, null, .{
        .fd = todo.handle, .buff = buff, .count = 1024, .offset = 0
    });


    try AsyncIo.eventLoop();

    Executor.iso().condition.broadcast();
    Signal.terminate(@as(i64, Executor.iso().worker));
}

fn res(cqe_res: i32, userdata: ?*anyopaque) void {
    _ = userdata;
    std.debug.print("res: {}\n", .{cqe_res});
}
