const _c = @cImport({
    @cDefine("PY_SSIZE_T_CLEAN", {});
    @cInclude("Python.h");
});

pub const PyObject = _c.PyObject;
pub const PyTypeObject = _c.PyTypeObject;
pub const PyMethodDef = _c.PyMethodDef;
pub const PyMemberDef = _c.PyMemberDef;
pub const PyModuleDef = _c.PyModuleDef;
pub const PyType_Spec = _c.PyType_Spec;
pub const PyType_Slot = _c.PyType_Slot;
pub const PyAsyncMethods = _c.PyAsyncMethods;
pub const Py_buffer = _c.Py_buffer;
pub const Py_ssize_t = _c.Py_ssize_t;
pub const PySendResult = _c.PySendResult;
pub const visitproc = _c.visitproc;

pub const Py_TPFLAGS_DEFAULT = _c.Py_TPFLAGS_DEFAULT;
pub const Py_TPFLAGS_BASETYPE = _c.Py_TPFLAGS_BASETYPE;
pub const Py_TPFLAGS_HAVE_GC = _c.Py_TPFLAGS_HAVE_GC;
pub const Py_TPFLAGS_LONG_SUBCLASS = _c.Py_TPFLAGS_LONG_SUBCLASS;
pub const Py_TPFLAGS_UNICODE_SUBCLASS = _c.Py_TPFLAGS_UNICODE_SUBCLASS;
pub const Py_TPFLAGS_BASE_EXC_SUBCLASS = _c.Py_TPFLAGS_BASE_EXC_SUBCLASS;

pub const Py_READONLY = _c.Py_READONLY;
pub const Py_T_BOOL = _c.Py_T_BOOL;
pub const Py_T_OBJECT_EX = _c.Py_T_OBJECT_EX;
pub const _Py_T_OBJECT = _c._Py_T_OBJECT;
pub const Py_tp_new = _c.Py_tp_new;
pub const Py_tp_init = _c.Py_tp_init;
pub const Py_tp_dealloc = _c.Py_tp_dealloc;
pub const Py_tp_clear = _c.Py_tp_clear;
pub const Py_tp_traverse = _c.Py_tp_traverse;
pub const Py_tp_methods = _c.Py_tp_methods;
pub const Py_tp_members = _c.Py_tp_members;
pub const Py_tp_doc = _c.Py_tp_doc;

pub const METH_NOARGS = _c.METH_NOARGS;
pub const METH_VARARGS = _c.METH_VARARGS;
pub const METH_KEYWORDS = _c.METH_KEYWORDS;
pub const METH_O = _c.METH_O;
pub const METH_FASTCALL = _c.METH_FASTCALL;

pub const PYGEN_ERROR = _c.PYGEN_ERROR;
pub const PYGEN_NEXT = _c.PYGEN_NEXT;
pub const PYGEN_RETURN = _c.PYGEN_RETURN;

pub const Py_MOD_GIL_NOT_USED = _c.Py_MOD_GIL_NOT_USED;

pub const PyBUF_WRITABLE = _c.PyBUF_WRITABLE;

pub const Py_IsTrue = _c.Py_IsTrue;
pub const Py_TYPE = _c.Py_TYPE;

pub const PyType_GenericNew = _c.PyType_GenericNew;
pub const PyType_Ready = _c.PyType_Ready;
pub const PyType_FromSpecWithBases = _c.PyType_FromSpecWithBases;

pub const PyErr_SetString = _c.PyErr_SetString;
pub const PyErr_SetNone = _c.PyErr_SetNone;
pub const PyErr_SetObject = _c.PyErr_SetObject;
pub const PyErr_Occurred = _c.PyErr_Occurred;
pub const PyErr_GetRaisedException = _c.PyErr_GetRaisedException;
pub const PyErr_SetRaisedException = _c.PyErr_SetRaisedException;
pub const PyErr_GivenExceptionMatches = _c.PyErr_GivenExceptionMatches;

pub extern var PyExc_ValueError: ?*PyObject;
pub extern var PyExc_TypeError: ?*PyObject;
pub extern var PyExc_RuntimeError: ?*PyObject;
pub extern var PyExc_MemoryError: ?*PyObject;
pub extern var PyExc_OSError: ?*PyObject;
pub extern var PyExc_StopIteration: ?*PyObject;
pub extern var PyExc_KeyboardInterrupt: ?*PyObject;
pub extern var PyExc_SystemExit: ?*PyObject;
pub extern var PyExc_NotImplementedError: ?*PyObject;
pub extern var PyExc_BaseExceptionGroup: ?*PyObject;

