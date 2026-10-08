//! # Thread Pool Module For CPU Bound Workloads - v1.4.0
//! - Multi-producer and multi-consumer (MPMC) ring buffer
//! - Allocation-free task submission and completion: the `Task` itself travels
//!   inside the queue slot (no cell pool, no free list, no pointer chase)
//! - Thread per core (logical) architecture with `N` number of workers
//! - Spin-then-park workers with a lost-wakeup-free sleep protocol
//!
//! **Remarks:** on task execution:
//! - Sequential execution of the submitted tasks are not guaranteed
//! - Tasks synchronization (if necessary) must be managed explicitly by the App
//! - Needs `queue.zig` v2.1.0 (`MPMCOf`); public API is unchanged from v1.3.0
//!   and `wakeAll()` is the only addition
//!
//! **Remarks:** on the hot path (v1.4.0):
//! - `submit` = 1 `pending_ios` RMW + 1 slot push (the task is written straight
//!   into the slot, so ONE cache line moves producer -> worker per task instead
//!   of the queue slot + task cell + two free-list slots of v1.3.0)
//! - A worker never touches the mutex/condition while there is work or while
//!   it is still spinning; wake-ups are only issued when a worker is parked
//! - Memory: `capacity` slots only (v1.3.0 also kept `capacity` free-list slots
//!   plus `capacity` cache-line padded task cells)
//! - Every cross-thread word of the singleton owns its cache line(s): the
//!   producers' `queue` cursors, `pending_ios`, `sleepers`, the park
//!   `mutex`/`condition`, and the read-mostly `io`/`heap`/`worker`
//!
//! **Remarks:** on shutdown (`Signal`):
//! - After the signal is set, `submit` returns `Error.Draining`
//! - Workers drain every task that was accepted, then bump `participant`
//! - Whoever sets the signal must wake the parked workers afterwards. Call
//!   `wakeAll()` for this (`Signal.terminate` should): it broadcasts WHILE
//!   HOLDING the park mutex, which is what makes the wake-up impossible to lose
//!   (a bare `iso().condition.broadcast()` can slip between a worker's last
//!   `draining()` check and its `wait` and leave that worker parked forever)

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const log = std.log;
const heap = std.heap;
const atomic = std.atomic;
const Thread = std.Thread;
const process = std.process;
const testing = std.testing;

const Signal = @import("./signal.zig");

const queue = @import("./queue.zig");
const MPMCOf = queue.MPMCOf;


pub const Error = error { Overflow, Draining };

pub const Callback = union(enum) {
    cpu: *const fn(?*anyopaque) void,
    aio: *const fn(i32, ?*anyopaque) void
};

pub const Task = struct { handle: Callback, data: ?*anyopaque, cqe: ?i32 };

/// - Idle spins (with a CPU pause) before a worker parks on the condition.
const spin_limit: u32 = 256;

/// - Retries for *transient* full answers of the lock-free queue.
/// - A peer that claimed a ticket but has not published it yet makes the queue
///   look full for a few instructions; this rides that window out.
const retry_limit: u32 = 32;

