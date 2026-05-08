const std = @import("std");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;
const utils = @import("utils");
const Loop = @import("../../../main.zig");
const LoopObject = Loop.Python.LoopObject;
const Future = @import("../../../../future/main.zig");
const FutureObject = Future.Python.FutureObject;
const DatagramTransport = @import("../../../../transports/datagram/main.zig");

inline fn z_loop_create_datagram_endpoint(
    self: *LoopObject, args: []?PyObject, knames: ?PyObject
) !*FutureObject {
    if (args.len < 1) {
        python_c.raise_python_value_error("protocol_factory is required");
        return error.PythonError;
    }

    const protocol_factory: PyObject = args[0].?;
    var py_local_addr: ?PyObject = null;
    var py_remote_addr: ?PyObject = null;
    var py_family: ?PyObject = null;
    var py_reuse_port: ?PyObject = null;
    var py_allow_broadcast: ?PyObject = null;
    var py_sock: ?PyObject = null;

    try python_c.parse_vector_call_kwargs(
        knames, args.ptr + args.len,
        &.{ "local_addr", "remote_addr", "family", "reuse_port", "allow_broadcast", "sock" },
        &.{ &py_local_addr, &py_remote_addr, &py_family, &py_reuse_port, &py_allow_broadcast, &py_sock },
    );

    if (python_c.PyCallable_Check(protocol_factory) <= 0) {
        python_c.raise_python_type_error("protocol_factory must be callable");
        return error.PythonError;
    }

    const fut = try Future.Python.Constructors.fast_new_future(self);

    const fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0);
    errdefer std.posix.close(fd);

    if (py_local_addr) |la| {
        const port: u16 = blk: {
            const po = python_c.PyTuple_GetItem(la, 1) orelse break :blk 0;
            break :blk @intCast(python_c.PyLong_AsInt(po));
        };
        const host = python_c.PyTuple_GetItem(la, 0) orelse return error.PythonError;
        var c_size: python_c.Py_ssize_t = 0;
        const host_ptr = python_c.PyUnicode_AsUTF8AndSize(host, &c_size) orelse return error.PythonError;
        const host_str = host_ptr[0..@intCast(c_size)];

        var parts: [4]u8 = undefined;
        var iter = std.mem.splitScalar(u8, host_str, '.');
        for (&parts) |*p| {
            const token = iter.next() orelse return error.PythonError;
            p.* = @intCast(std.fmt.parseInt(u8, token, 10) catch return error.PythonError);
        }

        var sa: std.posix.sockaddr.in = undefined;
        sa.family = std.posix.AF.INET;
        sa.port = std.mem.nativeToBig(u16, port);
        sa.addr = @bitCast(parts);
        try std.posix.bind(fd, @ptrCast(&sa), @sizeOf(std.posix.sockaddr.in));
    }

    if (py_reuse_port) |rp| {
        if (python_c.PyObject_IsTrue(rp) != 0) {
            const val: c_int = 1;
            try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, std.mem.asBytes(&val));
        }
    }

    if (py_allow_broadcast) |ab| {
        if (python_c.PyObject_IsTrue(ab) != 0) {
            const val: c_int = 1;
            try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.BROADCAST, std.mem.asBytes(&val));
        }
    }

    if (py_remote_addr) |ra| {
        const port: u16 = blk: {
            const po = python_c.PyTuple_GetItem(ra, 1) orelse break :blk 0;
            break :blk @intCast(python_c.PyLong_AsInt(po));
        };
        const host = python_c.PyTuple_GetItem(ra, 0) orelse return error.PythonError;
        var c_size: python_c.Py_ssize_t = 0;
        const host_ptr = python_c.PyUnicode_AsUTF8AndSize(host, &c_size) orelse return error.PythonError;
        const host_str = host_ptr[0..@intCast(c_size)];

        var parts: [4]u8 = undefined;
        var iter = std.mem.splitScalar(u8, host_str, '.');
        for (&parts) |*p| {
            const token = iter.next() orelse return error.PythonError;
            p.* = @intCast(std.fmt.parseInt(u8, token, 10) catch return error.PythonError);
        }

        var sa: std.posix.sockaddr.in = undefined;
        sa.family = std.posix.AF.INET;
        sa.port = std.mem.nativeToBig(u16, port);
        sa.addr = @bitCast(parts);
        try std.posix.connect(fd, @ptrCast(&sa), @sizeOf(std.posix.sockaddr.in));
    }

    const protocol = python_c.PyObject_CallNoArgs(protocol_factory) orelse return error.PythonError;
    const transport = try DatagramTransport.Constructors.new_datagram_transport(protocol, self, fd);
    errdefer python_c.py_decref(@ptrCast(transport));

    const connection_made = python_c.PyObject_GetAttrString(protocol, "connection_made") orelse return error.PythonError;
    defer python_c.py_decref(connection_made);
    const ret = python_c.PyObject_CallOneArg(connection_made, @ptrCast(transport)) orelse return error.PythonError;
    python_c.py_decref(ret);

    // Start reading
    try DatagramTransport.ReadTransport.queue_read(transport);

    const result_tuple = python_c.PyTuple_New(2) orelse return error.PythonError;
    if (python_c.PyTuple_SetItem(result_tuple, 0, @ptrCast(transport)) != 0) return error.PythonError;
    if (python_c.PyTuple_SetItem(result_tuple, 1, protocol) != 0) {
        python_c.py_decref(@ptrCast(transport));
        return error.PythonError;
    }

    const future_data = utils.get_data_ptr(Future, fut);
    Future.Python.Result.future_fast_set_result(future_data, result_tuple);
    python_c.py_decref(result_tuple);
    return fut;
}

pub fn loop_create_datagram_endpoint(
    self: ?*LoopObject, args: ?[*]?PyObject, nargs: isize, knames: ?PyObject
) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(
        z_loop_create_datagram_endpoint, .{ self.?, args.?[0..@as(usize, @intCast(nargs))], knames },
    );
}