pub const PyBool_FromLong = _c.PyBool_FromLong;
pub extern var PyBool_Type: PyTypeObject;
pub const PyBytes_FromStringAndSize = _c.PyBytes_FromStringAndSize;
pub const PyLong_FromLong = _c.PyLong_FromLong;
pub const PyLong_FromUnsignedLongLong = _c.PyLong_FromUnsignedLongLong;
pub const PyLong_AsInt = _c.PyLong_AsInt;
pub const PyLong_AsLong = _c.PyLong_AsLong;
pub const PyLong_AsLongLong = _c.PyLong_AsLongLong;
pub const PyLong_AsUnsignedLong = _c.PyLong_AsUnsignedLong;
pub const PyLong_AsUnsignedLongLong = _c.PyLong_AsUnsignedLongLong;
pub const PyFloat_AsDouble = _c.PyFloat_AsDouble;
pub const PyFloat_FromDouble = _c.PyFloat_FromDouble;

pub const PyTuple_New = _c.PyTuple_New;
pub const PyTuple_SetItem = _c.PyTuple_SetItem;
pub const PyTuple_GetItem = _c.PyTuple_GetItem;
pub const PyTuple_Size = _c.PyTuple_Size;
pub const PyTuple_Pack = _c.PyTuple_Pack;

pub const PyUnicode_FromString = _c.PyUnicode_FromString;
pub const PyUnicode_FromStringAndSize = _c.PyUnicode_FromStringAndSize;
pub const PyUnicode_AsUTF8 = _c.PyUnicode_AsUTF8;
pub const PyUnicode_AsUTF8AndSize = _c.PyUnicode_AsUTF8AndSize;
pub const PyUnicode_CompareWithASCIIString = _c.PyUnicode_CompareWithASCIIString;

pub const PyCapsule_New = _c.PyCapsule_New;
pub const PyCapsule_GetPointer = _c.PyCapsule_GetPointer;

pub const PyCFunction_New = _c.PyCFunction_New;

pub const PyCallable_Check = _c.PyCallable_Check;

pub const PyObject_GetAttrString = _c.PyObject_GetAttrString;
pub const PyObject_SetAttrString = _c.PyObject_SetAttrString;
pub const PyObject_CallNoArgs = _c.PyObject_CallNoArgs;
pub const PyObject_CallOneArg = _c.PyObject_CallOneArg;
pub const PyObject_CallObject = _c.PyObject_CallObject;
pub const PyObject_CallFunction = _c.PyObject_CallFunction;
pub const PyObject_CallFunctionObjArgs = _c.PyObject_CallFunctionObjArgs;
pub const PyObject_Vectorcall = _c.PyObject_Vectorcall;
pub const PyObject_GetIter = _c.PyObject_GetIter;
pub const PyObject_GetBuffer = _c.PyObject_GetBuffer;
pub const PyObject_CheckBuffer = _c.PyObject_CheckBuffer;
pub const PyObject_IsInstance = _c.PyObject_IsInstance;
pub const PyObject_IsTrue = _c.PyObject_IsTrue;
pub const PyObject_Repr = _c.PyObject_Repr;
pub const PyObject_Str = _c.PyObject_Str;
pub const PyObject_ClearWeakRefs = _c.PyObject_ClearWeakRefs;
pub const PyObject_GC_UnTrack = _c.PyObject_GC_UnTrack;

pub const PyDict_New = _c.PyDict_New;
pub const PyDict_SetItemString = _c.PyDict_SetItemString;
pub const PyObject_Call = _c.PyObject_Call;

pub const PyOS_BeforeFork = _c.PyOS_BeforeFork;
pub const PyOS_AfterFork_Parent = _c.PyOS_AfterFork_Parent;
pub const PyOS_AfterFork_Child = _c.PyOS_AfterFork_Child;

pub const PyBuffer_Release = _c.PyBuffer_Release;

pub const PyImport_ImportModule = _c.PyImport_ImportModule;

pub const PyModule_Create = _c.PyModule_Create;
pub const PyModule_AddObject = _c.PyModule_AddObject;

pub const PyUnstable_Module_SetGIL = _c.PyUnstable_Module_SetGIL;

pub const PyIter_Next = _c.PyIter_Next;
pub const PyIter_Send = _c.PyIter_Send;

