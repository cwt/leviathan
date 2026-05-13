const std = @import("std");
const builtin = @import("builtin");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;
const PyEval_SaveThread = python_c.PyEval_SaveThread;
const PyEval_RestoreThread = python_c.PyEval_RestoreThread;

const utils = @import("utils");
const lock = @import("../utils/lock.zig");

const CallbackManager = @import("callback_manager");
const Loop = @import("main.zig");
const Future = @import("../future/main.zig");

fn slow_callback_warning_handler(duration: f64, context: ?CallbackManager.CallbackExceptionContext, data: ?*anyopaque) void {
    const loop_obj: *Loop.Python.LoopObject = @alignCast(@ptrCast(data.?));
    const loop_data = utils.get_data_ptr(Loop, loop_obj);

    const msg_allocated = if (context) |ctx|
        std.fmt.allocPrint(loop_data.allocator, "Executing callback took {d:.6} seconds (context: {s})", .{ duration, ctx.exc_message }) catch null
    else
        std.fmt.allocPrint(loop_data.allocator, "Executing callback took {d:.6} seconds", .{ duration }) catch null;
    
    const msg = msg_allocated orelse "Executing callback took too long";
    defer if (msg_allocated) |m| loop_data.allocator.free(m);

    const context_dict = python_c.PyDict_New() orelse return;
    defer python_c.py_decref(context_dict);

    const py_msg = python_c.PyUnicode_FromStringAndSize(msg.ptr, @intCast(msg.len)) orelse return;
    defer python_c.py_decref(py_msg);
    _ = python_c.PyDict_SetItemString(context_dict, "message\x00", py_msg);

    if (context) |ctx| {
        _ = python_c.PyDict_SetItemString(context_dict, "module\x00", ctx.module_ptr);
        if (ctx.callback_ptr) |cp| {
            _ = python_c.PyDict_SetItemString(context_dict, "callback\x00", cp);
        }
    }

    const ret = python_c.PyObject_CallMethod(@ptrCast(loop_obj), "call_exception_handler\x00", "O\x00", context_dict) orelse {
        if (python_c.PyErr_Occurred()) |exc| {
            if (python_c.PyErr_GivenExceptionMatches(exc, python_c.PyExc_KeyboardInterrupt.?) != 0 or
                python_c.PyErr_GivenExceptionMatches(exc, python_c.PyExc_SystemExit.?) != 0) {
                return; // Can't return error from void function, but we shouldn't PyErr_Clear()
            }
        }
        python_c.PyErr_Clear();
        return;
    };
    python_c.py_decref(ret);
}

fn exception_handler(err: anyerror, data: ?*anyopaque, context: ?CallbackManager.CallbackExceptionContext) !void {
    const loop_obj: *Loop.Python.LoopObject = @alignCast(@ptrCast(data.?));
    
    const context_dict = python_c.PyDict_New() orelse return error.PythonError;
    defer python_c.py_decref(context_dict);

    const msg = if (context) |ctx| ctx.exc_message else "Exception in callback";
    const py_msg = python_c.PyUnicode_FromString(msg.ptr) orelse return error.PythonError;
    defer python_c.py_decref(py_msg);
    _ = python_c.PyDict_SetItemString(context_dict, "message\x00", py_msg);

    if (context) |ctx| {
        _ = python_c.PyDict_SetItemString(context_dict, "module\x00", ctx.module_ptr);
        if (ctx.callback_ptr) |cp| {
            _ = python_c.PyDict_SetItemString(context_dict, "callback\x00", cp);
        }
    }

    const py_err_name = @errorName(err);
    const py_err_obj = python_c.PyUnicode_FromString(py_err_name.ptr) orelse return error.PythonError;
    defer python_c.py_decref(py_err_obj);
    _ = python_c.PyDict_SetItemString(context_dict, "exception\x00", py_err_obj);

    const ret = python_c.PyObject_CallMethod(@ptrCast(loop_obj), "call_exception_handler\x00", "O\x00", context_dict) orelse {
        if (python_c.PyErr_Occurred()) |exc| {
            if (python_c.PyErr_GivenExceptionMatches(exc, python_c.PyExc_KeyboardInterrupt.?) != 0 or
                python_c.PyErr_GivenExceptionMatches(exc, python_c.PyExc_SystemExit.?) != 0) {
                return error.PythonError;
            }
        }
        python_c.PyErr_Clear();
        return;
    };
    python_c.py_decref(ret);
}

pub inline fn call_once(
    ready_queue: *CallbackManager.DynamicRingBuffer,
    _: usize,
    loop_obj: *Loop.Python.LoopObject
) !usize {
    const debug_state = CallbackManager.DebugState{ .slow_callback_duration = loop_obj.slow_callback_duration };

    const callbacks_executed = try CallbackManager.execute_dynamic_ring_buffer(
        ready_queue,
        if (builtin.is_test) null else &exception_handler,
        loop_obj,
        if (loop_obj.debug) &slow_callback_warning_handler else null,
        if (loop_obj.debug) &debug_state else null
    );
    if (callbacks_executed == 0) {
        ready_queue.reset();
    }

    return callbacks_executed;
}

