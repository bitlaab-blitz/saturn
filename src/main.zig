const std = @import("std");
const linux = std.os.linux;

const saturn = @import("saturn");
const Signal = saturn.Signal;
const AsyncIo = saturn.AsyncIo(512);
const Executor = saturn.TaskExecutor(512);

// To kill one or more rouge processes run:
// sudo kill -9 "$(pidof saturn | awk '{print $1}')"


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

    // Write your code here...

    try AsyncIo.eventLoop(0, null);

    Signal.terminate(Executor);
}
