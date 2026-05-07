const std = @import("std");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;
const utils = @import("utils");
const CallbackManager = @import("callback_manager");
const Loop = @import("../../loop/main.zig");
const DatagramTransport = @import("main.zig");

pub fn z_datagram_sendto(self: *DatagramTransport.DatagramTransportObject, args: []?PyObject) !?PyObject {
    if (args.len < 1) {
        python_c.raise_python_value_error("data argument is required");
        return error.PythonError;
    }
    const data = args[0].?;
    if (self.closed) {
        python_c.raise_python_runtime_error("Transport is closed");
        return error.PythonError;
    }
    if (!self.is_writing) {
        return python_c.get_py_none();
    }

    var pbuffer: python_c.Py_buffer = undefined;
    if (python_c.PyObject_GetBuffer(data, &pbuffer, 0) < 0) return error.PythonError;
    defer python_c.PyBuffer_Release(&pbuffer);

    const len: usize = @intCast(pbuffer.len);
    if (len == 0) return python_c.get_py_none();

    const loop_data = utils.get_data_ptr(Loop, @as(*Loop.Python.LoopObject, @ptrCast(self.loop.?)));
    const iov = [1]std.posix.iovec_const{.{ .base = @ptrCast(pbuffer.buf.?), .len = len }};
    _ = try loop_data.io.queue(.{
        .PerformWriteV = .{
            .fd = self.fd,
            .data = &iov,
            .callback = .{
                .func = &write_completed,
                .cleanup = null,
                .data = .{ .user_data = self, .exception_context = null },
            },
            .offset = 0,
            .timeout = null,
            .zero_copy = false,
        },
    });

    self.buffer_size += len;
    if (self.buffer_size > self.writing_high_water_mark and self.is_writing) {
        self.is_writing = false;
        if (self.protocol) |proto| {
            const pw = python_c.PyObject_GetAttrString(proto, "pause_writing") orelse return error.PythonError;
            defer python_c.py_decref(pw);
            const r = python_c.PyObject_CallNoArgs(pw) orelse return error.PythonError;
            python_c.py_decref(r);
        }
    }

    return python_c.get_py_none();
}

fn write_completed(data: *const CallbackManager.CallbackData) !void {
    const self: *DatagramTransport.DatagramTransportObject = @alignCast(@ptrCast(data.user_data.?));
    if (data.cancelled) return;
    if (data.io_uring_err != .SUCCESS) {
        if (self.protocol_error_received) |er| {
            const exc = python_c.PyObject_CallFunction(
                python_c.PyExc_OSError, "Ls", @as(c_long, @intFromEnum(data.io_uring_err)), "Write error"
            ) orelse return error.PythonError;
            defer python_c.py_decref(exc);
            const r = python_c.PyObject_CallOneArg(er, exc) orelse return error.PythonError;
            python_c.py_decref(r);
        }
        return;
    }

    const written: usize = @intCast(@max(data.io_uring_res, 0));
    if (self.buffer_size >= written) {
        self.buffer_size -= written;
    } else {
        self.buffer_size = 0;
    }

    if (!self.is_writing and self.buffer_size <= self.writing_low_water_mark) {
        self.is_writing = true;
        if (self.protocol) |proto| {
            const rw = python_c.PyObject_GetAttrString(proto, "resume_writing") orelse return error.PythonError;
            defer python_c.py_decref(rw);
            const r = python_c.PyObject_CallNoArgs(rw) orelse return error.PythonError;
            python_c.py_decref(r);
        }
    }
}

pub fn z_datagram_set_write_buffer_limits(self: *DatagramTransport.DatagramTransportObject, args: []?PyObject) !?PyObject {
    if (args.len < 1) return error.InvalidArgs;
    const py_high = args[0].?;
    const py_low: ?PyObject = if (args.len > 1 and !python_c.is_none(args[1].?)) args[1].? else null;

    const high = @as(usize, @intCast(python_c.PyLong_AsUnsignedLongLong(py_high)));
    const low: usize = if (py_low) |l| @as(usize, @intCast(python_c.PyLong_AsUnsignedLongLong(l))) else high / 4;
    self.writing_high_water_mark = high;
    self.writing_low_water_mark = @min(low, high);
    return python_c.get_py_none();
}
