//! # Asynchronous I/O Module
//! - Provides a set of API on top of Linux's `oi_uring` kernel interface
//! - See - https://kernel.dk/io_uring.pdf
//! - See - https://kernel.dk/axboe-kr2022.pdf
//! - See - https://github.com/axboe/liburing/blob/master/src/include/liburing.h
//!
//! **Remarks:**
//! - IO Uring is designed as a single-threaded SPSC ring buffer
//! - Any thread synchronization must be managed explicitly by the App
//! - We use `MPSC` queue wrapper for multi-threaded I/O submission to `SQE`
//! - I/O completion `CQE` is done by the kernel and consumed by our ↻ EventLoop

const std = @import("std");
const mem = std.mem;
const log = std.log;
const debug = std.debug;
const posix = std.posix;
const Statx = linux.Statx;
const linux = std.os.linux;
const SemVer = std.SemanticVersion;
const SigInfo = linux.signalfd_siginfo;

const builtin = @import("builtin");

const utils = @import("./utils.zig");
const Signal = @import("./signal.zig");

const queue = @import("./queue.zig");
const MPSC = queue.MPSC;


const Error = error { Overflow, Closed };

const EventLoopStatus = enum { inactive, running, closing, closed };

/// # I/O SQE Operation Modes
/// - See section [5.1] and [5.2] on - https://kernel.dk/io_uring.pdf
const Mode = enum(u8) {
    /// Waits for previous SQEs to be complete (A ← B ← C)
    io_drain = linux.IOSQE_IO_DRAIN,
    /// Chains subsequent SQEs together (A → B → C)
    io_link = linux.IOSQE_IO_LINK,
    /// Runs SQEs independent of each other (A | B | C)
    io_async = linux.IOSQE_ASYNC
};

const Any = ?*anyopaque;
const ExitCallback = *const fn() void;

//##############################################################################
//# HIGH LEVEL ASYNCHRONOUS I/O INTERFACE -------------------------------------#
//##############################################################################

