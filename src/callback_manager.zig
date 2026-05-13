const std = @import("std");
const builtin = @import("builtin");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");

pub const CallbackExceptionContext = struct {
    module_name: [:0]const u8,
    module_ptr: *python_c.PyObject,

    callback_ptr: ?PyObject,
    exc_message: [:0]const u8
};

pub const ExceptionHandler = *const fn (anyerror, ?*anyopaque, ?CallbackExceptionContext) anyerror!void;

pub const DebugState = struct {
    slow_callback_duration: f64,
};

pub const WarningHandler = *const fn (duration: f64, ?CallbackExceptionContext, ?*anyopaque) void;

pub const CallbackData = struct {
    io_uring_res: i32 = 0,
    io_uring_err: std.os.linux.E = .SUCCESS,

    user_data: ?*anyopaque,

    exception_context: ?CallbackExceptionContext,
    cancelled: bool = false,

    traverse: ?*const fn (ptr: ?*anyopaque, visit: ?*anyopaque, arg: ?*anyopaque) c_int = null,
};

pub const GenericCallback = *const fn (data: *const CallbackData) anyerror!void;
pub const GenericCleanUpCallback = *const fn (user_data: ?*anyopaque) void;

pub const Callback = struct {
    func: GenericCallback,
    cleanup: ?GenericCleanUpCallback,
    data: CallbackData,
    executed: bool = false
};

pub fn RingBuffer(comptime N: usize) type {
    return struct {
        const Self = @This();
        pub const BitSet = std.bit_set.StaticBitSet(N);

        callbacks: [N]Callback,
        read_idx: usize,
        write_idx: usize,
        executed: BitSet,

        pub fn init(self: *Self) void {
            self.read_idx = 0;
            self.write_idx = 0;
            self.executed = BitSet.initEmpty();
        }

        pub inline fn is_full(self: *const Self) bool {
            return (@atomicLoad(usize, &self.write_idx, .acquire) - @atomicLoad(usize, &self.read_idx, .acquire)) == N;
        }

        pub inline fn is_empty(self: *const Self) bool {
            return @atomicLoad(usize, &self.read_idx, .acquire) == @atomicLoad(usize, &self.write_idx, .acquire);
        }

        pub inline fn count(self: *const Self) usize {
            return @atomicLoad(usize, &self.write_idx, .acquire) - @atomicLoad(usize, &self.read_idx, .acquire);
        }

        pub fn try_push(self: *Self, callback: Callback) bool {
            const w_idx = @atomicLoad(usize, &self.write_idx, .acquire);
            const r_idx = @atomicLoad(usize, &self.read_idx, .acquire);
            if ((w_idx - r_idx) == N) return false;
            
            const idx = w_idx % N;
            self.callbacks[idx] = callback;
            self.executed.unset(idx);
            
            @atomicStore(usize, &self.write_idx, w_idx + 1, .release);
            return true;
        }

        pub fn push(self: *Self, callback: Callback) void {
            if (!self.try_push(callback)) {
                @panic("RingBuffer overflow");
            }
        }

        pub fn next(self: *Self) ?*Callback {
            const r_idx = @atomicLoad(usize, &self.read_idx, .acquire);
            const w_idx = @atomicLoad(usize, &self.write_idx, .acquire);
            if (r_idx == w_idx) return null;
            
            const idx = r_idx % N;
            return &self.callbacks[idx];
        }

        pub inline fn consume(self: *Self) void {
            const r_idx = @atomicLoad(usize, &self.read_idx, .acquire);
            const idx = r_idx % N;
            self.executed.set(idx);
            @atomicStore(usize, &self.read_idx, r_idx + 1, .release);
        }

        pub fn reset(self: *Self) void {
            @atomicStore(usize, &self.read_idx, 0, .release);
            @atomicStore(usize, &self.write_idx, 0, .release);
            self.executed = BitSet.initEmpty();
        }

        pub fn traverse(self: *const Self, visit: python_c.visitproc, arg: ?*anyopaque) c_int {
            const r_idx = @atomicLoad(usize, &self.read_idx, .acquire);
            const w_idx = @atomicLoad(usize, &self.write_idx, .acquire);
            
            var i = r_idx;
            while (i < w_idx) : (i += 1) {
                const idx = i % N;
                if (self.executed.isSet(idx)) continue;

                const callback = &self.callbacks[idx];
                if (callback.data.traverse) |t| {
                    const vret = t(callback.data.user_data, @constCast(@ptrCast(visit)), arg);
                    if (vret != 0) return vret;
                }

                if (callback.data.exception_context) |ctx| {
                    const vret1 = visit.?(@ptrCast(ctx.module_ptr), arg);
                    if (vret1 != 0) return vret1;
                    if (ctx.callback_ptr) |cp| {
                        const vret2 = visit.?(@ptrCast(cp), arg);
                        if (vret2 != 0) return vret2;
                    }
                }
            }
            return 0;
        }
    };
}

