const Loop = @import("main.zig");
const CallbackManager = @import("callback_manager");

const Lock = @import("../utils/lock.zig").Mutex;

const utils = @import("utils");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const std = @import("std");
const builtin = @import("builtin");

// ------------------------------------------------------------
// https://github.com/ziglang/zig/issues/1499
const PyThreadState = opaque {};
extern fn PyEval_SaveThread() ?*PyThreadState;
extern fn PyEval_RestoreThread(?*PyThreadState) void;
// ------------------------------------------------------------

fn exception_handler(
    err: anyerror, py_exception_handler: ?*anyopaque,
    context: ?CallbackManager.CallbackExceptionContext
) !void {
    utils.handle_zig_function_error(err, {});
    const exception = python_c.PyErr_GetRaisedException() orelse return error.PythonError;

    if (
        python_c.PyErr_GivenExceptionMatches(exception, python_c.PyExc_SystemExit) > 0 or
        python_c.PyErr_GivenExceptionMatches(exception, python_c.PyExc_KeyboardInterrupt) > 0
    ) {
        python_c.PyErr_SetRaisedException(exception);
        return error.PythonError;
    }
    defer python_c.py_decref(exception);

    const context_dict = python_c.PyDict_New() orelse return error.PythonError;
    defer python_c.py_decref(context_dict);

    if (python_c.PyDict_SetItemString(context_dict, "exception\x00", exception) < 0) return error.PythonError;

    if (context) |ctx| {
        const msg = python_c.PyUnicode_FromString(ctx.exc_message) orelse return error.PythonError;
        defer python_c.py_decref(msg);
        if (python_c.PyDict_SetItemString(context_dict, "message\x00", msg) < 0) return error.PythonError;

        if (python_c.PyDict_SetItemString(context_dict, ctx.module_name, ctx.module_ptr) < 0) return error.PythonError;

        if (ctx.callback_ptr) |c_ptr| {
            if (python_c.PyDict_SetItemString(context_dict, "callback\x00", c_ptr) < 0) return error.PythonError;
        }
    }else{
        const msg = python_c.PyUnicode_FromString("Exception ocurred executing an event\x00")
            orelse return error.PythonError;
        defer python_c.py_decref(msg);
        if (python_c.PyDict_SetItemString(context_dict, "message\x00", msg) < 0) return error.PythonError;
    }

    const ret = python_c.PyObject_CallOneArg(@alignCast(@ptrCast(py_exception_handler.?)), context_dict)
        orelse return error.PythonError;
    python_c.py_decref(ret);
}

pub inline fn call_once(
    ready_queue: *CallbackManager.CallbacksSetsQueue,
    ready_tasks_queue_max_capacity: usize,
    py_exception_handler: PyObject
) !usize {
    const callbacks_executed = try CallbackManager.execute_callbacks(
        ready_queue, if (builtin.is_test) null else &exception_handler, py_exception_handler
    );
    if (callbacks_executed == 0) {
        ready_queue.prune(ready_tasks_queue_max_capacity);
    }

    return callbacks_executed;
}

fn fetch_completed_tasks(
    self: *Loop,
    blocking_ready_tasks: []std.os.linux.io_uring_cqe,
    ready_queue: *CallbackManager.CallbacksSetsQueue
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
                _ = ready_queue.try_append(v) orelse unreachable;
                self.reserved_slots -= 1;
            },
            .none => {}
        }

        blocking_task.deinit();
    }
}

fn poll_blocking_events(
    self: *Loop,
    mutex: *Lock,
    wait: bool,
    ready_queue: *CallbackManager.CallbacksSetsQueue
) !void {
    const blocking_ready_tasks = self.io.blocking_ready_tasks;

    var nevents: u32 = undefined;
    while (true) {
        if (wait and ready_queue.empty()) {
            self.io.ring_blocked = true;
            mutex.unlock();
            defer {
                mutex.lock();
                self.io.ring_blocked = false;
            }

            const py_thread_state = PyEval_SaveThread();
            defer PyEval_RestoreThread(py_thread_state);

            nevents = self.io.ring.copy_cqes(blocking_ready_tasks, 1) catch |err| {
                if (err == error.SignalInterrupt) continue;
                return err;
            };
        } else {
            nevents = self.io.ring.copy_cqes(blocking_ready_tasks, 0) catch |err| {
                if (err == error.SignalInterrupt) continue;
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

pub fn start(self: *Loop, py_exception_handler: PyObject) !void {
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

    const ready_tasks_queues: []CallbackManager.CallbacksSetsQueue = &self.ready_tasks_queues;
    const ready_tasks_queue_max_capacity = self.ready_tasks_queue_max_capacity;

    const self_py = utils.get_parent_ptr(Loop.Python.LoopObject, self);
    var ready_tasks_queue_index = self.ready_tasks_queue_index;
    var wait_for_blocking_events: bool = false;
    while (!self.stopping) {
        if (self_py.owner_pid != std.os.linux.getpid()) break;

        const old_index = ready_tasks_queue_index;
        const ready_tasks_queue = &ready_tasks_queues[old_index];

        const reserved_slots = self.reserved_slots;
        for (ready_tasks_queues) |*queue| {
            try queue.ensure_capacity(reserved_slots);
        }

        try poll_blocking_events(self, mutex, wait_for_blocking_events, ready_tasks_queue);
        ready_tasks_queue_index = 1 - ready_tasks_queue_index;
        self.ready_tasks_queue_index = ready_tasks_queue_index;

        mutex.unlock();
        defer mutex.lock();

        const callbacks_executed = try call_once(
            ready_tasks_queue,
            @max(self.reserved_slots, ready_tasks_queue_max_capacity),
            py_exception_handler
        );

        wait_for_blocking_events = (callbacks_executed == 0);
    }
}
