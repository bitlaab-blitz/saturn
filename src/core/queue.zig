//! # Multi-Threaded Queue Module - v2.1.0
//! - Bounded, non-blocking multi-producer and/or multi-consumer queues
//! - Provides thread synchronization for highly multi-threaded workloads
//!
//! ## Design
//! **per-slot sequence stamps + ticket cursors (crossbeam style)**
//! - Every slot carries its own stamp, so a producer/consumer only ever touches
//!   the slot it owns plus (for the multi side) one cursor
//! - `push`/`pop` answer "full"/"empty" in O(1), never by scanning the ring
//! - Entries leave the ring in the order their tickets were claimed (FIFO)
//! - Consecutive tickets are mapped to *different cache lines* (index remap),
//!   so threads working on neighbouring tickets do not false-share
//! - `head`, `tail` and `ring` live on separate cache lines
//! - The single side (SP or SC) uses a plain, non-atomic cursor
//! - A slot is always a power of two in size (padded), so a slot never
//!   straddles two cache lines and the remap stays a bijection for any `T`
//!
//! **Remarks:** on MP and/or MC part of the queue:
//! - The index returned by `push` is the physical slot of the entry, and the
//!   same index is reported by `pop` for that entry (mapping is guaranteed)
//! - Indices aren't sequential: consecutive push land on different cache lines
//! - `null` from `pop` means "no entry is ready at the head of the queue". If a
//!   producer claimed a ticket but has not published it yet, `pop` reports
//!   empty until it does (this is the price of FIFO order)
//! - `null` from `push` means slot at the tail of the ring is still occupied
//!
//! **Remarks:** on SP and/or SC part of the queue:
//! - Make sure; push and/or pop from the ring is always single threaded
//! - Any accidental multi-threaded access will cause undefined behavior
//!   (Debug builds trap the detectable cases instead of spinning forever)
//!
//! **Remarks:** on entries:
//! - Queues accept any value, `T` is copied in and out by plain loads/stores
//!   that the slot stamp orders (write -> release-store, acquire-load -> read)
//! - Tickets are `usize` counters that wrap; the stamp scheme is exact for the
//!   2^64 pushes of a 64-bit target (a 32-bit target wraps after 2^32 pushes)

const std = @import("std");
const math = std.math;
const debug = std.debug;
const atomic = std.atomic;

const builtin = @import("builtin");

pub fn DataOf(comptime T: type) type {
    return struct { index: usize, entry: T };
}

pub const Data = DataOf(usize);

/// # Single-Producer Multi-Consumer Queue
/// - `entries` - Must be the power of two e.g., `512`, `1024`, etc.
pub fn SPMC(comptime entries: u32) type {
    return Ring(usize, entries, false, true);
}

/// # Multi-Producer Single-Consumer Queue
/// - `entries` - Must be the power of two e.g., `512`, `1024`, etc.
pub fn MPSC(comptime entries: u32) type {
    return Ring(usize, entries, true, false);
}

/// # Multi-Producer Multi-Consumer Queue
/// - `entries` - Must be the power of two e.g., `512`, `1024`, etc.
pub fn MPMC(comptime entries: u32) type {
    return Ring(usize, entries, true, true);
}

/// # Single-Producer Multi-Consumer Queue Carrying `T` In Its Slots
pub fn SPMCOf(comptime T: type, comptime entries: u32) type {
    return Ring(T, entries, false, true);
}

/// # Multi-Producer Single-Consumer Queue Carrying `T` In Its Slots
pub fn MPSCOf(comptime T: type, comptime entries: u32) type {
    return Ring(T, entries, true, false);
}

/// # Multi-Producer Multi-Consumer Queue Carrying `T` In Its Slots
pub fn MPMCOf(comptime T: type, comptime entries: u32) type {
    return Ring(T, entries, true, true);
}

/// - One ring cell. `seq` (the stamp) tells whose turn it is;
/// - `entry` is plain data protected by that stamp (written before a
///   release-store of `seq`, read after an acquire-load of it).
/// - A zero stamp is a valid "empty, lap 0" cell, so a init queue `.{}` works.
/// - The cell is padded up to a power of two so cells never straddle a cache
///   line and `cache_line / @sizeOf(Slot)` is exact.
fn Slot(comptime T: type) type {
    const Raw = struct { seq: usize, entry: T };
    const raw = @sizeOf(Raw);
    const full = math.ceilPowerOfTwoAssert(usize, raw);

    return struct {
        seq: usize = 0,
        entry: T = undefined,
        _pad: [full - raw]u8 = undefined,

        const empty: @This() = .{};
    };
}

