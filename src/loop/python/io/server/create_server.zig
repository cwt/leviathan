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

const ServerCreationData = struct {
    py_host: ?PyObject = null,
    py_port: ?PyObject = null,
    py_family: ?PyObject = null,
    py_flags: ?PyObject = null,
    py_sock: ?PyObject = null,
    py_backlog: ?PyObject = null,
    py_reuse_address: ?PyObject = null,
    py_reuse_port: ?PyObject = null,
    protocol_factory: ?PyObject = null,
    future: ?*FutureObject = null,
    loop: ?*LoopObject = null,

    pub fn deinit(self: *ServerCreationData) void {
        const loop_data = utils.get_data_ptr(Loop, self.loop.?);
        const allocator = loop_data.allocator;

        python_c.deinitialize_object_fields(self, &.{});
        allocator.destroy(self);
    }
};

const ServerSocketData = struct {
    creation_data: *ServerCreationData,
    address_list: ?[]std.net.Address = null,

    pub fn deinit(self: *ServerSocketData) void {
        const loop_data = utils.get_data_ptr(Loop, self.creation_data.loop.?);
        const allocator = loop_data.allocator;

        if (self.address_list) |v| {
            allocator.free(v);
        }
        self.creation_data.deinit();
        allocator.destroy(self);
    }
};

fn set_future_exception(err: anyerror, future: *FutureObject) !void {
    utils.handle_zig_function_error(err, {});
    const exc = python_c.PyErr_GetRaisedException() orelse return error.PythonError;
    defer python_c.py_decref(exc);
    const future_data = utils.get_data_ptr(Future, future);
    try Future.Python.Result.future_fast_set_exception(future, future_data, exc);
}

fn get_host_slice(data: *ServerCreationData) ![]const u8 {
    const py_host = data.py_host orelse {
        python_c.raise_python_value_error("Host is required\x00");
        return error.PythonError;
    };

    if (!python_c.unicode_check(py_host)) {
        python_c.raise_python_value_error("Host must be a valid string\x00");
        return error.PythonError;
    }

    var host_ptr_length: python_c.Py_ssize_t = undefined;
    const host_ptr = python_c.PyUnicode_AsUTF8AndSize(py_host, &host_ptr_length)
        orelse return error.PythonError;

    return host_ptr[0..@intCast(host_ptr_length)];
}

inline fn z_loop_create_server(
    self: *LoopObject, args: []?PyObject, knames: ?PyObject
) !*FutureObject {
    if (Loop.Python.check_forked(self)) return error.PythonError;
    if (Loop.Python.check_thread(self)) return error.PythonError;
    if (args.len < 2) {
        python_c.raise_python_value_error("protocol_factory and host are required\x00");
        return error.PythonError;
    }

    const protocol_factory: PyObject = args[0].?;

    if (python_c.PyCallable_Check(protocol_factory) <= 0) {
        python_c.raise_python_type_error("protocol_factory must be callable\x00");
        return error.PythonError;
    }

    var creation_data = ServerCreationData{};
    creation_data.py_host = python_c.py_newref(args[1].?);

    if (args.len > 2) creation_data.py_port = python_c.py_newref(args[2].?);

    try python_c.parse_vector_call_kwargs(
        knames, args.ptr + args.len,
        &.{ "family\x00", "flags\x00", "sock\x00", "backlog\x00", "reuse_address\x00", "reuse_port\x00" },
        &.{ &creation_data.py_family, &creation_data.py_flags, &creation_data.py_sock, &creation_data.py_backlog, &creation_data.py_reuse_address, &creation_data.py_reuse_port },
    );

    const loop_data = utils.get_data_ptr(Loop, self);
    const allocator = loop_data.allocator;

    const fut = try Future.Python.Constructors.fast_new_future(self);
    errdefer python_c.py_decref(@ptrCast(fut));

    creation_data.loop = python_c.py_newref(self);
    creation_data.future = python_c.py_newref(fut);
    creation_data.protocol_factory = python_c.py_newref(protocol_factory);

    const creation_data_ptr = try allocator.create(ServerCreationData);
    creation_data_ptr.* = creation_data;
    errdefer allocator.destroy(creation_data_ptr);

    const callback = CallbackManager.Callback{
        .func = &try_resolve_server_host,
        .cleanup = null,
        .data = .{
            .user_data = creation_data_ptr,
        },
    };
    try Loop.Scheduling.Soon.dispatch(loop_data, &callback);

    return python_c.py_newref(fut);
}

// -----------------------------------------------------------------
// STEP 1: Resolve host