pub const DynamicRingBuffer = struct {
    const Self = @This();

    callbacks: []Callback,
    executed: []bool,
    capacity: usize,
    read_idx: usize,
    write_idx: usize,

    pub fn init(self: *Self, allocator: std.mem.Allocator, capacity: usize) !void {
        self.callbacks = try allocator.alloc(Callback, capacity);
        errdefer allocator.free(self.callbacks);
        self.executed = try allocator.alloc(bool, capacity);
        @memset(self.executed, false);
        self.capacity = capacity;
        self.read_idx = 0;
        self.write_idx = 0;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.callbacks);
        allocator.free(self.executed);
        self.* = undefined;
    }

    pub inline fn is_full(self: *const Self) bool {
        return (@atomicLoad(usize, &self.write_idx, .acquire) - @atomicLoad(usize, &self.read_idx, .acquire)) == self.capacity;
    }

    pub inline fn is_empty(self: *const Self) bool {
        return @atomicLoad(usize, &self.read_idx, .acquire) == @atomicLoad(usize, &self.write_idx, .acquire);
    }

    pub inline fn count(self: *const Self) usize {
        return @atomicLoad(usize, &self.write_idx, .acquire) - @atomicLoad(usize, &self.read_idx, .acquire);
    }

    pub fn try_push(self: *Self, callback: Callback) bool {
        const w_idx = @atomicLoad(usize, &self.write_idx, .acquire);
        const r_idx = @atomicLoad(usize, &self.read_idx, .acquire);
        if ((w_idx - r_idx) == self.capacity) return false;

        const idx = w_idx % self.capacity;
        self.callbacks[idx] = callback;
        self.executed[idx] = false;

        @atomicStore(usize, &self.write_idx, w_idx + 1, .release);
        return true;
    }

    pub fn push(self: *Self, callback: Callback) void {
        if (!self.try_push(callback)) {
            @panic("RingBuffer overflow");
        }
    }

    pub fn next(self: *Self) ?*Callback {
        const r_idx = @atomicLoad(usize, &self.read_idx, .acquire);
        const w_idx = @atomicLoad(usize, &self.write_idx, .acquire);
        if (r_idx == w_idx) return null;

        const idx = r_idx % self.capacity;
        return &self.callbacks[idx];
    }

    pub inline fn consume(self: *Self) void {
        const r_idx = @atomicLoad(usize, &self.read_idx, .acquire);
        const idx = r_idx % self.capacity;
        self.executed[idx] = true;
        @atomicStore(usize, &self.read_idx, r_idx + 1, .release);
    }

    pub fn reset(self: *Self) void {
        @memset(self.executed, false);
        @atomicStore(usize, &self.read_idx, 0, .release);
        @atomicStore(usize, &self.write_idx, 0, .release);
    }

    pub fn traverse(self: *const Self, visit: python_c.visitproc, arg: ?*anyopaque) c_int {
        const r_idx = @atomicLoad(usize, &self.read_idx, .acquire);
        const w_idx = @atomicLoad(usize, &self.write_idx, .acquire);

        var i = r_idx;
        while (i < w_idx) : (i += 1) {
            const idx = i % self.capacity;
            if (self.executed[idx]) continue;

            const callback = &self.callbacks[idx];
            if (callback.data.traverse) |t| {
                const vret = t(callback.data.user_data, @constCast(@ptrCast(visit)), arg);
                if (vret != 0) return vret;
            }

            if (callback.data.exception_context) |ctx| {
                const vret1 = visit.?(@ptrCast(ctx.module_ptr), arg);
                if (vret1 != 0) return vret1;
                if (ctx.callback_ptr) |cp| {
                    const vret2 = visit.?(@ptrCast(cp), arg);
                    if (vret2 != 0) return vret2;
                }
            }
        }
        return 0;
    }
};