/// # Singleton Asynchronous I/O Executor
/// - `capacity` - Must be the power of two e.g., `512`, `1024`, etc.
pub fn AsyncIo(comptime capacity: u32) type {
    debug.assert(std.math.isPowerOfTwo(capacity));

    return struct {
        const SingletonObject = struct {
            flags: u32,
            ring_fd: usize,
            sqes: [*]IoUringSqe,
            cqes: [*]IoUringCqe,
            sq_ring: struct {
                tail: *u32,
                mask: *u32,
                flags: *u32,
                array: [*]u32
            },
            cq_ring: struct {
                head: *u32,
                tail: *u32,
                mask: *u32
            },
            sfd: i32,
            status: EventLoopStatus,
            heap: mem.Allocator,
            queue: MPSC(capacity),
            ongoing_ios: u32 = 0
        };

        var so: ?SingletonObject = null;
        var gpa: ?std.heap.DebugAllocator(.{}) = null;
        var mio_pull_add: ?*OpWrapper = null;

        const Self = @This();

        /// # Initializes Asynchronous I/O Instance
        /// - `detect_mem_leaks` - When **true**, uses `DebugAllocator`.
        pub fn init(detect_mem_leaks: bool) !void {
            if(Self.so != null) @panic("Initialize Only Once Per Process!");

            var sig = [_]u6{linux.SIG.USR1};
            const sigset = Signal.Linux.signalMask(&sig);
            const signal_fd = linux.signalfd(-1, &sigset, linux.SFD.NONBLOCK);
            const sfd: i32 = @bitCast(@as(u32, @truncate(signal_fd)));

            const spot = detect_mem_leaks;
            if (spot) Self.gpa = std.heap.DebugAllocator(.{}).init;

            const T = AsyncIo(capacity).SingletonObject;
            Self.so = try Uring.setup(T, capacity, sfd, .{.spot_leaks = spot});
        }

        /// # Destroys Asynchronous I/O Instance
        pub fn deinit() void {
            const sop = Self.iso();
            sop.heap.destroy(Self.mio_pull_add.?);
            debug.assert(linux.close(@intCast(sop.ring_fd)) == 0);
            if (Self.gpa) |_| debug.assert(Self.gpa.?.deinit() == .ok);
        }

        /// # Internal Static Object
        pub fn iso() *SingletonObject { return &Self.so.?; }

        /// # Sleeps for a Specified Duration
        pub fn timeout(callback: ?OpHandler, data: Any, op: Timeout) !void {
            try submit(OpData {.timeout = op}, callback, data);
        }

        /// # Accepts New Connection on a Socket
        pub fn accept(callback: ?OpHandler, data: Any, op: Accept) !void {
            try submit(OpData {.accept = op}, callback, data);
        }

        /// # Shuts Down a Socket Connection
        pub fn shutdown(callback: ?OpHandler, data: Any, op: Shutdown) !void {
            try submit(OpData {.shutdown = op}, callback, data);
        }

        /// # Open and Possibly Create a File
        pub fn open(callback: ?OpHandler, data: Any, op: Open) !void {
            try submit(OpData {.open = op}, callback, data);
        }

        /// # Closes a File Descriptor
        pub fn close(callback: ?OpHandler, data: Any, op: Close) !void {
            try submit(OpData {.close = op}, callback, data);
        }

        /// # Sends a Message on a Socket
        pub fn send(callback: ?OpHandler, data: Any, op: Send) !void {
            try submit(OpData {.send = op}, callback, data);
        }

        /// # Receives a Message from a Socket
        pub fn recv(callback: ?OpHandler, data: Any, op: Recv) !void {
            try submit(OpData {.recv = op}, callback, data);
        }

        /// # Reads from a File Descriptor at a Given Offset
        pub fn read(callback: ?OpHandler, data: Any, op: Read) !void {
            try submit(OpData {.read = op}, callback, data);
        }

        /// # Writes to a File Descriptor at a Given Offset
        pub fn write(callback: ?OpHandler, data: Any, op: Write) !void {
            try submit(OpData {.write = op}, callback, data);
        }

        /// # Gets Extended File Status
        pub fn status(callback: ?OpHandler, data: Any, op: Status) !void {
            try submit(OpData {.status = op}, callback, data);
        }

        /// # Returns the Current Event Loop Status
        pub fn evlStatus() EventLoopStatus { return Self.iso().status; }

        /// # Submits a New I/O Operation
        fn submit(op: OpData, handle: ?OpHandler, data: ?*anyopaque) !void {
            const sop = Self.iso();

            if (sop.status == .closed) return Error.Closed;

            const io_op = try sop.heap.create(OpWrapper);
            errdefer sop.heap.destroy(io_op);

            io_op.* = OpWrapper {.op = op, .handle = handle, .data = data };

            const entry: usize = @intFromPtr(io_op);
            _ = sop.queue.push(entry) orelse return Error.Overflow;

            // Notifies the watcher
            Signal.Linux.signalEmit(linux.SIG.USR1);
        }

        /// # Starts the I/O Event Loop for Execution
        /// - `l` - Length of the callbacks array at compile time
        /// - `callbacks` - Runs on exit, before closing the event loop
        pub fn eventLoop(comptime l: u8, callbacks: ?[l]ExitCallback) !void {
            const sop = Self.iso();

            log.info(
                "Async I/O event loop is running on [SQ-{d} | CQ-{d}]",
                .{sop.sq_ring.mask.* + 1, sop.cq_ring.mask.* + 1}
            );

            try Self.watch();
            sop.status = .running;

            while(true) {
                try Self.flush();    // Submitted I/O
                try Self.reapCqes(); // Completed I/O

                switch (sop.status) {
                    .inactive => unreachable,
                    .running => {
                        if (Signal.iso().signal > 0) {
                            if (callbacks) |cbs| { for (cbs) |cb| cb(); }
                            Signal.Linux.signalEmit(linux.SIG.USR1);
                            sop.status = .closing;
                        }
                    },
                    .closing => {
                        if (@atomicLoad(u32, &sop.ongoing_ios, .acquire) == 1) {
                            sop.status = .closed;
                        }
                    },
                    .closed => break
                }
            }
        }

        /// # Watches for any I/O Submission
        fn watch() !void {
            const sop = Self.iso();
            const data = PollAdd {.fd = sop.sfd, .mask = linux.POLL.IN};
            const op_data = OpData {.poll_add = data};

            const io_op = try sop.heap.create(OpWrapper);
            errdefer sop.heap.destroy(io_op);

            io_op.* = OpWrapper {.op = op_data, .handle = null, .data = null };

            Self.mio_pull_add = io_op;
            const entry: usize = @intFromPtr(io_op);
            _ = sop.queue.push(entry) orelse return Error.Overflow;
        }

        /// # Flushes Pending I/O Operations to the SQE
        /// - Submits consumed op to the SQE for completion
        /// - Sleeps when waiting on CQE completions or idle
        /// - Wakes up when `submit()` is called for a new op
        fn flush() !void {
            var count: u32 = 0;
            const sop = Self.iso();

            while(sop.queue.pop()) |op| {
                count += 1;
                try Self.submitToSqe(op.entry);
            }

            if (count > 0) { Self.pushSqes(count); return; }
            if (sop.status == .closing) return;

            // EINTR: -4 (Interrupted system call)
            const rv = uringEnter(sop.ring_fd, 0, 1, ENTER_GETEVENTS);
            const res: i32 = @bitCast(@as(u32, @truncate(rv)));
            if (res != 0 and res != -4) utils.syscallError(res, @src());
        }

        /// # Consumes and Dispatches Completed I/O from CQEs
        fn reapCqes() !void {
            while (Self.getCqe()) |cqe| {
                // Checks multishot I/O
                const cqe_flags = cqe.flags & CQE_F_MORE;
                const mio = if (cqe_flags == CQE_F_MORE) true else false;

                const sop = Self.iso();
                if (!mio) {
                    _ = @atomicRmw(u32, &sop.ongoing_ios, .Sub, 1, .release);
                }

                switch (cqe.user_data) {
                    0 => if (cqe.res < 0) utils.syscallError(cqe.res, @src()),
                    1 => {
                        // PollAdd signal handler - Consume the emitted signal
                        var info = mem.zeroes(SigInfo);
                        _ = linux.read(3, mem.asBytes(&info), @sizeOf(SigInfo));
                    },
                    else => {
                        const p: *OpWrapper = @ptrFromInt(cqe.user_data);
                        if (p.handle) |callback| callback(cqe.res, p.data)
                        else {
                            // Captures error for *null** callbacks
                            if (cqe.res < 0) {
                                utils.syscallError(cqe.res, @src());
                            }
                        }

                        if (!mio) sop.heap.destroy(p);
                    }
                }
            }
        }

        fn submitToSqe(entry: usize) !void {
            const io: *OpWrapper = @ptrFromInt(entry);
            const op_ptr = @as(?*anyopaque, io);

            var prep = Self.prepSqe();
            switch(OpData.code(&io.op)) {
                .PollAdd => {
                    const d: PollAdd = io.op.poll_add;
                    Syscall.pollAdd(&prep, d.fd, d.mask, d.mode);
                },
                .Timeout => {
                    var d: Timeout = io.op.timeout;
                    Syscall.timeout(&prep, op_ptr, &d.ts, d.mode);
                },
                .Accept => {
                    const d: Accept = io.op.accept;
                    Syscall.accept(
                        &prep, op_ptr, d.fd, d.addr, d.len, d.mode
                    );
                },
                .Shutdown => {
                    const d: Shutdown = io.op.shutdown;
                    Syscall.shutdown(&prep, op_ptr, d.fd, d.mode);
                },
                .Open => {
                    const d: Open = io.op.open;
                    Syscall.open(
                        &prep, op_ptr, d.path, d.flags, d.open_mode, d.mode
                    );
                },
                .Close => {
                    const d: Close = io.op.close;
                    Syscall.close(&prep, op_ptr, d.fd, d.mode);
                },

                .Send => {
                    const d: Send = io.op.send;
                    Syscall.send(&prep, op_ptr, d.fd, d.buff, d.len, d.mode);
                },
                .Recv => {
                    const d: Recv = io.op.recv;
                    Syscall.recv(&prep, op_ptr, d.fd, d.buff, d.len, d.mode);
                },
                .Read => {
                    const d: Read = io.op.read;
                    Syscall.read(
                        &prep, op_ptr, d.fd, d.buff, d.count, d.offset, d.mode
                    );
                },
                .Write => {
                    const d: Write = io.op.write;
                    Syscall.write(
                        &prep, op_ptr, d.fd, d.buff, d.count, d.offset, d.mode
                    );
                },
                .Status => {
                    const d: Status = io.op.status;
                    Syscall.status(
                        &prep, op_ptr, d.path, d.flags, d.mask, d.result, d.mode
                    );
                }
            }

            try Self.updateSqe(&prep);
        }

        /// # Prepares I/O Submission
        /// - Returns a pointer to fill in an SQE for an operation
        fn prepSqe() PrepData {
            const sop = Self.iso();
            const tail = sop.sq_ring.tail.*;
            const index = tail & sop.sq_ring.mask.*;

            const sqe = &sop.sqes[index];
            return .{.tail = tail, .index = index, .sqe = sqe};
        }

        /// # Updates I/O to the SQE Entry
        /// - Adds submission queue entry to the tail of the SQE ring buffer
        fn updateSqe(pd: *const PrepData) !void {
            const sop = Self.iso();

            // Only after the `SQE` has been filled
            sop.sq_ring.array[pd.index] = pd.index;
            sop.sq_ring.tail.* = pd.tail + 1;
        }

        /// # Submits Batched SQEs for Completion
        fn pushSqes(batch_len: u32) void {
            const sop = Self.iso();
            const flags = sop.sq_ring.flags.*;
            var submit_flags: u32 = ENTER_SQ_WAIT;

            // Wakes up the kernel thread for I/O submission
            if (flags & SQ_NEED_WAKEUP == SQ_NEED_WAKEUP) {
                submit_flags |= ENTER_SQ_WAKEUP;
            }

            const rv = uringEnter(sop.ring_fd, batch_len, 0, submit_flags);
            if (rv < 0) @panic("Failed to push on SQE!");

            _ = @atomicRmw(u32, &sop.ongoing_ios, .Add, batch_len, .release);
        }

        /// # Extracts Completed CQE from CQ Ring Buffer
        fn getCqe() ?IoUringCqe {
            const sop = Self.iso();
            const head = sop.cq_ring.head.*;
            if (head == sop.cq_ring.tail.*) return null; // Ring buffer is empty

            const cqe = sop.cqes[head & sop.cq_ring.mask.*];
            sop.cq_ring.head.* = head + 1;
            return cqe;
        }
    };
}

