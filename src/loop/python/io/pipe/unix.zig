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

inline fn get_string(py_obj: PyObject, alloc: std.mem.Allocator) ![]u8 {
    var c_size: python_c.Py_ssize_t = 0;
    const ptr = python_c.PyUnicode_AsUTF8AndSize(py_obj, &c_size) orelse return error.PythonError;
    const size: usize = @intCast(c_size);
    const r = try alloc.alloc(u8, size);
    @memcpy(r, ptr[0..size]);
    return r;
}

// ============================================================
// create_unix_connection
// ============================================================

const UnixConnectData = struct {
    future: *FutureObject,
    loop: *LoopObject,
    protocol_factory: PyObject,
    path: []u8,
    allocator: std.mem.Allocator,
};

fn unix_connect_callback(data: *const CallbackManager.CallbackData) !void {
    const ucd: *UnixConnectData = @alignCast(@ptrCast(data.user_data.?));
    defer {
        ucd.allocator.free(ucd.path);
        python_c.py_decref(ucd.protocol_factory);
        ucd.allocator.destroy(ucd);
    }

    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    errdefer std.posix.close(fd);

    const addr = try create_unix_sockaddr(ucd.path, ucd.allocator);
    defer ucd.allocator.free(addr);

    try std.posix.connect(fd, @ptrCast(@alignCast(&addr[0])), @intCast(addr.len));

    const protocol = python_c.PyObject_CallNoArgs(ucd.protocol_factory) orelse return error.PythonError;
    errdefer python_c.py_decref(protocol);

    const transport = try Stream.Constructors.new_stream_transport(
        protocol, @ptrCast(ucd.loop), fd, false
    );
    errdefer python_c.py_decref(@ptrCast(transport));

    const connection_made = python_c.PyObject_GetAttrString(protocol, "connection_made\x00")
        orelse return error.PythonError;
    defer python_c.py_decref(connection_made);

    const ret = python_c.PyObject_CallOneArg(connection_made, @ptrCast(transport))
        orelse return error.PythonError;
    python_c.py_decref(ret);

    const result_tuple = python_c.PyTuple_New(2) orelse return error.PythonError;
    if (python_c.PyTuple_SetItem(result_tuple, 0, @ptrCast(transport)) != 0) return error.PythonError;
    if (python_c.PyTuple_SetItem(result_tuple, 1, protocol) != 0) {
        python_c.py_decref(@ptrCast(transport));
        return error.PythonError;
    }

    const future_data = utils.get_data_ptr(Future, ucd.future);
    Future.Python.Result.future_fast_set_result(future_data, result_tuple);
}

fn create_unix_sockaddr(path: []const u8, alloc: std.mem.Allocator) ![]u8 {
    if (path.len >= 108) return error.NameTooLong;
    const addr = try alloc.alloc(u8, @sizeOf(std.posix.sockaddr.un));
    @memset(addr, 0);
    const sun: *std.posix.sockaddr.un = @ptrCast(@alignCast(addr.ptr));
    sun.family = std.posix.AF.UNIX;
    @memcpy(sun.path[0..path.len], path);
    sun.path[path.len] = 0;
    return addr;
}

inline fn z_loop_create_unix_connection(
    self: *LoopObject, args: []?PyObject, knames: ?PyObject
) !*FutureObject {
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
    const alloc = loop_data.allocator;
    const fut = try Future.Python.Constructors.fast_new_future(self);
    const path = try get_string(py_path, alloc);

    const ucd = try alloc.create(UnixConnectData);
    errdefer alloc.destroy(ucd);
    ucd.* = .{
        .future = fut, .loop = self,
        .protocol_factory = python_c.py_newref(protocol_factory),
        .path = path, .allocator = alloc,
    };

    const callback = CallbackManager.Callback{
        .func = &unix_connect_callback,
        .cleanup = null,
        .data = .{ .user_data = ucd, .exception_context = null },
    };
    try Loop.Scheduling.Soon.dispatch(loop_data, &callback);
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

    const loop_data = utils.get_data_ptr(Loop, self);
    const alloc = loop_data.allocator;
    const fut = try Future.Python.Constructors.fast_new_future(self);

    const path = try get_string(py_path, alloc);

    const backlog: c_int = if (py_backlog) |b| @intCast(python_c.PyLong_AsInt(b)) else 100;

    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    errdefer std.posix.close(fd);

    // Unlink existing socket file before bind
    std.posix.unlink(path) catch {};

    const addr = try create_unix_sockaddr(path, alloc);
    defer alloc.free(addr);
    try std.posix.bind(fd, @ptrCast(@alignCast(&addr[0])), @intCast(addr.len));
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
    alloc.free(path);
    return fut;
}

pub fn loop_create_unix_server(
    self: ?*LoopObject, args: ?[*]?PyObject, nargs: isize, knames: ?PyObject
) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(
        z_loop_create_unix_server, .{ self.?, args.?[0..@as(usize, @intCast(nargs))], knames },
    );
}