pub const ReadyTasksQueueCapacity = 524288;

pub fn execute_ring_buffer(
    comptime N: usize,
    ring: *RingBuffer(N),
    comptime exception_handler: ?ExceptionHandler,
    exception_handler_data: ?*anyopaque,
    warning_handler: ?WarningHandler,
    debug_state: ?*const DebugState
) !usize {
    if (ring.is_empty()) return 0;

    var callbacks_executed: usize = 0;
    var yield_counter: usize = 0;

    while (ring.next()) |callback| {
        if (debug_state != null) {
            if (callback.data.exception_context) |ctx| {
                python_c.py_incref(ctx.module_ptr);
                if (ctx.callback_ptr) |cp| python_c.py_incref(cp);
            }
        }

        const start_time = if (debug_state != null) std.time.nanoTimestamp() else 0;

        callback.func(&callback.data) catch |err| {
            // Check for fatal exceptions BEFORE calling the handler
            if (err == error.PythonError) {
                if (python_c.PyErr_Occurred()) |exc| {
                    if (python_c.PyErr_GivenExceptionMatches(exc, python_c.PyExc_KeyboardInterrupt.?) != 0 or
                        python_c.PyErr_GivenExceptionMatches(exc, python_c.PyExc_SystemExit.?) != 0) {
                        return err;
                    }
                }
            }

            defer {
                if (callback.cleanup) |cleanup| {
                    cleanup(callback.data.user_data);
                }
                ring.consume();
                callbacks_executed += 1;
            }

            const handler = exception_handler orelse return err;
            handler(err, exception_handler_data, callback.data.exception_context) catch |err2| {
                return err2;
            };
            continue;
        };

        if (debug_state) |ds| {
            const end_time = std.time.nanoTimestamp();
            const duration = @as(f64, @floatFromInt(end_time - start_time)) / 1e9;
            if (duration >= ds.slow_callback_duration) {
                if (warning_handler) |wh| {
                    wh(duration, callback.data.exception_context, exception_handler_data);
                }
            }
            if (callback.data.exception_context) |ctx| {
                python_c.py_decref(ctx.module_ptr);
                if (ctx.callback_ptr) |cp| python_c.py_decref(cp);
            }
        }

        ring.consume();
        callbacks_executed += 1;

        yield_counter += 1;
        if (!builtin.is_test and yield_counter == 64) {
            yield_counter = 0;
            const ts = python_c.PyEval_SaveThread();
            _ = python_c.PyEval_RestoreThread(ts);
        }
    }

    return callbacks_executed;
}

pub fn release_ring_buffer(
    comptime N: usize,
    ring: *RingBuffer(N),
) void {
    while (ring.next()) |callback| {
        callback.data.cancelled = true;
        _ = callback.func(&callback.data) catch {};
        ring.consume();
    }
}