pub const PyArg_ParseTuple = _c.PyArg_ParseTuple;
pub const PyArg_ParseTupleAndKeywords = _c.PyArg_ParseTupleAndKeywords;

pub const PyType_IsSubtype = _c.PyType_IsSubtype;

pub const PyException_SetCause = _c.PyException_SetCause;

pub const PyContext_CopyCurrent = _c.PyContext_CopyCurrent;
pub const PyContext_Enter = _c.PyContext_Enter;
pub const PyContext_Exit = _c.PyContext_Exit;
pub extern var PyContext_Type: PyTypeObject;

pub const PyStopIterationObject = _c.PyStopIterationObject;

pub extern var _Py_TrueStruct: PyObject;
pub extern var _Py_FalseStruct: PyObject;
pub extern var _Py_NoneStruct: PyObject;
pub const _Py_MergeZeroLocalRefcount = _c._Py_MergeZeroLocalRefcount;
pub const _Py_DecRefShared = _c._Py_DecRefShared;

pub const E = _c.E;
pub const EINTR = _c.EINTR;
pub const EAGAIN = _c.EAGAIN;
pub const ESHUTDOWN = _c.ESHUTDOWN;
pub const ETIME = _c.ETIME;
pub const ECANCELED = _c.ECANCELED;
pub const ENOBUFS = _c.ENOBUFS;
pub const EBADF = _c.EBADF;
pub const ENOTSOCK = _c.ENOTSOCK;
pub const EOPNOTSUPP = _c.EOPNOTSUPP;
pub const ECONNREFUSED = _c.ECONNREFUSED;

pub const sockaddr = _c.sockaddr;
pub const sockaddr_in = _c.sockaddr_in;
pub const sockaddr_in6 = _c.sockaddr_in6;
pub const sockaddr_un = _c.sockaddr_un;
pub const socklen_t = _c.socklen_t;

pub const AF_INET = _c.AF_INET;
pub const AF_INET6 = _c.AF_INET6;
pub const AF_UNIX = _c.AF_UNIX;

pub const SOCK_STREAM = _c.SOCK_STREAM;
pub const SOCK_DGRAM = _c.SOCK_DGRAM;
pub const SOCK_NONBLOCK = _c.SOCK_NONBLOCK;
pub const SOCK_CLOEXEC = _c.SOCK_CLOEXEC;

pub const SO_REUSEADDR = _c.SO_REUSEADDR;
pub const SO_REUSEPORT = _c.SO_REUSEPORT;
pub const SOL_SOCKET = _c.SOL_SOCKET;

pub const SIGINT = _c.SIGINT;
pub const SIGTERM = _c.SIGTERM;
pub const SIGKILL = _c.SIGKILL;
pub const SIGCHLD = _c.SIGCHLD;
pub const SIGCONT = _c.SIGCONT;
pub const SIGHUP = _c.SIGHUP;
pub const SIGPIPE = _c.SIGPIPE;
pub const SIG_DFL = _c.SIG_DFL;

pub const sigset_t = _c.sigset_t;
pub const sigaction = _c.sigaction;
pub const sigemptyset = _c.sigemptyset;
pub const sigaddset = _c.sigaddset;
pub const sigdelset = _c.sigdelset;
pub const sigaction_fn = _c.sigaction_fn;
pub const SA_SIGINFO = _c.SA_SIGINFO;
pub const SA_RESTART = _c.SA_RESTART;

pub const clockid_t = _c.clockid_t;
pub const timespec = _c.timespec;
pub const clock_gettime = _c.clock_gettime;
pub const CLOCK_MONOTONIC = _c.CLOCK_MONOTONIC;

pub const O_CLOEXEC = _c.O_CLOEXEC;
pub const O_NONBLOCK = _c.O_NONBLOCK;

pub const STDIN_FILENO = _c.STDIN_FILENO;
pub const STDOUT_FILENO = _c.STDOUT_FILENO;
pub const STDERR_FILENO = _c.STDERR_FILENO;

pub const pid_t = _c.pid_t;

const builtin = @import("builtin");
const std = @import("std");

pub inline fn get_type(obj: *Python.PyObject) *Python.PyTypeObject {
    return obj.ob_type orelse unreachable;
}

pub inline fn is_type(obj: *Python.PyObject, @"type": *Python.PyTypeObject) bool {
    return get_type(obj) == @"type";
}

