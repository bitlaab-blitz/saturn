//! # Multi-Threaded Queue Module - v1.0.0
//! - Lock-free and wait-free multi-producer and/or multi-consumer queues
//! - Provides thread synchronization for highly multi-threaded workloads
//!
//! **Remarks:** on MP and/or MC part of the queue:
//! - Sequential push and/or pop from the ring is not guaranteed
//! - The head and tail cursors are not responsible for any synchronization
//! - Cells will be fragmented in a busy system, but the mapping is guaranteed
//!
//! **Remarks:** on SP and/or SC part of the queue:
//! - Make sure; push and/or pop from the ring is always single threaded
//! - Any accidental multi-threaded access will cause undefined behavior
//!
//! **Cautionary Info:**
//! CAS (weak) can fail spuriously. Means they might fail even when the expected
//! value matches the current value in memory. Spurious failures allow more
//! efficient hardware implementations and reduce contention. On success, value
//! at the memory location matched the expected value, and the exchange will be
//! performed atomically. The concept of _false success_ does not exist because
//! it would violate the atomicity and correctness guarantees of CAS operation!

const std = @import("std");
const math = std.math;
const debug = std.debug;


const Data = struct { index: usize, entry: usize };

/// # Single-Producer Multi-Consumer Queue
/// - `entries` - Must be the power of two e.g., `512`, `1024`, etc.
pub fn SPMC(comptime entries: u32) type {
    debug.assert(math.isPowerOfTwo(entries));

    return struct {
        head: u32 = 0, // cursor - push
        tail: u32 = 0, // cursor - pop
        ring: [entries]usize = [_]usize {0} ** entries,

        const depth = entries;
        const mask = entries - 1;

        const ORD = .monotonic;

        const Self = @This();

        pub fn init() Self { return .{}; }

        pub fn capacity(self: *const Self) u32 { _ = self; return Self.depth; }

        /// # Returns the Queued Position of the Entry
        pub fn push(self: *Self, entry: usize) ?usize {
            for (0..Self.depth) |_| {
                const index = self.head & Self.mask;
                if (self.ring[index] == 0) {
                    self.ring[index] = entry;
                    return index;
                }

                self.head +%= 1; // Next try or push
            }

            return null; // Queue is full
        }

        /// # Extracts the Queued Entry
        pub fn pop(self: *Self) ?Data {
            var max_retry = Self.depth;

            while (max_retry > 0) : (max_retry -= 1) {
                const index = self.tail & Self.mask;
                const ptr = &self.ring[index];

                if (@cmpxchgWeak(usize, ptr, 0, 0, ORD, ORD)) |entry| {
                    if (entry == 0) continue;
                    // Ensures `entry` isn't popped by other since last check ↖
                    if (@cmpxchgWeak(usize, ptr, entry, 0, ORD, ORD) == null) {
                        return .{.index = index, .entry = entry};
                    }
                }

                self.tail +%= 1; // Next try or pop
            }

            return null; // Queue is empty
        }
    };
}

/// # Multi-Producer Single-Consumer Queue
/// - `entries` - Must be the power of two e.g., `512`, `1024`, etc.
pub fn MPSC(comptime entries: u32) type {
    debug.assert(math.isPowerOfTwo(entries));

    return struct {
        head: u32 = 0, // cursor - push
        tail: u32 = 0, // cursor - pop
        ring: [entries]usize = [_]usize {0} ** entries,

        const depth = entries;
        const mask = entries - 1;

        const ORD = .monotonic;

        const Self = @This();

        pub fn init() Self { return .{}; }

        pub fn capacity(self: *const Self) u32 { _ = self; return Self.depth; }

        /// # Returns the Queued Position of the Entry
        pub fn push(self: *Self, entry: usize) ?usize {
            for (0..Self.depth) |_| {
                const ptr = &self.ring[self.head & Self.mask];
                if (@cmpxchgWeak(usize, ptr, 0, entry, ORD, ORD) == null) {
                    return self.head & Self.mask;
                }

                self.head +%= 1; // Next try or push
            }

            return null; // Queue is full
        }

        /// # Extracts the Queued Entry
        pub fn pop(self: *Self) ?Data {
            var max_retry = Self.depth;

            while (max_retry > 0) : (max_retry -= 1) {
                const index = self.tail & Self.mask;
                const entry = self.ring[index];

                if (entry > 0) {
                    self.ring[index] = 0;
                    return .{.index = index, .entry = entry};
                }

                self.tail +%= 1; // Next pop
            }

            return null; // Queue is empty
        }
    };
}

/// # Multi-Producer Multi-Consumer Queue
/// - `entries` - Must be the power of two e.g., `512`, `1024`, etc.
pub fn MPMC(comptime entries: u32) type {
    debug.assert(math.isPowerOfTwo(entries));

    return struct {
        head: u32 = 0, // cursor - push
        tail: u32 = 0, // cursor - pop
        ring: [entries]usize = [_]usize {0} ** entries,

        const depth = entries;
        const mask = entries - 1;

        const ORD = .monotonic;

        const Self = @This();

        pub fn init() Self { return .{}; }

        pub fn capacity(self: *const Self) u32 { _ = self; return Self.depth; }

        /// # Returns the Queued Position of the Entry
        pub fn push(self: *Self, entry: usize) ?usize {
            for (0..Self.depth) |_| {
                const ptr = &self.ring[self.head & Self.mask];
                if (@cmpxchgWeak(usize, ptr, 0, entry, ORD, ORD) == null) {
                    return self.head & Self.mask;
                }

                self.head +%= 1; // Next try or push
            }

            return null; // Queue is full
        }

        /// # Extracts the Queued Entry
        pub fn pop(self: *Self) ?Data {
            var max_retry = Self.depth;

            while (max_retry > 0) : (max_retry -= 1) {
                const index = self.tail & Self.mask;
                const ptr = &self.ring[index];

                if (@cmpxchgWeak(usize, ptr, 0, 0, ORD, ORD)) |entry| {
                    if (entry == 0) continue;
                    // Ensures `entry` isn't popped by other since last check ↖
                    if (@cmpxchgWeak(usize, ptr, entry, 0, ORD, ORD) == null) {
                        return .{.index = index, .entry = entry};
                    }
                }

                self.tail +%= 1; // Next try or pop
            }

            return null; // Queue is empty
        }
    };
}
