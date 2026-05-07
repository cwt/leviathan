const std = @import("std");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;
const utils = @import("utils");
const CallbackManager = @import("callback_manager");
const Loop = @import("../../loop/main.zig");
const LoopObject = Loop.Python.LoopObject;

pub const SubprocessTransportObject = extern struct {
    ob_base: python_c.PyObject,

    loop: ?PyObject,
    protocol: ?PyObject,
    pid: std.posix.pid_t,
    returncode: ?PyObject,
    pidfd_task_id: usize,
    closed: bool,
};

fn subprocess_dealloc(self: ?*SubprocessTransportObject) callconv(.c) void {
    const instance = self.?;
    python_c.py_xdecref(instance.loop);
    python_c.py_xdecref(instance.protocol);
    python_c.py_xdecref(instance.returncode);
    const @"type": *python_c.PyTypeObject = python_c.get_type(@ptrCast(instance));
    @"type".tp_free.?(@ptrCast(instance));
}

fn subprocess_get_pid(self: ?*SubprocessTransportObject, _: ?PyObject) callconv(.c) ?PyObject {
    return python_c.PyLong_FromLong(@intCast(self.?.pid));
}

fn subprocess_get_returncode(self: ?*SubprocessTransportObject, _: ?PyObject) callconv(.c) ?PyObject {
    if (self.?.returncode) |rc| return python_c.py_newref(rc);
    return python_c.get_py_none();
}

fn subprocess_kill(self: ?*SubprocessTransportObject, _: ?PyObject) callconv(.c) ?PyObject {
    _ = std.posix.kill(self.?.pid, std.os.linux.SIG.KILL) catch {};
    return python_c.get_py_none();
}

fn subprocess_terminate(self: ?*SubprocessTransportObject, _: ?PyObject) callconv(.c) ?PyObject {
    _ = std.posix.kill(self.?.pid, std.os.linux.SIG.TERM) catch {};
    return python_c.get_py_none();
}

fn subprocess_send_signal(self: ?*SubprocessTransportObject, args: ?PyObject) callconv(.c) ?PyObject {
    const sig: c_int = @intCast(python_c.PyLong_AsInt(args.?));
    _ = std.posix.kill(self.?.pid, @intCast(sig)) catch {};
    return python_c.get_py_none();
}

fn subprocess_close(self: ?*SubprocessTransportObject, _: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;
    if (!instance.closed) {
        instance.closed = true;
    }
    return python_c.get_py_none();
}

const SubprocessMethods: []const python_c.PyMethodDef = &[_]python_c.PyMethodDef{
    .{ .ml_name = "get_pid", .ml_meth = @ptrCast(&subprocess_get_pid), .ml_doc = "Get PID.", .ml_flags = python_c.METH_NOARGS },
    .{ .ml_name = "get_returncode", .ml_meth = @ptrCast(&subprocess_get_returncode), .ml_doc = "Get returncode.", .ml_flags = python_c.METH_NOARGS },
    .{ .ml_name = "kill", .ml_meth = @ptrCast(&subprocess_kill), .ml_doc = "SIGKILL.", .ml_flags = python_c.METH_NOARGS },
    .{ .ml_name = "terminate", .ml_meth = @ptrCast(&subprocess_terminate), .ml_doc = "SIGTERM.", .ml_flags = python_c.METH_NOARGS },
    .{ .ml_name = "send_signal", .ml_meth = @ptrCast(&subprocess_send_signal), .ml_doc = "Send signal.", .ml_flags = python_c.METH_O },
    .{ .ml_name = "close", .ml_meth = @ptrCast(&subprocess_close), .ml_doc = "Close.", .ml_flags = python_c.METH_NOARGS },
    .{ .ml_name = null, .ml_meth = null, .ml_doc = null, .ml_flags = 0 },
};

const SubprocessSlots: []const python_c.PyType_Slot = &[_]python_c.PyType_Slot{
    .{ .slot = python_c.Py_tp_new, .pfunc = @ptrCast(@constCast(&python_c.PyType_GenericNew)) },
    .{ .slot = python_c.Py_tp_dealloc, .pfunc = @ptrCast(@constCast(&subprocess_dealloc)) },
    .{ .slot = python_c.Py_tp_methods, .pfunc = @constCast(SubprocessMethods.ptr) },
    .{ .slot = python_c.Py_tp_doc, .pfunc = @constCast("Leviathan SubprocessTransport.") },
    .{ .slot = 0, .pfunc = null },
};

