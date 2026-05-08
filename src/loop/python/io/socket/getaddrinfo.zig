const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");
const CallbackManager = @import("callback_manager");

const Loop = @import("../../../main.zig");
const LoopObject = Loop.Python.LoopObject;
const Future = @import("../../../../future/main.zig");
const FutureObject = Future.Python.FutureObject;

const GetAddrInfoData = struct {
    future: *FutureObject,
    loop: *LoopObject,
    host: []u8,
    port: u16,
    allocator: std.mem.Allocator,
};

fn getaddrinfo_callback(data: *const CallbackManager.CallbackData) !void {
    const gaid: *GetAddrInfoData = @alignCast(@ptrCast(data.user_data.?));
    defer {
        gaid.allocator.free(gaid.host);
        gaid.allocator.destroy(gaid);
    }
    const loop_data = utils.get_data_ptr(Loop, gaid.loop);
    if (data.cancelled) {
        python_c.raise_python_runtime_error("getaddrinfo cancelled");
        return error.PythonError;
    }
    const address_list = try loop_data.dns.lookup(gaid.host, null) orelse {
        python_c.raise_python_runtime_error("Failed to resolve host");
        return error.PythonError;
    };
    const py_tuple = try build_result_tuple(address_list, gaid.port);
    const future_data2 = utils.get_data_ptr(Future, gaid.future);
    Future.Python.Result.future_fast_set_result(future_data2, py_tuple);
    python_c.py_decref(py_tuple);
}

fn build_result_tuple(address_list: []const std.net.Address, port: u16) !PyObject {
    const py_list = python_c.PyTuple_New(@intCast(address_list.len)) orelse return error.PythonError;
    errdefer python_c.py_decref(py_list);
    for (address_list, 0..) |addr, i| {
        var host_buf: [64]u8 = undefined;
        const host = blk: {
            if (addr.any.family == std.posix.AF.INET) {
                const raw = @as(u32, @bitCast(addr.in.sa.addr));
                break :blk try std.fmt.bufPrint(&host_buf, "{d}.{d}.{d}.{d}", .{
                    (raw >> 0) & 0xFF, (raw >> 8) & 0xFF, (raw >> 16) & 0xFF, (raw >> 24) & 0xFF,
                });
            }
            break :blk "::1";
        };
        const sockaddr = python_c.PyTuple_Pack(2,
            python_c.PyUnicode_FromStringAndSize(host.ptr, @intCast(host.len)) orelse return error.PythonError,
            python_c.PyLong_FromLong(@intCast(port)) orelse return error.PythonError,
        ) orelse return error.PythonError;
        const entry = python_c.PyTuple_Pack(5,
            python_c.PyLong_FromLong(std.posix.AF.INET),
            python_c.PyLong_FromLong(std.posix.SOCK.STREAM),
            python_c.PyLong_FromLong(0),
            python_c.get_py_none_without_incref(),
            sockaddr,
        ) orelse return error.PythonError;
        if (python_c.PyTuple_SetItem(py_list, @intCast(i), entry) != 0) {
            python_c.py_decref(entry);
            return error.PythonError;
        }
    }
    return py_list;
}

inline fn z_loop_getaddrinfo(self: *LoopObject, args: []?PyObject, knames: ?PyObject) !*FutureObject {
    if (args.len < 1) {
        python_c.raise_python_value_error("host argument is required");
        return error.PythonError;
    }
    const py_host = args[0].?;
    var py_port: ?PyObject = null;
    if (args.len > 1) py_port = args[1].?;

    var py_family: ?PyObject = null;
    var py_type: ?PyObject = null;
    var py_proto: ?PyObject = null;
    var py_flags: ?PyObject = null;
    try python_c.parse_vector_call_kwargs(
        knames, args.ptr + args.len,
        &.{ "family", "type", "proto", "flags" },
        &.{ &py_family, &py_type, &py_proto, &py_flags },
    );

    const port: u16 = blk: {
        if (py_port) |p| {
            const v = python_c.PyLong_AsInt(p);
            if (v == -1 and python_c.PyErr_Occurred() != null) return error.PythonError;
            break :blk @intCast(v);
        }
        break :blk 0;
    };

    const loop_data = utils.get_data_ptr(Loop, self);
    const alloc = loop_data.allocator;
    const fut = try Future.Python.Constructors.fast_new_future(self);
    const host_str = try get_string(py_host, alloc);

    const gaid = try alloc.create(GetAddrInfoData);
    errdefer alloc.destroy(gaid);
    gaid.* = .{ .future = fut, .loop = self, .host = host_str, .port = port, .allocator = alloc };

    const callback = CallbackManager.Callback{
        .func = &getaddrinfo_callback,
        .cleanup = null,
        .data = .{ .user_data = gaid, .exception_context = null },
    };
    const address_list = try loop_data.dns.lookup(host_str, &callback) orelse return fut;

    defer {
        alloc.free(host_str);
        alloc.destroy(gaid);
    }

    const py_tuple = try build_result_tuple(address_list, port);
    const future_data = utils.get_data_ptr(Future, fut);
    Future.Python.Result.future_fast_set_result(future_data, py_tuple);
    python_c.py_decref(py_tuple);
    return fut;
}

fn get_string(py_obj: PyObject, alloc: std.mem.Allocator) ![]u8 {
    var c_size: python_c.Py_ssize_t = 0;
    const ptr = python_c.PyUnicode_AsUTF8AndSize(py_obj, &c_size) orelse return error.PythonError;
    const size: usize = @intCast(c_size);
    const r = try alloc.alloc(u8, size);
    @memcpy(r, ptr[0..size]);
    return r;
}

pub fn loop_getaddrinfo(
    self: ?*LoopObject, args: ?[*]?PyObject, nargs: isize, knames: ?PyObject
) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(
        z_loop_getaddrinfo, .{ self.?, args.?[0..@as(usize, @intCast(nargs))], knames },
    );
}
