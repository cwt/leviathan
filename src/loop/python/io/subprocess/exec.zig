const std = @import("std");
const python_c = @import("python_c");
const PyObject = *python_c.PyObject;
const utils = @import("utils");
const Loop = @import("../../../main.zig");
const LoopObject = Loop.Python.LoopObject;
const Future = @import("../../../../future/main.zig");
const FutureObject = Future.Python.FutureObject;
const SubprocessTransport = @import("../../../../transports/subprocess/transport.zig");

inline fn get_string(py_obj: PyObject, alloc: std.mem.Allocator) ![]u8 {
    var c_size: python_c.Py_ssize_t = 0;
    const ptr = python_c.PyUnicode_AsUTF8AndSize(py_obj, &c_size) orelse return error.PythonError;
    const sz: usize = @intCast(c_size);
    const r = try alloc.alloc(u8, sz);
    @memcpy(r, ptr[0..sz]);
    return r;
}

inline fn z_loop_subprocess_exec(
    self: *LoopObject, args: []?PyObject, knames: ?PyObject
) !*FutureObject {
    _ = knames;
    if (args.len < 1) {
        python_c.raise_python_value_error("protocol_factory is required");
        return error.PythonError;
    }
    const protocol_factory: PyObject = args[0].?;
    var py_program: ?PyObject = null;
    if (args.len > 1) py_program = args[1].?;

    if (python_c.PyCallable_Check(protocol_factory) <= 0) {
        python_c.raise_python_type_error("protocol_factory must be callable");
        return error.PythonError;
    }
    if (py_program == null) {
        python_c.raise_python_value_error("program args required");
        return error.PythonError;
    }

    const loop_data = utils.get_data_ptr(Loop, self);
    const alloc = loop_data.allocator;
    const fut = try Future.Python.Constructors.fast_new_future(self);

    // Parse the program name and args from the sequence
    var prog_args = std.ArrayList([]const u8){};
    defer {
        for (prog_args.items) |s| alloc.free(s);
        prog_args.deinit(alloc);
    }
    const iter = python_c.PyObject_GetIter(py_program.?) orelse return error.PythonError;
    defer python_c.py_decref(iter);
    while (true) {
        const item = python_c.PyIter_Next(iter) orelse break;
        const s = try get_string(item, alloc);
        try prog_args.append(alloc, s);
    }
    if (prog_args.items.len == 0) return error.PythonError;

    // Build argv with trailing null
    var raw_argv = try alloc.alloc(?[*:0]u8, prog_args.items.len + 1);
    defer alloc.free(raw_argv);
    for (prog_args.items, 0..) |s, i| {
        raw_argv[i] = @ptrCast(try alloc.dupeZ(u8, s));
    }
    raw_argv[prog_args.items.len] = null;
    defer for (prog_args.items, 0..) |_, i| {
        if (raw_argv[i]) |p| alloc.free(std.mem.span(p));
    };

    const protocol = python_c.PyObject_CallNoArgs(protocol_factory) orelse return error.PythonError;
    const transport = try SubprocessTransport.spawn_and_create(
        protocol, self, prog_args.items[0], prog_args.items
    );
    errdefer python_c.py_decref(@ptrCast(transport));

    const connection_made = python_c.PyObject_GetAttrString(protocol, "connection_made") orelse return error.PythonError;
    defer python_c.py_decref(connection_made);
    const ret = python_c.PyObject_CallOneArg(connection_made, @ptrCast(transport)) orelse return error.PythonError;
    python_c.py_decref(ret);

    const future_data = utils.get_data_ptr(Future, fut);
    Future.Python.Result.future_fast_set_result(future_data, @ptrCast(transport));
    return fut;
}

pub fn loop_subprocess_exec(
    self: ?*LoopObject, args: ?[*]?PyObject, nargs: isize, knames: ?PyObject
) callconv(.c) ?*FutureObject {
    return utils.execute_zig_function(
        z_loop_subprocess_exec, .{ self.?, args.?[0..@as(usize, @intCast(nargs))], knames },
    );
}