//##############################################################################
//# I/O OP DATA DECLARATION ---------------------------------------------------#
//##############################################################################

const PollAdd = struct {
    fd: i32,
    mask: u32,
    mode: Mode = .io_async
};

const Timeout = struct {
    ts: linux.timespec,
    mode: Mode = .io_async
};

const Accept = struct {
    fd: i32,
    addr: *linux.sockaddr,
    len: *linux.socklen_t,
    mode: Mode = .io_async
};

const Shutdown = struct {
    fd: i32,
    mode: Mode = .io_async
};

const Open = struct {
    path: []const u8,
    flags: i32,
    open_mode: linux.mode_t,
    mode: Mode = .io_async
};

const Close = struct {
    fd: i32,
    mode: Mode = .io_async
};

const Send = struct {
    fd: i32,
    buff: []const u8,
    len: usize,
    mode: Mode = .io_async
};

const Recv = struct {
    fd: i32,
    buff: []u8,
    len: usize,
    mode: Mode = .io_async
};

const Read = struct {
    fd: i32,
    buff: []u8,
    count: usize,
    offset: usize,
    mode: Mode = .io_async
};

const Write = struct {
    fd: i32,
    buff: []const u8,
    count: usize,
    offset: usize,
    mode: Mode = .io_async
};

const Status = struct {
    path: []const u8,
    flags: i32,
    mask: u32,
    result: *linux.Statx,
    mode: Mode = .io_async
};