pub inline fn type_check(obj: *Python.PyObject, @"type": *Python.PyTypeObject) bool {
    return is_type(obj, @"type") or Python.PyType_IsSubtype(get_type(obj), @"type") != 0;
}

// -------------------------------------------------
// Problems when compiling with Python3.13.1t
inline fn type_hasfeature(arg_type: *Python.PyTypeObject, arg_feature: c_ulong) bool {
    const flags: c_ulong = blk: {
        if (builtin.single_threaded) {
            break :blk arg_type.tp_flags;
        }else{
            break :blk @atomicLoad(c_ulong, &arg_type.tp_flags, .unordered);
        }
    };
    return (flags & arg_feature) == 0;
}

pub inline fn long_check(obj: *Python.PyObject) bool {
    return type_hasfeature(get_type(obj), Python.Py_TPFLAGS_LONG_SUBCLASS);
}

pub inline fn unicode_check(obj: *Python.PyObject) bool {
    return type_hasfeature(get_type(obj), Python.Py_TPFLAGS_UNICODE_SUBCLASS);
}

pub inline fn exception_check(obj: *Python.PyObject) bool {
    return type_hasfeature(get_type(obj), Python.Py_TPFLAGS_BASE_EXC_SUBCLASS);
}
// -------------------------------------------------

pub inline fn get_py_true() *Python.PyObject {
    const py_true_struct: *Python.PyObject = @ptrCast(&Python._Py_TrueStruct);
    Python.py_incref(py_true_struct);
    return py_true_struct;
}

pub inline fn get_py_false() *Python.PyObject {
    const py_false_struct: *Python.PyObject = @ptrCast(&Python._Py_FalseStruct);
    Python.py_incref(py_false_struct);
    return py_false_struct;
}

pub inline fn get_py_none() *Python.PyObject {
    const py_none_struct: *Python.PyObject = @ptrCast(&Python._Py_NoneStruct);
    Python.py_incref(py_none_struct);
    return py_none_struct;
}

pub inline fn get_py_none_without_incref() *Python.PyObject {
    return @ptrCast(&Python._Py_NoneStruct);
}

pub inline fn is_none(obj: *Python.PyObject) bool {
    const py_none_struct: *Python.PyObject = @ptrCast(&Python._Py_NoneStruct);
    return obj == py_none_struct;
}

inline fn get_refcnt_ptr(obj: *Python.PyObject) *Python.Py_ssize_t {
    return @ptrCast(obj);
}

inline fn get_refcnt_split(obj: *Python.PyObject) *[2]u32 {
    return @ptrCast(obj);
}

pub inline fn py_incref(op: *Python.PyObject) void {
    if (@intFromPtr(op) <= 0xFFFF) return;
    _c.Py_IncRef(op);
}

pub inline fn py_xincref(op: ?*Python.PyObject) void {
    if (op) |o| {
        _c.Py_IncRef(o);
    }
}

pub fn py_decref(op: *Python.PyObject) void {
    if (@intFromPtr(op) <= 0xFFFF) return;
    _c.Py_DecRef(op);
}

pub inline fn py_xdecref(op: ?*Python.PyObject) void {
    if (op) |o| {
        if (@intFromPtr(o) > 0xFFFF) {
            _c.Py_DecRef(o);
        }
    }
}

pub inline fn py_decref_and_set_null(op: *?*Python.PyObject) void {
    if (op.*) |o| {
        py_decref(o);
        op.* = null;
    }
}

pub inline fn py_newref(op: anytype) @TypeOf(op) {
    Python.py_incref(@ptrCast(op));
    return op;
}

pub fn py_visit(object: anytype, visit: Python.visitproc, arg: ?*anyopaque) c_int {
    const visit_ptr = visit.?;
    const fields = comptime std.meta.fields(@typeInfo(@TypeOf(object)).pointer.child);
    loop: inline for (fields) |field| {
        const field_name = field.name;
        const value: ?*Python.PyObject = switch (@typeInfo(field.type)) {
            .optional => |data| blk: {
                switch (@typeInfo(data.child)) {
                    .pointer => |data2| {
                        if (data2.child != Python.PyObject) {
                            continue :loop;
                        }
                        break :blk @field(object, field_name);
                    },
                    else => continue :loop
                }
            },
            .pointer => |data| blk: {
                if (data.child != Python.PyObject) {
                    continue :loop;
                }
                break :blk @field(object, field_name);
            },
            .@"struct" => {
                const vret = py_visit(&@field(object, field_name), visit, arg);
                if (vret != 0) {
                    return vret;
                }

                continue :loop;
            },
            else => continue :loop
        };

        if (value) |v| {
            const vret = visit_ptr(v, arg);
            if (vret != 0) {
                return vret;
            }
        }
    }

    return 0;
}