fn Ring(
    comptime T: type,
    comptime entries: u32,
    comptime multi_producer: bool,
    comptime multi_consumer: bool
) type {
    comptime debug.assert(math.isPowerOfTwo(entries));
    const S = Slot(T);
    comptime debug.assert(math.isPowerOfTwo(@sizeOf(S)));

    return struct {
        // Each field starts on its own cache line:
        // Producers and consumers never false-share their cursors
        // Producers and consumers never shares a line with the ring
        // The struct size is a multiple of the line, so a neighbour in a parent
        // struct can never land inside this queue's tail padding either.
        head: usize align(atomic.cache_line) = 0, // ticket cursor - push
        tail: usize align(atomic.cache_line) = 0, // ticket cursor - pop
        ring: [entries]S align(atomic.cache_line) = @splat(S.empty),

        const depth = entries;
        const mask: usize = entries - 1;
        // log2(entries): ticket -> lap
        const shift: usize = @ctz(@as(u32, entries)); 
        // Index remap: slots per cache line, and whether remapping applies.
        const slots_per_line: usize = @max(1, atomic.cache_line / @sizeOf(S));
        const do_remap = slots_per_line > 1 and entries >= slots_per_line * 2;
        const lines: usize = if (do_remap) entries / slots_per_line else 1;
        const line_bits: usize = if (do_remap) @ctz(@as(u32, lines)) else 0;

        pub const Item = DataOf(T);

        const Self = @This();

        pub fn init() Self { return .{}; }

        pub fn capacity(self: *const Self) u32 { _ = self; return depth; }

        /// Bijective map ticket -> physical slot.
        /// Consecutive tickets land on different cache lines;
        /// every slot is still used exactly once per lap.
        inline fn slotIndex(ticket: usize) usize {
            const p = ticket & mask;
            if (!do_remap) return p;
            return ((p & (lines - 1)) * slots_per_line) + (p >> line_bits);
        }

        /// # Returns the Queued Position of the Entry
        pub fn push(self: *Self, entry: T) ?usize {
            var pos = if (multi_producer)
                @atomicLoad(usize, &self.head, .monotonic)
            else
                self.head;

            while (true) {
                const index = slotIndex(pos);
                const slot = &self.ring[index];
                const stamp = (pos >> shift) *% 2; // "empty for this lap"
                const seq = @atomicLoad(usize, &slot.seq, .acquire);
                const diff: isize = @bitCast(seq -% stamp);

                if (diff == 0) {
                    // Slot is free for this ticket: claim the ticket.
                    if (multi_producer) {
                        if (@cmpxchgWeak(usize, &self.head, pos, pos +% 1, .monotonic, .monotonic)) |cur| {
                            // lost the race (or spurious):
                            // retry from the fresh head
                            pos = cur; 
                            atomic.spinLoopHint();
                            continue;
                        }
                    } else {
                        self.head = pos +% 1;
                    }

                    slot.entry = entry;

                    // Publish
                    @atomicStore(usize, &slot.seq, stamp +% 1, .release); 
                    return index;
                } else if (diff < 0) {
                    // Queue is full (slot not yet consumed from last lap)
                    return null;
                } else {
                    // Another producer already took this ticket: reload the
                    // cursor. Single producer can never see a published slot
                    // ahead of it.
                    if (!multi_producer) unreachable;
                    pos = @atomicLoad(usize, &self.head, .monotonic);
                }
            }
        }

        /// # Extracts the Queued Entry
        pub fn pop(self: *Self) ?Item {
            var pos = if (multi_consumer)
                @atomicLoad(usize, &self.tail, .monotonic)
            else
                self.tail;

            while (true) {
                const index = slotIndex(pos);
                const slot = &self.ring[index];
                const stamp = (pos >> shift) *% 2; // "empty for this lap"
                const seq = @atomicLoad(usize, &slot.seq, .acquire);
                const diff: isize = @bitCast(seq -% (stamp +% 1));

                if (diff == 0) {
                    // Slot is published for this ticket: claim the ticket.
                    if (multi_consumer) {
                        if (@cmpxchgWeak(usize, &self.tail, pos, pos +% 1, .monotonic, .monotonic)) |cur| {
                            // lost the race (or spurious):
                            // retry from the fresh tail
                            pos = cur;
                            atomic.spinLoopHint();
                            continue;
                        }
                    } else {
                        self.tail = pos +% 1;
                    }

                    const entry = slot.entry;
                    // free for next lap
                    @atomicStore(usize, &slot.seq, stamp +% 2, .release); 
                    return .{ .index = index, .entry = entry };
                } else if (diff < 0) {
                    // Queue is empty (nothing published at the head)
                    return null; 
                } else {
                    // Another consumer already took this ticket: reload the
                    // cursor. Single consumer can never see a slot consumed
                    // ahead of it.
                    if (!multi_consumer) unreachable;
                    pos = @atomicLoad(usize, &self.tail, .monotonic);
                }
            }
        }
    };
}