/// # Supported I/O Operations
/// To implement a new operation do the following:
///
/// - Add the new I/O data structure above and include here as follows
/// - Capture that new I/O operation in `submitToSqe()`'s switch prong
/// - Add `io_uring` syscall implementation at the `Syscall` structure
const OpData = union(enum) {
    const Op = enum {
        PollAdd,
        Timeout,
        Accept,
        Shutdown,
        Open,
        Close,
        Send,
        Recv,
        Read,
        Write,
        Status
    };

    poll_add: PollAdd,
    timeout:  Timeout,
    accept:   Accept,
    shutdown: Shutdown,
    open:     Open,
    close:    Close,
    send:     Send,
    recv:     Recv,
    read:     Read,
    write:    Write,
    status:   Status,

    fn code(self: *OpData) Op {
        return switch (self.*) {
            .poll_add => .PollAdd,
            .timeout =>  .Timeout,
            .accept =>   .Accept,
            .shutdown => .Shutdown,
            .open =>     .Open,
            .close =>    .Close,
            .send =>     .Send,
            .recv =>     .Recv,
            .read =>     .Read,
            .write =>    .Write,
            .status =>   .Status
        };
    }
};

const OpHandler = *const fn(cqe_res: i32, userdata: ?*anyopaque) void;
const OpWrapper = struct { op: OpData, handle: ?OpHandler, data: ?*anyopaque };

//##############################################################################
//# I/O SYSCALL IMPLEMENTATION ------------------------------------------------#
//##############################################################################

const PrepData = struct { tail: u32, index: u32, sqe: *IoUringSqe };