pub fn execute_dynamic_ring_buffer(
    ring: *DynamicRingBuffer,
    comptime exception_handler: ?ExceptionHandler,
    exception_handler_data: ?*anyopaque,
    warning_handler: ?WarningHandler,
    debug_state: ?*const DebugState
) !usize {
    if (ring.is_empty()) return 0;

    var callbacks_executed: usize = 0;
    var yield_counter: usize = 0;

    while (ring.next()) |callback| {
        if (debug_state != null) {
            if (callback.data.exception_context) |ctx| {
                python_c.py_incref(ctx.module_ptr);
                if (ctx.callback_ptr) |cp| python_c.py_incref(cp);
            }
        }

        const start_time = if (debug_state != null) std.time.nanoTimestamp() else 0;

        callback.func(&callback.data) catch |err| {
            if (err == error.PythonError) {
                if (python_c.PyErr_Occurred()) |exc| {
                    if (python_c.PyErr_GivenExceptionMatches(exc, python_c.PyExc_KeyboardInterrupt.?) != 0 or
                        python_c.PyErr_GivenExceptionMatches(exc, python_c.PyExc_SystemExit.?) != 0) {
                        return err;
                    }
                }
            }

            defer {
                if (callback.cleanup) |cleanup| {
                    cleanup(callback.data.user_data);
                }
                ring.consume();
                callbacks_executed += 1;
            }

            const handler = exception_handler orelse return err;
            handler(err, exception_handler_data, callback.data.exception_context) catch |err2| {
                return err2;
            };
            continue;
        };

        if (debug_state) |ds| {
            const end_time = std.time.nanoTimestamp();
            const duration = @as(f64, @floatFromInt(end_time - start_time)) / 1e9;
            if (duration >= ds.slow_callback_duration) {
                if (warning_handler) |wh| {
                    wh(duration, callback.data.exception_context, exception_handler_data);
                }
            }
            if (callback.data.exception_context) |ctx| {
                python_c.py_decref(ctx.module_ptr);
                if (ctx.callback_ptr) |cp| python_c.py_decref(cp);
            }
        }

        ring.consume();
        callbacks_executed += 1;

        yield_counter += 1;
        if (!builtin.is_test and yield_counter == 64) {
            yield_counter = 0;
            const ts = python_c.PyEval_SaveThread();
            _ = python_c.PyEval_RestoreThread(ts);
        }
    }

    return callbacks_executed;
}

pub fn release_dynamic_ring_buffer(
    ring: *DynamicRingBuffer,
) void {
    while (ring.next()) |callback| {
        callback.data.cancelled = true;
        _ = callback.func(&callback.data) catch {};
        ring.consume();
    }
}

// ---- Tests ----

fn test_callback(data: *const CallbackData) !void {
    if (data.cancelled) return;

    const executed_ptr: *usize = @alignCast(@ptrCast(data.user_data.?));
    executed_ptr.* += 1;
    return;
}

fn test_callback2(_: *const CallbackData) !void {
    return error.Test;
}

fn test_exception_handler(err: anyerror, data: ?*anyopaque, _: ?CallbackExceptionContext) !void {
    try std.testing.expectEqual(error.Test, err);

    const executed_ptr: *usize = @alignCast(@ptrCast(data.?));
    executed_ptr.* += 1;
}

test "RingBuffer basic properties" {
    const RB = RingBuffer(8);
    var rb: RB = undefined;
    rb.init();

    try std.testing.expect(rb.is_empty());
    try std.testing.expect(!rb.is_full());
    try std.testing.expectEqual(@as(usize, 0), rb.count());

    @atomicStore(usize, &rb.write_idx, 4, .release);
    try std.testing.expect(!rb.is_empty());
    try std.testing.expect(!rb.is_full());
    try std.testing.expectEqual(@as(usize, 4), rb.count());

    @atomicStore(usize, &rb.write_idx, 8, .release);
    try std.testing.expect(rb.is_full());
    try std.testing.expectEqual(@as(usize, 8), rb.count());

    @atomicStore(usize, &rb.read_idx, 4, .release);
    try std.testing.expect(!rb.is_full());
    try std.testing.expectEqual(@as(usize, 4), rb.count());

    @atomicStore(usize, &rb.read_idx, 8, .release);
    try std.testing.expect(rb.is_empty());
    try std.testing.expectEqual(@as(usize, 0), rb.count());
}

