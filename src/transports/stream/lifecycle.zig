const std = @import("std");

const python_c = @import("python_c");
const PyObject = *python_c.PyObject;

const utils = @import("utils");

const Loop = @import("../../loop/main.zig");

const Stream = @import("main.zig");
const StreamTransportObject = Stream.StreamTransportObject;

const Constructors = @import("constructors.zig");

const WriteTransport = @import("../write_transport.zig");
const ReadTransport = @import("../read_transport.zig");

pub fn connection_lost_callback(transport_obj: PyObject, exception: PyObject) !void {
    const transport: *StreamTransportObject = @ptrCast(transport_obj);

    const read_transport = utils.get_data_ptr2(ReadTransport, "read_transport", transport);
    const write_transport = utils.get_data_ptr2(WriteTransport, "write_transport", transport);

    try close_transports(transport, read_transport, write_transport, exception);
} 

pub fn close_transports(
    transport: *StreamTransportObject,
    read_transport: *ReadTransport,
    write_transport: *WriteTransport,
    exception: PyObject
) !void {
    const closed_already = read_transport.closed or write_transport.closed;

    try read_transport.close();
    try write_transport.close();

    transport.is_reading = false;
    transport.is_writing = false;

    if (!closed_already) {
        const ret = python_c.PyObject_CallOneArg(transport.protocol_connection_lost.?, exception)
            orelse return error.PythonError;
        python_c.py_decref(ret);
    }
}

pub fn transport_close(self: ?*StreamTransportObject) callconv(.c) ?PyObject {
    const instance = self.?;

    if (instance.closed) {
        return python_c.get_py_none();
    }

    const read_transport = utils.get_data_ptr2(ReadTransport, "read_transport", instance);
    const write_transport = utils.get_data_ptr2(WriteTransport, "write_transport", instance);

    if (read_transport.closed and write_transport.closed) {
        instance.closed = true;

        return python_c.get_py_none();
    }

    const arg = python_c.get_py_none();
    close_transports(instance, read_transport, write_transport, arg) catch |err| {
        python_c.py_decref(arg);
        return utils.handle_zig_function_error(err, null);
    };

    const fd = instance.fd;
    if (fd >= 0) {
        _ = std.os.linux.close(fd);
        instance.fd = -1;
    }

    return arg;
}

pub fn transport_is_closing(self: ?*StreamTransportObject) callconv(.c) ?PyObject {
    const instance = self.?;

    if (instance.closed) {
        return python_c.get_py_true();
    }

    const read_transport = utils.get_data_ptr2(ReadTransport, "read_transport", instance);
    const write_transport = utils.get_data_ptr2(WriteTransport, "write_transport", instance);

    const closed = read_transport.closed and write_transport.closed;
    if (closed) {
        instance.closed = closed;
    }

    return python_c.PyBool_FromLong(@intCast(@intFromBool(closed)));
}

pub fn transport_get_protocol(self: ?*StreamTransportObject) callconv(.c) ?PyObject {
    return python_c.py_newref(self.?.protocol.?);
}

pub fn transport_set_protocol(self: ?*StreamTransportObject, new_protocol: ?PyObject) callconv(.c) ?PyObject {
    _ = Constructors.set_protocol(self.?, new_protocol.?) catch |err| {
        return utils.handle_zig_function_error(err, null);
    };

    return python_c.get_py_none();
}

pub fn transport_force_close(self: ?*StreamTransportObject, exc: ?PyObject) callconv(.c) ?PyObject {
    const instance = self.?;

    if (instance.closed) {
        return python_c.get_py_none();
    }
    instance.closed = true;

    const read_transport = utils.get_data_ptr2(ReadTransport, "read_transport", instance);
    const write_transport = utils.get_data_ptr2(WriteTransport, "write_transport", instance);

    read_transport.close() catch {};
    write_transport.close() catch {};

    instance.is_reading = false;
    instance.is_writing = false;

    const fd = instance.fd;
    if (fd >= 0) {
        _ = std.os.linux.close(fd);
        instance.fd = -1;
    }

    const exc_arg = if (exc) |e| python_c.py_newref(e) else python_c.get_py_none();
    defer python_c.py_decref(exc_arg);

    const connection_lost = instance.protocol_connection_lost orelse return python_c.get_py_none();
    const ret = python_c.PyObject_CallOneArg(connection_lost, exc_arg)
        orelse return null;
    python_c.py_decref(ret);

    return python_c.get_py_none();
}
