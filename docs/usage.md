# How to use

First, import Saturn on your Zig source file.

```zig
const saturn = @import("saturn");
```

Now, initialize following types with appropriate parameters.

```zig
pub const Signal = saturn.Signal;
pub const Executor = saturn.TaskExecutor(1024);
pub const AsyncIo = saturn.AsyncIo(1024, Executor);
```

**Remarks:** Make sure to check code comments for each of these types.

## Signal Setup

For handling app exit signals, paste the following code in your `main.zig` file.

```zig
try Signal.init();
Signal.Linux.signal(std.os.linux.SIG.INT, Signal.register);
Signal.Linux.signal(std.os.linux.SIG.TERM, Signal.register);
```

Signal is a singleton instance, therefore you can look out for `Signal.iso().signal` to detect the above signals from any where in your codebase.

Use, `Signal.terminate(Executor);` to pass exit signal to your worker threads.

## Executor Setup

Paste the following code in your `main.zig` file.

```zig
try Executor.init(null, true);
defer Executor.deinit();
```

The above snippet creates and runs a thread pool using available logical CPU cores. You can specify the number of workers via the first `init()` argument.

**Remarks:** If debug mode is **false**, the executor uses `malloc` for internal bookkeeping.

### Submitting a Task to the Executor

To run a task, submit it using `Executor.submit()`. See its comments for details. Once submitted, the executor will automatically execute it.

**Remarks:** `Executor.submit()` supports both CPU-bound and AIO-bound tasks.

## Async I/O Setup

Paste the following code in your `main.zig` file.

```zig
try AsyncIo.init(true);
defer AsyncIo.deinit();
```

**Remarks:** If debug mode is **false**, the I/O executor uses `malloc` for internal bookkeeping.

To run the even loop, paste the following snippet at the end of your `main.zig`.

```zig
try AsyncIo.eventLoop(0, .{});
```

**Remarks:** Once called, the I/O event loop will run on the main thread!

### Submitting a I/O to the Executor

To run an I/O task, call appropriate I/O functions. See `AsyncIo` code comments for details.

**CAUTION:** Asynchronous I/O with a lock-free executor can be tricky. Proceed with care and confidence in your implementation.