var subprocess_spec = python_c.PyType_Spec{
    .name = "leviathan.SubprocessTransport",
    .basicsize = @sizeOf(SubprocessTransportObject),
    .itemsize = 0,
    .flags = python_c.Py_TPFLAGS_DEFAULT | python_c.Py_TPFLAGS_BASETYPE,
    .slots = @constCast(SubprocessSlots.ptr),
};

pub var SubprocessType: ?*python_c.PyTypeObject = null;

pub fn create_type() !void {
    if (SubprocessType != null) return;
    SubprocessType = @ptrCast(python_c.PyType_FromSpecWithBases(
        @constCast(&subprocess_spec), null
    ) orelse return error.PythonError);
}

fn pidfd_exit_callback(data: *const CallbackManager.CallbackData) !void {
    const transport: *SubprocessTransportObject = @alignCast(@ptrCast(data.user_data.?));
    if (data.cancelled or transport.closed) return;

    const result = std.posix.waitpid(transport.pid, std.posix.W.NOHANG);
    if (result.pid != transport.pid) {
        // Still running — re-arm the timer
        const loop_data = utils.get_data_ptr(Loop, @as(*LoopObject, @ptrCast(transport.loop.?)));
        _ = try loop_data.io.queue(.{
            .WaitTimer = .{
                .duration = .{ .sec = 0, .nsec = 100_000_000 },
                .delay_type = .Relative,
                .callback = .{
                    .func = &pidfd_exit_callback,
                    .cleanup = null,
                    .data = .{ .user_data = transport, .exception_context = null },
                },
            },
        });
        return;
    }
    const status = result.status;

    const rc: c_int = if (std.posix.W.IFEXITED(status))
        @intCast(std.posix.W.EXITSTATUS(status))
    else if (std.posix.W.IFSIGNALED(status))
        -@as(c_int, @intCast(std.posix.W.TERMSIG(status)))
    else
        0;

    transport.returncode = python_c.PyLong_FromLong(rc);

    // Notify protocol
    if (transport.protocol) |proto| {
        const pe = python_c.PyObject_GetAttrString(proto, "process_exited") orelse return error.PythonError;
        defer python_c.py_decref(pe);
        const r1 = python_c.PyObject_CallNoArgs(pe) orelse return error.PythonError;
        python_c.py_decref(r1);

        const cl = python_c.PyObject_GetAttrString(proto, "connection_lost") orelse return error.PythonError;
        defer python_c.py_decref(cl);
        const r2 = python_c.PyObject_CallOneArg(cl, python_c.get_py_none_without_incref()) orelse return error.PythonError;
        python_c.py_decref(r2);
    }
}

pub fn start_exit_watcher(transport: *SubprocessTransportObject, loop: *LoopObject) !void {
    const loop_data = utils.get_data_ptr(Loop, loop);

    transport.pidfd_task_id = try loop_data.io.queue(.{
        .WaitTimer = .{
            .duration = .{ .sec = 0, .nsec = 100_000_000 },
            .delay_type = .Relative,
            .callback = .{
                .func = &pidfd_exit_callback,
                .cleanup = null,
                .data = .{ .user_data = transport, .exception_context = null },
            },
        },
    });
}

pub fn spawn_and_create(
    protocol: PyObject, loop: *LoopObject, program: []const u8, argv: []const []const u8
) !*SubprocessTransportObject {
    _ = argv;
    const pid = try std.posix.fork();
    if (pid == 0) {
        const devnull = std.posix.openZ("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch std.os.linux.exit(1);
        _ = std.posix.dup2(devnull, 0) catch {};
        _ = std.posix.dup2(devnull, 1) catch {};
        _ = std.posix.dup2(devnull, 2) catch {};
        var child_argv = [_:null]?[*:0]const u8{ @ptrCast(program.ptr), null };
        _ = std.posix.execveZ(@ptrCast(program.ptr), &child_argv, &[_:null]?[*:0]const u8{null}) catch std.os.linux.exit(127);
    }

    const self: *SubprocessTransportObject = @ptrCast(
        SubprocessType.?.tp_alloc.?(SubprocessType.?, 0) orelse return error.PythonError
    );
    self.* = .{
        .ob_base = undefined,
        .loop = python_c.py_newref(@as(*python_c.PyObject, @ptrCast(loop))),
        .protocol = python_c.py_newref(protocol),
        .pid = pid,
        .returncode = null,
        .pidfd_task_id = 0,
        .closed = false,
    };

    // try start_exit_watcher(self, loop);
    return self;
}