const Syscall = struct {
    /// # Issues the io_uring `poll_add` Operation
    /// - Set `POLL_ADD_MULTI` in `pd.sqe.len` field for multishot
    fn pollAdd(pd: *PrepData, fd: i32, poll_mask: u32, io_mode: Mode) void {
        pd.sqe.opcode = linux.IORING_OP.POLL_ADD;
        pd.sqe.fd = fd;
        pd.sqe.flags = @intFromEnum(io_mode);
        pd.sqe.ioprio = 0;
        pd.sqe.union_1.off = 0;
        pd.sqe.union_2.addr = 0;
        pd.sqe.len = POLL_ADD_MULTI;
        pd.sqe.union_3.rw_flags = std.mem.nativeToLittle(u32, poll_mask);
        pd.sqe.user_data = 1;
        pd.sqe.union_4.__pad2 = [3]u64{0, 0, 0};
    }

    /// # Issues the io_uring `timeout` Operation
    /// - See `IORING_OP_TIMEOUT` section on `io_uring_enter(2)` man page
    fn timeout(
        pd: *PrepData,
        p: ?*anyopaque,
        ts: *linux.timespec,
        io_mode: Mode
    ) void {
        pd.sqe.opcode = linux.IORING_OP.TIMEOUT;
        pd.sqe.fd = 0;
        pd.sqe.flags = @intFromEnum(io_mode);
        pd.sqe.ioprio = 0;
        pd.sqe.union_1.off = 0;
        pd.sqe.union_2.addr = @intFromPtr(ts);
        pd.sqe.len = 1;
        pd.sqe.union_3.timeout_flags = linux.IORING_TIMEOUT_BOOTTIME;
        pd.sqe.user_data = if (p) |data| @intFromPtr(data) else 0;
        pd.sqe.union_4.__pad2 = [3]u64{0, 0, 0};
    }

    /// # Issues the Equivalent of a `accept4(2)` Syscall
    /// - See https://man7.org/linux/man-pages/man2/accept.2.html
    /// - We set the `flags` field of `accept4(2)` in `sqe.union_3.accept_flags`
    fn accept(
        pd: *PrepData,
        p: ?*anyopaque,
        sock_fd: i32,
        addr: *linux.sockaddr,
        addrlen: *linux.socklen_t,
        io_mode: Mode
    ) void {
        pd.sqe.opcode = linux.IORING_OP.ACCEPT;
        pd.sqe.fd = sock_fd;
        pd.sqe.flags = @intFromEnum(io_mode);
        pd.sqe.ioprio = ACCEPT_MULTISHOT;
        pd.sqe.union_1.addr2 = @intFromPtr(addrlen);
        pd.sqe.union_2.addr = @intFromPtr(addr);
        pd.sqe.len = 0;
        pd.sqe.union_3.accept_flags = 0;
        pd.sqe.user_data = @intFromPtr(p);
        pd.sqe.union_4.__pad2 = [3]u64{0, 0, 0};
    }

    /// # Issues the Equivalent of a `shutdown(2)` Syscall
    /// - See https://man7.org/linux/man-pages/man2/shutdown.2.html
    fn shutdown(
        pd: *PrepData,
        p: ?*anyopaque,
        sock_fd: i32,
        io_mode: Mode
    ) void {
        pd.sqe.opcode = linux.IORING_OP.SHUTDOWN;
        pd.sqe.fd = sock_fd;
        pd.sqe.flags = @intFromEnum(io_mode);
        pd.sqe.ioprio = 0;
        pd.sqe.union_1.off = 0;
        pd.sqe.union_2.addr = 0;
        pd.sqe.len = linux.SHUT.RD;
        pd.sqe.union_3.rw_flags = 0;
        pd.sqe.user_data = if (p) |data| @intFromPtr(data) else 0;
        pd.sqe.union_4.__pad2 = [3]u64{0, 0, 0};
    }

    /// # Issues the Equivalent of a `openat(2)` Syscall
    /// - See - https://man7.org/linux/man-pages/man2/openat.2.html
    /// - Set the `flags` field of `openat(2)` in `sqe.union_3.open_flags`
    fn open(
        pd: *PrepData,
        p: ?*anyopaque,
        path: []const u8,
        flags: i32,
        mode: linux.mode_t,
        io_mode: Mode
    ) void {
        pd.sqe.opcode = linux.IORING_OP.OPENAT;
        pd.sqe.fd = 0; // Only when given path is an absolute file path
        pd.sqe.flags = @intFromEnum(io_mode);
        pd.sqe.ioprio = 0;
        pd.sqe.union_1.off = 0;
        pd.sqe.union_2.addr = @intFromPtr(path.ptr);
        pd.sqe.len = mode;
        pd.sqe.union_3.open_flags = @bitCast(flags);
        pd.sqe.user_data = if (p) |data| @intFromPtr(data) else 0;
        pd.sqe.union_4.__pad2 = [3]u64{0, 0, 0};
    }

    /// # Issues the Equivalent of a `close(2)` Syscall
    /// - See - https://man7.org/linux/man-pages/man2/close.2.html
    /// - Set the `flags` field of `close(2)` in `sqe.union_3.msg_flags`
    fn close(pd: *PrepData, p: ?*anyopaque, fd: i32, io_mode: Mode) void {
        pd.sqe.opcode = linux.IORING_OP.CLOSE;
        pd.sqe.fd = fd;
        pd.sqe.flags = @intFromEnum(io_mode);
        pd.sqe.ioprio = 0;
        pd.sqe.union_1.off = 0;
        pd.sqe.union_2.addr = 0;
        pd.sqe.len = 0;
        pd.sqe.union_3.msg_flags = 0;
        pd.sqe.user_data = if (p) |data| @intFromPtr(data) else 0;
        pd.sqe.union_4.__pad2 = [3]u64{0, 0, 0};
    }

    /// # Issues the Equivalent of a `send(2)` Syscall
    /// - See https://man7.org/linux/man-pages/man2/send.2.html
    /// - Set the `flags` field of `send(2)` in `sqe.union_3.msg_flags`
    fn send(
        pd: *PrepData,
        p: ?*anyopaque,
        fd: i32,
        buff: []const u8,
        len: usize,
        io_mode: Mode
    ) void {
        pd.sqe.opcode = linux.IORING_OP.SEND;
        pd.sqe.fd = fd;
        pd.sqe.flags = @intFromEnum(io_mode);
        pd.sqe.ioprio = 0;
        pd.sqe.union_1.off = 0;
        pd.sqe.union_2.addr = @intFromPtr(buff.ptr);
        pd.sqe.len = @as(u32, @intCast(len));
        pd.sqe.union_3.msg_flags = 0;
        pd.sqe.user_data = if (p) |data| @intFromPtr(data) else 0;
        pd.sqe.union_4.__pad2 = [3]u64{0, 0, 0};
    }

    /// # Issues the Equivalent of a `recv(2)` Syscall
    /// - See https://man7.org/linux/man-pages/man2/recv.2.html
    /// - Set the `flags` field of `recv(2)` in `sqe.union_3.msg_flags`
    fn recv(
        pd: *PrepData,
        p: ?*anyopaque,
        fd: i32,
        buff: []u8,
        len: usize,
        io_mode: Mode
    ) void {
        pd.sqe.opcode = linux.IORING_OP.RECV;
        pd.sqe.fd = fd;
        pd.sqe.flags = @intFromEnum(io_mode);
        pd.sqe.ioprio = RECVSEND_POLL_FIRST;
        pd.sqe.union_1.off = 0;
        pd.sqe.union_2.addr = @intFromPtr(buff.ptr);
        pd.sqe.len = @as(u32, @intCast(len));
        pd.sqe.union_3.msg_flags = 0;
        pd.sqe.user_data = if (p) |data| @intFromPtr(data) else 0;
        pd.sqe.union_4.__pad2 = [3]u64{0, 0, 0};
    }

    /// # Issues the Equivalent of a `pread(2)` Syscall
    /// - See - https://man7.org/linux/man-pages/man2/pread.2.html
    /// - The file referenced by `fd` must be capable of seeking
    /// - Reads the whole buffer if `count` is 0 or more than the `buff.len`
    fn read(
        pd: *PrepData,
        p: ?*anyopaque,
        fd: i32,
        buff: []u8,
        count: usize,
        offset: usize,
        io_mode: Mode
    ) void {
        pd.sqe.opcode = linux.IORING_OP.READ;
        pd.sqe.fd = fd;
        pd.sqe.flags = @intFromEnum(io_mode);
        pd.sqe.ioprio = 0;
        pd.sqe.union_1.off = offset;
        pd.sqe.union_2.addr = @intFromPtr(buff.ptr);
        pd.sqe.len = @as(u32, @intCast(count));
        pd.sqe.union_3.rw_flags = 0;
        pd.sqe.user_data = if (p) |data| @intFromPtr(data) else 0;
        pd.sqe.union_4.__pad2 = [3]u64{0, 0, 0};
    }

    /// # Issues the Equivalent of a `pwrite(2)` Syscall
    /// - See https://man7.org/linux/man-pages/man2/pwrite.2.html
    /// - The file referenced by `fd` must be capable of seeking
    /// - Writes the whole buffer if `count` is 0 or more than the `buff.len`
    fn write(
        pd: *PrepData,
        p: ?*anyopaque,
        fd: i32,
        buff: []const u8,
        count: usize,
        offset: usize,
        io_mode: Mode
    ) void {
        pd.sqe.opcode = linux.IORING_OP.WRITE;
        pd.sqe.fd = fd;
        pd.sqe.flags = @intFromEnum(io_mode);
        pd.sqe.ioprio = 0;
        pd.sqe.union_1.off = offset;
        pd.sqe.union_2.addr = @intFromPtr(buff.ptr);
        pd.sqe.len = @as(u32, @intCast(count));
        pd.sqe.union_3.rw_flags = 0;
        pd.sqe.user_data = if (p) |data| @intFromPtr(data) else 0;
        pd.sqe.union_4.__pad2 = [3]u64{0, 0, 0};
    }

    /// # Issues the Equivalent of a `statx(2)` Syscall
    /// - https://man7.org/linux/man-pages/man2/statx.2.html
    /// - Set the `flags` field of `statx(2)` in `sqe.union_3.statx_flags`
    fn status(
        pd: *PrepData,
        p: ?*anyopaque,
        path: []const u8,
        flags: i32,
        mask: u32,
        result: *Statx,
        io_mode: Mode
    ) void {
        pd.sqe.opcode = linux.IORING_OP.STATX;
        pd.sqe.fd = 0; // Only when given path is an absolute file path
        pd.sqe.flags = @intFromEnum(io_mode);
        pd.sqe.ioprio = 0;
        pd.sqe.union_1.off = @intFromPtr(result);
        pd.sqe.union_2.addr = @intFromPtr(path.ptr);
        pd.sqe.len = mask;
        pd.sqe.union_3.statx_flags = @bitCast(flags);
        pd.sqe.user_data = if (p) |data| @intFromPtr(data) else 0;
        pd.sqe.union_4.__pad2 = [3]u64{0, 0, 0};
    }
};