test "FIFO order, full and empty, across many laps" {
    inline for (.{ SPMC(16), MPSC(16), MPMC(16) }) |Q| {
        var q: Q = .init();
        try std.testing.expect(q.pop() == null);

        // Fill: every entry accepted, 17th rejected in O(1).
        for (1..17) |v| try std.testing.expect(q.push(v) != null);
        try std.testing.expect(q.push(99) == null);

        // Drain in FIFO order.
        for (1..17) |v| {
            const d = q.pop().?;
            try std.testing.expectEqual(v, d.entry);
        }
        try std.testing.expect(q.pop() == null);

        // Wrap the ring many times (laps) with single push/pop.
        for (1..16 * 10) |v| {
            try std.testing.expect(q.push(v) != null);
            try std.testing.expectEqual(v, q.pop().?.entry);
        }
    }
}

test "push index matches pop index, and indices are unique" {
    inline for (.{ SPMC(16), MPSC(16), MPMC(16) }) |Q| {
        var q: Q = .init();
        var idx: [16]usize = undefined;
        var seen: u16 = 0;

        for (0..16) |i| {
            idx[i] = q.push(i + 1).?;
            try std.testing.expect(idx[i] < 16);
            seen |= @as(u16, 1) << @intCast(idx[i]);
        }
        try std.testing.expectEqual(@as(u16, 0xFFFF), seen); // bijection: all slots used

        for (0..16) |i| {
            const d = q.pop().?;
            try std.testing.expectEqual(i + 1, d.entry);
            try std.testing.expectEqual(idx[i], d.index);
        }
    }
}

test "default-initialised queue works" {
    var q: MPMC(8) = .{};
    try std.testing.expect(q.push(7) != null);
    try std.testing.expectEqual(@as(usize, 7), q.pop().?.entry);
}

test "layout: cursors and ring never share a cache line" {
    inline for (.{ MPMC(64), MPSC(64), SPMC(64), MPMC(2), MPMCOf([5]u64, 64) }) |Q| {
        const cl = atomic.cache_line;
        try std.testing.expect(@offsetOf(Q, "head") % cl == 0);
        try std.testing.expect(@offsetOf(Q, "tail") % cl == 0);
        try std.testing.expect(@offsetOf(Q, "ring") % cl == 0);
        try std.testing.expect(@offsetOf(Q, "head") / cl != @offsetOf(Q, "tail") / cl);
        try std.testing.expect(@sizeOf(Q) % cl == 0);
        try std.testing.expect(@alignOf(Q) >= cl);
    }
}

test "slots are power-of-two sized for any payload" {
    try std.testing.expect(std.math.isPowerOfTwo(@sizeOf(Slot(usize))));
    try std.testing.expect(std.math.isPowerOfTwo(@sizeOf(Slot([3]u64))));
    try std.testing.expect(std.math.isPowerOfTwo(@sizeOf(Slot(struct { a: u8 }))));
    try std.testing.expect(std.math.isPowerOfTwo(@sizeOf(Slot([40]u8))));
}

test "value queues: FIFO, laps, unique indices, any payload" {
    const P = struct { a: u64, b: u64, c: ?*anyopaque, d: ?i32 };

    inline for (.{ SPMCOf(P, 16), MPSCOf(P, 16), MPMCOf(P, 16), MPMCOf(P, 4), MPMCOf(P, 256) }) |Q| {
        var q: Q = .init();
        const n = q.capacity();
        try std.testing.expect(q.pop() == null);

        var seen = try std.testing.allocator.alloc(bool, n);
        defer std.testing.allocator.free(seen);
        @memset(seen, false);

        for (0..n) |i| {
            const idx = q.push(.{ .a = i, .b = ~@as(u64, i), .c = null, .d = @intCast(i) }).?;
            try std.testing.expect(idx < n and !seen[idx]);
            seen[idx] = true;
        }
        try std.testing.expect(q.push(.{ .a = 0, .b = 0, .c = null, .d = null }) == null);

        for (0..n) |i| {
            const d = q.pop().?;
            try std.testing.expectEqual(@as(u64, i), d.entry.a);
            try std.testing.expectEqual(~@as(u64, i), d.entry.b);
            try std.testing.expectEqual(@as(?i32, @intCast(i)), d.entry.d);
        }
        try std.testing.expect(q.pop() == null);

        // 0 is a legal payload value for `...Of` queues, many laps
        for (0..n * 9 + 3) |i| {
            _ = q.push(.{ .a = i, .b = ~@as(u64, i), .c = null, .d = null }).?;
            const d = q.pop().?;
            try std.testing.expectEqual(@as(u64, i), d.entry.a);
        }
    }
}

