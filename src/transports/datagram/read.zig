const std = @import("std");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;
const utils = @import("utils");
const CallbackManager = @import("callback_manager");
const Loop = @import("../../loop/main.zig");
const DatagramTransport = @import("main.zig");

const MAX_DGRAM: usize = 65536;

pub fn queue_read(self: *DatagramTransport.DatagramTransportObject) !void {
    if (self.closed or self.fd < 0) return;

    const loop_data = utils.get_data_ptr(Loop, @as(*Loop.Python.LoopObject, @ptrCast(self.loop.?)));
    const alloc = loop_data.allocator;

    const buf = try alloc.alloc(u8, MAX_DGRAM);
    errdefer alloc.free(buf);

    const rd = try alloc.create(ReadData);
    errdefer alloc.destroy(rd);

    rd.* = .{
        .transport = self,
        .buf = buf,
        .alloc = alloc,
        .msg = undefined,
        .iov = undefined,
        .addr = undefined,
    };

    rd.iov = .{ .base = buf.ptr, .len = buf.len };
    rd.msg = .{
        .name = @ptrCast(&rd.addr),
        .namelen = @sizeOf(std.posix.sockaddr.storage),
        .iov = @ptrCast(&rd.iov),
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };

    _ = try loop_data.io.queue(.{
        .PerformRecvMsg = .{
            .fd = self.fd,
            .msg = &rd.msg,
            .callback = .{
                .func = &read_completed,
                .cleanup = &cleanup_read,
                .data = .{ .user_data = rd, .exception_context = null },
            },
            .flags = 0,
        },
    });
}

const ReadData = struct {
    transport: *DatagramTransport.DatagramTransportObject,
    buf: []u8,
    alloc: std.mem.Allocator,
    msg: std.posix.msghdr,
    iov: std.posix.iovec,
    addr: std.posix.sockaddr.storage,
};

fn cleanup_read(ptr: ?*anyopaque) void {
    const rd: *ReadData = @ptrCast(@alignCast(ptr.?));
    rd.alloc.free(rd.buf);
    rd.alloc.destroy(rd);
}

fn read_completed(data: *const CallbackManager.CallbackData) !void {
    const rd: *ReadData = @alignCast(@ptrCast(data.user_data.?));
    defer cleanup_read(@ptrCast(@alignCast(rd)));

    const self = rd.transport;
    if (data.cancelled or self.closed) return;

    if (data.io_uring_err != .SUCCESS) {
        // Error — notify protocol and re-arm
        if (self.protocol_error_received) |er| {
            const exc = python_c.PyObject_CallFunction(
                python_c.PyExc_OSError, "Ls", @as(c_long, @intFromEnum(data.io_uring_err)), "Read error"
            ) orelse return error.PythonError;
            defer python_c.py_decref(exc);
            const r = python_c.PyObject_CallOneArg(er, exc) orelse return error.PythonError;
            python_c.py_decref(r);
        }
        try queue_read(self);
        return;
    }

    const nread: usize = @intCast(@max(data.io_uring_res, 0));
    if (nread == 0) {
        // Empty datagram — re-arm
        try queue_read(self);
        return;
    }

    // Deliver data to protocol
    if (self.protocol_datagram_received) |dr| {
        const py_data = python_c.PyBytes_FromStringAndSize(rd.buf.ptr, @intCast(nread)) orelse return error.PythonError;
        defer python_c.py_decref(py_data);
        
        // Format source address
        const py_addr = (try format_sockaddr(&rd.addr, rd.msg.namelen)) orelse python_c.get_py_none();
        defer python_c.py_decref(py_addr);

        const args = python_c.PyTuple_Pack(2, py_data, py_addr) orelse return error.PythonError;
        defer python_c.py_decref(args);
        const r = python_c.PyObject_CallObject(dr, args) orelse return error.PythonError;
        python_c.py_decref(r);
    }

    // Re-arm read
    try queue_read(self);
}

fn format_sockaddr(storage: *const std.posix.sockaddr.storage, len: std.posix.socklen_t) !?PyObject {
    if (len == 0) return null;

    switch (storage.family) {
        std.posix.AF.INET => {
            const sa: *const std.posix.sockaddr.in = @ptrCast(storage);
            var buf: [22]u8 = undefined;
            const addr = std.net.Address.initIp4(@as([4]u8, @bitCast(sa.addr)), std.mem.bigToNative(u16, sa.port));
            const addr_str = try std.fmt.bufPrint(&buf, "{any}", .{addr});
            // Split into host and port
            const colon_idx = std.mem.lastIndexOfScalar(u8, addr_str, ':') orelse return null;
            const host = addr_str[0..colon_idx];
            const port = addr.getPort();

            const py_host = python_c.PyUnicode_FromStringAndSize(host.ptr, @intCast(host.len)) orelse return error.PythonError;
            defer python_c.py_decref(py_host);
            const py_port = python_c.PyLong_FromLong(port) orelse return error.PythonError;
            defer python_c.py_decref(py_port);
            return python_c.PyTuple_Pack(2, py_host, py_port);
        },
        std.posix.AF.INET6 => {
            const sa: *const std.posix.sockaddr.in6 = @ptrCast(storage);
            var buf: [64]u8 = undefined;
            const addr = std.net.Address.initIp6(sa.addr, std.mem.bigToNative(u16, sa.port), sa.flowinfo, sa.scope_id);
            const addr_str = try std.fmt.bufPrint(&buf, "{any}", .{addr});
            
            // IPv6 format from std.fmt is [addr]:port
            const start = if (addr_str[0] == '[') @as(usize, 1) else @as(usize, 0);
            const end = std.mem.lastIndexOfScalar(u8, addr_str, ']') orelse addr_str.len;
            const host = addr_str[start..end];
            const port = addr.getPort();

            const py_host = python_c.PyUnicode_FromStringAndSize(host.ptr, @intCast(host.len)) orelse return error.PythonError;
            defer python_c.py_decref(py_host);
            const py_port = python_c.PyLong_FromLong(port) orelse return error.PythonError;
            defer python_c.py_decref(py_port);
            // IPv6 addr tuple is (host, port, flowinfo, scopeid)
            const py_flow = python_c.PyLong_FromUnsignedLongLong(sa.flowinfo) orelse return error.PythonError;
            defer python_c.py_decref(py_flow);
            const py_scope = python_c.PyLong_FromUnsignedLongLong(sa.scope_id) orelse return error.PythonError;
            defer python_c.py_decref(py_scope);
            return python_c.PyTuple_Pack(4, py_host, py_port, py_flow, py_scope);
        },
        else => return null,
    }
}
