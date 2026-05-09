const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");
const CallbackManager = @import("callback_manager");

const Loop = @import("../main.zig");
const LoopObject = Loop.Python.LoopObject;

const Hooks = @import("hooks.zig");

inline fn z_loop_run_forever(self: *LoopObject) !PyObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    const loop_data = utils.get_data_ptr(Loop, self);

    try Hooks.setup_asyncgen_hooks(self);

    const set_running_loop = utils.PythonImports.set_running_loop;
    if (python_c.PyObject_CallOneArg(set_running_loop, @ptrCast(self))) |v| {
        python_c.py_decref(v);
    }else{
        const exc = python_c.PyErr_GetRaisedException();
        Hooks.cleanup_asyncgen_hooks(self);
        python_c.PyErr_SetRaisedException(exc);
        return error.PythonError;
    }

    var py_exception: ?PyObject = null;
    Loop.Runner.start(loop_data, self) catch |err| {
        utils.handle_zig_function_error(err, {});
        py_exception = python_c.PyErr_GetRaisedException() orelse unreachable;
    };

    if (python_c.PyObject_CallOneArg(set_running_loop, python_c.get_py_none_without_incref())) |v| {
        python_c.py_decref(v);
    }else{
        const py_exc = python_c.PyErr_GetRaisedException() orelse unreachable;
        if (py_exception) |v| {
            python_c.PyException_SetCause(py_exc, v);
        }

        py_exception = py_exc;
    }

    Hooks.cleanup_asyncgen_hooks(self);
    if (py_exception) |v| {
        python_c.PyErr_SetRaisedException(v);
        return error.PythonError;
    }

    return python_c.get_py_none();
}

pub fn loop_run_forever(self: ?*LoopObject, _: ?PyObject) callconv(.c) ?PyObject {
    return utils.execute_zig_function(z_loop_run_forever, .{self.?});
}

pub fn loop_stop(self: ?*LoopObject, _: ?PyObject) callconv(.c) ?PyObject {
    if (Loop.Python.check_forked(self.?)) return null;
    const loop_data = utils.get_data_ptr(Loop, self.?);

    const mutex = &loop_data.mutex;
    mutex.lock();
    defer mutex.unlock();

    loop_data.stopping = true;
    return python_c.get_py_none();
}

pub fn loop_is_running(self: ?*LoopObject, _: ?PyObject) callconv(.c) ?PyObject {
    if (Loop.Python.check_forked(self.?)) return null;
    const loop_data = utils.get_data_ptr(Loop, self.?);
    const mutex = &loop_data.mutex;
    mutex.lock();
    defer mutex.unlock();

    return python_c.PyBool_FromLong(@intCast(@intFromBool(loop_data.running)));
}

pub fn loop_is_closed(self: ?*LoopObject, _: ?PyObject) callconv(.c) ?PyObject {
    if (Loop.Python.check_forked(self.?)) return null;
    const loop_data = utils.get_data_ptr(Loop, self.?);

    const mutex = &loop_data.mutex;
    mutex.lock();
    defer mutex.unlock();

    return python_c.PyBool_FromLong(@intCast(@intFromBool(!loop_data.initialized)));
}

pub fn loop_get_debug(self: ?*LoopObject, _: ?PyObject) callconv(.c) ?PyObject {
    return python_c.PyBool_FromLong(@intCast(@intFromBool(self.?.debug)));
}

pub fn loop_set_debug(self: ?*LoopObject, enabled: ?PyObject) callconv(.c) ?PyObject {
    self.?.debug = (python_c.PyObject_IsTrue(enabled.?) != 0);
    return python_c.get_py_none();
}

pub fn loop_get_task_factory(self: ?*LoopObject, _: ?PyObject) callconv(.c) ?PyObject {
    if (self.?.task_factory) |tf| return python_c.py_newref(tf);
    return python_c.get_py_none();
}

pub fn loop_set_task_factory(self: ?*LoopObject, factory: ?PyObject) callconv(.c) ?PyObject {
    if (factory) |f| {
        if (!python_c.is_none(f) and python_c.PyCallable_Check(f) == 0) {
            python_c.raise_python_type_error("task factory must be a callable or None\x00");
            return null;
        }
    }
    python_c.py_xdecref(self.?.task_factory);
    if (factory) |f| {
        if (python_c.is_none(f)) {
            self.?.task_factory = null;
        } else {
            self.?.task_factory = python_c.py_newref(f);
        }
    } else {
        self.?.task_factory = null;
    }
    return python_c.get_py_none();
}

