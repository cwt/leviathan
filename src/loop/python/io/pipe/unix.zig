const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");
const CallbackManager = @import("callback_manager");

const Loop = @import("../../../main.zig");
const LoopObject = Loop.Python.LoopObject;
const Future = @import("../../../../future/main.zig");
const FutureObject = Future.Python.FutureObject;
const Stream = @import("../../../../transports/stream/main.zig");
const StreamServer = @import("../../../../transports/streamserver/main.zig");

fn set_future_exception(err: anyerror, future: *FutureObject) !void {
    utils.handle_zig_function_error(err, {});
    const exc = python_c.PyErr_GetRaisedException() orelse return error.PythonError;
    const future_data = utils.get_data_ptr(Future, future);
    Future.Python.Result.future_fast_set_exception(future, future_data, exc);
}

inline fn get_string_slice(py_obj: PyObject) ![]const u8 {
    var c_size: python_c.Py_ssize_t = 0;
    const ptr = python_c.PyUnicode_AsUTF8AndSize(py_obj, &c_size) orelse return error.PythonError;
    const size: usize = @intCast(c_size);
    return ptr[0..size];
}

// ============================================================
// create_unix_connection
// ============================================================

const UnixConnectData = struct {
    future: *FutureObject,
    loop: *LoopObject,
    protocol_factory: PyObject,
    allocator: std.mem.Allocator,
    addr: std.posix.sockaddr.un,
    socket_fd: std.posix.fd_t = -1,
};

fn unix_connect_callback(data: *const CallbackManager.CallbackData) !void {
    const ucd: *UnixConnectData = @alignCast(@ptrCast(data.user_data.?));
    const allocator = ucd.allocator;

    defer {
        if (ucd.socket_fd >= 0) {
            std.posix.close(ucd.socket_fd);
        }
        python_c.py_decref(ucd.protocol_factory);
        python_c.py_decref(@ptrCast(ucd.future));
        python_c.py_decref(@ptrCast(ucd.loop));
        allocator.destroy(ucd);
    }

    if (data.cancelled) {
        python_c.raise_python_runtime_error("Unix connection cancelled");
        return set_future_exception(error.PythonError, ucd.future);
    }

    const io_uring_res = data.io_uring_res;
    const io_uring_err = data.io_uring_err;

    if (io_uring_err != .SUCCESS or io_uring_res < 0) {
        const errno_val = if (io_uring_res < 0) -io_uring_res else @intFromEnum(io_uring_err);
        const exc = python_c.PyObject_CallFunction(
            python_c.PyExc_OSError, "is\x00",
            @as(c_int, @intCast(errno_val)),
            "Connect call failed\x00"
        ) orelse return set_future_exception(error.PythonError, ucd.future);
        
        const future_data = utils.get_data_ptr(Future, ucd.future);
        Future.Python.Result.future_fast_set_exception(ucd.future, future_data, exc);
        return;
    }

    const fd = ucd.socket_fd;
    ucd.socket_fd = -1; // Ownership transferred to transport

    const protocol = python_c.PyObject_CallNoArgs(ucd.protocol_factory) orelse return set_future_exception(error.PythonError, ucd.future);
    errdefer python_c.py_decref(protocol);

    const transport = try Stream.Constructors.new_stream_transport(
        protocol, @ptrCast(ucd.loop), fd, false
    );
    errdefer python_c.py_decref(@ptrCast(transport));

    const connection_made = python_c.PyObject_GetAttrString(protocol, "connection_made\x00")
        orelse return set_future_exception(error.PythonError, ucd.future);
    defer python_c.py_decref(connection_made);

    const ret = python_c.PyObject_CallOneArg(connection_made, @ptrCast(transport))
        orelse return set_future_exception(error.PythonError, ucd.future);
    python_c.py_decref(ret);

    const result_tuple = python_c.PyTuple_New(2) orelse return set_future_exception(error.PythonError, ucd.future);
    // Note: PyTuple_SetItem steals a reference
    if (python_c.PyTuple_SetItem(result_tuple, 0, @ptrCast(transport)) != 0) return set_future_exception(error.PythonError, ucd.future);
    if (python_c.PyTuple_SetItem(result_tuple, 1, protocol) != 0) {
        python_c.py_decref(result_tuple);
        return set_future_exception(error.PythonError, ucd.future);
    }

    const future_data = utils.get_data_ptr(Future, ucd.future);
    Future.Python.Result.future_fast_set_result(future_data, result_tuple);
    python_c.py_decref(result_tuple);
}

fn create_unix_sockaddr(path: []const u8) !std.posix.sockaddr.un {
    if (path.len >= 108) return error.NameTooLong;
    var sun: std.posix.sockaddr.un = undefined;
    @memset(std.mem.asBytes(&sun), 0);
    sun.family = std.posix.AF.UNIX;
    @memcpy(sun.path[0..path.len], path);
    sun.path[path.len] = 0;
    return sun;
}

