//! # Thread Pool Module For CPU Bound Workloads
//! **Last Updated: 08 May 2025 - v1.0.0**
//! - Multi-producer and multi-consumer (MPMC) ring buffer
//! - Lock-free and wait-free task submission and completion
//! - Thread per core (logical) architecture with `N` number of workers
//! - Parallel task submission and execution with atomic CAS and memory ordering
//!
//! **Remarks:**
//! - Sequential execution of the submitted tasks are not guaranteed
//! - Tasks synchronization (if necessary) must be managed explicitly in the App
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
const testing = std.testing;

const Signal = @import("./signal.zig");

const queue = @import("./queue.zig");
const MPMC = queue.MPMC;


const Error = error { Overflow, Halting };

const Args = ?*anyopaque;
const Callback = *const fn(Args) void;
const Task = struct { handle: Callback, data: Args };

/// # Singleton Task Executor
/// - `capacity` - Must be the power of two e.g., `512`, `1024`, etc.
pub fn Executor(comptime capacity: u32) type {
    std.debug.assert(std.math.isPowerOfTwo(capacity));

    return struct {
        const SingletonObject = struct {
            queue: MPMC(capacity),
            worker: u16,
            heap: mem.Allocator,
            mutex: Thread.Mutex,
            condition: Thread.Condition

            // TODO:
            // var counter: usize align(std.atomic.cache_line) = 0;
            // To see if applying cache line gives any performance boost
        };

        var so: ?SingletonObject = null;
        var gpa: ?std.heap.DebugAllocator(.{}) = null;

        const Self = @This();

        /// # Initializes and Runs the Executor
        /// - `worker` - Threads count, uses available CPU cores when **null**.
        /// - `detect_mem_leaks` - When **true**, uses `DebugAllocator`.
        pub fn init(worker: ?u16, detect_mem_leaks: bool) !void {
            if (Self.so != null) @panic("Initialize Only Once Per Process!");

            const cpu_threads: u16 = @intCast(try Thread.getCpuCount());
            const threads = worker orelse cpu_threads;
            if (threads == 0) @panic("Need at Least One or More Workers!");

            const spot = detect_mem_leaks;
            if (spot) Self.gpa = heap.DebugAllocator(.{}).init;

            Self.so = .{
                .queue = MPMC(capacity).init(),
                .worker = threads,
                .heap = if (spot) Self.gpa.?.allocator() else heap.c_allocator,
                .mutex = Thread.Mutex{},
                .condition = Thread.Condition{}
            };

            try run();
        }

        /// # Destroys the Executor
        /// **Remarks:** `NOP` when `detect_mem_leaks` is **false**.
        pub fn deinit() void {
            if (Self.gpa) |_| std.debug.assert(Self.gpa.?.deinit() == .ok);
        }

        /// # Spawns the Worker Threads
        fn run() !void {
            const sop = Self.iso();
            for (0..sop.worker) |_| {
                const worker = try Thread.spawn(.{}, tick, .{});
                worker.detach();
            }

            log.info(
                "Executor is running on a [SQ-{d}] with {d} Threads!",
                .{capacity, sop.worker}
            );
        }

        /// # Consumes and executes a submitted task from the queue
        fn tick() void {
            var sop = Self.iso();

            while(true) {
                while (sop.queue.pop()) |data| {
                    const task: *Task = @ptrFromInt(data.entry);
                    task.handle(task.data); // Task dispatched!
                    sop.heap.destroy(task);
                }

                if (Signal.iso().signal > 0) {
                    // Participant response on exit
                    const participant = &Signal.iso().participant;
                    _ = @atomicRmw(i32, participant, .Add, 1, .monotonic);
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

        /// # Task On Queue
        pub fn submit(handle: Callback, data: Args) !void {
            var sop = Self.iso();
            if (Signal.iso().signal > 0) return Error.Halting;

            const task = try sop.heap.create(Task);
            task.* = Task {.handle = handle, .data = data};

            if (sop.queue.push(@intFromPtr(task))) |_| {
                sop.condition.signal();
                return;
            }

            return Error.Overflow;
        }
    };
}

test "SmokeTest" {
    // Use - zig test src/core/tpool.zig -lc

    try Signal.init();

    const TaskExecutor = Executor(8192);

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
        fn handle(payload: Args) void {
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
                TaskExecutor.submit(handle, @as(*anyopaque, op)) catch |err| {
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

    Signal.terminate(8);

    const result = @atomicLoad(usize, &p_counter.value, .acquire);
    try testing.expect(result == test_limit);

    // As of now (May 2025) only `log.warn` is allowed to print within test!
    log.warn("1M Task Took: {d}ms", .{p_counter.elapsed.? / time.ns_per_ms});
}
