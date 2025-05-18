//! # App Interrupt Signal Handler Module
//! 
//! - Provides a set of utilities for interrupt register and participants
//!
//! NOTE: Only the detached threads (worker) are eligible to participate!

const std = @import("std");
const fmt = std.fmt;
const log = std.log;
const time = std.time;
const debug = std.debug;
const linux = std.os.linux;


const SingletonObject = struct {
    signal: i32,     // External user interrupt signal
    participant: i32 // Internal participants response
};

var so: ?SingletonObject = null;

const Self = @This();

pub fn init() !void {
    if (Self.so != null) @panic("Initialize Only Once Per Process!");
    Self.so = .{.signal = 0, .participant = 0};
}

/// # Returns Internal Static Object
pub fn iso() *SingletonObject { return &Self.so.?; }

pub fn register(sig: i32) callconv(.C) void {
    const fmt_str = "has been issued! Shutting down...";
    switch (sig) {
        2 => log.info("[CTRL + C] {s}", .{fmt_str}),
        15 => log.info("[SIGTERM] {s}", .{fmt_str}),
        else => @panic("Encountered an Unknown Signal")
    }

    const sop = Self.iso();
    sop.signal = sig;
}

/// # Graceful App Shutdown
/// - `res` - Should always be equal to the participants of the signal
/// - `WARNING` - Incorrect participant response will create an infinite loop!
pub fn terminate(cond: std.Thread.Condition, res: i64) void {
    std.debug.print("Captured signal {d}\n", .{res});
    cond.broadcast();
    const sop = Self.iso();

    if (sop.signal > 0) {
        while(true) {
            if (sop.participant == res) {
                log.info("Gracefully Shutdown.", .{});
                break;
            }
            else time.sleep(time.ns_per_ms * 500);
        }
    }
}

/// # OS Specific Signal Functionalities
pub const Linux = struct {
    /// # Examine And Change Signal Action
    /// - `Maskable`: signals can be changed or ignored (e.g., Ctrl+C)
    /// - `Non-Maskable`: signals can't be changed or ignored (e.g., KILL)
    ///
    /// **Remarks:** Non-Maskable signals only occur for non-recoverable errors.
    /// See - https://man7.org/linux/man-pages/man2/sigaction.2.html
    pub fn signal(sig: u6, handler: *const fn (i32) callconv(.c) void) void {
        const sig_ign = linux.Sigaction {
            .handler = .{.handler = handler},
            .mask = linux.empty_sigset,
            .flags = 0,
        };

        debug.assert(linux.sigaction(sig, &sig_ign, null) == 0);
    }

    /// # Masks Given Sigset
    /// **Remarks:** Prevents default signal disposition for the given sigset
    pub fn signalMask(sigs: []u6) linux.sigset_t {
        var sigset: linux.sigset_t = linux.empty_sigset;
        for (sigs) |sig| linux.sigaddset(&sigset, sig);

        if (linux.sigprocmask(linux.SIG.BLOCK, &sigset, null) != 0) {
            @panic("Failed to set sigprocmask on sigset!");
        }

        return sigset;
    }

    /// # User Defined Signal
    /// - Sends a signal to the calling process or thread
    ///
    /// **Remarks:** Alternative to `raise(3)` syscall. As of now `raise(3)`
    /// in `std.posix` fails to send signal across thread boundaries in zig.
    pub fn signalEmit(sig: u6) void {
        const pid = linux.getpid();
        debug.assert(linux.kill(pid, sig) == 0);
    }
};