const HookHandle = extern struct {
    ob_base: python_c.PyObject,
    loop_data: *Loop,
    hook_type: c_int,
    node: Loop.HooksList.Node,
    callback: PyObject,
};

fn hook_handle_dealloc(self: ?*HookHandle) callconv(.c) void {
    const instance = self.?;
    python_c.py_decref(instance.callback);
    const @"type": *python_c.PyTypeObject = python_c.get_type(@ptrCast(instance));
    @"type".tp_free.?(@ptrCast(instance));
}

fn hook_handle_cancel(self: ?*HookHandle, _: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;
    const hook_type: Loop.HookType = @enumFromInt(instance.hook_type);
    instance.loop_data.remove_hook(hook_type, instance.node);
    return python_c.get_py_none();
}

const HookHandleMethods = [_]python_c.PyMethodDef{
    .{ .ml_name = "cancel\x00", .ml_meth = @ptrCast(&hook_handle_cancel), .ml_flags = python_c.METH_NOARGS, .ml_doc = "Cancel the hook\x00" },
    .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null }
};

var HookHandleType = python_c.PyTypeObject{
    .tp_name = "leviathan._HookHandle\x00",
    .tp_basicsize = @sizeOf(HookHandle),
    .tp_flags = python_c.Py_TPFLAGS_DEFAULT,
    .tp_dealloc = @ptrCast(&hook_handle_dealloc),
    .tp_methods = @constCast(&HookHandleMethods),
};

fn hook_callback(data: *const CallbackManager.CallbackData) !void {
    const handle: *HookHandle = @alignCast(@ptrCast(data.user_data.?));
    const ret = python_c.PyObject_CallNoArgs(handle.callback) orelse return error.PythonError;
    python_c.py_decref(ret);
}

pub fn loop_add_hook(self: ?*LoopObject, args: ?[*]const ?PyObject, nargs: python_c.Py_ssize_t) callconv(.c) ?PyObject {
    return utils.execute_zig_function(z_loop_add_hook, .{ self.?, args.?[0..@as(usize, @intCast(nargs))] });
}

fn z_loop_add_hook(self: *LoopObject, args: []const ?PyObject) !PyObject {
    if (args.len < 2) return error.PythonError;
    const hook_type_int: c_int = @intCast(python_c.PyLong_AsLong(args[0].?));
    const py_callback = args[1].?;

    const hook_type: Loop.HookType = switch (hook_type_int) {
        0 => .prepare,
        1 => .check,
        2 => .idle,
        else => return error.PythonError,
    };

    if (python_c.PyType_Ready(&HookHandleType) < 0) return error.PythonError;
    const handle: *HookHandle = @ptrCast(HookHandleType.tp_alloc.?(&HookHandleType, 0) orelse return error.PythonError);
    handle.loop_data = utils.get_data_ptr(Loop, self);
    handle.hook_type = hook_type_int;
    handle.callback = python_c.py_newref(py_callback);

    handle.node = try handle.loop_data.add_hook(hook_type, .{
        .func = &hook_callback,
        .cleanup = null,
        .data = .{ .user_data = handle, .exception_context = null },
    });

    return @ptrCast(handle);
}

pub fn loop_close(self: ?*LoopObject, _: ?PyObject) callconv(.c) ?PyObject {
    if (Loop.Python.check_forked(self.?)) return null;
    const instance = self.?;

    const loop_data = utils.get_data_ptr(Loop, instance);

    {
        const mutex = &loop_data.mutex;
        mutex.lock();
        defer mutex.unlock();

        if (loop_data.running) {
            python_c.raise_python_runtime_error("Loop is running\x00");
            return null;
        }

        for (&loop_data.ready_tasks_queues) | *queue| {
            queue.ensure_capacity(loop_data.reserved_slots) catch |err| {
                return utils.handle_zig_function_error(err, null);
            };
        }
    }

    loop_data.release();
    return python_c.get_py_none();
}