fn execute_hooks(hooks: *Loop.HooksList) !void {
    var node = hooks.first;
    while (node) |n| {
        node = n.next;
        try n.data.func(&n.data.data);
    }
}

fn fetch_completed_tasks(
    self: *Loop,
    blocking_ready_tasks: []std.os.linux.io_uring_cqe,
    ready_queue: *CallbackManager.DynamicRingBuffer
) !void {
    for (blocking_ready_tasks) |cqe| {
        const user_data = cqe.user_data;
        if (user_data == 0) continue; // Timeout and cancel operations

        const err: std.os.linux.E = @call(.always_inline, std.os.linux.io_uring_cqe.err, .{cqe});
        const blocking_task: *Loop.Scheduling.IO.BlockingTask = @ptrFromInt(user_data);

        switch (blocking_task.data) {
            .callback => |*v| {
                v.data.io_uring_err = err;
                v.data.io_uring_res = cqe.res;

                blocking_task.check_result(err);
                if (!ready_queue.try_push(v.*)) return error.Overflow;
                self.reserved_slots -= 1;
            },
            .none => {}
        }

        blocking_task.deinit();
    }
}

fn poll_blocking_events(
    self: *Loop,
    mutex: *lock.Mutex,
    wait: bool,
    ready_queue: *CallbackManager.DynamicRingBuffer
) !void {
    const blocking_ready_tasks = self.io.blocking_ready_tasks;

    var nevents: u32 = undefined;
    while (true) {
        if (wait and ready_queue.is_empty()) {
            self.io.ring_blocked = true;
            mutex.unlock();
            defer {
                mutex.lock();
                self.io.ring_blocked = false;
            }

            const py_thread_state = PyEval_SaveThread();
            defer PyEval_RestoreThread(py_thread_state);

            nevents = self.io.ring.copy_cqes(blocking_ready_tasks, 1) catch |err| {
                if (err == error.SignalInterrupt) {
                    if (python_c.PyErr_Occurred() != null) return error.PythonError;
                    continue;
                }
                return err;
            };
        } else {
            nevents = self.io.ring.copy_cqes(blocking_ready_tasks, 0) catch |err| {
                if (err == error.SignalInterrupt) {
                    if (python_c.PyErr_Occurred() != null) return error.PythonError;
                    continue;
                }
                return err;
            };
        }
        break;
    }

    while (nevents > 0) {
        try fetch_completed_tasks(self, blocking_ready_tasks[0..nevents], ready_queue);

        if (nevents == blocking_ready_tasks.len) {
            nevents = try self.io.ring.copy_cqes(blocking_ready_tasks, 0);
        }else{
            break;
        }
    }
}

pub fn start(self: *Loop, loop_obj: *Loop.Python.LoopObject) !void {
    const mutex = &self.mutex;
    mutex.lock();
    defer mutex.unlock();

    if (!self.initialized) {
        python_c.raise_python_runtime_error("Loop is closed\x00");
        return error.PythonError;
    }

    if (self.stopping) {
        python_c.raise_python_runtime_error("Loop is stopping\x00");
        return error.PythonError;
    }

    if (self.running) {
        python_c.raise_python_runtime_error("Loop is already running\x00");
        return error.PythonError;
    }

    self.running = true;
    defer {
        self.running = false;
        self.stopping = false;
    }

    const ready_tasks_queue_max_capacity = self.ready_tasks_queue_max_capacity;

    var ready_tasks_queue_index = self.ready_tasks_queue_index;
    var wait_for_blocking_events: bool = false;
    while (!self.stopping) {
        if (loop_obj.owner_pid != std.os.linux.getpid()) break;

        const old_index = ready_tasks_queue_index;
        const ready_tasks_queue = &self.ready_tasks_queues[old_index];

        try poll_blocking_events(self, mutex, wait_for_blocking_events, ready_tasks_queue);

        ready_tasks_queue_index = 1 - ready_tasks_queue_index;
        self.ready_tasks_queue_index = ready_tasks_queue_index;

        mutex.unlock();
        defer mutex.lock();

        try execute_hooks(&self.check_hooks);

        const callbacks_executed = try call_once(
            ready_tasks_queue,
            ready_tasks_queue_max_capacity,
            loop_obj
        );

        try execute_hooks(&self.idle_hooks);
        try execute_hooks(&self.prepare_hooks);
        wait_for_blocking_events = (callbacks_executed == 0 and self.idle_hooks.len == 0);
    }
}
