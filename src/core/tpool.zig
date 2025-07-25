//! # Thread Pool Module For CPU Bound Workloads - v1.2.0
//! - Multi-producer and multi-consumer (MPMC) ring buffer
//! - Lock-free and wait-free task submission and completion
//! - Thread per core (logical) architecture with `N` number of workers
//! - Parallel task submission and execution with atomic CAS and memory ordering
//!
//! **Remarks:** on task execution:
//! - Sequential execution of the submitted tasks are not guaranteed
//! - Tasks synchronization (if necessary) must be managed explicitly by the App
//! - See - https://internalpointers.com/post/gentle-introduction-multithreading
//! - See - https://youtube.com/watch?v=RWCadBJ6wTk
//! - See - https://youtube.com/watch?v=A8eCGOqgvH4
//! - See - https://youtube.com/watch?v=HP2InVqgBFM

const std = @import("std");
const mem = std.mem;
const log = std.log;
const heap = std.heap;
const time = std.time;
const Thread = std.Thread;
const process = std.process;
const testing = std.testing;

const Signal = @import("./signal.zig");

const queue = @import("./queue.zig");
const MPMC = queue.MPMC;


const Error = error { Overflow, Draining };

const Callback = union(enum) {
    cpu: *const fn(?*anyopaque) void,
    aio: *const fn(i32, ?*anyopaque) void
};

const Task = struct { handle: Callback, data: ?*anyopaque, cqe: ?i32 };

/// # Singleton Task Executor
/// - `capacity` - Must be the power of two e.g., `512`, `1024`, etc.
pub fn Executor(comptime capacity: u32) type {
    std.debug.assert(std.math.isPowerOfTwo(capacity));

    return struct {
        const SingletonObject = struct {
            queue: MPMC(capacity),
            worker: u16,
            pending_ios: u32,
            heap: mem.Allocator,
            mutex: Thread.Mutex,
            condition: Thread.Condition

            // TODO:
            // e.g., var counter: usize align(std.atomic.cache_line) = 0;
            // To see if applying cache line gives any performance boost!
        };

        var so: ?SingletonObject = null;
        var gpa: ?std.heap.DebugAllocator(.{}) = null;

        const Self = @This();

        /// # Initializes and Runs the Executor
        /// - `worker` - Threads count, uses available CPU cores when **null**.
        /// - `detect_mem_leaks` - When **true**, uses `DebugAllocator`.
        pub fn init(worker: ?u16, detect_mem_leaks: bool) !void {
            if (Self.so != null) @panic("Initialize Only Once Per Process!");

            // Ignores `USR1` - AsyncIo emits this for I/O submission
            var sig = [_]u6{std.os.linux.SIG.USR1};
            _ = Signal.Linux.signalMask(&sig);

            const cpu_threads: u16 = @intCast(try Thread.getCpuCount());
            const threads = worker orelse cpu_threads;
            if (threads == 0) @panic("Need at Least One or More Workers!");

            const spot = detect_mem_leaks;
            if (spot) Self.gpa = heap.DebugAllocator(.{}).init;

            Self.so = .{
                .queue = MPMC(capacity).init(),
                .worker = threads,
                .pending_ios = 0,
                .heap = if (spot) Self.gpa.?.allocator() else heap.c_allocator,
                .mutex = Thread.Mutex{},
                .condition = Thread.Condition{}
            };

            try run();
        }

        /// # Destroys the Executor
        /// **Remarks:** `NOP` when `detect_mem_leaks` is **false**.
        pub fn deinit() void {
            if (Self.gpa) |_| {
                switch (Self.gpa.?.deinit()) {
                    .leak => process.exit(1), .ok => {}, // NOP
                }
            }
        }

        /// # Spawns the Worker Threads
        fn run() !void {
            const sop = Self.iso();
            for (0..sop.worker) |_| {
                const worker = try Thread.spawn(.{}, tick, .{});
                worker.detach();
            }

            log.info(
                "Executor is running on [SQ-{d}] with {d} Threads",
                .{capacity, sop.worker}
            );
        }

        /// # Consumes and Executes a Submitted Task from the Queue
        fn tick() void {
            var sop = Self.iso();
            const ORD = .monotonic;

            while(true) {
                while (sop.queue.pop()) |data| {
                    const task: *Task = @ptrFromInt(data.entry);

                    // Dynamic task dispatch
                    if (task.cqe) |cqe| task.handle.aio(cqe, task.data)
                    else task.handle.cpu(task.data);

                    sop.heap.destroy(task);

                    const ios = &sop.pending_ios;
                    if (@atomicRmw(u32, ios, .Sub, 1, ORD) <= 1) break;
                }

                if (Signal.iso().signal > 0) {
                    // Participant response on exit
                    const participant = &Signal.iso().participant;
                    _ = @atomicRmw(i32, participant, .Add, 1, ORD);
                    break;
                }

                // Nothing to do (idle period)
                sop.mutex.lock();
                sop.condition.wait(&sop.mutex);
                sop.mutex.unlock();
            }
        }

        /// # Returns Internal Static Object
        pub fn iso() *SingletonObject { return &Self.so.?; }

        /// # Submits a New Task on Queue
        /// - `cb` - Either `.{.aio = handle}` or `.{.cpu = handle}`
        /// - `cqe` - Return value of the CQE or userdata if needed!
        pub fn submit(cb: Callback, data: ?*anyopaque, cqe: ?i32) !void {
            var sop = Self.iso();
            if (Signal.iso().signal > 0) return Error.Draining;

            const task = try sop.heap.create(Task);
            if (cqe) |v| task.* = .{.handle = cb, .data = data, .cqe = v}
            else task.* = .{.handle = cb, .data = data, .cqe = null};

            if (sop.queue.push(@intFromPtr(task))) |_| {
                _ = @atomicRmw(u32, &sop.pending_ios, .Sub, 1, .monotonic);
                sop.condition.signal();
                return;
            }

            sop.heap.destroy(task);
            return Error.Overflow;
        }
    };
}

