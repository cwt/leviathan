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
    const addr_buf = try alloc.alloc(u8, @sizeOf(std.posix.sockaddr.in));
    errdefer alloc.free(buf);

    const rd = try alloc.create(ReadData);
    rd.* = .{ .transport = self, .buf = buf, .addr_buf = addr_buf, .alloc = alloc };

    _ = try loop_data.io.queue(.{
        .PerformRead = .{
            .fd = self.fd,
            .data = .{ .buffer = buf },
            .callback = .{
                .func = &read_completed,
                .cleanup = &cleanup_read,
                .data = .{ .user_data = rd, .exception_context = null },
            },
            .offset = 0,
            .timeout = null,
            .zero_copy = false,
        },
    });
}

const ReadData = struct {
    transport: *DatagramTransport.DatagramTransportObject,
    buf: []u8,
    addr_buf: []u8,
    alloc: std.mem.Allocator,
};

fn cleanup_read(ptr: ?*anyopaque) void {
    const rd: *ReadData = @ptrCast(@alignCast(ptr.?));
    rd.alloc.free(rd.buf);
    rd.alloc.free(rd.addr_buf);
    rd.alloc.destroy(rd);
}

fn read_completed(data: *const CallbackManager.CallbackData) !void {
    const rd: *ReadData = @alignCast(@ptrCast(data.user_data.?));
    defer cleanup_read(@ptrCast(@alignCast(rd)));

    const self = rd.transport;
    if (data.cancelled or self.closed) return;

    const nread: usize = @intCast(@max(data.io_uring_res, 0));
    if (data.io_uring_err != .SUCCESS or nread == 0) {
        if (data.io_uring_err == .SUCCESS) {
            // Empty datagram or closed — re-arm
            try queue_read(self);
            return;
        }
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

    // Build source address from sockaddr_in
    const sa: *std.posix.sockaddr.in = @ptrCast(@alignCast(rd.addr_buf.ptr));
    var addr_buf: [32]u8 = undefined;
    const raw_addr = @as(u32, @bitCast(sa.addr));
    const addr_str = try std.fmt.bufPrint(&addr_buf, "{d}.{d}.{d}.{d}", .{
        (raw_addr >> 0) & 0xFF, (raw_addr >> 8) & 0xFF, (raw_addr >> 16) & 0xFF, (raw_addr >> 24) & 0xFF,
    });
    const py_host = python_c.PyUnicode_FromStringAndSize(addr_str.ptr, @intCast(addr_str.len)) orelse return error.PythonError;
    defer python_c.py_decref(py_host);
    const py_port = python_c.PyLong_FromLong(std.mem.bigToNative(u16, sa.port)) orelse return error.PythonError;
    defer python_c.py_decref(py_port);
    const py_addr = python_c.PyTuple_Pack(2, py_host, py_port) orelse return error.PythonError;
    defer python_c.py_decref(py_addr);

    // Deliver data to protocol
    if (self.protocol_datagram_received) |dr| {
        const py_data = python_c.PyBytes_FromStringAndSize(rd.buf.ptr, @intCast(nread)) orelse return error.PythonError;
        defer python_c.py_decref(py_data);
        const args = python_c.PyTuple_Pack(2, py_data, py_addr) orelse return error.PythonError;
        defer python_c.py_decref(args);
        const r = python_c.PyObject_CallObject(dr, args) orelse return error.PythonError;
        python_c.py_decref(r);
    }

    // Re-arm read
    try queue_read(self);
}
