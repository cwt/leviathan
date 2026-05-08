const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");

const CallbackManager = @import("callback_manager");

const Loop = @import("../../../main.zig");
const LoopObject = Loop.Python.LoopObject;

const Future = @import("../../../../future/main.zig");
const FutureObject = Future.Python.FutureObject;

const StreamServer = @import("../../../../transports/streamserver/main.zig");

fn set_future_exception(err: anyerror, future: *FutureObject) !void {
    utils.handle_zig_function_error(err, {});
    const exc = python_c.PyErr_GetRaisedException() orelse return error.PythonError;
    const future_data = utils.get_data_ptr(Future, future);
    Future.Python.Result.future_fast_set_exception(future, future_data, exc);
}

inline fn z_loop_create_server(
    self: *LoopObject, args: []?PyObject, knames: ?PyObject
) !*FutureObject {
    if (args.len < 2) {
        python_c.raise_python_value_error("protocol_factory and host are required\x00");
        return error.PythonError;
    }

    const protocol_factory: PyObject = args[0].?;
    const py_host: PyObject = args[1].?;
    var py_port: ?PyObject = null;
    var py_family: ?PyObject = null;
    var py_flags: ?PyObject = null;
    var py_sock: ?PyObject = null;
    var py_backlog: ?PyObject = null;
    var py_reuse_address: ?PyObject = null;
    var py_reuse_port: ?PyObject = null;

    if (args.len > 2) py_port = args[2].?;

    try python_c.parse_vector_call_kwargs(
        knames, args.ptr + args.len,
        &.{ "family\x00", "flags\x00", "sock\x00", "backlog\x00", "reuse_address\x00", "reuse_port\x00" },
        &.{ &py_family, &py_flags, &py_sock, &py_backlog, &py_reuse_address, &py_reuse_port },
    );
    defer {
        python_c.py_xdecref(py_sock);
    }

    if (python_c.PyCallable_Check(protocol_factory) <= 0) {
        python_c.raise_python_type_error("protocol_factory must be callable\x00");
        return error.PythonError;
    }

    const loop_data = utils.get_data_ptr(Loop, self);
    const allocator = loop_data.allocator;

    const fut = try Future.Python.Constructors.fast_new_future(self);

    const port: u16 = blk: {
        if (py_port) |p| {
            const val = python_c.PyLong_AsInt(p);
            if (val == -1 and python_c.PyErr_Occurred() != null) return error.PythonError;
            break :blk @intCast(val);
        }
        break :blk 0;
    };

    const family: u32 = 2; // AF_INET

    const backlog: c_int = blk: {
        if (py_backlog) |b| {
            break :blk @intCast(python_c.PyLong_AsInt(b));
        }
        break :blk 100;
    };

    const reuse_address: bool = if (py_reuse_address) |r|
        python_c.PyObject_IsTrue(r) != 0
    else
        true;

    const reuse_port: bool = if (py_reuse_port) |r|
        python_c.PyObject_IsTrue(r) != 0
    else
        false;

    const host_str = try get_host_string(py_host);
    defer allocator.free(host_str);

    // Resolve host to get address
    const address_list = try loop_data.dns.lookup(host_str, &.{.func = &dummy_dns_callback, .cleanup = null, .data = .{ .user_data = null, .exception_context = null }}) orelse {
        python_c.raise_python_runtime_error("Failed to resolve host\x00");
        return set_future_exception_and_return(fut, error.PythonError);
    };

    if (address_list.len == 0) {
        python_c.raise_python_runtime_error("No addresses to bind to\x00");
        return set_future_exception_and_return(fut, error.PythonError);
    }

    // Create socket for first address
    const addr = address_list[0];
    var addr_with_port = addr;
    addr_with_port.setPort(port);

    const flags: u32 = std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC;
    const fd = try std.posix.socket(
        family, flags, std.posix.IPPROTO.TCP
    );
    errdefer std.posix.close(fd);

    if (reuse_address) {
        const val: c_int = 1;
        try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&val));
    }
    if (reuse_port) {
        const val: c_int = 1;
        try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, std.mem.asBytes(&val));
    }

    try std.posix.bind(fd, &addr_with_port.any, addr_with_port.getOsSockLen());
    errdefer std.posix.close(fd);

    try std.posix.listen(fd, @intCast(backlog));

    // Create the server transport
    const py_fd = python_c.PyLong_FromLong(@intCast(fd)) orelse return error.PythonError;
    defer python_c.py_decref(py_fd);

    const py_backlog_obj = python_c.PyLong_FromLong(@intCast(backlog)) orelse return error.PythonError;
    defer python_c.py_decref(py_backlog_obj);

    const server = python_c.PyObject_CallFunction(
        @as(*python_c.PyObject, @ptrCast(StreamServer.StreamServerType.?)), "OOOi\x00",
        @as(*python_c.PyObject, @ptrCast(self)), protocol_factory, py_fd, backlog
    ) orelse return error.PythonError;
    errdefer python_c.py_decref(server);

    const server_ptr: *StreamServer.StreamServerObject = @ptrCast(server);

    // Start accepting
    StreamServer.start_serving(server_ptr) catch |err| {
        python_c.py_decref(server);
        return set_future_exception_and_return(fut, err);
    };

    // Set future result — return the server object
    const future_data = utils.get_data_ptr(Future, fut);
    Future.Python.Result.future_fast_set_result(future_data, server);
    python_c.py_decref(server);
    return fut;
}

fn set_future_exception_and_return(fut: *FutureObject, err: anyerror) !*FutureObject {
    try set_future_exception(err, fut);
    return fut;
}

fn get_host_string(py_host: PyObject) ![]u8 {
    var c_size: python_c.Py_ssize_t = 0;
    const ptr = python_c.PyUnicode_AsUTF8AndSize(py_host, &c_size) orelse return error.PythonError;
    const size: usize = @intCast(c_size);
    const allocator = utils.gpa.allocator();
    const result = try allocator.alloc(u8, size);
    @memcpy(result, ptr[0..size]);
    return result;
}

fn dummy_dns_callback(_: *const CallbackManager.CallbackData) !void {}

pub fn loop_create_server(
    self: ?*LoopObject, args: ?[*]?PyObject, nargs: isize, knames: ?PyObject
) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(
        z_loop_create_server, .{ self.?, args.?[0..@as(usize, @intCast(nargs))], knames },
    );
}