//##############################################################################
//# URING STRUCTURE & SETUP ---------------------------------------------------#
//##############################################################################

// IO Uring Magic Offsets For Ring `mmap()`
const OFF_SQ_RING = linux.IORING_OFF_SQ_RING;
const OFF_SQES = linux.IORING_OFF_SQES;

// IO Uring Features
const FEAT_SINGLE_MMAP = linux.IORING_FEAT_SINGLE_MMAP;

// IO Uring Context Setup Flags
const SETUP_SQPOLL = linux.IORING_SETUP_SQPOLL;
const SETUP_ATTACH_WQ = linux.IORING_SETUP_ATTACH_WQ;
const SETUP_SINGLE_ISSUER = linux.IORING_SETUP_SINGLE_ISSUER;

// IO Uring Context SQE flags
const ENTER_SQ_WAIT = linux.IORING_ENTER_SQ_WAIT;
const SQ_NEED_WAKEUP = linux.IORING_SQ_NEED_WAKEUP;
const ENTER_SQ_WAKEUP = linux.IORING_ENTER_SQ_WAKEUP;

// IO Uring Context POLL flags
const POLL_ADD_MULTI = linux.IORING_POLL_ADD_MULTI;
const ACCEPT_MULTISHOT = linux.IORING_ACCEPT_MULTISHOT;
const RECVSEND_POLL_FIRST = linux.IORING_RECVSEND_POLL_FIRST;

// IO Uring Context CQE flags
const CQE_F_MORE = linux.IORING_CQE_F_MORE;
const ENTER_GETEVENTS = linux.IORING_ENTER_GETEVENTS;

/// # Completion Queue Event
const IoUringCqe = extern struct { user_data: u64, res: i32, flags: u32 };