/// # Singleton Task Executor
/// - `capacity` - Must be the power of two e.g., `512`, `1024`, etc.
///
/// **Remarks:** Capacity is the max number of tasks that can be queued at once.
pub fn Executor(comptime capacity: u32) type {
    comptime std.debug.assert(std.math.isPowerOfTwo(capacity));

    return struct {
        const Queue = MPMCOf(Task, capacity);
        const line = atomic.cache_line;

        /// - Zig lays small fields out right behind the previous (even aligned)
        ///   field, so an `align(cache_line)` on a 4-byte counter does NOT keep
        ///   its neighbours off that line. Therefore EVERY field is aligned:
        ///   each one starts on its own line, and no two ever share one.
        const SingletonObject = struct {
            /// - Cursors + ring of the queue (aligned internally, size is a
            ///   multiple of the line)
            queue: Queue align(line),
            /// - Tasks submitted but not yet picked up by a worker. Always
            ///   incremented BEFORE the task is published, so `0` really means
            ///   "nothing queued and nothing in flight".
            pending_ios: u32 align(line),
            /// - Number of workers parked (or about to park) on `condition`
            sleepers: u32 align(line),

            // - Park/wake machinery - written only when workers park or wake
            mutex: Io.Mutex align(line),
            condition: Io.Condition align(line),

            // - Read-mostly after init
            io: Io align(line),
            heap: mem.Allocator align(line),
            worker: u16 align(line),
        };

        var so: ?SingletonObject = null;
        var gpa: ?std.heap.DebugAllocator(.{}) = null;

        const Self = @This();

        /// # Initializes and Runs the Executor
        /// - `worker` - Threads count, uses available CPU cores when **null**.
        /// - `detect_mem_leaks` - When **true**, uses `DebugAllocator`.
        pub fn init(io: Io, worker: ?u16, detect_mem_leaks: bool) !void {
            if (Self.so != null) @panic("Initialize Only Once Per Process!");

            // Ignores `USR1` - AsyncIo emits this for I/O submission
            var sig = [_]std.os.linux.SIG{std.os.linux.SIG.USR1};
            _ = Signal.Linux.signalMask(&sig);

            const cpu_threads: u16 = @intCast(try Thread.getCpuCount());
            const threads = worker orelse cpu_threads;
            if (threads == 0) @panic("Need at Least One or More Workers!");

            const spot = detect_mem_leaks;
            if (spot) Self.gpa = heap.DebugAllocator(.{}).init;

            Self.so = .{
                .queue = Queue.init(),
                .pending_ios = 0,
                .sleepers = 0,
                .mutex = .init,
                .condition = .init,
                .io = io,
                .heap = if (spot) Self.gpa.?.allocator() else heap.c_allocator,
                .worker = threads,
            };

            try run();
        }

        /// # Destroys the Executor
        /// **Remarks:** Call only once after all workers have exited.
        pub fn deinit() void {
            if (Self.gpa) |_| {
                switch (Self.gpa.?.deinit()) {
                    .leak => process.exit(1), .ok => {}, // NO-OP
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

        /// - True once a termination signal has been recorded
        inline fn draining() bool {
            // Volatile read: the signal is written from outside this module
            const sig: *const volatile @TypeOf(Signal.iso().signal) = &Signal.iso().signal;
            return sig.* != null;
        }

        /// - Every 64th round yields so a preempted peer can finish
        inline fn relax(round: u32) void {
            if (round & 63 == 63) Thread.yield() catch {} else atomic.spinLoopHint();
        }

        /// - Undoes the effects of a submit that did not publish its task
        inline fn abort(sop: *SingletonObject) void {
            _ = @atomicRmw(u32, &sop.pending_ios, .Sub, 1, .release);
        }

        /// - Wakes one parked worker. Taking the mutex guarantees the worker is
        ///   already inside `wait` (it holds the mutex from announcing itself
        ///   until `wait` releases it), so the signal cannot be lost.
        fn wake(sop: *SingletonObject) void {
            sop.mutex.lockUncancelable(sop.io);
            sop.condition.signal(sop.io);
            sop.mutex.unlock(sop.io);
        }

        /// # Wakes Every Parked Worker
        /// - Call this right after the termination signal has been set, so
        ///   that parked workers notice it, drain and exit.
        /// - Broadcasts under the park mutex: a worker that is between its last
        ///   `draining()` check and its `wait` still holds that mutex, so this
        ///   call blocks until it is really waiting; the wake-up can't be lost.
        pub fn wakeAll() void {
            const sop = Self.iso();
            sop.mutex.lockUncancelable(sop.io);
            sop.condition.broadcast(sop.io);
            sop.mutex.unlock(sop.io);
        }

        /// - Parks the calling worker until woken. Safe against lost wake-ups:
        ///   the worker announces itself (`sleepers`), then re-checks
        ///   `pending_ios`; a producer bumps `pending_ios`, then checks
        ///   `sleepers`. With all four accesses sequentially consistent, at
        ///   least one side is guaranteed to see the other.
        fn park(sop: *SingletonObject) void {
            sop.mutex.lockUncancelable(sop.io);

            _ = @atomicRmw(u32, &sop.sleepers, .Add, 1, .seq_cst);
            if (@atomicLoad(u32, &sop.pending_ios, .seq_cst) == 0 and !draining()) {
                sop.condition.waitUncancelable(sop.io, &sop.mutex);
            }
            _ = @atomicRmw(u32, &sop.sleepers, .Sub, 1, .monotonic);

            sop.mutex.unlock(sop.io);
        }

        /// - Runs one task
        inline fn execute(task: Task) void {
            switch (task.handle) {
                .cpu => |handle| handle(task.data),
                .aio => |handle| handle(task.cqe orelse 0, task.data),
            }
        }

        /// # Consumes and Executes Submitted Tasks from the Queue
        fn tick() void {
            const sop = Self.iso();

            var spins: u32 = 0; // idle spins before parking
            var round: u32 = 0; // waiting for an in-flight task

            while (true) {
                if (sop.queue.pop()) |data| {
                    spins = 0;
                    round = 0;
                    _ = @atomicRmw(u32, &sop.pending_ios, .Sub, 1, .release);
                    // The slot was already handed back to producers by `pop`,
                    // so a callback may itself call `submit` freely
                    execute(data.entry);
                    continue;
                }

                // A task is announced but not visible yet (its producer is
                // between "announce" and "publish"): never sleep on that.
                if (@atomicLoad(u32, &sop.pending_ios, .acquire) != 0) {
                    relax(round);
                    round +%= 1;
                    continue;
                }

                if (draining()) {
                    // Participant response on exit (queue is drained)
                    const participant = &Signal.iso().participant;
                    _ = @atomicRmw(i32, participant, .Add, 1, .release);
                    return;
                }

                // Nothing to do (idle period): spin first, then park
                if (spins < spin_limit) {
                    spins += 1;
                    atomic.spinLoopHint();
                    continue;
                }

                park(sop);
                spins = 0;
            }
        }

        /// # Returns Internal Static Object
        pub fn iso() *SingletonObject { return &Self.so.?; }

        /// # Submits a New Task on Queue
        /// - `cb` - Either `.{.aio = handle}` or `.{.cpu = handle}`
        /// - `cqe` - Return value of the CQE or userdata if needed!
        pub fn submit(cb: Callback, data: ?*anyopaque, cqe: ?i32) !void {
            const sop = Self.iso();
            if (draining()) return Error.Draining;

            // 1. Announce BEFORE publishing so no worker parks while this
            // task is in flight (see `park`)
            _ = @atomicRmw(u32, &sop.pending_ios, .Add, 1, .seq_cst);

            // Shutdown raced with us: nothing has been published yet
            if (draining()) {
                abort(sop);
                return Error.Draining;
            }

            // 2. Publish - the task is copied straight into its queue slot
            const task: Task = .{ .handle = cb, .data = data, .cqe = cqe };
            var tries: u32 = 0;
            while (sop.queue.push(task) == null) {
                tries += 1;
                if (tries >= retry_limit) {
                    abort(sop);
                    return Error.Overflow;
                }
                atomic.spinLoopHint();
            }

            // 3. Wake a parked worker, only when one exists
            if (@atomicLoad(u32, &sop.sleepers, .seq_cst) != 0) wake(sop);
        }
    };
}

test "layout: every field of the singleton owns its cache line(s)" {
    const S = Executor(64).SingletonObject;
    const cl = atomic.cache_line;
    const names = .{ "queue", "pending_ios", "sleepers", "mutex", "condition", "io", "heap", "worker" };

    inline for (names, 0..) |a, i| {
        const a_first = @offsetOf(S, a) / cl;
        const a_last = (@offsetOf(S, a) + @sizeOf(@FieldType(S, a)) - 1) / cl;
        inline for (names, 0..) |b, j| {
            if (i < j) {
                const b_first = @offsetOf(S, b) / cl;
                const b_last = (@offsetOf(S, b) + @sizeOf(@FieldType(S, b)) - 1) / cl;
                // line ranges must be disjoint: no false sharing between a and b
                try testing.expect(a_last < b_first or b_last < a_first);
            }
        }
    }
}

test "SmokeTest" {
    // Use - zig test src/core/tpool.zig -lc

    try Signal.init();

    // Use - `Executor(4096 * 4)`, when `TaskExecutor.init()` is false;
    const TaskExecutor = Executor(4096);

    // Test Data Structure
    const Counter = struct { value: usize = 0 };

    const test_limit = 1_000_000;
    const producers = 4;

    const Job = struct {
        fn handle(payload: ?*anyopaque) void {
            const d: *Counter = @ptrCast(@alignCast(payload));
            _ = @atomicRmw(usize, &d.value, .Add, 1, .release);
        }

        fn submit(op: *Counter) void {
            for (0..test_limit / producers) |_| {
                const args = @as(?*anyopaque, op);
                const task_handle: Callback = .{.cpu = handle};

                while (true) {
                    TaskExecutor.submit(task_handle, args, null) catch |err| switch (err) {
                        // Queue is full: back off and retry, never drop a task
                        error.Overflow => { Thread.yield() catch {}; continue; },
                        else => { log.warn("{s}", .{@errorName(err)}); return; },
                    };
                    break;
                }
            }
        }
    };

    // Runs one million highly parallel tasks

    try TaskExecutor.init(testing.io, 8, true);
    defer TaskExecutor.deinit();

    const alloc = testing.allocator;
    const p_counter: *Counter = try alloc.create(Counter);
    defer alloc.destroy(p_counter);

    p_counter.* = .{};

    const start = Io.Clock.awake.now(testing.io);

    var threads: [producers]Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try Thread.spawn(.{}, Job.submit, .{p_counter});
    }
    for (threads) |thread| thread.join();

    // Waits for the job completion
    while (@atomicLoad(usize, &p_counter.value, .acquire) < test_limit) {
        Thread.yield() catch {};
    }

    const stop = Io.Clock.awake.now(testing.io);

    // Assumes `Signal.iso().signal` is `?std.os.linux.SIG`
    Signal.iso().signal = std.os.linux.SIG.TERM; // Mimics SIGTERM signal
    try Signal.terminate(testing.io, TaskExecutor);

    const result = @atomicLoad(usize, &p_counter.value, .acquire);
    try testing.expect(result == test_limit);

    // As of now (May 2025) only `log.warn` is allowed to print within test!
    log.warn("1M Task Took: {d}ms", .{stop.toMilliseconds() - start.toMilliseconds()});
}