fn z_try_resolve_server_host(creation_data: *ServerCreationData) !void {
    const hostname = try get_host_slice(creation_data);

    const loop_data = utils.get_data_ptr(Loop, creation_data.loop.?);
    const allocator = loop_data.allocator;

    const server_data = try allocator.create(ServerSocketData);
    errdefer allocator.destroy(server_data);
    server_data.creation_data = creation_data;
    server_data.address_list = null;

    if (hostname.len == 0) {
        const allow_ipv6 = loop_data.dns.ipv6_supported;
        var list = std.ArrayList(std.net.Address){};
        try list.append(allocator, std.net.Address.initIp4(.{0, 0, 0, 0}, 0));
        if (allow_ipv6) {
            try list.append(allocator, std.net.Address.initIp6(.{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, 0, 0, 0));
        }
        server_data.address_list = try list.toOwnedSlice(allocator);
        const callback = CallbackManager.Callback{
            .func = &create_server_socket,
            .cleanup = null,
            .data = .{
                .user_data = server_data,
            },
        };
        try Loop.Scheduling.Soon.dispatch(loop_data, &callback);
        return;
    }

    const resolver_callback = CallbackManager.Callback{
        .func = &server_host_resolved_callback,
        .cleanup = null,
        .data = .{
            .user_data = server_data,
        },
    };
    const address_list = try loop_data.dns.lookup(hostname, &resolver_callback) orelse return;

    server_data.address_list = try allocator.dupe(std.net.Address, address_list);
    errdefer allocator.free(server_data.address_list.?);

    const callback = CallbackManager.Callback{
        .func = &create_server_socket,
        .cleanup = null,
        .data = .{
            .user_data = server_data,
        },
    };
    try Loop.Scheduling.Soon.dispatch(loop_data, &callback);
}

fn try_resolve_server_host(data: *const CallbackManager.CallbackData) !void {
    const creation_data: *ServerCreationData = @alignCast(@ptrCast(data.user_data.?));
    errdefer creation_data.deinit();

    if (data.cancelled) {
        python_c.raise_python_runtime_error("Event for server host resolution cancelled\x00");
        return set_future_exception(error.PythonError, creation_data.future.?);
    }

    z_try_resolve_server_host(creation_data) catch |err| {
        return set_future_exception(err, creation_data.future.?);
    };
}

// -----------------------------------------------------------------
// STEP 2: Host resolved

fn z_server_host_resolved_callback(server_data: *ServerSocketData) !void {
    const creation_data = server_data.creation_data;
    const loop_data = utils.get_data_ptr(Loop, creation_data.loop.?);
    const allocator = loop_data.allocator;

    const host = try get_host_slice(creation_data);
    const address_list = try loop_data.dns.lookup(host, null) orelse {
        python_c.raise_python_runtime_error("Failed to resolve host\x00");
        return set_future_exception(error.PythonError, creation_data.future.?);
    };

    if (address_list.len == 0) {
        python_c.raise_python_runtime_error("No addresses to bind to\x00");
        return set_future_exception(error.PythonError, creation_data.future.?);
    }

    server_data.address_list = try allocator.dupe(std.net.Address, address_list);
    errdefer allocator.free(server_data.address_list.?);

    const callback = CallbackManager.Callback{
        .func = &create_server_socket,
        .cleanup = null,
        .data = .{
            .user_data = server_data,
        },
    };
    try Loop.Scheduling.Soon.dispatch(loop_data, &callback);
}

fn server_host_resolved_callback(data: *const CallbackManager.CallbackData) !void {
    const server_data: *ServerSocketData = @alignCast(@ptrCast(data.user_data.?));
    errdefer server_data.deinit();

    if (data.cancelled) {
        python_c.raise_python_runtime_error("Server host resolution cancelled\x00");
        return set_future_exception(error.PythonError, server_data.creation_data.future.?);
    }

    z_server_host_resolved_callback(server_data) catch |err| {
        return set_future_exception(err, server_data.creation_data.future.?);
    };
}

// -----------------------------------------------------------------
// STEP 3: Create socket, bind, listen, start serving

fn z_create_server_socket(server_data: *ServerSocketData) !void {
    const creation_data = server_data.creation_data;
    const address_list = server_data.address_list orelse {
        python_c.raise_python_runtime_error("No addresses to bind to\x00");
        return set_future_exception(error.PythonError, creation_data.future.?);
    };

    const port: u16 = blk: {
        if (creation_data.py_port) |p| {
            const val = python_c.PyLong_AsInt(p);
            if (val == -1 and python_c.PyErr_Occurred() != null) return error.PythonError;
            break :blk @intCast(val);
        }
        break :blk 0;
    };

    const requested_family: ?i32 = if (creation_data.py_family) |f| blk: {
        const val = python_c.PyLong_AsLong(f);
        if (val == -1 and python_c.PyErr_Occurred() != null) return error.PythonError;
        break :blk @intCast(val);
    } else null;

    const backlog: c_int = blk: {
        if (creation_data.py_backlog) |b| {
            break :blk @intCast(python_c.PyLong_AsInt(b));
        }
        break :blk 100;
    };

    const reuse_address: bool = if (creation_data.py_reuse_address) |r|
        python_c.PyObject_IsTrue(r) != 0
    else
        true;

    const reuse_port: bool = if (creation_data.py_reuse_port) |r|
        python_c.PyObject_IsTrue(r) != 0
    else
        false;

    const servers_list = python_c.PyList_New(0) orelse return error.PythonError;
    errdefer python_c.py_decref(servers_list);

    var last_err: ?anyerror = null;

    for (address_list) |addr| {
        if (requested_family) |rf| {
            if (addr.any.family != rf) continue;
        }

        var addr_with_port = addr;
        addr_with_port.setPort(port);

        const flags: u32 = std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC;
        const fd = std.posix.socket(addr_with_port.any.family, flags, std.posix.IPPROTO.TCP) catch |err| {
            last_err = err;
            continue;
        };
        errdefer std.posix.close(fd);

        if (reuse_address) {
            const val: c_int = 1;
            std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&val)) catch {};
        }
        if (reuse_port) {
            const val: c_int = 1;
            std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, std.mem.asBytes(&val)) catch {};
        }

        std.posix.bind(fd, &addr_with_port.any, addr_with_port.getOsSockLen()) catch |err| {
            last_err = err;
            continue;
        };

        std.posix.listen(fd, @intCast(backlog)) catch |err| {
            last_err = err;
            continue;
        };

        const py_fd = python_c.PyLong_FromLong(@intCast(fd)) orelse return error.PythonError;
        defer python_c.py_decref(py_fd);

        const py_family_obj = python_c.PyLong_FromLong(@intCast(addr_with_port.any.family)) orelse return error.PythonError;
        defer python_c.py_decref(py_family_obj);

        const py_backlog_obj = python_c.PyLong_FromLong(@intCast(backlog)) orelse return error.PythonError;
        defer python_c.py_decref(py_backlog_obj);

        const protocol_factory = creation_data.protocol_factory.?;
        const loop_obj = creation_data.loop.?;

        const server = python_c.PyObject_CallFunction(
            @as(*python_c.PyObject, @ptrCast(StreamServer.StreamServerType.?)), "OOOOO\x00",
            @as(*python_c.PyObject, @ptrCast(loop_obj)), protocol_factory, py_fd, py_family_obj, py_backlog_obj
        ) orelse return error.PythonError;
        errdefer python_c.py_decref(server);

        const server_ptr: *StreamServer.StreamServerObject = @ptrCast(server);

        StreamServer.start_serving(server_ptr) catch |err| {
            python_c.py_decref(server);
            last_err = err;
            continue;
        };

        if (python_c.PyList_Append(servers_list, server) != 0) return error.PythonError;
        python_c.py_decref(server);
    }

    if (python_c.PyList_Size(servers_list) == 0) {
        if (last_err) |err| {
            if (err == error.AddressNotAvailable) {
                const exception = python_c.PyObject_CallFunction(
                    python_c.PyExc_OSError, "is\x00",
                    @as(c_int, 99), // EADDRNOTAVAIL
                    "Cannot assign requested address\x00"
                ) orelse return error.PythonError;
                python_c.PyErr_SetRaisedException(exception);
                return error.PythonError;
            }
            return err;
        }
        python_c.raise_python_runtime_error("Failed to bind to any address\x00");
        return error.PythonError;
    }
    const future_data = utils.get_data_ptr(Future, server_data.creation_data.future.?);
    try Future.Python.Result.future_fast_set_result(future_data, servers_list);
    python_c.py_decref(servers_list);
}

fn create_server_socket(data: *const CallbackManager.CallbackData) !void {
    const server_data: *ServerSocketData = @alignCast(@ptrCast(data.user_data.?));
    defer server_data.deinit();

    if (data.cancelled) {
        python_c.raise_python_runtime_error("Server socket creation cancelled\x00");
        return set_future_exception(error.PythonError, server_data.creation_data.future.?);
    }

    z_create_server_socket(server_data) catch |err| {
        return set_future_exception(err, server_data.creation_data.future.?);
    };
}

// -----------------------------------------------------------------

pub fn loop_create_server(
    self: ?*LoopObject, args: ?[*]?PyObject, nargs: isize, knames: ?PyObject
) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(
        z_loop_create_server, .{ self.?, args.?[0..@as(usize, @intCast(nargs))], knames },
    );
}