inline fn z_loop_create_unix_connection(
    self: *LoopObject, args: []?PyObject, knames: ?PyObject
) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (args.len < 2) {
        python_c.raise_python_value_error("protocol_factory and path are required");
        return error.PythonError;
    }

    const protocol_factory: PyObject = args[0].?;
    const py_path = args[1].?;
    var py_ssl: ?PyObject = null;
    try python_c.parse_vector_call_kwargs(knames, args.ptr + args.len, &.{"ssl"}, &.{&py_ssl});

    if (python_c.PyCallable_Check(protocol_factory) <= 0) {
        python_c.raise_python_type_error("protocol_factory must be callable");
        return error.PythonError;
    }

    const loop_data = utils.get_data_ptr(Loop, self);
    const fut = try Future.Python.Constructors.fast_new_future(self);
    const path = try get_string_slice(py_path);

    const ucd = try loop_data.allocator.create(UnixConnectData);
    errdefer loop_data.allocator.destroy(ucd);
    ucd.* = .{
        .future = @ptrCast(python_c.py_newref(@as(PyObject, @ptrCast(fut)))),
        .loop = python_c.py_newref(self),
        .protocol_factory = python_c.py_newref(protocol_factory),
        .allocator = loop_data.allocator,
        .addr = try create_unix_sockaddr(path),
    };
    errdefer {
        python_c.py_decref(@as(PyObject, @ptrCast(ucd.future)));
        python_c.py_decref(@as(PyObject, @ptrCast(ucd.loop)));
        python_c.py_decref(ucd.protocol_factory);
    }

    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0);
    ucd.socket_fd = fd;
    errdefer std.posix.close(fd);

    _ = try Loop.Scheduling.IO.queue(
        &loop_data.io, .{
            .SocketConnect = .{
                .addr = @ptrCast(&ucd.addr),
                .len = @sizeOf(std.posix.sockaddr.un),
                .socket_fd = fd,
                .callback = .{
                    .func = &unix_connect_callback,
                    .cleanup = null,
                    .data = .{ .user_data = ucd, .exception_context = null },
                },
            },
        }
    );

    return fut;
}

pub fn loop_create_unix_connection(
    self: ?*LoopObject, args: ?[*]?PyObject, nargs: isize, knames: ?PyObject
) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(
        z_loop_create_unix_connection, .{ self.?, args.?[0..@as(usize, @intCast(nargs))], knames },
    );
}

// ============================================================
// create_unix_server
// ============================================================

inline fn z_loop_create_unix_server(
    self: *LoopObject, args: []?PyObject, knames: ?PyObject
) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (args.len < 2) {
        python_c.raise_python_value_error("protocol_factory and path are required");
        return error.PythonError;
    }

    const protocol_factory: PyObject = args[0].?;
    const py_path = args[1].?;
    var py_backlog: ?PyObject = null;
    var py_ssl: ?PyObject = null;
    try python_c.parse_vector_call_kwargs(knames, args.ptr + args.len, &.{ "backlog", "ssl" }, &.{ &py_backlog, &py_ssl });

    if (python_c.PyCallable_Check(protocol_factory) <= 0) {
        python_c.raise_python_type_error("protocol_factory must be callable");
        return error.PythonError;
    }

    const fut = try Future.Python.Constructors.fast_new_future(self);

    const path = try get_string_slice(py_path);

    const backlog: c_int = if (py_backlog) |b| @intCast(python_c.PyLong_AsInt(b)) else 100;

    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    errdefer std.posix.close(fd);

    // Unlink existing socket file before bind
    std.posix.unlink(path) catch {};

    const addr = try create_unix_sockaddr(path);
    try std.posix.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));
    errdefer std.posix.close(fd);

    try std.posix.listen(fd, @intCast(backlog));

    // Create server transport
    const py_fd = python_c.PyLong_FromLong(@intCast(fd)) orelse return error.PythonError;
    defer python_c.py_decref(py_fd);
    const py_backlog_obj = python_c.PyLong_FromLong(@intCast(backlog)) orelse return error.PythonError;
    defer python_c.py_decref(py_backlog_obj);

    const server = python_c.PyObject_CallFunction(
        @as(*python_c.PyObject, @ptrCast(StreamServer.StreamServerType.?)),
        "OOOi\x00",
        @as(*python_c.PyObject, @ptrCast(self)), protocol_factory, py_fd, backlog
    ) orelse return error.PythonError;
    errdefer python_c.py_decref(server);

    StreamServer.start_serving(@ptrCast(server)) catch |err| {
        python_c.py_decref(server);
        try set_future_exception(err, fut);
        return fut;
    };

    const future_data = utils.get_data_ptr(Future, fut);
    Future.Python.Result.future_fast_set_result(future_data, server);
    python_c.py_decref(server);
    return fut;
}

pub fn loop_create_unix_server(
    self: ?*LoopObject, args: ?[*]?PyObject, nargs: isize, knames: ?PyObject
) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(
        z_loop_create_unix_server, .{ self.?, args.?[0..@as(usize, @intCast(nargs))], knames },
    );
}

test "create_unix_sockaddr: basic path" {
    const path = "/tmp/test.sock";
    const sun = try create_unix_sockaddr(path);
    try std.testing.expectEqual(std.posix.AF.UNIX, sun.family);
    try std.testing.expectEqualStrings(path, std.mem.span(@as([*:0]const u8, @ptrCast(&sun.path))));
}

test "create_unix_sockaddr: path too long" {
    const long_path = "a" ** 108;
    try std.testing.expectError(error.NameTooLong, create_unix_sockaddr(long_path));
}