/// # Submission Queue Event
const IoUringSqe = extern struct {
    /// Handles various offsets
    const Union1 = extern union {
        /// Offset into file
        off: u64,
        /// Address at which the operation should perform IO
        addr2: u64
    };

    /// Handles various pointers
    const Union2 = extern union {
        /// Pointer to buffer or iovecs
        addr: u64,
        /// Starting offset for `splice()` syscall
        splice_off_in: u64
    };

    /// Handles necessary flags for various IO operations
    const Union3 = extern union {
        /// Additional flags for read and write operations
        rw_flags: u32,
        fsync_flags: u32,
        /// Compatibility
        poll_events: u16,
        /// Word-reversed for BE
        poll32_events: u32,
        sync_range_flags: u32,
        /// For `send()` and `recv()` syscalls
        msg_flags: u32,
        /// For `io_uring` timeout operation
        timeout_flags: u32,
        /// For `accept4()` syscall
        accept_flags: u32,
        cancel_flags: u32,
        open_flags: u32,
        statx_flags: u32,
        fadvise_advice: u32,
        splice_flags: u32
    };

    /// Pack this to avoid bogus arm **OABI** complaints
    const NestedUnion1 = packed union {
        /// Index into fixed buffers (if used).
        buf_index: u16,
        /// For grouped buffer selection
        buf_group: u16
    };

    const Struct1 = extern struct {
        nested_union_1: NestedUnion1,
        /// Sets execution domain for `personality()` syscall
        personality: u16,
        /// For `splice()` syscall
        splice_fd_in: i32
    };

    const Union4 = extern union { struct_1: Struct1, __pad2: [3]u64 };

    /// Type of operation for this SQE
    opcode: linux.IORING_OP,
    /// Common modifier flags across command types
    flags: u8,
    /// Request priority and additional flags
    ioprio: u16,
    /// File descriptor to do I/O on
    fd: i32,
    union_1: Union1,
    union_2: Union2,
    /// Buffer size or number of iovecs
    len: u32,
    union_3: Union3,
    /// Data to be passed back at I/O completion
    user_data: u64,
    union_4: Union4
};

/// # Configuration Options
const Cfg = struct {
    /// Detects memory leaks when true
    spot_leaks: bool,
    /// Standalone kernel thread backend
    shared_worker: bool = false,
    /// Used when `ATTACH_WQ` is set
    parent_ring_fd: u32 = 0
};