test "SmokeTest" {
    // Use - zig test src/core/tpool.zig -lc

    try Signal.init();

    // Use - `Executor(4096 * 4)`, when `TaskExecutor.init()` is false;
    const TaskExecutor = Executor(4096);

    // Test Data Structure
    const Counter = struct {
        value: usize,
        bench: time.Timer,
        elapsed: ?usize = null,
        mutex: Thread.Mutex = Thread.Mutex{},
        condition: Thread.Condition = Thread.Condition{},
    };

    const test_limit = 1_000_000;

    const Job = struct {
        fn handle(payload: ?*anyopaque) void {
            const d: *Counter = @ptrCast(@alignCast(payload));
            const value = @atomicRmw(usize, &d.value, .Add, 1, .release);

            if (value + 1 >= test_limit) {
                // Asserts that the worker threads are synchronized!
                testing.expect(d.elapsed == null) catch unreachable;
                d.elapsed = d.bench.lap();
                Signal.iso().signal = 15; // Mimics SIGTERM signal
                d.condition.broadcast();
            }
        }

        fn submit(op: *Counter) void {
            for (0..250_000) |_| {
                const args = @as(?*anyopaque, op);
                const task_handle: Callback = .{.cpu = handle};
                TaskExecutor.submit(task_handle, args, null) catch |err| {
                    log.warn("{s}", .{@errorName(err)});
                };
            }
        }
    };

    // Runs one million highly parallel tasks

    try TaskExecutor.init(8, true);
    defer TaskExecutor.deinit();

    const alloc = testing.allocator;
    const p_counter: *Counter = try alloc.create(Counter);
    defer alloc.destroy(p_counter);

    p_counter.* = .{.value = 0, .bench = try time.Timer.start()};

    for (0..4) |_| {
        const thread = try Thread.spawn(.{}, Job.submit, .{p_counter});
        thread.detach();
    }

    // Waits for the job completion
    p_counter.mutex.lock();
    p_counter.condition.wait(&p_counter.mutex);
    p_counter.mutex.unlock();

    Signal.terminate(TaskExecutor);

    const result = @atomicLoad(usize, &p_counter.value, .acquire);
    try testing.expect(result == test_limit);

    // As of now (May 2025) only `log.warn` is allowed to print within test!
    log.warn("1M Task Took: {d}ms", .{p_counter.elapsed.? / time.ns_per_ms});
}