test "MPMC threaded: every entry popped exactly once" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const Q = MPMC(64);
    const producers = 4;
    const consumers = 4;
    const per_producer = 20_000;
    const total = producers * per_producer;

    const H = struct {
        fn produce(q: *Q, base: usize) void {
            var v = base + 1;
            const end = base + per_producer;
            while (v <= end) {
                if (q.push(v) != null) v += 1 else atomic.spinLoopHint();
            }
        }

        fn consume(q: *Q, count: *atomic.Value(usize), sum: *atomic.Value(u64)) void {
            while (count.load(.monotonic) < total) {
                if (q.pop()) |d| {
                    _ = sum.fetchAdd(d.entry, .monotonic);
                    _ = count.fetchAdd(1, .monotonic);
                } else atomic.spinLoopHint();
            }
        }
    };

    var q: Q = .init();
    var count = atomic.Value(usize).init(0);
    var sum = atomic.Value(u64).init(0);

    var threads: [producers + consumers]std.Thread = undefined;
    for (0..consumers) |i| threads[i] = try std.Thread.spawn(.{}, H.consume, .{ &q, &count, &sum });
    for (0..producers) |i| threads[consumers + i] = try std.Thread.spawn(.{}, H.produce, .{ &q, i * per_producer });
    for (threads) |t| t.join();

    // Values are 1..total exactly once each => sum is total*(total+1)/2.
    try std.testing.expectEqual(@as(usize, total), count.load(.monotonic));
    try std.testing.expectEqual(@as(u64, total) * (total + 1) / 2, sum.load(.monotonic));
}

test "MPMCOf threaded: multi-word payload is never torn" {
    if (builtin.single_threaded) return error.SkipZigTest;

    // `a ^ b == mask` and `c == a + 1` must hold in every popped value, which
    // fails if a consumer ever observes half-written or stale payload words
    const P = struct { a: u64, b: u64, c: u64 };
    const Q = MPMCOf(P, 32);
    const producers = 3;
    const consumers = 3;
    const per_producer = 30_000;
    const total = producers * per_producer;
    const mask: u64 = 0xA5A5_A5A5_5A5A_5A5A;

    const H = struct {
        fn produce(q: *Q, base: u64) void {
            var v = base + 1;
            const end = base + per_producer;
            while (v <= end) {
                if (q.push(.{ .a = v, .b = v ^ mask, .c = v + 1 }) != null) v += 1 else atomic.spinLoopHint();
            }
        }

        fn consume(q: *Q, count: *atomic.Value(usize), sum: *atomic.Value(u64), bad: *atomic.Value(usize)) void {
            while (count.load(.monotonic) < total) {
                if (q.pop()) |d| {
                    const p = d.entry;
                    if ((p.a ^ p.b) != mask or p.c != p.a + 1) _ = bad.fetchAdd(1, .monotonic);
                    _ = sum.fetchAdd(p.a, .monotonic);
                    _ = count.fetchAdd(1, .monotonic);
                } else atomic.spinLoopHint();
            }
        }
    };

    var q: Q = .init();
    var count = atomic.Value(usize).init(0);
    var sum = atomic.Value(u64).init(0);
    var bad = atomic.Value(usize).init(0);

    var threads: [producers + consumers]std.Thread = undefined;
    for (0..consumers) |i| threads[i] = try std.Thread.spawn(.{}, H.consume, .{ &q, &count, &sum, &bad });
    for (0..producers) |i| threads[consumers + i] = try std.Thread.spawn(.{}, H.produce, .{ &q, @as(u64, i) * per_producer });
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(usize, 0), bad.load(.monotonic));
    try std.testing.expectEqual(@as(usize, total), count.load(.monotonic));
    try std.testing.expectEqual(@as(u64, total) * (total + 1) / 2, sum.load(.monotonic));
}

test "MPSCOf threaded: single consumer sees per-producer FIFO" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const P = struct { who: u32, seq: u32 };
    const Q = MPSCOf(P, 64);
    const producers = 4;
    const per_producer = 25_000;

    const H = struct {
        fn produce(q: *Q, who: u32) void {
            var s: u32 = 0;
            while (s < per_producer) {
                if (q.push(.{ .who = who, .seq = s }) != null) s += 1 else atomic.spinLoopHint();
            }
        }
    };

    var q: Q = .init();
    var threads: [producers]std.Thread = undefined;
    for (0..producers) |i| threads[i] = try std.Thread.spawn(.{}, H.produce, .{ &q, @as(u32, @intCast(i)) });

    var next: [producers]u32 = @splat(0);
    var got: usize = 0;
    while (got < producers * per_producer) {
        if (q.pop()) |d| {
            try std.testing.expectEqual(next[d.entry.who], d.entry.seq); // FIFO per producer
            next[d.entry.who] += 1;
            got += 1;
        } else atomic.spinLoopHint();
    }
    for (threads) |t| t.join();
}