/// # IO Uring Initialization
const Uring = struct {
    /// Describes the offsets of various SQ ring buffer fields
    const IoSqringOffsets = extern struct {
        head: u32,
        tail: u32,
        ring_mask: u32,
        ring_entries: u32,
        flags: u32,
        dropped: u32,
        array: u32,
        resv1: u32,
        user_addr: u64,
    };

    /// Describes the offsets of various CQ ring buffer fields
    const IoCqringOffsets = extern struct {
        head: u32,
        tail: u32,
        ring_mask: u32,
        ring_entries: u32,
        overflow: u32,
        cqes: u32,
        flags: u32,
        resv1: u32,
        user_addr: u64
    };

    /// The `flags`, `sq_thread_cpu`, and `sq_thread_idle` fields are used to
    /// configure the io_uring instance. The rest of the fields are filled in by the kernel. See `io_uring_setup()` man page for more details.
    const IoUringParams = extern struct {
        sq_entries: u32,
        cq_entries: u32,
        // Bit mask of 0 or more values `|` (**OR**ed) together. If no flags are specified, the io_uring instance is setup with interrupt driven IO.
        flags: u32,
        // If `IORING_SETUP_SQ_AFF` flag is specified, then the poll thread will be bound to the cpu set in the `sq_thread_cpu` field. This field specifies the CPU core (logical CPU number) to which the SQ thread should be bound. Depending on the specified CPU load it can improve cache locality and reduce context switches or it may impact the performance. The actual behavior depends on the OS and its scheduler.
        sq_thread_cpu: u32,
        // Thread (kernel) idle time in milliseconds
        sq_thread_idle: u32,
        // Specifies various features supported by current kernel version.
        features: u32,
        // An existing `io_uring` ring fd. Shares the asynchronous worker thread backend of the specified `io_uring` ring, rather than create a new separate thread pool when `IORING_SETUP_ATTACH_WQ` flag is set.
        wq_fd: u32,
        // Must be initialized to zero.
        resv: [3]u32 = [_]u32{0} ** 3,
        sq_off: IoSqringOffsets,
        cq_off: IoCqringOffsets
    };

    /// # Asynchronous I/O context setup for I/O bound workloads
    /// - `sfd` - SignalFD for the `submitWatcher()`
    /// = `cap` - Total capacity of the underlying MPSC queue
    /// - `cfg` - Additional configuration options for `io_uring` interface
    fn setup(comptime T: type, comptime cap: u32, sfd: i32, cfg: Cfg) !T {
        // Ensures that the currently installed OS kernel supports
        // all `io_uring` operations that are defined in this file.
        var uts: linux.utsname = undefined;
        _ = linux.uname(&uts);

        const version = try utils.parseDirtySemver(&uts.release);
        const sem_ver = SemVer {.major = 6, .minor = 8, .patch = 0};
        if (version.order(sem_ver) == .lt) {
            @panic("Linux kernel >= 6.8 is required!");
        }

        var p = mem.zeroes(IoUringParams);

        // Checks whether the `Io` instance being created will share
        // the kernels asynchronous worker from another instance or not!
        if (!cfg.shared_worker) p.flags = SETUP_SQPOLL | SETUP_SINGLE_ISSUER
        else {
            // We must provide a valid ring fd as parent when `ATTACH_WQ` is set
            // The parent ring must be setup with the `IORING_SETUP_SQPOLL` flag
            debug.assert(cfg.parent_ring_fd > 0);
            p.wq_fd = cfg.parent_ring_fd;

            p.flags = SETUP_SQPOLL | SETUP_SINGLE_ISSUER | SETUP_ATTACH_WQ;
        }

        const ring_fd = uringSetup(cap, &p);
        debug.assert(ring_fd > 0);

        // Checks whether a feature is supported by the kernel or not.
        // const feat_nodrop = linux.IORING_FEAT_NODROP;
        // if (p.features & feat_nodrop == feat_nodrop) {
        //     log.info("This Linux Kernel supports NODROP for CQE's", .{});
        // }

        debug.assert(p.features & FEAT_SINGLE_MMAP == FEAT_SINGLE_MMAP);

        const fd: i32 = @intCast(ring_fd);

        const size = @max(
            p.sq_off.array + p.sq_entries * @sizeOf(u32),
            p.cq_off.cqes + p.cq_entries * @sizeOf(IoUringCqe)
        );

        // Map in the submission and completion queue ring buffers
        // Communication happens via 2 shared kernel-user space ring buffers
        // Which can be jointly mapped with the following single `mmap()`.
        const PROT = linux.PROT;
        const mmap = try posix.mmap(null, size, PROT.READ | PROT.WRITE, .{.TYPE = .SHARED, .POPULATE = true}, fd, OFF_SQ_RING);
        errdefer posix.munmap(mmap);
        debug.assert(mmap.len == size);

        // Map in the submission queue entries array
        const sqes_size = p.sq_entries * @sizeOf(IoUringSqe);
        const sqes_mmap = try posix.mmap(null, sqes_size, PROT.READ | PROT.WRITE, .{.TYPE = .SHARED, .POPULATE = true}, fd, OFF_SQES);
        errdefer posix.munmap(sqes_mmap);
        debug.assert(sqes_mmap.len == sqes_size);

        const sqes: [*]IoUringSqe = @ptrCast(@alignCast(&sqes_mmap[0]));

        const sq_tail: *u32 = @ptrCast(@alignCast(&mmap[p.sq_off.tail]));
        const sq_mask: *u32 = @ptrCast(@alignCast(&mmap[p.sq_off.ring_mask]));
        const sq_flag: *u32 = @ptrCast(@alignCast(&mmap[p.sq_off.flags]));
        const sq_array: [*]u32 = @ptrCast(@alignCast(&mmap[p.sq_off.array]));

        const cqes: [*]IoUringCqe = @ptrCast(@alignCast(&mmap[p.cq_off.cqes]));

        const cq_head: *u32 = @ptrCast(@alignCast(&mmap[p.cq_off.head]));
        const cq_tail: *u32 = @ptrCast(@alignCast(&mmap[p.cq_off.tail]));
        const cq_mask: *u32 = @ptrCast(@alignCast(&mmap[p.cq_off.ring_mask]));

        const Aio = AsyncIo(cap);
        const malloc = std.heap.c_allocator;

        return .{
            .flags = p.flags,
            .ring_fd = ring_fd,
            .sqes = sqes,
            .cqes = cqes,
            .sq_ring = .{
                .tail = sq_tail,
                .mask = sq_mask,
                .flags = sq_flag,
                .array = sq_array
            },
            .cq_ring = .{
                .head = cq_head,
                .tail = cq_tail,
                .mask = cq_mask
            },
            .sfd = sfd,
            .status = .inactive,
            .heap = if (cfg.spot_leaks) Aio.gpa.?.allocator() else malloc,
            .queue = MPSC(cap).init()
        };
    }
};

//##############################################################################
//# SYSCALL IMPLEMENTATION ----------------------------------------------------#
//##############################################################################

/// # Context For Performing Asynchronous I/O
/// - See https://man7.org/linux/man-pages/man2/io_uring_setup.2.html
fn uringSetup(entries: u32, params: *Uring.IoUringParams) usize {
    const num = switch (builtin.cpu.arch) {
        .x86_64 => linux.syscalls.X64.io_uring_setup,
        .aarch64 => linux.syscalls.Arm64.io_uring_setup,
        else => @compileError("Unsupported Architecture!")
    };

    return linux.syscall2(num, entries, @intFromPtr(params));
}

/// # Initiates and/or Completes Asynchronous I/O
/// - See https://man7.org/linux/man-pages/man2/io_uring_enter.2.html
fn uringEnter(fd: usize, to_submit: u32, min_complete: u32, flags: u32) usize {
    const num = switch (builtin.cpu.arch) {
        .x86_64 => linux.syscalls.X64.io_uring_enter,
        .aarch64 => linux.syscalls.Arm64.io_uring_enter,
        else => @compileError("Unsupported Architecture!")
    };

    const sig = linux.NSIG / 8;
    return linux.syscall6(num, fd, to_submit, min_complete, flags, 0, sig);
}