test "RingBuffer push and execute" {
    const RB = RingBuffer(4);
    var rb: RB = undefined;
    rb.init();

    var executed: usize = 0;
    const callback = Callback{
        .func = &test_callback,
        .cleanup = null,
        .data = .{
            .user_data = &executed,
            .exception_context = null
        }
    };

    try std.testing.expect(rb.try_push(callback));
    try std.testing.expectEqual(@as(usize, 1), rb.count());
    try std.testing.expect(!rb.executed.isSet(0));

    try std.testing.expect(rb.try_push(callback));
    try std.testing.expect(rb.try_push(callback));
    try std.testing.expect(rb.try_push(callback));
    try std.testing.expect(!rb.try_push(callback)); // full

    try std.testing.expectEqual(@as(usize, 4), rb.count());

    const executed_count = try execute_ring_buffer(4, &rb, null, null, null, null);
    try std.testing.expectEqual(@as(usize, 4), executed_count);
    try std.testing.expectEqual(@as(usize, 4), executed);
    try std.testing.expect(rb.is_empty());

    rb.reset();
    try std.testing.expectEqual(@as(usize, 0), rb.read_idx);
    try std.testing.expectEqual(@as(usize, 0), rb.write_idx);
    try std.testing.expectEqual(@as(usize, 0), rb.executed.count());
}

test "RingBuffer handle exceptions" {
    const RB = RingBuffer(4);
    var rb: RB = undefined;
    rb.init();

    var executed: usize = 0;
    var exceptions: usize = 0;

    const cb1 = Callback{
        .func = &test_callback,
        .cleanup = null,
        .data = .{ .user_data = &executed, .exception_context = null }
    };
    const cb2 = Callback{
        .func = &test_callback2,
        .cleanup = null,
        .data = .{ .user_data = null, .exception_context = null }
    };

    rb.push(cb1);
    rb.push(cb2);
    rb.push(cb1);

    const executed_count = try execute_ring_buffer(4, &rb, test_exception_handler, &exceptions, null, null);
    try std.testing.expectEqual(@as(usize, 3), executed_count);
    try std.testing.expectEqual(@as(usize, 2), executed);
    try std.testing.expectEqual(@as(usize, 1), exceptions);
}

fn mock_visit(obj: ?*python_c.PyObject, arg: ?*anyopaque) callconv(.c) c_int {
    _ = obj;
    const count_ptr: *usize = @ptrCast(@alignCast(arg));
    count_ptr.* += 1;
    return 0;
}

test "RingBuffer traverse" {
    const RB = RingBuffer(4);
    var rb: RB = undefined;
    rb.init();

    var visit_count: usize = 0;
    var dummy_obj: usize = 0xDEADBEEF;

    const callback = Callback{
        .func = &test_callback,
        .cleanup = null,
        .data = .{
            .user_data = null,
            .exception_context = .{
                .module_name = "test",
                .module_ptr = @ptrCast(&dummy_obj),
                .callback_ptr = null,
                .exc_message = "error",
            }
        }
    };

    rb.push(callback);
    rb.push(callback);

    _ = rb.traverse(mock_visit, &visit_count);
    try std.testing.expectEqual(@as(usize, 2), visit_count);

    // Consume one
    _ = rb.next();
    rb.consume();

    visit_count = 0;
    _ = rb.traverse(mock_visit, &visit_count);
    try std.testing.expectEqual(@as(usize, 1), visit_count);
}