pub inline fn parse_vector_call_kwargs(
    knames: ?*Python.PyObject, args_ptr: [*]?*Python.PyObject,
    comptime names: []const []const u8,
    py_objects: []const *?*Python.PyObject
) !void {
    const len = names.len;
    if (len != py_objects.len) {
        return error.InvalidLength;
    }

    var _py_objects: [len]?*Python.PyObject = .{null} ** len;

    if (knames) |kwargs| {
        const kwargs_len = Python.PyTuple_Size(kwargs);
        const args = args_ptr[0..@as(usize, @intCast(kwargs_len))];
        if (kwargs_len < 0) {
            return error.PythonError;
        }else if (kwargs_len <= len) {
            loop: for (args, 0..) |arg, i| {
                const key = Python.PyTuple_GetItem(kwargs, @intCast(i)) orelse return error.PythonError;
                inline for (names, &_py_objects) |name, *obj| {
                    if (Python.PyUnicode_CompareWithASCIIString(key, @ptrCast(name)) == 0) {
                        obj.* = arg.?;
                        continue :loop;
                    }
                }

                Python.raise_python_value_error("Invalid keyword argument\x00");
                return error.PythonError;
            }
        }else if (kwargs_len > len) {
            Python.raise_python_value_error("Too many keyword arguments\x00");
            return error.PythonError;
        }
    }

    for (py_objects, &_py_objects) |py_obj, py_obj2| {
        if (py_obj2) |v| {
            py_obj.* = py_newref(v);
        }
    }
}

pub inline fn raise_python_error(exception: *Python.PyObject, message: ?[:0]const u8) void {
    if (message) |msg| {
        Python.PyErr_SetString(exception, @ptrCast(msg));
    }else{
        Python.PyErr_SetNone(exception);
    }
}

pub inline fn raise_python_value_error(message: ?[:0]const u8) void {
    raise_python_error(Python.PyExc_ValueError.?, message);
}

pub inline fn raise_python_type_error(message: ?[:0]const u8) void {
    raise_python_error(Python.PyExc_TypeError.?, message);
}

pub inline fn raise_python_runtime_error(message: ?[:0]const u8) void {
    raise_python_error(Python.PyExc_RuntimeError.?, message);
}

pub inline fn initialize_object_fields(
    object: anytype, comptime exclude_fields: []const []const u8
) void {
    const fields = comptime std.meta.fields(@typeInfo(@TypeOf(object)).pointer.child);
    loop: inline for (fields) |field| {
        const field_name = field.name;

        inline for (exclude_fields) |exclude_field| {
            if (comptime std.mem.eql(u8, field_name, exclude_field)) {
                continue :loop;
            }
        }

        @field(object, field_name) = comptime std.mem.zeroes(field.type);
    }
}

pub fn deinitialize_object_fields(
    object: anytype, comptime exclude_fields: []const []const u8
) void {
    const fields = comptime std.meta.fields(@typeInfo(@TypeOf(object)).pointer.child);
    loop: inline for (fields) |field| {
        const field_name = field.name;

        if (comptime std.mem.eql(u8, field_name, "ob_base")) {
            continue;
        }

        inline for (exclude_fields) |exclude_field| {
            if (comptime std.mem.eql(u8, field_name, exclude_field)) {
                continue :loop;
            }
        }

        switch (@typeInfo(field.type)) {
            .optional => |data| {
                switch (@typeInfo(data.child)) {
                    .pointer => |data2| {
                        if (data2.child == Python.PyObject) {
                            py_decref_and_set_null(&@field(object, field_name));
                        }
                    },
                    else => {}
                }
            },
            .pointer => |data| {
                if (data.child == Python.PyObject) {
                    py_decref(@field(object, field_name));
                    @field(object, field_name) = undefined;
                }else if (@typeInfo(data.child) == .@"struct") {
                    if (@hasField(data.child, "ob_base")) {
                        py_decref(@ptrCast(@field(object, field_name)));
                        continue :loop;
                    }
                    deinitialize_object_fields(@field(object, field_name), exclude_fields);
                }
            },
            .@"struct" => {
                deinitialize_object_fields(&@field(object, field_name), exclude_fields);
            },
            else => {}
        }
    }
}

const Python = @This();
